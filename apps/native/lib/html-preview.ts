// Static HTML result renderer: no scripts, external resources, forms or navigation.
const tags = new Set('style article section header footer main nav div span p h1 h2 h3 h4 h5 h6 ul ol li strong em b i small code pre br hr details summary table thead tbody tfoot tr th td caption figure figcaption blockquote'.split(' '));
const attrs = new Set(['class', 'style', 'title', 'open', 'colspan', 'rowspan']);
export function previewDocument(source: string): string {
  if (source.length > 262144) throw Error('Preview is too large');
  // A template is inert: source resources never enter the host's live document.
  if ((source.match(/</g)?.length ?? 0) > 8000) throw Error('HTML has too many tags');
  const template = document.createElement('template');
  template.innerHTML = source;
  let nodes = 0;
  const clean = (parent: DocumentFragment | Element, depth = 0) => {
    if (depth > 64) throw Error('HTML nesting is too deep');
    for (const child of Array.from(parent.children)) {
      if (++nodes > 4000) throw Error('HTML has too many elements');
      if (!tags.has(child.localName) || child.namespaceURI !== 'http://www.w3.org/1999/xhtml') { child.remove(); continue; }
      for (const attr of Array.from(child.attributes)) if (!attrs.has(attr.name)) child.removeAttribute(attr.name);
      clean(child, depth + 1);
    }
  };
  clean(template.content);
  const csp = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src 'none'; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";
  return `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${csp}"><meta name="referrer" content="no-referrer"><style>html{color-scheme:light}body{margin:0}*{box-sizing:border-box}@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}</style></head><body>${template.innerHTML}</body></html>`;
}
