import type { AcpTransport } from "./acp-transport";

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
      pending = transport.request("session/prompt", params, 24 * 60 * 60 * 1000, send);
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
