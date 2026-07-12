// Turns bookmarklet.js into the draggable `javascript:` URL in bookmarklet.txt.
//   node build-bookmarklet.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, 'bookmarklet.js'), 'utf8');

// Strip `// …` line comments, collapse whitespace runs. The source avoids
// `//` inside strings and regex literals, so this is safe here.
const body = src
  .split('\n')
  .map((line) => line.replace(/^\s*\/\/.*$/, ''))
  .join('\n')
  .replace(/\s+/g, ' ')
  .trim();

const url = 'javascript:' + encodeURIComponent(body);
writeFileSync(join(here, 'bookmarklet.txt'), url + '\n');
console.log('wrote bookmarklet.txt (' + url.length + ' chars)');
