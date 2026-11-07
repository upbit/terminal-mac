const MAX_PIXELS = 2073600;
const MAX_MESSAGE = 12 * 1024 * 1024;
const MAX_FPS = 30;

export class ObserverMeter {
  constructor(now, ceiling = MAX_FPS) { this.ceiling = ceiling; this.maxFps = 0; this.reset(now, 0, 0); }
  reset(now, bytes, frames) {
    this.time = now; this.bytes = bytes; this.frames = frames;
    return { fps: 0, maxFps: this.maxFps, kbps: 0 };
  }
  sample(now, bytes, frames) {
    const elapsed = now - this.time;
    if (elapsed <= 0) return { fps: 0, maxFps: this.maxFps, kbps: 0 };
    const fps = Math.min(this.ceiling, Math.max(0, frames - this.frames) * 1000 / elapsed);
    const kbps = Math.max(0, bytes - this.bytes) / elapsed;
    this.maxFps = Math.max(this.maxFps, fps);
    this.time = now; this.bytes = bytes; this.frames = frames;
    return { fps, maxFps: this.maxFps, kbps };
  }
}
const integer = (v, min, max) => Number.isSafeInteger(v) && v >= min && v <= max;
const sequence = (v) => typeof v === "string" && /^[1-9][0-9]{0,19}$/.test(v) && BigInt(v) <= 18446744073709551615n;
const uuid = (v) => typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const crcTable = Uint32Array.from({ length: 256 }, (_, value) => {
  for (let i = 0; i < 8; i++) value = (value & 1) ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});
function validatePNG(buffer, start, length, width, height) {
  const view = new DataView(buffer, start, length), bytes = new Uint8Array(buffer, start, length);
  if (view.getUint32(0) !== 0x89504e47 || view.getUint32(4) !== 0x0d0a1a0a || view.getUint32(8) !== 13 ||
      view.getUint32(12) !== 0x49484452 || view.getUint32(16) !== width || view.getUint32(20) !== height) throw Error("PNG dimensions do not match block");
  let offset = 8, chunks = 0, hasData = false, ended = false;
  while (offset + 12 <= length) {
    const size = view.getUint32(offset), type = view.getUint32(offset + 4);
    if (size > length - offset - 12 || ++chunks > 1024 || (offset !== 8 && type === 0x49484452)) throw Error("Invalid PNG chunks");
    let crc = 0xffffffff;
    for (let i = offset + 4; i < offset + 8 + size; i++) crc = crcTable[(crc ^ bytes[i]) & 255] ^ (crc >>> 8);
    if (((crc ^ 0xffffffff) >>> 0) !== view.getUint32(offset + 8 + size)) throw Error("PNG checksum mismatch");
    offset += size + 12;
    if (type === 0x49444154) hasData = true;
    if (type === 0x49454e44) {
      if (size !== 0 || offset !== length) throw Error("Invalid PNG end");
      ended = true; break;
    }
  }
  if (!hasData || !ended || offset !== length) throw Error("Incomplete PNG image");
}

export function parseBatch(buffer) {
  if (!(buffer instanceof ArrayBuffer) || buffer.byteLength < 12 || buffer.byteLength > MAX_MESSAGE) throw Error("Invalid image message size");
  const view = new DataView(buffer);
  if (view.getUint32(0) !== 0x544d4f42 || view.getUint16(4) !== 1 || view.getUint16(6) !== 0) throw Error("Invalid image protocol");
  const headerLength = view.getUint32(8);
  if (headerLength < 2 || headerLength > 65536 || 12 + headerLength > buffer.byteLength) throw Error("Invalid image header length");
  const header = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array(buffer, 12, headerLength)));
  const { type, epoch, seq, baseSeq, width, height, codec, blocks, tileSize = 128 } = header;
  if (!["full", "delta"].includes(type) || !uuid(epoch) || !sequence(seq) || codec !== "png" ||
      !integer(width, 2, 1920) || !integer(height, 2, 2160) || width * height > MAX_PIXELS ||
      ![64, 128].includes(tileSize) || !Array.isArray(blocks) || blocks.length < 1 || blocks.length > 256 ||
      (type === "full" ? baseSeq != null || blocks.length !== 1 : !sequence(baseSeq))) throw Error("Invalid image metadata");
  let expectedOffset = 0, pixels = 0, previousIndex = -1;
  const payloadStart = 12 + headerLength;
  for (const b of blocks) {
    if (!b || !integer(b.x, 0, width - 1) || !integer(b.y, 0, height - 1) || !integer(b.w, 1, width - b.x) ||
        !integer(b.h, 1, height - b.y) || b.offset !== expectedOffset || !integer(b.length, 33, MAX_MESSAGE) ||
        b.length > buffer.byteLength - payloadStart - b.offset) throw Error("Invalid PNG block bounds");
    if (type === "full") {
      if (b.x !== 0 || b.y !== 0 || b.w !== width || b.h !== height) throw Error("Incomplete full image");
    } else {
      const index = (b.y / tileSize) * Math.ceil(width / tileSize) + b.x / tileSize;
      if (b.x % tileSize || b.y % tileSize || b.w !== Math.min(tileSize, width - b.x) || b.h !== Math.min(tileSize, height - b.y) ||
          index <= previousIndex) throw Error("Invalid delta tile grid");
      previousIndex = index;
    }
    validatePNG(buffer, payloadStart + b.offset, b.length, b.w, b.h);
    expectedOffset += b.length; pixels += b.w * b.h;
  }
  if (payloadStart + expectedOffset !== buffer.byteLength || pixels > MAX_PIXELS) throw Error("Invalid image payload coverage");
  return { header, buffer, payloadStart };
}

async function decodePNG(blob) {
  if (typeof createImageBitmap === "function") {
    try { return await createImageBitmap(blob); } catch { /* Controlled Image fallback below. */ }
  }
  const url = URL.createObjectURL(blob);
  try {
    const image = new Image();
    await new Promise((resolve, reject) => { image.onload = resolve; image.onerror = () => reject(Error("PNG decode failed")); image.src = url; });
    return image;
  } finally { URL.revokeObjectURL(url); }
}

export async function drawBatch(batch, canvas, cancelled = () => false) {
  const { header: h, buffer, payloadStart } = batch, decoded = new Array(h.blocks.length);
  let next = 0;
  try {
    const workers = Array.from({ length: Math.min(4, h.blocks.length) }, async () => {
      while (next < h.blocks.length) {
        if (cancelled()) return;
        const i = next++, b = h.blocks[i];
        const blob = new Blob([new Uint8Array(buffer, payloadStart + b.offset, b.length)], { type: "image/png" });
        const image = await decodePNG(blob);
        decoded[i] = image;
        if ((image.width ?? image.naturalWidth) !== b.w || (image.height ?? image.naturalHeight) !== b.h) throw Error("Decoded PNG size mismatch");
      }
    });
    const results = await Promise.allSettled(workers);
    const failure = results.find((result) => result.status === "rejected");
    if (failure) throw failure.reason;
    if (cancelled()) return false;
    const stage = document.createElement("canvas"); stage.width = h.width; stage.height = h.height;
    const ctx = stage.getContext("2d", { alpha: false });
    if (!ctx) throw Error("Staging Canvas is unavailable");
    if (h.type === "delta") ctx.drawImage(canvas, 0, 0);
    h.blocks.forEach((b, i) => ctx.drawImage(decoded[i], b.x, b.y));
    if (canvas.width !== h.width || canvas.height !== h.height) { canvas.width = h.width; canvas.height = h.height; }
    const target = canvas.getContext("2d");
    if (!target || target.isContextLost?.()) throw Error("Canvas context is lost");
    target.drawImage(stage, 0, 0);
    return true;
  } finally { decoded.forEach((image) => image?.close?.()); }
}

if (typeof document !== "undefined" && document.getElementById("mirror")) {
  const canvas = document.getElementById("mirror"), empty = document.getElementById("empty");
  const lowSwitch = document.getElementById("low-bandwidth");
  let lowBandwidth = null, modeTimer;
  let socket, generation = 0, welcome = null, lastSeq = null, disposed = false;
  let bytes = 0, frames = 0, retry = 0, retryTimer, queue = Promise.resolve(), queued = 0;
  let health = "warning";
  const meter = new ObserverMeter(performance.now());
  const text = (id, value) => { document.getElementById(id).textContent = value; };
  const formatBytes = (n) => n < 1000 ? `${n} B` : n < 1000000 ? `${(n / 1000).toFixed(1)} KB` : `${(n / 1000000).toFixed(2)} MB`;
  const renderMeter = ({ fps, maxFps, kbps }) => {
    text("fps", fps.toFixed(1)); text("fps-max", maxFps.toFixed(1));
    document.getElementById("fps-fill").style.transform = `scaleX(${fps / meter.ceiling})`;
    const progress = document.getElementById("fps-meter");
    progress.setAttribute("aria-valuenow", fps.toFixed(1));
    progress.setAttribute("aria-valuemax", String(meter.ceiling));
    progress.setAttribute("aria-valuetext", `${fps.toFixed(1)} FPS; sampled max ${maxFps.toFixed(1)}; ceiling ${meter.ceiling}`);
    const transfer = `${kbps.toFixed(1)} KB/s`;
    text("transfer", transfer); text("transfer-live", transfer);
  };
  const resetMeter = () => renderMeter(meter.reset(performance.now(), bytes, frames));
  const setStatus = (level, label, message = "") => {
    health = level;
    const indicator = document.getElementById("connection"), notice = document.getElementById("error");
    indicator.dataset.health = level; indicator.title = message || label;
    text("status", label); notice.dataset.health = level; notice.textContent = message; notice.hidden = !message;
  };
  const send = (message) => { if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message)); };
  const invalidate = () => { generation++; welcome = null; lastSeq = null; };
  const clear = () => { canvas.getContext("2d").clearRect(0, 0, canvas.width, canvas.height); empty.hidden = false; };
  const recover = (error) => {
    setStatus("warning", "Syncing", error.message); invalidate(); clear(); resetMeter(); send({ type: "resync" });
  };
  lowSwitch.addEventListener("change", () => {
    if (socket?.readyState !== WebSocket.OPEN) { lowSwitch.checked = lowBandwidth === true; return; }
    const low = lowSwitch.checked;
    lowSwitch.disabled = true;
    // Coalesce rapid activation and stay below the lifecycle control limit.
    clearTimeout(modeTimer);
    modeTimer = setTimeout(() => {
      if (socket?.readyState === WebSocket.OPEN) send({ type: "mode", lowBandwidth: low });
    }, 300);
  });

  async function apply(batch, receivedGeneration) {
    const { header: h, buffer } = batch;
    if (receivedGeneration !== generation || document.hidden || !welcome || h.epoch !== welcome.epoch) return;
    if (h.width !== welcome.width || h.height !== welcome.height || (h.tileSize ?? 128) !== welcome.tileSize ||
        (h.type === "delta" ? h.baseSeq !== lastSeq : lastSeq === null && h.seq !== "1") ||
        (lastSeq !== null && BigInt(h.seq) !== BigInt(lastSeq) + 1n)) throw Error("Image sequence or baseline mismatch");
    const started = performance.now();
    if (await drawBatch(batch, canvas, () => receivedGeneration !== generation || document.hidden) &&
        receivedGeneration === generation && !document.hidden) {
      lastSeq = h.seq; empty.hidden = true; frames++; retry = 0;
      send({ type: "ack", epoch: h.epoch, seq: h.seq });
      const elapsed = performance.now() - started;
      if (elapsed > 1000 / meter.ceiling) setStatus("warning", "Slow draw", `Decode + draw: ${elapsed.toFixed(1)} ms exceeds the ${meter.ceiling} FPS frame budget.`);
      else setStatus("normal", "Connected");
      text("dimensions", `${h.width} x ${h.height}`);
      text("batch", `${h.type} #${h.seq}`);
      const unit = h.type === "full" ? "image" : h.blocks.length === 1 ? "tile" : "tiles";
      text("batch-detail", `${h.blocks.length} ${unit} / ${formatBytes(buffer.byteLength)}`);
      text("timing", `${elapsed.toFixed(1)} ms`);
    }
  }

  function connect() {
    if (disposed || document.hidden) return;
    clearTimeout(modeTimer); lowSwitch.disabled = true;
    invalidate(); resetMeter(); setStatus("warning", retry ? "Reconnecting" : "Connecting");
    const ws = new WebSocket(`ws://${location.host}/stream`); socket = ws; ws.binaryType = "arraybuffer";
    ws.onopen = () => {
      if (ws !== socket || disposed) return;
      if (document.hidden) { send({ type: "pause" }); setStatus("warning", "Paused"); }
      else { setStatus("warning", "Syncing"); send({ type: "subscribe", v: 1 }); }
    };
    ws.onmessage = (event) => {
      if (ws !== socket || disposed) return;
      bytes += typeof event.data === "string" ? new TextEncoder().encode(event.data).byteLength : event.data.byteLength;
      text("bytes", formatBytes(bytes));
      try {
        if (typeof event.data === "string") {
          const message = JSON.parse(event.data);
          switch (message.type) {
            case "mode": {
              if (typeof message.lowBandwidth !== "boolean" || !integer(message.maxFps, 1, MAX_FPS)) throw Error("Invalid observer mode");
              const changed = lowBandwidth !== message.lowBandwidth;
              lowBandwidth = message.lowBandwidth; lowSwitch.checked = lowBandwidth; lowSwitch.disabled = false;
              if (changed) {
                invalidate(); clear(); meter.maxFps = 0; meter.ceiling = message.maxFps; resetMeter();
                setStatus("warning", document.hidden ? "Paused" : "Syncing");
              }
              break;
            }
            case "welcome":
              if (message.v !== 1 || !uuid(message.epoch) || !integer(message.width, 2, 1920) || !integer(message.height, 2, 2160) ||
                  message.width * message.height > MAX_PIXELS || ![64, 128].includes(message.tileSize) || message.codec !== "png" ||
                  !integer(message.maxFps, 1, MAX_FPS)) throw Error("Invalid welcome");
              invalidate(); welcome = message; meter.ceiling = message.maxFps; resetMeter(); break;
            case "ping": if (typeof message.nonce === "string" && message.nonce.length <= 64) send({ type: "pong", nonce: message.nonce }); break;
            case "error": invalidate(); clear(); resetMeter(); setStatus("error", "Error", String(message.message)); break;
            case "state": setStatus("warning", "Syncing"); break;
            default: throw Error("Unknown server message");
          }
        } else {
          const batch = parseBatch(event.data), current = generation;
          if (++queued > 2) { queued--; throw Error("Image queue overflow"); }
          queue = queue.then(() => apply(batch, current)).catch((error) => { if (current === generation) recover(error); }).finally(() => queued--);
        }
      } catch (error) { recover(error); }
    };
    ws.onerror = () => { if (ws === socket) setStatus("error", "Error", "WebSocket connection failed"); };
    ws.onclose = () => {
      if (ws !== socket) return;
      clearTimeout(modeTimer); lowSwitch.disabled = true;
      invalidate(); clear(); resetMeter();
      setStatus("error", "Disconnected", document.getElementById("error").textContent || "WebSocket disconnected; reconnecting.");
      if (!disposed && !document.hidden) {
        const delays = [1000, 2000, 4000, 8000, 15000];
        retryTimer = setTimeout(connect, delays[Math.min(retry++, delays.length - 1)]);
      }
    };
  }
  canvas.addEventListener("contextlost", (event) => {
    event.preventDefault(); invalidate(); resetMeter(); setStatus("error", "Error", "Canvas context lost");
  });
  canvas.addEventListener("contextrestored", () => recover(Error("Canvas restored; refreshing")));
  document.addEventListener("visibilitychange", () => {
    clearTimeout(retryTimer); invalidate(); resetMeter();
    if (document.hidden) { send({ type: "pause" }); setStatus("warning", "Paused"); }
    else if (socket?.readyState === WebSocket.OPEN) { setStatus("warning", "Syncing"); send({ type: "resume" }); }
    else connect();
  });
  window.addEventListener("pagehide", () => {
    disposed = true; clearTimeout(retryTimer); clearTimeout(modeTimer); lowSwitch.disabled = true;
    invalidate(); resetMeter(); send({ type: "pause" }); socket?.close(); clear();
  });
  window.addEventListener("pageshow", (event) => { if (event.persisted) { disposed = false; connect(); } });
  setInterval(() => {
    if (disposed || document.hidden) return;
    const sample = meter.sample(performance.now(), bytes, frames);
    renderMeter(health === "error" ? { ...sample, fps: 0 } : sample);
  }, 1000);
  connect();
}
