use std::path::{Path, PathBuf};

use bytes::Bytes;
use forge_app::{
    DirectoryReaderInfra, FileDirectoryInfra, FileInfoInfra, FileReaderInfra, FileRemoverInfra,
    FileWriterInfra, WalkedFile, Walker, WalkerInfra,
};
use forge_domain::FileInfo;

use super::DesktopInfra;

#[async_trait::async_trait]
impl FileReaderInfra for DesktopInfra {
    async fn read_utf8(&self, path: &Path) -> anyhow::Result<String> {
        self.inner.read_utf8(path).await
    }

    fn read_batch_utf8(
        &self,
        batch_size: usize,
        paths: Vec<PathBuf>,
    ) -> impl futures::Stream<Item = (PathBuf, anyhow::Result<String>)> + Send {
        self.inner.read_batch_utf8(batch_size, paths)
    }

    async fn read(&self, path: &Path) -> anyhow::Result<Vec<u8>> {
        self.inner.read(path).await
    }

    async fn range_read_utf8(
        &self,
        path: &Path,
        start_line: u64,
        end_line: u64,
    ) -> anyhow::Result<(String, FileInfo)> {
        self.inner.range_read_utf8(path, start_line, end_line).await
    }
}

#[async_trait::async_trait]
impl FileWriterInfra for DesktopInfra {
    async fn write(&self, path: &Path, contents: Bytes) -> anyhow::Result<()> {
        self.inner.write(path, contents).await
    }

    async fn append(&self, path: &Path, contents: Bytes) -> anyhow::Result<()> {
        self.inner.append(path, contents).await
    }

    async fn write_temp(&self, prefix: &str, ext: &str, content: &str) -> anyhow::Result<PathBuf> {
        self.inner.write_temp(prefix, ext, content).await
    }
}

#[async_trait::async_trait]
impl FileRemoverInfra for DesktopInfra {
    async fn remove(&self, path: &Path) -> anyhow::Result<()> {
        self.inner.remove(path).await
    }
}

#[async_trait::async_trait]
impl FileInfoInfra for DesktopInfra {
    async fn is_binary(&self, path: &Path) -> anyhow::Result<bool> {
        self.inner.is_binary(path).await
    }

    async fn is_file(&self, path: &Path) -> anyhow::Result<bool> {
        self.inner.is_file(path).await
    }

    async fn exists(&self, path: &Path) -> anyhow::Result<bool> {
        self.inner.exists(path).await
    }

    async fn file_size(&self, path: &Path) -> anyhow::Result<u64> {
        self.inner.file_size(path).await
    }
}

#[async_trait::async_trait]
impl FileDirectoryInfra for DesktopInfra {
    async fn create_dirs(&self, path: &Path) -> anyhow::Result<()> {
        self.inner.create_dirs(path).await
    }
}

#[async_trait::async_trait]
impl DirectoryReaderInfra for DesktopInfra {
    async fn list_directory_entries(
        &self,
        directory: &Path,
    ) -> anyhow::Result<Vec<(PathBuf, bool)>> {
        self.inner.list_directory_entries(directory).await
    }

    async fn read_directory_files(
        &self,
        directory: &Path,
        pattern: Option<&str>,
    ) -> anyhow::Result<Vec<(PathBuf, String)>> {
        self.inner.read_directory_files(directory, pattern).await
    }
}

#[async_trait::async_trait]
impl WalkerInfra for DesktopInfra {
    async fn walk(&self, config: Walker) -> anyhow::Result<Vec<WalkedFile>> {
        self.inner.walk(config).await
    }
}
