// icons.jsx — minimal, stroke-based icons for cairn.
// All 20x20 unless noted, stroke 1.5, round caps.

const iconDefaults = {
  width: 20,
  height: 20,
  viewBox: '0 0 20 20',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.5,
  strokeLinecap: 'round',
  strokeLinejoin: 'round',
};

const I = {
  cairn: (p = {}) => (
    // Three stacked stones — the brand mark
    <svg {...iconDefaults} {...p}>
      <ellipse cx="10" cy="15.5" rx="6.5" ry="1.5"/>
      <ellipse cx="10" cy="11" rx="5" ry="1.3"/>
      <ellipse cx="10" cy="6.5" rx="3.2" ry="1.1"/>
      <path d="M3.5 15.5V14.5M16.5 15.5V14.5" opacity="0.5"/>
      <path d="M5 11V10M15 11V10" opacity="0.5"/>
      <path d="M6.8 6.5V5.8M13.2 6.5V5.8" opacity="0.5"/>
    </svg>
  ),
  sync: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M3.5 10a6.5 6.5 0 0 1 10.9-4.8"/>
      <path d="M16.5 10a6.5 6.5 0 0 1-10.9 4.8"/>
      <path d="M14.5 2v3.5h-3.5"/>
      <path d="M5.5 18v-3.5h3.5"/>
    </svg>
  ),
  clock: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <circle cx="10" cy="10" r="7"/>
      <path d="M10 6v4.2l2.7 1.6"/>
    </svg>
  ),
  shield: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M10 2.5l6.5 2v5.3c0 3.7-2.7 6.8-6.5 7.7-3.8-.9-6.5-4-6.5-7.7V4.5L10 2.5z"/>
    </svg>
  ),
  settings: (p = {}) => {
    // Traditional 8-tooth gear, generated from angle → (r1/r2) polar points.
    // r1 is the tooth tip radius, r2 is the valley radius. Each tooth spans
    // 360/8 = 45°, split half on the tip and half in the valley.
    const cx = 10, cy = 10;
    const teeth = 8;
    const rTip = 8.2, rBase = 6.4;
    const tipWidth = 0.32; // fraction of a tooth pitch the tip occupies
    const step = (Math.PI * 2) / teeth;
    const pts = [];
    for (let i = 0; i < teeth; i++) {
      const a = i * step;
      const half = (step * tipWidth) / 2;
      // valley leading into the tooth, tip corners, valley trailing out
      pts.push([a - step/2 + half*0.5, rBase]);
      pts.push([a - half, rTip]);
      pts.push([a + half, rTip]);
      pts.push([a + step/2 - half*0.5, rBase]);
    }
    const toXY = ([a, r]) => [cx + Math.cos(a - Math.PI/2) * r, cy + Math.sin(a - Math.PI/2) * r];
    const d = pts.map((pt, i) => {
      const [x, y] = toXY(pt);
      return `${i === 0 ? 'M' : 'L'}${x.toFixed(2)} ${y.toFixed(2)}`;
    }).join(' ') + ' Z';
    return (
      <svg {...iconDefaults} {...p}>
        <path d={d} strokeLinejoin="round"/>
        <circle cx={cx} cy={cy} r="2.5"/>
      </svg>
    );
  },
  list: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M6.5 5.5h10M6.5 10h10M6.5 14.5h10"/>
      <circle cx="3.5" cy="5.5" r="0.8" fill="currentColor"/>
      <circle cx="3.5" cy="10" r="0.8" fill="currentColor"/>
      <circle cx="3.5" cy="14.5" r="0.8" fill="currentColor"/>
    </svg>
  ),
  check: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M4 10.5L8 14.5 16 5.5"/>
    </svg>
  ),
  checkCircle: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <circle cx="10" cy="10" r="7.5"/>
      <path d="M6.5 10l2.5 2.5 5-5"/>
    </svg>
  ),
  warn: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M10 3.5L17.5 16.5h-15L10 3.5z"/>
      <path d="M10 8v3.5M10 14v.01" strokeLinecap="round"/>
    </svg>
  ),
  info: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <circle cx="10" cy="10" r="7.5"/>
      <path d="M10 9v4.5M10 6.5v.01" strokeLinecap="round"/>
    </svg>
  ),
  trash: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M3.5 5.5h13M8 5.5V4a1.5 1.5 0 0 1 1.5-1.5h1A1.5 1.5 0 0 1 12 4v1.5M5 5.5l.8 10A1.5 1.5 0 0 0 7.3 17h5.4a1.5 1.5 0 0 0 1.5-1.5L15 5.5"/>
    </svg>
  ),
  restore: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M3 9.5a7 7 0 1 1 2.5 5.5"/>
      <path d="M3 4.5v5h5"/>
    </svg>
  ),
  chevron: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M7.5 4.5l5 5.5-5 5.5"/>
    </svg>
  ),
  chevronDown: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M5 7.5l5 5 5-5"/>
    </svg>
  ),
  server: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <rect x="3" y="4" width="14" height="5" rx="1.3"/>
      <rect x="3" y="11" width="14" height="5" rx="1.3"/>
      <path d="M6 6.5h.01M6 13.5h.01" strokeLinecap="round"/>
    </svg>
  ),
  phone: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <rect x="5" y="2.5" width="10" height="15" rx="2"/>
      <path d="M8.5 15h3"/>
    </svg>
  ),
  photo: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <rect x="2.5" y="3.5" width="15" height="13" rx="2"/>
      <circle cx="7" cy="8" r="1.3"/>
      <path d="M2.5 13l4-4 4 4M10 12l2.5-2.5 5 5"/>
    </svg>
  ),
  play: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M5.5 3.5l10 6.5-10 6.5v-13z" fill="currentColor"/>
    </svg>
  ),
  doc: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M4.5 2.5h7.5L15.5 6v11.5a1 1 0 0 1-1 1h-10a1 1 0 0 1-1-1V3.5a1 1 0 0 1 1-1z"/>
      <path d="M12 2.5V6h3.5"/>
    </svg>
  ),
  close: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M4.5 4.5l11 11M15.5 4.5l-11 11"/>
    </svg>
  ),
  key: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <circle cx="6.5" cy="13.5" r="3.5"/>
      <path d="M9 11L16.5 3.5M13.5 6.5l2 2"/>
    </svg>
  ),
  link: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M8 12l4-4"/>
      <path d="M11 6l1.5-1.5a3 3 0 1 1 4.2 4.2L15 10"/>
      <path d="M9 10l-1.5 1.5a3 3 0 1 1-4.2-4.2L5 6"/>
    </svg>
  ),
  bolt: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M11 2.5L4 11h5v6.5L16 9h-5V2.5z"/>
    </svg>
  ),
  eye: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M1.5 10S4.5 4.5 10 4.5 18.5 10 18.5 10 15.5 15.5 10 15.5 1.5 10 1.5 10z"/>
      <circle cx="10" cy="10" r="2.5"/>
    </svg>
  ),
  bell: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M4.5 14.5h11l-1.5-2V9a4 4 0 1 0-8 0v3.5l-1.5 2z"/>
      <path d="M8 17a2 2 0 0 0 4 0"/>
    </svg>
  ),
  wand: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M14 3.5l-10 10 2.5 2.5 10-10-2.5-2.5z"/>
      <path d="M3 5.5l1 .5.5 1 .5-1 1-.5-1-.5-.5-1-.5 1-1 .5zM16 11l1 .5.5 1 .5-1 1-.5-1-.5-.5-1-.5 1-1 .5z" fill="currentColor" stroke="none"/>
    </svg>
  ),
  tag: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <path d="M10.5 2.5H3.5a1 1 0 0 0-1 1v7a1 1 0 0 0 .3.7l6.5 6.5a1 1 0 0 0 1.4 0l7-7a1 1 0 0 0 0-1.4l-6.5-6.5a1 1 0 0 0-.7-.3z"/>
      <circle cx="6.5" cy="6.5" r="1" fill="currentColor" stroke="none"/>
    </svg>
  ),
  search: (p = {}) => (
    <svg {...iconDefaults} {...p}>
      <circle cx="8.5" cy="8.5" r="5"/>
      <path d="M12.5 12.5l4 4"/>
    </svg>
  ),
};

window.I = I;
