# Installs Elfton Player for the current user: downloads the latest release,
# unpacks it to %LOCALAPPDATA%\Programs\Elfton Player and adds Start menu and
# desktop shortcuts. No administrator rights needed.
#
#   irm https://raw.githubusercontent.com/lioilsources/ol1nplay/main/tools/install.ps1 | iex
#
# Run from inside an unpacked release folder it installs that copy instead
# of downloading.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$name = 'Elfton Player'
$target = Join-Path $env:LOCALAPPDATA "Programs\$name"
$local = if ($PSScriptRoot) { Join-Path $PSScriptRoot "$name.exe" } else { $null }

Get-Process -Name $name, 'ol1nplay-engine' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

if ($local -and (Test-Path $local)) {
    if ((Resolve-Path $PSScriptRoot).Path -ne $target) {
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $target -Recurse -Force
    }
} else {
    $release = Invoke-RestMethod 'https://api.github.com/repos/lioilsources/ol1nplay/releases?per_page=10'
    $asset = $release | ForEach-Object { $_.assets } |
        Where-Object { $_.name -like 'ElftonPlayer-*-Windows.zip' } | Select-Object -First 1
    if (-not $asset) { throw 'No Windows build found in the releases.' }
    Write-Host "Downloading $($asset.name) ..."
    $zip = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip
    if (Test-Path $target) { Remove-Item $target -Recurse -Force }
    Expand-Archive $zip -DestinationPath (Split-Path $target) -Force
    Remove-Item $zip
}

$exe = Join-Path $target "$name.exe"
$shell = New-Object -ComObject WScript.Shell
foreach ($dir in [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop')) {
    $link = $shell.CreateShortcut((Join-Path $dir "$name.lnk"))
    $link.TargetPath = $exe
    $link.WorkingDirectory = $target
    $link.Save()
}

Write-Host "Installed to $target"
Start-Process $exe
