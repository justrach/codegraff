use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex as StdMutex};
use std::thread;

use anyhow::{Context, Result, anyhow};
use bstr::ByteSlice;
use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize, native_pty_system};
use tokio::sync::Mutex;

use crate::bridge::emitter::UiEventEmitter;
use crate::dto::{
    TerminalCloseInput, TerminalErrorEventDto, TerminalExitEventDto, TerminalOpenInput,
    TerminalOutputEventDto, TerminalResizeInput, TerminalSessionDto, TerminalWriteInput,
};
use crate::runtime::canonicalize_workspace_path;

const DEFAULT_COLS: u16 = 80;
const DEFAULT_ROWS: u16 = 24;

pub struct TerminalManager {
    emitter: Arc<dyn UiEventEmitter>,
    sessions: Mutex<HashMap<String, Arc<TerminalSession>>>,
}

impl TerminalManager {
    pub fn new(emitter: Arc<dyn UiEventEmitter>) -> Self {
        Self {
            emitter,
            sessions: Mutex::new(HashMap::new()),
        }
    }

    pub async fn open(&self, input: TerminalOpenInput) -> Result<TerminalSessionDto> {
        let workspace_path = canonicalize_workspace_path(PathBuf::from(input.workspace_path))?;
        let (cols, rows) = normalize_size(input.cols, input.rows);

        if let Some(existing) = self.get_session(&input.terminal_id).await {
            if existing.has_exited()? {
                self.remove_session(&input.terminal_id).await;
            } else {
                existing.resize(cols, rows)?;
                return existing.snapshot();
            }
        }

        let session = spawn_terminal_session(
            self.emitter.clone(),
            input.terminal_id,
            workspace_path,
            cols,
            rows,
        )?;
        let snapshot = session.snapshot()?;

        let mut sessions = self.sessions.lock().await;
        sessions.insert(session.terminal_id.clone(), session);

        Ok(snapshot)
    }

    pub async fn write(&self, input: TerminalWriteInput) -> Result<()> {
        let session = self
            .get_session(&input.terminal_id)
            .await
            .ok_or_else(|| anyhow!("Terminal session {} is not open", input.terminal_id))?;
        session.write(&input.data)
    }

    pub async fn resize(&self, input: TerminalResizeInput) -> Result<()> {
        let session = self
            .get_session(&input.terminal_id)
            .await
            .ok_or_else(|| anyhow!("Terminal session {} is not open", input.terminal_id))?;
        let (cols, rows) = normalize_size(input.cols, input.rows);
        session.resize(cols, rows)
    }

    pub async fn close(&self, input: TerminalCloseInput) -> Result<()> {
        let session = self.remove_session(&input.terminal_id).await;
        if let Some(session) = session {
            session.kill()?;
        }

        Ok(())
    }

    async fn get_session(&self, terminal_id: &str) -> Option<Arc<TerminalSession>> {
        let sessions = self.sessions.lock().await;
        sessions.get(terminal_id).cloned()
    }

    async fn remove_session(&self, terminal_id: &str) -> Option<Arc<TerminalSession>> {
        let mut sessions = self.sessions.lock().await;
        sessions.remove(terminal_id)
    }
}

struct TerminalSession {
    terminal_id: String,
    workspace_path: String,
    shell: String,
    master: StdMutex<Box<dyn MasterPty + Send>>,
    writer: StdMutex<Box<dyn Write + Send>>,
    killer: StdMutex<Box<dyn ChildKiller + Send + Sync>>,
    exit_status: StdMutex<bool>,
}

impl TerminalSession {
    fn snapshot(&self) -> Result<TerminalSessionDto> {
        let size = lock_mutex(&self.master, "terminal master")?.get_size()?;
        Ok(TerminalSessionDto {
            terminal_id: self.terminal_id.clone(),
            workspace_path: self.workspace_path.clone(),
            shell: self.shell.clone(),
            cols: size.cols,
            rows: size.rows,
        })
    }

    fn write(&self, data: &str) -> Result<()> {
        if self.has_exited()? {
            return Err(anyhow!("Terminal session {} has exited", self.terminal_id));
        }

        let mut writer = lock_mutex(&self.writer, "terminal writer")?;
        writer.write_all(data.as_bytes())?;
        writer.flush()?;
        Ok(())
    }

    fn resize(&self, cols: u16, rows: u16) -> Result<()> {
        if self.has_exited()? {
            return Ok(());
        }

        lock_mutex(&self.master, "terminal master")?.resize(PtySize {
            cols,
            rows,
            pixel_width: 0,
            pixel_height: 0,
        })?;
        Ok(())
    }

    fn kill(&self) -> Result<()> {
        if self.has_exited()? {
            return Ok(());
        }

        let mut killer = lock_mutex(&self.killer, "terminal killer")?;
        match killer.kill() {
            Ok(()) => Ok(()),
            Err(error) => Err(error).with_context(|| {
                format!("Failed to terminate terminal session {}", self.terminal_id)
            }),
        }
    }

    fn has_exited(&self) -> Result<bool> {
        Ok(*lock_mutex(&self.exit_status, "terminal exit status")?)
    }

    fn mark_exited(&self) -> Result<()> {
        let mut exit_status = lock_mutex(&self.exit_status, "terminal exit status")?;
        *exit_status = true;
        Ok(())
    }
}

fn spawn_terminal_session(
    emitter: Arc<dyn UiEventEmitter>,
    terminal_id: String,
    workspace_path: String,
    cols: u16,
    rows: u16,
) -> Result<Arc<TerminalSession>> {
    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            cols,
            rows,
            pixel_width: 0,
            pixel_height: 0,
        })
        .with_context(|| format!("Failed to create PTY for {}", workspace_path))?;

    let (shell, command) = build_shell_command(&workspace_path);
    let child = pair
        .slave
        .spawn_command(command)
        .with_context(|| format!("Failed to spawn shell {}", shell))?;
    let killer = child.clone_killer();
    let reader = pair.master.try_clone_reader()?;
    let writer = pair.master.take_writer()?;

    drop(pair.slave);

    let session = Arc::new(TerminalSession {
        terminal_id,
        workspace_path,
        shell,
        master: StdMutex::new(pair.master),
        writer: StdMutex::new(writer),
        killer: StdMutex::new(killer),
        exit_status: StdMutex::new(false),
    });

    spawn_reader_thread(emitter.clone(), session.clone(), reader)?;
    spawn_wait_thread(emitter, session.clone(), child)?;

    Ok(session)
}

fn spawn_reader_thread(
    emitter: Arc<dyn UiEventEmitter>,
    session: Arc<TerminalSession>,
    mut reader: Box<dyn Read + Send>,
) -> Result<()> {
    let thread_name = format!("terminal-reader-{}", session.terminal_id);
    thread::Builder::new()
        .name(thread_name)
        .spawn(move || {
            let mut buffer = [0u8; 4096];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => {
                        let data = buffer[..count].as_bstr().to_string();
                        if let Err(error) = emitter.emit_terminal_output(TerminalOutputEventDto {
                            terminal_id: session.terminal_id.clone(),
                            data,
                        }) {
                            log::warn!("Failed to emit terminal output: {error:#}");
                        }
                    }
                    Err(error) => {
                        if session.has_exited().unwrap_or(false) {
                            break;
                        }

                        if let Err(emit_error) =
                            emitter.emit_terminal_error(TerminalErrorEventDto {
                                terminal_id: session.terminal_id.clone(),
                                message: error.to_string(),
                            })
                        {
                            log::warn!("Failed to emit terminal reader error: {emit_error:#}");
                        }
                        break;
                    }
                }
            }
        })
        .context("Failed to spawn terminal reader thread")?;

    Ok(())
}

fn spawn_wait_thread(
    emitter: Arc<dyn UiEventEmitter>,
    session: Arc<TerminalSession>,
    mut child: Box<dyn portable_pty::Child + Send + Sync>,
) -> Result<()> {
    let thread_name = format!("terminal-wait-{}", session.terminal_id);
    thread::Builder::new()
        .name(thread_name)
        .spawn(move || match child.wait() {
            Ok(status) => {
                let exit_code = Some(status.exit_code());
                let signal = status.signal().map(ToOwned::to_owned);
                if let Err(error) = session.mark_exited() {
                    log::warn!("Failed to update terminal exit state: {error:#}");
                }
                if let Err(error) = emitter.emit_terminal_exit(TerminalExitEventDto {
                    terminal_id: session.terminal_id.clone(),
                    exit_code,
                    signal,
                }) {
                    log::warn!("Failed to emit terminal exit event: {error:#}");
                }
            }
            Err(error) => {
                if let Err(mark_error) = session.mark_exited() {
                    log::warn!("Failed to update terminal exit state: {mark_error:#}");
                }
                if let Err(emit_error) = emitter.emit_terminal_error(TerminalErrorEventDto {
                    terminal_id: session.terminal_id.clone(),
                    message: error.to_string(),
                }) {
                    log::warn!("Failed to emit terminal wait error: {emit_error:#}");
                }
            }
        })
        .context("Failed to spawn terminal wait thread")?;

    Ok(())
}

fn build_shell_command(workspace_path: &str) -> (String, CommandBuilder) {
    #[cfg(windows)]
    let shell = std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".to_string());
    #[cfg(not(windows))]
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());

    let mut command = CommandBuilder::new(shell.clone());
    #[cfg(not(windows))]
    {
        if PathBuf::from(&shell)
            .file_name()
            .and_then(|name| name.to_str())
            == Some("zsh")
        {
            command.arg("-o");
            command.arg("NO_PROMPT_SP");
            command.arg("-o");
            command.arg("NO_PROMPT_CR");
        }
    }
    command.cwd(workspace_path);
    command.env("TERM", "xterm-256color");
    command.env("COLORTERM", "truecolor");
    command.env("TERM_PROGRAM", "codegraff-gui");

    (shell, command)
}

fn lock_mutex<'a, T>(mutex: &'a StdMutex<T>, label: &str) -> Result<std::sync::MutexGuard<'a, T>> {
    mutex.lock().map_err(|_| anyhow!("Failed to lock {label}"))
}

fn normalize_size(cols: u16, rows: u16) -> (u16, u16) {
    let cols = if cols == 0 { DEFAULT_COLS } else { cols.max(2) };
    let rows = if rows == 0 { DEFAULT_ROWS } else { rows.max(1) };
    (cols, rows)
}
