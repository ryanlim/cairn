// SetupScreen — onboarding / fresh install flow

function SetupScreen({ onDone }) {
  const [step, setStep] = React.useState(0);
  const [url, setUrl] = React.useState('https://immich.home.arpa');
  const [key, setKey] = React.useState('');
  const [verifying, setVerifying] = React.useState(false);
  const [verified, setVerified] = React.useState(false);

  const verify = () => {
    setVerifying(true);
    setTimeout(() => { setVerifying(false); setVerified(true); }, 900);
  };

  const steps = [
    { n: 0, label: 'Server' },
    { n: 1, label: 'Photos' },
    { n: 2, label: 'Safety' },
    { n: 3, label: 'First run' },
    { n: 4, label: 'Indexing' },
  ];

  return (
    <div className="screen fade-in" style={{ padding: '60px 0 120px' }}>
      {/* Brand */}
      <div style={{ padding: '0 24px 18px', display: 'flex', alignItems: 'center', gap: 10 }}>
        <CairnMark size={32}/>
        <div style={{ fontSize: 22, fontWeight: 600, letterSpacing: '-0.02em' }}>cairn</div>
      </div>

      {/* Stepper */}
      <div style={{ padding: '0 24px 22px', display: 'flex', gap: 6 }}>
        {steps.map(s => (
          <div key={s.n} style={{
            flex: 1, height: 3, borderRadius: 999,
            background: s.n <= step ? 'var(--stone-7)' : 'var(--stone-2)',
            transition: 'background 200ms',
          }}/>
        ))}
      </div>

      {/* Step content */}
      {step === 0 && (
        <div style={{ padding: '0 24px' }}>
          <h2 style={{ fontSize: 26, fontWeight: 600, letterSpacing: '-0.02em', margin: '0 0 8px', lineHeight: 1.15 }}>
            Point cairn at your Immich.
          </h2>
          <p style={{ fontSize: 14, color: 'var(--stone-5)', lineHeight: 1.5, margin: '0 0 24px' }}>
            Photos never leave your iPhone or your Immich server. cairn only sends trash requests, signed with your API key.
          </p>

          <label style={{ fontSize: 11, fontWeight: 600, color: 'var(--stone-4)', textTransform: 'uppercase', letterSpacing: '0.09em', display: 'block', marginBottom: 6 }}>Server URL</label>
          <div className="card" style={{ padding: 0, marginBottom: 16, display: 'flex', alignItems: 'center', paddingLeft: 14 }}>
            <I.server width="16" height="16" style={{ color: 'var(--stone-4)' }}/>
            <input
              value={url} onChange={(e) => setUrl(e.target.value)}
              style={{ flex: 1, border: 'none', background: 'transparent', padding: '14px 12px', fontSize: 14, fontFamily: 'var(--font-mono)', color: 'var(--stone-7)', outline: 'none' }}
            />
          </div>

          <label style={{ fontSize: 11, fontWeight: 600, color: 'var(--stone-4)', textTransform: 'uppercase', letterSpacing: '0.09em', display: 'block', marginBottom: 6 }}>API key</label>
          <div className="card" style={{ padding: 0, marginBottom: 10, display: 'flex', alignItems: 'center', paddingLeft: 14 }}>
            <I.key width="16" height="16" style={{ color: 'var(--stone-4)' }}/>
            <input
              type="password"
              value={key} onChange={(e) => setKey(e.target.value)}
              placeholder="paste key from Immich account settings"
              style={{ flex: 1, border: 'none', background: 'transparent', padding: '14px 12px', fontSize: 14, fontFamily: 'var(--font-mono)', color: 'var(--stone-7)', outline: 'none' }}
            />
          </div>
          <div style={{ fontSize: 11.5, color: 'var(--stone-5)', lineHeight: 1.5, marginBottom: 20 }}>
            Scopes required: <code className="inline">asset.read</code>, <code className="inline">asset.delete</code>, <code className="inline">tag.create</code>, <code className="inline">tag.asset</code>, <code className="inline">tag.read</code>.
          </div>

          {verified ? (
            <div className="callout callout-moss" style={{ display: 'flex', gap: 10, marginBottom: 16 }}>
              <I.checkCircle /><div><b>Connected.</b> 1,204 assets visible to this key.</div>
            </div>
          ) : (
            <button className="btn btn-secondary btn-block" onClick={verify} disabled={verifying} style={{ marginBottom: 16 }}>
              {verifying ? 'Verifying…' : 'Verify connection'}
            </button>
          )}

          <button className="btn btn-primary btn-block" disabled={!verified} onClick={() => setStep(1)}>Continue</button>
        </div>
      )}

      {step === 1 && (
        <div style={{ padding: '0 24px' }}>
          <h2 style={{ fontSize: 26, fontWeight: 600, letterSpacing: '-0.02em', margin: '0 0 8px', lineHeight: 1.15 }}>Grant full Photos access.</h2>
          <p style={{ fontSize: 14, color: 'var(--stone-5)', lineHeight: 1.5, margin: '0 0 24px' }}>
            cairn needs to enumerate your whole library to know what's no longer there. It only reads content identifiers — never photo contents — and never transmits anything outside your devices.
          </p>
          <div className="card" style={{ padding: 16, marginBottom: 16, display: 'flex', gap: 12, alignItems: 'flex-start' }}>
            <div style={{ color: 'var(--stone-6)' }}><I.photo /></div>
            <div>
              <div style={{ fontSize: 14, fontWeight: 500, marginBottom: 2 }}>Full library access</div>
              <div style={{ fontSize: 12.5, color: 'var(--stone-5)', lineHeight: 1.5 }}>
                Limited access won't work: cairn must distinguish photos you deleted from photos it hasn't indexed yet.
              </div>
            </div>
          </div>
          <button className="btn btn-primary btn-block" onClick={() => setStep(2)}>Allow Full Access</button>
        </div>
      )}

      {step === 2 && (
        <div style={{ padding: '0 24px' }}>
          <h2 style={{ fontSize: 26, fontWeight: 600, letterSpacing: '-0.02em', margin: '0 0 8px', lineHeight: 1.15 }}>Set safety thresholds.</h2>
          <p style={{ fontSize: 14, color: 'var(--stone-5)', lineHeight: 1.5, margin: '0 0 24px' }}>
            Defaults are conservative. If any single run would trash more than the threshold, cairn stops and asks. Trash is never permanent — Immich keeps deleted assets for 30 days.
          </p>
          <div className="card" style={{ overflow: 'hidden', marginBottom: 18 }}>
            <div style={{ padding: 16, display: 'flex', gap: 12 }}>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 28, fontWeight: 600, fontFamily: 'var(--font-display)', letterSpacing: '-0.02em' }}>1.0%</div>
                <div style={{ fontSize: 12, color: 'var(--stone-5)', marginTop: 2 }}>percent cap</div>
              </div>
              <div style={{ width: 0.5, background: 'var(--stone-3)' }}/>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 28, fontWeight: 600, fontFamily: 'var(--font-display)', letterSpacing: '-0.02em' }}>5</div>
                <div style={{ fontSize: 12, color: 'var(--stone-5)', marginTop: 2 }}>count floor</div>
              </div>
            </div>
          </div>
          <button className="btn btn-primary btn-block" onClick={() => setStep(3)} style={{ marginBottom: 10 }}>Use defaults</button>
          <button className="btn btn-quiet btn-block" onClick={() => setStep(3)}>Customize later</button>
        </div>
      )}

      {step === 3 && (
        <div style={{ padding: '0 24px' }}>
          <h2 style={{ fontSize: 26, fontWeight: 600, letterSpacing: '-0.02em', margin: '0 0 8px', lineHeight: 1.15 }}>First run is always a dry-run.</h2>
          <p style={{ fontSize: 14, color: 'var(--stone-5)', lineHeight: 1.5, margin: '0 0 22px' }}>
            cairn will scan your library, index every asset, and show exactly what it would move to Immich trash. Nothing happens on the server until you confirm a second time.
          </p>

          <div className="card" style={{ padding: 18, marginBottom: 20 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 13, color: 'var(--stone-5)', marginBottom: 10 }}>
              <span>What happens next</span>
              <span className="mono" style={{ fontSize: 11 }}>~40s</span>
            </div>
            {[
              'Hash on-device photos (lazy, cached)',
              'Pull server asset checksums',
              'Compute diff',
              'Show preview → you confirm',
            ].map((s, i) => (
              <div key={i} style={{ display: 'flex', gap: 10, padding: '8px 0', borderTop: i === 0 ? 'none' : '0.5px solid var(--stone-3)' }}>
                <div style={{ width: 20, height: 20, borderRadius: 999, background: 'var(--stone-2)', color: 'var(--stone-6)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 500 }}>{i + 1}</div>
                <div style={{ fontSize: 13, color: 'var(--stone-7)' }}>{s}</div>
              </div>
            ))}
          </div>

          <button className="btn btn-primary btn-block" onClick={() => setStep(4)}>Begin first sync</button>
        </div>
      )}

      {step === 4 && (
        <IndexingStep onDone={onDone}/>
      )}
    </div>
  );
}

// ── Indexing step — "we've learned your library" confirmation ─────────────
// Plays right after "Begin first sync". A progress bar runs through three
// hash/pull/diff phases, then lands on a confirmation screen with the tracked
// count before handing off to the dry-run sheet. Gives the user a moment to
// see "cairn now knows about my library" without yet asking for a trash
// decision — the two scariest actions are separated by a breath.
function IndexingStep({ onDone }) {
  const { LIBRARY_SIZE_DEFAULTS } = window.CAIRN_DATA;
  const lib = LIBRARY_SIZE_DEFAULTS.medium; // onboarding assumes medium library
  const phases = [
    { label: 'Hashing on-device photos', sub: 'cached after first run' },
    { label: 'Pulling server checksums',  sub: `${lib.server.toLocaleString()} assets on Immich` },
    { label: 'Computing diff',            sub: 'index ready' },
  ];
  const [phaseIdx, setPhaseIdx] = React.useState(0);
  const [done, setDone] = React.useState(false);

  React.useEffect(() => {
    if (done) return;
    if (phaseIdx >= phases.length) { setDone(true); return; }
    const t = setTimeout(() => setPhaseIdx(i => i + 1), 900);
    return () => clearTimeout(t);
  }, [phaseIdx, done]);

  if (done) {
    return (
      <div style={{ padding: '0 24px', animation: 'fadeIn 240ms ease' }}>
        <div style={{
          width: 64, height: 64, borderRadius: 999,
          background: 'var(--ui-verified-soft)',
          color: 'var(--ui-verified-ink)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          marginBottom: 18,
        }}>
          <I.check width="28" height="28" strokeWidth="2.2"/>
        </div>
        <h2 style={{ fontSize: 26, fontWeight: 600, letterSpacing: '-0.02em', margin: '0 0 8px', lineHeight: 1.15 }}>
          Your library is indexed.
        </h2>
        <p style={{ fontSize: 14, color: 'var(--stone-5)', lineHeight: 1.5, margin: '0 0 22px' }}>
          cairn now knows about every asset on your device and on your Immich server. From here, each run is just a diff — fast and incremental.
        </p>

        <div className="card" style={{ padding: 16, marginBottom: 20, display: 'flex', gap: 14 }}>
          <StatBlock label="Tracked on device" value={lib.indexed.toLocaleString()}/>
          <div style={{ width: 0.5, background: 'var(--stone-3)' }}/>
          <StatBlock label="On Immich" value={lib.server.toLocaleString()}/>
          <div style={{ width: 0.5, background: 'var(--stone-3)' }}/>
          <StatBlock label="Candidates" value={String(lib.candidates)} tone="info"/>
        </div>

        <div style={{
          padding: 14, marginBottom: 20,
          background: 'var(--ui-info-soft, color-mix(in oklab, var(--ui-info) 10%, var(--ui-surface)))',
          border: '0.5px solid color-mix(in oklab, var(--ui-info-ink) 20%, transparent)',
          borderRadius: 10,
          display: 'flex', gap: 10,
        }}>
          <div style={{ color: 'var(--ui-info-ink)', marginTop: 1 }}><I.eye /></div>
          <div style={{ fontSize: 12.5, lineHeight: 1.5, color: 'var(--ui-text-body)' }}>
            Next up: a preview of the <b>{lib.candidates} candidates</b> cairn found. Nothing gets touched until you confirm a second time.
          </div>
        </div>

        <button className="btn btn-primary btn-block" onClick={onDone}>Show me the preview</button>
      </div>
    );
  }

  return (
    <div style={{ padding: '0 24px', animation: 'fadeIn 240ms ease' }}>
      <h2 style={{ fontSize: 26, fontWeight: 600, letterSpacing: '-0.02em', margin: '0 0 8px', lineHeight: 1.15 }}>
        Learning your library…
      </h2>
      <p style={{ fontSize: 14, color: 'var(--stone-5)', lineHeight: 1.5, margin: '0 0 24px' }}>
        One-time setup. Subsequent runs reuse this index.
      </p>

      <div className="card" style={{ overflow: 'hidden', marginBottom: 20 }}>
        {phases.map((p, i) => {
          const state = i < phaseIdx ? 'done' : i === phaseIdx ? 'active' : 'idle';
          return (
            <div key={i} style={{
              padding: '14px 16px',
              display: 'flex', gap: 12, alignItems: 'center',
              borderBottom: i === phases.length - 1 ? 'none' : '0.5px solid var(--stone-3)',
              opacity: state === 'idle' ? 0.45 : 1,
              transition: 'opacity 160ms',
            }}>
              <div style={{
                width: 22, height: 22, borderRadius: 999,
                background: state === 'done'
                  ? 'var(--ui-verified-soft)'
                  : state === 'active'
                  ? 'var(--ui-primary-soft, color-mix(in oklab, var(--ui-primary) 15%, var(--ui-surface)))'
                  : 'var(--stone-2)',
                color: state === 'done'
                  ? 'var(--ui-verified-ink)'
                  : state === 'active'
                  ? 'var(--ui-primary-ink)'
                  : 'var(--stone-5)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontSize: 11, fontWeight: 600,
              }}>
                {state === 'done'
                  ? <I.check width="13" height="13" strokeWidth="2.4"/>
                  : state === 'active'
                  ? <div style={{ width: 6, height: 6, borderRadius: 999, background: 'currentColor', animation: 'pulse 900ms ease-in-out infinite' }}/>
                  : i + 1}
              </div>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 14, color: 'var(--stone-7)', fontWeight: state === 'active' ? 500 : 400 }}>
                  {p.label}
                </div>
                <div style={{ fontSize: 11.5, color: 'var(--stone-5)', marginTop: 1 }}>
                  {p.sub}
                </div>
              </div>
              {state === 'active' && (
                <div style={{ color: 'var(--ui-text-muted)', animation: 'spin 900ms linear infinite', display: 'flex' }}>
                  <I.sync width="14" height="14"/>
                </div>
              )}
            </div>
          );
        })}
      </div>

      <style>{`
        @keyframes pulse { 0%, 100% { opacity: 1 } 50% { opacity: 0.3 } }
        @keyframes spin { to { transform: rotate(360deg) } }
      `}</style>
    </div>
  );
}

function StatBlock({ label, value, tone }) {
  const color = tone === 'info' ? 'var(--ui-info-ink)' : 'var(--stone-7)';
  return (
    <div style={{ flex: 1, minWidth: 0 }}>
      <div style={{ fontSize: 10.5, color: 'var(--stone-4)', fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.09em', marginBottom: 4 }}>
        {label}
      </div>
      <div className="tabular" style={{
        fontSize: 22, fontWeight: 600, letterSpacing: '-0.02em', lineHeight: 1,
        color, fontFamily: 'var(--font-display)', whiteSpace: 'nowrap',
      }}>
        {value}
      </div>
    </div>
  );
}

window.SetupScreen = SetupScreen;