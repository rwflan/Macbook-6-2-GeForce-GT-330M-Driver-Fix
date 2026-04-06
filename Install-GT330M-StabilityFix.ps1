[CmdletBinding()]
param(
    [string]$Branch = "main"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedBootstrap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$SelectedBranch
    )

    $quotedScriptPath = '"' + $CurrentScriptPath + '"'
    $quotedBranch = '"' + $SelectedBranch + '"'
    $argumentList = "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath -Branch $quotedBranch"

    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argumentList | Out-Null
}

if (-not (Test-Administrator)) {
    Write-Host "Requesting elevation..."
    Start-ElevatedBootstrap -CurrentScriptPath $PSCommandPath -SelectedBranch $Branch
    return
}

$repoSlug = "rwflan/Macbook-6-2-GeForce-GT-330M-Driver-Fix"
$tempRoot = Join-Path $env:TEMP ("gt330m-fix-" + [guid]::NewGuid().ToString("N"))
$zipPath = Join-Path $tempRoot "repo.zip"
$extractRoot = Join-Path $tempRoot "extracted"
$repoRoot = Join-Path $extractRoot "Macbook-6-2-GeForce-GT-330M-Driver-Fix-$Branch"
$applyScriptPath = Join-Path $repoRoot "scripts\Apply-GT330M-StabilityFix.ps1"
$zipUrl = "https://codeload.github.com/$repoSlug/zip/refs/heads/$Branch"

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Write-Host "Downloading $repoSlug ($Branch)..."
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath

    Write-Host "Extracting package..."
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force

    if (-not (Test-Path -LiteralPath $applyScriptPath)) {
        throw "Unable to find Apply-GT330M-StabilityFix.ps1 in downloaded package."
    }

    Write-Host "Running the GT 330M stability fix..."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $applyScriptPath
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
