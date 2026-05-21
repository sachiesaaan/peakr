param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Paths
)

# -----------------------------
# Resolve Tool Root (PS1 lives in .\app\)
# -----------------------------
$ToolRoot = Split-Path -Parent $PSScriptRoot

# -----------------------------
# Config loader (must be defined before Settings)
# -----------------------------
function Read-ConfigIni([string]$Path) {
  $cfg = @{}
  if (-not (Test-Path -LiteralPath $Path)) { return $cfg }
  foreach ($line in (Get-Content -LiteralPath $Path)) {
    $line = $line.Trim()
    if (-not $line -or $line -like '#*' -or $line -like ';*' -or $line -like '[*') { continue }
    if ($line -match '^\s*([^=]+?)\s*=\s*(.*)$') {
      $cfg[$Matches[1].Trim()] = $Matches[2].Trim()
    }
  }
  return $cfg
}
$cfg = Read-ConfigIni (Join-Path $ToolRoot "config.ini")

# -----------------------------
# Settings (defaults overridden by config.ini when present)
# -----------------------------
$extStr        = if ($cfg['SupportedExts'])       { $cfg['SupportedExts']       } else { ".wav,.flac,.aif,.aiff,.mp3,.m4a" }
$SupportedExts = @($extStr -split ',' | ForEach-Object { $_.Trim() })

$RecurseFolders = if ($cfg['RecurseFolders']) { $cfg['RecurseFolders'] -eq 'true' } else { $true }

$TargetLUFS    = if ($cfg['TargetLUFS'])    { [double]$cfg['TargetLUFS']    } else { -14.0 }
$LUFSTolerance = if ($cfg['LUFSTolerance']) { [double]$cfg['LUFSTolerance'] } else { 0.5   }
$MaxTruePeak   = if ($cfg['MaxTruePeak'])   { [double]$cfg['MaxTruePeak']   } else { -1.0  }

$srStr              = if ($cfg['AllowedSampleRates']) { $cfg['AllowedSampleRates'] } else { "44100,48000" }
$AllowedSampleRates = @($srStr -split ',' | ForEach-Object { [int]$_.Trim() })

$WriteRawLoudnormDumpOnFailure = if ($cfg['WriteRawLoudnormDumpOnFailure']) { $cfg['WriteRawLoudnormDumpOnFailure'] -eq 'true' } else { $true }
$ShowDebugLines                = if ($cfg['ShowDebugLines'])                { $cfg['ShowDebugLines']                -eq 'true' } else { $false }

$PhaseCancelThreshold = if ($cfg['PhaseCancelThreshold']) { [double]$cfg['PhaseCancelThreshold'] } else { 0.0  }
$PhaseWarnThreshold   = if ($cfg['PhaseWarnThreshold'])   { [double]$cfg['PhaseWarnThreshold']   } else { 0.3  }
$ImbalanceThreshold   = if ($cfg['ImbalanceThreshold'])   { [double]$cfg['ImbalanceThreshold']   } else { 1.5  }


# -----------------------------
# Splash Banner (v1.2)
# -----------------------------
Clear-Host

$bannerColor = "Magenta"
$lineColor   = "DarkMagenta"
$version     = "1.2"

Write-Host ""
Write-Host "==================================================" -ForegroundColor $lineColor
Write-Host "                    LUFS Lens                     " -ForegroundColor $bannerColor
Write-Host ("                    Version {0}                    " -f $version) -ForegroundColor $bannerColor
Write-Host "==================================================" -ForegroundColor $lineColor
Write-Host ""
Write-Host "Independent loudness analysis utility."
Write-Host "Because it sounded louder in the studio."
Write-Host ""
Write-Host "Contact: lufslens@gmail.com"
Write-Host ""
Write-Host "==================================================" -ForegroundColor $lineColor
Write-Host ""

Write-Host "Initializing loudness inspection..." -ForegroundColor Yellow
Start-Sleep -Milliseconds 300
Write-Host "Calibrating peak detectors..." -ForegroundColor Yellow
Start-Sleep -Milliseconds 300
Write-Host "Preparing loudness verdict..." -ForegroundColor Yellow
Start-Sleep -Milliseconds 300
Write-Host ""

# -----------------------------
# Helpers
# -----------------------------
function Get-AudioFilesFromPath([string]$p) {
  if (-not $p) { return @() }
  $p = "$p".Trim().Trim('"')
  if (-not (Test-Path -LiteralPath $p)) { return @() }

  if (Test-Path -LiteralPath $p -PathType Container) {
    $opts = @{ Path = $p; File = $true }
    if ($RecurseFolders) { $opts.Recurse = $true }
    return Get-ChildItem @opts | Where-Object { $SupportedExts -contains $_.Extension.ToLower() }
  }

  if (Test-Path -LiteralPath $p -PathType Leaf) {
    $item = Get-Item -LiteralPath $p
    if ($SupportedExts -contains $item.Extension.ToLower()) { return @($item) }
  }

  return @()
}

function Format-Duration([double]$seconds) {
  if ($null -eq $seconds -or $seconds -le 0) { return "" }
  $ts = [TimeSpan]::FromSeconds($seconds)
  return "{0}:{1:D2}" -f [int]$ts.TotalMinutes, $ts.Seconds
}

function Get-Base64ImageDataUri {
  param([Parameter(Mandatory = $true)][string]$ImagePath)
  if (-not (Test-Path -LiteralPath $ImagePath)) { return $null }
  $ext = ([IO.Path]::GetExtension($ImagePath)).ToLowerInvariant()
  $mime = switch ($ext) {
    ".png"  { "image/png" }
    ".jpg"  { "image/jpeg" }
    ".jpeg" { "image/jpeg" }
    ".gif"  { "image/gif" }
    ".svg"  { "image/svg+xml" }
    default { "application/octet-stream" }
  }
  try {
    $bytes = [IO.File]::ReadAllBytes($ImagePath)
    $b64   = [Convert]::ToBase64String($bytes)
    return "data:$mime;base64,$b64"
  } catch { return $null }
}

function Normalize-InputPaths([string[]]$InPaths) {
  $out = New-Object System.Collections.Generic.List[string]
  if (-not $InPaths -or $InPaths.Count -eq 0) { return @() }

  if ($InPaths.Count -eq 1) {
    $first = "$($InPaths[0])".Trim()
    if ($first -like '@*') {
      $listFile = $first.Substring(1).Trim().Trim('"')
      if (Test-Path -LiteralPath $listFile) {
        $lines = Get-Content -LiteralPath $listFile | Where-Object { $_ -and $_.Trim() -ne "" }
        foreach ($ln in $lines) {
          $s = "$ln".Trim().Trim('"')
          if ($s) { $out.Add($s) }
        }
        return $out.ToArray()
      }
    }
  }

  foreach ($p in $InPaths) {
    if ($null -eq $p) { continue }
    $s = "$p".Trim().Trim('"')
    if (-not $s) { continue }
    if ($s -like '*|*') {
      foreach ($part in ($s -split '\|')) {
        $t = "$part".Trim().Trim('"')
        if ($t) { $out.Add($t) }
      }
    } else {
      $out.Add($s)
    }
  }
  return $out.ToArray()
}

function Get-TrackNumber([string]$name) {
  # Matches leading number: "01 Title", "01_Title", "01-Title", "01.Title"
  if ($name -match '^(\d{1,3})[\s_\-\.]') { return [int]$Matches[1] }
  # Matches "Track 01", "Disc 01" style
  if ($name -match '[Tt]rack\s*(\d{1,3})') { return [int]$Matches[1] }
  return 9999
}

# -----------------------------
# Locate ffmpeg/ffprobe (bundled preferred)
# -----------------------------
$ffmpeg  = Join-Path $ToolRoot "ffmpeg\bin\ffmpeg.exe"
$ffprobe = Join-Path $ToolRoot "ffmpeg\bin\ffprobe.exe"

if (-not (Test-Path $ffmpeg)) {
  $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if ($cmd) { $ffmpeg = $cmd.Source }
}
if (-not (Test-Path $ffprobe)) {
  $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
  if ($cmd) { $ffprobe = $cmd.Source }
}

if (-not (Test-Path $ffmpeg) -or -not (Test-Path $ffprobe)) {
  Write-Host "ERROR: ffmpeg/ffprobe not found." -ForegroundColor Red
  Write-Host "Fix: bundle them in .\ffmpeg\bin\ OR install FFmpeg and ensure ffmpeg/ffprobe are in PATH."
  exit 1
}

# -----------------------------
# Input paths
# -----------------------------
if (-not $Paths -or $Paths.Count -eq 0) {
  $Paths = @((Get-Location).Path)
}
$Paths = Normalize-InputPaths $Paths

# -----------------------------
# Collect files
# -----------------------------
$files = @()
foreach ($p in $Paths) { $files += Get-AudioFilesFromPath $p }
$files = $files | Sort-Object FullName -Unique

if (-not $files -or $files.Count -eq 0) {
  Write-Host "No supported audio files found." -ForegroundColor Yellow
  Write-Host "Supported: WAV, FLAC, AIFF, MP3, M4A"
  exit 0
}

# -----------------------------
# Output / temp folders (always inside tool root)
# -----------------------------
$timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$reportsDir = Join-Path $ToolRoot "Reports"
$tempDir    = Join-Path $ToolRoot "temp"

foreach ($d in @($reportsDir, $tempDir)) {
  if (-not (Test-Path -LiteralPath $d)) {
    New-Item -ItemType Directory -Path $d | Out-Null
  }
}

$outCsv  = Join-Path $reportsDir "loudness_report_$timestamp.csv"
$outHtml = Join-Path $reportsDir "loudness_report_$timestamp.html"

Write-Host "Analyzing $($files.Count) file(s)..."
Write-Host "Output CSV: $outCsv`n"

# -----------------------------
# Main loop
# -----------------------------
$results = foreach ($file in $files) {
  Write-Host "Analyzing $($file.Name)..."

  # ---- ffprobe: duration, SR, bit depth, channels, codec, bitrate ----
  $durationSec = $null
  $sampleRate  = $null
  $bitDepth    = $null
  $channels    = $null
  $codec       = $null
  $bitrateKbps = $null

  try {
    $probeJson = & $ffprobe -v error -select_streams a:0 `
      -show_entries format=duration,bit_rate `
      -show_entries stream=sample_rate,bits_per_sample,bits_per_raw_sample,channels,codec_name,bit_rate `
      -of json "$($file.FullName)" 2>$null

    $probe = $probeJson | ConvertFrom-Json

    $dText = [string]$probe.format.duration
    if ($dText -match '(-?\d+(\.\d+)?)') { $durationSec = [double]$Matches[1] }

    $stream = $probe.streams | Select-Object -First 1
    if ($stream) {
      if ($stream.sample_rate) { $sampleRate = [int]$stream.sample_rate }

      if ($stream.bits_per_sample) { $bitDepth = [int]$stream.bits_per_sample }
      elseif ($stream.bits_per_raw_sample) { $bitDepth = [int]$stream.bits_per_raw_sample }

      if ($stream.channels) { $channels = [int]$stream.channels }
      $codec = $stream.codec_name

      $br = $null
      if ($stream.bit_rate) { $br = [int64]$stream.bit_rate }
      elseif ($probe.format.bit_rate) { $br = [int64]$probe.format.bit_rate }

      if ($br -and $br -gt 0) { $bitrateKbps = [math]::Round($br / 1000) }
    }
  } catch { }

  $durationStr = if ($durationSec) { Format-Duration $durationSec } else { "" }

  # ---- loudnorm: Integrated LUFS, True Peak, LRA ----
  $I = $null; $TP = $null; $LRA = $null

  $targetStr = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.###}", $TargetLUFS)
  $tpStr     = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.###}", $MaxTruePeak)

  $loudnormFilter = "loudnorm=I=${targetStr}:TP=${tpStr}:LRA=8:print_format=json"
  if ($ShowDebugLines) { Write-Host "LOUDNORM FILTER: $loudnormFilter" }

  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $logLN = & $ffmpeg -hide_banner -i "$($file.FullName)" `
    -af "$loudnormFilter" `
    -f null - 2>&1
  $ErrorActionPreference = $oldEap
  $logLN = $logLN | ForEach-Object { $_.ToString() }

  $idxHit = ($logLN | Select-String -Pattern '"input_i"\s*:' | Select-Object -First 1)

  if ($idxHit) {
    $i0    = $idxHit.LineNumber - 1
    $start = $i0
    while ($start -ge 0 -and ($logLN[$start] -notmatch '\{')) { $start-- }
    $end = $i0
    while ($end -lt $logLN.Count -and ($logLN[$end] -notmatch '\}')) { $end++ }

    if ($start -ge 0 -and $end -lt $logLN.Count) {
      $jsonText = ($logLN[$start..$end] -join "`n")
      try {
        $json = $jsonText | ConvertFrom-Json
        $I   = [double]$json.input_i
        $TP  = [double]$json.input_tp
        $LRA = [double]$json.input_lra
      } catch {
        if ($WriteRawLoudnormDumpOnFailure) {
          $dbg1 = Join-Path $reportsDir "debug_RAW_loudnorm_$($file.BaseName)_$timestamp.txt"
          $dbg2 = Join-Path $reportsDir "debug_JSON_loudnorm_$($file.BaseName)_$timestamp.txt"
          ($logLN -join "`n") | Out-File -Encoding UTF8 $dbg1
          $jsonText | Out-File -Encoding UTF8 $dbg2
        }
      }
    }
  } else {
    if ($WriteRawLoudnormDumpOnFailure) {
      $dbg1 = Join-Path $reportsDir "debug_RAW_loudnorm_$($file.BaseName)_$timestamp.txt"
      ($logLN -join "`n") | Out-File -Encoding UTF8 $dbg1
    }
  }


  # ---- astats: sample peak (dBFS) + RMS level -> DR ----
  $samplePeak = $null
  $dr         = $null

  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $logPeak = & $ffmpeg -hide_banner -i "$($file.FullName)" `
    -af "astats=metadata=1:reset=0,ametadata=print" `
    -f null - 2>&1
  $ErrorActionPreference = $oldEap
  $logPeak = $logPeak | ForEach-Object { $_.ToString() }

  $peakVals  = New-Object System.Collections.Generic.List[double]
  $rmsVals   = New-Object System.Collections.Generic.List[double]
  $rmsVals1  = New-Object System.Collections.Generic.List[double]
  $rmsVals2  = New-Object System.Collections.Generic.List[double]
  foreach ($line in $logPeak) {
    if ($line -match 'lavfi\.astats\.Overall\.Peak_level=([-]?\d+(\.\d+)?)') {
      $peakVals.Add([double]$Matches[1])
    }
    if ($line -match 'lavfi\.astats\.Overall\.RMS_level=([-]?\d+(\.\d+)?)') {
      $rmsVals.Add([double]$Matches[1])
    }
    if ($line -match 'lavfi\.astats\.1\.RMS_level=([-]?\d+(\.\d+)?)') {
      $rmsVals1.Add([double]$Matches[1])
    }
    if ($line -match 'lavfi\.astats\.2\.RMS_level=([-]?\d+(\.\d+)?)') {
      $rmsVals2.Add([double]$Matches[1])
    }
  }

  if ($peakVals.Count -gt 0) {
    $samplePeak = [math]::Round(($peakVals | Measure-Object -Maximum).Maximum, 2)
  }
  $rmsLevel = $null
  if ($rmsVals.Count -gt 0) {
    $rmsLevel = [math]::Round(($rmsVals | Measure-Object -Maximum).Maximum, 2)
  }
  if ($null -ne $samplePeak -and $null -ne $rmsLevel) {
    $dr = [math]::Round($samplePeak - $rmsLevel, 1)
  }

  # ---- aphasemeter: phase correlation + channel imbalance (stereo only) ----
  $phaseCorr    = $null
  $phaseCorrMin = $null
  $imbalanceDb  = $null

  if ($channels -eq 2) {
    if ($rmsVals1.Count -gt 0 -and $rmsVals2.Count -gt 0) {
      $rmsL        = ($rmsVals1 | Measure-Object -Maximum).Maximum
      $rmsR        = ($rmsVals2 | Measure-Object -Maximum).Maximum
      $imbalanceDb = [math]::Round($rmsL - $rmsR, 2)
    }

    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $logPhase = & $ffmpeg -hide_banner -i "$($file.FullName)" `
      -af "aphasemeter=video=0,ametadata=print" `
      -f null - 2>&1
    $ErrorActionPreference = $oldEap
    $logPhase = $logPhase | ForEach-Object { $_.ToString() }

    $phaseVals = New-Object System.Collections.Generic.List[double]
    foreach ($line in $logPhase) {
      if ($line -match 'lavfi\.aphasemeter\.phase=([-]?\d+(\.\d+)?)') {
        $phaseVals.Add([double]$Matches[1])
      }
    }
    if ($phaseVals.Count -gt 0) {
      $phaseCorr    = [math]::Round(($phaseVals | Measure-Object -Average).Average, 3)
      $phaseCorrMin = [math]::Round(($phaseVals | Measure-Object -Minimum).Minimum, 3)
    }
  }

  # ---- Status + Issues ----
  $issues     = @()
  $analysisOk = ($null -ne $I -and $null -ne $TP -and $null -ne $LRA)
  if (-not $analysisOk) { $issues += "ANALYSIS ERROR" }

  $srOk = ($null -eq $sampleRate -or ($AllowedSampleRates -contains $sampleRate))
  if (-not $srOk) { $issues += "SAMPLE RATE CHECK" }

  $withinLUFS = ($null -ne $I -and [math]::Abs($I - $TargetLUFS) -le $LUFSTolerance)
  if ($null -ne $I) {
    if ($I -gt ($TargetLUFS + $LUFSTolerance)) { $issues += "LUFS HIGH" }
    elseif ($I -lt ($TargetLUFS - $LUFSTolerance)) { $issues += "LUFS LOW" }
  }

  $phaseOk    = $true
  $imbalanceOk = $true
  if ($null -ne $phaseCorr) {
    if ($phaseCorr -lt $PhaseCancelThreshold) { $issues += "PHASE CANCEL"; $phaseOk = $false }
    elseif ($phaseCorr -lt $PhaseWarnThreshold) { $issues += "PHASE WARN" }
  }
  if ($null -ne $imbalanceDb -and [math]::Abs($imbalanceDb) -gt $ImbalanceThreshold) {
    $issues += "IMBALANCE"; $imbalanceOk = $false
  }

  $status =
    if (-not $analysisOk) { "ERROR" }
    elseif ($withinLUFS -and $srOk -and $phaseOk -and $imbalanceOk) { "READY" }
    else { "ADJUST" }

  $issuesText = if ($issues.Count -gt 0) { $issues -join "|" } else { "NONE" }

  [PSCustomObject]@{
    File             = $file.Name
    Duration         = $durationStr
    SampleRate_Hz    = $sampleRate
    Bitrate_kbps     = $bitrateKbps
    BitDepth         = $bitDepth
    Channels         = $channels
    Codec            = $codec
    IntegratedLUFS   = $I
    TruePeak_dBTP    = $TP
    SamplePeak_dBFS  = $samplePeak
    LRA              = $LRA
    DR               = $dr
    PhaseCorr_Avg    = $phaseCorr
    PhaseCorr_Min    = $phaseCorrMin
    Imbalance_dB     = $imbalanceDb
    Status           = $status
    Issues           = $issuesText
    Path             = $file.FullName
  }
}

# -----------------------------
# Write CSV
# -----------------------------
$results | Sort-Object File | Export-Csv -Path $outCsv -NoTypeInformation -Encoding UTF8
Write-Host "`nDone. CSV saved to: $outCsv"

# -----------------------------
# Summary
# -----------------------------
$total      = @($results).Count
$ready      = @(@($results) | Where-Object { ("$($_.Status)".Trim().ToUpper()) -eq "READY"  }).Count
$adjust     = @(@($results) | Where-Object { ("$($_.Status)".Trim().ToUpper()) -eq "ADJUST" }).Count
$errorCount = @(@($results) | Where-Object { ("$($_.Status)".Trim().ToUpper()) -eq "ERROR"  }).Count

$avgLUFS = ($results | Where-Object { $_.IntegratedLUFS -ne $null } | Measure-Object IntegratedLUFS -Average).Average
$avgLRA  = ($results | Where-Object { $_.LRA            -ne $null } | Measure-Object LRA            -Average).Average
$avgDR   = ($results | Where-Object { $_.DR             -ne $null } | Measure-Object DR             -Average).Average

Write-Host ("Summary: {0} file(s) | READY: {1} | ADJUST: {2} | ERROR: {3}" -f $total, $ready, $adjust, $errorCount)
if ($null -ne $avgLUFS) { Write-Host ("Average Integrated LUFS: {0:N2}" -f $avgLUFS) }
if ($null -ne $avgLRA)  { Write-Host ("Average LRA:             {0:N2}" -f $avgLRA)  }
if ($null -ne $avgDR)   { Write-Host ("Average DR:              {0:N1}" -f $avgDR)   }

# -----------------------------
# HTML report
# -----------------------------

# Sort by track number, then filename
$sortedResults = @($results | Sort-Object { Get-TrackNumber $_.File }, File)

# Pre-compute album stats for header
$validLUFS  = @($sortedResults | Where-Object { $null -ne $_.IntegratedLUFS })
$validPhase = @($sortedResults | Where-Object { $null -ne $_.PhaseCorr_Avg })
$validDRv   = @($sortedResults | Where-Object { $null -ne $_.DR })

$avgL    = if ($validLUFS.Count  -gt 0) { [math]::Round(($validLUFS  | Measure-Object IntegratedLUFS  -Average).Average, 1) } else { $null }
$maxL    = if ($validLUFS.Count  -gt 0) { [math]::Round(($validLUFS  | Measure-Object IntegratedLUFS  -Maximum).Maximum, 1) } else { $null }
$minL    = if ($validLUFS.Count  -gt 0) { [math]::Round(($validLUFS  | Measure-Object IntegratedLUFS  -Minimum).Minimum, 1) } else { $null }
$spreadL = if ($null -ne $maxL -and $null -ne $minL) { [math]::Round($maxL - $minL, 1) } else { $null }
$avgPhaseAlbum = if ($validPhase.Count -gt 0) { [math]::Round(($validPhase | Measure-Object PhaseCorr_Avg -Average).Average, 3) } else { $null }
$minPhaseAlbum = if ($validPhase.Count -gt 0) { [math]::Round(($validPhase | Measure-Object PhaseCorr_Avg -Minimum).Minimum, 3) } else { $null }
$avgDRAlbum    = if ($validDRv.Count   -gt 0) { [math]::Round(($validDRv   | Measure-Object DR           -Average).Average, 1) } else { $null }

# Stat card values
$lufsCardVal    = if ($null -ne $avgL)    { "$avgL LUFS" }    else { "n/a" }
$spreadCardVal  = if ($null -ne $spreadL) { "$spreadL LU" }   else { "n/a" }
$spreadCardCls  = if ($null -ne $spreadL -and $spreadL -gt 3) { "warn" } else { "" }
$phaseCardVal   = if ($null -ne $avgPhaseAlbum) { "$avgPhaseAlbum" } else { "n/a" }
$phaseCardCls   = if ($null -ne $minPhaseAlbum -and $minPhaseAlbum -lt $PhaseCancelThreshold) { "bad" } elseif ($null -ne $minPhaseAlbum -and $minPhaseAlbum -lt $PhaseWarnThreshold) { "warn" } else { "" }
$drCardVal      = if ($null -ne $avgDRAlbum) { "DR $avgDRAlbum" } else { "n/a" }
$readyCardCls   = if ($ready -eq $total) { "good" } elseif ($ready -gt 0) { "" } else { "bad" }

# LUFS meter geometry
$dispMin   = -24.0
$dispMax   = -6.0
$dispRange = $dispMax - $dispMin
$targetPct = [math]::Round(($TargetLUFS - $dispMin) / $dispRange * 100, 1)
$tolLoPct  = [math]::Round(($TargetLUFS - $LUFSTolerance - $dispMin) / $dispRange * 100, 1)
$tolHiPct  = [math]::Round(($TargetLUFS + $LUFSTolerance - $dispMin) / $dispRange * 100, 1)
$tolWidPct = [math]::Round($tolHiPct - $tolLoPct, 1)

# Logo
$logoPath    = Join-Path $ToolRoot "assets\logo\LufsLensLogo.png"
$logoDataUri = Get-Base64ImageDataUri -ImagePath $logoPath
$logoHtml    = if ($logoDataUri) { "<img src='$logoDataUri' alt='LUFS Lens'>" } else { "" }

$csvUri      = "file:///" + ($outCsv -replace '\\','/')
$kofiUrl     = "https://ko-fi.com/lufslens"
$limQuotes   = @(
  "Blessed are the quiet, for they shall inherit the headroom.",
  "In limiter we trust, but in LUFS we verify.",
  "Thou shalt not clip.",
  "If it's red, it's dead.",
  "Ask not what your limiter can do for you. Ask what you did to your transients.",
  "Peak performance requires peak restraint.",
  "All roads lead to -14 LUFS."
)
$randomQuote = Get-Random -InputObject $limQuotes

# Build track cards
$trackCards = foreach ($r in $sortedResults) {
  $statusCls = $r.Status
  $fileUri   = "file:///" + ($r.Path -replace '\\','/')

  # LUFS meter
  $lufsMeter = ""
  if ($null -ne $r.IntegratedLUFS) {
    $fillPct  = [math]::Max(0, [math]::Min(100, [math]::Round(($r.IntegratedLUFS - $dispMin) / $dispRange * 100, 1)))
    $fillCls  = switch ($r.Status) { 'READY' { 'ok' } 'ADJUST' { 'warn' } default { 'err' } }
    $lufsVal  = "{0:N1}" -f $r.IntegratedLUFS
    $lufsMeter = @"
<div class='meter-row'>
  <span class='m-label'>LUFS</span>
  <div class='m-track'>
    <div class='m-tol' style='left:${tolLoPct}%;width:${tolWidPct}%;'></div>
    <div class='m-fill $fillCls' style='width:${fillPct}%;'></div>
    <div class='m-target' style='left:${targetPct}%;'></div>
  </div>
  <span class='m-val'>$lufsVal</span>
</div>
"@
  }

  # Phase meter
  $phaseMeter = ""
  if ($null -ne $r.PhaseCorr_Avg) {
    $phMarkerPct = [math]::Max(0, [math]::Min(100, [math]::Round(($r.PhaseCorr_Avg - (-1.0)) / 2.0 * 100, 1)))
    $phVal       = "{0:N3}" -f $r.PhaseCorr_Avg
    $phMinVal    = if ($null -ne $r.PhaseCorr_Min) { " (min {0:N3})" -f $r.PhaseCorr_Min } else { "" }
    $phaseMeter  = @"
<div class='meter-row'>
  <span class='m-label'>Phase</span>
  <div class='phase-track'>
    <div class='ph-marker' style='left:${phMarkerPct}%;'></div>
  </div>
  <span class='m-val'>$phVal$phMinVal</span>
</div>
"@
  }

  # Pills
  $pills = [System.Collections.Generic.List[string]]::new()
  if ($null -ne $r.TruePeak_dBTP)   { $pills.Add("<div class='pill'><span class='pl'>TP</span><span class='pv'>{0:N2}</span></div>" -f $r.TruePeak_dBTP) }
  if ($null -ne $r.SamplePeak_dBFS) { $pills.Add("<div class='pill'><span class='pl'>Peak</span><span class='pv'>{0:N2}</span></div>" -f $r.SamplePeak_dBFS) }
  if ($null -ne $r.LRA)             { $pills.Add("<div class='pill'><span class='pl'>LRA</span><span class='pv'>{0:N1}</span></div>" -f $r.LRA) }
  if ($null -ne $r.DR)              { $pills.Add("<div class='pill'><span class='pl'>DR</span><span class='pv'>{0:N1}</span></div>" -f $r.DR) }
  if ($null -ne $r.Imbalance_dB)    { $pills.Add("<div class='pill'><span class='pl'>L-R</span><span class='pv'>{0:N2} dB</span></div>" -f $r.Imbalance_dB) }
  if ($r.SampleRate_Hz)             { $pills.Add("<div class='pill'><span class='pl'>SR</span><span class='pv'>$($r.SampleRate_Hz)</span></div>") }
  if ($r.BitDepth)                  { $pills.Add("<div class='pill'><span class='pl'>Bit</span><span class='pv'>$($r.BitDepth)</span></div>") }
  $pillsHtml = if ($pills.Count -gt 0) { "<div class='pills'>$($pills -join '')</div>" } else { "" }

  # Issues
  $issuesHtml = ""
  if ($r.Issues -ne "NONE") {
    $criticals = @('PHASE CANCEL','ANALYSIS ERROR','IMBALANCE')
    $tags = ($r.Issues -split '\|') | ForEach-Object {
      $cls = if ($criticals -contains $_) { "issue crit" } else { "issue warn" }
      "<span class='$cls'>$_</span>"
    }
    $issuesHtml = "<div class='issue-row'>$($tags -join '')</div>"
  }

  # Track meta
  $metaParts = @()
  if ($r.Duration)    { $metaParts += $r.Duration }
  if ($r.Codec)       { $metaParts += $r.Codec.ToUpper() }
  if ($r.Channels -eq 2) { $metaParts += "Stereo" } elseif ($r.Channels -eq 1) { $metaParts += "Mono" }
  $metaStr = $metaParts -join " &middot; "

  @"
<div class='card $statusCls'>
  <div class='card-header'>
    <span class='badge $statusCls'>$statusCls</span>
    <a class='fname' href='$fileUri' title='$($r.Path)'>$($r.File)</a>
    <span class='fmeta'>$metaStr</span>
  </div>
  $lufsMeter
  $phaseMeter
  $pillsHtml
  $issuesHtml
</div>
"@
}

$css = @"
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f2f2f2;color:#1a1a1a;padding:28px 24px;min-height:100vh}
.wrap{max-width:960px;margin:0 auto}

/* ---- Header ---- */
.hdr{display:flex;align-items:flex-start;justify-content:space-between;gap:20px;margin-bottom:24px;flex-wrap:wrap}
.brand{display:flex;align-items:center;gap:14px}
.brand img{height:44px;width:auto}
.brand h1{font-size:20px;font-weight:700;color:#111;letter-spacing:-.3px}
.brand .sub{font-size:12px;color:#999;margin-top:3px}

/* ---- Stat chips ---- */
.stats{display:flex;gap:10px;flex-wrap:wrap;align-items:flex-start;margin-bottom:24px}
.chip{background:#fff;border:1px solid #e4e4e4;border-radius:10px;padding:10px 14px;min-width:80px}
.chip .cl{font-size:10px;font-weight:600;letter-spacing:.07em;color:#b0b0b0;text-transform:uppercase;margin-bottom:4px}
.chip .cv{font-size:18px;font-weight:700;color:#222;font-variant-numeric:tabular-nums}
.chip .cs{font-size:11px;color:#b0b0b0;margin-top:2px}
.chip.warn .cv{color:#d97706}
.chip.bad  .cv{color:#dc2626}
.chip.good .cv{color:#16a34a}
.chip.c-ready  .cv{color:#16a34a}
.chip.c-adjust .cv{color:#d97706}
.chip.c-error  .cv{color:#dc2626}

/* ---- CSV notice ---- */
.csv-bar{background:#eff6ff;border:1px solid #dbeafe;border-radius:8px;padding:8px 14px;margin-bottom:18px;font-size:11px;color:#6b7280}
.csv-bar a{color:#3b82f6}

/* ---- Track cards ---- */
.tracks{display:flex;flex-direction:column;gap:8px}
.card{background:#fff;border:1px solid #e8e8e8;border-left:3px solid #d0d0d0;border-radius:10px;padding:14px 16px}
.card.READY  {border-left-color:#16a34a}
.card.ADJUST {border-left-color:#d97706}
.card.ERROR  {border-left-color:#dc2626}

.card-header{display:flex;align-items:center;gap:10px;margin-bottom:12px}
.badge{font-size:9px;font-weight:700;letter-spacing:.08em;padding:3px 8px;border-radius:20px;flex-shrink:0;text-transform:uppercase}
.badge.READY  {background:#dcfce7;color:#16a34a}
.badge.ADJUST {background:#fef3c7;color:#d97706}
.badge.ERROR  {background:#fee2e2;color:#dc2626}
.fname{font-size:13px;font-weight:600;color:#222;flex:1;text-decoration:none;word-break:break-all}
.fname:hover{color:#000;text-decoration:underline}
.fmeta{font-size:11px;color:#b0b0b0;white-space:nowrap;flex-shrink:0}

/* ---- Meters ---- */
.meter-row{display:flex;align-items:center;gap:10px;margin-bottom:8px}
.m-label{font-size:10px;font-weight:600;color:#b0b0b0;letter-spacing:.05em;text-transform:uppercase;width:38px;flex-shrink:0}
.m-track{flex:1;height:8px;background:#ececec;border-radius:4px;position:relative;overflow:visible}
.m-tol{position:absolute;top:0;height:100%;background:rgba(0,0,0,.07);border-radius:2px}
.m-fill{position:absolute;top:0;left:0;height:100%;border-radius:4px}
.m-fill.ok  {background:linear-gradient(90deg,#86efac,#16a34a)}
.m-fill.warn{background:linear-gradient(90deg,#fcd34d,#d97706)}
.m-fill.err {background:linear-gradient(90deg,#fca5a5,#dc2626)}
.m-target{position:absolute;top:-3px;width:2px;height:14px;background:#999;border-radius:1px}
.m-val{font-size:13px;font-weight:600;color:#333;font-variant-numeric:tabular-nums;width:100px;text-align:right;flex-shrink:0}

/* Phase meter */
.phase-track{flex:1;height:8px;border-radius:4px;position:relative;background:linear-gradient(90deg,#fca5a5 0%,#fcd34d 33%,#bbf7d0 50%,#86efac 100%)}
.ph-marker{position:absolute;top:-3px;width:3px;height:14px;background:#333;border-radius:2px;transform:translateX(-50%)}

/* ---- Pills ---- */
.pills{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:6px}
.pill{background:#f6f6f6;border:1px solid #e8e8e8;border-radius:6px;padding:4px 9px;display:flex;gap:5px;align-items:baseline}
.pl{font-size:9px;color:#b0b0b0;font-weight:600;text-transform:uppercase;letter-spacing:.04em}
.pv{font-size:12px;font-weight:600;color:#444;font-variant-numeric:tabular-nums}

/* ---- Issues ---- */
.issue-row{display:flex;gap:5px;flex-wrap:wrap;margin-top:8px}
.issue{font-size:10px;font-weight:700;letter-spacing:.05em;padding:2px 8px;border-radius:20px;text-transform:uppercase}
.issue.warn{background:#fffbeb;color:#d97706;border:1px solid #fde68a}
.issue.crit{background:#fef2f2;color:#dc2626;border:1px solid #fecaca}

/* ---- Legend ---- */
.legend{margin-top:24px;padding:14px 16px;background:#fff;border:1px solid #e8e8e8;border-radius:10px;font-size:11px;color:#888}
.legend h3{font-size:10px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:#bbb;margin-bottom:10px}
.legend-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:5px 20px}
.legend-grid b{color:#888}
code{background:#f4f4f4;border:1px solid #e0e0e0;padding:1px 5px;border-radius:3px;font-family:monospace;font-size:10px}

/* ---- Footer ---- */
.footer{margin-top:20px;text-align:center;font-size:11px;color:#ccc;padding:10px}
.footer a{color:#bbb}
.donate{display:inline-block;margin-top:6px;padding:5px 14px;border:1px solid #ddd;border-radius:20px;color:#aaa;text-decoration:none;font-size:11px}
.donate:hover{border-color:#bbb;color:#666}
</style>
"@

$fullHtml = @"
<!DOCTYPE html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1'>
<title>LUFS Lens Report</title>
$css
</head>
<body>
<div class='wrap'>

  <div class='hdr'>
    <div class='brand'>
      $logoHtml
      <div>
        <h1>LUFS Lens</h1>
        <div class='sub'>v$version &middot; $(Get-Date -Format 'yyyy-MM-dd HH:mm') &middot; Target $TargetLUFS LUFS</div>
      </div>
    </div>
  </div>

  <div class='stats'>
    <div class='chip'><div class='cl'>Tracks</div><div class='cv'>$total</div></div>
    <div class='chip $readyCardCls'><div class='cl'>Ready</div><div class='cv'>$ready</div></div>
    <div class='chip c-adjust'><div class='cl'>Adjust</div><div class='cv'>$adjust</div></div>
    <div class='chip c-error'><div class='cl'>Error</div><div class='cv'>$errorCount</div></div>
    <div class='chip'><div class='cl'>Avg LUFS</div><div class='cv'>$lufsCardVal</div><div class='cs'>spread $spreadCardVal</div></div>
    <div class='chip $phaseCardCls'><div class='cl'>Phase Corr</div><div class='cv'>$phaseCardVal</div><div class='cs'>min $minPhaseAlbum</div></div>
    <div class='chip'><div class='cl'>Avg DR</div><div class='cv'>$drCardVal</div></div>
  </div>

  <div class='csv-bar'>CSV &rarr; <a href='$csvUri'>$outCsv</a></div>

  <div class='tracks'>
$($trackCards -join "`n")
  </div>

  <div class='legend'>
    <h3>Legend</h3>
    <div class='legend-grid'>
      <div><b>LUFS meter</b>: bar spans <code>$dispMin</code> to <code>$dispMax</code>. Shaded band = tolerance +/-<code>$LUFSTolerance</code>. Tick = target <code>$TargetLUFS</code>.</div>
      <div><b>Phase</b>: -1 (cancel) to +1 (mono). Red zone = cancel, orange = warn &lt;<code>$PhaseWarnThreshold</code>.</div>
      <div><b>TP</b>: True Peak (dBTP). Reference only.</div>
      <div><b>LRA</b>: Loudness Range. Low = compressed; high = dynamic.</div>
      <div><b>DR</b>: Peak-to-RMS ratio. &lt;8 = heavily limited.</div>
      <div><b>L-R</b>: Channel RMS imbalance (dB). &gt;<code>$ImbalanceThreshold</code> dB = ADJUST.</div>
      <div><b>PHASE CANCEL</b>: avg corr &lt; <code>$PhaseCancelThreshold</code> &rarr; ADJUST.</div>
      <div><b>PHASE WARN</b>: avg corr &lt; <code>$PhaseWarnThreshold</code> &rarr; Issues only.</div>
    </div>
  </div>

  <div class='footer'>
    $randomQuote<br>
    <a href='mailto:lufslens@gmail.com'>lufslens@gmail.com</a>
    &nbsp;&middot;&nbsp;
    <a class='donate' href='$kofiUrl' target='_blank' rel='noopener'>Buy the limiter a coffee</a>
  </div>

</div>
</body>
</html>
"@
$fullHtml | Out-File -Encoding UTF8 $outHtml

Write-Host "HTML report saved to: $outHtml"

# -----------------------------
# Auto-open HTML report
# -----------------------------
try {
  Start-Process -FilePath $outHtml
} catch {
  Write-Host "Could not auto-open report." -ForegroundColor Yellow
}
