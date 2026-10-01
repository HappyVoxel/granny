// Granny Agent MV3 background service worker.
// Content scripts ask it to check URLs; the fetch happens here because
// content-script fetch can be restricted by page CSP in some browsers.
const HARD_BLOCKED = ['facebook.com', 'instagram.com', 'tiktok.com'];

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || message.type !== 'granny-check') return undefined;
  (async () => {
    let settings = await chrome.storage.local.get({ decidePort: 47899, token: '' });
    if (!settings.token) {
      settings = await pair(settings.decidePort) || settings;
    }
    try {
      const params = new URLSearchParams({
        url: message.url || '',
        title: message.title || '',
        channel: message.channel || '',
        description: message.description || '',
        kind: message.kind || '',
      });
      if (message.force) params.set('force', '1');
      const url = 'http://127.0.0.1:' + settings.decidePort + '/decide?' + params.toString();
      let response = await fetch(url, { headers: { 'X-Granny-Token': settings.token } });
      if (response.status === 401) {
        // The app's token changed (config regenerated): drop the stale one
        // and pair once more before giving up.
        await chrome.storage.local.set({ token: '' });
        const paired = await pair(settings.decidePort);
        if (paired && paired.token) {
          settings = paired;
          const retryURL = 'http://127.0.0.1:' + settings.decidePort + '/decide?' + params.toString();
          response = await fetch(retryURL, { headers: { 'X-Granny-Token': settings.token } });
        }
      }
      if (!response.ok) throw new Error('HTTP ' + response.status);
      sendResponse(await response.json());
    } catch (error) {
      // Daemon unreachable: fail open for everything except the hard list -
      // a missing granny must never brick browsing. The hard list mirrors
      // Config.defaultBlockedDomains; keep the two in step.
      sendResponse(fallback(message.url));
    }
  })();
  return true;
});

// Tokenless pairing on loopback: the daemon hands the extension its token so
// nobody has to paste anything. Manual values in the options page win.
async function pair(port) {
  for (const candidate of [port, 47899]) {
    try {
      const response = await fetch('http://127.0.0.1:' + candidate + '/hello');
      if (!response.ok) continue;
      const hello = await response.json();
      if (!hello.token) continue;
      const settings = { decidePort: hello.port || candidate, token: hello.token };
      await chrome.storage.local.set(settings);
      return settings;
    } catch (error) {
      /* daemon not up on this port */
    }
  }
  return null;
}

function fallback(url) {
  let host = '';
  try {
    host = new URL(url).hostname;
  } catch (error) {
    host = '';
  }
  const blocked = HARD_BLOCKED.some((domain) => host === domain || host.endsWith('.' + domain));
  // No message: the content script supplies one in the machine's language.
  return blocked
    ? { action: 'block', source: 'extension-fallback' }
    : { action: 'allow', source: 'extension-fallback' };
}
