// Intercepts navigations and asks granny. document_start, top frame only.
//
// Two-phase workflow:
//   1. fast check with whatever context exists (rules decide most pages)
//   2. if granny answers "need-context" (content pages like YouTube before
//      the title exists), show a small "granny is looking" layer, wait for
//      the real title/channel, then ask again with force.
//
// On block, granny also purges the origin's offline data: Cache Storage and
// service-worker registrations. A blocked site must not survive as an
// offline shell that reloads from its own cache.
(() => {
  if (window.top !== window) return;
  if (location.protocol !== 'http:' && location.protocol !== 'https:') return;

  const ALLOW_PREFIX = 'granny-allow:';
  // Timings for the "granny is looking" phase: poll the title every
  // TITLE_TICK_MS, give up (force) after TITLE_WAIT_MS; the description is
  // capped before it goes over the wire.
  const DESCRIPTION_LIMIT = 300;
  const TITLE_TICK_MS = 250;
  const TITLE_WAIT_MS = 2500;
  let layer = null;

  // English is the default; Vietnamese and Finnish when the machine speaks them.
  const TEXT = {
    vi: {
      looking: 'Ngoại đang xem cháu định làm gì đấy…',
      continue: 'Tiếp tục',
      back: 'Quay lại',
      blocked: 'Ngoại nói không nhé cháu.',
    },
    fi: {
      looking: 'Mummo katsoo, mitä sinä oikein puuhaat…',
      continue: 'Jatka',
      back: 'Palaa takaisin',
      blocked: 'Mummo sanoo ei, kulta.',
    },
  }[(navigator.language || 'en').toLowerCase().split('-')[0]] || {
    looking: 'Granny is checking what you are up to…',
    continue: 'Continue',
    back: 'Go back',
    blocked: 'Granny says no, dear.',
  };

  function send(message) {
    return new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage(message, (response) => resolve(response || null));
      } catch (error) {
        resolve(null);
      }
    });
  }

  function removeLayer() {
    if (layer) {
      layer.remove();
      layer = null;
    }
  }

  function showLayer(text, options) {
    const continueAfterSeconds = options && options.continueAfterSeconds;
    const showBack = !options || options.back !== false;
    const root = document.documentElement;
    if (!root) return;

    removeLayer();
    layer = document.createElement('div');
    layer.style.cssText = [
      'position:fixed', 'inset:0', 'z-index:2147483647',
      'background:#1c1a17', 'color:#f4e9d8',
      'display:flex', 'flex-direction:column', 'align-items:center',
      'justify-content:center', 'gap:16px',
      'font:16px/1.5 -apple-system, system-ui', 'padding:32px', 'text-align:center',
    ].join(';');

    const line = document.createElement('div');
    line.textContent = text;
    line.style.cssText = 'font-size:22px;max-width:640px';
    layer.appendChild(line);

    if (continueAfterSeconds) {
      const button = document.createElement('button');
      button.disabled = true;
      button.style.cssText =
        'padding:8px 20px;border-radius:8px;border:1px solid #f4e9d8;background:transparent;color:#f4e9d8;font-size:15px;cursor:pointer';
      let remaining = continueAfterSeconds;
          button.textContent = TEXT.continue + ' (' + remaining + ')';
      const timer = setInterval(() => {
        remaining -= 1;
        if (remaining <= 0) {
          clearInterval(timer);
          button.disabled = false;
          button.textContent = TEXT.continue;
        } else {
      button.textContent = TEXT.continue + ' (' + remaining + ')';
        }
      }, 1000);
      button.addEventListener('click', () => {
        sessionStorage.setItem(ALLOW_PREFIX + location.href, '1');
        removeLayer();
      });
      layer.appendChild(button);
    }

    if (showBack) {
      const back = document.createElement('a');
      back.textContent = TEXT.back;
      back.href = 'about:blank';
      back.style.cssText = 'color:#b8a88f;font-size:14px';
      back.addEventListener('click', (event) => {
        event.preventDefault();
        if (history.length > 1) history.back();
        else window.close();
      });
      layer.appendChild(back);
    }

    root.appendChild(layer);
  }

  function metaContent(name) {
    const el = document.querySelector('meta[name="' + name + '"], meta[property="' + name + '"]');
    return el ? el.content || '' : '';
  }

  function extractContext() {
    const host = location.hostname;
    const isYouTube = host === 'youtube.com' || host.endsWith('.youtube.com');
    let kind = 'page';
    if (host === 'music.youtube.com') {
      kind = 'music';
    } else if (isYouTube) {
      if (location.pathname.startsWith('/shorts')) kind = 'shorts';
      else if (location.pathname.startsWith('/watch')) kind = 'video';
      else kind = 'youtube';
    }

    let channel = '';
    if (kind === 'video' || kind === 'youtube') {
      const node = document.querySelector(
        'ytd-video-owner-renderer #channel-name a, #owner #channel-name a, ytd-channel-name a');
      channel = node ? (node.textContent || '').trim() : '';
    }

    return {
      title: (document.title || '').trim(),
      channel: channel,
      description: (metaContent('description') || metaContent('og:description')).slice(0, DESCRIPTION_LIMIT),
      kind: kind,
    };
  }

  function waitForTitle(timeoutMs, previousTitle) {
    return new Promise((resolve) => {
      const deadline = Date.now() + timeoutMs;
      const tick = () => {
        const title = (document.title || '').trim();
        if (title && title !== 'YouTube' && title !== previousTitle) return resolve(title);
        if (Date.now() > deadline) return resolve(title);
        setTimeout(tick, TITLE_TICK_MS);
      };
      tick();
    });
  }

  /// Deletes the origin's Cache Storage and unregisters its service workers,
  /// so a blocked site cannot re-serve itself from offline cache.
  async function purgeOfflineData() {
    try {
      const keys = await caches.keys();
      await Promise.all(keys.map((key) => caches.delete(key)));
    } catch (error) {
      /* caches API unavailable: nothing to purge */
    }
    try {
      const registrations = await navigator.serviceWorker.getRegistrations();
      await Promise.all(registrations.map((registration) => registration.unregister()));
    } catch (error) {
      /* serviceWorker API unavailable: nothing to unregister */
    }
  }

  async function guard(previousTitle) {
    const url = location.href;
    if (sessionStorage.getItem(ALLOW_PREFIX + url)) return;

    let context = extractContext();
    let decision = await send({ type: 'granny-check', url: url, title: context.title, channel: context.channel, description: context.description, kind: context.kind });

    if (decision && decision.action === 'need-context') {
      showLayer(TEXT.looking, { back: false });
      await waitForTitle(TITLE_WAIT_MS, previousTitle);
      context = extractContext();
      decision = await send({ type: 'granny-check', url: url, title: context.title, channel: context.channel, description: context.description, kind: context.kind, force: true });
    }

    removeLayer();
    if (!decision || decision.action === 'allow') return;
    if (decision.action === 'block') {
      purgeOfflineData();
    }
    showLayer(decision.message || TEXT.blocked, {
      continueAfterSeconds: decision.action === 'warn' ? 5 : 0,
    });
  }

  function hookHistory() {
    for (const method of ['pushState', 'replaceState']) {
      const original = history[method];
      history[method] = function () {
        const previousTitle = document.title;
        const result = original.apply(this, arguments);
        window.dispatchEvent(new CustomEvent('granny:navigation', { detail: { previousTitle: previousTitle } }));
        return result;
      };
    }
    window.addEventListener('popstate', () => {
      window.dispatchEvent(new CustomEvent('granny:navigation', { detail: { previousTitle: document.title } }));
    });
    window.addEventListener('granny:navigation', (event) => {
      guard(event.detail ? event.detail.previousTitle : undefined);
    });
  }

  hookHistory();
  if (document.documentElement) guard();
  else document.addEventListener('DOMContentLoaded', () => guard(), { once: true });
})();
