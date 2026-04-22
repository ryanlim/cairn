// DryRunSheet — review-and-sync modal.
//
// Thumbnails are the primary affordance here (per brief: "the single most
// important safety affordance cairn can offer"). A responsive grid fills most
// of the sheet; per-asset filename stays visible on the tile so the user can
// cross-reference "IMG_2024 → my kid's birthday."
//
// Phases: review → confirming → running → done. Over-threshold state is
// surfaced inline at the top of review, not as a separate screen, so the user
// sees the candidates at the same time they see the warning.

function DryRunSheet({ data, libSize, settings, forceTripped, onClose, onConfirm }) {
  const { SAMPLE_CANDIDATES, LIBRARY_SIZE_DEFAULTS } = window.CAIRN_DATA;
  const lib = LIBRARY_SIZE_DEFAULTS[libSize];
  // In threshold app-state we show the tripped run — a larger candidate set
  // (the one that actually exceeded the cap), not the current small preview.
  const candidateCount = forceTripped
    ? Math.max(lib.candidates, Math.ceil(lib.matched * (settings.maxDeletePercent / 100) * 2.3))
    : lib.candidates;
  const assets = [];
  for (let i = 0; i < candidateCount; i++) {
    assets.push(SAMPLE_CANDIDATES[i % SAMPLE_CANDIDATES.length]);
  }
  const pct = (candidateCount / lib.matched) * 100;
  const overPct   = pct > settings.maxDeletePercent;
  const overFloor = candidateCount > settings.minDeleteFloor;
  const tripped   = forceTripped || (overPct && overFloor);
  const [phase, setPhase] = React.useState('review'); // review | confirming | running | done
  const [zoom, setZoom]   = React.useState(null);     // clicked asset for lightbox
  const [sort, setSort]   = React.useState('recent'); // recent | type

  const totalBytes  = assets.reduce((s, a) => s + a.bytes, 0);
  const livePairs   = assets.filter(a => a.kind === 'live-pair').length;
  const videoCount  = assets.filter(a => a.kind === 'video').length;

  const sorted = React.useMemo(() => {
    if (sort === 'type') {
      const order = { video: 0, 'live-pair': 1, photo: 2 };
      return [...assets].sort((a, b) => (order[a.kind] - order[b.kind]) || a.name.localeCompare(b.name));
    }
    return assets; // already recent-first
  }, [sort, libSize]);

  const go = () => setPhase('confirming');
  const realGo = () => {
    setPhase('running');
    setTimeout(() => setPhase('done'), 2200);
  };

  // ── Terminal phases ────────────────────────────────────────────────────
  if (phase === 'running' || phase === 'done') {
    const isDryLog = settings.dryRunByDefault;
    return (
      <div className="scrim" onClick={phase === 'done' ? onClose : undefined}>
        <div className="sheet" onClick={(e) => e.stopPropagation()} style={{ maxHeight: '70%' }}>
          <div className="sheet-grip"/>
          <div style={{ padding: '30px 28px 20px', textAlign: 'center' }}>
            {phase === 'running' ? (
              <>
                <div style={{ width: 48, height: 48, borderRadius: 999, background: 'var(--ui-surface-alt)', margin: '0 auto 18px', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                  <div style={{ animation: 'spin 900ms linear infinite', color: 'var(--ui-text-body)' }}>
                    <I.sync width="22" height="22"/>
                  </div>
                </div>
                <div style={{ fontSize: 20, fontWeight: 600, letterSpacing: '-0.015em' }}>
                  {isDryLog ? 'Recording preview' : 'Tagging and trashing'}
                </div>
                <div style={{ fontSize: 13, color: 'var(--ui-text-muted)', marginTop: 6 }}>
                  {isDryLog
                    ? `Nothing touched · ${candidateCount} assets noted`
                    : `Writing breadcrumb · ${candidateCount} assets`}
                </div>
                <style>{`@keyframes spin{to{transform:rotate(360deg)}}`}</style>
              </>
            ) : (
              <>
                <div style={{
                  width: 48, height: 48, borderRadius: 999,
                  background: isDryLog ? 'var(--ui-info-soft, color-mix(in oklab, var(--ui-info) 14%, var(--ui-surface)))' : 'var(--ui-verified-soft)',
                  color:      isDryLog ? 'var(--ui-info-ink)'      : 'var(--ui-verified-ink)',
                  margin: '0 auto 18px', display: 'flex', alignItems: 'center', justifyContent: 'center',
                }}>
                  {isDryLog ? <I.eye width="22" height="22" strokeWidth="2"/> : <I.check width="22" height="22" strokeWidth="2.2"/>}
                </div>
                <div style={{ fontSize: 20, fontWeight: 600, letterSpacing: '-0.015em' }}>
                  {isDryLog ? `${candidateCount} preview logged` : `${candidateCount} moved to trash`}
                </div>
                <div style={{ fontSize: 13, color: 'var(--ui-text-muted)', marginTop: 6, maxWidth: 280, margin: '6px auto 0' }}>
                  {isDryLog
                    ? <>Nothing touched on server. Turn off <span style={{ color: 'var(--ui-text)' }}>Dry-run by default</span> in Settings to actually trash.</>
                    : <>Tagged <span className="mono" style={{ fontSize: 11.5 }}>cairn/v1/run/…</span>. Recoverable in Immich trash for 30 days.</>}
                </div>
                <button className="btn btn-primary btn-block" style={{ marginTop: 22 }} onClick={() => { onConfirm(); onClose(); }}>Back to status</button>
              </>
            )}
          </div>
        </div>
      </div>
    );
  }

  // ── Review / confirm phase ─────────────────────────────────────────────
  return (
    <div className="scrim" onClick={phase === 'review' ? onClose : undefined}>
      <div className="sheet" onClick={(e) => e.stopPropagation()} style={{ maxHeight: '94%' }}>
        <div className="sheet-grip"/>

        {/* Header */}
        <div style={{ padding: '2px 20px 12px' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6 }}>
            <ModeChip dryRun={settings.dryRunByDefault} tripped={tripped}/>
            <button onClick={onClose} style={{ color: 'var(--ui-text-muted)' }}><I.close /></button>
          </div>
          <div style={{ fontSize: 22, fontWeight: 600, letterSpacing: '-0.02em', lineHeight: 1.15 }}>
            {tripped
              ? `${candidateCount} candidates is above your cap`
              : settings.dryRunByDefault
              ? `${candidateCount} would move to trash`
              : `Trash ${candidateCount} on Immich?`}
          </div>
          <div style={{ fontSize: 13, color: 'var(--ui-text-muted)', marginTop: 4 }}>
            {tripped
              ? 'Nothing was touched. Review the photos before deciding.'
              : settings.dryRunByDefault
              ? `${fmtBytes(totalBytes)} · preview only, nothing will be touched on your server`
              : `${fmtBytes(totalBytes)} · stays in Immich trash for 30 days`}
          </div>
        </div>

        {/* Tripped banner — inline, with explicit reason */}
        {tripped && (
          <div style={{ padding: '0 16px 12px' }}>
            <div className="callout callout-rust" style={{ display: 'flex', gap: 10 }}>
              <div><I.warn /></div>
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 600, marginBottom: 2 }}>
                  {pct.toFixed(2)}% of matched would be trashed
                </div>
                <div style={{ opacity: 0.9, lineHeight: 1.45 }}>
                  Your cap is {settings.maxDeletePercent.toFixed(1)}% (and {settings.minDeleteFloor}+ assets).
                  Look through the grid — does it match what you deleted on your phone?
                </div>
              </div>
            </div>
          </div>
        )}

        {/* Compact numerical summary (always visible) */}
        <div style={{ padding: '0 16px 12px' }}>
          <div className="card" style={{ padding: 12, display: 'flex', gap: 12 }}>
            <MiniStat
              label={tripped ? 'Over cap' : 'Of matched'}
              value={pct.toFixed(2) + '%'}
              sub={`cap ${settings.maxDeletePercent.toFixed(1)}%`}
              tone={tripped ? 'danger' : undefined}
            />
            <div style={{ width: 0.5, background: 'var(--ui-divider)' }}/>
            <MiniStat label="Live pairs" value={String(livePairs)} sub="still + motion"/>
            <div style={{ width: 0.5, background: 'var(--ui-divider)' }}/>
            <MiniStat label="Videos" value={String(videoCount)}/>
            <div style={{ width: 0.5, background: 'var(--ui-divider)' }}/>
            <MiniStat label="Freed" value={fmtBytes(totalBytes).split(' ')[0]} sub={fmtBytes(totalBytes).split(' ')[1]}/>
          </div>
        </div>

        {/* Grid header with sort */}
        <div style={{ padding: '0 20px 8px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <div className="uc" style={{ color: 'var(--ui-text-quiet)' }}>
            {candidateCount} photos · tap to zoom
          </div>
          <div style={{ display: 'flex', gap: 2, background: 'var(--ui-bg)', borderRadius: 7, padding: 2 }}>
            <SegBtn active={sort === 'recent'} onClick={() => setSort('recent')}>Recent</SegBtn>
            <SegBtn active={sort === 'type'}   onClick={() => setSort('type')}>By type</SegBtn>
          </div>
        </div>

        {/* Thumbnail grid — the heart of the sheet */}
        <div style={{ flex: 1, overflowY: 'auto', padding: '0 16px 12px' }}>
          <div className="card" style={{ padding: 10, marginBottom: 12 }}>
            <div style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(auto-fill, minmax(78px, 1fr))',
              gap: 6,
            }}>
              {sorted.map((a) => (
                <AssetThumbCell
                  key={a.name}
                  asset={a}
                  onClick={() => setZoom(a)}
                />
              ))}
            </div>
          </div>

          {/* Safety-checks card stays — receipts not confetti */}
          <div className="uc" style={{ color: 'var(--ui-text-quiet)', padding: '6px 4px 8px' }}>
            Safety checks
          </div>
          <div className="card" style={{ overflow: 'hidden', marginBottom: 16 }}>
            <CheckRow label={`Under ${settings.maxDeletePercent.toFixed(1)}% cap`} pass={!overPct}/>
            <CheckRow label={`Over ${settings.minDeleteFloor}-asset floor`} pass={overFloor}/>
            <CheckRow label="Server returned > 0 assets" pass={true}/>
            <CheckRow label="Photos access is Full" pass={true}/>
            <CheckRow label="Purview set populated" pass={true}/>
          </div>
        </div>

        {/* Actions */}
        <div style={{ padding: '14px 16px 0', borderTop: '0.5px solid var(--ui-divider)', background: 'var(--ui-surface)' }}>
          {phase === 'review' ? (
            tripped ? (
              <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                <div style={{ display: 'flex', gap: 10 }}>
                  <button className="btn btn-secondary" style={{ flex: 1 }} onClick={onClose}>Cancel</button>
                  <button
                    className="btn btn-primary"
                    style={{ flex: 1.3 }}
                    onClick={go}>
                    <I.warn width="16" height="16"/>
                    Proceed anyway
                  </button>
                </div>
                <button className="btn btn-quiet btn-small" style={{ width: '100%' }}>
                  Raise threshold to {Math.ceil(pct * 1.2)}% and retry
                </button>
              </div>
            ) : (
              <div style={{ display: 'flex', gap: 10 }}>
                <button className="btn btn-secondary" style={{ flex: 1 }} onClick={onClose}>Not now</button>
                {settings.dryRunByDefault ? (
                  <button className="btn btn-primary" style={{ flex: 1.5 }} onClick={realGo}>
                    <I.eye width="16" height="16"/>
                    Log dry-run
                  </button>
                ) : (
                  <button className="btn btn-danger" style={{ flex: 1.5 }} onClick={go}>
                    <I.trash width="16" height="16"/>
                    Move {candidateCount} to trash
                  </button>
                )}
              </div>
            )
          ) : (
            <div>
              <div className="callout callout-rust" style={{ marginBottom: 12, display: 'flex', gap: 10 }}>
                <I.warn />
                <div>
                  <div style={{ fontWeight: 600, marginBottom: 2 }}>Confirm once more</div>
                  <div style={{ opacity: 0.9 }}>
                    cairn will tag <span className="mono" style={{ fontSize: 11.5 }}>cairn/v1/run/…</span> then
                    move {candidateCount} asset{candidateCount === 1 ? '' : 's'} to Immich trash.
                  </div>
                </div>
              </div>
              <div style={{ display: 'flex', gap: 10 }}>
                <button className="btn btn-secondary" style={{ flex: 1 }} onClick={() => setPhase('review')}>Back</button>
                <button className="btn btn-danger" style={{ flex: 1.5 }} onClick={realGo}>
                  Yes, trash {candidateCount}
                </button>
              </div>
            </div>
          )}
        </div>
      </div>

      {/* Lightbox */}
      {zoom && <ThumbZoom asset={zoom} onClose={() => setZoom(null)}/>}
    </div>
  );
}

// ── Tile w/ filename ──────────────────────────────────────────────────────
function AssetThumbCell({ asset, onClick }) {
  return (
    <div onClick={onClick} style={{ cursor: 'pointer', display: 'flex', flexDirection: 'column', gap: 4 }}>
      <AssetThumb asset={asset} size={76}/>
      <div
        className="mono"
        title={asset.name}
        style={{
          fontSize: 9.5,
          color: 'var(--ui-text-muted)',
          letterSpacing: '0.01em',
          overflow: 'hidden',
          textOverflow: 'ellipsis',
          whiteSpace: 'nowrap',
          textAlign: 'center',
          lineHeight: 1.2,
        }}>
        {asset.name.replace(/\.[^.]+$/, '')}
      </div>
    </div>
  );
}

// ── Compact stat used on the summary row ─────────────────────────────────
function MiniStat({ label, value, sub, tone }) {
  const color = tone === 'danger' ? 'var(--ui-danger-ink)' : 'var(--ui-text)';
  return (
    <div style={{ flex: 1, minWidth: 0 }}>
      <div className="uc" style={{ color: 'var(--ui-text-quiet)', marginBottom: 4 }}>{label}</div>
      <div className="tabular" style={{
        fontSize: 18, fontWeight: 600, letterSpacing: '-0.02em', lineHeight: 1,
        color,
        fontFamily: 'var(--font-display)',
        whiteSpace: 'nowrap',
      }}>{value}</div>
      {sub && <div style={{ fontSize: 10.5, color: 'var(--ui-text-quiet)', marginTop: 3, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{sub}</div>}
    </div>
  );
}

// ── Small segmented button ───────────────────────────────────────────────
function SegBtn({ active, onClick, children }) {
  return (
    <button onClick={onClick} style={{
      padding: '4px 10px',
      fontSize: 11,
      fontWeight: 500,
      color: active ? 'var(--ui-text)' : 'var(--ui-text-muted)',
      background: active ? 'var(--ui-surface)' : 'transparent',
      borderRadius: 5,
      boxShadow: active ? '0 1px 2px rgba(0,0,0,0.06)' : 'none',
    }}>{children}</button>
  );
}

// ── Lightbox: tapped-asset zoom with metadata ─────────────────────────────
function ThumbZoom({ asset, onClose }) {
  return (
    <div
      onClick={onClose}
      style={{
        position: 'absolute', inset: 0,
        background: 'rgba(10, 8, 6, 0.82)',
        backdropFilter: 'blur(12px)',
        WebkitBackdropFilter: 'blur(12px)',
        zIndex: 200,
        display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
        padding: 24,
        animation: 'fadeIn 160ms ease',
      }}>
      <div onClick={(e) => e.stopPropagation()} style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14, maxWidth: '100%' }}>
        <AssetThumb asset={asset} size={260}/>
        <div style={{ textAlign: 'center' }}>
          <div className="mono" style={{ fontSize: 13, color: '#fff', fontWeight: 500 }}>{asset.name}</div>
          <div style={{ fontSize: 12, color: 'rgba(255,255,255,0.65)', marginTop: 4, display: 'flex', gap: 8, justifyContent: 'center' }}>
            <span>{asset.date}</span>
            <span>·</span>
            <span>{fmtBytes(asset.bytes)}</span>
            {asset.kind === 'live-pair' && <><span>·</span><span>live pair</span></>}
            {asset.kind === 'video' && asset.durationSec && <><span>·</span><span>{asset.durationSec}s video</span></>}
          </div>
          <div className="mono" style={{ fontSize: 10.5, color: 'rgba(255,255,255,0.45)', marginTop: 6 }}>
            {asset.checksum}
          </div>
        </div>
        <button
          onClick={onClose}
          style={{
            marginTop: 4,
            padding: '8px 16px',
            fontSize: 13,
            color: '#fff',
            background: 'rgba(255,255,255,0.12)',
            border: '0.5px solid rgba(255,255,255,0.18)',
            borderRadius: 10,
          }}>Close</button>
      </div>
    </div>
  );
}

// ── Shared: pass/fail row ─────────────────────────────────────────────────
function CheckRow({ label, pass }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '11px 14px', borderBottom: '0.5px solid var(--ui-divider)' }}>
      <div style={{
        width: 20, height: 20, borderRadius: 999,
        background: pass ? 'var(--ui-verified-soft)' : 'var(--ui-danger-soft)',
        color:      pass ? 'var(--ui-verified-ink)'  : 'var(--ui-danger-ink)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        {pass ? <I.check width="12" height="12" strokeWidth="2.5"/> : <I.close width="12" height="12" strokeWidth="2.5"/>}
      </div>
      <div style={{ flex: 1, fontSize: 14, color: 'var(--ui-text-body)' }}>{label}</div>
    </div>
  );
}

window.DryRunSheet = DryRunSheet;
window.ThumbZoom   = ThumbZoom;

// ── ModeChip ─────────────────────────────────────────────────────────────
// Makes it unambiguous which mode the sheet is in. Three states:
//   · tripped       → "Aborted", rust
//   · dry-run mode  → "Dry-run mode", info, with dot
//   · live mode     → "Live · will trash", rust-ink subtle
function ModeChip({ dryRun, tripped }) {
  if (tripped) {
    return (
      <div style={{
        display: 'inline-flex', alignItems: 'center', gap: 6,
        fontSize: 10.5, fontWeight: 600, letterSpacing: '0.08em', textTransform: 'uppercase',
        color: 'var(--ui-danger-ink)',
        background: 'var(--ui-danger-soft)',
        padding: '4px 9px',
        borderRadius: 999,
      }}>
        <I.warn width="11" height="11" strokeWidth="2.4"/>
        Safety rail tripped
      </div>
    );
  }
  if (dryRun) {
    return (
      <div style={{
        display: 'inline-flex', alignItems: 'center', gap: 6,
        fontSize: 10.5, fontWeight: 600, letterSpacing: '0.08em', textTransform: 'uppercase',
        color: 'var(--ui-info-ink)',
        background: 'color-mix(in oklab, var(--ui-info) 14%, var(--ui-surface))',
        padding: '4px 9px',
        borderRadius: 999,
        border: '0.5px solid color-mix(in oklab, var(--ui-info-ink) 25%, transparent)',
      }}>
        <I.eye width="11" height="11" strokeWidth="2"/>
        Dry-run mode
      </div>
    );
  }
  return (
    <div style={{
      display: 'inline-flex', alignItems: 'center', gap: 6,
      fontSize: 10.5, fontWeight: 600, letterSpacing: '0.08em', textTransform: 'uppercase',
      color: 'var(--rust-ink)',
      background: 'color-mix(in oklab, var(--rust) 10%, var(--ui-surface))',
      padding: '4px 9px',
      borderRadius: 999,
      border: '0.5px solid color-mix(in oklab, var(--rust-ink) 22%, transparent)',
    }}>
      <span style={{
        width: 6, height: 6, borderRadius: 999,
        background: 'var(--rust-ink)',
      }}/>
      Live · will trash
    </div>
  );
}

window.ModeChip = ModeChip;
