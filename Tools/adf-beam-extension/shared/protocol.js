// ADF Beam frame protocol — shared by the extension overlay, the browser
// round-trip test page, and the Node fixture generator.
//
// Frame format: ADF1|<docId>|<index>|<total>|<data>
//   data = base64 of one <=chunkSize-byte slice of the RAW-deflate-compressed
//   ADF JSON. Raw deflate (pako deflateRaw/inflateRaw) matches Apple's
//   COMPRESSION_ZLIB, which has no zlib header.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory(require('../lib/pako.min.js'));
  } else {
    root.ADFBeamProtocol = factory(root.pako);
  }
}(typeof self !== 'undefined' ? self : this, function (pako) {
  'use strict';

  const PREFIX = 'ADF1';
  const DEFAULT_CHUNK_SIZE = 800;

  function bytesToBase64(bytes) {
    let binary = '';
    for (let i = 0; i < bytes.length; i += 0x8000) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(binary);
  }

  function base64ToBytes(b64) {
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  // JSON string -> array of frame payload strings.
  function encodeFrames(jsonString, docId, chunkSize) {
    if (!docId || docId.includes('|')) throw new Error('invalid docId');
    const size = chunkSize || DEFAULT_CHUNK_SIZE;
    const compressed = pako.deflateRaw(jsonString);
    const total = Math.max(1, Math.ceil(compressed.length / size));
    const frames = [];
    for (let index = 0; index < total; index++) {
      const slice = compressed.subarray(index * size, (index + 1) * size);
      frames.push([PREFIX, docId, index, total, bytesToBase64(slice)].join('|'));
    }
    return frames;
  }

  // One frame payload string -> {docId, index, total, chunk} or throws.
  function parseFrame(payload) {
    // base64 never contains '|', so a plain split is safe
    const parts = payload.split('|');
    if (parts.length !== 5) throw new Error('bad field count');
    const [prefix, docId, indexStr, totalStr, data] = parts;
    if (prefix !== PREFIX) throw new Error('bad prefix');
    if (!docId) throw new Error('empty docId');
    const index = Number(indexStr);
    const total = Number(totalStr);
    if (!Number.isInteger(index) || index < 0) throw new Error('bad index');
    if (!Number.isInteger(total) || total <= 0) throw new Error('bad total');
    if (index >= total) throw new Error('index out of range');
    const chunk = base64ToBytes(data);
    if (chunk.length === 0) throw new Error('empty chunk');
    return { docId, index, total, chunk };
  }

  // Array of frame payload strings (any order, dupes ok) -> original JSON string.
  function decodeFrames(payloads) {
    const frames = payloads.map(parseFrame);
    const docId = frames[0].docId;
    const total = frames[0].total;
    const chunks = new Array(total).fill(null);
    for (const frame of frames) {
      if (frame.docId !== docId || frame.total !== total) throw new Error('mixed documents');
      chunks[frame.index] = frame.chunk;
    }
    if (chunks.some((c) => c === null)) throw new Error('missing chunks');
    let length = 0;
    for (const c of chunks) length += c.length;
    const joined = new Uint8Array(length);
    let offset = 0;
    for (const c of chunks) {
      joined.set(c, offset);
      offset += c.length;
    }
    return pako.inflateRaw(joined, { to: 'string' });
  }

  return { PREFIX, DEFAULT_CHUNK_SIZE, encodeFrames, parseFrame, decodeFrames };
}));
