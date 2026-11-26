param([string]$Compiler = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe")

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$tempRoot = [IO.Path]::GetTempPath()
$fixture = Join-Path $tempRoot ("h2-notices-" + [guid]::NewGuid().ToString('N'))
$release = Join-Path $fixture 'build\windows\x64\runner\Release'

function Test-Compile([string]$ExpectedError) {
    # ISCC writes expected preprocessor errors to stderr. Inspect the exit code
    # and diagnostic together, including on Windows PowerShell 5.1.
    $ErrorActionPreference = 'Continue'
    $output = & $Compiler /Q /O- (Join-Path $fixture 'installer\H2Readmd.iss') 2>&1
    $code = $LASTEXITCODE
    $message = $output -join [Environment]::NewLine
    if ($ExpectedError) {
        if ($code -eq 0 -or !$message.Contains($ExpectedError)) {
            throw "Expected compiler rejection: $ExpectedError. Exit $code. $message"
        }
    } elseif ($code -ne 0) {
        throw "Complete fixture failed to compile. Exit $code. $message"
    }
}

New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    foreach ($file in 'installer\H2Readmd.iss', 'installer\Prepare-ReleaseNotices.ps1',
                      'windows\runner\resources\app_icon.ico', 'THIRD_PARTY_NOTICES.md') {
        $dest = Join-Path $fixture $file
        [IO.Directory]::CreateDirectory((Split-Path -Parent $dest)) | Out-Null
        Copy-Item -LiteralPath (Join-Path $project $file) -Destination $dest
    }
    Copy-Item -LiteralPath (Join-Path $project 'licenses') -Destination $fixture -Recurse
    foreach ($file in 'H2Readmd.exe', 'flutter_windows.dll', 'data\app.so', 'data\flutter_assets\NOTICES.Z') {
        $dest = Join-Path $release $file
        [IO.Directory]::CreateDirectory((Split-Path -Parent $dest)) | Out-Null
        [IO.File]::WriteAllText($dest, 'fixture')
    }
    & (Join-Path $fixture 'installer\Prepare-ReleaseNotices.ps1')
    Test-Compile
    foreach ($file in 'THIRD_PARTY_NOTICES.md', 'licenses\FLUTTER_GENERATED_NOTICES.txt',
                      'licenses\fonts\JetBrainsMono-OFL.txt', 'licenses\fonts\LatinModern-GUST-FONT-LICENSE.txt',
                      'licenses\fonts\LPPL-1.3c.txt', 'data\flutter_assets\NOTICES.Z') {
        $dest = Join-Path $release $file
        $original = [IO.File]::ReadAllBytes($dest)
        [IO.File]::Delete($dest)
        Test-Compile "Missing or empty Release file: $file"
        [IO.File]::WriteAllBytes($dest, [byte[]]@())
        Test-Compile "Missing or empty Release file: $file"
        [IO.File]::WriteAllBytes($dest, $original)
    }
    [IO.File]::AppendAllText((Join-Path $release 'licenses\fonts\LPPL-1.3c.txt'), 'changed')
    Test-Compile 'Release notice differs from source: licenses\fonts\LPPL-1.3c.txt'
    & (Join-Path $fixture 'installer\Prepare-ReleaseNotices.ps1')
    Test-Compile
    Write-Output 'PASS: complete and re-prepared bundles compile; missing, empty and changed notices are rejected.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $fixture).ProviderPath
    if ($resolved -eq [IO.Path]::GetFullPath($fixture) -and
        (Split-Path -Parent $resolved) -eq $tempRoot.TrimEnd('\')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
