from json_stream import DecodingError, Stream, StreamConsumed, iter_json


def test_json_array_and_reject_other_tree():
    assert list(iter_json("application/json", "[1, 2]")) == [1, 2]
    try:
        list(iter_json("image/svg+json", "{}"))
        raise AssertionError("image/*+json must be rejected")
    except DecodingError:
        pass


def test_trailing_junk():
    try:
        list(iter_json("application/json", '{"a": 1} trailing'))
        raise AssertionError("trailing data must error")
    except DecodingError:
        pass


def test_ndjson_skips_blank():
    body = "1\n\n2\n"
    assert list(iter_json("application/ndjson", body)) == [1, 2]


def test_stream_consumed():
    s = Stream("[1]")
    assert list(iter_json("application/json", s, streaming=True)) == [1]
    try:
        list(iter_json("application/json", s, streaming=True))
        raise AssertionError("expected StreamConsumed")
    except StreamConsumed:
        pass


if __name__ == "__main__":
    test_json_array_and_reject_other_tree()
    test_trailing_junk()
    test_ndjson_skips_blank()
    test_stream_consumed()
    print("OK")
