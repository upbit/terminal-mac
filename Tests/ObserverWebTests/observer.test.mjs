import assert from 'node:assert/strict';
import { test } from 'node:test';
import { crc32 } from 'node:zlib';
import { parseBatch } from '../../Sources/TerminalObserver/Web/observer.js';

const epoch = '459d11da-fc80-490e-a7a8-7b670cc93a03';
function envelope({ type = 'full', width = 640, height = 400, blocks, mutate } = {}) {
  blocks ??= [{ x: 0, y: 0, w: width, h: height, offset: 0, length: 57 }];
  const header = { type, epoch, seq: type === 'full' ? '1' : '2', baseSeq: type === 'full' ? null : '1', width, height, codec: 'png', blocks };
  mutate?.(header);
  const metadata = Buffer.from(JSON.stringify(header));
  const prefix = Buffer.alloc(12); prefix.write('TMOB'); prefix.writeUInt16BE(1, 4); prefix.writeUInt32BE(metadata.length, 8);
  // Structurally valid PNG fixtures for validation, not for image decoding.
  const pngs = blocks.map((b) => {
    const png = Buffer.alloc(57); png.writeUInt32BE(0x89504e47); png.writeUInt32BE(0x0d0a1a0a, 4);
    png.writeUInt32BE(13, 8); png.write('IHDR', 12); png.writeUInt32BE(b.w, 16); png.writeUInt32BE(b.h, 20);
    png[24] = 8; png[25] = 2; png.writeUInt32BE(crc32(png.subarray(12, 29)), 29);
    png.write('IDAT', 37); png.writeUInt32BE(crc32(png.subarray(37, 41)), 41);
    png.write('IEND', 49); png.writeUInt32BE(crc32(png.subarray(49, 53)), 53); return png;
  });
  const data = Buffer.concat([prefix, metadata, ...pngs]);
  return data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
}
test('full and partial edge tile validate', () => {
  assert.equal(parseBatch(envelope()).header.type, 'full');
  const edge = { x: 512, y: 384, w: 128, h: 16, offset: 0, length: 57 };
  assert.equal(parseBatch(envelope({ type: 'delta', blocks: [edge] })).header.blocks[0].h, 16);
});
test('bad message lengths and versions reject before PNG decode', () => {
  assert.throws(() => parseBatch(new ArrayBuffer(11)));
  const data = envelope(); new DataView(data).setUint32(8, 65537); assert.throws(() => parseBatch(data));
  const version = envelope(); new DataView(version).setUint16(4, 2); assert.throws(() => parseBatch(version));
});
test('oversized dimensions and imprecise sequence numbers reject', () => {
  assert.throws(() => parseBatch(envelope({ mutate: (h) => { h.width = 999999; } })));
  assert.throws(() => parseBatch(envelope({ mutate: (h) => { h.seq = 2; } })));
  assert.throws(() => parseBatch(envelope({ mutate: (h) => { h.seq = '18446744073709551616'; } })));
});
test('duplicate, overlapping or unsorted delta tiles reject', () => {
  const b = { x: 0, y: 0, w: 128, h: 128, offset: 0, length: 57 };
  assert.throws(() => parseBatch(envelope({ type: 'delta', blocks: [b, { ...b, offset: 57 }] })));
  assert.throws(() => parseBatch(envelope({ type: 'delta', blocks: [{ ...b, x: 1 }] })));
  assert.throws(() => parseBatch(envelope({ type: 'delta', blocks: [{ ...b, x: 128 }, { ...b, offset: 57 }] })));
});
test('payload holes, trailing bytes and PNG dimension mismatch reject', () => {
  assert.throws(() => parseBatch(envelope({ mutate: (h) => { h.blocks[0].offset = 1; } })));
  const original = new Uint8Array(envelope()), trailing = new Uint8Array(original.length + 1); trailing.set(original);
  assert.throws(() => parseBatch(trailing.buffer));
  const mismatch = envelope(), view = new DataView(mismatch), start = 12 + view.getUint32(8);
  view.setUint32(start + 16, 100000); assert.throws(() => parseBatch(mismatch));
});
test('PNG chunk CRC and missing end reject', () => {
  const corrupt = envelope(), view = new DataView(corrupt), start = 12 + view.getUint32(8);
  view.setUint32(start + 41, 123); assert.throws(() => parseBatch(corrupt), /checksum/);
  const incomplete = envelope(), v = new DataView(incomplete), begin = 12 + v.getUint32(8);
  new Uint8Array(incomplete).fill(0, begin + 45); assert.throws(() => parseBatch(incomplete));
});
