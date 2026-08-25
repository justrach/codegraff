"""Streaming JSON — incomplete. Fix the SPEC.md contract."""
import json
import re


class DecodingError(Exception):
    pass


class StreamConsumed(Exception):
    pass


class Stream:
    def __init__(self, data):
        self.data = data
        self.consumed = False


def _media(ct):
    ct = (ct or "").split(";", 1)[0].strip().lower()
    return ct


def iter_json(content_type, body, streaming=False):
    if isinstance(body, Stream):
        if streaming and body.consumed:
            raise StreamConsumed()
        data = body.data
        if streaming:
            body.consumed = True
    else:
        data = body

    media = _media(content_type)
    # BUG: accepts any *+json (e.g. image/svg+json)
    ok = (
        media == "application/json"
        or media.endswith("+json")
        or media in ("application/ndjson", "application/x-ndjson", "application/json-seq")
    )
    if not ok:
        raise DecodingError(media)

    if media in ("application/ndjson", "application/x-ndjson"):
        # BUG: blank lines are parsed
        for line in re.split(r"\r\n|\n|\r", data):
            yield json.loads(line)
        return

    if media == "application/json-seq":
        if not data.strip():
            return
        parts = data.split("\x1e")
        for part in parts:
            if not part.strip():
                continue
            if part.endswith("\n"):
                part = part[:-1]
            yield json.loads(part)
        return

    text = data.lstrip()
    val, _end = json.JSONDecoder().raw_decode(text)
    # BUG: leftover after one JSON value is ignored
    if isinstance(val, list):
        yield from val
    else:
        yield val
