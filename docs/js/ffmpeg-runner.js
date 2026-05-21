let ffmpeg = null;
let FFmpegLib = null;
let UtilLib = null;

export async function initFFmpeg(onStatus) {
  onStatus('FFmpeg WASM をロード中...');

  FFmpegLib = await import('https://cdn.jsdelivr.net/npm/@ffmpeg/ffmpeg@0.12.10/dist/esm/index.js');
  UtilLib   = await import('https://cdn.jsdelivr.net/npm/@ffmpeg/util@0.12.1/dist/esm/index.js');

  ffmpeg = new FFmpegLib.FFmpeg();

  const coreBase   = 'https://cdn.jsdelivr.net/npm/@ffmpeg/core@0.12.6/dist/esm';
  const ffmpegBase = 'https://cdn.jsdelivr.net/npm/@ffmpeg/ffmpeg@0.12.10/dist/esm';

  // Rewrite relative imports in worker.js to absolute CDN URLs so it runs from a blob URL.
  const workerSrc = await fetch(`${ffmpegBase}/worker.js`).then(r => r.text());
  const patchedWorker = workerSrc.replace(
    /from\s+"(\.\/[^"]+)"/g,
    (_, rel) => `from "${ffmpegBase}/${rel.slice(2)}"`
  );
  const workerBlob = new Blob([patchedWorker], { type: 'text/javascript' });
  const workerLoadURL = URL.createObjectURL(workerBlob);

  await ffmpeg.load({
    classWorkerURL: workerLoadURL,
    coreURL:  await UtilLib.toBlobURL(`${coreBase}/ffmpeg-core.js`,   'text/javascript'),
    wasmURL:  await UtilLib.toBlobURL(`${coreBase}/ffmpeg-core.wasm`, 'application/wasm'),
  });

  onStatus('FFmpeg 準備完了 — ファイルをドロップして分析を開始');
}

export function isReady() {
  return ffmpeg !== null;
}

export async function writeFile(name, file) {
  const data = await UtilLib.fetchFile(file);
  await ffmpeg.writeFile(name, data);
}

export async function deleteFile(name) {
  try { await ffmpeg.deleteFile(name); } catch (_) { /* already gone */ }
}

// Capture all stderr lines emitted during exec
async function execCapture(args) {
  const lines = [];
  const handler = ({ message }) => lines.push(message);
  ffmpeg.on('log', handler);
  try {
    await ffmpeg.exec(args);
  } catch (_) {
    // non-zero exit is normal for -f null
  }
  ffmpeg.off('log', handler);
  return lines;
}

// ---- Pass 1: loudnorm → LUFS / True Peak / LRA ----
export async function runLoudnorm(inputName) {
  // TP parameter must be in [-9, 0]; pass -1 as a safe fixed value.
  const lines = await execCapture([
    '-hide_banner', '-i', inputName,
    '-af', 'loudnorm=I=-23:TP=-1:LRA=8:print_format=json',
    '-f', 'null', '-',
  ]);

  // JSON block appears at end of stderr, bounded by { … }
  let inBlock = false;
  const jsonLines = [];
  for (const l of lines) {
    if (!inBlock && l.includes('{')) { inBlock = true; }
    if (inBlock) jsonLines.push(l);
    if (inBlock && l.includes('}')) break;
  }
  if (!jsonLines.length) return null;
  try {
    const obj = JSON.parse(jsonLines.join('\n'));
    const I  = parseFloat(obj.input_i);
    const TP = parseFloat(obj.input_tp);
    const LRA = parseFloat(obj.input_lra);
    if (!isFinite(I) || !isFinite(TP) || !isFinite(LRA)) return null;
    return { I, TP, LRA };
  } catch (_) {
    return null;
  }
}

// ---- Pass 2: astats → Sample Peak / RMS / DR / Imbalance ----
export async function runAstats(inputName) {
  const lines = await execCapture([
    '-hide_banner', '-i', inputName,
    '-af', 'astats=metadata=1:reset=0,ametadata=print',
    '-f', 'null', '-',
  ]);

  const peakVals = [], rmsVals = [], rms1 = [], rms2 = [];
  for (const l of lines) {
    let m;
    if ((m = l.match(/lavfi\.astats\.Overall\.Peak_level=([-\d.]+)/)))  peakVals.push(+m[1]);
    if ((m = l.match(/lavfi\.astats\.Overall\.RMS_level=([-\d.]+)/)))   rmsVals.push(+m[1]);
    if ((m = l.match(/lavfi\.astats\.1\.RMS_level=([-\d.]+)/)))         rms1.push(+m[1]);
    if ((m = l.match(/lavfi\.astats\.2\.RMS_level=([-\d.]+)/)))         rms2.push(+m[1]);
  }

  const safeMax = arr => arr.length ? Math.max(...arr) : null;
  const samplePeak = safeMax(peakVals);
  const rmsLevel   = safeMax(rmsVals);
  const rmsL       = safeMax(rms1);
  const rmsR       = safeMax(rms2);

  const dr = (samplePeak != null && rmsLevel != null)
    ? Math.round((samplePeak - rmsLevel) * 10) / 10
    : null;
  const imbalanceDb = (rmsL != null && rmsR != null)
    ? Math.round((rmsL - rmsR) * 100) / 100
    : null;

  return { samplePeak, rmsLevel, dr, imbalanceDb };
}

// ---- Pass 3: aphasemeter → Phase correlation (stereo only) ----
export async function runAphasemeter(inputName) {
  const lines = await execCapture([
    '-hide_banner', '-i', inputName,
    '-af', 'aphasemeter=video=0,ametadata=print',
    '-f', 'null', '-',
  ]);

  const vals = [];
  for (const l of lines) {
    const m = l.match(/lavfi\.aphasemeter\.phase=([-\d.]+)/);
    if (m) vals.push(+m[1]);
  }
  if (!vals.length) return null;

  const avg = vals.reduce((a, b) => a + b, 0) / vals.length;
  const min = Math.min(...vals);
  return {
    avg: Math.round(avg * 1000) / 1000,
    min: Math.round(min * 1000) / 1000,
  };
}

// ---- Probe: parse ffmpeg header stderr for metadata ----
export async function probeFile(inputName) {
  const lines = await execCapture([
    '-hide_banner', '-v', 'info', '-i', inputName,
    '-f', 'null', '-',
  ]);

  let durationSec = null, sampleRate = null, channels = null;
  let bitDepth = null, codec = null, bitrateKbps = null;

  for (const l of lines) {
    const dur = l.match(/Duration:\s*(\d+):(\d+):(\d+\.?\d*)/);
    if (dur) durationSec = +dur[1] * 3600 + +dur[2] * 60 + +dur[3];

    const br = l.match(/bitrate:\s*(\d+)\s*kb\/s/);
    if (br) bitrateKbps = +br[1];

    // "Stream #0:0: Audio: pcm_s16le, 44100 Hz, stereo, s16"
    const stream = l.match(/Audio:\s*([\w]+),\s*(\d+)\s*Hz,\s*(stereo|mono|[\d\s\w]+channels?)/i);
    if (stream) {
      codec = stream[1];
      sampleRate = +stream[2];
      const ch = stream[3].toLowerCase().trim();
      channels = ch === 'stereo' ? 2 : ch === 'mono' ? 1 : parseInt(ch) || null;
    }

    const bd = l.match(/\b(s8|s16|s24|s32|u8)\b/i);
    if (bd) {
      const map = { s8: 8, u8: 8, s16: 16, s24: 24, s32: 32 };
      bitDepth = map[bd[1].toLowerCase()] ?? null;
    }
  }

  return { durationSec, sampleRate, channels, bitDepth, codec, bitrateKbps };
}
