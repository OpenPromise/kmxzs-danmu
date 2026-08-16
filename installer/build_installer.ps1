# 打包 Windows 安装包
# 用法（在仓库根目录）：
#   powershell -ExecutionPolicy Bypass -File installer\build_installer.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$secrets = Join-Path $PSScriptRoot 'secrets.ps1'
if (-not (Test-Path $secrets)) {
  throw "缺少 installer/secrets.ps1，请先复制 installer/secrets.ps1.example 并填入服务器地址与密钥"
}
. $secrets
if (-not $apiBase -or -not $apiSecret -or -not $version) {
  throw "installer/secrets.ps1 需要设置 `$apiBase、`$apiSecret、`$version"
}

# 阶段3：证书指纹与更新公钥（可从服务器导出，见 server/scripts 与部署文档）。
# 生产 Release 必须注入；未设置时警告并继续（开发包）。
if (-not $certSha256) {
  Write-Warning "secrets.ps1 未设置 `$certSha256（服务器自签证书 SHA-256 指纹），新客户端将无法完成证书绑定"
}
if (-not $updatePubkey) {
  Write-Warning "secrets.ps1 未设置 `$updatePubkey（安装包 Ed25519 公钥 base64），客户端将拒绝安装更新包"
}

Write-Host "== flutter build windows --release =="
foreach ($n in @('快马小助手', 'zbxzs', 'kmxzs')) {
  Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

flutter build windows --release --obfuscate --split-debug-info=build/debug-info `
  --dart-define=KMXZS_API_BASE=$apiBase `
  --dart-define=KMXZS_API_SECRET=$apiSecret `
  --dart-define=KMXZS_CERT_SHA256=$certSha256 `
  --dart-define=KMXZS_UPDATE_PUBKEY=$updatePubkey
if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }

$exe = Join-Path $root "build\windows\x64\runner\Release\快马小助手.exe"
if (-not (Test-Path $exe)) { throw "missing $exe" }

$iscc = @(
  "${env:LOCALAPPDATA}\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $iscc) {
  throw "未找到 Inno Setup 6（ISCC.exe）。请先安装后再打包。"
}

New-Item -ItemType Directory -Force -Path (Join-Path $root "dist") | Out-Null
Write-Host "== Inno Setup compile =="
& $iscc "/DMyAppVersion=$version" (Join-Path $root "installer\zbxzs.iss")
if ($LASTEXITCODE -ne 0) { throw "ISCC failed" }

Get-ChildItem (Join-Path $root "dist\zbxzs-setup-*.exe") | Sort-Object LastWriteTime -Descending | Select-Object -First 3 FullName, Length
