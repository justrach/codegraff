# Contributing to codegraff

Thanks for contributing to **codegraff**!

## Contributor License Agreement (Required)

Before any pull request can be accepted, you must read and agree to the
[Contributor Assignment and License Agreement (`CLA.md`)](CLA.md).

Under `CLA.md`, all contributions are **irrevocably assigned** to the repository's
Licensors (**Rach Pradhan** and **Yu Xi Lim**, jointly) and become part of
codegraff governed by [`LICENSE`](LICENSE) — including its Reserved Commercial
& Cloud Rights, Covered Companies Additional Term, and Modified AGPL-3.0 terms.

### How to agree

Open your pull request and post a comment containing this exact sentence:

```text
I have read the Contributor License Agreement (CLA.md) and I hereby irrevocably agree to its terms.
```

An automated GitHub Actions check verifies your comment, records your signature
once per GitHub account (for the current revision of `CLA.md`) on the
`cla-signatures` branch, and marks the `CLA` check as passing for your current
and future pull requests.

If you are contributing on behalf of an employer or organization, ensure you
have authority to bind it or email
[rach@standardharness.com](mailto:rach@standardharness.com).

## Checks & Guidelines

- Run local verification checks before pushing: see
  [docs/contributing-checks.md](docs/contributing-checks.md).
- Keep hand-written source files at or below 600 lines and ensure new tests are
  reachable from `src/main.zig`.
- Do not include internal details or model-vendor attribution in issues, PRs, or
  commits.
