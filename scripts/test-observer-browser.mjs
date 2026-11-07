import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdir } from 'node:fs/promises';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const url = process.argv[2] || 'http://127.0.0.1:33841/';
const output = process.env.OBSERVER_SCREENSHOTS || '/private/tmp/terminal-mac-observer-screenshots';
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  await context.addInitScript(() => {
    window.__observerStats = { full: 0, delta: 0, bytes: 0 };
    window.__observerAcks = [];
    const Original = window.WebSocket;
    window.WebSocket = class extends Original {
      constructor(...args) {
        super(...args);
        this.addEventListener('message', (event) => {
          if (event.data instanceof ArrayBuffer) {
            const view = new DataView(event.data), length = view.getUint32(8);
            const head = JSON.parse(new TextDecoder().decode(new Uint8Array(event.data, 12, length)));
            window.__observerStats[head.type]++; window.__observerStats.bytes += event.data.byteLength;
            if (window.__corruptNextImage) {
              window.__corruptNextImage = false;
              const copy = event.data.slice(0), bytes = new Uint8Array(copy);
              const start = 12 + length + head.blocks[0].offset;
              bytes.fill(0, start + 33, start + head.blocks[0].length);
              window.__corruptedImage = { epoch: head.epoch, seq: head.seq };
              Object.defineProperty(event, 'data', { value: copy });
            }
          }
        });
      }
      send(data) {
        const message = JSON.parse(data);
        if (message.type === 'ack') window.__observerAcks.push(message);
        super.send(data);
      }
    };
  });
  const page = await context.newPage(), errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.goto(url);
  await page.waitForFunction(() => document.getElementById('empty').hidden);
  await page.waitForFunction(() => window.__observerStats.delta >= 2);
  const oracle = async () => page.evaluate(() => {
    const canvas = document.getElementById('mirror'), pixels = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
    let mismatches = 0;
    const value = pixels[0];
    for (let y = 0; y < 400; y++) for (let x = 0; x < 640; x++) {
      const i = (y * 640 + x) * 4, changed = (x < 32 && y < 32) || (x >= 512 && y >= 384);
      if (pixels[i] !== (changed ? value : 240) || pixels[i + 1] !== (changed ? 32 : 245) ||
          pixels[i + 2] !== (changed ? 64 : 250) || pixels[i + 3] !== 255) mismatches++;
    }
    return { mismatches, width: canvas.width, height: canvas.height, stats: window.__observerStats };
  });
  for (let i = 0; i < 12; i++) { assert.equal((await oracle()).mismatches, 0); await page.waitForTimeout(250); }
  await page.screenshot({ path: `${output}/desktop.png`, fullPage: true });
  assert.equal(await page.locator('#error').textContent(), '');
  const other = await context.newPage(); await other.goto(url);
  await other.waitForFunction(() => document.getElementById('empty').hidden);
  assert.equal((await oracle()).mismatches, 0);
  await other.close();
  const fullBeforeCorruption = await page.evaluate(() => window.__observerStats.full);
  await page.evaluate(() => { window.__corruptNextImage = true; });
  await page.waitForFunction(() => !!window.__corruptedImage);
  await page.waitForFunction((count) => window.__observerStats.full > count && document.getElementById('error').textContent === '' &&
    document.getElementById('empty').hidden, fullBeforeCorruption);
  assert.equal(await page.evaluate(() => window.__observerAcks.some((ack) => ack.epoch === window.__corruptedImage.epoch &&
    ack.seq === window.__corruptedImage.seq)), false);
  assert.equal((await oracle()).mismatches, 0);
  await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, value: true });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await page.waitForTimeout(300);
  const paused = await page.evaluate(() => ({ ...window.__observerStats }));
  await page.waitForTimeout(1200);
  assert.deepEqual(await page.evaluate(() => window.__observerStats), paused);
  await page.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, value: false });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await page.waitForFunction((count) => window.__observerStats.full > count, paused.full);
  await page.waitForFunction(() => document.getElementById('empty').hidden && document.getElementById('error').textContent === '');
  assert.equal((await oracle()).mismatches, 0);
  await page.reload(); await page.waitForFunction(() => document.getElementById('empty').hidden);
  assert.equal((await oracle()).mismatches, 0);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: `${output}/mobile.png`, fullPage: true });
  const layout = await page.evaluate(() => {
    const elements = [...document.querySelectorAll('header, .mirror, aside, dd, pre')];
    return { width: document.documentElement.scrollWidth, viewport: innerWidth,
      overflow: elements.some((element) => element.scrollWidth > element.clientWidth + 1) };
  });
  assert.ok(layout.width <= layout.viewport); assert.equal(layout.overflow, false);
  assert.deepEqual(errors, []);
  console.log(JSON.stringify({ status: 'pass', oracle: await oracle(), layout, screenshots: output }, null, 2));
  await context.close();
} finally { await browser.close(); }
