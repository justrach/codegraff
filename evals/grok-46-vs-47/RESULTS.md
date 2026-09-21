# Grok 4.6 vs Grok 4.7 on three codegraff PRs

Single-turn Grok Build calls, `reasoning_effort=high`, tools off. Both models saw the same closed-book prompt: the bug, the relevant pre-change excerpt, and a request for one unified diff. Gold diffs are in `gold/`. Raw CLI JSON is in `runs/`.

Models resolved to `grok-4.6-build` and `grok-4.7-build`. This is the Build the CLI is logged into, not a separate public HTTPS call.

## Same price means the published card

Public list for both model names, under 200k prompt tokens: **$2 / 1M input, $0.50 / 1M cached input, $6 / 1M output**. Reasoning tokens are inside output. That is the card in the Grok 4.7 docs and the Grok 4.6 docs.

`grok-4.7-build` receipts matched that card to the fraction of a cent on every run, and on a one-word probe before these runs (`$0.048194`).

`grok-4.6-build` receipts were **exactly 0.34×** that card on all three runs. They do not match 1× list, 2× Fast, or `grok-build-0.1` ($1 / $2). The comparison below prices both models on the published card so a Build billing quirk is not treated as a model win. The receipt column is what the CLI actually printed.

## Latency, tokens, cost

| PR | Model | Wall | In | Cache | Out | Reasoning | Completion | Build receipt | List cost |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1149 | 4.6 | 109s | 17,502 | 256 | 5,962 | 5,461 | 501 | $0.02411 | $0.07090 |
| 1149 | 4.7 | 334s | 15,922 | 1,152 | 22,958 | 22,438 | 520 | $0.17017 | $0.17017 |
| 1096 | 4.6 | 139s | 18,669 | 0 | 8,064 | 7,036 | 1,028 | $0.02915 | $0.08572 |
| 1096 | 4.7 | 270s | 15,713 | 1,152 | 19,450 | 18,435 | 1,015 | $0.14870 | $0.14870 |
| 1035 | 4.6 | 260s | 16,846 | 1,920 | 15,551 | 14,319 | 1,232 | $0.04351 | $0.12796 |
| 1035 | 4.7 | 748s | 16,958 | 1,152 | 52,540 | 50,930 | 1,610 | $0.34973 | $0.34973 |
| all | 4.6 | 507s | 53,017 | 2,176 | 29,577 | 26,816 | 2,761 | $0.09676 | $0.28458 |
| all | 4.7 | 1,351s | 48,593 | 3,456 | 94,948 | 91,803 | 3,145 | $0.66860 | $0.66860 |

Visible completions are about the same length. 4.7's extra time and list-price cost are almost entirely reasoning tokens (3.4×). Output throughput including reasoning was 58 tok/s for 4.6 and 70 tok/s for 4.7, so 4.7 is not a slower decoder. It just thinks longer.

Pairs ran concurrently (same prompt, same window). PRs ran one pair after another. Wall time is each process's own clock.

## What was asked

- **#1149** tests only. A same-team `TEAM.*` keychain group must not authorize another bundle. `signBundle` must reject that profile before the signer runs.
- **#1096** the `@` menu must not activate its default row on Enter/Tab until `engaged` is set by hover or arrow keys. Unengaged Enter still submits.
- **#1035** drop `{pid}-{hex}.accord.sock` only when `proc_identity.stateOf` is `.reclaimable`. Unknown stays. Do not unlink the live listener's own sock. Sweep on listen.

## Checklist (8 each)

Scored against the merged diff's behavior, not against a byte-identical patch. These prompts did not include the full files, so none of the diffs are `patch -p1` clean. That miss is shared and is not in the checklist.

**#1149.** Profile test, different application id, explicit `TEAM.*` groups, `authorize` throws, gold `/provisioning profile/` regex, `signBundle` test, signer not called, other-bundle profile injected.

- 4.6 hit 6. It changed the application id (the fixture already has `TEAM.*`) and rejected before the signer. It did not set the groups explicitly, and the regex was `/application-identifier/` rather than `/provisioning profile/`.
- 4.7 hit 7. Same shape, plus an explicit `TEAM.*` assignment. Same wrong regex.

**#1096.** Helper predicate, PromptBar wired to it, unengaged Enter/Tab false, engaged Enter/Tab true, Shift does not activate, arrows are not activation, package.json gains the new test without dropping the others, tests use `node:test`.

- Both hit 7. The predicate matches the merged helper (`engaged && !shiftKey && (Enter || Tab)`). Both rewrote the `test` script down to two files, which would drop the rest of the native suite. 4.7 used `node:test`'s `test()`; 4.6 used `describe`/`it`, which still runs.

**#1035.** Parse `42-2a.accord.sock`, reject junk and non-positive pids, unlink only when reclaimable, unknown stays, skip own sock, do not dial an unlinked sock, sweep on listen, tests would compile against the real `listen` / `livePost` / `writeFile` signatures.

- Both hit 7. The reclaim rule is right. Both tests call `listen` and `livePost` with the wrong arity and would not compile. 4.7's parser also rejects non-hex stems. 4.6 uses the first dash, not the last; for this name format that is the same split.

## Reading

On this sample, high-effort 4.7 is not a better patch author. It wins one checklist point on #1149 and ties the other two. At the shared list price it costs 2.3× as much and takes 2.7× as long, because it spends about 22k–51k reasoning tokens to emit a completion of similar length.

n=3, one turn, no tools, no apply-and-test loop. A longer agent run could change the quality gap. It would not change the token shape seen here: 4.7's bill is reasoning.
