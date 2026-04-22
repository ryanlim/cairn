// SettingsScreen — server, safety rails, notifications

function SettingsScreen({ settings, onSettingsChange, libSize, onLibChange, excludedCount, onOpenExcluded, onOpenPalette }) {
  const { LIBRARY_SIZE_DEFAULTS } = window.CAIRN_DATA;
  const set = (k, v) => onSettingsChange({ ...settings, [k]: v });
  const [revealKey, setRevealKey] = React.useState(false);
  const [copiedKey, setCopiedKey] = React.useState(false);

  React.useEffect(() => {
    if (!copiedKey) return;
    const t = setTimeout(() => setCopiedKey(false), 1400);
    return () => clearTimeout(t);
  }, [copiedKey]);

  // Auto-hide key after reveal
  React.useEffect(() => {
    if (!revealKey) return;
    const t = setTimeout(() => setRevealKey(false), 8000);
    return () => clearTimeout(t);
  }, [revealKey]);

  return (
    <div className="screen fade-in">
      <AppHeader title="Settings"/>

      <div className="keyline">Immich server</div>
      <div style={{ padding: '0 16px' }}>
        <div className="card" style={{ overflow: 'hidden' }}>
          <KeyValRow label="URL"        value={settings.serverUrl.replace('https://', '')} mono onClick={() => {}} chevron/>
          <ApiKeyRow
            keyValue={settings.apiKey}
            masked={settings.apiKeyTail}
            revealed={revealKey}
            onToggleReveal={() => setRevealKey(r => !r)}
            onCopy={() => setCopiedKey(true)}
            copied={copiedKey}
          />
          <KeyValRow label="Connection" value={<span style={{ display: 'flex', alignItems: 'center', gap: 6, color: 'var(--moss-ink)' }}><span className="dot moss"/>healthy · 42ms</span>}/>
        </div>
      </div>

      <div className="keyline">Safety rails</div>
      <div style={{ padding: '0 16px' }}>
        <div className="card" style={{ overflow: 'hidden' }}>
          <SliderRow
            label="Percent threshold"
            sub={`Abort if a run would trash more than ${settings.maxDeletePercent.toFixed(1)}% of matched assets.`}
            value={settings.maxDeletePercent}
            min={0.5} max={5} step={0.1}
            onChange={(v) => set('maxDeletePercent', v)}
            fmt={(v) => v.toFixed(1) + '%'}
          />
          <KeyValRow label="Count floor" value={`${settings.minDeleteFloor} assets`} onClick={() => {}} chevron/>
          <ToggleRow
            label="Dry-run by default"
            sub="Every scheduled run is preview-only. You confirm each trash manually."
            value={settings.dryRunByDefault}
            onChange={(v) => set('dryRunByDefault', v)}
          />
          <KeyValRow
            label="Excluded assets"
            value={
              <span style={{ color: excludedCount > 0 ? 'var(--ui-info-ink)' : 'var(--ui-text-muted)' }}>
                {excludedCount > 0 ? `${excludedCount} protected` : 'None'}
              </span>
            }
            onClick={onOpenExcluded}
            chevron
          />
        </div>
      </div>

      <div className="keyline">Notifications</div>
      <div style={{ padding: '0 16px' }}>
        <div className="card" style={{ overflow: 'hidden' }}>
          <ToggleRow
            label="Alert on aborted run"
            sub="Local notification when a safety rail trips. Next open surfaces the review screen."
            value={settings.notifyOnAbort}
            onChange={(v) => set('notifyOnAbort', v)}
          />
          <ToggleRow
            label="Verbose journal"
            sub="Record every API request in deletion-journal.jsonl."
            value={settings.verboseLogging}
            onChange={(v) => set('verboseLogging', v)}
          />
        </div>
      </div>

      <div className="keyline">Permissions</div>
      <div style={{ padding: '0 16px' }}>
        <div className="card" style={{ overflow: 'hidden' }}>
          <KeyValRow label="Photos access" value={<span style={{ color: 'var(--moss-ink)' }}>Full library</span>} onClick={() => {}} chevron/>
          <KeyValRow label="Background refresh" value={<span style={{ color: 'var(--moss-ink)' }}>Allowed</span>} onClick={() => {}} chevron/>
        </div>
      </div>

      <div className="keyline">Appearance</div>
      <div style={{ padding: '0 16px' }}>
        <div className="card" style={{ overflow: 'hidden' }}>
          <KeyValRow
            label="Palette"
            value={<span style={{ color: 'var(--ui-text-muted)' }}>Accents &amp; neutrals</span>}
            onClick={onOpenPalette}
            chevron
          />
        </div>
      </div>

      <div className="keyline">Danger zone</div>
      <div style={{ padding: '0 16px 20px' }}>
        <div className="card" style={{ overflow: 'hidden' }}>
          <KeyValRow label="Reset index" value={<span style={{ color: 'var(--rust-ink)' }}>Re-seed</span>} onClick={() => {}} chevron/>
          <KeyValRow label="Clear journal"        value={<span style={{ color: 'var(--rust-ink)' }}>Delete JSONL</span>} onClick={() => {}} chevron/>
          <KeyValRow label="Sign out of server"   value={<span style={{ color: 'var(--rust-ink)' }}>Remove key</span>} onClick={() => {}} chevron/>
        </div>
      </div>

      <div style={{ padding: '10px 28px 20px', textAlign: 'center', color: 'var(--stone-4)', fontSize: 11, lineHeight: 1.6 }}>
        cairn v0.2.0 · not affiliated with Immich<br/>
        MIT · <span style={{ textDecoration: 'underline' }}>open source</span> · <span style={{ textDecoration: 'underline' }}>privacy</span>
      </div>
    </div>
  );
}

function SliderRow({ label, sub, value, min, max, step, onChange, fmt }) {
  const pct = ((value - min) / (max - min)) * 100;
  return (
    <div className="row" style={{ flexDirection: 'column', alignItems: 'stretch', padding: '14px 16px' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 3 }}>
        <div style={{ fontSize: 15, color: 'var(--stone-7)' }}>{label}</div>
        <div className="tabular mono" style={{ fontSize: 13, color: 'var(--stone-6)' }}>{fmt(value)}</div>
      </div>
      {sub && <div style={{ fontSize: 12, color: 'var(--stone-5)', marginBottom: 12, lineHeight: 1.4 }}>{sub}</div>}
      <div style={{ position: 'relative', height: 24, display: 'flex', alignItems: 'center' }}>
        <div style={{ position: 'absolute', left: 0, right: 0, height: 3, background: 'var(--stone-2)', borderRadius: 999 }}/>
        <div style={{ position: 'absolute', left: 0, width: pct + '%', height: 3, background: 'var(--stone-7)', borderRadius: 999 }}/>
        <div style={{
          position: 'absolute', left: `calc(${pct}% - 10px)`,
          width: 20, height: 20, borderRadius: 999,
          background: 'var(--stone-0)',
          border: '1.5px solid var(--stone-7)',
          boxShadow: '0 1px 3px rgba(0,0,0,0.12)',
        }}/>
        <input
          type="range"
          min={min} max={max} step={step} value={value}
          onChange={(e) => onChange(parseFloat(e.target.value))}
          style={{ position: 'absolute', left: 0, right: 0, width: '100%', opacity: 0, height: 24, cursor: 'pointer', margin: 0 }}
        />
      </div>
    </div>
  );
}

window.SettingsScreen = SettingsScreen;

function ApiKeyRow({ keyValue, masked, revealed, onToggleReveal, onCopy, copied }) {
  return (
    <div className="row" style={{ flexDirection: 'column', alignItems: 'stretch', padding: '12px 16px', gap: 8 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{ fontSize: 15, color: 'var(--stone-7)' }}>API key</div>
        <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
          <button
            onClick={onToggleReveal}
            style={{
              fontSize: 12,
              color: revealed ? 'var(--rust-ink)' : 'var(--ui-primary-ink)',
              background: 'transparent',
              border: 'none',
              padding: '2px 2px',
              cursor: 'pointer',
              fontWeight: 500,
            }}>
            {revealed ? 'Hide' : 'Reveal'}
          </button>
          <button
            onClick={() => {
              try { navigator.clipboard?.writeText(keyValue); } catch(e) {}
              onCopy();
            }}
            style={{
              fontSize: 12,
              color: copied ? 'var(--moss-ink)' : 'var(--ui-text-muted)',
              background: 'transparent',
              border: 'none',
              padding: '2px 2px',
              cursor: 'pointer',
              fontWeight: 500,
            }}>
            {copied ? 'Copied ✓' : 'Copy'}
          </button>
        </div>
      </div>
      <div
        className="mono tabular"
        style={{
          fontSize: 13,
          color: revealed ? 'var(--stone-7)' : 'var(--stone-5)',
          background: revealed ? 'color-mix(in oklab, var(--rust) 6%, var(--stone-0))' : 'var(--stone-1)',
          border: revealed ? '0.5px solid color-mix(in oklab, var(--rust-ink) 35%, transparent)' : '0.5px solid var(--ui-divider)',
          borderRadius: 7,
          padding: '7px 10px',
          wordBreak: 'break-all',
          lineHeight: 1.45,
          letterSpacing: revealed ? 0 : 0.5,
          transition: 'background 160ms ease',
        }}>
        {revealed ? keyValue : masked}
      </div>
      {revealed && (
        <div style={{ fontSize: 11, color: 'var(--rust-ink)', display: 'flex', alignItems: 'center', gap: 5 }}>
          <span style={{ fontSize: 10 }}>⚠</span>
          Hiding automatically in a few seconds. Don't screenshot.
        </div>
      )}
    </div>
  );
}

window.ApiKeyRow = ApiKeyRow;
