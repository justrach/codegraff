use std::collections::HashMap;
use std::fmt::Display;
use std::future::Future;

use anyhow::Context;
use tokio::sync::{Mutex, mpsc, oneshot};
use uuid::Uuid;

use crate::dto::{FollowupKind, FollowupOptionDto, FollowupRequestDto, FollowupResponseDto};

tokio::task_local! {
    static FOLLOWUP_CONTEXT: FollowupContext;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FollowupContext {
    pub workspace_path: String,
    pub conversation_id: String,
    pub request_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FollowupResolution {
    cancelled: bool,
    text: Option<String>,
    selected_option_ids: Vec<String>,
}

pub struct FollowupBridge {
    notifications: mpsc::UnboundedSender<FollowupRequestDto>,
    pending: Mutex<HashMap<String, oneshot::Sender<FollowupResolution>>>,
}

impl FollowupBridge {
    pub fn new(notifications: mpsc::UnboundedSender<FollowupRequestDto>) -> Self {
        Self {
            notifications,
            pending: Mutex::new(HashMap::new()),
        }
    }

    pub async fn prompt_question(&self, question: &str) -> anyhow::Result<Option<String>> {
        let response = self
            .request(FollowupKind::Text, question.to_string(), None)
            .await?;

        if response.cancelled {
            return Ok(None);
        }

        Ok(response.text.filter(|value| !value.trim().is_empty()))
    }

    pub async fn select_one<T>(&self, message: &str, options: Vec<T>) -> anyhow::Result<Option<T>>
    where
        T: Clone + Display + Send + 'static,
    {
        let mapped = map_options(options);
        let response = self
            .request(
                FollowupKind::Single,
                message.to_string(),
                Some(mapped.iter().map(|(_, option, _)| option.clone()).collect()),
            )
            .await?;

        if response.cancelled {
            return Ok(None);
        }

        let Some(selected_id) = response.selected_option_ids.first() else {
            return Ok(None);
        };

        Ok(mapped
            .into_iter()
            .find_map(|(id, _, option)| (id == *selected_id).then_some(option)))
    }

    pub async fn select_many<T>(
        &self,
        message: &str,
        options: Vec<T>,
    ) -> anyhow::Result<Option<Vec<T>>>
    where
        T: Clone + Display + Send + 'static,
    {
        let mapped = map_options(options);
        let response = self
            .request(
                FollowupKind::Multi,
                message.to_string(),
                Some(mapped.iter().map(|(_, option, _)| option.clone()).collect()),
            )
            .await?;

        if response.cancelled {
            return Ok(None);
        }

        let selected = mapped
            .into_iter()
            .filter_map(|(id, _, option)| {
                response.selected_option_ids.contains(&id).then_some(option)
            })
            .collect::<Vec<_>>();

        Ok(Some(selected))
    }

    pub async fn respond(&self, response: FollowupResponseDto) -> anyhow::Result<()> {
        let sender = self
            .pending
            .lock()
            .await
            .remove(&response.followup_id)
            .with_context(|| format!("Unknown follow-up request: {}", response.followup_id))?;

        sender
            .send(FollowupResolution {
                cancelled: response.cancelled,
                text: response.text,
                selected_option_ids: response.selected_option_ids.unwrap_or_default(),
            })
            .map_err(|_| anyhow::anyhow!("Follow-up receiver dropped"))?;

        Ok(())
    }

    pub async fn cancel_all(&self) {
        let pending = std::mem::take(&mut *self.pending.lock().await);
        for (_, sender) in pending {
            let _ = sender.send(cancelled_resolution());
        }
    }

    async fn request(
        &self,
        kind: FollowupKind,
        question: String,
        options: Option<Vec<FollowupOptionDto>>,
    ) -> anyhow::Result<FollowupResolution> {
        let context = FOLLOWUP_CONTEXT
            .try_with(|current| current.clone())
            .map_err(|_| anyhow::anyhow!("Follow-up requested outside an active chat context."))?;
        let followup_id = Uuid::new_v4().to_string();
        let (sender, receiver) = oneshot::channel();
        self.pending
            .lock()
            .await
            .insert(followup_id.clone(), sender);

        let payload = FollowupRequestDto {
            followup_id: followup_id.clone(),
            workspace_path: context.workspace_path,
            conversation_id: context.conversation_id,
            request_id: context.request_id,
            kind,
            question,
            options,
        };

        if let Err(error) = self.notifications.send(payload) {
            self.pending.lock().await.remove(&followup_id);
            return Err(anyhow::anyhow!(error.to_string()));
        }

        Ok(receiver.await.unwrap_or_else(|_| cancelled_resolution()))
    }
}

pub async fn with_followup_context<T, F>(context: FollowupContext, future: F) -> T
where
    F: Future<Output = T>,
{
    FOLLOWUP_CONTEXT.scope(context, future).await
}

fn map_options<T>(options: Vec<T>) -> Vec<(String, FollowupOptionDto, T)>
where
    T: Clone + Display + Send + 'static,
{
    options
        .into_iter()
        .enumerate()
        .map(|(index, option)| {
            let id = format!("option-{index}");
            (
                id.clone(),
                FollowupOptionDto {
                    id,
                    label: option.to_string(),
                },
                option,
            )
        })
        .collect()
}

fn cancelled_resolution() -> FollowupResolution {
    FollowupResolution {
        cancelled: true,
        text: None,
        selected_option_ids: Vec::new(),
    }
}
