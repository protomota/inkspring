// Regenerate shipped logo images from the editable SVG, retaining each asset's layout.
// Run from the desktop repo: node build/generate-brand-assets.mjs
// Render on Expand, then copy the small shipped assets into their source locations.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { execFileSync } from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = '/Volumes/Expand/Codex Media/inkspring/brand-assets';
await fs.access('/Volumes/Expand');
await fs.mkdir(output, { recursive: true });
const master = await fs.readFile(path.join(root, 'public/inkspring-mark.svg'), 'utf8');
const paths = [...master.matchAll(/<path[^>]*d="([^"]+)"/g)].map(match => `<path d="${match[1]}"/>`).join('');
const circle = master.match(/<circle[^>]*cx="([^"]+)"[^>]*cy="([^"]+)"[^>]*r="([^"]+)"/);
if (paths.length === 0 || !circle) throw new Error('The master must contain the ink drops and a circle.');
const [centerX, centerY, radius] = circle.slice(1, 4).map(Number);

function mark([x, y, width, height], color) {
  const sx = width / 1808;
  const sy = height / 1789;
  // Keep the dot circular even in the older, slightly taller bitmap layouts.
  return `<g fill="${color}"><g transform="translate(${x} ${y}) scale(${sx} ${sy}) translate(-1102 -1124)"><g transform="translate(0 4000) scale(1 -1)">${paths}</g></g><circle cx="${x + (centerX - 1102) * sx}" cy="${y + (4000 - centerY - 1124) * sy}" r="${radius * Math.sqrt(sx * sy)}"/></g>`;
}

const paper = '#F5F2EC';
const accent = '#C4613C';
const variants = [
  ['website/public/social-card.png', 1024, 1024, [154, 158, 716, 708], accent, paper, 0],
  ['website/public/inkspring-logo.png', 992, 1072, [176, 200, 644, 688], '#000000', 'transparent', 0],
  ['website/public/inkspring-logo-white.png', 992, 1072, [176, 200, 644, 688], '#FFFFFF', 'transparent', 0],
  ['website/public/inkspring-logo-cyan.png', 992, 1072, [176, 200, 644, 688], '#22D3EE', 'transparent', 0],
  ['website/public/inkspring-logo-flat.png', 992, 1072, [176, 200, 644, 688], '#22D3EE', '#030712', 0],
  ['website/public/inkspring-logo-styled.png', 400, 400, [110, 112, 182, 180], '#FFFFFF', 'gradient', 48],
  ['website/public/inkspring-logo-black-on-gradient.png', 400, 400, [110, 112, 182, 180], '#111116', 'gradient', 48],
  ['website/public/inkspring-icon-black-gradient.png', 512, 512, [40, 56, 435, 432], '#111116', 'gradient', 80],
  ['website/public/apple-touch-icon.png', 180, 180, [14.0625, 19.6875, 152.9297, 151.875], '#111116', 'gradient', 28.125],
];
for (const size of [16, 32, 128, 256, 512]) {
  for (const retina of [false, true]) {
    const pixels = size * (retina ? 2 : 1);
    variants.push([`build/icon.iconset/icon_${size}x${size}${retina ? '@2x' : ''}.png`, pixels, pixels,
      [154, 158, 716, 708].map(value => value * pixels / 1024), accent, paper, 0]);
  }
}

const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  for (const [file, width, height, box, color, background, rounding] of variants) {
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
    const fill = background === 'gradient' ? 'url(#background)' : background === 'transparent' ? 'none' : background;
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}"><defs><linearGradient id="background" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#22D3EE"/><stop offset="1" stop-color="#A855F7"/></linearGradient></defs><rect width="${width}" height="${height}" rx="${rounding}" fill="${fill}"/>${mark(box, color)}</svg>`;
    await page.setContent(`<style>html,body{margin:0;background:transparent}svg{display:block}</style>${svg}`);
    const target = path.join(output, file);
    await fs.mkdir(path.dirname(target), { recursive: true });
    await page.screenshot({ path: target, omitBackground: true, scale: 'css' });
    // These small shipped assets belong in git; only large transient output stays on Expand.
    await fs.copyFile(target, path.join(root, file));
    await page.close();
  }
} finally {
  await browser.close();
}
execFileSync('/usr/bin/iconutil', ['-c', 'icns', path.join(output, 'build/icon.iconset'), '-o', path.join(output, 'build/icon.icns')]);
await fs.copyFile(path.join(output, 'build/icon.icns'), path.join(root, 'build/icon.icns'));
console.log(`Rendered ${variants.length} logo/icon images and the macOS icon from the circular-dot SVG.`);
