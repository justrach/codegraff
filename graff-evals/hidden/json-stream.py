"""Held-out checks for json-stream."""
import os
import sys

sys.path.insert(0, os.getcwd())
from json_stream import DecodingError, Stream, StreamConsumed, iter_json  # noqa: E402


def main():
    assert list(iter_json("Application/JSON; charset=utf-8", "  {\"a\": 1}  ")) == [{"a": 1}]
    assert list(iter_json("application/vnd.api+json", "[1]")) == [1]
    try:
        list(iter_json("text/foo+json", "{}"))
        raise SystemExit("text/*+json must be rejected")
    except DecodingError:
        pass

    try:
        list(iter_json("application/json", "1 2"))
        raise SystemExit("trailing")
    except DecodingError:
        pass

    body = "\n3\r\n\r4\n"
    assert list(iter_json("application/x-ndjson", body)) == [3, 4]

    seq = "\x1e{\"x\":1}\n\x1e2"
    assert list(iter_json("application/json-seq", seq)) == [{"x": 1}, 2]
    assert list(iter_json("application/json-seq", "   ")) == []

    s = Stream("5")
    assert list(iter_json("application/json", s, streaming=False)) == [5]
    assert list(iter_json("application/json", s, streaming=False)) == [5]
    list(iter_json("application/json", s, streaming=True))
    try:
        list(iter_json("application/json", s, streaming=True))
        raise SystemExit("consumed")
    except StreamConsumed:
        pass

    print("HIDDEN_OK")


if __name__ == "__main__":
    main()
