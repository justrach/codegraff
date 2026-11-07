# Install graff on Windows from the latest GitHub release.
#
#   irm https://github.com/justrach/codegraff/releases/latest/download/install.ps1 | iex
#
# Environment overrides:
#   GRAFF_INSTALL_DIR  where graff.exe goes (default %LOCALAPPDATA%\Programs\graff\bin)
#   GRAFF_VERSION      a release tag such as v0.0.302.20 (default: the latest release)
#   GRAFF_NO_PATH=1    do not add the install directory to the user PATH
#
# Unlike install.sh this runs no `graff mcp install`: that sets up a
# launchd/systemd service and is macOS/Linux only.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Invoke-WebRequest is far slower with the progress bar

function Fail([string]$Message) {
    Write-Host "  error: $Message" -ForegroundColor Red
    throw $Message
}

$repo = 'https://github.com/justrach/codegraff'
$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$target = switch ($arch) {
    'AMD64' { 'x86_64-windows' }
    'ARM64' { 'aarch64-windows' }
    default { Fail "unsupported processor architecture '$arch' (graff ships x86_64 and ARM64 builds)" }
}
$dir = if ($env:GRAFF_INSTALL_DIR) { $env:GRAFF_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\graff\bin' }
$base = if ($env:GRAFF_VERSION) { "$repo/releases/download/$($env:GRAFF_VERSION)" } else { "$repo/releases/latest/download" }
$asset = "graff-$target.tar.gz"

Write-Host ''
Write-Host '  graff installer' -ForegroundColor White
Write-Host "  platform  $target"
Write-Host "  install   $dir"
Write-Host ''

if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
    Fail 'tar.exe was not found (it ships with Windows 10 1803 and later)'
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("graff-install-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Write-Host "  download  $asset"
    Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile (Join-Path $tmp $asset)
    Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile (Join-Path $tmp 'SHA256SUMS')

    # Verify against the release's SHA256SUMS before anything runs.
    $line = Get-Content (Join-Path $tmp 'SHA256SUMS') | Where-Object { $_ -match "\s\*?$([regex]::Escape($asset))$" } | Select-Object -First 1
    if (-not $line) { Fail "SHA256SUMS has no entry for $asset" }
    $expected = ($line -split '\s+')[0].ToLowerInvariant()
    # .NET directly, not Get-FileHash: that cmdlet's module may not load
    # (Windows PowerShell started from PowerShell 7 inherits its module path).
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead((Join-Path $tmp $asset))
    try { $actual = -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) }
    finally { $stream.Dispose(); $sha.Dispose() }
    if ($expected -ne $actual) { Fail "checksum mismatch for $asset (expected $expected, got $actual)" }
    Write-Host '  verify    sha256 ok'

    & tar.exe -xzf (Join-Path $tmp $asset) -C $tmp
    if ($LASTEXITCODE -ne 0) { Fail "could not unpack $asset" }
    $exe = Join-Path $tmp "graff-$target\graff.exe"
    if (-not (Test-Path $exe)) {
        $found = Get-ChildItem -Path $tmp -Recurse -Filter graff.exe | Select-Object -First 1
        if (-not $found) { Fail "$asset contains no graff.exe" }
        $exe = $found.FullName
    }

    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dest = Join-Path $dir 'graff.exe'
    # A running graff.exe cannot be overwritten, but it can be renamed aside.
    if (Test-Path $dest) {
        $old = "$dest.old"
        Remove-Item -Force $old -ErrorAction SilentlyContinue
        try { Remove-Item -Force $dest } catch { Rename-Item -Path $dest -NewName 'graff.exe.old' }
    }
    Copy-Item -Path $exe -Destination $dest
    Write-Host "  installed $dest" -ForegroundColor Green
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($env:GRAFF_NO_PATH -ne '1') {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($userPath -split ';' | Where-Object { $_ })
    if ($entries -notcontains $dir) {
        [Environment]::SetEnvironmentVariable('Path', (($entries + $dir) -join ';'), 'User')
        Write-Host "  PATH      added $dir (new terminals pick it up)"
    } else {
        Write-Host '  PATH      already set'
    }
    if (($env:Path -split ';') -notcontains $dir) { $env:Path = "$env:Path;$dir" }
}

# Capture everything before taking the first line: `| Select-Object -First 1`
# closes the pipe while graff still prints its what's-new list, and the write
# error made a working graff.exe exit non-zero ("did not start").
$output = & (Join-Path $dir 'graff.exe') --version 2>&1
$code = $LASTEXITCODE
$version = $output | Select-Object -First 1
if ($code -ne 0) { Fail "graff.exe did not start: $version" }
Write-Host "  version   $version"

Write-Host ''
Write-Host '  done! open a new terminal and run graff, or graff --help' -ForegroundColor White
Write-Host ''
