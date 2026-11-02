//! Shared issue-lifecycle guidance for ordinary reports and `/issue`.
pub const guidance =
    \\For a matching issue, inspect its state, closure reason, and latest
    \\resolution before reporting. Add only genuinely new reproduction evidence
    \\or diagnostics. If a current reproduction or new evidence shows that the
    \\same failure remains unresolved after a resolved closure, reopen the
    \\canonical issue and attach the evidence; do not create a duplicate just
    \\to obtain an open ticket. A comment alone does not complete a recurrence report.
    \\For an already-open match, add the new evidence without reopening it.
    \\For a duplicate closure, follow its canonical issue and update or reopen
    \\that issue as appropriate, rather than reopening the duplicate. Do not
    \\blindly reopen intentionally rejected, withdrawn, or out-of-scope reports.
    \\If reopening is denied or unavailable, save the new evidence as a comment
    \\when permitted and explicitly report that the issue remains closed and
    \\requires a maintainer; never claim reopening succeeded. Verify the final
    \\issue state and report it accurately, including any failed operation.
    \\No fresh evidence or unresolved recurrence means no automatic reopening.
    \\
;
