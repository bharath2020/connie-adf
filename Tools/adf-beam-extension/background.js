// Toolbar click -> inject the overlay (or toggle it off) into the current tab.
// Runs as a service worker in Chrome and as an event page in Firefox (which has
// no MV3 service workers); the manifest declares both, and this file uses only
// APIs common to the two.
const api = globalThis.browser ?? globalThis.chrome;

api.action.onClicked.addListener(async (tab) => {
  if (!tab.id) return;
  try {
    await api.scripting.insertCSS({ target: { tabId: tab.id }, files: ['overlay.css'] });
    await api.scripting.executeScript({
      target: { tabId: tab.id },
      files: ['lib/pako.min.js', 'lib/qrcode.js', 'shared/protocol.js', 'content.js'],
    });
  } catch (error) {
    // chrome:// and about: pages, the Web Store, etc. refuse injection — nothing to do.
    console.warn('ADF Beam: cannot inject into this tab.', error);
  }
});
