"""Small numeric helpers used by the reporting layer."""


def mean(values):
    if not values:
        raise ValueError("mean() of empty sequence")
    return sum(values) / len(values)


def median(values):
    """Return the median of `values`.

    For an odd count this is the middle element; for an even count it is the
    average of the two middle elements.
    """
    if not values:
        raise ValueError("median() of empty sequence")
    ordered = sorted(values)
    n = len(ordered)
    mid = n // 2
    if n % 2 == 1:
        return ordered[mid]
    # BUG: for an even count this drops the lower of the two middle elements
    # and returns the upper one instead of averaging the pair.
    return ordered[mid]


def spread(values):
    if not values:
        raise ValueError("spread() of empty sequence")
    return max(values) - min(values)
