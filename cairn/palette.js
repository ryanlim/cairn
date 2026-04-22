// cairn palette — user-provided + neutrals + runtime tint/shade helpers

window.CAIRN_PALETTE = [
  { name: 'Flag Red',         hex: '#d52023', role: 'destructive' },
  { name: 'Strawberry Red',   hex: '#f94144', role: 'danger' },
  { name: 'Atomic Tangerine', hex: '#f3722c', role: 'warn' },
  { name: 'Carrot Orange',    hex: '#f8961e', role: 'accent' },
  { name: 'Tuscan Sun',       hex: '#f9c74f', role: 'pending' },
  { name: 'Willow Green',     hex: '#90be6d', role: 'success' },
  { name: 'Seaweed',          hex: '#46af8f', role: 'verified' },
  { name: 'Dark Cyan',        hex: '#478583', role: 'info' },
  { name: 'Blue Slate',       hex: '#577590', role: 'muted' },
  { name: 'Air Force Blue',   hex: '#7890a5', role: 'quiet' },
];

window.CAIRN_NEUTRALS = [
  { name: 'Ink',         hex: '#111111', role: 'ink' },
  { name: 'Graphite',    hex: '#2a2722', role: 'graphite' },
  { name: 'Charcoal',    hex: '#4a4640', role: 'charcoal' },
  { name: 'Slate',       hex: '#76716a', role: 'slate' },
  { name: 'Pebble',      hex: '#a8a194', role: 'pebble' },
  { name: 'Sand',        hex: '#d6cfc1', role: 'sand' },
  { name: 'Linen',       hex: '#e8e3d9', role: 'linen' },
  { name: 'Paper',       hex: '#f2eee7', role: 'paper' },
  { name: 'Bone',        hex: '#faf8f4', role: 'bone' },
  { name: 'White',       hex: '#ffffff', role: 'white' },
];

// ── Color math ──────────────────────────────────────────────────────────
// All math in HSL space — matches what the supplied palette already encodes.
// shade(hex, amount)  darker when amount > 0, lighter when amount < 0
// tint(hex, amount)   alias for negative shade (lighter)
// adjust(hex, {l, s, h}) fine-grained shift on hsl axes (l,s in [-100..100], h in degrees)
// mix(a, b, t)        blend two hexes, t in [0..1]

function hexToRgb(h) {
  h = h.replace('#', '');
  if (h.length === 3) h = h.split('').map(c => c + c).join('');
  const n = parseInt(h, 16);
  return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
}
function rgbToHex({ r, g, b }) {
  const c = (v) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0');
  return '#' + c(r) + c(g) + c(b);
}
function rgbToHsl({ r, g, b }) {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  let h = 0, s = 0; const l = (max + min) / 2;
  if (max !== min) {
    const d = max - min;
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    switch (max) {
      case r: h = (g - b) / d + (g < b ? 6 : 0); break;
      case g: h = (b - r) / d + 2; break;
      case b: h = (r - g) / d + 4; break;
    }
    h *= 60;
  }
  return { h, s: s * 100, l: l * 100 };
}
function hslToRgb({ h, s, l }) {
  s /= 100; l /= 100;
  const k = (n) => (n + h / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  const f = (n) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
  return { r: f(0) * 255, g: f(8) * 255, b: f(4) * 255 };
}
function parseHexOrCssVar(c) {
  if (c.startsWith('#')) return c;
  if (c.startsWith('var(')) {
    const name = c.match(/var\((--[^)]+)\)/)?.[1];
    if (name) return getComputedStyle(document.documentElement).getPropertyValue(name).trim() || '#000';
  }
  return c;
}

window.CairnColor = {
  shade(hex, amount = 10) {
    const h = parseHexOrCssVar(hex);
    const hsl = rgbToHsl(hexToRgb(h));
    hsl.l = Math.max(0, Math.min(100, hsl.l - amount));
    return rgbToHex(hslToRgb(hsl));
  },
  tint(hex, amount = 10) {
    return this.shade(hex, -amount);
  },
  adjust(hex, { l = 0, s = 0, h = 0 } = {}) {
    const hex2 = parseHexOrCssVar(hex);
    const hsl = rgbToHsl(hexToRgb(hex2));
    hsl.h = (hsl.h + h + 360) % 360;
    hsl.s = Math.max(0, Math.min(100, hsl.s + s));
    hsl.l = Math.max(0, Math.min(100, hsl.l + l));
    return rgbToHex(hslToRgb(hsl));
  },
  mix(a, b, t = 0.5) {
    const A = hexToRgb(parseHexOrCssVar(a));
    const B = hexToRgb(parseHexOrCssVar(b));
    return rgbToHex({
      r: A.r + (B.r - A.r) * t,
      g: A.g + (B.g - A.g) * t,
      b: A.b + (B.b - A.b) * t,
    });
  },
  // Build a 5-stop ramp (lightest → darkest) for a given hue
  ramp(hex, stops = [36, 22, 8, -8, -22]) {
    return stops.map(s => this.shade(hex, s));
  },
  // Auto-generate soft/ink pair for a role color
  softInk(hex, { softL = 45, inkL = -25 } = {}) {
    return { soft: this.tint(hex, softL), ink: this.shade(hex, -inkL) };
  },
  // Generate a human-readable name from a hex, used when the user edits a
  // default color and we want to drop the factory name automatically.
  // Output shape: "<Shade> <Hue>"  →  "Deep teal", "Pale rose", "Soft violet".
  // Near-neutral → gray family.  Plain mid-lightness → unmodified hue name.
  suggestName(hex) {
    const h = parseHexOrCssVar(hex);
    const { h: H, s: S, l: L } = rgbToHsl(hexToRgb(h));

    // Near-neutral → gray family. Uses its own shade axis so we get
    // "Black" / "Ink" / "Charcoal" / "Slate" / "Gray" / "Silver" / "Paper" / "White".
    if (S < 10) {
      if (L < 6)  return 'Black';
      if (L < 18) return 'Ink';
      if (L < 32) return 'Charcoal';
      if (L < 48) return 'Slate';
      if (L < 62) return 'Gray';
      if (L < 75) return 'Silver';
      if (L < 88) return 'Paper';
      if (L < 97) return 'Bone';
      return 'White';
    }

    // Hue bucket — 12-slice wheel merged into a cleaner 12-name set.
    let hue;
    if      (H < 15)  hue = 'red';
    else if (H < 35)  hue = 'orange';
    else if (H < 55)  hue = 'amber';
    else if (H < 75)  hue = 'yellow';
    else if (H < 100) hue = 'lime';
    else if (H < 150) hue = 'green';
    else if (H < 185) hue = 'teal';
    else if (H < 210) hue = 'cyan';
    else if (H < 250) hue = 'blue';
    else if (H < 280) hue = 'indigo';
    else if (H < 320) hue = 'violet';
    else if (H < 345) hue = 'magenta';
    else              hue = 'red';

    // Shade modifier: combine lightness + saturation so a desaturated
    // mid-blue reads as "Dusty blue" instead of a plain "blue" that
    // misleadingly implies a vivid color.
    //   Very dark, saturated  → "Deep"
    //   Dark                  → "Dark"
    //   Muted (low S)         → "Dusty" or "Muted"
    //   Mid-range saturated   → no modifier (just the hue)
    //   Light                 → "Soft" or "Pale"
    //   Very light            → "Pale"
    //   Very vivid            → "Vivid"

    let shade = '';
    if (L < 22)      shade = 'Deep';
    else if (L < 38) shade = S > 55 ? 'Rich' : 'Dark';
    else if (L > 85) shade = 'Pale';
    else if (L > 72) shade = 'Soft';
    else {
      // Mid lightness: describe saturation instead.
      if (S < 30)       shade = 'Dusty';
      else if (S < 55)  shade = 'Muted';
      else if (S > 85)  shade = 'Vivid';
      // else: no modifier — the plain hue name reads cleanly.
    }

    // Capitalize the hue if we have no shade modifier.
    if (!shade) {
      return hue.charAt(0).toUpperCase() + hue.slice(1);
    }
    return `${shade} ${hue}`;
  },
};

// Snapshot the factory palette so the editor can detect "changed" and
// offer a per-color reset. Frozen to make accidental mutation impossible.
window.CAIRN_DEFAULT_PALETTE  = Object.freeze(window.CAIRN_PALETTE.map(c => Object.freeze({ ...c })));
window.CAIRN_DEFAULT_NEUTRALS = Object.freeze(window.CAIRN_NEUTRALS.map(c => Object.freeze({ ...c })));
