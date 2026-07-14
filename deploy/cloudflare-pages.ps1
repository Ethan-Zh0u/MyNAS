param([Parameter(Mandatory=$true)][string]$ProjectName)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$nodeBin = 'C:\Users\qdzn\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin'
$pnpmBin = 'C:\Users\qdzn\.cache\codex-runtimes\codex-primary-runtime\dependencies\bin\fallback'
$env:PATH = "$nodeBin;$pnpmBin;$env:PATH"
$env:VITE_API_URL = 'https://rsp.tail681937.ts.net'

Push-Location (Join-Path $root 'frontend')
try {
    pnpm build
    if ($LASTEXITCODE -ne 0) { throw 'Cloudflare frontend build failed.' }
    pnpm dlx wrangler pages deploy dist --project-name $ProjectName
    if ($LASTEXITCODE -ne 0) { throw 'Cloudflare Pages deployment failed.' }
} finally {
    Pop-Location
}
