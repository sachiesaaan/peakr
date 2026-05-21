import { initFFmpeg, isReady }    from './ffmpeg-runner.js';
import { analyzeFile, rawStore }  from './analyzer.js';
import { evaluate }               from './evaluator.js';
import {
  renderCard, updateCard,
  renderStats, renderLegend,
  showProgress, setStatus,
} from './renderer.js';
import { exportCsv }              from './exporter.js';

// Expose rawStore globally for renderer's lazy lookup
window.__rawStore = rawStore;

// ---- State ----
const thresholds = {
  targetLUFS:           -9.0,
  LUFSTolerance:         1.0,
  maxTruePeak:          -0.1,
  phaseCancelThreshold:  0.0,
  phaseWarnThreshold:    0.3,
  imbalanceThreshold:    1.5,
  allowedSampleRates:    [44100, 48000],
};

const results = [];      // { raw, evaluated }[]
const queue   = [];      // File[]
let analyzing = false;

// ---- Boot ----
window.addEventListener('DOMContentLoaded', async () => {
  wireThresholds();
  wireDragDrop();
  wireFilePicker();
  document.getElementById('btnExportCsv').addEventListener('click', () => exportCsv(results));
  document.getElementById('btnClear').addEventListener('click', clearAll);

  try {
    await initFFmpeg(setStatus);
  } catch (e) {
    setStatus(`FFmpeg のロードに失敗しました: ${e.message}`);
  }
});

// ---- Drag & Drop ----
function wireDragDrop() {
  const zone = document.getElementById('dropZone');

  zone.addEventListener('dragover',  e => { e.preventDefault(); zone.classList.add('drag-over'); });
  zone.addEventListener('dragleave', ()  => zone.classList.remove('drag-over'));
  zone.addEventListener('drop',      e  => {
    e.preventDefault();
    zone.classList.remove('drag-over');
    const files = [...e.dataTransfer.files].filter(isSupportedAudio);
    if (files.length) enqueueFiles(files);
  });
}

// ---- File Picker ----
function wireFilePicker() {
  const btn    = document.getElementById('btnPick');
  const picker = document.getElementById('filePicker');
  btn.addEventListener('click',   () => picker.click());
  picker.addEventListener('change', e => {
    const files = [...e.target.files].filter(isSupportedAudio);
    if (files.length) enqueueFiles(files);
    picker.value = '';
  });
}

// ---- Threshold Controls ----
function wireThresholds() {
  const pairs = [
    ['sTargetLUFS',  'nTargetLUFS',  'targetLUFS'],
    ['sLUFSTol',     'nLUFSTol',     'LUFSTolerance'],
    ['sMaxTP',       'nMaxTP',       'maxTruePeak'],
    ['sPhaseCancel', 'nPhaseCancel', 'phaseCancelThreshold'],
    ['sPhaseWarn',   'nPhaseWarn',   'phaseWarnThreshold'],
    ['sImbalance',   'nImbalance',   'imbalanceThreshold'],
  ];

  for (const [sid, nid, key] of pairs) {
    const slider = document.getElementById(sid);
    const num    = document.getElementById(nid);
    slider.addEventListener('input',  () => { num.value = slider.value; applyThreshold(key, +slider.value); });
    num.addEventListener('change',    () => { slider.value = num.value; applyThreshold(key, +num.value); });
  }

  document.getElementById('nAllowedSR').addEventListener('change', e => {
    thresholds.allowedSampleRates = e.target.value
      .split(',').map(s => parseInt(s.trim())).filter(n => !isNaN(n));
    reEvaluateAll();
  });
}

function applyThreshold(key, value) {
  thresholds[key] = value;
  reEvaluateAll();
}

function reEvaluateAll() {
  for (const r of results) {
    r.evaluated = evaluate(r.raw, thresholds);
    updateCard(r.raw.fileId, r.evaluated, thresholds);
  }
  if (results.length) {
    renderStats(results, thresholds);
    renderLegend(thresholds);
  }
}

// ---- Analysis Queue (sequential — ffmpeg.wasm is single-threaded) ----
function enqueueFiles(files) {
  if (!isReady()) {
    setStatus('FFmpeg まだ準備中です。少し待ってからもう一度お試しください。');
    return;
  }
  const large = files.filter(f => f.size > 150 * 1024 * 1024);
  if (large.length) {
    const names = large.map(f => f.name).join(', ');
    if (!confirm(`以下のファイルは 150 MB を超えています。ブラウザのメモリが不足する可能性があります。続行しますか？\n\n${names}`)) return;
  }
  queue.push(...files);
  if (!analyzing) runQueue();
}

async function runQueue() {
  analyzing = true;
  document.getElementById('dropZone').classList.add('compact');

  const startCount = results.length;
  const totalNew   = queue.length;

  while (queue.length > 0) {
    const file = queue.shift();
    const done = results.length - startCount;
    showProgress(totalNew, done);

    let raw;
    try {
      raw = await analyzeFile(file, msg => setStatus(msg));
    } catch (e) {
      console.error('Analysis failed for', file.name, e);
      raw = {
        fileId:     crypto.randomUUID(),
        fileName:   file.name,
        fileSize:   file.size,
        durationSec: null, sampleRate: null, channels: null,
        bitDepth: null, codec: null, bitrateKbps: null,
        I: null, TP: null, LRA: null,
        samplePeak: null, dr: null, imbalanceDb: null, phase: null,
      };
      rawStore.set(raw.fileId, raw);
    }

    const evaluated = evaluate(raw, thresholds);
    const result    = { raw, evaluated };
    results.push(result);

    renderCard(result, thresholds);
    renderStats(results, thresholds);
    renderLegend(thresholds);
  }

  showProgress(0, 0);
  setStatus(`完了 — ${results.length} ファイル解析済み`);
  document.getElementById('btnExportCsv').disabled = false;
  document.getElementById('btnClear').disabled = false;
  analyzing = false;
}

// ---- Clear ----
function clearAll() {
  results.length = 0;
  rawStore.clear();
  document.getElementById('tracksArea').innerHTML = '';
  document.getElementById('statsArea').style.display = 'none';
  document.getElementById('legendArea').style.display = 'none';
  document.getElementById('dropZone').classList.remove('compact');
  document.getElementById('btnExportCsv').disabled = true;
  document.getElementById('btnClear').disabled = true;
  setStatus('クリア完了 — ファイルをドロップして再開');
}

// ---- Helpers ----
const SUPPORTED_EXTS = new Set(['.wav', '.flac', '.aif', '.aiff', '.mp3', '.m4a']);
function isSupportedAudio(file) {
  const ext = '.' + file.name.split('.').pop().toLowerCase();
  return SUPPORTED_EXTS.has(ext);
}
