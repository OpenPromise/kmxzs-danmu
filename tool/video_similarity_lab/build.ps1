$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$entry = Join-Path $PSScriptRoot 'video_similarity_lab.py'
$dist = Join-Path $root 'dist'
$work = Join-Path $root 'build\video_similarity_lab'
$icon = Join-Path $root 'windows\runner\resources\app_icon.ico'

New-Item -ItemType Directory -Force -Path $dist, $work | Out-Null

Write-Host '== Build offline video similarity lab =='
python -m PyInstaller --noconfirm --clean --onefile --windowed `
  --name video-similarity-lab `
  --icon $icon `
  --paths $PSScriptRoot `
  --hidden-import cv2 `
  --hidden-import numpy `
  --distpath $dist `
  --workpath $work `
  --specpath $work `
  $entry
if ($LASTEXITCODE -ne 0) { throw 'PyInstaller build failed' }

$output = Join-Path $dist 'video-similarity-lab.exe'
if (-not (Test-Path -LiteralPath $output)) { throw "Missing output: $output" }

Write-Host '== Run packaged application self-test =='
$selfTest = Start-Process -FilePath $output -ArgumentList '--self-test' `
  -WindowStyle Hidden -Wait -PassThru
if ($selfTest.ExitCode -ne 0) {
  throw "Packaged application self-test failed (exit $($selfTest.ExitCode))"
}

Get-Item -LiteralPath $output | Select-Object FullName, Length, LastWriteTime
