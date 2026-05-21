import {
  writeFile, deleteFile,
  probeFile, runLoudnorm, runAstats, runAphasemeter,
} from './ffmpeg-runner.js';

export const rawStore = new Map(); // fileId → raw metrics

export async function analyzeFile(file, onProgress) {
  const fileId = crypto.randomUUID();
  const ext    = file.name.split('.').pop().toLowerCase();
  const name   = `in_${fileId.slice(0, 8)}.${ext}`;

  onProgress(`${file.name}: writing file...`);
  await writeFile(name, file);

  try {
    onProgress(`${file.name}: reading metadata...`);
    const probe = await probeFile(name);

    onProgress(`${file.name}: analyzing loudness...`);
    const loudnorm = await runLoudnorm(name);

    onProgress(`${file.name}: analyzing peak & dynamics...`);
    const astats = await runAstats(name);

    let phase = null;
    if (probe.channels === 2) {
      onProgress(`${file.name}: analyzing phase...`);
      phase = await runAphasemeter(name);
    }

    const raw = {
      fileId,
      fileName: file.name,
      fileSize: file.size,
      ...probe,
      I:          loudnorm?.I   ?? null,
      TP:         loudnorm?.TP  ?? null,
      LRA:        loudnorm?.LRA ?? null,
      samplePeak: astats?.samplePeak ?? null,
      dr:         astats?.dr         ?? null,
      imbalanceDb: astats?.imbalanceDb ?? null,
      phase,
    };

    rawStore.set(fileId, raw);
    return raw;

  } finally {
    await deleteFile(name);
  }
}
