// StatusScreen — the default landing. Steady state.

function StatusScreen({ state, degraded, data, settings, onStartSync, onOpenRun, libSize }) {
  const { RUNS, JOURNAL_TAIL, LIBRARY_SIZE_DEFAULTS } = window.CAIRN_DATA;
  const lib = LIBRARY_SIZE_DEFAULTS[libSize];
  const latest = RUNS[0];
  const pct = ((lib.candidates / lib.matched) * 100);
  const percentBudget = settings.maxDeletePercent;
  const withinBudget = pct <= percentBudget;

  // Degraded conditions are orthogonal to app-state — they describe an
  // environmental problem (server down, auth stale, photos permission limited,
  // library too small to trust). They preempt the primary action and replace
  // the "ready to sync" CTA.
  const isDegraded = degraded && degraded !== 'none';
  const degradedBanner = () => {
    if (!isDegraded) return null;
    const map = {
      'server-down': {
        icon: <I.server/>,
        tone: 'rust',
        title: 'Immich server unreachable',
        body: <>Tried <span className="mono" style={{ fontSize: 11.5 }}>{settings.serverUrl.replace('https://','')}</span> three times over 2m. Check VPN or server health before syncing.</>,
        cta: 'Retry connection',
      },
      'auth-stale': {
        icon: <I.key/>,
        tone: 'amber',
        title: 'API key rejected',
        body: 'Server returned 401. Your key may have been revoked or expired. Paste a new one in Settings.',
        cta: 'Update key',
      },
      'photos-limited': {
        icon: <I.photo/>,
        tone: 'amber',
        title: 'Photos access is Limited',
        body: 'cairn can only see the 84 assets you picked. With Limited access it will flag everything outside as "missing" and suggest deleting them — dangerous. Grant Full access to continue.',
        cta: 'Grant Full access',
      },
      'tiny-library': {
        icon: <I.info/>,
        tone: 'amber',
        title: 'Library is small',
        body: 'Your iPhone has 47 assets. cairn works best with 200+ so signals are reliable. You can still sync, but treat the first run carefully.',
        cta: null,
      },
    };
    const d = map[degraded];
    if (!d) return null;
    return (
      <div
        className={`callout callout-${d.tone} fade-in`}
        style={{ margin: '0 16px 12px', display: 'flex', gap: 12, borderLeft: `3px solid var(--c-${d.tone === 'rust' ? 'danger' : 'warn'})` }}>
        <div style={{ marginTop: 1 }}>{d.icon}</div>
        <div style={{ flex: 1 }}>
          <div style={{ fontWeight: 600, marginBottom: 3 }}>{d.title}</div>
          <div style={{ opacity: 0.88, lineHeight: 1.45 }}>{d.body}</div>
          {d.cta && (
            <button
              className="btn btn-quiet btn-small"
              style={{ marginTop: 10, padding: '0 12px' }}>
              {d.cta}
            </button>
          )}
        </div>
      </div>
    );
  };

  // Sync button is blocked by server-down, auth-stale, photos-limited.
  // tiny-library is a soft warning, not a hard block.
  const syncBlocked = ['server-down', 'auth-stale', 'photos-limited'].includes(degraded);

  // State-specific banner
  const stateBanner = () => {
    if (state === 'threshold') {
      // Synthesize a threshold scenario: 2.3% of matched.
      const tripCount = Math.max(settings.minDeleteFloor + 1, Math.round(lib.matched * 0.023));
      return (
        <div className="callout callout-amber fade-in" style={{ margin: '0 16px 12px', display: 'flex', gap: 12, borderLeft: '3px solid var(--c-danger)' }}>
          <div style={{ marginTop: 1, color: 'var(--ui-warn-ink)' }}><I.warn /></div>
          <div>
            <div style={{ fontWeight: 600, marginBottom: 3 }}>Safety rail tripped</div>
            <div style={{ opacity: 0.88 }}>Last run would have trashed <b>{tripCount.toLocaleString()} assets</b> (<b>2.3%</b> of matched), above your <b>{settings.maxDeletePercent.toFixed(1)}%</b> cap. Review before re-running.</div>
          </div>
        </div>
      );
    }
    if (state === 'dryrun') {
      return (
        <div className="callout callout-amber fade-in" style={{ margin: '0 16px 12px', display: 'flex', gap: 12, borderLeft: '3px solid var(--ui-info)' }}>
          <div style={{ marginTop: 1, color: 'var(--ui-info-ink)' }}><I.info /></div>
          <div>
            <div style={{ fontWeight: 600, marginBottom: 3 }}>First sync is a dry-run</div>
            <div style={{ opacity: 0.88 }}>We'll show exactly what would be trashed. Nothing gets touched on your server until you confirm.</div>
          </div>
        </div>
      );
    }
    return null;
  };

  return (
    <div className="screen fade-in">
      {/* Header */}
      <div style={{ padding: '60px 20px 4px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <CairnMark size={28}/>
          <div className="app-title" style={{ fontWeight: 600 }}>cairn</div>
        </div>
        <div className={`chip ${isDegraded ? (degraded === 'tiny-library' ? 'info' : 'danger') : 'verified'}`}>
          <span className={`dot ${isDegraded ? (degraded === 'tiny-library' ? 'info' : 'danger') : 'verified'}`}/>
          {isDegraded
            ? (degraded === 'server-down' ? 'offline'
              : degraded === 'auth-stale' ? 'auth expired'
              : degraded === 'photos-limited' ? 'limited'
              : 'small library')
            : 'synced'}
        </div>
      </div>
      <div style={{ padding: '0 20px 18px', color: 'var(--ui-text-muted)', fontSize: 13, letterSpacing: '-0.005em' }}>
        reconciling <span style={{ color: 'var(--ui-muted-ink)' }}>iPhone 15 Pro</span> against <span className="mono" style={{ fontSize: 12, color: 'var(--ui-text-quiet)' }}>{settings.serverUrl.replace('https://', '')}</span>
      </div>

      {degradedBanner()}
      {stateBanner()}

      {/* Ready to sync card */}
      <div style={{ padding: '0 16px 14px' }}>
        <div className="card" style={{ padding: 18, display: 'flex', flexDirection: 'column', gap: 14 }}>
          <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 16 }}>
            <div>
              <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--stone-4)', textTransform: 'uppercase', letterSpacing: '0.09em', marginBottom: 6 }}>
                Pending candidates
              </div>
              <div className="tabular" style={{ fontSize: 52, fontWeight: 600, letterSpacing: '-0.04em', lineHeight: 0.92, fontFamily: 'var(--font-display)', color: 'var(--ui-accent)' }}>
                {lib.candidates}
              </div>
              <div style={{ fontSize: 13, color: 'var(--stone-5)', marginTop: 8 }}>
                would move to <span style={{ color: 'var(--stone-7)' }}>Immich trash</span> on next run
              </div>
            </div>
            <div style={{ textAlign: 'right', display: 'flex', flexDirection: 'column', gap: 4, alignItems: 'flex-end', marginTop: 2 }}>
              <div className="chip" style={{ background: withinBudget ? 'var(--moss-soft)' : 'var(--amber-soft)', color: withinBudget ? 'var(--moss-ink)' : 'var(--amber-ink)' }}>
                <span className={`dot ${withinBudget ? 'moss' : 'amber'}`}/>
                {pct.toFixed(2)}% of matched
              </div>
              <div style={{ fontSize: 11, color: 'var(--stone-4)' }}>cap {percentBudget.toFixed(1)}%</div>
            </div>
          </div>

          <div className="progress">
            <div className="progress-fill" style={{
              width: Math.min(100, (pct / percentBudget) * 100) + '%',
              background: withinBudget ? 'var(--ui-pending)' : 'var(--ui-warn)',
            }}/>
          </div>

          <button
            className={`btn ${syncBlocked ? 'btn-secondary' : 'btn-primary'} btn-block`}
            onClick={syncBlocked ? undefined : onStartSync}
            disabled={syncBlocked}
            style={syncBlocked ? { opacity: 0.55, cursor: 'not-allowed' } : undefined}>
            <I.sync width="16" height="16"/>
            {syncBlocked
              ? 'Can\u2019t sync — see banner'
              : state === 'threshold' ? 'Review before syncing' : 'Review & sync'}
          </button>
        </div>
      </div>

      {/* Library snapshot — 3 stats */}
      <div className="keyline">Library</div>
      <div style={{ padding: '0 16px' }}>
        <div className="card" style={{ padding: 18, display: 'flex', gap: 16 }}>
          <Stat label="On iPhone" value={lib.local.toLocaleString()} sub="current"/>
          <div style={{ width: 0.5, background: 'var(--stone-3)' }}/>
          <Stat label="Indexed" value={lib.indexed.toLocaleString()} sub={<span style={{ color: 'var(--ui-verified-ink)' }}>SHA1 set</span>}/>
          <div style={{ width: 0.5, background: 'var(--stone-3)' }}/>
          <Stat label="On server" value={lib.server.toLocaleString()} sub={<span>{lib.matched.toLocaleString()} <span style={{ color: 'var(--ui-info-ink)' }}>matched</span></span>}/>
        </div>
      </div>

      {/* Recent runs — compact timeline */}
      <div className="keyline">Recent runs</div>
      <div style={{ padding: '0 16px' }}>
        <div className="card" style={{ overflow: 'hidden' }}>
          {RUNS.slice(0, 4).map((r, i) => <RunRow key={r.id} run={r} onOpen={() => onOpenRun(r)} isLast={i === 3}/>)}
          <div
            onClick={() => window.__setTab && window.__setTab('runs')}
            style={{
              padding: '12px 16px',
              fontSize: 13, color: 'var(--stone-5)',
              display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
              borderTop: '0.5px solid var(--stone-3)',
              cursor: 'pointer',
            }}>
            See all runs <I.chevron width="12" height="12"/>
          </div>
        </div>
      </div>

      {/* Journal tail */}
      <div className="keyline">Latest journal</div>
      <div style={{ padding: '0 16px 20px' }}>
        <div className="card" style={{ padding: '12px 14px', background: 'var(--stone-0)' }}>
          <div className="mono" style={{ fontSize: 11.5, lineHeight: 1.7, color: 'var(--stone-5)' }}>
            {JOURNAL_TAIL.map((j, i) => {
              const evColor =
                j.ev === 'verify'      ? 'var(--ui-verified-ink)' :
                j.ev === 'tag'         ? 'var(--ui-info-ink)'     :
                j.ev === 'trash'       ? 'var(--ui-warn-ink)'     :
                j.ev === 'abort'       ? 'var(--ui-danger-ink)'   :
                                         'var(--ui-text-body)';
              return (
                <div key={i} style={{ display: 'flex', gap: 8 }}>
                  <span style={{ color: 'var(--ui-muted-ink)', flexShrink: 0 }}>{j.t}</span>
                  <span style={{ color: evColor, flexShrink: 0, width: 84, fontWeight: 500 }}>{j.ev}</span>
                  <span style={{ color: 'var(--stone-5)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{j.msg}</span>
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </div>
  );
}

function RunRow({ run, onOpen, isLast }) {
  const statusRole = run.status === 'aborted' ? 'danger' : run.dryRun ? 'pending' : 'verified';
  const softBg = `var(--ui-${statusRole === 'danger' ? 'danger' : statusRole === 'pending' ? 'pending' : 'verified'}-soft)`;
  const inkFg  = `var(--ui-${statusRole === 'danger' ? 'danger' : statusRole === 'pending' ? 'pending' : 'verified'}-ink)`;
  const icon = run.status === 'aborted'
    ? <I.warn width="14" height="14"/>
    : run.dryRun
      ? <I.eye width="14" height="14"/>
      : <I.trash width="14" height="14"/>;
  const verb = run.status === 'aborted' ? 'Aborted' : run.dryRun ? 'Dry-run' : run.trashed === 0 ? 'No changes' : `${run.trashed} trashed`;
  return (
    <div onClick={onOpen} style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '14px 16px',
      borderBottom: isLast ? 'none' : '0.5px solid var(--stone-3)',
      cursor: 'pointer',
    }}>
      <div style={{
        width: 30, height: 30, borderRadius: 9, flexShrink: 0,
        background: softBg, color: inkFg,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>{icon}</div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <div style={{ fontSize: 14, fontWeight: 500, color: 'var(--stone-7)' }}>{verb}</div>
          {run.restored > 0 && <span className="chip muted" style={{ fontSize: 10, padding: '1px 6px' }}>{run.restored} restored</span>}
        </div>
        <div style={{ fontSize: 11.5, color: 'var(--ui-muted-ink)', marginTop: 2 }}>
          {relTime(run.startedAt)} · <span className="mono" style={{ fontSize: 10.5, color: 'var(--ui-text-quiet)' }}>{run.id.slice(-8)}</span>
        </div>
      </div>
      <I.chevron width="14" height="14" style={{ color: 'var(--stone-4)' }}/>
    </div>
  );
}

window.StatusScreen = StatusScreen;
