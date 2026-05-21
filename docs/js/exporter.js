function fmt(v, dec) {
  return v != null ? v.toFixed(dec) : '';
}

function formatDuration(sec) {
  if (sec == null) return '';
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${m}:${s.toString().padStart(2, '0')}`;
}

function csvRow(cells) {
  return cells.map(c => `"${String(c ?? '').replace(/"/g, '""')}"`).join(',');
}

export function exportCsv(results) {
  const header = csvRow([
    'File', 'Duration', 'SampleRate_Hz', 'Bitrate_kbps', 'BitDepth', 'Channels', 'Codec',
    'IntegratedLUFS', 'TruePeak_dBTP', 'SamplePeak_dBFS', 'LRA', 'DR',
    'PhaseCorr_Avg', 'PhaseCorr_Min', 'Imbalance_dB', 'Status', 'Issues',
  ]);

  const rows = results.map(({ raw, evaluated }) => csvRow([
    raw.fileName,
    formatDuration(raw.durationSec),
    raw.sampleRate ?? '',
    raw.bitrateKbps ?? '',
    raw.bitDepth ?? '',
    raw.channels ?? '',
    raw.codec ?? '',
    fmt(raw.I, 2),
    fmt(raw.TP, 2),
    fmt(raw.samplePeak, 2),
    fmt(raw.LRA, 1),
    fmt(raw.dr, 1),
    fmt(raw.phase?.avg, 3),
    fmt(raw.phase?.min, 3),
    fmt(raw.imbalanceDb, 2),
    evaluated.status,
    evaluated.issues.length ? evaluated.issues.join('|') : 'NONE',
  ]));

  const csv = '﻿' + [header, ...rows].join('\r\n');
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
  const url  = URL.createObjectURL(blob);
  const a    = document.createElement('a');
  a.href = url;
  a.download = `loudness_report_${new Date().toISOString().replace(/[:.]/g, '').slice(0, 15)}.csv`;
  a.click();
  URL.revokeObjectURL(url);
}
