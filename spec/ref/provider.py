"""Executable port of lean-proofs/Graff/Provider.lean."""

from __future__ import annotations

from typing import Literal

Kind = Literal["anthropic", "openai", "responses"]
Auth = Literal["x_api_key", "bearer"]
Login = Literal["api_key", "codegraff_device", "codex_device", "kimi_device", "xai_device"]
Catalog = Literal["baked", "codex", "kimi", "openai", "anthropic"]


def row(
    id: str,
    kind: Kind,
    auth: Auth,
    login: Login = "api_key",
    catalog: Catalog = "baked",
    sub_login: bool = False,
    takes_effort: bool = False,
) -> dict:
    return {
        "id": id,
        "kind": kind,
        "auth": auth,
        "login": login,
        "catalog": catalog,
        "sub_login": sub_login,
        "takes_effort": takes_effort,
    }


SPECS: list[dict] = [
    row("anthropic", "anthropic", "x_api_key", catalog="anthropic"),
    row("codegraff", "openai", "bearer", login="codegraff_device", catalog="openai", takes_effort=True),
    row("deepseek", "openai", "bearer", takes_effort=True),
    row("openai", "responses", "bearer"),
    row("minimax", "anthropic", "bearer"),
    row("xiaomi", "openai", "bearer"),
    row("kilo", "openai", "bearer"),
    row("vercel", "openai", "bearer", catalog="openai"),
    row("groq", "openai", "bearer"),
    row("mistral", "openai", "bearer"),
    row("kimi", "openai", "bearer", login="kimi_device", catalog="kimi", sub_login=True),
    row("moonshot", "openai", "bearer"),
    row("xai", "openai", "bearer", login="xai_device", catalog="openai", sub_login=True),
    row("zai", "openai", "bearer"),
    row("fugu", "openai", "bearer"),
    row("fireworks", "openai", "bearer", catalog="openai"),
    row("mlx", "openai", "bearer"),
    row("lmstudio", "openai", "bearer"),
    row("codex", "responses", "bearer", login="codex_device", catalog="codex", sub_login=True),
]


def ws_capable(r: dict) -> bool:
    # #514: only codex and xai serve a WS endpoint; platform OpenAI does not.
    return r["id"] in ("codex", "xai") and r["kind"] == "responses"
