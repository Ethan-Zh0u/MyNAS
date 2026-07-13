param([Parameter(Mandatory=$true)][string]$ProjectName)
$ErrorActionPreference='Stop';$root=Split-Path -Parent $PSScriptRoot
Push-Location "$root\frontend"
$env:VITE_API_URL='https://rsp.tail681937.ts.net';pnpm build
pnpm dlx wrangler pages deploy dist --project-name $ProjectName
Pop-Location
