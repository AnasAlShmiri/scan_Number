# Regression checks run without Flutter, Gradle, downloads, or Pester.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('scan-number-paths-' + [guid]::NewGuid().ToString('N'))
$oldPath = $env:PATH
$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$project = Join-Path $testRoot 'project with spaces'
$scriptFile = Join-Path $project 'tools/build-offline.ps1'
$fakeBin = Join-Path $testRoot 'flutter/bin'
$outside = Join-Path $testRoot 'outside'
$checks = 0

function Assert-SetupFailure {
    param([string]$Case, [hashtable]$Parameters, [string]$Expected)
    try {
        & $scriptFile @Parameters
    }
    catch {
        if ($_.Exception.Message -notlike "*$Expected*") {
            throw "$Case failed with an unexpected error: $($_.Exception.Message)"
        }
        Write-Host "PASS: $Case"
        return
    }
    throw "$Case unexpectedly passed the missing-tool preflight."
}

try {
    New-Item -ItemType Directory -Path (Split-Path $scriptFile), $fakeBin, $outside -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'build-offline.ps1') $scriptFile
    Set-Content -Path (Join-Path $project 'pubspec.yaml') -Value 'name: scan_number'
    $flutterStub = Join-Path $fakeBin $(if ($onWindows) { 'flutter.bat' } else { 'flutter' })
    $stubText = if ($onWindows) { "@exit /b 1`r`n" } else { "#!/bin/sh`nexit 1`n" }
    [IO.File]::WriteAllText($flutterStub, $stubText, (New-Object Text.UTF8Encoding($false)))
    if (-not $onWindows) {
        & chmod +x $flutterStub
        if ($LASTEXITCODE -ne 0) { throw 'Could not prepare Flutter stub.' }
    }
    $env:PATH = $fakeBin + [IO.Path]::PathSeparator + $oldPath

    # Calling from outside the project must still locate the script's project.
    Push-Location $outside
    try {
        Assert-SetupFailure 'default project from unrelated working directory' @{} 'Flutter cache is incomplete:'
        $checks++
        Assert-SetupFailure 'explicit project path with spaces' @{ ProjectPath = $project } 'Flutter cache is incomplete:'
        $checks++
        Assert-SetupFailure 'invalid project fails before tool execution' @{ ProjectPath = $outside } 'ProjectPath must point'
        $checks++
    }
    finally { Pop-Location }
}
finally {
    $env:PATH = $oldPath
    if (Test-Path $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
Write-Host "$checks offline path checks passed."
