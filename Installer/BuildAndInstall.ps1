<#
.SYNOPSIS
    Builds File Converter from this repository and (re)installs it on the local machine.

.DESCRIPTION
    1. Builds FileConverter.sln (application, shell extension and WiX installer).
    2. Closes running File Converter / ffmpeg processes.
    3. Uninstalls any installed "File Converter" (same version numbers cannot be upgraded in place).
    4. Installs the freshly built MSI.

    Prerequisites: Visual Studio 2022 (or Build Tools) with the .NET desktop workload and the
    .NET Framework 4.8.1 Developer Pack (winget install Microsoft.DotNet.Framework.DeveloperPack_4).
    The WiX toolset is restored from NuGet automatically.

.EXAMPLE
    .\Installer\BuildAndInstall.ps1                  # build Release + reinstall
    .\Installer\BuildAndInstall.ps1 -BuildOnly       # only build the MSI
    .\Installer\BuildAndInstall.ps1 -RestartExplorer # also restart Explorer so the context menu extension reloads
#>
param(
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [switch]$BuildOnly,
    [switch]$SkipBuild,
    [switch]$RestartExplorer
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$msiPath = Join-Path $repoRoot "Installer\bin\x64\$Configuration\FileConverter-setup.msi"
$logDir = Join-Path $env:TEMP 'FileConverter-dev'
New-Item -ItemType Directory -Force $logDir | Out-Null

function Test-Admin {
    $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- Build (non elevated)
if (-not $SkipBuild) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
    if (-not $msbuild) { throw 'MSBuild not found. Install Visual Studio 2022 or Build Tools.' }

    Write-Host "Building File Converter ($Configuration|x64)..." -ForegroundColor Cyan
    $buildLog = Join-Path $logDir 'build.log'
    & $msbuild (Join-Path $repoRoot 'FileConverter.sln') -restore -m -nologo -v:minimal `
        "-p:Configuration=$Configuration" '-p:Platform=x64' "-flp:logfile=$buildLog;verbosity=normal"
    if ($LASTEXITCODE -ne 0) { throw "Build failed (see $buildLog)." }
    Write-Host "MSI built: $msiPath" -ForegroundColor Green
}

if ($BuildOnly) { return }
if (-not (Test-Path $msiPath)) { throw "MSI not found: $msiPath" }

# ---------------------------------------------------------------- Install (elevated)
if (-not (Test-Admin)) {
    Write-Host 'Requesting administrator rights to reinstall...' -ForegroundColor Cyan
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-SkipBuild', '-Configuration', $Configuration)
    if ($RestartExplorer) { $argsList += '-RestartExplorer' }
    # Windows PowerShell is always present (a Microsoft Store pwsh.exe cannot always be elevated from its package path).
    $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $argsList -Wait -PassThru
    exit $proc.ExitCode
}

Get-Process FileConverter, ffmpeg -ErrorAction SilentlyContinue | Stop-Process -Force

$uninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
$installed = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq 'File Converter' -and $_.PSChildName -match '^\{.+\}$' }

foreach ($product in $installed) {
    Write-Host "Uninstalling File Converter $($product.DisplayVersion) $($product.PSChildName)..." -ForegroundColor Cyan
    $p = Start-Process msiexec.exe -ArgumentList "/x $($product.PSChildName) /qn /norestart /l*v `"$logDir\uninstall.log`"" -Wait -PassThru
    if ($p.ExitCode -notin 0, 1605, 3010) { throw "Uninstall failed ($($p.ExitCode)), see $logDir\uninstall.log" }
}

Write-Host "Installing $msiPath..." -ForegroundColor Cyan
$p = Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart /l*v `"$logDir\install.log`"" -Wait -PassThru
if ($p.ExitCode -notin 0, 3010) { throw "Install failed ($($p.ExitCode)), see $logDir\install.log" }

if ($RestartExplorer) {
    Stop-Process -Name explorer -Force
    Start-Process explorer.exe
}

Write-Host 'File Converter installed.' -ForegroundColor Green
if ($p.ExitCode -eq 3010) { Write-Host 'A reboot is required to finish the installation.' -ForegroundColor Yellow }
