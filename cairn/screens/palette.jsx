// PaletteScreen — browse + edit palette. Changes persist to localStorage,
// apply to CSS vars globally, and drive the rest of the app.

function usePaletteStore() {
  const DEFAULT = {
    accents: window.CAIRN_PALETTE,
    neutrals: window.CAIRN_NEUTRALS,
    step: 12,
  };

  // One-time migration: normalize legacy storage so users who installed
  // earlier builds don't see every swatch flagged "modified" after we ship
  // factory name changes. Rules:
  //   • If a stored color's hex still matches the current factory hex AND
  //     it has no nameSource flag, we treat it as unchanged and adopt the
  //     current factory name.
  //   • User-typed names (nameSource === 'user') are always preserved.
  //   • User-modified hexes (drift from factory) are always preserved.
  const migrate = (parsed) => {
    if (!parsed) return null;
    const normaliseList = (stored, factory) => {
      if (!Array.isArray(stored)) return stored;
      return stored.map((c, i) => {
        const def = factory[i];
        if (!def) return c;
        const hexMatches = (c.hex || '').toLowerCase() === def.hex.toLowerCase();
        const isLegacy = !c.nameSource;
        if (hexMatches && isLegacy) {
          return { ...c, name: def.name };
        }
        return c;
      });
    };
    return {
      ...parsed,
      accents:  normaliseList(parsed.accents,  window.CAIRN_DEFAULT_PALETTE),
      neutrals: normaliseList(parsed.neutrals, window.CAIRN_DEFAULT_NEUTRALS),
    };
  };

  const [store, setStore] = React.useState(() => {
    try {
      const s = localStorage.getItem('cairn.palette');
      if (s) {
        const migrated = migrate(JSON.parse(s));
        return { ...DEFAULT, ...migrated };
      }
    } catch (e) {}
    return DEFAULT;
  });
  const persist = (next) => {
    setStore(next);
    try { localStorage.setItem('cairn.palette', JSON.stringify(next)); } catch (e) {}
    applyPaletteToCSS(next);
  };
  React.useEffect(() => { applyPaletteToCSS(store); }, []);
  return [store, persist];
}

// Map roles → CSS variables that cairn.css / palette.css consume.
// Layer 1: write raw palette hexes into --c-<role> and --n-<role>.
// Layer 2 (semantic tokens in cairn.css) reads these via var() — so editing
// a palette swatch ripples through every UI category that references it.
function applyPaletteToCSS(store) {
  const r = document.documentElement;
  store.accents.forEach(c => r.style.setProperty(`--c-${c.role}`, c.hex));
  store.neutrals.forEach(c => r.style.setProperty(`--n-${c.role}`, c.hex));
}

function PaletteScreen({ onBack }) {
  const [store, setStore] = usePaletteStore();
  const [editing, setEditing] = React.useState(null); // {kind:'accent'|'neutral', index}

  const defaultAt = (kind, index) =>
    (kind === 'accent' ? window.CAIRN_DEFAULT_PALETTE : window.CAIRN_DEFAULT_NEUTRALS)[index];

  const isChanged = (kind, index) => {
    const def = defaultAt(kind, index);
    const cur = store[kind === 'accent' ? 'accents' : 'neutrals'][index];
    if (!def || !cur) return false;
    // Hex is authoritative — any drift from factory hex is a real edit.
    if (cur.hex.toLowerCase() !== def.hex.toLowerCase()) return true;
    // Name is only a "change" if the user explicitly typed it. A
    // nameSource of 'default' or 'auto' (or missing, for pre-nameSource
    // storage) should never mark a color as modified on name alone —
    // otherwise any factory-name rename we ship flags all existing
    // installs as "all colors modified".
    if (cur.nameSource === 'user' && cur.name !== def.name) return true;
    return false;
  };

  const updateColor = (kind, index, patch) => {
    const key = kind === 'accent' ? 'accents' : 'neutrals';
    const cur = store[key][index];
    const def = defaultAt(kind, index);
    const finalPatch = { ...patch };

    // Name-source tracking:
    //   'default' → still the factory name (first edit)
    //   'auto'    → last set by suggestName() from a hex change
    //   'user'    → user typed into the name field; stop auto-renaming
    //
    // We auto-rename on any hex change while nameSource is 'default' or
    // 'auto'. As soon as the user types in the name field, we flip to
    // 'user' and future hex changes leave the name alone.
    const source = cur.nameSource || (def && cur.name === def.name ? 'default' : 'user');

    if ('name' in patch && !('hex' in patch)) {
      // Direct name edit from the user — mark it as user-authored so future
      // hex changes won't overwrite it.
      finalPatch.nameSource = 'user';
    } else if ('hex' in patch && !('name' in patch) && source !== 'user') {
      finalPatch.name = CairnColor.suggestName(patch.hex);
      finalPatch.nameSource = 'auto';
    }

    const next = { ...store, [key]: store[key].map((c, i) => i === index ? { ...c, ...finalPatch } : c) };
    setStore(next);
  };

  const resetOne = (kind, index) => {
    const def = defaultAt(kind, index);
    if (!def) return;
    const key = kind === 'accent' ? 'accents' : 'neutrals';
    // Reset clears nameSource so it behaves like a fresh factory color.
    const next = { ...store, [key]: store[key].map((c, i) => i === index ? { ...def, nameSource: 'default' } : c) };
    setStore(next);
  };

  const setStep = (v) => setStore({ ...store, step: v });

  const resetAll = () => {
    if (!confirm('Reset all palette colors to factory defaults?')) return;
    localStorage.removeItem('cairn.palette');
    setStore({
      accents: window.CAIRN_DEFAULT_PALETTE.map(c => ({ ...c })),
      neutrals: window.CAIRN_DEFAULT_NEUTRALS.map(c => ({ ...c })),
      step: 12,
    });
  };

  const changedCount =
    store.accents.filter((_, i) => isChanged('accent', i)).length +
    store.neutrals.filter((_, i) => isChanged('neutral', i)).length;

  return (
    <div className="screen fade-in">
      <AppHeader
        title="Palette"
        subtitle={changedCount > 0
          ? `${changedCount} color${changedCount === 1 ? '' : 's'} modified from factory`
          : "Tap any swatch to edit · changes apply live"}
        leading={onBack && (
          <button onClick={onBack} style={{
            display: 'flex', alignItems: 'center', gap: 4,
            color: 'var(--ui-text-body)', fontSize: 15,
            background: 'transparent', border: 'none', cursor: 'pointer',
            padding: '4px 0',
          }}>
            <I.chevron width="16" height="16" style={{ transform: 'rotate(180deg)' }}/>
            Settings
          </button>
        )}
        trailing={
          <button
            className="btn btn-quiet btn-small"
            onClick={resetAll}
            disabled={changedCount === 0}
            style={{
              fontSize: 12,
              color: changedCount === 0 ? 'var(--stone-4)' : 'var(--ui-text-body)',
              opacity: changedCount === 0 ? 0.5 : 1,
              cursor: changedCount === 0 ? 'default' : 'pointer',
            }}>
            Reset all
          </button>
        }
      />

      <div className="keyline">Accents</div>
      <div style={{ padding: '0 16px' }}>
        <div className="card" style={{ overflow: 'hidden' }}>
          {store.accents.map((c, i) => (
            <SwatchRow
              key={i}
              color={c} amount={store.step}
              isLast={i === store.accents.length - 1}
              changed={isChanged('accent', i)}
              onEdit={() => setEditing({ kind: 'accent', index: i })}
            />
          ))}
        </div>
      </div>

      <div className="keyline">Neutrals</div>
      <div style={{ padding: '0 16px' }}>
        <div className="card" style={{ overflow: 'hidden' }}>
          {store.neutrals.map((c, i) => (
            <SwatchRow
              key={i}
              color={c} amount={store.step} neutral
              isLast={i === store.neutrals.length - 1}
              changed={isChanged('neutral', i)}
              onEdit={() => setEditing({ kind: 'neutral', index: i })}
            />
          ))}
        </div>
      </div>

      <div className="keyline">Tint / shade step</div>
      <div style={{ padding: '0 16px 20px' }}>
        <div className="card" style={{ padding: 16 }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
            <div style={{ fontSize: 13, color: 'var(--stone-5)' }}>Shift L% per step</div>
            <div className="mono tabular" style={{ fontSize: 13, color: 'var(--stone-7)' }}>±{store.step}</div>
          </div>
          <input type="range" min="4" max="32" step="2" value={store.step}
            onChange={(e) => setStep(parseInt(e.target.value))}
            style={{ width: '100%' }}/>
          <div style={{ fontSize: 11.5, color: 'var(--stone-5)', lineHeight: 1.5, marginTop: 10 }}>
            Each row shows the base hue flanked by 2 tints and 2 shades. Tap a swatch to edit its hex, name, or shift it on the HSL axes.
          </div>
        </div>
      </div>

      {editing && (
        <ColorEditorSheet
          color={store[editing.kind === 'accent' ? 'accents' : 'neutrals'][editing.index]}
          kind={editing.kind}
          changed={isChanged(editing.kind, editing.index)}
          defaultColor={defaultAt(editing.kind, editing.index)}
          onChange={(patch) => updateColor(editing.kind, editing.index, patch)}
          onReset={() => resetOne(editing.kind, editing.index)}
          onClose={() => setEditing(null)}
        />
      )}
    </div>
  );
}

function SwatchRow({ color, amount, isLast, neutral, changed, onEdit }) {
  const ramp = [
    CairnColor.tint(color.hex, amount * 2),
    CairnColor.tint(color.hex, amount),
    color.hex,
    CairnColor.shade(color.hex, amount),
    CairnColor.shade(color.hex, amount * 2),
  ];
  return (
    <div
      onClick={onEdit}
      style={{
        display: 'flex', alignItems: 'center', gap: 12, padding: '12px 14px',
        borderBottom: isLast ? 'none' : '0.5px solid var(--stone-3)',
        cursor: 'pointer',
      }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <div style={{
            fontSize: 13, fontWeight: 500, color: 'var(--stone-7)',
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          }}>{color.name}</div>
          {changed && (
            <span
              title="Modified from factory default"
              style={{
                width: 6, height: 6, borderRadius: 999,
                background: 'var(--ui-info)',
                boxShadow: '0 0 0 2px color-mix(in oklab, var(--ui-info) 22%, transparent)',
                flexShrink: 0,
              }}
            />
          )}
        </div>
        <div style={{ fontSize: 11, color: 'var(--stone-5)', display: 'flex', gap: 8 }}>
          <span className="mono">{color.hex.toUpperCase()}</span>
          {!neutral && <span>· {color.role}</span>}
        </div>
      </div>
      <div style={{ display: 'flex', gap: 3, flexShrink: 0 }}>
        {ramp.map((h, i) => (
          <div key={i} title={h} style={{
            width: 22, height: 28, borderRadius: 5, background: h,
            border: '0.5px solid rgba(0,0,0,0.08)',
            outline: i === 2 ? '1.5px solid var(--stone-7)' : 'none',
            outlineOffset: i === 2 ? 1 : 0,
          }}/>
        ))}
      </div>
      <div style={{ marginLeft: 8, color: 'var(--stone-4)', flexShrink: 0 }}>
        <I.chevron width="14" height="14"/>
      </div>
    </div>
  );
}

function ColorEditorSheet({ color, kind, changed, defaultColor, onChange, onReset, onClose }) {
  // Parse a hex into HSL. For achromatic colors (S≈0), H is mathematically
  // undefined — return `null` so callers can decide whether to fall back to
  // a remembered hue instead of snapping to 0.
  const hexToHSL = React.useCallback((hex) => {
    const h = hex.replace('#', '');
    const n = parseInt(h.length === 3 ? h.split('').map(c => c+c).join('') : h, 16);
    const r = ((n>>16)&255)/255, g = ((n>>8)&255)/255, b = (n&255)/255;
    const max = Math.max(r,g,b), min = Math.min(r,g,b);
    const L = (max+min)/2;
    if (max === min) return { h: null, s: 0, l: Math.round(L*100) };
    const d = max - min;
    const S = L > 0.5 ? d/(2-max-min) : d/(max+min);
    let H = 0;
    if (max === r)      H = (g-b)/d + (g<b?6:0);
    else if (max === g) H = (b-r)/d + 2;
    else                H = (r-g)/d + 4;
    H *= 60;
    return { h: Math.round(H), s: Math.round(S*100), l: Math.round(L*100) };
  }, []);

  // Local HSL state is the source of truth during editing. Seeded once from
  // the incoming hex; subsequent slider drags update HSL and *emit* a hex
  // without round-tripping through hex→HSL (which would erase the hue on
  // low-saturation colors like Graphite).
  const [hsl, setHsl] = React.useState(() => {
    const parsed = hexToHSL(color.hex);
    return { h: parsed.h ?? 0, s: parsed.s, l: parsed.l };
  });

  // If the underlying color changes from *outside* (e.g. Reset), re-seed.
  // Track last-seen hex so we don't thrash on our own emissions.
  const lastSeen = React.useRef(color.hex);
  React.useEffect(() => {
    if (color.hex === lastSeen.current) return;
    const parsed = hexToHSL(color.hex);
    // When the new color is achromatic, keep the remembered hue so the user
    // can still sweep saturation along the hue they last set.
    setHsl((prev) => ({
      h: parsed.h ?? prev.h,
      s: parsed.s,
      l: parsed.l,
    }));
    lastSeen.current = color.hex;
  }, [color.hex, hexToHSL]);

  // HSL → hex (sRGB), no round-trip.
  const hslToHex = (h, s, l) => {
    s /= 100; l /= 100;
    const k = (n) => (n + h/30) % 12;
    const a = s * Math.min(l, 1-l);
    const f = (n) => l - a * Math.max(-1, Math.min(k(n)-3, Math.min(9-k(n), 1)));
    const c = (v) => Math.max(0, Math.min(255, Math.round(v*255))).toString(16).padStart(2, '0');
    return '#' + c(f(0)) + c(f(8)) + c(f(4));
  };

  const setHSL = (h, s, l) => {
    const next = { h, s, l };
    setHsl(next);
    const hex = hslToHex(h, s, l);
    lastSeen.current = hex;
    onChange({ hex });
  };

  return (
    <div className="scrim" onClick={onClose}>
      <div className="sheet" onClick={(e) => e.stopPropagation()} style={{ maxHeight: '88%' }}>
        <div className="sheet-grip"/>
        <div style={{ padding: '6px 20px 16px' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 4 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--stone-4)', textTransform: 'uppercase', letterSpacing: '0.09em' }}>Edit color</div>
              {changed && (
                <span style={{
                  fontSize: 10, fontWeight: 600, letterSpacing: '0.06em', textTransform: 'uppercase',
                  color: 'var(--ui-info-ink)',
                  background: 'var(--ui-info-soft)',
                  padding: '2px 7px',
                  borderRadius: 999,
                  display: 'inline-flex', alignItems: 'center', gap: 4,
                }}>
                  <span style={{ width: 5, height: 5, borderRadius: 999, background: 'var(--ui-info)' }}/>
                  Modified
                </span>
              )}
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
              {changed && (
                <button
                  onClick={onReset}
                  title={defaultColor ? `Restore to ${defaultColor.name} (${defaultColor.hex.toUpperCase()})` : 'Restore factory default'}
                  style={{
                    fontSize: 12,
                    color: 'var(--ui-text-body)',
                    background: 'transparent',
                    border: '0.5px solid var(--ui-divider)',
                    borderRadius: 7,
                    padding: '4px 10px',
                    cursor: 'pointer',
                    fontWeight: 600,
                    display: 'inline-flex', alignItems: 'center', gap: 6,
                  }}>
                  {defaultColor && (
                    <span style={{
                      width: 12, height: 12, borderRadius: 3,
                      background: defaultColor.hex,
                      border: '0.5px solid rgba(0,0,0,0.1)',
                    }}/>
                  )}
                  Reset
                </button>
              )}
              <button onClick={onClose} style={{ color: 'var(--stone-5)', padding: '4px 8px' }}><I.close /></button>
            </div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <div style={{
              width: 72, height: 72, borderRadius: 14, background: color.hex,
              border: '0.5px solid rgba(0,0,0,0.1)', flexShrink: 0,
              boxShadow: 'inset 0 1px 2px rgba(255,255,255,0.2)',
            }}/>
            <div style={{ flex: 1, minWidth: 0 }}>
              <input
                value={color.name}
                onChange={(e) => onChange({ name: e.target.value })}
                style={{
                  width: '100%', border: 'none', background: 'transparent',
                  fontSize: 20, fontWeight: 600, letterSpacing: '-0.015em',
                  color: 'var(--stone-7)', outline: 'none', padding: 0,
                }}
              />
              <div className="mono" style={{ fontSize: 13, color: 'var(--stone-5)', marginTop: 2 }}>
                {color.hex.toUpperCase()}
                {changed && defaultColor && (
                  <span style={{ color: 'var(--stone-4)', marginLeft: 8, fontSize: 11 }}>
                    was <span style={{ textDecoration: 'line-through' }}>{defaultColor.hex.toUpperCase()}</span>
                  </span>
                )}
              </div>
            </div>
          </div>
        </div>

        <div style={{ padding: '0 16px 16px', overflowY: 'auto' }}>
          {/* Hex + native picker */}
          <div className="card" style={{ padding: 14, marginBottom: 12, display: 'flex', gap: 10, alignItems: 'center' }}>
            <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--stone-4)', textTransform: 'uppercase', letterSpacing: '0.09em', width: 40 }}>Hex</div>
            <input
              value={color.hex}
              onChange={(e) => {
                const v = e.target.value.trim();
                if (/^#?[0-9a-f]{3}([0-9a-f]{3})?$/i.test(v)) {
                  onChange({ hex: v.startsWith('#') ? v : '#' + v });
                }
              }}
              className="mono"
              style={{ flex: 1, border: '0.5px solid var(--stone-3)', borderRadius: 8, padding: '8px 10px', fontSize: 13, background: 'var(--stone-1)', outline: 'none', color: 'var(--stone-7)' }}
            />
            <label style={{
              width: 36, height: 36, borderRadius: 8, background: color.hex,
              border: '0.5px solid var(--stone-3)', cursor: 'pointer', position: 'relative', overflow: 'hidden',
            }}>
              <input type="color" value={color.hex}
                onChange={(e) => onChange({ hex: e.target.value })}
                style={{ position: 'absolute', inset: 0, opacity: 0, cursor: 'pointer' }}/>
            </label>
          </div>

          {/* HSL sliders */}
          <div className="card" style={{ padding: 14, marginBottom: 12 }}>
            <HSLSlider label="Hue" value={hsl.h} min={0} max={360} fmt={(v) => `${v}°`}
              track={`linear-gradient(to right, #f00 0%, #ff0 17%, #0f0 33%, #0ff 50%, #00f 67%, #f0f 83%, #f00 100%)`}
              onChange={(v) => setHSL(v, hsl.s, hsl.l)}/>
            <div style={{ height: 12 }}/>
            <HSLSlider label="Saturation" value={hsl.s} min={0} max={100} fmt={(v) => `${v}%`}
              track={`linear-gradient(to right, ${CairnColor.adjust(color.hex, { s: -100 })}, ${CairnColor.adjust(color.hex, { s: 100 })})`}
              onChange={(v) => setHSL(hsl.h, v, hsl.l)}/>
            <div style={{ height: 12 }}/>
            <HSLSlider label="Lightness" value={hsl.l} min={0} max={100} fmt={(v) => `${v}%`}
              track={`linear-gradient(to right, #000, ${color.hex}, #fff)`}
              onChange={(v) => setHSL(hsl.h, hsl.s, v)}/>
          </div>

          {/* Quick nudges — each tile is a preview of the resulting color,
              so the outcome is visible before you tap. */}
          <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--stone-4)', textTransform: 'uppercase', letterSpacing: '0.09em', padding: '4px 4px 8px' }}>Quick adjust</div>
          <div style={{ fontSize: 11.5, color: 'var(--stone-5)', padding: '0 4px 10px', lineHeight: 1.45 }}>
            Tap a tile to nudge this color one step. Each tile previews the result.
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 8, marginBottom: 16 }}>
            {[
              { label: 'Lighter', sub: '+10% L', hint: 'Mix toward white', fn: () => CairnColor.tint(color.hex, 10) },
              { label: 'Darker',  sub: '−10% L', hint: 'Mix toward black', fn: () => CairnColor.shade(color.hex, 10) },
              { label: 'More',    sub: '+10% S', hint: 'Saturate',         fn: () => CairnColor.adjust(color.hex, { s: 10 }) },
              { label: 'Less',    sub: '−10% S', hint: 'Desaturate',       fn: () => CairnColor.adjust(color.hex, { s: -10 }) },
            ].map(a => {
              const preview = a.fn();
              return (
                <button key={a.label}
                  onClick={() => onChange({ hex: preview })}
                  title={a.hint}
                  style={{
                    padding: 0,
                    borderRadius: 10,
                    border: '0.5px solid var(--stone-3)',
                    background: 'var(--ui-surface)',
                    overflow: 'hidden',
                    cursor: 'pointer',
                    display: 'flex',
                    flexDirection: 'column',
                    alignItems: 'stretch',
                  }}>
                  {/* Preview swatch */}
                  <div style={{
                    height: 34,
                    background: preview,
                    borderBottom: '0.5px solid var(--stone-3)',
                  }}/>
                  <div style={{ padding: '6px 4px 7px', textAlign: 'center' }}>
                    <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--stone-7)', lineHeight: 1 }}>{a.label}</div>
                    <div className="mono tabular" style={{ fontSize: 10, color: 'var(--stone-5)', marginTop: 3, lineHeight: 1 }}>{a.sub}</div>
                  </div>
                </button>
              );
            })}
          </div>

          {/* Per-color usage — only the categories this specific swatch drives */}
          <UsageForRole role={color.role}/>
        </div>

        <div style={{ padding: '14px 16px 0', borderTop: '0.5px solid var(--stone-3)', background: 'var(--stone-0)' }}>
          <button className="btn btn-primary btn-block" onClick={onClose}>Done</button>
        </div>
      </div>
    </div>
  );
}

function HSLSlider({ label, value, min, max, fmt, track, onChange }) {
  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 6 }}>
        <div style={{ fontSize: 12, color: 'var(--stone-5)' }}>{label}</div>
        <div className="mono tabular" style={{ fontSize: 12, color: 'var(--stone-7)' }}>{fmt(value)}</div>
      </div>
      <div style={{ position: 'relative', height: 22, display: 'flex', alignItems: 'center' }}>
        <div style={{ position: 'absolute', left: 0, right: 0, height: 10, borderRadius: 999, background: track, border: '0.5px solid rgba(0,0,0,0.08)' }}/>
        <input type="range" min={min} max={max} value={value}
          onChange={(e) => onChange(parseInt(e.target.value))}
          style={{ position: 'absolute', inset: 0, width: '100%', opacity: 0, margin: 0, cursor: 'pointer' }}/>
        <div style={{
          position: 'absolute',
          left: `calc(${((value - min) / (max - min)) * 100}% - 9px)`,
          width: 18, height: 18, borderRadius: 999,
          background: '#fff', border: '1.5px solid var(--stone-6)',
          boxShadow: '0 1px 3px rgba(0,0,0,0.15)',
          pointerEvents: 'none',
        }}/>
      </div>
    </div>
  );
}

// ── Usage map — what UI categories a specific palette role drives ───────
// Keyed by the Layer-1 role (`destructive`, `verified`, etc for accents;
// `paper`, `graphite`, etc for neutrals). Each entry names semantic
// categories and concrete sightings, so the color editor can tell you
// exactly where a given swatch shows up.
const USAGE_BY_ROLE = {
  // Accents
  destructive: {
    label: 'Destructive',
    categories: [
      { token: '--ui-danger', label: 'Danger fills', examples: ['"Delete anyway" button', 'Aborted-run icon', 'Abort journal events'] },
    ],
  },
  danger: {
    label: 'Danger (soft)',
    categories: [
      { token: '--c-danger', label: 'Soft danger accent', examples: ['Threshold banner left-border', 'Threshold warn icon'] },
    ],
  },
  warn: {
    label: 'Warning',
    categories: [
      { token: '--ui-warn', label: 'Warning fills', examples: ['Over-cap progress bar', 'Amber chips & callouts', 'Live-pair label', 'Trash journal events'] },
    ],
  },
  accent: {
    label: 'Emphasis',
    categories: [
      { token: '--ui-accent', label: 'Numerical emphasis', examples: ['Pending-candidates numeral on Status'] },
    ],
  },
  pending: {
    label: 'Pending',
    categories: [
      { token: '--ui-pending', label: 'Pending fills', examples: ['In-budget progress bar', 'Dry-run run icons', 'Dry-run badges'] },
    ],
  },
  success: {
    label: 'Success',
    categories: [
      { token: '--ui-success', label: 'Success fills', examples: ['Toggle-on track', 'Healthy connection dot', 'Permissions "allowed"'] },
    ],
  },
  verified: {
    label: 'Verified',
    categories: [
      { token: '--ui-verified', label: 'Verified fills', examples: ['"synced" badge', '"SHA1 set" label', 'Completed-run icons', 'Journal "verify" events'] },
    ],
  },
  info: {
    label: 'Informational',
    categories: [
      { token: '--ui-primary', label: 'Primary action', examples: ['Primary buttons', 'Active tab', 'Cairn mark tint', 'Stepper fill'] },
      { token: '--ui-info', label: 'Info accents', examples: ['Dry-run banner border', '"matched" label', 'Journal "tag" events'] },
    ],
  },
  muted: {
    label: 'Muted cool',
    categories: [
      { token: '--ui-muted', label: 'Secondary text & chips', examples: ['Device name "iPhone 15 Pro"', 'Run timestamps', 'Restored-count chip'] },
    ],
  },
  quiet: {
    label: 'Quiet cool',
    categories: [
      { token: '--c-quiet', label: 'Tertiary meta', examples: ['Server URL mono text', 'Run ID hash'] },
    ],
  },

  // Neutrals
  paper:    { label: 'App background',     categories: [{ token: '--ui-bg',            label: 'App background' }] },
  bone:     { label: 'Cards / sheets',     categories: [{ token: '--ui-surface',       label: 'Card & sheet surface' }] },
  linen:    { label: 'Raised panels',      categories: [{ token: '--ui-surface-alt',   label: 'Segmented controls, nested rows' }] },
  white:    { label: 'Elevated',           categories: [{ token: '--ui-elevated',      label: 'Toggle knob, modal top' }] },
  graphite: { label: 'Headings',           categories: [{ token: '--ui-text',          label: 'Primary text' }] },
  ink:      { label: 'Strongest ink',      categories: [{ token: '--ui-text-strong',   label: 'Display headings' }] },
  charcoal: { label: 'Body copy',          categories: [{ token: '--ui-text-body',     label: 'Row values, body text' }] },
  slate:    { label: 'Secondary text',     categories: [{ token: '--ui-text-muted',    label: 'Subtitles, row labels' }] },
  pebble:   { label: 'Tertiary text',      categories: [{ token: '--ui-text-quiet',    label: 'Caption labels, uppercase eyebrows' }, { token: '--ui-border-strong', label: 'Strong borders' }] },
  sand:     { label: 'Dividers',           categories: [{ token: '--ui-divider',       label: 'Row separators, hairlines' }] },
};

function UsageForRole({ role }) {
  const entry = USAGE_BY_ROLE[role];
  if (!entry) return null;
  return (
    <div>
      <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--ui-text-quiet)', textTransform: 'uppercase', letterSpacing: '0.09em', padding: '4px 4px 8px' }}>
        Used for
      </div>
      <div className="card" style={{ overflow: 'hidden' }}>
        {entry.categories.map((cat, i) => (
          <div key={cat.token} style={{
            padding: '11px 14px',
            borderBottom: i === entry.categories.length - 1 ? 'none' : '0.5px solid var(--ui-divider)',
          }}>
            <div style={{ fontSize: 13, color: 'var(--ui-text)', fontWeight: 600, letterSpacing: '-0.005em' }}>
              {cat.label}
            </div>
            {cat.examples && (
              <div style={{ fontSize: 12, color: 'var(--ui-text-muted)', marginTop: 3, lineHeight: 1.5 }}>
                {cat.examples.join(' · ')}
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}

window.PaletteScreen = PaletteScreen;
