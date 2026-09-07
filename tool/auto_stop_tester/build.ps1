$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$buildDir = Join-Path $root 'build\auto_stop_tester'
$distDir = Join-Path $root 'dist'
$sample = Join-Path $buildDir 'sample.flv'
$source = Join-Path $PSScriptRoot 'AutoStopTester.cs'
$output = Join-Path $distDir 'auto-stop-stream-tester.exe'

New-Item -ItemType Directory -Force -Path $buildDir, $distDir | Out-Null

$ffmpeg = (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue).Source
if (-not $ffmpeg) {
  throw 'ffmpeg.exe is required to generate the embedded test clip'
}

Write-Host '== Generate embedded FLV test clip =='
& $ffmpeg -hide_banner -loglevel error -y `
  -f lavfi -i 'testsrc2=size=320x180:rate=10' `
  -f lavfi -i 'sine=frequency=880:sample_rate=16000' `
  -t 6 -c:v libx264 -preset ultrafast -tune zerolatency `
  -pix_fmt yuv420p -g 20 -b:v 100k -maxrate 120k -bufsize 240k `
  -c:a aac -b:a 24k -ar 16000 -f flv $sample
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $sample)) {
  throw 'Failed to generate the FLV test clip'
}

$csc = @(
  'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
  'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw '.NET Framework C# compiler was not found' }

Write-Host '== Compile Windows test tool =='
& $csc /nologo /target:winexe /optimize+ /platform:anycpu /codepage:65001 `
  /reference:System.dll /reference:System.Core.dll `
  /reference:System.Drawing.dll /reference:System.Windows.Forms.dll `
  "/win32icon:$root\windows\runner\resources\app_icon.ico" `
  "/resource:$sample,AutoStopTest.sample.flv" `
  "/out:$output" $source
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) {
  throw 'Failed to compile the auto-stop stream tester'
}

Write-Host '== Run embedded stream/cutoff self-test =='
$selfTest = Start-Process -FilePath $output -ArgumentList '--self-test' `
  -WindowStyle Hidden -Wait -PassThru
if ($selfTest.ExitCode -ne 0) {
  throw "Auto-stop stream tester self-test failed (exit $($selfTest.ExitCode))"
}

Get-Item -LiteralPath $output | Select-Object FullName, Length, LastWriteTime
