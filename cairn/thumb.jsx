// AssetThumb — deterministic CSS "thumbnail" for a cairn asset.
//
// These are intentionally stylized placeholders, not attempts at photorealism.
// The brief's point stands: in a real build the Immich thumbnail endpoint fills
// this frame. For the prototype we want:
//   (a) stable per-filename output (same IMG_ always looks the same),
//   (b) enough visual distinction that you can scan a grid and spot "that one"
//       from "those three receipts," and
//   (c) clear overlays for video / live-pair / trashed / restored state.
//
// All scenes are layered CSS gradients + radial blobs — no raster, no network.

// Lightweight string → integer hash for deterministic jitter.
function _h(s, salt = 0) {
  let h = 2166136261 ^ salt;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0);
}
function _jit(s, salt, min, max) {
  return min + (_h(s, salt) % 1000) / 1000 * (max - min);
}

// Scene palettes — each returns a layered background string.
// Scenes are designed to read in a 72–140px tile at a glance.
const SCENES = {
  'portrait-dim': (n) => {
    const warm = _jit(n, 1, 20, 45);   // skin hue
    const bg   = _jit(n, 2, 10, 28);
    return `
      radial-gradient(ellipse 55% 70% at 50% 42%, hsl(${warm} 40% 62%) 0%, hsl(${warm} 30% 40%) 38%, transparent 60%),
      radial-gradient(ellipse 40% 55% at 50% 92%, hsl(${warm+10} 30% 30%) 0%, transparent 70%),
      linear-gradient(180deg, hsl(${bg} 30% 15%) 0%, hsl(${bg+8} 35% 10%) 100%)`;
  },
  'portrait-bright': (n) => {
    const warm = _jit(n, 1, 15, 40);
    return `
      radial-gradient(ellipse 50% 60% at 50% 45%, hsl(${warm} 45% 72%) 0%, hsl(${warm-5} 40% 58%) 40%, transparent 62%),
      linear-gradient(180deg, hsl(${warm+180} 35% 85%) 0%, hsl(${warm+190} 40% 70%) 100%)`;
  },
  'receipt': (n) => {
    const rot = _jit(n, 3, -6, 6);
    return `
      linear-gradient(90deg, transparent 14%, #00000010 14.5%, transparent 15.5%, transparent 30%, #00000010 30.5%, transparent 32%, transparent 48%, #00000010 48.5%, transparent 50%, transparent 68%, #00000010 68.5%, transparent 70%),
      linear-gradient(${rot}deg, #fafaf5 30%, #e8e4d8 100%)`;
  },
  'document': (n) => `
      repeating-linear-gradient(0deg, transparent 0 9px, #00000008 9px 10px),
      linear-gradient(180deg, #fdfcf6 0%, #f0ecdf 100%)`,
  'whiteboard': (n) => {
    const a = _jit(n, 4, 0, 360);
    return `
      radial-gradient(ellipse 30% 18% at 30% 40%, hsl(${a} 70% 45% / 0.65) 0%, transparent 70%),
      radial-gradient(ellipse 22% 14% at 68% 60%, hsl(${a+120} 65% 45% / 0.55) 0%, transparent 70%),
      radial-gradient(ellipse 16% 10% at 50% 78%, hsl(${a+220} 60% 50% / 0.5) 0%, transparent 70%),
      linear-gradient(180deg, #f9f9f6 0%, #ecebe4 100%)`;
  },
  'meal': (n) => {
    const hueA = _jit(n, 5, 20, 50);   // warm food
    const hueB = _jit(n, 6, 80, 140);  // greens
    return `
      radial-gradient(ellipse 45% 45% at 50% 55%, hsl(${hueA} 60% 50%) 0%, hsl(${hueA-5} 55% 35%) 55%, transparent 70%),
      radial-gradient(ellipse 20% 20% at 28% 30%, hsl(${hueB} 55% 45%) 0%, transparent 70%),
      radial-gradient(ellipse 18% 18% at 75% 68%, hsl(${hueB+20} 50% 55%) 0%, transparent 70%),
      linear-gradient(180deg, #38312a 0%, #201b17 100%)`;
  },
  'beach': (n) => {
    const sky = _jit(n, 7, 195, 215);
    return `
      linear-gradient(180deg, hsl(${sky} 55% 78%) 0%, hsl(${sky-5} 55% 85%) 45%, #f1e6c8 58%, #d9c898 72%, #b8a070 100%),
      radial-gradient(ellipse 40% 8% at 60% 62%, #ffffff55 0%, transparent 70%)`;
  },
  'sunset': (n) => {
    const core = _jit(n, 8, 15, 35);
    return `
      linear-gradient(180deg, hsl(${core+220} 50% 25%) 0%, hsl(${core+200} 60% 40%) 30%, hsl(${core+30} 75% 55%) 60%, hsl(${core+5} 85% 62%) 82%, hsl(${core-10} 60% 35%) 100%)`;
  },
  'landscape': (n) => {
    const sky = _jit(n, 9, 195, 220);
    const grn = _jit(n, 10, 80, 130);
    return `
      linear-gradient(180deg, hsl(${sky} 55% 72%) 0%, hsl(${sky-5} 50% 82%) 55%, hsl(${grn} 40% 50%) 58%, hsl(${grn+10} 45% 30%) 100%)`;
  },
  'flora': (n) => {
    const hue = _jit(n, 11, 280, 360);
    return `
      radial-gradient(circle at 35% 45%, hsl(${hue} 65% 65%) 0%, hsl(${hue-10} 55% 45%) 40%, transparent 60%),
      radial-gradient(circle at 70% 62%, hsl(${hue+30} 60% 60%) 0%, transparent 50%),
      linear-gradient(180deg, hsl(100 35% 40%) 0%, hsl(110 40% 25%) 100%)`;
  },
  'pet': (n) => {
    const fur = _jit(n, 12, 20, 45);
    return `
      radial-gradient(ellipse 55% 60% at 50% 58%, hsl(${fur} 45% 55%) 0%, hsl(${fur-5} 50% 35%) 55%, transparent 72%),
      radial-gradient(ellipse 8% 6% at 42% 45%, #1a1310 0%, transparent 80%),
      radial-gradient(ellipse 8% 6% at 58% 45%, #1a1310 0%, transparent 80%),
      linear-gradient(180deg, hsl(${fur+180} 20% 70%) 0%, hsl(${fur+170} 25% 55%) 100%)`;
  },
  'city-night': (n) => {
    const warm = _jit(n, 13, 30, 55);
    return `
      radial-gradient(circle at 22% 62%, hsl(${warm} 95% 62% / 0.75) 0%, transparent 12%),
      radial-gradient(circle at 38% 70%, hsl(${warm-5} 90% 58% / 0.7) 0%, transparent 10%),
      radial-gradient(circle at 55% 55%, hsl(${warm+5} 85% 65% / 0.65) 0%, transparent 14%),
      radial-gradient(circle at 72% 68%, hsl(${warm+10} 90% 60% / 0.7) 0%, transparent 11%),
      radial-gradient(circle at 85% 58%, hsl(${warm-8} 95% 65% / 0.6) 0%, transparent 9%),
      linear-gradient(180deg, #0a0f1e 0%, #1c2335 50%, #0d1120 100%)`;
  },
};

// Resolve scene, defaulting to a neutral gradient.
function resolveScene(name, scene) {
  const fn = SCENES[scene] || SCENES['landscape'];
  return fn(name);
}

function AssetThumb({ asset, size = 72, state, selected, onClick, showLabel }) {
  const bg = resolveScene(asset.name, asset.scene);
  const isVideo = asset.kind === 'video';
  const isLive  = asset.kind === 'live-pair';
  const radius = Math.max(6, Math.round(size * 0.11));

  const stateOverlay = (() => {
    if (state === 'trashed') {
      return {
        background: 'linear-gradient(180deg, rgba(26,24,21,0.55), rgba(26,24,21,0.65))',
        color: '#fff', opacity: 0.95,
      };
    }
    if (state === 'restored') {
      return { background: 'transparent', color: '#fff' };
    }
    if (state === 'excluded') {
      return {
        background: `color-mix(in oklab, var(--ui-info) 42%, transparent)`,
        color: 'var(--ui-info-ink)',
      };
    }
    return null;
  })();

  return (
    <div
      onClick={onClick}
      style={{
        position: 'relative',
        width: size,
        height: size,
        borderRadius: radius,
        overflow: 'hidden',
        background: bg,
        border: selected
          ? '2px solid var(--ui-primary)'
          : '0.5px solid color-mix(in oklab, var(--ui-text) 12%, transparent)',
        boxShadow: selected ? '0 0 0 3px color-mix(in oklab, var(--ui-primary) 22%, transparent)' : 'inset 0 1px 0 rgba(255,255,255,0.08)',
        flexShrink: 0,
        cursor: onClick ? 'pointer' : 'default',
        transition: 'transform 120ms ease, box-shadow 120ms ease',
      }}>

      {/* Live-pair offset "second tile" peek */}
      {isLive && (
        <div style={{
          position: 'absolute',
          inset: 0,
          borderRadius: radius,
          boxShadow: `2px 2px 0 0 color-mix(in oklab, var(--ui-text) 20%, transparent), 4px 4px 0 0 color-mix(in oklab, var(--ui-text) 10%, transparent)`,
          pointerEvents: 'none',
        }}/>
      )}

      {/* Badges (bottom-left corner) */}
      <div style={{ position: 'absolute', left: 5, bottom: 5, display: 'flex', gap: 3, alignItems: 'center' }}>
        {isVideo && (
          <Badge>
            <I.play width="9" height="9" strokeWidth="0" fill="currentColor"/>
            {asset.durationSec && <span>{asset.durationSec}s</span>}
          </Badge>
        )}
        {isLive && (
          <Badge>
            <LiveDot/> <span>LIVE</span>
          </Badge>
        )}
      </div>

      {/* Selection checkmark (top-right) */}
      {selected && (
        <div style={{
          position: 'absolute', top: 5, right: 5,
          width: 18, height: 18, borderRadius: 999,
          background: 'var(--ui-primary)',
          color: 'var(--ui-primary-ink)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          boxShadow: '0 1px 3px rgba(0,0,0,0.25)',
        }}>
          <I.check width="11" height="11" strokeWidth="3"/>
        </div>
      )}

      {/* State overlay (trashed dim, restored shine) */}
      {stateOverlay && state === 'trashed' && (
        <div style={{
          position: 'absolute', inset: 0,
          ...stateOverlay,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <I.trash width={size * 0.28} height={size * 0.28} strokeWidth="1.5" style={{ opacity: 0.9 }}/>
        </div>
      )}

      {/* Excluded — info-tinted wash + shield glyph */}
      {stateOverlay && state === 'excluded' && (
        <div style={{
          position: 'absolute', inset: 0,
          ...stateOverlay,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <div style={{
            background: 'rgba(255,255,255,0.92)',
            borderRadius: 999,
            width: size * 0.4, height: size * 0.4,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            color: 'var(--ui-info-ink)',
          }}>
            <I.shield width={size * 0.22} height={size * 0.22} strokeWidth="2"/>
          </div>
        </div>
      )}

      {/* Optional filename label (used in run-detail large view) */}
      {showLabel && (
        <div style={{
          position: 'absolute', left: 0, right: 0, bottom: 0,
          padding: '14px 6px 4px',
          background: 'linear-gradient(180deg, transparent, rgba(0,0,0,0.55))',
          color: '#fff',
          fontSize: 10,
          fontFamily: 'var(--font-mono)',
          letterSpacing: '0.02em',
          textAlign: 'left',
          overflow: 'hidden',
          whiteSpace: 'nowrap',
          textOverflow: 'ellipsis',
        }}>
          {asset.name.replace(/\.[^.]+$/, '')}
        </div>
      )}
    </div>
  );
}

function Badge({ children }) {
  return (
    <div style={{
      display: 'inline-flex', alignItems: 'center', gap: 3,
      padding: '2px 5px',
      fontSize: 9,
      fontWeight: 600,
      letterSpacing: '0.04em',
      color: '#fff',
      background: 'rgba(0,0,0,0.55)',
      backdropFilter: 'blur(4px)',
      WebkitBackdropFilter: 'blur(4px)',
      borderRadius: 4,
      lineHeight: 1,
    }}>
      {children}
    </div>
  );
}
function LiveDot() {
  return (
    <span style={{
      width: 6, height: 6, borderRadius: 999,
      background: '#fff',
      boxShadow: '0 0 0 1.5px rgba(255,255,255,0.35)',
      display: 'inline-block',
    }}/>
  );
}

window.AssetThumb = AssetThumb;
