import {test,expect} from "@playwright/test";
import {mkdir,writeFile,unlink} from "node:fs/promises";
import {randomBytes} from "node:crypto";
import {homedir} from "node:os";
import path from "node:path";

const ids:string[]=[];
const root=path.join(homedir(),".graff","views");
/** What the model would hand `render_html`: one self-contained page that tries
 *  all three things a page is not allowed to do from this fixture — load from
 *  the network, reach the app's DOM, and run its own inline script (which it
 *  IS allowed to do, so the check can tell "contained" from "not rendered"). */
const drawn=`<!doctype html><meta charset="utf-8"><style>h1{color:#059669}</style><h1>Revision burn-down</h1>
<p id="script"></p><p id="fetch"></p><p id="escape"></p>
<script>
document.querySelector('#script').textContent='inline script ran';
fetch('https://blocked.example/leak').then(r=>{document.querySelector('#fetch').textContent='network reached '+r.status}).catch(()=>{document.querySelector('#fetch').textContent='fetch blocked'});
try{top.document.body.innerHTML='escaped';document.querySelector('#escape').textContent='escaped'}catch(e){document.querySelector('#escape').textContent='isolated'}
</script>`;
async function snapshot(html:string){
  const id=randomBytes(16).toString('hex');
  await mkdir(root,{recursive:true});
  await writeFile(path.join(root,`${id}.html`),html,{mode:0o600});
  ids.push(id);return id;
}
test.afterAll(async()=>{await Promise.all(ids.map(id=>unlink(path.join(root,`${id}.html`))));});

test('a model-drawn page renders inline in a sandbox that cannot reach the app or the network',async({page})=>{
  let leaks=0;
  await page.route('https://blocked.example/**',route=>{leaks++;return route.abort();});
  const id=await snapshot(drawn);
  await page.goto(`/visual-tests/views?id=${id}`);
  await expect(page.locator('section[aria-label="Rendered view"]')).toBeVisible();
  const app=page.frameLocator('iframe');
  // Rendered, with its own inline script and style — a page, not a screenshot.
  await expect(app.locator('h1')).toHaveText('Revision burn-down');
  await expect(app.locator('#script')).toHaveText('inline script ran');
  // The two things the policy exists for.
  await expect(app.locator('#fetch')).toHaveText('fetch blocked',{timeout:15000});
  await expect(app.locator('#escape')).toHaveText('isolated');
  expect(leaks).toBe(0);
  await expect(page.locator('h1')).toHaveText('Simulated rendered view');
  await page.screenshot({path:'/tmp/codegraff-rendered-view.png'});
  // Closing disposes the frame; reopening restores a live one.
  await page.getByRole('button',{name:'Close view'}).click();
  await expect(page.locator('iframe')).toHaveCount(0);
  await page.getByRole('button',{name:'Open view',exact:true}).click();
  await expect(app.locator('#script')).toHaveText('inline script ran');
  // Scrolling a long transcript releases script work, then restores the view.
  await page.evaluate(() => { document.body.style.paddingBottom = '2200px'; window.scrollTo(0, 2000); });
  await expect(page.locator('iframe')).toHaveCount(0);
  await page.evaluate(() => window.scrollTo(0, 0));
  await expect(app.locator('#script')).toHaveText('inline script ran');
});

test('the view route serves untrusted markup under a containing policy',async({page,request})=>{
  const id=await snapshot(drawn);
  const response=await request.get(`/api/views?id=${id}`);
  expect(response.status()).toBe(200);
  const headers=response.headers();
  expect(headers['content-security-policy']).toContain("sandbox allow-scripts");
  expect(headers['content-security-policy']).toContain("default-src 'none'");
  expect(headers['content-security-policy']).toContain("connect-src 'none'");
  expect(headers['content-security-policy']).toContain("frame-ancestors 'self'");
  expect(headers['x-content-type-options']).toBe('nosniff');
  // Only opaque ids we wrote, and only from our own origin.
  expect((await request.get('/api/views?id=../secret')).status()).toBe(400);
  expect((await request.get(`/api/views?id=${'f'.repeat(32)}`)).status()).toBe(404);
  expect((await request.get(`/api/views?id=${id}`,{headers:{Origin:'https://evil.example'}})).status()).toBe(403);
  // A page whose own markup asks for the app's APIs still gets a blank origin.
  await page.goto(`/visual-tests/views?id=${id}`);
  await expect(page.frameLocator('iframe').locator('#script')).toHaveText('inline script ran');
  await expect(page.locator('iframe')).toHaveCount(1);
});
