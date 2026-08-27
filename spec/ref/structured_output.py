"""Executable port of lean-proofs/Graff/StructuredOutput.lean (#543 / #550)."""

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
    # anthropic: native output_config.format on the formatting turn (#550);
    # sox (rejected) falls back to the structured_output tool. Tools turns
    # never carry a grammar (ADR 0001).
    if tools:
        return "none"
    return "toolAnthropic" if sox else "outputConfig"


def prompt_schema(wire: str, schema: bool, sox: bool) -> bool:
    if not schema:
        return False
    if wire in ("anthropic", "openai"):
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
        # never_silent: a set schema always reaches the provider, except an
        # anthropic tools turn (ADR 0001; the two-phase split holds it).
        if s and row["carrier"] == "none" and not row["prompt_schema"]:
            if not (w == "anthropic" and t):
                raise ValueError(f"never_silent violated: {row}")
        # sox_leaves_responses_alone
        if w == "responses" and carrier(w, s, True, t) != carrier(w, s, False, t):
            raise ValueError(f"sox_leaves_responses_alone violated: {row}")
        # sox_degrades_anthropic_native
        if w == "anthropic" and s and not t:
            want = "toolAnthropic" if x else "outputConfig"
            if row["carrier"] != want:
                raise ValueError(f"sox_degrades_anthropic_native violated: {row}")
        # no_json_schema_after_rejection / no leftover output_config
        if x and row["carrier"] in ("jsonSchema", "outputConfig"):
            raise ValueError(f"no_json_schema_after_rejection violated: {row}")
        # absent_schema_is_silent
        if not s and (row["carrier"] != "none" or row["prompt_schema"]):
            raise ValueError(f"absent_schema_is_silent violated: {row}")
        # no_grammar_on_anthropic_tools
        if w == "anthropic" and s and t and row["carrier"] != "none":
            raise ValueError(f"no_grammar_on_anthropic_tools violated: {row}")
    return n


def payload() -> dict:
    return {"kernel": "structured_output", "cells": cells()}
