"""Oneshot printer — incomplete. Fix the SPEC.md contract."""
CHROME = "· turn still going ·"


def chrome_goes_to_stdout(unattended, json_mode):
    # BUG: chrome always rides stdout (turn-pulse on -p / --json).
    return True


def emit_pulse(stream, unattended=False, json_mode=False):
    if chrome_goes_to_stdout(unattended, json_mode):
        stream.write(CHROME + "\n")


def print_answer(stream, text, unattended=False, json_mode=False):
    emit_pulse(stream, unattended, json_mode)
    stream.write(text + "\n")
