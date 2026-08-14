<#!
.SYNOPSIS
    Create a distributable ops-rework ZIP without secrets or runtime material.

.DESCRIPTION
    The archive is assembled through a temporary staging directory. Credential
    files are assembled from an explicit allow-list of current scripts and
    documentation, so runtime material and historical folders cannot enter.
#>
[CmdletBinding()]
param(
    [string] $OutputPath = '',
    [switch] $ListOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OpsRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$defaultOutputPath = Join-Path $OpsRoot ('ops-rework-distribution-{0}.zip' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = $defaultOutputPath }
$excludedPatterns = @(
    '^restart bot account\.txt$',
    '^state\\soap-credential\.xml$',
    '^state\\soap-credential\.xml\..+\.tmp$',
    '^state\\soap-credential\.xml\..+\.lastgood\.bak$',
    '^state\\.*\.json$',
    '^state\\.*\.tmp$',
    '^state\\operator-marker-filesystem-test(?:\\|$)',
    '^logs(?:\\|$)',
    '^test-artifacts(?:\\|$)',
    '^backups(?:\\|$)',
    '^(?:watcher-task|supervisor-task)\.xml$',
    '\.zip$'
)

function Get-RelativePath {
    param([Parameter(Mandatory)][string] $FullName)
    return $FullName.Substring($OpsRoot.Length).TrimStart('\','/')
}

function Test-IncludedFile {
    param([Parameter(Mandatory)][string] $RelativePath)
    foreach ($pattern in $excludedPatterns) { if ($RelativePath -match $pattern) { return $false } }
    return $true
}

$distributionNames = @(
    'README.md',
    'New-OpsReworkArchive.ps1',
    'Register-RestartWatcher.ps1',
    'Register-Supervisor.ps1',
    'Restart-Watcher.ps1',
    'Set-SoapCredential.ps1',
    'Start-AzerothCore.ps1',
    'Status-AzerothCore.ps1',
    'Stop-AzerothCoreMaintenance.ps1',
    'Test-CredentialRotation.ps1',
    'Test-OperatorMaintenance.ps1',
    'Test-RestartAutomation.ps1',
    'Worldserver-Supervisor.ps1'
)
$files = @($distributionNames | ForEach-Object {
    $path = Join-Path $OpsRoot $_
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required distribution file is missing: $path" }
    [pscustomobject]@{ File = Get-Item -LiteralPath $path; RelativePath = $_ }
})

if ($ListOnly) {
    $files | ForEach-Object RelativePath
    exit 0
}

$outputFull = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $outputFull) { throw "Refusing to overwrite existing archive: $outputFull" }
$stage = Join-Path ([IO.Path]::GetTempPath()) ('azeroth-ops-rework-archive-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($entry in $files) {
        $destination = Join-Path $stage $entry.RelativePath
        $destinationDirectory = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationDirectory)) { New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null }
        Copy-Item -LiteralPath $entry.File.FullName -Destination $destination -Force
    }
    $outputDirectory = Split-Path -Parent $outputFull
    if (-not (Test-Path -LiteralPath $outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $outputFull -CompressionLevel Optimal
    Write-Host "Created distribution archive: $outputFull"
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
