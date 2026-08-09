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
already loaded in memory in the current process. If the *current* session turns out to
be the one holding the lock (common, since PSReadLine is normally auto-loaded), this
script schedules itself to retry once this process exits, then exits immediately - no
manual "close every window" dance needed for that case.

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

# Captured here (script scope, before any dot-sourcing) so it also works when this script
# is invoked as a scriptblock built from downloaded text, e.g.
# `& ([scriptblock]::Create((Invoke-RestMethod <raw-url>)))` - in that case $PSCommandPath
# is empty, but MyCommand.Definition still holds the full source text.
$ScriptSource = $MyInvocation.MyCommand.Definition
$MaxAutoRetries = 3

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

function Invoke-RetryAfterExit {
    # Re-runs this same script (same args) in a detached process that waits for the
    # current process to exit first, then exits the current process - so whatever handle
    # this session holds on the module's files gets released before the retry runs.
    $stamp = [guid]::NewGuid()
    $tempPath = [System.IO.Path]::GetTempPath()
    $targetScriptPath = Join-Path $tempPath "PSLoomPSReadLine-retry-$stamp.ps1"
    $trampolinePath = Join-Path $tempPath "PSLoomPSReadLine-trampoline-$stamp.ps1"
    $logPath = Join-Path $tempPath "PSLoomPSReadLine-retry-$stamp.log"

    Set-Content -LiteralPath $targetScriptPath -Value $ScriptSource -Encoding utf8

    # Array-splatting `@Rest` binds positionally, not by name, so `-Uninstall` wouldn't be
    # recognized as a switch that way - accept the known parameters explicitly and forward
    # them as a hashtable splat instead, which binds by name.
    $trampolineSource = @'
param(
    [Parameter(Mandatory)] [string] $TargetScript,
    [Parameter(Mandatory)] [int] $WaitPid,
    [Parameter(Mandatory)] [string] $LogPath,
    [string] $Repository,
    [string] $ReleaseTag,
    [switch] $Uninstall
)
while (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 200 }
$forward = @{}
foreach ($name in 'Repository', 'ReleaseTag', 'Uninstall') {
    if ($PSBoundParameters.ContainsKey($name)) { $forward[$name] = $PSBoundParameters[$name] }
}
$env:PSLOOM_INSTALL_RETRY_COUNT = [string]([int]($env:PSLOOM_INSTALL_RETRY_COUNT) + 1)
try {
    & $TargetScript @forward *>&1 | Out-File -LiteralPath $LogPath -Encoding utf8
} finally {
    Remove-Item -LiteralPath $TargetScript -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}
'@
    Set-Content -LiteralPath $trampolinePath -Value $trampolineSource -Encoding utf8

    $processArgs = [Collections.Generic.List[string]]::new()
    $processArgs.AddRange([string[]]@(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $trampolinePath,
        '-TargetScript', $targetScriptPath,
        '-WaitPid', $PID,
        '-LogPath', $logPath,
        '-Repository', $Repository,
        '-ReleaseTag', $ReleaseTag
    ))
    if ($Uninstall) { $processArgs.Add('-Uninstall') }

    $exePath = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exePath -ArgumentList $processArgs -WindowStyle Hidden

    Write-Host "This session appears to be holding the lock on the module's files itself. Scheduled the operation to retry automatically once this session exits (attempt $([int]($env:PSLOOM_INSTALL_RETRY_COUNT) + 1) of $MaxAutoRetries)." -ForegroundColor Yellow
    Write-Host "Its output will be written to: $logPath" -ForegroundColor Yellow
    Write-Host "Closing this session now..." -ForegroundColor Yellow
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
        $retryCount = [int]($env:PSLOOM_INSTALL_RETRY_COUNT)
        if ($retryCount -lt $MaxAutoRetries) {
            Invoke-RetryAfterExit
            # PowerShell's own `exit` only unwinds to the nearest script-file `&` boundary,
            # not necessarily the whole process (this script may itself be running as a
            # temp file invoked that way by a previous retry hop) - use the .NET API to
            # actually terminate the process now, releasing whatever lock it's holding.
            [Environment]::Exit(0)
        }

        $runningSessions = Get-Process -Name pwsh, powershell -ErrorAction SilentlyContinue |
            Where-Object Id -ne $PID |
            ForEach-Object { "  PID $($_.Id): $($_.Path)" }
        $sessionsHint = if ($runningSessions) {
            "Other PowerShell processes currently running (likely holding the lock):`n$($runningSessions -join "`n")"
        } else {
            "No other pwsh/powershell processes were found running under this user - the lock may belong to a session running elevated or as another user."
        }

        throw "Failed to $Verb '$Path' after $MaxAutoRetries automatic retries - it looks like a file inside is still in use " +
            "(locked by a running pwsh/powershell process). Close every other PowerShell session that has PSReadLine loaded, " +
            "then try again. $sessionsHint`nOriginal error: $($_.Exception.Message)"
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

        # PowerShellGet-style installs keep modules under a version-numbered folder (e.g.
        # ...\PSReadLine\2.4.5\). The fork's shipped ModuleVersion (3.0.0) won't match that
        # folder name, which confuses module resolution - align the manifest to whatever
        # version folder it's actually sitting in.
        $targetVersion = Split-Path -Leaf $TargetDir
        if ($targetVersion -match '^\d+(\.\d+){1,3}$') {
            $manifestPath = Join-Path $TargetDir 'PSReadLine.psd1'
            $manifestContent = Get-Content -LiteralPath $manifestPath -Raw
            $patched = $manifestContent -replace "ModuleVersion\s*=\s*'[^']*'", "ModuleVersion = '$targetVersion'"
            Set-Content -LiteralPath $manifestPath -Value $patched -NoNewline
        }
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
