# peakr

Browser-based loudness & dynamics analyzer for audio files. Drag in your tracks, get LUFS / True Peak / LRA / DR / phase metrics instantly — no uploads, no server, everything runs locally via FFmpeg WASM.

## Features

- **Integrated LUFS** (EBU R128) with configurable target and tolerance window
- **True Peak** (dBTP) — flags clips against a configurable ceiling
- **Loudness Range** (LRA) per file
- **Dynamic Range** (DR) via RMS peak analysis
- **Channel Imbalance** — L/R level difference in dB
- **Phase Correlation** — detects phase cancellation on stereo files
- **Sample Rate check** — warn on non-standard rates
- Per-file status: **READY** / **ADJUST** / **ERROR**
- Summary stat chips across all analyzed files
- **CSV export** of all metrics
- All processing runs in-browser (FFmpeg WASM) — no file ever leaves your machine

## Supported Formats

WAV · FLAC · AIFF · MP3 · M4A

## Usage

Open `docs/index.html` in a browser (or serve the `docs/` directory), then:

1. Drop audio files onto the drop zone, or click **ファイルを選択**
2. Files are analyzed sequentially (FFmpeg WASM is single-threaded)
3. Each card shows meters and issues once analysis completes
4. Adjust thresholds in **閾値設定** — cards re-evaluate instantly
5. Click **CSV エクスポート** to save results

## Thresholds

| Setting | Default | Description |
|---|---|---|
| Target LUFS | −9.0 LUFS | Integrated loudness target |
| Tolerance ± | 1.0 LU | Accepted window around target |
| Max True Peak | −0.1 dBTP | Hard ceiling for true peak |
| Phase Cancel | 0.0 | Below this → PHASE CANCEL issue |
| Phase Warn | 0.3 | Below this → PHASE WARN issue |
| Imbalance | 1.5 dB | L/R difference threshold |
| Allowed SR | 44100, 48000 | Comma-separated list of valid sample rates |

## Output Metrics per File

| Metric | Description |
|---|---|
| I | Integrated loudness (LUFS) |
| TP | True Peak (dBTP) |
| LRA | Loudness Range (LU) |
| DR | Dynamic Range (dB) |
| Imbalance | L/R level difference (dB) |
| Phase | Stereo phase correlation (−1 to +1) |
| SR | Sample rate (Hz) |
| Channels | Mono / Stereo |
| Bit depth | PCM bit depth (where available) |
| Bitrate | Encoded bitrate for lossy formats (kbps) |

## Tech Stack

- FFmpeg WASM (`@ffmpeg/ffmpeg`) — runs entirely in-browser
- Vanilla JS (ES modules) — no build step, no framework
- Bricolage Grotesque · Geist · JetBrains Mono (Google Fonts)

## File Structure

```
docs/
  index.html          — UI
  css/style.css       — styles
  js/
    app.js            — entry point, drag-drop, queue
    analyzer.js       — FFmpeg pipeline per file
    evaluator.js      — threshold evaluation (pure function)
    renderer.js       — DOM card/stats/legend rendering
    exporter.js       — CSV export
    ffmpeg-runner.js  — FFmpeg WASM wrapper
```

## License

MIT
