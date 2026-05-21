const DISP_MIN   = -24.0;
const DISP_MAX   = -6.0;
const DISP_RANGE = DISP_MAX - DISP_MIN;

function pct(val, min, max) {
  return Math.max(0, Math.min(100, (val - min) / (max - min) * 100));
}

function fmt(v, dec = 1) {
  return v != null ? v.toFixed(dec) : 'N/A';
}

function formatDuration(sec) {
  if (sec == null) return '?:??';
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${s.toString().padStart(2, '0')}`;
}

function lufsClass(I, targetLUFS, LUFSTolerance) {
  if (I == null) return 'err';
  if (I > targetLUFS + LUFSTolerance) return 'warn';
  if (I < targetLUFS - LUFSTolerance) return 'warn';
  return 'ok';
}

function issueClass(tag) {
  const crits = ['ANALYSIS ERROR', 'PHASE CANCEL'];
  return crits.includes(tag) ? 'crit' : 'warn';
}

export function renderPendingCard(tempId, fileName) {
  const el = document.createElement('div');
  el.className = 'card pending';
  el.id = tempId;
  el.innerHTML = `
  <div class="card-header">
    <span class="badge pending">Analyzing</span>
    <span class="fname">${fileName}</span>
    <span class="analyzing-spinner"></span>
  </div>
  <div class="pending-shimmer"></div>`;
  document.getElementById('tracksArea').appendChild(el);
}

export function renderCard(result, thresholds, tempId) {
  const { raw, evaluated } = result;
  const pending = tempId ? document.getElementById(tempId) : null;
  const el = pending || document.createElement('div');
  if (!pending) document.getElementById('tracksArea').appendChild(el);
  el.removeAttribute('id');
  el.className = `card ${evaluated.status}`;
  el.dataset.id = raw.fileId;
  el.innerHTML = buildCardHTML(raw, evaluated, thresholds);
}

export function updateCard(fileId, evaluated, thresholds) {
  const el = document.querySelector(`.card[data-id="${fileId}"]`);
  if (!el) return;

  // Update border class
  el.className = `card ${evaluated.status}`;

  // Update badge
  const badge = el.querySelector('.badge');
  badge.className = `badge ${evaluated.status}`;
  badge.textContent = evaluated.status;

  // Re-render the meter and issues sections
  const raw = getRaw(fileId);
  if (!raw) return;

  const meterRow = el.querySelector('.meter-row.lufs-meter');
  if (meterRow) meterRow.outerHTML = buildLufsMeter(raw, evaluated, thresholds);

  const issueRow = el.querySelector('.issue-row');
  if (evaluated.issues.length) {
    const newIssues = buildIssues(evaluated.issues);
    if (issueRow) issueRow.outerHTML = newIssues;
    else el.querySelector('.pills').insertAdjacentHTML('afterend', newIssues);
  } else {
    if (issueRow) issueRow.remove();
  }
}

function getRaw(fileId) {
  // Import rawStore lazily to avoid circular
  return window.__rawStore?.get(fileId);
}

function buildCardHTML(raw, evaluated, thresholds) {
  const meta = [
    formatDuration(raw.durationSec),
    raw.codec?.toUpperCase(),
    raw.channels === 2 ? 'Stereo' : raw.channels === 1 ? 'Mono' : null,
  ].filter(Boolean).join(' · ');

  return `
  <div class="card-header">
    <span class="badge ${evaluated.status}">${evaluated.status}</span>
    <span class="fname" title="${raw.fileName}">${raw.fileName}</span>
    <span class="fmeta">${meta}</span>
  </div>
  ${buildLufsMeter(raw, evaluated, thresholds)}
  ${raw.phase != null ? buildPhaseMeter(raw) : ''}
  <div class="pills">${buildPills(raw)}</div>
  ${evaluated.issues.length ? buildIssues(evaluated.issues) : ''}
  `;
}

function buildLufsMeter(raw, evaluated, thresholds) {
  const { targetLUFS, LUFSTolerance } = thresholds;
  const targetPct = pct(targetLUFS, DISP_MIN, DISP_MAX);
  const tolLoPct  = pct(targetLUFS - LUFSTolerance, DISP_MIN, DISP_MAX);
  const tolWidPct = pct(targetLUFS + LUFSTolerance, DISP_MIN, DISP_MAX) - tolLoPct;
  const fillPct   = raw.I != null ? pct(raw.I, DISP_MIN, DISP_MAX) : 0;
  const cls       = raw.I != null ? lufsClass(raw.I, targetLUFS, LUFSTolerance) : 'err';
  return `
  <div class="meter-row lufs-meter">
    <span class="m-label">LUFS</span>
    <div class="m-track">
      <div class="m-tol"  style="left:${tolLoPct.toFixed(1)}%;width:${tolWidPct.toFixed(1)}%;"></div>
      <div class="m-fill ${cls}" style="width:${fillPct.toFixed(1)}%;"></div>
      <div class="m-target" style="left:${targetPct.toFixed(1)}%;"></div>
    </div>
    <span class="m-val">${fmt(raw.I, 1)}</span>
  </div>`;
}

function buildPhaseMeter(raw) {
  const markerPct = pct(raw.phase.avg, -1, 1);
  return `
  <div class="meter-row">
    <span class="m-label">Phase</span>
    <div class="phase-track">
      <div class="ph-marker" style="left:${markerPct.toFixed(1)}%;"></div>
    </div>
    <span class="m-val">${fmt(raw.phase.avg, 3)} (min ${fmt(raw.phase.min, 3)})</span>
  </div>`;
}

function buildPills(raw) {
  const pills = [
    ['TP',   raw.TP   != null ? `${fmt(raw.TP, 2)} dBTP` : 'N/A'],
    ['Peak', raw.samplePeak != null ? fmt(raw.samplePeak, 2) : 'N/A'],
    ['LRA',  raw.LRA  != null ? fmt(raw.LRA, 1) : 'N/A'],
    ['DR',   raw.dr   != null ? `${fmt(raw.dr, 1)}` : 'N/A'],
    ['L-R',  raw.imbalanceDb != null ? `${fmt(raw.imbalanceDb, 2)} dB` : '—'],
    ['SR',   raw.sampleRate ?? 'N/A'],
    ['Bit',  raw.bitDepth   ?? 'N/A'],
  ];
  return pills.map(([l, v]) =>
    `<div class="pill"><span class="pl">${l}</span><span class="pv">${v}</span></div>`
  ).join('');
}

function buildIssues(issues) {
  return `<div class="issue-row">${
    issues.map(t => `<span class="issue ${issueClass(t)}">${t}</span>`).join('')
  }</div>`;
}

export function renderStats(results, thresholds) {
  const area = document.getElementById('statsArea');
  area.style.display = '';
  const total   = results.length;
  const ready   = results.filter(r => r.evaluated.status === 'READY').length;
  const adjust  = results.filter(r => r.evaluated.status === 'ADJUST').length;
  const error   = results.filter(r => r.evaluated.status === 'ERROR').length;

  const lufsVals = results.map(r => r.raw.I).filter(v => v != null);
  const avgLUFS  = lufsVals.length
    ? lufsVals.reduce((a, b) => a + b, 0) / lufsVals.length
    : null;
  const spreadLUFS = lufsVals.length > 1
    ? Math.max(...lufsVals) - Math.min(...lufsVals)
    : 0;

  const phaseVals = results.map(r => r.raw.phase?.avg).filter(v => v != null);
  const avgPhase  = phaseVals.length
    ? phaseVals.reduce((a, b) => a + b, 0) / phaseVals.length
    : null;
  const minPhase  = phaseVals.length ? Math.min(...phaseVals) : null;

  const drVals = results.map(r => r.raw.dr).filter(v => v != null);
  const avgDR  = drVals.length
    ? drVals.reduce((a, b) => a + b, 0) / drVals.length
    : null;

  const phaseChipCls = avgPhase != null
    ? avgPhase < thresholds.phaseCancelThreshold ? 'bad'
    : avgPhase < thresholds.phaseWarnThreshold   ? 'warn' : ''
    : '';

  area.innerHTML = `
    <div class="chip"><div class="cl">Tracks</div><div class="cv">${total}</div></div>
    <div class="chip c-ready"><div class="cl">Ready</div><div class="cv">${ready}</div></div>
    <div class="chip c-adjust"><div class="cl">Adjust</div><div class="cv">${adjust}</div></div>
    <div class="chip c-error"><div class="cl">Error</div><div class="cv">${error}</div></div>
    ${avgLUFS != null ? `<div class="chip"><div class="cl">Avg LUFS</div><div class="cv">${fmt(avgLUFS, 1)} LUFS</div><div class="cs">spread ${fmt(spreadLUFS, 1)} LU</div></div>` : ''}
    ${avgPhase != null ? `<div class="chip ${phaseChipCls}"><div class="cl">Phase Corr</div><div class="cv">${fmt(avgPhase, 3)}</div><div class="cs">min ${fmt(minPhase, 3)}</div></div>` : ''}
    ${avgDR != null ? `<div class="chip"><div class="cl">Avg DR</div><div class="cv">DR ${fmt(avgDR, 0)}</div></div>` : ''}
  `;
}

export function renderLegend(thresholds) {
  const area = document.getElementById('legendArea');
  area.style.display = '';
  area.innerHTML = `
    <h3>Legend</h3>
    <div class="legend-grid">
      <div><b>LUFS meter</b>: bar spans <code>-24</code> to <code>-6</code>. Shaded band = tolerance ±<code>${thresholds.LUFSTolerance}</code>. Tick = target <code>${thresholds.targetLUFS}</code>.</div>
      <div><b>Phase</b>: -1 (cancel) to +1 (mono). Red zone = cancel, orange = warn &lt;<code>${thresholds.phaseWarnThreshold}</code>.</div>
      <div><b>TP</b>: True Peak (dBTP). Reference only.</div>
      <div><b>LRA</b>: Loudness Range. Low = compressed; high = dynamic.</div>
      <div><b>DR</b>: Peak-to-RMS ratio. &lt;8 = heavily limited.</div>
      <div><b>L-R</b>: Channel RMS imbalance (dB). &gt;<code>${thresholds.imbalanceThreshold}</code> dB = ADJUST.</div>
      <div><b>PHASE CANCEL</b>: avg corr &lt; <code>${thresholds.phaseCancelThreshold}</code> → ADJUST.</div>
      <div><b>PHASE WARN</b>: avg corr &lt; <code>${thresholds.phaseWarnThreshold}</code> → Issues only.</div>
    </div>
  `;
}

export function showProgress(total, done) {
  const bar  = document.getElementById('progressBar');
  const fill = document.getElementById('progressFill');
  if (total === 0) {
    bar.classList.add('hidden');
    return;
  }
  bar.classList.remove('hidden');
  fill.style.width = `${(done / total * 100).toFixed(1)}%`;
}

export function setStatus(msg) {
  const el = document.getElementById('ffmpegStatus');
  if (el) el.textContent = msg;
}
