// Render the tracked vector at every native icon size; never reuse a stale app.
const sharp = require('sharp');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

async function main() {
  const output = process.argv[2];
  if (!output) throw new Error('Provide the output .icns path.');
  const source = path.join(__dirname, '../desktop/icon.svg');
  const work = await fs.mkdtemp(path.join(os.tmpdir(), 'graff-icon-'));
  const iconset = path.join(work, 'Codegraff.iconset');
  try {
    await fs.mkdir(iconset);
    for (const size of [16, 32, 128, 256, 512]) {
      for (const scale of [1, 2]) {
        await sharp(source).resize(size * scale, size * scale).png().toFile(
          path.join(iconset, `icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`));
      }
    }
    execFileSync('iconutil', ['-c', 'icns', iconset, '-o', path.resolve(output)]);
  } finally {
    await fs.rm(work, { recursive: true, force: true });
  }
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
