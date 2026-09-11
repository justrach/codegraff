export const sampleHtml = `<style>
body{font:14px/1.55 system-ui,sans-serif;color:#253b32;background:#f5f8f4;padding:30px}
.eyebrow{font-size:10px;letter-spacing:1.8px;font-weight:700;color:#52745e;text-transform:uppercase}
h1{font-size:29px;line-height:1.15;letter-spacing:-1px;margin:12px 0 10px;font-weight:600}
.intro{color:#647368;max-width:500px;margin:0 0 25px}
.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}
.card{background:#fff;border:1px solid #dae4d8;border-radius:14px;padding:17px}
.number{color:#739077;font-size:11px}h2{font-size:15px;margin:9px 0 7px}.card p{color:#69766d;font-size:12px;margin:0}
.pill{display:inline-block;padding:4px 8px;border-radius:6px;background:#edf4e9;color:#4d6c48;font-size:10px;margin-top:15px}
details{margin-top:20px;border-top:1px solid #d6e1d3;padding-top:16px}summary{cursor:pointer;font-weight:550;font-size:13px}details p{font-size:12px;color:#647368;margin-bottom:0}
@media(max-width:520px){body{padding:20px}.grid{grid-template-columns:1fr}h1{font-size:25px}}
</style>
<div class="eyebrow">A visual explanation</div>
<h1>Where the memory goes.</h1>
<p class="intro">Three parts of the app do different jobs. Each can release work when you no longer need it.</p>
<div class="grid">
  <article class="card"><span class="number">01 / RENDER</span><h2>Your conversation</h2><p>Text, highlighted code and the panes you're reading.</p><span class="pill">Render on demand</span></article>
  <article class="card"><span class="number">02 / BROWSE</span><h2>Embedded pages</h2><p>Each live page has its own document and scripts.</p><span class="pill">Suspend idle views</span></article>
  <article class="card"><span class="number">03 / WORK</span><h2>The Graff engine</h2><p>Active tools and agent work run alongside the interface.</p><span class="pill">Clean up finished work</span></article>
</div>
<details><summary>What happens when I close a tab?</summary><p>The view can release its document and listeners. Saved conversation history remains on disk, ready to open again. Memory release may take time as the runtime reuses allocations.</p></details>`;
