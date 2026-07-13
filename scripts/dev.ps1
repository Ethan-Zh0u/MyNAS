$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'backend\mynas-windows-amd64.exe'
if (-not (Test-Path $exe)) { & (Join-Path $PSScriptRoot 'build.ps1') }

$env:MYNAS_ENV = 'development'
$env:MYNAS_DEV_IDENTITY = '1'
$env:MYNAS_ROOT = Join-Path $root 'dev-data'
$env:MYNAS_DATA_DIR = Join-Path $root '.dev-state'
$env:MYNAS_LISTEN = '127.0.0.1:8080'
$env:MYNAS_WEB_DIR = Join-Path $root 'frontend\dist'
New-Item -ItemType Directory -Force $env:MYNAS_ROOT, $env:MYNAS_DATA_DIR | Out-Null

$pidFile = Join-Path $env:MYNAS_DATA_DIR 'mynas.pid'
if (Test-Path $pidFile) {
    $oldPid = [int](Get-Content -Raw $pidFile)
    if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) { throw "Local MyNAS is already running, PID=$oldPid" }
}
$process = Start-Process -FilePath $exe -WorkingDirectory (Join-Path $root 'backend') -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText($pidFile, [string]$process.Id)
for ($i = 0; $i -lt 30; $i++) {
    try { $health = Invoke-RestMethod 'http://127.0.0.1:8080/api/v1/health'; break } catch { Start-Sleep -Milliseconds 200 }
}
if (-not $health.ok) { throw 'Local MyNAS health check failed.' }
Write-Host "Local MyNAS started: http://127.0.0.1:8080/ (PID=$($process.Id))"
