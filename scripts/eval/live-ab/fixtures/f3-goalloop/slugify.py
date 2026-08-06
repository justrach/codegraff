"""URL slug helper used by the docs site build."""


def slugify(text):
    """Turn a title into a URL slug.

    Currently a naive pass-through: callers report the output is not usable
    as a URL yet.
    """
    return text
