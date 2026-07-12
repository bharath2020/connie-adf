// ADF Beam overlay: fetches the current Confluence page's ADF and cycles it
// as animated QR frames. Injected (with pako, qrcode, and protocol.js) by
// background.js on toolbar click; clicking again toggles the overlay off.
(() => {
  'use strict';

  const OVERLAY_ID = 'adf-beam-overlay';
  const existing = document.getElementById(OVERLAY_ID);
  if (existing) {
    existing.dispatchEvent(new CustomEvent('adf-beam-teardown'));
    existing.remove();
    return;
  }

  const CHUNK_SIZES = [300, 500, 800, 1200];
  const state = {
    json: null,
    docId: null,
    frames: [],
    frameIndex: 0,
    fps: 5,
    chunkSize: ADFBeamProtocol.DEFAULT_CHUNK_SIZE,
    timer: null,
  };

  // --- DOM -----------------------------------------------------------------
  const overlay = document.createElement('div');
  overlay.id = OVERLAY_ID;
  overlay.innerHTML = `
    <div class="adf-beam-panel">
      <div class="adf-beam-header">
        <span class="adf-beam-title">ADF Beam</span>
        <button class="adf-beam-close" title="Close">✕</button>
      </div>
      <div class="adf-beam-body">
        <div class="adf-beam-status">Fetching page…</div>
        <canvas class="adf-beam-qr" width="640" height="640" hidden></canvas>
        <div class="adf-beam-counter" hidden></div>
      </div>
      <div class="adf-beam-controls" hidden>
        <label>Speed <input type="range" class="adf-beam-fps" min="1" max="15" step="1" value="5">
          <span class="adf-beam-fps-value">5 fps</span></label>
        <label>Chunk size <select class="adf-beam-chunk">
          ${CHUNK_SIZES.map((s) => `<option value="${s}" ${s === state.chunkSize ? 'selected' : ''}>${s} B</option>`).join('')}
        </select></label>
        <button class="adf-beam-copy">Copy all frames</button>
      </div>
    </div>`;
  document.documentElement.appendChild(overlay);

  const el = (selector) => overlay.querySelector(selector);
  const statusEl = el('.adf-beam-status');
  const canvas = el('.adf-beam-qr');
  const counterEl = el('.adf-beam-counter');
  const controlsEl = el('.adf-beam-controls');

  function teardown() {
    if (state.timer) clearInterval(state.timer);
    overlay.remove();
  }
  overlay.addEventListener('adf-beam-teardown', () => { if (state.timer) clearInterval(state.timer); });
  el('.adf-beam-close').addEventListener('click', teardown);

  function showError(message) {
    if (state.timer) clearInterval(state.timer);
    canvas.hidden = true;
    counterEl.hidden = true;
    controlsEl.hidden = true;
    statusEl.hidden = false;
    statusEl.classList.add('adf-beam-error');
    statusEl.textContent = message;
  }

  // --- QR rendering --------------------------------------------------------
  function drawFrame() {
    if (state.frames.length === 0) return;
    const payload = state.frames[state.frameIndex];
    const qr = qrcode(0, 'L');
    qr.addData(payload, 'Byte');
    qr.make();

    const modules = qr.getModuleCount();
    const quiet = 4;
    const scale = Math.max(1, Math.floor(canvas.width / (modules + quiet * 2)));
    const size = (modules + quiet * 2) * scale;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = '#000000';
    const origin = Math.floor((canvas.width - size) / 2) + quiet * scale;
    for (let row = 0; row < modules; row++) {
      for (let col = 0; col < modules; col++) {
        if (qr.isDark(row, col)) {
          ctx.fillRect(origin + col * scale, origin + row * scale, scale, scale);
        }
      }
    }
    counterEl.textContent = `Frame ${state.frameIndex + 1} / ${state.frames.length}`;
    state.frameIndex = (state.frameIndex + 1) % state.frames.length;
  }

  function restartCycle() {
    if (state.timer) clearInterval(state.timer);
    state.frameIndex = 0;
    drawFrame();
    state.timer = setInterval(drawFrame, 1000 / state.fps);
  }

  function rebuildFrames() {
    state.frames = ADFBeamProtocol.encodeFrames(state.json, state.docId, state.chunkSize);
    restartCycle();
  }

  // --- Controls ------------------------------------------------------------
  el('.adf-beam-fps').addEventListener('input', (event) => {
    state.fps = Number(event.target.value);
    el('.adf-beam-fps-value').textContent = `${state.fps} fps`;
    restartCycle();
  });
  el('.adf-beam-chunk').addEventListener('change', (event) => {
    state.chunkSize = Number(event.target.value);
    rebuildFrames();
  });
  el('.adf-beam-copy').addEventListener('click', async () => {
    const button = el('.adf-beam-copy');
    try {
      await navigator.clipboard.writeText(state.frames.join('\n'));
      button.textContent = `Copied ${state.frames.length} frames`;
    } catch (error) {
      button.textContent = 'Copy failed';
    }
    setTimeout(() => { button.textContent = 'Copy all frames'; }, 2000);
  });

  // --- Confluence fetch ----------------------------------------------------
  function extractPageId(url) {
    const pathMatch = url.pathname.match(/\/pages\/(\d+)(\/|$)/);
    if (pathMatch) return pathMatch[1];
    const queryId = url.searchParams.get('pageId');
    if (queryId && /^\d+$/.test(queryId)) return queryId;
    return null;
  }

  async function load() {
    const url = new URL(location.href);
    if (!url.hostname.endsWith('.atlassian.net')) {
      showError('This is not a Confluence Cloud page. Open a *.atlassian.net wiki page and try again.');
      return;
    }
    const pageId = extractPageId(url);
    if (!pageId) {
      showError('Could not find a page ID in this URL. Open a Confluence page (…/pages/<id>/…) and try again.');
      return;
    }
    let response;
    try {
      response = await fetch(
        `${url.origin}/wiki/api/v2/pages/${pageId}?body-format=atlas_doc_format`,
        { credentials: 'include', headers: { Accept: 'application/json' } },
      );
    } catch (error) {
      showError(`Could not reach the Confluence API: ${error.message}`);
      return;
    }
    if (!response.ok) {
      showError(`Confluence API returned ${response.status} ${response.statusText}. Are you logged in?`);
      return;
    }
    const page = await response.json();
    const adf = page?.body?.atlas_doc_format?.value; // ADF arrives as a JSON *string*
    if (typeof adf !== 'string' || adf.length === 0) {
      showError('The API response did not include an atlas_doc_format body.');
      return;
    }
    state.json = adf;
    state.docId = `${pageId}-${page.version?.number ?? 0}`;
    el('.adf-beam-title').textContent = page.title || 'ADF Beam';
    statusEl.hidden = true;
    canvas.hidden = false;
    counterEl.hidden = false;
    controlsEl.hidden = false;
    rebuildFrames();
  }

  load();
})();
