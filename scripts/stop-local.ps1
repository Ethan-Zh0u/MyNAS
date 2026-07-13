$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pidFile = Join-Path $root '.dev-state\mynas.pid'
if (-not (Test-Path $pidFile)) { Write-Host 'Local MyNAS is not running.'; exit 0 }
$processId = [int](Get-Content -Raw $pidFile)
$process = Get-Process -Id $processId -ErrorAction SilentlyContinue
if ($process) { Stop-Process -Id $processId -Force; $process.WaitForExit() }
Remove-Item -LiteralPath $pidFile -Force
Write-Host 'Local MyNAS stopped.'
