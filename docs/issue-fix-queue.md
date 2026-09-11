# Requested issue fixes

Checked 2026-09-10. These open issues contain an explicit `@justrach` mention
by yxlyx in the issue body or a comment. Requested work is tracked here; an issue
stays open until its fix is reviewed and delivered.

| Issue | Work | Status | Regression coverage |
|---|---|---|---|
| [#839](https://github.com/justrach/codegraff/issues/839) | Saved GUI conversations must not imply external execution finished. | Implemented; saved-session GUI regression coverage | Open intermediate REPL history in the GUI; verify snapshot status, refresh and explicit continuation. |
| [#823](https://github.com/justrach/codegraff/issues/823#issuecomment-5613707588) | Browser input should search ordinary terms and explain invalid addresses. | Queued | Search terms, hostnames, valid URLs and blocked schemes through the Browser form. |
| [#825](https://github.com/justrach/codegraff/issues/825#issuecomment-5613669743) | Make Tasks optional and explain the split-pane limit. | Queued | Explicit open/close, dismissal across updates/navigation and feedback at the pane limit. |
| [#829](https://github.com/justrach/codegraff/issues/829#issuecomment-5613854701) | Explain update unavailability accurately and align both menu controls. | Queued | Unavailability reasons, disabled controls and a supported manual update check. |
| [#832](https://github.com/justrach/codegraff/issues/832#issuecomment-5613862436) | GUI tests must preserve desktop focus by default. | Implemented; shared background policy and regression coverage | Shared hidden-window policy, automatic background preflight, trusted page input, macOS activation/window observation and explicit foreground opt-in. |
| [#845](https://github.com/justrach/codegraff/issues/845#issuecomment-5614160827) | Keep the thinking indicator live during follow-up composition and queuing. | Queued | Indicator progress, preserved input and queue delivery after the active turn. |

All default visual suites use the shared background policy. Native fullscreen,
computer input and native sheets remain explicitly opt-in; their foreground
checks were not run as part of this background verification.
