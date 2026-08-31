# Pi + Codegraff Gemini echo

Pi's `openai-completions` assembler keeps `role` / `content` / `tool_calls` and drops the fields Gemini Interactions needs on the next turn:

- `message.id` starting with `v1_`
- `thought_signature` on the message and each `tool_calls[]` entry
- `extra_content` if present

Without those, a `role:tool` follow-up 400s (`request_rejected`, ~217 bytes). Do **not** rewrite `role: "tool"` to `role: "function"`.

Install the extension (Pi auto-loads `~/.pi/agent/extensions/*.ts`):

```bash
mkdir -p ~/.pi/agent/extensions
cp graff-evals/pi-extensions/codegraff-gemini-echo.ts ~/.pi/agent/extensions/
```

Smoke:

```bash
python3 graff-evals/run.py --harness pi-codegraff --model gemini-3.7-flash --task fix-fib
```

For a same-seat SWE A/B against graff (SuperGrok / grok-4.6), skip the
gateway and use `pi-xai`:

```bash
# pi-xai.sh reads ~/.xai/credentials/graff-oauth.json (same as `graff login xai`)
cd graff-evals && ./run.py --suite swe --harness graff-dev,pi-xai --model grok-4.6 -j 6
```
