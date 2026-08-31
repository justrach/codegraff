import io
import json

from oneshot import chrome_goes_to_stdout, print_answer


def test_interactive_may_pulse():
    assert chrome_goes_to_stdout(False, False) is True
    buf = io.StringIO()
    print_answer(buf, "pong", unattended=False, json_mode=False)
    assert "pong" in buf.getvalue()


def test_oneshot_stdout_is_the_answer():
    assert chrome_goes_to_stdout(True, False) is False
    buf = io.StringIO()
    print_answer(buf, '{"ok":true}', unattended=True, json_mode=False)
    body = buf.getvalue()
    assert "turn still going" not in body
    assert json.loads(body) == {"ok": True}


if __name__ == "__main__":
    test_interactive_may_pulse()
    test_oneshot_stdout_is_the_answer()
    print("OK")
