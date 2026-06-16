use std::fmt::Display;

use forge_app::UserInfra;

use super::DesktopInfra;

#[async_trait::async_trait]
impl UserInfra for DesktopInfra {
    async fn prompt_question(&self, question: &str) -> anyhow::Result<Option<String>> {
        self.followups.prompt_question(question).await
    }

    async fn select_one<T: Clone + Display + Send + 'static>(
        &self,
        message: &str,
        options: Vec<T>,
    ) -> anyhow::Result<Option<T>> {
        self.followups.select_one(message, options).await
    }

    async fn select_many<T: Display + Clone + Send + 'static>(
        &self,
        message: &str,
        options: Vec<T>,
    ) -> anyhow::Result<Option<Vec<T>>> {
        self.followups.select_many(message, options).await
    }
}
