import { checkBearer, takeExtensionPins } from "@/lib/extension-bridge";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Drain the pins the user made in their own tabs. The pane polls this
 * (same origin, desktop header attached by Electron / no gate in dev, so
 * no Bearer needed); the prompt runner spends them with
 * `source: "extension"` on send. */
export async function GET() {
  const pins = takeExtensionPins().map((p) => ({ ...p, source: "extension" as const }));
  return Response.json({ pins });
}
