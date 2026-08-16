"""Executable port of lean-proofs/Graff/StructuredOutput.lean (#543)."""

from __future__ import annotations

WIRES = ("anthropic", "openai", "responses")
BOOLS = (False, True)


def carrier(wire: str, schema: bool, sox: bool, tools: bool) -> str:
    if not schema:
        return "none"
    if wire == "responses":
        return "textFormat"
    if wire == "openai":
        if not sox:
            return "jsonSchema"
        return "jsonObject" if tools else "toolOpenai"
    # anthropic: no response_format exists on this wire at all
    return "none" if tools else "toolAnthropic"


def prompt_schema(wire: str, schema: bool, sox: bool) -> bool:
    if not schema:
        return False
    if wire == "anthropic":
        return True
    if wire == "openai":
        return sox
    return False


def cells() -> list[dict]:
    rows = []
    for wire in WIRES:
        for schema in BOOLS:
            for sox in BOOLS:
                for tools in BOOLS:
                    rows.append({
                        "wire": wire,
                        "schema": schema,
                        "sox": sox,
                        "tools": tools,
                        "carrier": carrier(wire, schema, sox, tools),
                        "prompt_schema": prompt_schema(wire, schema, sox),
                    })
    return rows


def check_properties() -> int:
    n = 0
    for row in cells():
        n += 1
        w, s, x, t = row["wire"], row["schema"], row["sox"], row["tools"]
        # never_silent: a set schema always reaches the provider somewhere.
        if s and row["carrier"] == "none" and not row["prompt_schema"]:
            raise ValueError(f"never_silent violated: {row}")
        # sox_only_on_chat: the learned degrade changes nothing off the chat wire.
        if w != "openai" and carrier(w, s, True, t) != carrier(w, s, False, t):
            raise ValueError(f"sox_only_on_chat violated: {row}")
        # no_json_schema_after_rejection.
        if x and row["carrier"] == "jsonSchema":
            raise ValueError(f"no_json_schema_after_rejection violated: {row}")
        # absent_schema_is_silent.
        if not s and (row["carrier"] != "none" or row["prompt_schema"]):
            raise ValueError(f"absent_schema_is_silent violated: {row}")
    return n


def payload() -> dict:
    return {"kernel": "structured_output", "cells": cells()}
