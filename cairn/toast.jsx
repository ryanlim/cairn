// Toast — a tiny feedback layer for confirmations with optional Undo action.
//
// Two ways to show:
//   1) <Toast/>             — mount once, then call window.showToast({...}) anywhere
//   2) useToast()           — hook form for imperative use in a component tree
//
// Auto-dismiss after `durationMs` (default 3200ms). Calling showToast again while
// one is live replaces it. Undo calls the provided callback and dismisses.

function Toast() {
  const [toast, setToast] = React.useState(null);
  const timerRef = React.useRef(null);

  const show = React.useCallback((opts) => {
    if (timerRef.current) clearTimeout(timerRef.current);
    setToast(opts);
    timerRef.current = setTimeout(() => setToast(null), opts.durationMs || 3200);
  }, []);

  const dismiss = () => {
    if (timerRef.current) clearTimeout(timerRef.current);
    setToast(null);
  };

  // Expose globally so non-React call sites (or deeply-nested screens without a
  // prop-drilled handler) can fire toasts directly.
  React.useEffect(() => {
    window.showToast = show;
    return () => { if (window.showToast === show) delete window.showToast; };
  }, [show]);

  if (!toast) return null;

  const accent = toast.tone === 'danger'  ? 'var(--ui-danger)'
              : toast.tone === 'success'  ? 'var(--ui-success)'
              : toast.tone === 'info'     ? 'var(--ui-info)'
              : 'var(--ui-primary)';

  return (
    <div style={{
      position: 'absolute',
      left: 16, right: 16,
      bottom: 94, // clear the tab bar
      zIndex: 80,
      display: 'flex', justifyContent: 'center',
      pointerEvents: 'none',
    }}>
      <div
        role="status"
        className="toast-card"
        style={{
          pointerEvents: 'auto',
          background: 'var(--ui-toast-bg, rgba(20, 18, 14, 0.94))',
          color: 'var(--ui-toast-ink, #F4EFE5)',
          borderRadius: 12,
          padding: '10px 12px 10px 14px',
          display: 'flex', alignItems: 'center', gap: 12,
          boxShadow: '0 12px 28px rgba(0,0,0,0.28), 0 2px 6px rgba(0,0,0,0.12)',
          minWidth: 260,
          maxWidth: '100%',
          fontSize: 13.5,
          backdropFilter: 'blur(14px) saturate(1.2)',
          WebkitBackdropFilter: 'blur(14px) saturate(1.2)',
        }}>
        <div style={{
          width: 3, alignSelf: 'stretch',
          background: accent,
          borderRadius: 2,
          flexShrink: 0,
        }}/>
        <div style={{ flex: 1, minWidth: 0, lineHeight: 1.35 }}>
          <div style={{ fontWeight: 600 }}>{toast.title}</div>
          {toast.detail && (
            <div style={{ opacity: 0.75, fontSize: 12, marginTop: 2, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {toast.detail}
            </div>
          )}
        </div>
        {toast.action && (
          <button
            onClick={() => { toast.action.onClick?.(); dismiss(); }}
            style={{
              background: 'transparent',
              color: 'var(--ui-toast-action, #9BD3C7)',
              border: 'none',
              fontSize: 13,
              fontWeight: 600,
              padding: '4px 8px',
              borderRadius: 6,
              cursor: 'pointer',
              whiteSpace: 'nowrap',
            }}>
            {toast.action.label}
          </button>
        )}
      </div>
    </div>
  );
}

window.Toast = Toast;
