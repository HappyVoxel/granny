// Design tokens shared by the extension surfaces (the in-page layer today;
// the options page can adopt them next). The values mirror the app's
// GrannyTheme dark palette, so the overlay and the app read as one product:
// walnut, brass, parchment - old money, but liquid.
(() => {
  window.GRANNY_THEME = {
    // GrannyTheme dark: background / card / text / gold / hairline.
    background: '#1B1713',
    card: '#241E18',
    text: '#EDE5D5',
    gold: '#C2A15C',
    goldSoft: '#D9BE83',
    hairline: '#3B3229',
    onGold: '#241C17',
    // The negotiation trio: oxblood, brass, verdigris.
    danger: '#7E332C',
    dangerLight: '#9C443C',
    dangerHover: '#A0483E',
    success: '#5F8F6D',
    successText: '#9CC2A6',
    muted: '#8F8271',
    serif: "'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif",
    sans: '-apple-system, system-ui, sans-serif',
    radius: '999px',
    transition:
      'background-color .18s ease, box-shadow .18s ease, color .18s ease, transform .18s cubic-bezier(.2,.8,.2,1)',
  };
})();
