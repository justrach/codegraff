from stall_notice import GIVE_UP, stall_notice


def test_silent_while_budget_remains():
    assert stall_notice(2) is None
    assert stall_notice(1) is None


def test_give_up_when_budget_gone():
    assert stall_notice(0) == GIVE_UP


if __name__ == "__main__":
    test_silent_while_budget_remains()
    test_give_up_when_budget_gone()
    print("OK")
