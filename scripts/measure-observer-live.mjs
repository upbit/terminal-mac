import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdir, writeFile } from 'node:fs/promises';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { resolve } from 'node:path';

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const binary = resolve('dist/terminal-mac'), machine = process.argv[2] || 'default';
const output = process.argv[3] || '/private/tmp/observer-budget/live';
const seconds = Number(process.env.OBSERVER_MEASURE_SECONDS || 15);
const motion = process.env.OBSERVER_MEASURE_MOTION === '1';
const run = promisify(execFile);
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const results = [];
const cases = motion ? [
  ['cursor-show', ['--low-bandwidth']], ['cursor-hide', ['--low-bandwidth', '--hide-cursor']]
] : [
  ['standard', []], ['low', ['--low-bandwidth', '--hide-cursor']]
];
try {
  for (const [name, args] of cases) {
    const server = spawn(binary, ['observe', machine, ...args], { stdio: ['ignore', 'pipe', 'pipe'] });
    let log = '', url;
    const exited = new Promise((resolve) => server.once('exit', resolve));
    const ready = new Promise((resolve, reject) => {
      server.on('error', reject);
      server.stdout.on('data', (data) => {
        log += data; const match = log.match(/Observer: (http:\/\/127\.0\.0\.1:\d+\/)/);
        if (match) { url = match[1]; resolve(); }
      });
      server.stderr.on('data', (data) => { log += data; });
      server.once('exit', (code) => reject(Error(`Observer exited ${code}: ${log}`)));
    });
    let context;
    try {
      await ready;
      context = await browser.newContext({ viewport: { width: 390, height: 844 } });
      await context.addInitScript(() => {
        window.__measure = { bytes: 0, messages: [], draws: [], errors: [], welcome: null };
        const Original = WebSocket, pending = new Map();
        window.WebSocket = class extends Original {
          constructor(...args) {
            super(...args);
            this.addEventListener('message', (event) => {
              const stats = window.__measure;
              stats.bytes += typeof event.data === 'string' ? new TextEncoder().encode(event.data).length : event.data.byteLength;
              if (typeof event.data === 'string') {
                const message = JSON.parse(event.data);
                if (message.type === 'welcome') stats.welcome = message;
                if (message.type === 'error') stats.errors.push(message.message);
              } else {
                const view = new DataView(event.data), size = view.getUint32(8);
                const h = JSON.parse(new TextDecoder().decode(new Uint8Array(event.data, 12, size)));
                const time = performance.now(); pending.set(`${h.epoch}/${h.seq}`, time);
                stats.messages.push({ time, type: h.type, blocks: h.blocks.length, bytes: event.data.byteLength });
              }
            });
          }
          send(data) {
            const m = JSON.parse(data), key = `${m.epoch}/${m.seq}`;
            if (m.type === 'ack' && pending.has(key)) {
              window.__measure.draws.push({ time: performance.now(), ms: performance.now() - pending.get(key) });
              pending.delete(key);
            }
            super.send(data);
          }
        };
      });
      const page = await context.newPage(), errors = [];
      page.on('pageerror', (error) => errors.push(error.message));
      await page.goto(url);
      await page.waitForFunction(() => document.getElementById('empty').hidden || window.__measure.errors.length > 0, null, { timeout: 15000 });
      assert.deepEqual(await page.evaluate(() => window.__measure.errors), []);
      await page.waitForTimeout(2500);
      const start = await page.evaluate(() => ({ time: performance.now(), bytes: window.__measure.bytes }));
      if (motion) {
        for (let n = 0; n < seconds * 5; n++) {
          await run(binary, ['action', machine, 'move', String(200 + (n * 37) % 600), String(150 + (n * 23) % 350)]);
          await page.waitForTimeout(160);
        }
      } else await page.waitForTimeout(seconds * 1000);
      const stats = await page.evaluate(() => ({ ...window.__measure, now: performance.now() }));
      const duration = (stats.now - start.time) / 1000;
      const samples = stats.messages.filter((m) => m.time >= start.time);
      const draws = stats.draws.filter((m) => m.time >= start.time).map((m) => m.ms).sort((a, b) => a - b);
      const buckets = Array.from({ length: Math.floor(duration) }, (_, i) => samples.filter((m) =>
        m.time >= start.time + i * 1000 && m.time < start.time + (i + 1) * 1000).reduce((sum, m) => sum + m.bytes, 0) / 1000).sort((a, b) => a - b);
      const pixels = await page.evaluate(() => {
        const c = document.getElementById('mirror'), p = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
        return { width: c.width, height: c.height, nonblank: p.some((v, i) => i % 4 !== 3 && v !== p[i % 4]) };
      });
      assert.ok(pixels.nonblank); assert.deepEqual(stats.errors, []); assert.deepEqual(errors, []);
      const result = { name, motion, duration, welcome: stats.welcome, kbps: (stats.bytes - start.bytes) / duration / 1000,
        oneSecondP95KBps: buckets[Math.floor(buckets.length * 0.95)] || 0,
        fps: samples.length / duration, full: samples.filter((m) => m.type === 'full').length,
        delta: samples.filter((m) => m.type === 'delta').length, firstBytes: stats.messages[0]?.bytes,
        receiptToAckP95MS: draws[Math.floor(draws.length * 0.95)] || 0, pixels };
      results.push(result); console.log(JSON.stringify(result, null, 2));
      await writeFile(`${output}/results.json`, JSON.stringify(results, null, 2));
      await page.screenshot({ path: `${output}/${name}.png`, fullPage: true });
    } finally {
      await context?.close();
      server.kill('SIGTERM'); await exited;
    }
  }
  await writeFile(`${output}/results.json`, JSON.stringify(results, null, 2));
} finally { await browser.close(); }
