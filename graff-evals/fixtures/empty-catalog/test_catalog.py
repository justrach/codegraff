import json

from catalog import NATIVE, request_body, tools_json


def test_steady_catalog():
    assert json.loads(tools_json()) == NATIVE
    body = json.loads(request_body())
    assert body["tools"] == NATIVE


def test_showcase_rebuilds():
    raw = tools_json(showcase=True)
    assert raw != ""
    assert json.loads(raw) == NATIVE
    body = json.loads(request_body(showcase=True))
    assert body["tools"] == NATIVE
    assert ",}" not in request_body(showcase=True)


if __name__ == "__main__":
    test_steady_catalog()
    test_showcase_rebuilds()
    print("OK")
