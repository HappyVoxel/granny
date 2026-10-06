// Ambient types shared by the extension scripts. The sources are classic
// scripts (no imports: the manifests and options.html load them by name),
// so cross-file types live here rather than in a module.

/** Design tokens written by theme.ts and read by the overlay. */
interface GrannyTheme {
  background: string;
  card: string;
  text: string;
  gold: string;
  goldSoft: string;
  hairline: string;
  onGold: string;
  danger: string;
  dangerLight: string;
  dangerHover: string;
  success: string;
  successText: string;
  muted: string;
  serif: string;
  sans: string;
  radius: string;
  transition: string;
}

interface Window {
  GRANNY_THEME?: GrannyTheme;
}

/** The daemon's verdict, as the background worker relays it. */
interface GrannyDecision {
  action: 'allow' | 'warn' | 'block' | 'need-context';
  message?: string;
  reason?: string;
  source?: string;
}

interface GrannyCheckMessage {
  type: 'granny-check';
  url: string;
  title: string;
  channel: string;
  description: string;
  kind: string;
  force?: boolean;
}

interface GrannyCloseTabMessage {
  type: 'granny-close-tab';
}

type GrannyMessage = GrannyCheckMessage | GrannyCloseTabMessage;

/** Port + token, as stored in chrome.storage.local. */
interface GrannySettings {
  decidePort: number;
  token: string;
}

/** What /hello answers on loopback. */
interface GrannyHello {
  port?: number;
  token?: string;
}

/** Page context scraped by the content script. */
interface PageContext {
  title: string;
  channel: string;
  description: string;
  kind: string;
}

/** Overlay switches; every button is opt-in per verdict. */
interface LayerOptions {
  back?: boolean;
  dismiss?: boolean;
  close?: boolean;
  continue?: boolean;
  mute?: boolean;
}
