const fs = require('node:fs');
const path = require('node:path');
const ui = process.argv[2];
if (!ui) throw Error('Provide the bundled UI directory.');
const server = path.join(ui, 'server.js');
let source = fs.readFileSync(server, 'utf8');
source = source.replace(/const nextConfig = (.+)\n/, (_line, raw) => {
  const config = JSON.parse(raw);
  config.outputFileTracingRoot = '.';
  if (config.experimental?.turbopack) config.experimental.turbopack.root = '.';
  if (config.turbopack) config.turbopack.root = '.';
  if ('repoRoot' in config) config.repoRoot = '.';
  return `const nextConfig = ${JSON.stringify(config)}\n`;
});
fs.writeFileSync(server, source);
function stripMaps(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) stripMaps(file);
    else if (entry.name.endsWith('.map')) fs.unlinkSync(file);
  }
}
stripMaps(ui);
