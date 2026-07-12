// Headless round-trip check: kitchen-sink ADF JSON -> frames -> JSON,
// asserting byte-identical output. Exits 0 on PASS, 1 on FAIL.
//   node Tools/adf-beam-extension/test-roundtrip.mjs
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const protocol = require('./shared/protocol.js');

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const json = readFileSync(join(root, 'Fixtures', 'kitchen-sink.json'), 'utf8');

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS ${name}`);
  } catch (error) {
    failures++;
    console.error(`FAIL ${name}: ${error.message}`);
  }
}

check('round-trip is byte-identical', () => {
  const frames = protocol.encodeFrames(json, 'test-doc');
  if (protocol.decodeFrames(frames) !== json) throw new Error('output differs from input');
});

check('round-trip survives shuffling and duplicate frames', () => {
  const frames = protocol.encodeFrames(json, 'test-doc', 400);
  const noisy = [...frames, ...frames.slice(0, 3)].sort(() => 0.5 - Math.random());
  if (protocol.decodeFrames(noisy) !== json) throw new Error('output differs from input');
});

check('frames respect the chunk-size bound', () => {
  const frames = protocol.encodeFrames(json, 'test-doc', 800);
  for (const frame of frames) {
    const { chunk } = protocol.parseFrame(frame);
    if (chunk.length > 800) throw new Error(`chunk of ${chunk.length} bytes exceeds 800`);
  }
});

check('malformed frames are rejected', () => {
  for (const bad of ['QRX1|d|0|1|aGk=', 'ADF1|d|0|1', 'ADF1||0|1|aGk=', 'ADF1|d|9|3|aGk=', 'ADF1|d|0|0|aGk=']) {
    let threw = false;
    try { protocol.parseFrame(bad); } catch { threw = true; }
    if (!threw) throw new Error(`accepted malformed frame: ${bad}`);
  }
});

check('mixed documents are rejected', () => {
  const a = protocol.encodeFrames(json, 'doc-a', 400);
  const b = protocol.encodeFrames(json, 'doc-b', 400);
  let threw = false;
  try { protocol.decodeFrames([...a.slice(0, 1), ...b.slice(1)]); } catch { threw = true; }
  if (!threw) throw new Error('accepted frames from two documents');
});

process.exit(failures === 0 ? 0 : 1);
