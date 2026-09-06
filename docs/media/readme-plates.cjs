const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const uri = file => `data:${file.endsWith('.woff2') ? 'font/woff2' : file.endsWith('.png') ? 'image/png' : 'image/jpeg'};base64,${fs.readFileSync(file).toString('base64')}`;
const art = name => uri(path.join(__dirname, 'art', `workshop-${name}.jpg`));
const shot = name => uri(path.join(root, 'docs/images', `desktop-${name}.png`));
const grain = `<svg xmlns="http://www.w3.org/2000/svg" width="180" height="180"><filter id="n"><feTurbulence type="fractalNoise" baseFrequency=".75" numOctaves="3" stitchTiles="stitch"/></filter><rect width="100%" height="100%" opacity=".3" filter="url(#n)"/></svg>`;
const mark = `<svg viewBox="0 0 32 32" fill="none"><path d="M26 8a13 13 0 1 0 1 15" stroke="currentColor" stroke-width="3" stroke-linecap="round"/><path d="m12 12-4 4 4 4m9-8 4 4-4 4m-3-10-3 12" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>`;
function fonts() {
  const dir = process.env.GRAFF_DESIGN_FONTS;
  if (!dir) return '';
  return [['Display', 'SinarGrotesk-SemiBold.woff2'], ['Body', 'Gramatika-Regular.woff2']].map(([name, file]) => `@font-face{font-family:${name};src:url('${uri(path.join(dir, file))}')} `).join('');
}
function page(body, theme = '') {
  return `<!doctype html><html><head><meta charset="utf-8"><style>${fonts()}${fs.readFileSync(path.join(__dirname, 'readme-plates.css'), 'utf8')} .grain{background-image:url('data:image/svg+xml;base64,${Buffer.from(grain).toString('base64')}')}</style></head><body><main class="${theme}"><div class="grain"></div>${body}</main></body></html>`;
}
const brand = (label = 'DESKTOP / MACOS') => `<div class="brand">${mark}<span>codegraff</span><small>${label}</small></div>`;
const windowFrame = (image, tone) => `<div class="window ${tone}"><div class="chrome"><div class="lights"><i></i><i></i><i></i></div><span>CodeGraff</span><b>●</b></div><img class="screenshot" src="${image}" /></div>`;
function screen({ id, title, note, label, file, artName, theme }) {
  return page(`${brand()}<header><div class="eyebrow">${id} / ${label}</div><h1>${title}</h1><p>${note}</p></header>
    <div class="art-stamp"><img src="${art(artName)}" /></div><div class="stage">${windowFrame(shot(file), theme === 'night' ? 'dark' : 'paper')}</div>
    <footer><span class="footer-label">${label}</span><span>Actual desktop UI · demonstration workspace</span><span class="edition">GRAFF / DESKTOP</span></footer>`, theme);
}
module.exports = [
  { name: 'readme-rats', width: 512, height: 512, html: () => page(`<img class="workshop-icon" src="${art('run')}" />`, 'square') },
  { name: 'desktop-chat-studio', width: 1920, height: 1530, html: () => screen({ id:'01', title:'A place to do the work.', note:'A clear conversation. Your tools close at hand.', label:'THE WORKSPACE', file:'chat-light', artName:'run', theme:'bright' }) },
  { name: 'desktop-agents-studio', width: 1920, height: 1530, html: () => screen({ id:'02', title:'Many hands. One workspace.', note:'See the crew. Share context. Pass the work along.', label:'AGENT COORDINATION', file:'agents-codegraff', artName:'agents', theme:'coral' }) },
  { name: 'desktop-review-studio', width: 1920, height: 1530, html: () => screen({ id:'03', title:'Room for a closer look.', note:'Keep the conversation beside the changes.', label:'CHANGES & REVIEW', file:'review-dark', artName:'review', theme:'night' }) },
  { name: 'readme-context-workshop', width:1920, height:920, html: () => page(`${brand('INSIDE THE HARNESS')}
    <div class="loop-art"><img src="${art('review')}" /></div><div class="loop-copy"><div class="eyebrow">HOW CONTEXT MOVES THROUGH GRAFF</div><h1>Context that stays useful.</h1><ol><li><b>01</b><div><strong>Reuse the setup</strong><p>Keep stable instructions ready for the next step.</p></div></li><li><b>02</b><div><strong>Work with the context</strong><p>Run small programs and coordinate tool calls.</p></div></li><li><b>03</b><div><strong>Carry the result forward</strong><p>Return the information the next step needs.</p></div></li></ol></div>
    <div class="hero-bottom">THE GRAFF WORKSHOP <span>CONTEXT → TOOLS → RESULTS</span></div>`, 'loop') },
];
