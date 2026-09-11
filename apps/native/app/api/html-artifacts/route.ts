import { readHtml, validId } from '@/electron/html-artifacts.cjs';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export async function GET(request: Request) {
  const url = new URL(request.url), origin = request.headers.get('origin');
  if (request.headers.get('sec-fetch-site') === 'cross-site' || (origin && origin !== url.origin))
    return new Response('Forbidden', { status: 403 });
  const id = url.searchParams.get('id');
  if (!validId(id)) return new Response('Invalid preview id', { status: 400 });
  try { return Response.json(await readHtml(id), { headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' } }); }
  catch { return new Response('This saved preview is no longer available.', { status: 404 }); }
}
