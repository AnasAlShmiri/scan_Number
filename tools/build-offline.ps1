[CmdletBinding()]
param(
    [string]$ProjectPath = '',
    [string]$GradleCachePath = $env:GRADLE_USER_HOME,
    [switch]$Install,
    [string]$DeviceId
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Windows PowerShell may not populate PSScriptRoot while evaluating parameter
# defaults. Resolve it inside the script body, after parameter binding instead.
if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $ProjectPath = Split-Path -Path $PSScriptRoot -Parent
    }
    elseif (Test-Path (Join-Path (Get-Location).Path 'pubspec.yaml')) {
        $ProjectPath = (Get-Location).Path
    }
    else {
        throw 'Cannot determine the project directory. Specify -ProjectPath with the full project path.'
    }
}

function Invoke-Checked {
    param([string]$Command, [string[]]$CommandArguments, [string]$Step)
    & $Command @CommandArguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed (exit $LASTEXITCODE). No online retry is performed. Keep the error above: it identifies any missing cached dependency."
    }
}

$projectRoot = (Resolve-Path -LiteralPath $ProjectPath).Path
$androidRoot = Join-Path $projectRoot 'android'
if (-not (Test-Path (Join-Path $projectRoot 'pubspec.yaml'))) {
    throw 'ProjectPath must point to the scan_number project.'
}
if ($Install -and [string]::IsNullOrWhiteSpace($DeviceId)) {
    throw 'Use -Install -DeviceId YOUR_PHONE_ID to install after building.'
}

$onWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
$flutterCommand = (Get-Command flutter -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
$flutterRoot = Split-Path (Split-Path $flutterCommand -Parent) -Parent
$dartBinary = if ($onWindows) { 'dart.exe' } else { 'dart' }
$gradleBinary = if ($onWindows) { 'gradle.bat' } else { 'gradle' }
$adbBinary = if ($onWindows) { 'adb.exe' } else { 'adb' }

# Do not bootstrap a Flutter installation by downloading its host SDK/tools.
foreach ($relative in @(
    'bin/cache/flutter_tools.snapshot',
    "bin/cache/dart-sdk/bin/$dartBinary",
    'bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill',
    'bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'
)) {
    if (-not (Test-Path (Join-Path $flutterRoot $relative))) {
        throw "Flutter cache is incomplete: $relative. Copy a complete Flutter installation for the same operating system from another computer; this script will not download it."
    }
}

if ([string]::IsNullOrWhiteSpace($GradleCachePath)) {
    $userDirectory = [Environment]::GetFolderPath('UserProfile')
    $GradleCachePath = Join-Path $userDirectory '.gradle'
}

$wrapperProperties = Get-Content -LiteralPath (Join-Path $androidRoot 'gradle/wrapper/gradle-wrapper.properties') -Raw
$versionMatch = [regex]::Match($wrapperProperties, 'gradle-([0-9.]+)-(?:bin|all)\.zip')
if (-not $versionMatch.Success) {
    throw 'Cannot determine the required Gradle version from gradle-wrapper.properties.'
}
$requiredVersion = [version]$versionMatch.Groups[1].Value
$pattern = Join-Path $GradleCachePath "wrapper/dists/gradle-*/*/gradle-*/bin/$gradleBinary"
$cachedGradles = @(
    Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue | ForEach-Object {
        $folderName = $_.Directory.Parent.Name
        $match = [regex]::Match($folderName, '^gradle-([0-9.]+)$')
        if ($match.Success) {
            $version = [version]$match.Groups[1].Value
            if ($version -ge $requiredVersion -and $version.Major -eq $requiredVersion.Major) {
                [pscustomobject]@{ Version = $version; Path = $_.FullName }
            }
        }
    }
)
$selectedGradle = $cachedGradles | Where-Object { $_.Version -eq $requiredVersion } | Select-Object -First 1
if ($null -eq $selectedGradle) {
    $selectedGradle = $cachedGradles | Sort-Object Version -Descending | Select-Object -First 1
}
if ($null -eq $selectedGradle) {
    throw "No installed Gradle $requiredVersion (or compatible newer $($requiredVersion.Major).x) found under $GradleCachePath/wrapper/dists. Copy an installed distribution from another computer. The wrapper is not started, so no distribution download will occur."
}

$sdkCandidates = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)
$localProperties = Join-Path $androidRoot 'local.properties'
if (Test-Path $localProperties) {
    $sdkMatch = [regex]::Match((Get-Content $localProperties -Raw), '(?m)^sdk\.dir=(.+)$')
    if ($sdkMatch.Success) {
        $sdkCandidates += $sdkMatch.Groups[1].Value.Trim().Replace('\:', ':').Replace('\\', '\')
    }
}
if ($onWindows -and $env:LOCALAPPDATA) {
    $sdkCandidates += Join-Path $env:LOCALAPPDATA 'Android/Sdk'
}
$sdkCandidates += Join-Path (Split-Path $flutterRoot -Parent) 'Sdk'
$androidSdk = $sdkCandidates | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path (Join-Path $_ 'platform-tools'))
} | Select-Object -First 1
if ($null -eq $androidSdk) {
    throw 'Android SDK not found. Set ANDROID_HOME to your existing SDK directory; no SDK installer will be run.'
}

$appSettings = Get-Content -LiteralPath (Join-Path $androidRoot 'settings.gradle.kts') -Raw
$agpMatch = [regex]::Match($appSettings, 'id\("com\.android\.application"\)\s+version\s+"([0-9.]+)"')
if (-not $agpMatch.Success) {
    throw 'Cannot determine the application Android Gradle Plugin version from settings.gradle.kts.'
}
$appAgpVersion = $agpMatch.Groups[1].Value
$offlineInit = Join-Path $PSScriptRoot 'gradle-offline.init.gradle'
if (-not (Test-Path -LiteralPath $offlineInit)) {
    throw 'gradle-offline.init.gradle is missing. Keep it beside build-offline.ps1.'
}

$offlineRepository = Join-Path $projectRoot '.offline/maven'
$localRepositoryArguments = @()
if (Test-Path -LiteralPath $offlineRepository) {
    $manifestFile = Join-Path $PSScriptRoot 'offline-artifacts.json'
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    foreach ($artifact in $manifest.artifacts) {
        $artifactFile = Join-Path $offlineRepository $artifact.path
        if (-not (Test-Path -LiteralPath $artifactFile)) {
            throw "Offline bundle is incomplete: $($artifact.path). Extract the complete kotlin-reflect-offline.zip into the project directory."
        }
        $actualHash = (Get-FileHash -LiteralPath $artifactFile -Algorithm SHA256).Hash
        if ($actualHash -ne $artifact.sha256) {
            throw "Offline artifact checksum failed: $($artifact.path). This file will not be used."
        }
    }
    $localRepositoryArguments = @("-PscanNumberOfflineMavenRepo=$offlineRepository")
}

$environmentChanges = @{
    'CI' = 'true'
    'FLUTTER_SUPPRESS_ANALYTICS' = 'true'
    'DART_SUPPRESS_ANALYTICS' = 'true'
    'GRADLE_USER_HOME' = $GradleCachePath
    'ANDROID_HOME' = $androidSdk
    'ANDROID_SDK_ROOT' = $androidSdk
}
$previousEnvironment = @{}
foreach ($name in $environmentChanges.Keys) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $environmentChanges[$name], 'Process')
}

Push-Location $projectRoot
try {
    Write-Host "Offline build: existing Flutter at $flutterRoot"
    Write-Host "Using cached Gradle $($selectedGradle.Version) at $($selectedGradle.Path)"
    Write-Host "Plugin libraries use the app's Android Gradle Plugin $appAgpVersion in offline mode."
    if ($localRepositoryArguments.Count -gt 0) {
        Write-Host "Verified local artifact bundle: $offlineRepository"
    }
    Write-Host "Pub may print 'Downloading packages...' as a generic heading; --offline only uses cached packages."
    Invoke-Checked $flutterCommand @('--no-version-check', '--suppress-analytics', 'pub', 'get', '--offline') 'Offline package resolution'

    # Directly invoke an installed Gradle, avoiding wrapper downloads. Android
    # SDK auto-installation is also disabled. Only the phone's ARM64 ABI is built.
    $buildArguments = @(
        '--offline', '--no-daemon', '--max-workers=2', '--console=plain',
        '--init-script', $offlineInit,
        '-p', $androidRoot, 'assembleDebug',
        "-PscanNumberOfflineAgpVersion=$appAgpVersion",
        '-Ptarget-platform=android-arm64',
        "-Ptarget=$projectRoot/lib/main.dart",
        '-Pandroid.builder.sdkDownload=false',
        '-Porg.gradle.java.installations.auto-download=false'
    ) + $localRepositoryArguments
    Invoke-Checked $selectedGradle.Path $buildArguments 'Offline Android build'

    $apk = Join-Path $projectRoot 'build/app/outputs/flutter-apk/app-debug.apk'
    if (-not (Test-Path $apk)) {
        throw "Build completed but APK not found at $apk."
    }
    Write-Host "APK ready: $apk"
    if ($Install) {
        $adb = Join-Path $androidSdk "platform-tools/$adbBinary"
        Invoke-Checked $adb @('-s', $DeviceId, 'install', '-r', $apk) 'Phone installation'
        Invoke-Checked $adb @('-s', $DeviceId, 'shell', 'am', 'start', '-n', 'com.anas.scan_number/.MainActivity') 'App launch'
    }
}
finally {
    Pop-Location
    foreach ($name in $previousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
}
