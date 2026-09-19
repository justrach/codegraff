import type { AcpTransport } from "./acp-transport";

/** Production turns run for hours; GUI fixtures script seconds-long turns. When the
 * fixture's outer budget is visible, a worker silent past (outer - 60s) is hung,
 * and the HTTP stream must error so the renderer shows failure instead of hanging
 * until the external watchdog SIGKILLs the group with no diagnostics. The smoke's
 * own agent-completion bound (outer - 30s) then captures that error in its dump. */
export function promptTimeoutMs(): number {
  const day = 24 * 60 * 60 * 1000;
  const capped = Number(process.env.GRAFF_TEST_TIMEOUT_MS) - 60_000;
  if (!Number.isFinite(capped) || capped < 30_000) return day;
  return Math.min(day, capped);
}

/** An ACP error is a terminal RPC reply, not a broken HTTP response. Erroring
 * the controller discards queued output and replaces the reason with the
 * browser's generic network error. Close on the terminal line itself so reader
 * cleanup cannot cancel an already finished prompt. */
export function createPromptStream(transport: Pick<AcpTransport, "request">, params: unknown, cancel: () => void) {
  const encoder = new TextEncoder();
  let closed = false;
  let pending!: Promise<unknown>;
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      const send = (line: string) => {
        if (closed) return;
        controller.enqueue(encoder.encode(`${line}\n`));
        const message = JSON.parse(line);
        if (!message.method && "id" in message && ("result" in message || "error" in message)) {
          closed = true;
          controller.close();
        }
      };
      pending = transport.request("session/prompt", params, promptTimeoutMs(), send);
      // The prompt is now written before any subsequent cancel on this
      // transport. Flush readiness immediately: waiting for model output
      // makes steering unavailable throughout a slow first response.
      if (!closed) send(JSON.stringify({ method: "session/update", params: {
        update: { sessionUpdate: "gui_prompt_ready" },
      } }));
      void pending.then(() => {
        if (closed) return;
        // Missing terminal evidence must never become an inferred success.
        send(JSON.stringify({ id: null, error: { code: -32603, message: "Graff ended without a turn result." } }));
      }, (error: unknown) => {
        if (closed) return;
        // Worker exits, timeouts and cancel recovery have no RPC reply to relay.
        send(JSON.stringify({ id: null, error: { code: -32603,
          message: error instanceof Error ? error.message : String(error) } }));
      });
    },
    cancel() {
      if (closed) return;
      closed = true;
      cancel();
    },
  });
  return { stream, pending };
}
