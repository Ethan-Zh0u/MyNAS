param([string]$PagesOrigin = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$key = 'C:\Users\qdzn\.ssh\mynas_deploy'
$remote = 'rbp@rsp'
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$release = "/tmp/mynas-release-$stamp"
$sshOptions = @('-i', $key, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3')

function Invoke-NativeRetry([string]$label, [scriptblock]$operation) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        & $operation
        if ($LASTEXITCODE -eq 0) { return }
        if ($attempt -lt 3) { Write-Warning "$label failed (attempt $attempt/3); retrying."; Start-Sleep -Seconds (2 * $attempt) }
    }
    throw "$label failed after 3 attempts (exit code $LASTEXITCODE)."
}

if ($PagesOrigin -and -not [Uri]::IsWellFormedUriString($PagesOrigin, [UriKind]::Absolute)) { throw 'PagesOrigin must be an absolute HTTPS URL.' }
& (Join-Path $root 'scripts\build.ps1')

Invoke-NativeRetry 'remote preflight' { ssh @sshOptions $remote "set -eu; findmnt -no SOURCE,FSTYPE,TARGET /mnt/nas; df -h /mnt/nas; systemctl is-active --quiet smbd; mkdir -p '$release/web'" }
Invoke-NativeRetry 'backend upload' { scp @sshOptions (Join-Path $root 'backend\mynas-linux-arm64') "$remote`:$release/mynas" }
Invoke-NativeRetry 'deployment files upload' { scp @sshOptions (Join-Path $root 'deploy\mynas.service') (Join-Path $root 'deploy\install-pi.sh') "$remote`:$release/" }
$webArchive = Join-Path $root '.dev-state\frontend-dist.tar'
if (Test-Path $webArchive) { Remove-Item -LiteralPath $webArchive -Force }
tar.exe -cf $webArchive -C (Join-Path $root 'frontend\dist') .
if ($LASTEXITCODE -ne 0) { throw 'frontend archive creation failed' }
try { Invoke-NativeRetry 'frontend upload' { scp @sshOptions $webArchive "$remote`:$release/frontend-dist.tar" } } finally { Remove-Item -LiteralPath $webArchive -Force -ErrorAction SilentlyContinue }
Invoke-NativeRetry 'frontend extraction' { ssh @sshOptions $remote "set -eu; tar -xf '$release/frontend-dist.tar' -C '$release/web'; test -f '$release/web/index.html'" }

$envFile = Join-Path $root '.dev-state\mynas.deploy.env'
$content = "MYNAS_ALLOWED_ORIGIN=$PagesOrigin`nMYNAS_PRIVATE_ORIGIN=https://rsp.tail681937.ts.net`n"
[IO.File]::WriteAllText($envFile, $content, [Text.UTF8Encoding]::new($false))
try { Invoke-NativeRetry 'environment upload' { scp @sshOptions $envFile "$remote`:$release/mynas.env" } } finally { Remove-Item -LiteralPath $envFile -Force -ErrorAction SilentlyContinue }

Invoke-NativeRetry 'remote installation' { ssh @sshOptions $remote "set -eu; chmod +x '$release/mynas' '$release/install-pi.sh'; bash '$release/install-pi.sh' '$release'; sudo tailscale serve --bg --yes 127.0.0.1:8080; tailscale serve status; systemctl --no-pager --full status mynas" }
Write-Host "Deployment completed. Temporary release directory: $release"
