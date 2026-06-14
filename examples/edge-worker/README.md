# edge-worker — the remote SDK inside Cloudflare Workers

Proof that `@graff-new/sdk/remote` runs in the real Workers runtime
(workerd): the harness *binary* cannot run there (native executable,
spawns subprocesses), but the fetch-only remote client driving a
`harness serve` bridge can.

```sh
harness serve --port 8926 --token edge-test   # terminal 1: the bridge
npx wrangler dev --port 8970                  # terminal 2: workerd
curl http://127.0.0.1:8970                    # session + tool turn, summarized
curl -N 'http://127.0.0.1:8970/?q=run:%20echo%20hi'   # events streamed through
```

`src/remote.ts` is a vendored copy of `sdk/ts/remote.ts` so the example is
self-contained — refresh it with `cp ../../sdk/ts/remote.ts src/` after an
SDK regen. In a real project, `npm install @graff-new/sdk` and import from
`@graff-new/sdk/remote` instead.

Deploying for real: front the bridge with TLS (it speaks plain HTTP),
point `BRIDGE_URL` at it, and store the token as a secret
(`npx wrangler secret put BRIDGE_TOKEN`) rather than a var.
