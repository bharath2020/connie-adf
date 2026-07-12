// Toolbar click -> inject the overlay (or toggle it off) into the current tab.
chrome.action.onClicked.addListener(async (tab) => {
  if (!tab.id) return;
  try {
    await chrome.scripting.insertCSS({ target: { tabId: tab.id }, files: ['overlay.css'] });
    await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      files: ['lib/pako.min.js', 'lib/qrcode.js', 'shared/protocol.js', 'content.js'],
    });
  } catch (error) {
    // chrome:// pages, the Web Store, etc. refuse injection — nothing to do.
    console.warn('ADF Beam: cannot inject into this tab.', error);
  }
});
