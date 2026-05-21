// Pure function — no FFmpeg, re-run on every threshold change.
export function evaluate(raw, thresholds) {
  const {
    targetLUFS, LUFSTolerance, maxTruePeak,
    phaseCancelThreshold, phaseWarnThreshold,
    imbalanceThreshold, allowedSampleRates,
  } = thresholds;

  const issues = [];

  const analysisOk = raw.I != null && raw.TP != null && raw.LRA != null;
  if (!analysisOk) issues.push('ANALYSIS ERROR');

  const srOk = !raw.sampleRate || allowedSampleRates.includes(raw.sampleRate);
  if (!srOk) issues.push('SAMPLE RATE CHECK');

  let withinLUFS = false;
  if (raw.I != null) {
    if (raw.I > targetLUFS + LUFSTolerance)      issues.push('LUFS HIGH');
    else if (raw.I < targetLUFS - LUFSTolerance) issues.push('LUFS LOW');
    else withinLUFS = true;
  }

  let phaseOk = true;
  let imbalanceOk = true;

  if (raw.phase != null) {
    if (raw.phase.avg < phaseCancelThreshold) {
      issues.push('PHASE CANCEL');
      phaseOk = false;
    } else if (raw.phase.avg < phaseWarnThreshold) {
      issues.push('PHASE WARN');
    }
  }

  if (raw.imbalanceDb != null && Math.abs(raw.imbalanceDb) > imbalanceThreshold) {
    issues.push('IMBALANCE');
    imbalanceOk = false;
  }

  // srOk is Issues-only, does not affect status (matching PS1 behaviour)
  const status =
    !analysisOk                              ? 'ERROR'  :
    withinLUFS && phaseOk && imbalanceOk     ? 'READY'  :
                                               'ADJUST';

  return { status, issues };
}
