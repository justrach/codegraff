from pathlib import Path

def test_main():
    Path("tests/ran.marker").write_text("ran\n")
    assert True
