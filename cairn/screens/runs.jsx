// RunsScreen — full history list
//
// Empty state is the "fresh install, first sync not yet confirmed" moment or
// a reset index — history is a journal of past runs, so with zero runs there's
// nothing to group by day. We give the user something honest (not a zero count
// hidden behind clever copy) plus the two most-plausible next actions.

function RunsScreen({ onOpenRun, empty }) {
  const { RUNS } = window.CAIRN_DATA;
  const runs = empty ? [] : RUNS;

  if (runs.length === 0) {
    return (
      <div className="screen fade-in">
        <AppHeader title="Runs" subtitle="No runs yet"/>
        <div style={{ padding: '30px 24px', textAlign: 'center' }}>
          <div style={{
            width: 64, height: 64, borderRadius: 18,
            background: 'var(--ui-surface-alt)',
            color: 'var(--ui-text-muted)',
            display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
            marginBottom: 18,
            border: '0.5px dashed var(--ui-divider)',
          }}>
            <I.list width="26" height="26"/>
          </div>
          <div style={{ fontSize: 18, fontWeight: 600, letterSpacing: '-0.015em', marginBottom: 6 }}>
            Nothing to replay yet.
          </div>
          <div style={{ fontSize: 13, color: 'var(--ui-text-muted)', lineHeight: 1.5, maxWidth: 300, margin: '0 auto 20px' }}>
            Every sync — dry-run, aborted, or trashed — lands here with the exact filenames touched and the API calls made. You can restore any trashed batch as long as Immich still has it.
          </div>

          <div className="card" style={{ padding: 14, margin: '0 auto 16px', maxWidth: 320, textAlign: 'left' }}>
            <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--ui-text-quiet)', textTransform: 'uppercase', letterSpacing: '0.08em', marginBottom: 10 }}>
              A run includes
            </div>
            {[
              'Thumbnails + filenames of every candidate',
              'Safety-rail outcome (pass or tripped)',
              'Raw journal of every Immich API call',
              'One-tap restore for trashed assets',
            ].map((line, i) => (
              <div key={i} style={{
                display: 'flex', gap: 10, alignItems: 'flex-start',
                padding: '6px 0',
                borderTop: i === 0 ? 'none' : '0.5px solid var(--ui-divider)',
              }}>
                <div style={{
                  width: 14, height: 14, borderRadius: 3,
                  background: 'var(--ui-surface-alt)',
                  color: 'var(--ui-text-muted)',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  marginTop: 2, flexShrink: 0,
                }}>
                  <I.check width="9" height="9" strokeWidth="2.6"/>
                </div>
                <div style={{ fontSize: 12.5, color: 'var(--ui-text-body)', lineHeight: 1.45 }}>{line}</div>
              </div>
            ))}
          </div>

          <button
            className="btn btn-primary"
            style={{ minWidth: 200 }}
            onClick={() => window.__setTab?.('status')}>
            Start a sync from Status
          </button>
        </div>
      </div>
    );
  }

  // Group by day
  const byDay = {};
  runs.forEach(r => {
    const key = r.startedAt.toDateString();
    (byDay[key] = byDay[key] || []).push(r);
  });

  return (
    <div className="screen fade-in">
      <AppHeader title="Runs" subtitle={`${runs.length} total · last ${relTime(runs[0].startedAt)}`}/>
      {Object.entries(byDay).map(([day, dayRuns]) => (
        <div key={day}>
          <div className="keyline">{fmtDate(new Date(day), { weekday: 'short', month: 'long', day: 'numeric' })}</div>
          <div style={{ padding: '0 16px' }}>
            <div className="card" style={{ overflow: 'hidden' }}>
              {dayRuns.map((r, i) => <RunRow key={r.id} run={r} onOpen={() => onOpenRun(r)} isLast={i === dayRuns.length - 1}/>)}
            </div>
          </div>
        </div>
      ))}
      <div style={{ height: 40 }}/>
    </div>
  );
}

window.RunsScreen = RunsScreen;
