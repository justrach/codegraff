/** Only the local UI can call extension controls without the pairing bearer. */
export function sameOriginUiRequest(req: Pick<Request, "method" | "url" | "headers">): boolean {
  if (req.headers.get("sec-fetch-site") !== "same-origin") return false;
  const origin = req.headers.get("origin");
  const expected = new URL(req.url).origin;
  return req.method === "GET" ? !origin || origin === expected : origin === expected;
}
