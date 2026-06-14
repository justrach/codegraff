use forge_app::dto::openai::{ErrorCode, ErrorResponse};
use reqwest::StatusCode;
use serde_json::Value;

pub(crate) fn format_error_chain(error: &anyhow::Error) -> String {
    let mut parts = Vec::new();
    let mut pending_http_status = None;

    for error in error.chain() {
        let raw_message = error.to_string();
        let trimmed = raw_message.trim();
        if trimmed.is_empty() {
            continue;
        }

        if let Some(context) = parse_http_request_context(trimmed) {
            pending_http_status = context.status;
            push_error_part(&mut parts, &context.display());
            continue;
        }

        let formatted = format_error_detail(trimmed, pending_http_status.take());
        push_error_part(&mut parts, &formatted);
    }

    if parts.is_empty() {
        "Unknown error.".to_string()
    } else {
        parts.join(": ")
    }
}

#[derive(Clone, Copy)]
struct HttpRequestContext<'a> {
    status: Option<u16>,
    method: &'a str,
    url: &'a str,
}

impl HttpRequestContext<'_> {
    fn display(&self) -> String {
        format!("{} {}", self.method, self.url)
    }
}

fn push_error_part(parts: &mut Vec<String>, value: &str) {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return;
    }

    if parts.last().map(|last| last == trimmed).unwrap_or(false) {
        return;
    }

    parts.push(trimmed.to_string());
}

fn format_error_detail(message: &str, pending_status: Option<u16>) -> String {
    if let Some(formatted) = parse_http_reason_detail(message) {
        return formatted;
    }

    if let Some(formatted) = parse_http_status_detail(message) {
        return formatted;
    }

    if let Some(status) = pending_status {
        return format_http_body_detail(status, message);
    }

    if let Some(detail) = format_openai_error_detail(message) {
        return detail;
    }

    normalize_error_text(message)
}

fn parse_http_request_context(message: &str) -> Option<HttpRequestContext<'_>> {
    let mut parts = message.split_whitespace();
    let first = parts.next()?;
    let second = parts.next()?;
    let third = parts.next();

    match (first.parse::<u16>().ok(), third) {
        (Some(status), Some(url))
            if is_http_method(second) && is_http_url(url) && parts.next().is_none() =>
        {
            Some(HttpRequestContext { status: Some(status), method: second, url })
        }
        (None, Some(_)) => None,
        (_, None) if is_http_method(first) && is_http_url(second) && parts.next().is_none() => {
            Some(HttpRequestContext { status: None, method: first, url: second })
        }
        _ => None,
    }
}

fn parse_http_reason_detail(message: &str) -> Option<String> {
    let (status_text, body) = message.split_once(" Reason: ")?;
    let status = parse_status_prefix(status_text)?;
    let status_label = format_status_label(status, Some(status_text.trim()));
    let trimmed_body = body.trim();

    if trimmed_body.is_empty() || trimmed_body == "[Unknown]" {
        return Some(status_label);
    }

    let detail = format_openai_error_detail(trimmed_body)
        .unwrap_or_else(|| normalize_error_text(trimmed_body));
    Some(format!("{status_label} · {detail}"))
}

fn parse_http_status_detail(message: &str) -> Option<String> {
    let status_text = message.strip_prefix("Http Status: ")?.trim();
    let status = parse_status_prefix(status_text)?;
    Some(format_status_label(status, Some(status_text)))
}

fn format_http_body_detail(status: u16, body: &str) -> String {
    let status_label = format_status_label(status, None);

    match format_openai_error_detail(body) {
        Some(detail) => format!("{status_label} · {detail}"),
        None => format!("{status_label} · {}", normalize_error_text(body)),
    }
}

fn format_status_label(status: u16, fallback: Option<&str>) -> String {
    if let Ok(status_code) = StatusCode::from_u16(status) {
        match status_code.canonical_reason() {
            Some(reason) => format!("HTTP {} {}", status, reason),
            None => format!("HTTP {}", status),
        }
    } else {
        fallback
            .map(|value| format!("HTTP {value}"))
            .unwrap_or_else(|| format!("HTTP {status}"))
    }
}

fn format_openai_error_detail(body: &str) -> Option<String> {
    let error = parse_openai_error_response(body.trim())?;
    let mut parts = Vec::new();

    if let Some(code) = error.get_code_deep().map(format_error_code) {
        parts.push(format!("code {code}"));
    }

    if let Some(message) = first_error_message(&error) {
        parts.push(normalize_error_text(message));
    }

    if parts.is_empty() {
        None
    } else {
        Some(parts.join(" · "))
    }
}

fn parse_openai_error_response(body: &str) -> Option<ErrorResponse> {
    let value: Value = serde_json::from_str(body).ok()?;

    if let Some(error) = value.get("error") {
        return serde_json::from_value(error.clone()).ok();
    }

    serde_json::from_value(value).ok()
}

fn first_error_message(error: &ErrorResponse) -> Option<&str> {
    error
        .message
        .as_deref()
        .or_else(|| error.error.as_deref().and_then(first_error_message))
}

fn format_error_code(code: &ErrorCode) -> String {
    match code {
        ErrorCode::String(value) => value.clone(),
        ErrorCode::Number(value) => value.to_string(),
    }
}

fn parse_status_prefix(message: &str) -> Option<u16> {
    message.split_whitespace().next()?.parse::<u16>().ok()
}

fn is_http_method(value: &str) -> bool {
    matches!(
        value,
        "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "HEAD" | "OPTIONS"
    )
}

fn is_http_url(value: &str) -> bool {
    value.starts_with("http://") || value.starts_with("https://")
}

fn normalize_error_text(value: &str) -> String {
    const MAX_ERROR_TEXT_LEN: usize = 240;

    let compact = value.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.chars().count() <= MAX_ERROR_TEXT_LEN {
        return compact;
    }

    let truncated = compact.chars().take(MAX_ERROR_TEXT_LEN).collect::<String>();
    format!("{truncated}…")
}

#[cfg(test)]
mod tests {
    use anyhow::anyhow;

    use super::format_error_chain;

    #[test]
    fn format_error_chain_includes_nested_context() {
        let error = anyhow!("upstream rejected the request")
            .context("HTTP 400 Bad Request")
            .context("POST https://chatgpt.com/backend-api/codex/responses");

        assert_eq!(
            format_error_chain(&error),
            "POST https://chatgpt.com/backend-api/codex/responses: HTTP 400 Bad Request: upstream rejected the request"
        );
    }

    #[test]
    fn format_error_chain_deduplicates_adjacent_messages() {
        let error = anyhow!("Request failed").context("Request failed");

        assert_eq!(format_error_chain(&error), "Request failed");
    }

    #[test]
    fn format_error_chain_formats_openai_json_errors_from_request_context() {
        let error = anyhow!(
            "{}",
            r#"{"error":{"message":"Account is missing access to Codex","code":"access_denied"}}"#
        )
        .context("400 POST https://chatgpt.com/backend-api/codex/responses");

        assert_eq!(
            format_error_chain(&error),
            "POST https://chatgpt.com/backend-api/codex/responses: HTTP 400 Bad Request · code access_denied · Account is missing access to Codex"
        );
    }

    #[test]
    fn format_error_chain_formats_reason_wrapped_openai_errors() {
        let error = anyhow!(
            "{}",
            r#"400 Bad Request Reason: {"error":{"message":"Account is missing access to Codex","code":"access_denied"}}"#
        )
        .context("POST https://chatgpt.com/backend-api/codex/responses");

        assert_eq!(
            format_error_chain(&error),
            "POST https://chatgpt.com/backend-api/codex/responses: HTTP 400 Bad Request · code access_denied · Account is missing access to Codex"
        );
    }

    #[test]
    fn format_error_chain_formats_plain_http_response_bodies() {
        let error = anyhow!("upstream rejected the request")
            .context("400 POST https://chatgpt.com/backend-api/codex/responses");

        assert_eq!(
            format_error_chain(&error),
            "POST https://chatgpt.com/backend-api/codex/responses: HTTP 400 Bad Request · upstream rejected the request"
        );
    }

    #[test]
    fn format_error_chain_formats_http_status_wrappers() {
        let error = anyhow!("Http Status: 403 Forbidden")
            .context("POST https://chatgpt.com/backend-api/codex/responses");

        assert_eq!(
            format_error_chain(&error),
            "POST https://chatgpt.com/backend-api/codex/responses: HTTP 403 Forbidden"
        );
    }
}
