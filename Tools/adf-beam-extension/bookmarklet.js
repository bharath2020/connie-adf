// ADF Beam bookmarklet — automates "step 1": on a Confluence page, one click
// fetches that page's ADF (using your logged-in session, same-origin) and
// copies it to the clipboard. Paste into beam.html and press Beam.
//
// Not an extension, so a corporate ExtensionSettings policy doesn't block it;
// Chrome exempts bookmarklets from the page CSP, and the fetch is same-origin
// so it rides your existing session — no token, no auth flow.
//
// build.mjs turns this into the draggable `javascript:` URL in bookmarklet.txt.
(async () => {
  const toast = (msg) => {
    const d = document.createElement('div');
    d.textContent = 'ADF Beam: ' + msg;
    d.style.cssText =
      'position:fixed;z-index:2147483647;top:16px;left:50%;transform:translateX(-50%);' +
      'max-width:80vw;background:#172b4d;color:#fff;padding:10px 16px;border-radius:8px;' +
      'font:14px -apple-system,sans-serif;box-shadow:0 6px 20px rgba(0,0,0,.35)';
    document.documentElement.appendChild(d);
    setTimeout(() => d.remove(), 3500);
  };
  const copy = async (text) => {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (e) {
      // Transient-activation or focus loss after the fetch: fall back to a
      // hidden textarea + execCommand, still supported in Chrome.
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0';
      document.documentElement.appendChild(ta);
      ta.select();
      const ok = document.execCommand('copy');
      ta.remove();
      return ok;
    }
  };
  try {
    const u = new URL(location.href);
    const id = (u.pathname.match(/\/pages\/(\d+)/) || [])[1] || u.searchParams.get('pageId');
    if (!id) { toast('no page ID in this URL — open a Confluence page.'); return; }
    const r = await fetch(
      u.origin + '/wiki/api/v2/pages/' + id + '?body-format=atlas_doc_format',
      { credentials: 'include', headers: { Accept: 'application/json' } }
    );
    if (!r.ok) { toast('API returned ' + r.status + ' — are you logged in?'); return; }
    const j = await r.json();
    const adf = j && j.body && j.body.atlas_doc_format && j.body.atlas_doc_format.value;
    if (!adf) { toast('no ADF body in the response.'); return; }
    const ok = await copy(adf);
    toast(ok
      ? 'copied “' + (j.title || 'page') + '” — paste into beam.html.'
      : 'fetched “' + (j.title || 'page') + '” but clipboard was blocked.');
  } catch (e) {
    toast(e.message);
  }
})();
