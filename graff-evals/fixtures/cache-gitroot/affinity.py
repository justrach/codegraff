"""Prompt-cache affinity — incomplete. Fix the SPEC.md contract."""
import hashlib
import os

CACHE_SALT = "graff-cache-affinity-v2"
SCRATCH_SEED = "graff-scratch"


def git_root_of(cwd):
    # BUG: never walks to .git; callers that used cwd got a unique cold key
    # per sandbox / worktree leaf.
    return None


def affinity_seed(cwd):
    # BUG: leaf cwd, so sibling sandboxes under one repo do not share a key.
    return os.path.abspath(cwd)


def cache_key(cwd):
    return hashlib.sha256((CACHE_SALT + affinity_seed(cwd)).encode()).hexdigest()
