<#!
.SYNOPSIS
    Create a distributable ops-rework ZIP without secrets or runtime material.

.DESCRIPTION
    The archive is assembled through a temporary staging directory. Credential
    files, account notes, runtime state, logs, task exports, and existing ZIPs are
    excluded by relative path before any included file is copied.
#>
[CmdletBinding()]
param(
    [string] $OutputPath = '',
    [switch] $ListOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OpsRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$defaultOutputPath = Join-Path (Split-Path -Parent $OpsRoot) ('ops-rework-distribution-{0}.zip' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = $defaultOutputPath }
$excludedPatterns = @(
    '^restart bot account\.txt$',
    '^state\\soap-credential\.xml$',
    '^state\\soap-credential\.xml\..+\.tmp$',
    '^state\\.*\.json$',
    '^state\\.*\.tmp$',
    '^state\\operator-marker-filesystem-test(?:\\|$)',
    '^logs(?:\\|$)',
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

$files = @(Get-ChildItem -LiteralPath $OpsRoot -Recurse -File -Force | ForEach-Object {
    $relative = Get-RelativePath -FullName $_.FullName
    if (Test-IncludedFile -RelativePath $relative) { [pscustomobject]@{ File = $_; RelativePath = $relative } }
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
