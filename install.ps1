# Notilus installer (Windows x64).
#
# Usage:
#   irm https://raw.githubusercontent.com/JayashBhandary/Notilus/main/install.ps1 | iex
#
# Downloads the latest GitHub release zip and installs to:
#   %LOCALAPPDATA%\Programs\Notilus
# Also creates a Start Menu shortcut.

$ErrorActionPreference = 'Stop'

$Repo    = 'JayashBhandary/Notilus'
$AppName = 'Notilus'

# GitHub API needs TLS 1.2 on older Windows / PowerShell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "==> Fetching latest release info from $Repo"

$headers = @{}
if ($env:GITHUB_TOKEN) {
    $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
}
$headers['User-Agent'] = 'Notilus-installer'

$release = Invoke-RestMethod `
    -Uri "https://api.github.com/repos/$Repo/releases/latest" `
    -Headers $headers `
    -UseBasicParsing

$asset = $release.assets | Where-Object { $_.name -like '*windows-x64.zip' } | Select-Object -First 1

if (-not $asset) {
    Write-Error "No windows-x64.zip asset found in the latest release. See https://github.com/$Repo/releases"
    exit 1
}

$tmpFile = [System.IO.Path]::GetTempFileName()
$zipPath = "$tmpFile.zip"
Move-Item -Force $tmpFile $zipPath

try {
    Write-Host "==> Downloading $($asset.browser_download_url)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing

    $installDir = Join-Path $env:LOCALAPPDATA "Programs\$AppName"

    if (Test-Path $installDir) {
        Write-Host "==> Removing previous installation at $installDir"
        Remove-Item -Recurse -Force $installDir
    }

    Write-Host "==> Extracting to $installDir"
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $installDir -Force

    # Locate the executable (Flutter builds <project-name>.exe, lowercased)
    $exe = Get-ChildItem -Path $installDir -Filter '*.exe' -File |
           Where-Object { $_.Name -match '^(?i)notilus\.exe$' } |
           Select-Object -First 1

    if (-not $exe) {
        # Fallback: first .exe in the bundle
        $exe = Get-ChildItem -Path $installDir -Filter '*.exe' -File | Select-Object -First 1
    }

    if (-not $exe) {
        Write-Error "Could not find a .exe inside the extracted bundle at $installDir."
        exit 1
    }

    # Start Menu shortcut
    $startMenuDir = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
    if (-not (Test-Path $startMenuDir)) {
        New-Item -ItemType Directory -Force -Path $startMenuDir | Out-Null
    }
    $shortcutPath = Join-Path $startMenuDir "$AppName.lnk"

    $shell    = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath       = $exe.FullName
    $shortcut.WorkingDirectory = $exe.DirectoryName
    $shortcut.Save()

    Write-Host ''
    Write-Host "Installed:  $installDir"
    Write-Host "Executable: $($exe.FullName)"
    Write-Host "Shortcut:   $shortcutPath"
    Write-Host 'Done.'
}
finally {
    if (Test-Path $zipPath) {
        Remove-Item -Force $zipPath
    }
}
