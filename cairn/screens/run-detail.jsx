// RunDetailSheet — a run's full detail with selection-driven actions.
//
// When any asset is selected, the footer switches from Close/Restore to a
// contextual action bar: Exclude · Open in Immich · Copy · Restore.
//
//   · Restore — moves back out of trash. Disabled unless the run is a trash
//     run. (Dry-runs and aborted runs had nothing to undo.)
//   · Exclude — adds filenames to the allowlist so future runs skip them.
//     Available on every run type: on a dry-run this is the primary triage
//     action ("select the ones I want to keep, exclude, then run for real").
//   · Open in Immich — mocked deep-link. Single-asset selection opens the
//     asset; multi opens the run's breadcrumb tag view.
//   · Copy — copies filenames (one per line) to the clipboard.
//
// All actions confirm via <Toast>. Exclude and Restore include Undo.

function RunDetailSheet({ run, onClose, excluded, onExclude, onUnexclude, settings }) {
  const { SAMPLE_CANDIDATES } = window.CAIRN_DATA;
  const [selected, setSelected] = React.useState(new Set());
  const [restored, setRestored] = React.useState(new Set()); // names that have been restored
  const [filter, setFilter]     = React.useState('');
  const [zoom, setZoom]         = React.useState(null);
  const [justRestored, setJustRestored] = React.useState(null); // count flash

  // Assets in this run: for runs with trashed > 0, use top N. For aborted runs,
  // show the candidates that would have been affected so the user can inspect.
  const assets = React.useMemo(() => {
    if (run.status === 'aborted') return SAMPLE_CANDIDATES.slice(0, 14);
    return SAMPLE_CANDIDATES.slice(0, run.trashed);
  }, [run]);

  const filtered = React.useMemo(() => {
    const q = filter.trim().toLowerCase();
    if (!q) return assets;
    return assets.filter(a => a.name.toLowerCase().includes(q));
  }, [filter, assets]);

  const selectableAssets = filtered.filter(a => !restored.has(a.name));
  const allVisibleSelected = selectableAssets.length > 0 && selectableAssets.every(a => selected.has(a.name));

  const toggle = (name) => {
    if (restored.has(name)) return;
    const next = new Set(selected);
    next.has(name) ? next.delete(name) : next.add(name);
    setSelected(next);
  };

  const selectAllVisible = () => {
    if (allVisibleSelected) {
      const next = new Set(selected);
      selectableAssets.forEach(a => next.delete(a.name));
      setSelected(next);
    } else {
      const next = new Set(selected);
      selectableAssets.forEach(a => next.add(a.name));
      setSelected(next);
    }
  };

  const canRestore = run.trashed > 0 && !run.dryRun && run.status !== 'aborted';
  const hasSelection = selected.size > 0;

  // Live-photo expansion: selecting a live-pair asset implicitly includes its
  // paired motion video in any server-side action (restore / exclude). We
  // surface the actual asset total in the action bar so the user sees the
  // real count before tapping.
  const pairedInSelection = React.useMemo(() => {
    let c = 0;
    selected.forEach((name) => {
      const a = assets.find(x => x.name === name);
      if (a?.paired) c++;
    });
    return c;
  }, [selected, assets]);
  const expandedCount = selected.size + pairedInSelection;

  // --- Actions ---

  const doRestore = () => {
    const toRestore = Array.from(selected);
    const next = new Set(restored);
    toRestore.forEach(n => next.add(n));
    setRestored(next);
    setSelected(new Set());
    setJustRestored(toRestore.length);
    setTimeout(() => setJustRestored(null), 2400);
    window.showToast?.({
      title: `${toRestore.length} restored`,
      detail: 'Back in your active library on the server.',
      tone: 'success',
      action: {
        label: 'Undo',
        onClick: () => {
          // Roll back the restore set
          setRestored((r) => {
            const rev = new Set(r);
            toRestore.forEach(n => rev.delete(n));
            return rev;
          });
          window.showToast?.({ title: 'Restore undone', tone: 'info' });
        },
      },
    });
  };

  const doExclude = () => {
    const toExclude = Array.from(selected);
    onExclude?.(toExclude, { runId: run.id });
    setSelected(new Set());
    window.showToast?.({
      title: `${toExclude.length} excluded`,
      detail: toExclude.length === 1
        ? `${toExclude[0]} · future runs will skip it`
        : 'Future runs will skip these assets.',
      tone: 'info',
      action: {
        label: 'Undo',
        onClick: () => {
          onUnexclude?.(toExclude);
          window.showToast?.({ title: 'Exclusion undone', tone: 'info' });
        },
      },
    });
  };

  const doCopy = async () => {
    const names = Array.from(selected).join('\n');
    try {
      await navigator.clipboard.writeText(names);
      window.showToast?.({
        title: `Copied ${selected.size} filename${selected.size === 1 ? '' : 's'}`,
        detail: selected.size === 1 ? Array.from(selected)[0] : 'One per line, ready to paste.',
        tone: 'info',
      });
    } catch (e) {
      // Clipboard can fail in iframe sandboxes; offer a textarea fallback hint
      window.showToast?.({
        title: 'Clipboard unavailable',
        detail: 'Your browser blocked the copy. Try again from the device.',
        tone: 'danger',
      });
    }
  };

  const doOpenInImmich = () => {
    const serverBase = (settings?.serverUrl || 'https://immich.home.arpa').replace(/\/$/, '');
    let url;
    let detail;
    if (selected.size === 1 && run.tag) {
      // Single-asset deep link via breadcrumb tag + filename filter
      url = `${serverBase}/search?tag=${encodeURIComponent(run.tag)}&q=${encodeURIComponent(Array.from(selected)[0])}`;
      detail = 'Opens this asset in Immich search.';
    } else if (run.tag) {
      url = `${serverBase}/tags?name=${encodeURIComponent(run.tag.split('/').slice(-1)[0])}`;
      detail = `Opens this run's tag in Immich (${selected.size} assets).`;
    } else {
      // No breadcrumb (dry-runs / aborted) — fall back to trash view
      url = `${serverBase}/trash`;
      detail = "Run had no breadcrumb — opening Immich's trash view.";
    }
    window.showToast?.({
      title: 'Opening Immich…',
      detail,
      tone: 'info',
    });
    // In the real app this would hand off to the system opener; in the
    // prototype we log so devs can see the constructed URL.
    console.log('[cairn prototype] would open:', url);
  };

  const runKind =
    run.status === 'aborted' ? 'Aborted run' :
    run.dryRun ? 'Dry-run' :
    'Trash run';

  const assetState = (a) => {
    if (restored.has(a.name)) return 'restored';
    if (excluded?.has(a.name)) return 'excluded';
    if (run.status === 'aborted') return undefined;     // never touched
    if (!run.dryRun && run.trashed > 0) return 'trashed';
    return undefined;
  };

  return (
    <div className="scrim" onClick={onClose}>
      <div className="sheet" onClick={(e) => e.stopPropagation()} style={{ maxHeight: '94%' }}>
        <div className="sheet-grip"/>

        {/* Header */}
        <div style={{ padding: '2px 20px 10px' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 4 }}>
            <div className="uc" style={{ color: 'var(--ui-text-quiet)' }}>{runKind}</div>
            <button onClick={onClose} style={{ color: 'var(--ui-text-muted)' }}><I.close /></button>
          </div>
          <div style={{ fontSize: 22, fontWeight: 600, letterSpacing: '-0.02em' }}>
            {run.status === 'aborted'
              ? 'Stopped by safety rail'
              : run.dryRun
              ? 'Preview only — nothing touched'
              : `${run.trashed} asset${run.trashed === 1 ? '' : 's'} trashed`}
          </div>
          <div style={{ fontSize: 13, color: 'var(--ui-text-muted)', marginTop: 4 }}>
            {fmtDate(run.startedAt, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })}
            {run.durationMs > 0 && ` · ${(run.durationMs / 1000).toFixed(2)}s`}
          </div>
        </div>

        {/* Meta chips */}
        <div style={{ padding: '0 20px 10px', display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <span className="chip"><span className="mono">{run.id.slice(-8)}</span></span>
          {run.tag && (
            <span className="chip verified">
              <I.tag width="11" height="11"/> breadcrumb set
            </span>
          )}
          {restored.size > 0 && (
            <span className="chip info">{restored.size} restored</span>
          )}
        </div>

        {/* Aborted callout */}
        {run.status === 'aborted' && (
          <div style={{ padding: '0 16px 10px' }}>
            <div className="callout callout-rust" style={{ display: 'flex', gap: 10 }}>
              <div><I.warn /></div>
              <div>
                <div style={{ fontWeight: 600, marginBottom: 2 }}>Percent threshold exceeded</div>
                <div style={{ opacity: 0.9 }}>2.3% of matched assets would have been trashed. Your cap is 1.0%. Nothing was touched.</div>
              </div>
            </div>
          </div>
        )}

        {/* Just-restored flash */}
        {justRestored !== null && (
          <div style={{ padding: '0 16px 10px' }}>
            <div className="callout callout-moss fade-in" style={{ display: 'flex', gap: 10 }}>
              <I.checkCircle />
              <div>
                <div style={{ fontWeight: 600 }}>{justRestored} restored</div>
                <div style={{ opacity: 0.85 }}>Moved out of Immich trash, back to active library.</div>
              </div>
            </div>
          </div>
        )}

        {/* Filter + select-all */}
        {assets.length > 0 && (
          <div style={{ padding: '0 20px 8px', display: 'flex', alignItems: 'center', gap: 8 }}>
            <div style={{
              flex: 1,
              display: 'flex',
              alignItems: 'center',
              gap: 7,
              background: 'var(--ui-bg)',
              border: '0.5px solid var(--ui-divider)',
              borderRadius: 9,
              padding: '6px 10px',
              height: 32,
            }}>
              <I.search width="13" height="13" style={{ color: 'var(--ui-text-quiet)' }}/>
              <input
                value={filter}
                onChange={(e) => setFilter(e.target.value)}
                placeholder="Filter by filename…"
                className="mono"
                style={{
                  flex: 1, minWidth: 0,
                  background: 'transparent',
                  outline: 'none',
                  border: 'none',
                  fontSize: 12,
                  color: 'var(--ui-text)',
                }}
              />
              {filter && (
                <button onClick={() => setFilter('')} style={{ color: 'var(--ui-text-quiet)' }}>
                  <I.close width="12" height="12"/>
                </button>
              )}
            </div>
            {selectableAssets.length > 0 && (
              <button
                className="btn btn-quiet btn-small"
                onClick={selectAllVisible}
                style={{ fontSize: 11, padding: '0 10px', height: 32 }}>
                {allVisibleSelected ? 'Deselect' : 'Select all'}
              </button>
            )}
          </div>
        )}

        {/* Selection count row */}
        {assets.length > 0 && (
          <div style={{ padding: '0 20px 8px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
            <div className="uc" style={{ color: 'var(--ui-text-quiet)' }}>
              {filtered.length === assets.length
                ? `${assets.length} assets`
                : `${filtered.length} of ${assets.length} match`}
              {selected.size > 0 && ` · ${selected.size} selected`}
            </div>
            {run.trashed > 0 && !run.dryRun && run.status !== 'aborted' && (
              <div className="uc" style={{ color: 'var(--ui-text-quiet)' }}>
                <span className="dot" style={{ background: 'var(--ui-text-muted)', marginRight: 5 }}/>
                In trash
              </div>
            )}
          </div>
        )}

        {/* Asset grid */}
        <div style={{ flex: 1, overflowY: 'auto', padding: '0 16px 12px' }}>
          {assets.length > 0 && (
            <div className="card" style={{ padding: 10, marginBottom: 12 }}>
              {filtered.length === 0 ? (
                <div style={{ padding: '22px 8px', textAlign: 'center', fontSize: 13, color: 'var(--ui-text-muted)' }}>
                  No filename matches "{filter}".
                </div>
              ) : (
                <div style={{
                  display: 'grid',
                  gridTemplateColumns: 'repeat(auto-fill, minmax(78px, 1fr))',
                  gap: 6,
                }}>
                  {filtered.map((a) => (
                    <div key={a.name} style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                      <AssetThumb
                        asset={a}
                        size={76}
                        state={assetState(a)}
                        selected={selected.has(a.name)}
                        onClick={() => toggle(a.name)}
                      />
                      <div
                        className="mono"
                        onClick={() => setZoom(a)}
                        title={a.name}
                        style={{
                          fontSize: 9.5,
                          color: restored.has(a.name)
                            ? 'var(--ui-verified-ink)'
                            : excluded?.has(a.name)
                            ? 'var(--ui-info-ink)'
                            : 'var(--ui-text-muted)',
                          letterSpacing: '0.01em',
                          overflow: 'hidden',
                          textOverflow: 'ellipsis',
                          whiteSpace: 'nowrap',
                          textAlign: 'center',
                          lineHeight: 1.2,
                          cursor: 'pointer',
                        }}>
                        {a.name.replace(/\.[^.]+$/, '')}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

          {/* Run metadata card */}
          <div className="uc" style={{ color: 'var(--ui-text-quiet)', padding: '6px 4px 8px' }}>Run metadata</div>
          <div className="card" style={{ marginBottom: 12, overflow: 'hidden' }}>
            <KeyValRow label="Run ID"   value={run.id.slice(-8)} mono/>
            <KeyValRow label="Started"  value={fmtDate(run.startedAt)}/>
            {run.durationMs > 0 && <KeyValRow label="Duration" value={`${(run.durationMs/1000).toFixed(2)}s`}/>}
            {run.tag && <KeyValRow label="Breadcrumb" value={run.tag.split('/').slice(-1)[0]} mono/>}
            <KeyValRow label="Notes" value={run.notes}/>
          </div>

          {/* Server breadcrumb card */}
          <div className="uc" style={{ color: 'var(--ui-text-quiet)', padding: '6px 4px 8px' }}>Server-side breadcrumb</div>
          <div className="card" style={{ padding: 14, marginBottom: 16 }}>
            <div className="mono" style={{ fontSize: 12, color: 'var(--ui-text-body)', lineHeight: 1.5, wordBreak: 'break-all' }}>
              {run.tag || 'none — this run did not tag the server'}
            </div>
            <div style={{ fontSize: 12, color: 'var(--ui-text-muted)', marginTop: 6, lineHeight: 1.5 }}>
              Find these in Immich's Tags view. Assets stay in trash for 30 days.
            </div>
          </div>
        </div>

        {/* Footer — swaps between idle and selection-action bar */}
        {hasSelection ? (
          <SelectionActionBar
            selectedCount={selected.size}
            pairedCount={pairedInSelection}
            canRestore={canRestore}
            onClear={() => setSelected(new Set())}
            onExclude={doExclude}
            onOpen={doOpenInImmich}
            onCopy={doCopy}
            onRestore={doRestore}
          />
        ) : canRestore ? (
          <div style={{ padding: '14px 16px 0', borderTop: '0.5px solid var(--ui-divider)', display: 'flex', gap: 10, background: 'var(--ui-surface)' }}>
            <button className="btn btn-secondary" style={{ flex: 1 }} onClick={onClose}>Close</button>
            <div style={{ flex: 1.4, height: 44, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13, color: 'var(--ui-text-muted)' }}>
              Select assets to act on them
            </div>
          </div>
        ) : (
          <div style={{ padding: '14px 16px 0', borderTop: '0.5px solid var(--ui-divider)', background: 'var(--ui-surface)' }}>
            <button className="btn btn-secondary btn-block" onClick={onClose}>Close</button>
          </div>
        )}
      </div>

      {zoom && <ThumbZoom asset={zoom} onClose={() => setZoom(null)}/>}
    </div>
  );
}

// Contextual action bar rendered when the user has selected ≥1 asset. Shows
// a count pill on the left, a Clear, and icon+label buttons for each action.
// Restore is primary when available; otherwise Exclude takes visual primacy.
function SelectionActionBar({ selectedCount, pairedCount = 0, canRestore, onClear, onExclude, onOpen, onCopy, onRestore }) {
  const expandedCount = selectedCount + pairedCount;
  return (
    <div style={{
      borderTop: '0.5px solid var(--ui-divider)',
      background: 'var(--ui-surface)',
      padding: '10px 14px 0',
    }}>
      {/* Selection count + clear */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
          <div style={{
            fontSize: 12, fontWeight: 600,
            color: 'var(--ui-primary-ink)',
            background: 'var(--ui-primary-soft, color-mix(in oklab, var(--ui-primary) 14%, var(--ui-surface)))',
            padding: '3px 9px',
            borderRadius: 999,
          }}>
            {selectedCount} selected
          </div>
          {pairedCount > 0 && (
            <div
              title={`${pairedCount} Live Photo${pairedCount === 1 ? '' : 's'} in selection — each pulls its paired motion video, so actions affect ${expandedCount} server assets.`}
              style={{
                fontSize: 11, fontWeight: 500,
                color: 'var(--ui-info-ink)',
                background: 'color-mix(in oklab, var(--ui-info) 14%, var(--ui-surface))',
                padding: '3px 8px',
                borderRadius: 999,
                display: 'flex', alignItems: 'center', gap: 5,
                lineHeight: 1.2,
              }}>
              <span style={{
                width: 5, height: 5, borderRadius: 999,
                background: 'var(--ui-info-ink)',
                flexShrink: 0,
              }}/>
              +{pairedCount} paired video{pairedCount === 1 ? '' : 's'} = {expandedCount}
            </div>
          )}
          <button
            onClick={onClear}
            style={{
              fontSize: 12, color: 'var(--ui-text-muted)',
              background: 'transparent', border: 'none',
              padding: '3px 4px', cursor: 'pointer',
            }}>
            Clear
          </button>
        </div>
      </div>

      {/* Action row */}
      <div style={{ display: 'grid', gridTemplateColumns: `repeat(${canRestore ? 4 : 3}, 1fr)`, gap: 6 }}>
        <ActionButton
          icon={<I.shield width="18" height="18"/>}
          label="Exclude"
          tone={canRestore ? 'default' : 'primary'}
          onClick={onExclude}
        />
        <ActionButton
          icon={<I.link width="18" height="18"/>}
          label="Open"
          tone="default"
          onClick={onOpen}
        />
        <ActionButton
          icon={<I.doc width="18" height="18"/>}
          label="Copy"
          tone="default"
          onClick={onCopy}
        />
        {canRestore && (
          <ActionButton
            icon={<I.restore width="18" height="18"/>}
            label="Restore"
            tone="primary"
            onClick={onRestore}
          />
        )}
      </div>
    </div>
  );
}

function ActionButton({ icon, label, tone = 'default', onClick }) {
  const isPrimary = tone === 'primary';
  return (
    <button
      onClick={onClick}
      style={{
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        gap: 4,
        padding: '8px 4px 10px',
        background: isPrimary ? 'var(--ui-primary)' : 'var(--ui-bg)',
        color: isPrimary ? 'var(--ui-primary-ink)' : 'var(--ui-text)',
        border: isPrimary ? 'none' : '0.5px solid var(--ui-divider)',
        borderRadius: 10,
        cursor: 'pointer',
        fontSize: 11,
        fontWeight: 600,
        letterSpacing: '0.02em',
        transition: 'transform 80ms',
      }}
      onMouseDown={(e) => e.currentTarget.style.transform = 'scale(0.97)'}
      onMouseUp={(e) => e.currentTarget.style.transform = ''}
      onMouseLeave={(e) => e.currentTarget.style.transform = ''}>
      {icon}
      {label}
    </button>
  );
}

window.RunDetailSheet = RunDetailSheet;
