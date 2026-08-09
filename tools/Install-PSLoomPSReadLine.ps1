#requires -Version 7.0
<#
.SYNOPSIS
Installs, updates, or reverts this fork's PSReadLine build in place of whatever
PSReadLine module pwsh would otherwise auto-load.

.DESCRIPTION
pwsh loads its own bundled PSReadLine automatically in interactive sessions, and that
module normally can't be removed with Uninstall-Module. This script instead finds the
PSReadLine module that would actually be loaded, renames its directory to a `.bkp`
backup, and extracts this fork's release into the same path - so pwsh keeps
auto-loading "PSReadLine" by name, now served by the fork's build.

Run with -Uninstall to restore the original module from the backup.

Changes only take effect in a *new* pwsh session - files on disk don't affect a module
already loaded in memory in the current process.

.PARAMETER Repository
The GitHub repository ("owner/name") the release is published under.

.PARAMETER ReleaseTag
The release tag to download. Defaults to the rolling "fork-latest" release.

.PARAMETER Uninstall
Restore the original PSReadLine from the ".bkp" backup instead of installing.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Repository = 'baliestri/PSReadLine',
    [string] $ReleaseTag = 'fork-latest',
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

function Get-TargetModuleDir {
    $module = Get-Module -Name PSReadLine
    if (-not $module) {
        $module = Get-Module -Name PSReadLine -ListAvailable | Select-Object -First 1
    }
    if (-not $module) {
        throw "No PSReadLine module found (neither loaded nor available via `$env:PSModulePath)."
    }
    return Split-Path $module.Path -Parent
}

function Assert-Elevated {
    param([string] $Path)

    if ($IsWindows -eq $false) { return }

    $needsElevation = $Path -like (Join-Path ${env:ProgramFiles} '*') -or
        $Path -like (Join-Path ${env:ProgramW6432} '*')
    if (-not $needsElevation) { return }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "'$Path' is under Program Files and requires elevation. Re-run this script from an Administrator session."
    }
}

function Invoke-WithLockGuard {
    param(
        [Parameter(Mandatory)] [scriptblock] $Action,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Verb
    )

    try {
        & $Action
    } catch {
        throw "Failed to $Verb '$Path' - it looks like a file inside is still in use (locked by a running pwsh/powershell process). " +
            "Close every other PowerShell session that has PSReadLine loaded, then re-run this script non-interactively, e.g.: " +
            "pwsh -NoProfile -NonInteractive -File `"$PSCommandPath`". Original error: $($_.Exception.Message)"
    }
}

function Invoke-Uninstall {
    param([string] $TargetDir, [string] $BackupDir)

    if (-not (Test-Path -LiteralPath $BackupDir)) {
        throw "No backup found at '$BackupDir' - nothing to revert."
    }

    Assert-Elevated -Path $TargetDir

    if (-not $PSCmdlet.ShouldProcess($TargetDir, "Restore original PSReadLine from backup")) { return }

    if (Test-Path -LiteralPath $TargetDir) {
        Invoke-WithLockGuard -Path $TargetDir -Verb 'remove' -Action {
            Remove-Item -LiteralPath $TargetDir -Recurse -Force -ErrorAction Stop
        }
    }

    Rename-Item -LiteralPath $BackupDir -NewName (Split-Path -Leaf $TargetDir)

    Write-Host "Restored the original PSReadLine at '$TargetDir'. Restart your pwsh session to pick it up." -ForegroundColor Green
}

function Get-ReleaseAssetUrl {
    param([string] $Repository, [string] $ReleaseTag)

    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/tags/$ReleaseTag"
    $asset = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    if (-not $asset) {
        throw "Release '$ReleaseTag' on '$Repository' has no .zip asset."
    }
    return $asset.browser_download_url
}

function Invoke-Install {
    param([string] $TargetDir, [string] $BackupDir)

    # If a backup already exists, this fork was installed here before - update in place and
    # leave the backup (which still holds the *original* PSReadLine) untouched.
    $isUpdate = Test-Path -LiteralPath $BackupDir
    Assert-Elevated -Path $TargetDir

    if (-not $isUpdate) {
        if (-not $PSCmdlet.ShouldProcess($TargetDir, "Back up original PSReadLine and install fork build")) { return }

        Invoke-WithLockGuard -Path $TargetDir -Verb 'back up' -Action {
            Rename-Item -LiteralPath $TargetDir -NewName (Split-Path -Leaf $BackupDir) -ErrorAction Stop
        }
    } else {
        if (-not $PSCmdlet.ShouldProcess($TargetDir, "Update installed fork build")) { return }
        Write-Host "Fork build already installed at '$TargetDir' - updating in place (existing backup left untouched)." -ForegroundColor Cyan
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "PSLoomPSReadLine-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $zipPath = Join-Path $tempDir 'release.zip'
        $assetUrl = Get-ReleaseAssetUrl -Repository $Repository -ReleaseTag $ReleaseTag
        Invoke-WebRequest -Uri $assetUrl -OutFile $zipPath

        $extractDir = Join-Path $tempDir 'extracted'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir

        $moduleSource = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
        if (-not $moduleSource) {
            throw "Release zip did not contain a module folder."
        }

        if (Test-Path -LiteralPath $TargetDir) {
            Remove-Item -LiteralPath $TargetDir -Recurse -Force
        }
        Move-Item -LiteralPath $moduleSource.FullName -Destination $TargetDir
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Installed the fork build at '$TargetDir'. Restart your pwsh session to pick it up." -ForegroundColor Green
}

$targetDir = Get-TargetModuleDir
$backupDir = "$targetDir.bkp"

if ($Uninstall) {
    Invoke-Uninstall -TargetDir $targetDir -BackupDir $backupDir
} else {
    Invoke-Install -TargetDir $targetDir -BackupDir $backupDir
}
