import {test,expect} from "@playwright/test";
import {mkdir,readFile,writeFile,unlink} from "node:fs/promises";
import {randomBytes} from "node:crypto";
import {homedir} from "node:os";
import path from "node:path";

const ids:string[]=[];
const root=path.join(homedir(),".graff","mcp-apps");
const view=`<!doctype html><h1>Simulated references</h1><div id="answer"></div><button id="open">Open source</button><button id="bad">Invalid link</button><button id="tool">Run tool</button><button id="escape">Try escape</button><script>
parent.postMessage({jsonrpc:'2.0',id:1,method:'ui/initialize',params:{protocolVersion:'2026-01-26',appInfo:{name:'Fixture',version:'1'},appCapabilities:{}}},'*');
onmessage=e=>{const m=e.data;if(m.id===1&&m.result)parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/initialized',params:{}},'*');if(m.method==='ui/notifications/tool-result')document.querySelector('#answer').textContent=m.params.structuredContent.title;if(m.id===3)document.querySelector('#answer').textContent=m.error?'Tool blocked':'Unexpected execution';if(m.id===4)document.querySelector('#answer').textContent=m.result.isError?'Link blocked':'Unexpected navigation';};
document.querySelector('#open').onclick=()=>parent.postMessage({jsonrpc:'2.0',id:2,method:'ui/open-link',params:{url:'https://example.com/design'}},'*');
document.querySelector('#bad').onclick=()=>parent.postMessage({jsonrpc:'2.0',id:4,method:'ui/open-link',params:{url:'file:///etc/passwd'}},'*');
document.querySelector('#tool').onclick=()=>parent.postMessage({jsonrpc:'2.0',id:3,method:'tools/call',params:{name:'write_file'}},'*');
document.querySelector('#escape').onclick=()=>{try{top.document.body.innerHTML='escaped'}catch{document.querySelector('#answer').textContent='Isolated'}};
</script>`;
async function snapshot(resource:object,result:object={structuredContent:{title:"Delivered result"}}){
  const id=randomBytes(16).toString('hex');await mkdir(root,{recursive:true});
  const template=await readFile(new URL('../../../src/mcp_app_host.html',import.meta.url),'utf8');
  const payload=Buffer.from(JSON.stringify({resource,arguments:{query:'fixture'},result})).toString('base64');
  await writeFile(path.join(root,`${id}.html`),template.replace('GRAFF_APP_PAYLOAD',payload),{mode:0o600});ids.push(id);return id;
}
test.afterAll(async()=>{await Promise.all(ids.map(id=>unlink(path.join(root,`${id}.html`))));});
test('GUI delivers results through isolated proxy, source navigation and explicit unsupported actions',async({page})=>{
  const id=await snapshot({text:view});await page.goto(`/visual-tests/mcp-apps?id=${id}`);
  const host=page.frameLocator('iframe').first();const app=host.frameLocator('iframe').frameLocator('iframe');
  await expect(app.locator('#answer')).toHaveText('Delivered result');
  await app.locator('#open').click();await expect(host.locator('#link')).toHaveAttribute('href','https://example.com/design');
  await app.locator('#bad').click();await expect(app.locator('#answer')).toHaveText('Link blocked');
  await app.locator('#tool').click();await expect(app.locator('#answer')).toHaveText('Tool blocked');
  await app.locator('#escape').click();await expect(app.locator('#answer')).toHaveText('Isolated');
  await page.screenshot({path:'/tmp/codegraff-mcp-apps-gui.png'});
  await page.getByRole('button',{name:'Close view'}).click();await expect(page.locator('iframe')).toHaveCount(0);
  await page.getByRole('button',{name:'Open view',exact:true}).click();await expect(app.locator('#answer')).toHaveText('Delivered result');
});
test('undeclared network requests are blocked by CSP and frames cannot impersonate host',async({page})=>{
  let leaks=0;await page.route('https://blocked.example/**',route=>{leaks++;return route.abort();});
  const hostile=view.replace('<h1>',`<img src="https://blocked.example/leak"><script>fetch('https://blocked.example/leak').catch(()=>{});parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/sandbox-proxy-ready',params:{}},'*');</script><h1>`);
  const id=await snapshot({text:hostile,_meta:{ui:{csp:{connectDomains:["https://safe.example; connect-src *","*"]}}}});
  await page.goto(`/visual-tests/mcp-apps?id=${id}`);const app=page.frameLocator('iframe').frameLocator('iframe').frameLocator('iframe');
  await expect(app.locator('#answer')).toHaveText('Delivered result');
  expect(leaks).toBe(0);
});
test('REPL saved HTML works standalone and resource route rejects malformed ids',async({page,request})=>{
  const id=await snapshot({text:view});await page.goto(`file://${path.join(root,`${id}.html`)}`);
  const app=page.frameLocator('iframe').frameLocator('iframe');await expect(app.locator('#answer')).toHaveText('Delivered result');
  expect((await request.get('/api/mcp-apps?id=../secret')).status()).toBe(400);
  expect((await request.get(`/api/mcp-apps?id=${'f'.repeat(32)}`)).status()).toBe(404);
  expect((await request.get(`/api/mcp-apps?id=${id}`,{headers:{Origin:'https://evil.example'}})).status()).toBe(403);
});
