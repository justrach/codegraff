/** The browser is owned by the desktop bridge. Web requests must not launch a sidecar. */
export async function GET(): Promise<Response> {
  return new Response("Browser automation is available in the desktop app.", { status: 410 });
}

export async function POST(): Promise<Response> {
  return GET();
}
