"""Held-out checks for oneshot-chrome."""
import io
import json
import os
import sys

sys.path.insert(0, os.getcwd())
from oneshot import chrome_goes_to_stdout, emit_pulse, print_answer  # noqa: E402


def main():
    assert chrome_goes_to_stdout(False, True) is False
    assert chrome_goes_to_stdout(True, True) is False
    buf = io.StringIO()
    emit_pulse(buf, unattended=False, json_mode=True)
    assert buf.getvalue() == ""
    buf = io.StringIO()
    print_answer(buf, "[1,2]", unattended=False, json_mode=True)
    assert json.loads(buf.getvalue()) == [1, 2]
    print("hidden OK")


if __name__ == "__main__":
    main()
