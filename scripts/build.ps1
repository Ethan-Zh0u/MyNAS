$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$nodeBin = 'C:\Users\qdzn\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin'
$pnpmBin = 'C:\Users\qdzn\.cache\codex-runtimes\codex-primary-runtime\dependencies\bin\fallback'
$go = Join-Path $root '.tools\go\bin\go.exe'

if (-not (Test-Path $go)) { throw 'Local Go SDK is missing from .tools\go.' }
$env:PATH = "$nodeBin;$pnpmBin;$env:PATH"
$env:GOTOOLCHAIN = 'local'
$env:GOCACHE = Join-Path $root '.cache\go-build'
$env:GOMODCACHE = Join-Path $root '.cache\go-mod'
$env:TEMP = Join-Path $root '.cache\tmp'
$env:TMP = $env:TEMP
New-Item -ItemType Directory -Force $env:GOCACHE, $env:GOMODCACHE, $env:TEMP | Out-Null

Push-Location (Join-Path $root 'frontend')
try {
    pnpm install --frozen-lockfile
    pnpm test
    pnpm build
} finally { Pop-Location }

Push-Location (Join-Path $root 'backend')
try {
    & $go test ./...
    if ($LASTEXITCODE -ne 0) { throw 'Go tests failed' }
    & $go vet ./...
    if ($LASTEXITCODE -ne 0) { throw 'Go vet failed' }
    & $go build -buildvcs=false -trimpath -o mynas-windows-amd64.exe .
    if ($LASTEXITCODE -ne 0) { throw 'Windows backend build failed' }
    $env:GOOS = 'linux'; $env:GOARCH = 'arm64'; $env:CGO_ENABLED = '0'
    & $go build -buildvcs=false -trimpath -ldflags='-s -w' -o mynas-linux-arm64 .
    if ($LASTEXITCODE -ne 0) { throw 'Linux ARM64 backend build failed' }
} finally {
    foreach ($name in 'GOOS', 'GOARCH', 'CGO_ENABLED') { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    Pop-Location
}

Write-Host 'MyNAS tests and Windows/Linux ARM64 production builds completed.'
