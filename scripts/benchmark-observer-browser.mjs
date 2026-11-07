import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
if (!process.argv[2]) throw Error('Usage: node scripts/benchmark-observer-browser.mjs RECORDING_DIRECTORY');
const root = resolve(process.argv[2]);
const runs = JSON.parse(await readFile(`${root}/encoding-results.json`, 'utf8'));
const code = await readFile(new URL('../Sources/TerminalObserver/Web/observer.js', import.meta.url), 'utf8');
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const percentile = (values, fraction) => [...values].sort((a, b) => a - b)[Math.min(values.length - 1, Math.floor(values.length * fraction))] || 0;
const results = [];
try {
  for (const viewport of [{ width: 1280, height: 900 }, { width: 390, height: 844 }]) {
    const context = await browser.newContext({ viewport });
    const page = await context.newPage();
    await page.route('http://observer.test/**', async (route) => {
      const path = new URL(route.request().url()).pathname;
      if (path === '/observer.js') return route.fulfill({ contentType: 'text/javascript', body: code });
      if (path === '/') return route.fulfill({ contentType: 'text/html', body: '<canvas id="benchmark"></canvas>' });
      const file = resolve(root, `.${path}`);
      if (!file.startsWith(`${root}/`)) return route.abort();
      return route.fulfill({ contentType: 'application/octet-stream', body: await readFile(file) });
    });
    await page.goto('http://observer.test/');
    const session = await context.newCDPSession(page);
    const cpuRate = viewport.width === 390 ? 4 : 1;
    await session.send('Emulation.setCPUThrottlingRate', { rate: cpuRate });
    for (const run of runs) {
      const measured = await page.evaluate(async ({ messages }) => {
        const { parseBatch, drawBatch } = await import('/observer.js');
        const canvas = document.getElementById('benchmark');
        const timings = [];
        for (const [index, message] of messages.entries()) {
          const buffer = await (await fetch(`/${message.file}`)).arrayBuffer();
          const start = performance.now(), batch = parseBatch(buffer), parsed = performance.now();
          await drawBatch(batch, canvas);
          timings.push({ parseMS: parsed - start, drawMS: performance.now() - parsed,
            totalMS: performance.now() - start, blocks: batch.header.blocks.length, first: index === 0 });
        }
        const pixels = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
        // Fingerprint the final canvas to compare all tile/pacing variants.
        let hash = 2166136261;
        for (const value of pixels) hash = Math.imul(hash ^ value, 16777619) >>> 0;
        return { timings, hash, width: canvas.width, height: canvas.height,
          nonblank: pixels.some((value, i) => i % 4 !== 3 && value !== pixels[i % 4]) };
      }, run);
      assert.ok(measured.nonblank);
      const reference = results.find((row) => row.viewport === viewport.width);
      if (reference) assert.equal(measured.hash, reference.hash, `Final pixel mismatch: ${run.name}`);
      const steady = measured.timings.filter((t) => !t.first);
      const result = { name: run.name, viewport: viewport.width, cpuRate, hash: measured.hash,
        kbps: run.steadyKBps, batches: run.messages.length,
        full: run.messages.filter((m) => m.type === 'full').length,
        blocksP95: percentile(steady.map((t) => t.blocks), 0.95),
        encodeP95MS: percentile(run.messages.slice(1).map((m) => m.encodeMS), 0.95),
        parseP95MS: percentile(steady.map((t) => t.parseMS), 0.95),
        drawP95MS: percentile(steady.map((t) => t.drawMS), 0.95),
        totalP95MS: percentile(steady.map((t) => t.totalMS), 0.95) };
      results.push(result); console.log(JSON.stringify(result));
    }
    await page.screenshot({ path: `${root}/replay-${viewport.width}.png` });
    await context.close();
  }
  await writeFile(`${root}/browser-results.json`, JSON.stringify(results, null, 2));
} finally { await browser.close(); }
