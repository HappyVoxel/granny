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
  const MUTE_PREFIX = 'granny-mute:';
  // Timings for the "granny is looking" phase: poll the title every
  // TITLE_TICK_MS, give up (force) after TITLE_WAIT_MS; the description is
  // capped before it goes over the wire.
  const DESCRIPTION_LIMIT = 300;
  const TITLE_TICK_MS = 250;
  const TITLE_WAIT_MS = 2500;
  // How long the "no warnings for this domain" notice stays before it
  // fades on its own; the cross in its corner ends it sooner.
  const MUTED_CONFIRM_MS = 3000;
  let layer = null;

  // English is the default; Vietnamese and Finnish when the machine speaks them.
  const TEXT = {
    vi: {
      looking: 'Ngoại đang xem cháu định làm gì đấy…',
      continue: 'Tiếp tục',
      close: 'Đóng tab',
      back: 'Quay lại',
      blocked: 'Ngoại nói không nhé cháu.',
      mute: 'Đừng nhắc domain này nữa',
      muted: 'Rồi, ngoại không nhắc {domain} nữa cho hết ngày hôm nay nhé.',
      dismiss: 'Đóng',
    },
    fi: {
      looking: 'Mummo katsoo, mitä sinä oikein puuhaat…',
      continue: 'Jatka',
      close: 'Sulje välilehti',
      back: 'Palaa takaisin',
      blocked: 'Mummo sanoo ei, kulta.',
      mute: 'Älä varoita tästä verkkotunnuksesta',
      muted: 'Selvä, mummo ei enää varoita {domain}-osoitteesta tänään.',
      dismiss: 'Sulje',
    },
  }[(navigator.language || 'en').toLowerCase().split('-')[0]] || {
    looking: 'Granny is checking what you are up to…',
    continue: 'Continue',
    close: 'Close the tab',
    back: 'Go back',
    blocked: 'Granny says no, dear.',
    mute: "Don't warn for this domain",
    muted: "Alright dear - no warnings for {domain} for the rest of today.",
    dismiss: 'Dismiss',
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

  // "Don't warn for this domain": stored per host (www folded away) until
  // the end of today, so a work task that lives on a site stops drawing the
  // negotiable warning for the rest of the day.
  function muteKey(host) {
    return MUTE_PREFIX + host.replace(/^www\./, '');
  }

  function endOfToday() {
    const end = new Date();
    end.setHours(23, 59, 59, 999);
    return end.getTime();
  }

  function isMuted(host) {
    return new Promise((resolve) => {
      const key = muteKey(host);
      try {
        chrome.storage.local.get([key], (data) => {
          const expiry = data && data[key];
          if (!expiry) return resolve(false);
          if (Date.now() > expiry) {
            chrome.storage.local.remove([key]);
            return resolve(false);
          }
          resolve(true);
        });
      } catch (error) {
        resolve(false);
      }
    });
  }

  function muteDomain(host) {
    try {
      chrome.storage.local.set({ [muteKey(host)]: endOfToday() });
    } catch (error) {
      /* storage unavailable: the warning will show again next navigation */
    }
  }

  function showLayer(text, options) {
    const showBack = !options || options.back !== false;
    const root = document.documentElement;
    if (!root) return;

    // Shared with the app's GrannyTheme; theme.js loads before this script.
    const THEME = window.GRANNY_THEME || {};

    removeLayer();
    layer = document.createElement('div');
    layer.style.cssText = [
      'position:fixed', 'inset:0', 'z-index:2147483647',
      'background:rgba(27,23,19,.62)', 'color:' + THEME.text,
      '-webkit-backdrop-filter:blur(10px) saturate(1.05)',
      'backdrop-filter:blur(10px) saturate(1.05)',
      'display:flex', 'align-items:center', 'justify-content:center',
      'font:16px/1.5 ' + THEME.sans, 'padding:32px', 'text-align:center',
    ].join(';');

    // The card is the glass: walnut at low opacity, a brass hairline, and a
    // soft inner highlight so it reads liquid rather than flat.
    const card = document.createElement('div');
    card.style.cssText = [
      'display:flex', 'flex-direction:column', 'align-items:center', 'gap:12px',
      'padding:38px 42px', 'border-radius:22px', 'max-width:640px',
      'background:rgba(36,30,24,.78)',
      '-webkit-backdrop-filter:blur(18px) saturate(1.15)',
      'backdrop-filter:blur(18px) saturate(1.15)',
      'border:1px solid rgba(194,161,92,.32)',
      'box-shadow:0 30px 80px -30px rgba(0,0,0,.85), inset 0 1px 0 rgba(255,255,255,.05)',
    ].join(';');
    layer.appendChild(card);

    const line = document.createElement('div');
    line.textContent = text;
    line.style.cssText =
      'font:21px/1.55 ' + THEME.serif + ';max-width:520px;margin-bottom:14px';
    card.appendChild(line);

    const buttonBase = [
      'font:600 15px/1 ' + THEME.sans,
      'padding:13px 28px', 'border-radius:' + THEME.radius,
      'border:1.5px solid transparent', 'cursor:pointer', 'min-width:260px',
      'letter-spacing:.01em', 'transition:' + THEME.transition,
    ].join(';');

    // A quiet glassy lift on hover, without a stylesheet (page CSP safe).
    function withHover(el, base, hover) {
      el.style.cssText = base;
      el.addEventListener('mouseenter', () => {
        el.style.cssText = base + hover;
      });
      el.addEventListener('mouseleave', () => {
        el.style.cssText = base;
      });
    }

    const lift =
      ';transform:translateY(-1px);box-shadow:0 14px 30px -16px rgba(0,0,0,.85), inset 0 1px 0 rgba(255,255,255,.10)';

    if (options && options.dismiss) {
      // A notice, not a lock: a quiet cross in the corner ends it now
      // instead of waiting out the timer.
      card.style.position = 'relative';
      const cross = document.createElement('button');
      cross.setAttribute('aria-label', TEXT.dismiss);
      cross.title = TEXT.dismiss;
      cross.innerHTML =
        '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M18 6L6 18"/><path d="M6 6l12 12"/></svg>';
      withHover(
        cross,
        'position:absolute;top:10px;right:10px;background:none;border:none;color:' + THEME.muted + ';cursor:pointer;padding:7px;border-radius:999px;display:flex;align-items:center;justify-content:center;transition:background-color .15s ease, color .15s ease',
        ';color:' + THEME.text + ';background:rgba(237,229,213,.08)'
      );
      cross.addEventListener('click', () => removeLayer());
      card.appendChild(cross);
    }

    if (options && options.close) {
      // The negotiable verdict: granny states her case, the grandchild
      // chooses. One solid primary (close), two coloured outlines, an icon.
      const close = document.createElement('button');
      close.textContent = TEXT.close;
      withHover(
        close,
        buttonBase +
          ';background:linear-gradient(180deg,' + THEME.dangerLight + ',' + THEME.danger + ');border-color:rgba(0,0,0,.25);color:#F6EDE3;box-shadow:0 1px 0 rgba(0,0,0,.35), inset 0 1px 0 rgba(255,255,255,.12)',
        ';background:' + THEME.dangerHover + lift
      );
      close.addEventListener('click', () => {
        send({ type: 'granny-close-tab' });
        removeLayer();
      });
      card.appendChild(close);
    }

    if (options && options.continue) {
      // Immediate, no countdown: the negotiation is a choice, not a wait.
      const button = document.createElement('button');
      button.textContent = TEXT.continue;
      withHover(
        button,
        buttonBase + ';background:transparent;border-color:rgba(194,161,92,.75);color:' + THEME.goldSoft,
        ';background:rgba(194,161,92,.14)' + lift
      );
      button.addEventListener('click', () => {
        sessionStorage.setItem(ALLOW_PREFIX + location.href, '1');
        removeLayer();
      });
      card.appendChild(button);
    }

    if (options && options.mute) {
      const mute = document.createElement('button');
      mute.textContent = TEXT.mute;
      withHover(
        mute,
        buttonBase + ';background:transparent;border-color:rgba(95,143,109,.8);color:' + THEME.successText,
        ';background:rgba(95,143,109,.18)' + lift
      );
      mute.addEventListener('click', () => {
        muteDomain(location.hostname);
        removeLayer();
        showLayer(TEXT.muted.replace('{domain}', location.hostname.replace(/^www\./, '')), { back: false, dismiss: true });
        setTimeout(removeLayer, MUTED_CONFIRM_MS);
      });
      card.appendChild(mute);
    }

    if (showBack) {
      const back = document.createElement('button');
      back.setAttribute('aria-label', TEXT.back);
      back.title = TEXT.back;
      back.innerHTML =
        '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 12H5"/><path d="M12 19l-7-7 7-7"/></svg>';
      withHover(
        back,
        'background:none;border:none;color:' + THEME.muted + ';cursor:pointer;padding:8px;border-radius:999px;display:flex;align-items:center;justify-content:center;margin-top:4px;transition:background-color .15s ease, color .15s ease',
        ';color:' + THEME.text + ';background:rgba(237,229,213,.08)'
      );
      back.addEventListener('click', (event) => {
        event.preventDefault();
        if (history.length > 1) history.back();
        else window.close();
      });
      card.appendChild(back);
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
    // SPA navigation keeps the previous page's title until the new one
    // renders: sending it would judge - and cache - the wrong video.
    if (previousTitle && context.title === previousTitle) context.title = '';
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
    } else if (await isMuted(location.hostname)) {
      // "Don't warn for this domain" is in force until the end of today.
      return;
    }
    showLayer(decision.message || TEXT.blocked, {
      continue: decision.action === 'warn',
      close: decision.action === 'warn',
      mute: decision.action === 'warn',
    });
  }

  // SPA navigation: an isolated world cannot wrap the page's history
  // methods (the page keeps its own), so watch the URL instead and re-run
  // the check whenever it moves - YouTube's feed-to-video navigation is a
  // pushState in the page world, invisible to a content-script hook.
  function watchLocation() {
    let lastURL = location.href;
    let lastTitle = document.title;
    setInterval(() => {
      if (location.href === lastURL) {
        lastTitle = document.title;
        return;
      }
      const previousTitle = lastTitle;
      lastURL = location.href;
      lastTitle = document.title;
      guard(previousTitle);
    }, 500);
  }

  watchLocation();
  if (document.documentElement) guard();
  else document.addEventListener('DOMContentLoaded', () => guard(), { once: true });
})();
