// Echo Gemini Interactions fields the Codegraff gateway needs on tool follow-ups.
// Pi's openai-completions assembler keeps role/content/tool_calls and drops
// message.id (v1_…), thought_signature, and extra_content — the next request
// then 400s with request_rejected (~217 bytes). Do not rewrite role:tool.

const GATEWAY = "gateway.codegraff.com";

type Echo = {
	id?: string;
	thought_signature?: string;
	extra_content?: unknown;
	tool_sigs: Record<string, string>;
};

let last: Echo = { tool_sigs: {} };

function parseSse(text: string): void {
	for (const line of text.split("\n")) {
		if (!line.startsWith("data: ")) continue;
		const payload = line.slice(6).trim();
		if (!payload || payload === "[DONE]") continue;
		let ev: any;
		try {
			ev = JSON.parse(payload);
		} catch {
			continue;
		}
		if (typeof ev.id === "string" && ev.id.startsWith("v1_")) last.id = ev.id;
		const choice = ev.choices?.[0];
		const delta = choice?.delta ?? choice?.message;
		if (!delta || typeof delta !== "object") continue;
		if (typeof delta.id === "string" && delta.id.startsWith("v1_")) last.id = delta.id;
		if (typeof delta.thought_signature === "string" && delta.thought_signature) {
			last.thought_signature = delta.thought_signature;
		}
		if (delta.extra_content) last.extra_content = delta.extra_content;
		if (!Array.isArray(delta.tool_calls)) continue;
		for (const tc of delta.tool_calls) {
			if (!tc || typeof tc !== "object") continue;
			const sig =
				(typeof tc.thought_signature === "string" && tc.thought_signature) ||
				tc.extra_content?.google?.thought_signature;
			if (typeof sig === "string" && sig) {
				if (typeof tc.id === "string" && tc.id) last.tool_sigs[tc.id] = sig;
				last.thought_signature ??= sig;
			}
		}
	}
}

function wrapFetch(): void {
	const g = globalThis as typeof globalThis & { __cgGeminiEchoFetch?: boolean };
	if (g.__cgGeminiEchoFetch) return;
	g.__cgGeminiEchoFetch = true;
	const orig = globalThis.fetch.bind(globalThis);
	globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
		const url =
			typeof input === "string"
				? input
				: input instanceof URL
					? input.href
					: (input as Request).url;
		const res = await orig(input, init);
		if (!url.includes(GATEWAY) || !res.body) return res;
		const decoder = new TextDecoder();
		let buf = "";
		const transform = new TransformStream<Uint8Array, Uint8Array>({
			transform(chunk, controller) {
				controller.enqueue(chunk);
				buf += decoder.decode(chunk, { stream: true });
				let nl = buf.indexOf("\n");
				while (nl >= 0) {
					parseSse(buf.slice(0, nl + 1));
					buf = buf.slice(nl + 1);
					nl = buf.indexOf("\n");
				}
			},
			flush() {
				if (buf) parseSse(buf);
			},
		});
		return new Response(res.body.pipeThrough(transform), res);
	};
}

wrapFetch();

export default function (pi: { on: (event: string, fn: (event: any) => unknown) => void }) {
	pi.on("before_provider_request", (event) => {
		const payload = event.payload;
		const msgs = payload?.messages;
		if (!Array.isArray(msgs)) return;
		const hasAssistant = msgs.some((m: { role?: string }) => m?.role === "assistant");
		if (!hasAssistant) {
			last = { tool_sigs: {} };
			return;
		}
		for (let i = msgs.length - 1; i >= 0; i--) {
			const m = msgs[i];
			if (m?.role !== "assistant") continue;
			if (last.id && !m.id) m.id = last.id;
			if (last.thought_signature && !m.thought_signature) m.thought_signature = last.thought_signature;
			if (last.extra_content && !m.extra_content) m.extra_content = last.extra_content;
			if (Array.isArray(m.tool_calls)) {
				for (const tc of m.tool_calls) {
					const sig = (tc.id && last.tool_sigs[tc.id]) || last.thought_signature;
					if (sig && !tc.thought_signature) tc.thought_signature = sig;
				}
			}
			break;
		}
		return payload;
	});
}
