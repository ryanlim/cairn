// Shared small components — the cairn brand mark, headers, tab bar, etc.

function CairnMark({ size = 22 }) {
  // The real cairn brand mark — stacked stones with a red trash bin crown.
  // Vector-sourced from assets/cairn-mark.svg, rendered via <img>.
  return (
    <img
      src="assets/cairn-mark.svg"
      width={size}
      height={size}
      alt="cairn"
      draggable={false}
      style={{ display: 'block', userSelect: 'none' }}
    />
  );
}

function CairnLockup({ size = 60 }) {
  // Mark + wordmark lockup, for launch and setup surfaces.
  return (
    <img
      src="assets/cairn-lockup.svg"
      width={size}
      height={size}
      alt="cairn"
      draggable={false}
      style={{ display: 'block', userSelect: 'none' }}
    />
  );
}

function AppHeader({ title, subtitle, trailing, leading }) {
  return (
    <div className="app-header">
      <div style={{ flex: 1, minWidth: 0 }}>
        {leading && <div style={{ marginBottom: 4 }}>{leading}</div>}
        <div className="app-title">{title}</div>
        {subtitle && <div className="app-subtitle">{subtitle}</div>}
      </div>
      {trailing}
    </div>
  );
}

function TabBar({ active, onChange }) {
  const tabs = [
    { id: 'status',   label: 'Status',   icon: <CairnMark size={22}/> },
    { id: 'runs',     label: 'Runs',     icon: <I.list /> },
    { id: 'settings', label: 'Settings', icon: <I.settings /> },
  ];
  return (
    <div className="tabbar">
      {tabs.map(t => (
        <button
          key={t.id}
          className={`tabbar-item ${active === t.id ? 'active' : ''}`}
          onClick={() => onChange(t.id)}
        >
          <div style={{ height: 22, display: 'flex', alignItems: 'center' }}>{t.icon}</div>
          <div>{t.label}</div>
        </button>
      ))}
    </div>
  );
}

function Stat({ label, value, sub, color }) {
  return (
    <div style={{ flex: 1, minWidth: 0 }}>
      <div style={{ fontSize: 11, color: 'var(--stone-4)', fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.09em', marginBottom: 6 }}>
        {label}
      </div>
      <div className="tabular" style={{
        fontSize: 24, fontWeight: 600, letterSpacing: '-0.02em', lineHeight: 1,
        color: color || 'var(--stone-7)',
        fontFamily: 'var(--font-display)',
      }}>
        {value}
      </div>
      {sub && <div style={{ fontSize: 12, color: 'var(--stone-5)', marginTop: 4 }}>{sub}</div>}
    </div>
  );
}

function KeyValRow({ label, value, mono, onClick, chevron }) {
  return (
    <div className="row" onClick={onClick} style={{ cursor: onClick ? 'pointer' : 'default' }}>
      <div className="row-label">{label}</div>
      <div className="row-value">
        <span className={mono ? 'mono' : ''} style={{ color: 'var(--stone-6)', fontSize: mono ? 13 : 15 }}>
          {value}
        </span>
        {chevron && <span style={{ color: 'var(--stone-4)' }}><I.chevron width="14" height="14"/></span>}
      </div>
    </div>
  );
}

function ToggleRow({ label, sub, value, onChange }) {
  return (
    <div className="row" style={{ alignItems: sub ? 'flex-start' : 'center', paddingTop: sub ? 14 : 14, paddingBottom: sub ? 14 : 14 }}>
      <div style={{ flex: 1, paddingRight: 12 }}>
        <div className="row-label" style={{ color: 'var(--stone-7)' }}>{label}</div>
        {sub && <div style={{ fontSize: 12, color: 'var(--stone-5)', marginTop: 3, lineHeight: 1.4 }}>{sub}</div>}
      </div>
      <div className={`toggle ${value ? 'on' : ''}`} onClick={() => onChange(!value)} />
    </div>
  );
}

function relTime(d) {
  const now = new Date('2026-04-21T18:30:00Z').getTime();
  const diff = now - d.getTime();
  const m = Math.floor(diff / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  const d2 = Math.floor(h / 24);
  if (d2 < 7) return `${d2}d ago`;
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

function fmtBytes(b) {
  if (b < 1024) return b + ' B';
  if (b < 1024*1024) return (b/1024).toFixed(0) + ' KB';
  if (b < 1024*1024*1024) return (b/1024/1024).toFixed(1) + ' MB';
  return (b/1024/1024/1024).toFixed(2) + ' GB';
}

function fmtDate(d, opts) {
  return d.toLocaleString(undefined, opts || { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

Object.assign(window, {
  CairnMark, CairnLockup, AppHeader, TabBar, Stat, KeyValRow, ToggleRow,
  relTime, fmtBytes, fmtDate,
});
