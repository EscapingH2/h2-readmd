$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$release = Join-Path $projectRoot 'build\windows\x64\runner\Release'
if (!(Test-Path -LiteralPath (Join-Path $release 'H2Readmd.exe'))) {
    throw 'Build Windows Release first.'
}
Copy-Item -LiteralPath (Join-Path $projectRoot 'THIRD_PARTY_NOTICES.md') -Destination $release -Force
# Create the destination explicitly so repeated runs copy contents consistently.
$destination = Join-Path $release 'licenses'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $projectRoot 'licenses') | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $destination -Recurse -Force
}
Write-Output 'Third-party notices copied into the Release bundle. Re-run after each build.'
