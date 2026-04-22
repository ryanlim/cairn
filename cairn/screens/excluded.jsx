// ExcludedScreen — the allowlist: filenames that future runs will skip.
//
// Reachable from Settings → Safety rails → Excluded assets.
//
// Two sources feed this list today:
//   · Manual exclusion from a run detail (primary flow)
//   · (Future) rule-based excludes like "never trash videos > 30s"
//
// We render each entry with its thumbnail + filename + "excluded from <run id>"
// context, so users can see WHY something is protected and unexclude with one
// tap. The page shows an empty state when nothing is excluded.

function ExcludedScreen({ excluded, excludeMeta, onUnexclude, onBack }) {
  const { SAMPLE_CANDIDATES } = window.CAIRN_DATA;
  const names = Array.from(excluded);

  // Join metadata — find the asset record and the "added by" run context
  const entries = names
    .map((name) => {
      const asset = SAMPLE_CANDIDATES.find(a => a.name === name);
      const meta = excludeMeta?.[name];
      return asset ? { asset, meta } : null;
    })
    .filter(Boolean);

  const unexcludeAll = () => {
    if (!confirm(`Unexclude all ${entries.length} assets? They'll be eligible for future runs again.`)) return;
    onUnexclude?.(names);
    window.showToast?.({ title: 'All exclusions removed', tone: 'info' });
  };

  return (
    <div className="screen fade-in">
      <AppHeader
        title="Excluded"
        subtitle={entries.length === 0
          ? 'Nothing excluded — every indexed asset is fair game'
          : `${entries.length} asset${entries.length === 1 ? '' : 's'} protected from future runs`}
        leading={
          <button onClick={onBack} style={{
            display: 'flex', alignItems: 'center', gap: 4,
            color: 'var(--ui-text-body)', fontSize: 15,
            background: 'transparent', border: 'none', cursor: 'pointer',
            padding: '4px 0',
          }}>
            <I.chevron width="16" height="16" style={{ transform: 'rotate(180deg)' }}/>
            Settings
          </button>
        }
      />

      {entries.length === 0 ? (
        <EmptyState/>
      ) : (
        <>
          {/* Explainer card */}
          <div style={{ padding: '0 16px 12px' }}>
            <div className="card" style={{
              padding: '12px 14px',
              display: 'flex', gap: 10, alignItems: 'flex-start',
              background: 'var(--ui-info-soft)',
              border: '0.5px solid color-mix(in oklab, var(--ui-info) 20%, transparent)',
            }}>
              <div style={{ color: 'var(--ui-info-ink)', marginTop: 1 }}>
                <I.shield width="16" height="16"/>
              </div>
              <div style={{ fontSize: 12.5, color: 'var(--ui-info-ink)', lineHeight: 1.5 }}>
                Excluded assets stay indexed — cairn still knows they exist —
                but every future reconcile will skip them. Useful for photos
                you plan to re-trash yourself, or anything you'd rather keep on
                server even if it's gone from the phone.
              </div>
            </div>
          </div>

          <div className="keyline" style={{
            display: 'flex', alignItems: 'center', justifyContent: 'space-between',
            paddingRight: 16,
          }}>
            <span>Protected assets</span>
            <button
              onClick={unexcludeAll}
              style={{
                fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.09em',
                color: 'var(--ui-text-muted)',
                background: 'transparent', border: 'none',
                cursor: 'pointer', fontWeight: 600,
              }}>
              Clear all
            </button>
          </div>

          <div style={{ padding: '0 16px 20px' }}>
            <div className="card" style={{ overflow: 'hidden' }}>
              {entries.map((e, i) => (
                <ExcludedRow
                  key={e.asset.name}
                  asset={e.asset}
                  meta={e.meta}
                  isLast={i === entries.length - 1}
                  onRemove={() => {
                    onUnexclude?.([e.asset.name]);
                    window.showToast?.({
                      title: `${e.asset.name} is back in scope`,
                      detail: 'Future runs can trash this again.',
                      tone: 'info',
                    });
                  }}
                />
              ))}
            </div>
          </div>
        </>
      )}

      <div style={{ height: 40 }}/>
    </div>
  );
}

function ExcludedRow({ asset, meta, isLast, onRemove }) {
  const sizeMB = (asset.bytes / 1_048_576).toFixed(1);
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '12px 14px',
      borderBottom: isLast ? 'none' : '0.5px solid var(--ui-divider)',
    }}>
      <AssetThumb asset={asset} size={44}/>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div className="mono" style={{
          fontSize: 13, color: 'var(--ui-text)',
          overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          letterSpacing: '-0.005em',
        }}>
          {asset.name}
        </div>
        <div style={{ fontSize: 11.5, color: 'var(--ui-text-muted)', marginTop: 2, display: 'flex', gap: 8 }}>
          <span>{asset.kind}</span>
          <span>·</span>
          <span>{sizeMB} MB</span>
          {meta?.runId && (
            <>
              <span>·</span>
              <span>from run <span className="mono">{meta.runId.slice(-8)}</span></span>
            </>
          )}
        </div>
      </div>
      <button
        onClick={onRemove}
        aria-label={`Remove ${asset.name} from excluded list`}
        style={{
          padding: '6px 10px',
          fontSize: 11,
          fontWeight: 600,
          color: 'var(--ui-text-body)',
          background: 'var(--ui-bg)',
          border: '0.5px solid var(--ui-divider)',
          borderRadius: 7,
          cursor: 'pointer',
          textTransform: 'uppercase',
          letterSpacing: '0.06em',
        }}>
        Remove
      </button>
    </div>
  );
}

function EmptyState() {
  return (
    <div style={{
      padding: '40px 40px 20px',
      textAlign: 'center',
    }}>
      <div style={{
        width: 56, height: 56, borderRadius: 999,
        background: 'var(--ui-info-soft)',
        color: 'var(--ui-info-ink)',
        display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
        marginBottom: 14,
      }}>
        <I.shield width="26" height="26"/>
      </div>
      <div style={{ fontSize: 17, fontWeight: 600, color: 'var(--ui-text)', marginBottom: 6 }}>
        No assets excluded
      </div>
      <div style={{ fontSize: 13, color: 'var(--ui-text-muted)', lineHeight: 1.5, maxWidth: 280, margin: '0 auto' }}>
        Open any run, select the assets you want to keep in scope, and tap
        <span style={{ color: 'var(--ui-text-body)', fontWeight: 600 }}> Exclude</span>.
        They'll show up here.
      </div>
    </div>
  );
}

window.ExcludedScreen = ExcludedScreen;
