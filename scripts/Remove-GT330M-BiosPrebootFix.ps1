[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$BackupPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$baseDir = Split-Path -Parent $PSScriptRoot
$bootSectorTarget = "C:\gt330mfix.mbr"
$grldrTarget = "C:\grldr"
$menuLstTarget = "C:\menu.lst"
$bootManagerId = "{bootmgr}"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated PowerShell session."
    }
}

function Invoke-BcdEdit {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $escapedArgs = foreach ($argument in $Arguments) {
        if ($argument -match '\s') {
            '"' + $argument.Replace('"', '\"') + '"'
        }
        else {
            $argument
        }
    }

    $output = & cmd.exe /c ("bcdedit " + ($escapedArgs -join " ")) 2>&1
    $text = ($output | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "bcdedit $($Arguments -join ' ') failed: $text"
    }
    return $text
}

function Resolve-BackupPath {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        if (-not (Test-Path -LiteralPath $RequestedPath)) {
            throw "Backup path not found: $RequestedPath"
        }

        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    $latest = Get-ChildItem -LiteralPath $baseDir -Directory -Filter "backup-*-biospreboot" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latest) {
        throw "No backup-*-biospreboot directory was found under $baseDir"
    }

    return $latest.FullName
}

function Restore-Or-RemoveFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,
        [string]$BackupFile
    )

    if ($BackupFile -and (Test-Path -LiteralPath $BackupFile)) {
        Copy-Item -LiteralPath $BackupFile -Destination $TargetPath -Force
    }
    elseif (Test-Path -LiteralPath $TargetPath) {
        Remove-Item -LiteralPath $TargetPath -Force
    }
}

Assert-Administrator
$resolvedBackup = Resolve-BackupPath -RequestedPath $BackupPath
$stateFile = Join-Path $resolvedBackup "state-before.json"

if (-not (Test-Path -LiteralPath $stateFile)) {
    throw "Missing backup state file: $stateFile"
}

$state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
$afterStateFile = Join-Path $resolvedBackup "state-after.json"
$entryGuid = $null

if (Test-Path -LiteralPath $afterStateFile) {
    $afterState = Get-Content -LiteralPath $afterStateFile -Raw | ConvertFrom-Json
    if ($afterState.EntryGuid) {
        $entryGuid = [string]$afterState.EntryGuid
    }
}

if (-not $entryGuid -and $state.ExistingEntryGuid) {
    $entryGuid = [string]$state.ExistingEntryGuid
}

if ($entryGuid) {
    if ($PSCmdlet.ShouldProcess($entryGuid, "delete GT330M BIOS preboot entry")) {
        Invoke-BcdEdit -Arguments @("/delete", $entryGuid, "/f") | Out-Null
    }
}

if ($state.PreviousDefault) {
    if ($PSCmdlet.ShouldProcess($bootManagerId, "restore previous default boot entry")) {
        Invoke-BcdEdit -Arguments @("/default", ([string]$state.PreviousDefault)) | Out-Null
    }
}

if ($null -ne $state.PreviousTimeout) {
    if ($PSCmdlet.ShouldProcess($bootManagerId, "restore previous boot timeout")) {
        Invoke-BcdEdit -Arguments @("/timeout", ([string]$state.PreviousTimeout)) | Out-Null
    }
}

$backups = $state.BackedUpFiles
if ($PSCmdlet.ShouldProcess("C:\\", "restore or remove grub4dos root files")) {
    Restore-Or-RemoveFile -TargetPath $bootSectorTarget -BackupFile $backups.BootSector
    Restore-Or-RemoveFile -TargetPath $grldrTarget -BackupFile $backups.Grldr
    Restore-Or-RemoveFile -TargetPath $menuLstTarget -BackupFile $backups.MenuLst
}

Write-Host "Removed GT330M BIOS preboot fix."
Write-Host "Restored boot defaults from: $resolvedBackup"
