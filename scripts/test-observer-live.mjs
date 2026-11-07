import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdir } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const run = promisify(execFile);
const url = process.argv[2] || 'http://127.0.0.1:33842/';
const name = process.argv[3] || 'default';
const output = process.env.OBSERVER_SCREENSHOTS || '/private/tmp/terminal-mac-observer-screenshots';
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  await context.addInitScript(() => {
    window.__live = { full: 0, delta: 0, bytes: 0, connections: 0, closed: 0, errors: [], samples: [] };
    const Original = window.WebSocket;
    window.WebSocket = class extends Original {
      constructor(...args) {
        super(...args); window.__live.connections++;
        this.addEventListener('close', () => window.__live.closed++);
        this.addEventListener('message', (event) => {
          if (typeof event.data === 'string') {
            const m = JSON.parse(event.data);
            if (m.type === 'error') window.__live.errors.push(m.message);
          } else if (event.data instanceof ArrayBuffer) {
            const view = new DataView(event.data), length = view.getUint32(8);
            const h = JSON.parse(new TextDecoder().decode(new Uint8Array(event.data, 12, length)));
            window.__live[h.type]++; window.__live.bytes += event.data.byteLength;
            window.__live.samples.push({ time: performance.now(), type: h.type, blocks: h.blocks.length, bytes: event.data.byteLength });
          }
        });
      }
    };
  });
  const page = await context.newPage(), errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto(url);
  await page.waitForFunction(() => document.getElementById('empty').hidden, null, { timeout: 20000 });
  const start = await page.evaluate(() => performance.now());
  // Guest cursor movement only; no user files, text input, or lifecycle changes.
  for (let n = 0; n < 40; n++) {
    await run('./dist/terminal-mac', ['action', name, 'move', String(20 + (n * 97) % 1240), String(20 + (n * 53) % 760)]);
    await page.waitForTimeout(100);
  }
  await page.waitForTimeout(1500);
  const afterMotion = await page.evaluate(() => structuredClone(window.__live));
  assert.equal(afterMotion.connections, 1, 'Continuous updates unexpectedly reconnected');
  assert.equal(afterMotion.closed, 0); assert.deepEqual(afterMotion.errors, []);
  assert.ok(afterMotion.delta > 1);
  await page.screenshot({ path: `${output}/live-desktop.png`, fullPage: true });
  const canvas = await page.evaluate(() => {
    const c = document.getElementById('mirror'), pixels = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
    return { width: c.width, height: c.height, nonblank: pixels.some((value, i) => i % 4 !== 3 && value !== pixels[i % 4]) };
  });
  assert.deepEqual(canvas, { width: 640, height: 400, nonblank: true });
  const viewer = await run('python3', ['scripts/test-observer-viewer.py', name], { timeout: 12000 });
  assert.equal(JSON.parse(viewer.stdout).status, 'pass');
  assert.equal(await page.evaluate(() => document.getElementById('mirror').width), 640);
  assert.deepEqual(await page.evaluate(() => window.__live.errors), []);
  await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, value: true });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await page.waitForTimeout(1200);
  const paused = await page.evaluate(() => window.__live.full + window.__live.delta);
  await page.waitForTimeout(1200);
  assert.equal(await page.evaluate(() => window.__live.full + window.__live.delta), paused);
  await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, value: false });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await page.waitForFunction((count) => window.__live.full > count && document.getElementById('empty').hidden,
    afterMotion.full, { timeout: 5000 });
  for (let n = 0; n < 3; n++) {
    await page.reload();
    await page.waitForFunction(() => document.getElementById('empty').hidden, null, { timeout: 5000 });
    assert.deepEqual(await page.evaluate(() => window.__live.errors), []);
  }
  const other = await context.newPage(); await other.goto(url);
  await other.waitForFunction(() => document.getElementById('empty').hidden, null, { timeout: 5000 });
  await other.close();
  await page.waitForTimeout(1000);
  assert.deepEqual(await page.evaluate(() => window.__live.errors), []);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: `${output}/live-mobile.png`, fullPage: true });
  assert.equal(await page.locator('#error').textContent(), '');
  assert.deepEqual(errors, []);
  const samples = afterMotion.samples.filter((sample) => sample.time >= start);
  const duration = (afterMotion.samples.at(-1).time - start) / 1000;
  console.log(JSON.stringify({ status: 'pass', canvas, full: afterMotion.full, delta: afterMotion.delta,
    imageBytes: afterMotion.bytes, motionObservedFps: Number((samples.length / duration).toFixed(1)),
    largestOneSecondBatchCount: Math.max(...samples.map((sample) => samples.filter((other) => other.time >= sample.time && other.time < sample.time + 1000).length)),
    pauseResume: 'pass', reloads: 3, tabs: 2, viewer: JSON.parse(viewer.stdout), screenshots: output }, null, 2));
  await context.close();
} finally { await browser.close(); }
