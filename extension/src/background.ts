// Granny Agent MV3 background service worker.
// Content scripts ask it to check URLs; the fetch happens here because
// content-script fetch can be restricted by page CSP in some browsers.
const HARD_BLOCKED = ['facebook.com', 'instagram.com', 'tiktok.com'];
const DEFAULT_PORT = 47899;

chrome.runtime.onMessage.addListener((message: GrannyMessage | undefined, sender, sendResponse) => {
  if (!message) return undefined;
  if (message.type === 'granny-close-tab') {
    // The interstitial's "close the tab" button: the content script cannot
    // close its own tab, the background can.
    if (sender.tab && sender.tab.id !== undefined) chrome.tabs.remove(sender.tab.id);
    return undefined;
  }
  if (message.type !== 'granny-check') return undefined;
  (async () => {
    let settings: GrannySettings = await chrome.storage.local.get({
      decidePort: DEFAULT_PORT,
      token: '',
    });
    if (!settings.token) {
      settings = (await pair(settings.decidePort)) || settings;
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
      const url = decideURL(settings.decidePort, params);
      let response = await fetch(url, { headers: { 'X-Granny-Token': settings.token } });
      if (response.status === 401) {
        // The app's token changed (config regenerated): drop the stale one
        // and pair once more before giving up.
        await chrome.storage.local.set({ token: '' });
        const paired = await pair(settings.decidePort);
        if (paired && paired.token) {
          settings = paired;
          response = await fetch(decideURL(settings.decidePort, params), {
            headers: { 'X-Granny-Token': settings.token },
          });
        }
      }
      if (!response.ok) throw new Error('HTTP ' + response.status);
      sendResponse((await response.json()) as GrannyDecision);
    } catch (error) {
      // Daemon unreachable: fail open for everything except the hard list -
      // a missing granny must never brick browsing. The hard list mirrors
      // Config.defaultBlockedDomains; keep the two in step.
      sendResponse(fallback(message.url));
    }
  })();
  return true;
});

function decideURL(port: number, params: URLSearchParams): string {
  return 'http://127.0.0.1:' + port + '/decide?' + params.toString();
}

// Tokenless pairing on loopback: the daemon hands the extension its token so
// nobody has to paste anything. Manual values in the options page win.
async function pair(port: number): Promise<GrannySettings | null> {
  for (const candidate of [port, DEFAULT_PORT]) {
    try {
      const response = await fetch('http://127.0.0.1:' + candidate + '/hello');
      if (!response.ok) continue;
      const hello = (await response.json()) as GrannyHello;
      if (!hello.token) continue;
      const settings: GrannySettings = { decidePort: hello.port || candidate, token: hello.token };
      await chrome.storage.local.set(settings);
      return settings;
    } catch (error) {
      /* daemon not up on this port */
    }
  }
  return null;
}

function fallback(url: string): GrannyDecision {
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
