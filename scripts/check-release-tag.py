#!/usr/bin/env python3
"""Reject prerelease and malformed tags from the stable publication path."""

import re
import sys

STABLE_TAG = re.compile(r"^v\d+\.\d+\.\d+(?:\.\d+)?$")


def is_stable_tag(tag):
    return STABLE_TAG.fullmatch(tag) is not None


if __name__ == "__main__":
    if len(sys.argv) != 2 or not is_stable_tag(sys.argv[1]):
        raise SystemExit("Expected a stable vX.Y.Z or vX.Y.Z.W tag")
