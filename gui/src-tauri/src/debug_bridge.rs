//! Dev-only debug bridge: a localhost HTTP server that lets an external agent
//! (or a test harness) drive the *native* Tauri webview — evaluate JS with
//! return values, capture the real window, and synthesize input. This is the
//! "agentic remote control" for the desktop app, mirroring what a CDP session
//! gives you for a browser tab.
//!
//! Gate: the HTTP server only starts in debug builds (`cfg(debug_assertions)`).
//! The command + type are always compiled so the `invoke_handler!` list is
//! stable across configurations; in release the command is a harmless no-op
//! (nothing is ever pending because the server never runs).

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use tauri::{AppHandle, Manager};

const PORT: u16 = 9233;
const EVAL_TIMEOUT: Duration = Duration::from_secs(8);

#[derive(Debug)]
struct EvalResult {
    ok: bool,
    value: Option<String>,
    error: Option<String>,
}

/// Shared state holding pending eval requests and a handle to the app. Cheap to
/// clone (Arc-backed); one copy lives in Tauri's managed state (so the
/// `cg_debug_eval_result` command can resolve requests), another in the server
/// thread.
#[derive(Clone)]
pub struct DebugBridge {
    app: AppHandle,
    pending: Arc<Mutex<HashMap<u64, mpsc::Sender<EvalResult>>>>,
    next_id: Arc<AtomicU64>,
}

impl DebugBridge {
    pub fn new(app: AppHandle) -> Self {
        Self {
            app,
            pending: Arc::new(Mutex::new(HashMap::new())),
            next_id: Arc::new(AtomicU64::new(1)),
        }
    }

    /// Invoked from the webview (via `__TAURI_INTERNALS__.invoke`) to return an
    /// eval result. No-op when nothing is pending (e.g. release builds).
    pub fn resolve(&self, id: u64, ok: bool, value: Option<String>, error: Option<String>) {
        let sender = self
            .pending
            .lock()
            .ok()
            .and_then(|mut map| map.remove(&id));
        if let Some(tx) = sender {
            let _ = tx.send(EvalResult { ok, value, error });
        }
    }

    /// Launch the HTTP server. Only does something in debug builds.
    pub fn start(self) {
        #[cfg(debug_assertions)]
        {
            std::thread::spawn(move || run_server(self));
        }
        #[cfg(not(debug_assertions))]
        {
            let _ = self;
        }
    }
}

/// Tauri command the webview calls to deliver an eval result back to Rust.
/// Always registered; harmless when the bridge isn't running.
#[tauri::command]
#[allow(dead_code)]
pub fn cg_debug_eval_result(
    id: u64,
    ok: bool,
    value: Option<String>,
    error: Option<String>,
    state: tauri::State<'_, DebugBridge>,
) {
    state.resolve(id, ok, value, error);
}

#[cfg(debug_assertions)]
fn run_server(bridge: DebugBridge) {
    let server = match tiny_http::Server::http(format!("127.0.0.1:{PORT}")) {
        Ok(s) => s,
        Err(error) => {
            log::error!("debug bridge failed to bind 127.0.0.1:{PORT}: {error}");
            return;
        }
    };
    log::info!("debug bridge listening on http://127.0.0.1:{PORT}");

    for mut request in server.incoming_requests() {
        let method = request.method().as_str().to_string();
        let url = request.url().to_string();
        let response = handle_request(&method, &url, &mut request, &bridge);
        let _ = request.respond(response);
    }
}

#[cfg(debug_assertions)]
fn handle_request(
    method: &str,
    url: &str,
    request: &mut tiny_http::Request,
    bridge: &DebugBridge,
) -> tiny_http::Response<std::io::Cursor<Vec<u8>>> {
    match (method, url) {
        ("GET", "/health") => json_response(200, r#"{"ok":true}"#),
        ("POST", "/eval-result") => {
            let mut body = String::new();
            if request.as_reader().read_to_string(&mut body).is_err() {
                return json_response(400, r#"{"ok":false}"#);
            }
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&body) {
                let id = parsed.get("id").and_then(|v| v.as_u64()).unwrap_or(0);
                let ok = parsed.get("ok").and_then(|v| v.as_bool()).unwrap_or(false);
                let value = parsed
                    .get("value")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());
                let error = parsed
                    .get("error")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());
                bridge.resolve(id, ok, value, error);
            }
            json_response(200, r#"{"ok":true}"#)
        }
        ("POST", "/eval") => {
            let mut body = String::new();
            if request.as_reader().read_to_string(&mut body).is_err() {
                return json_response(400, r#"{"ok":false,"error":"bad body"}"#);
            }
            let parsed: serde_json::Value = match serde_json::from_str(&body) {
                Ok(v) => v,
                Err(_) => return json_response(400, r#"{"ok":false,"error":"bad json"}"#),
            };
            let code = match parsed.get("code").and_then(|v| v.as_str()) {
                Some(c) => c,
                None => {
                    return json_response(400, r#"{"ok":false,"error":"missing code"}"#)
                }
            };
            handle_eval(bridge, code)
        }
        ("GET", "/screenshot") => match capture_screenshot(&bridge.app) {
            Ok(bytes) => tiny_http::Response::from_data(bytes)
                .with_header(tiny_http::Header::from_bytes(
                    b"Content-Type".as_ref(),
                    b"image/png".as_ref(),
                )
                .unwrap()),
            Err(error) => json_response(
                500,
                &format!(r#"{{"ok":false,"error":{}}}"#, serde_json::json!(error)),
            ),
        },
        _ => json_response(404, r#"{"ok":false,"error":"not found"}"#),
    }
}

#[cfg(debug_assertions)]
fn handle_eval(bridge: &DebugBridge, code: &str) -> tiny_http::Response<std::io::Cursor<Vec<u8>>> {
    let id = bridge.next_id.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = mpsc::channel();
    if let Ok(mut map) = bridge.pending.lock() {
        map.insert(id, tx);
    } else {
        return json_response(500, r#"{"ok":false,"error":"state lock"}"#);
    }

    // Inject the user's code directly (no inner `eval()` — Tauri's default CSP
    // blocks `eval`/`new Function`, so we inline the code as the body of an
    // async arrow that evaluates it as an expression). The result is returned
    // via Tauri's native IPC (`__TAURI_INTERNALS__.invoke`), which is CSP-exempt
    // — unlike `fetch`, native invoke always works. The value is
    // JSON.stringified in JS so any serializable DOM state round-trips cleanly.
    // NB: `code` is inlined raw, so it must be a balanced expression (wrap
    // statements in an IIFE).
    let js = format!(
        "(async()=>{{const id={id};const send=(o)=>{{try{{window.__TAURI_INTERNALS__.invoke('cg_debug_eval_result',o)}}catch(_){{}}}};try{{const r=await (async()=>({user_code}))();let v;try{{v=JSON.stringify(r)}}catch(_){{v=String(r)}}send({{id,ok:true,value:v}})}}catch(e){{send({{id,ok:false,error:(e&&e.stack)||String(e)}})}}}})()",
        id = id,
        user_code = code,
    );

    let window = bridge.app.get_webview_window("main");
    if window.is_none() {
        drop_pending(bridge, id);
        return json_response(503, r#"{"ok":false,"error":"no main window"}"#);
    }
    log::info!("[debug-bridge] eval id={id}");
    if let Err(error) = window.unwrap().eval(&js) {
        drop_pending(bridge, id);
        return json_response(
            500,
            &format!(r#"{{"ok":false,"error":{}}}"#, serde_json::json!(error.to_string())),
        );
    }

    match rx.recv_timeout(EVAL_TIMEOUT) {
        Ok(result) => {
            let body = serde_json::json!({
                "ok": result.ok,
                "value": result.value,
                "error": result.error,
            });
            json_response(200, &body.to_string())
        }
        Err(_) => {
            drop_pending(bridge, id);
            json_response(504, r#"{"ok":false,"error":"eval timeout"}"#)
        }
    }
}

#[cfg(debug_assertions)]
fn drop_pending(bridge: &DebugBridge, id: u64) {
    if let Ok(mut map) = bridge.pending.lock() {
        map.remove(&id);
    }
}

/// Capture the main window: focus it, grab the full screen via `screencapture`,
/// then crop to the window's physical bounds (which match screencapture's pixel
/// space, even on retina). Uses only the already-vendored `image` crate.
#[cfg(debug_assertions)]
fn capture_screenshot(app: &AppHandle) -> Result<Vec<u8>, String> {
    let window = app
        .get_webview_window("main")
        .ok_or_else(|| "no main window".to_string())?;
    let _ = window.set_focus();
    std::thread::sleep(Duration::from_millis(150));

    let pos = window.outer_position().map_err(|e| e.to_string())?;
    let size = window.outer_size().map_err(|e| e.to_string())?;
    let x = pos.x.max(0) as u32;
    let y = pos.y.max(0) as u32;
    let w = size.width;
    let h = size.height;

    let tmp = std::env::temp_dir().join("cg_debug_full.png");
    let status = std::process::Command::new("screencapture")
        .arg("-x")
        .arg(&tmp)
        .status()
        .map_err(|e| e.to_string())?;
    if !status.success() {
        return Err("screencapture failed".to_string());
    }

    let img = image::open(&tmp).map_err(|e| e.to_string())?;
    let img_w = img.width();
    let img_h = img.height();
    // Clamp the crop rect to the captured image (window may extend off-screen).
    let cw = w.min(img_w.saturating_sub(x));
    let ch = h.min(img_h.saturating_sub(y));
    if cw == 0 || ch == 0 {
        return Err("window not visible on primary display".to_string());
    }
    let cropped = img.crop_imm(x, y, cw, ch);

    let mut buf = Vec::new();
    let mut cursor = std::io::Cursor::new(&mut buf);
    cropped
        .write_to(&mut cursor, image::ImageFormat::Png)
        .map_err(|e| e.to_string())?;
    Ok(buf)
}

#[cfg(debug_assertions)]
fn json_response(code: u16, body: &str) -> tiny_http::Response<std::io::Cursor<Vec<u8>>> {
    tiny_http::Response::from_data(body.as_bytes().to_vec())
        .with_status_code(code)
        .with_header(
            tiny_http::Header::from_bytes(
                b"Content-Type".as_ref(),
                b"application/json".as_ref(),
            )
            .unwrap(),
        )
        .with_header(
            tiny_http::Header::from_bytes(
                b"Access-Control-Allow-Origin".as_ref(),
                b"*".as_ref(),
            )
            .unwrap(),
        )
}
