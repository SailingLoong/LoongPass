# Build the pinned upstream SDK with LoongPass's bounded custom UI bridge.
# CI owns cache reuse: this script never trusts or overwrites an existing SDK.
#Requires -Version 7.0
param([Parameter(Mandatory = $true)][string]$Destination)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Checked {
  param([string]$Program, [string[]]$Arguments)
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}

$destinationPath = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $destinationPath) {
  throw 'SDK destination already exists; CI must validate its cache or choose a fresh destination'
}
$python = (Get-Command python -ErrorAction Stop).Source
$git = (Get-Command git -ErrorAction Stop).Source
$nuget = (Get-Command nuget -ErrorAction Stop).Source
$patch = Join-Path $PSScriptRoot 'patch_winsparkle.py'
$checks = Join-Path (Split-Path -Parent $PSScriptRoot) 'test\winsparkle_patch_test.py'
$commit = (Invoke-Checked $python @($patch, '--upstream-commit')).Trim()
if ($commit -notmatch '^[0-9a-f]{40}$') { throw 'Invalid pinned SDK commit' }
$repository = 'https://github.com/vslavik/winsparkle.git'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = (Invoke-Checked $vswhere @('-latest', '-version', '[17.0,18.0)', '-products', '*',
  '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'))
if (!$vs) { throw 'Visual Studio 2022 with x64 C++ tools is required' }
$msbuild = Join-Path $vs.Trim() 'MSBuild\Current\Bin\MSBuild.exe'
if (!(Test-Path -LiteralPath $msbuild)) { throw 'VS2022 MSBuild unavailable' }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('loongpass-winsparkle-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path (Split-Path -Parent $destinationPath) ('.winsparkle-sdk-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
  $source = Join-Path $scratch 'source'
  Invoke-Checked $git @('-c', 'core.autocrlf=false', 'clone', '--no-checkout', '--filter=blob:none',
    '--single-branch', '--branch', 'v0.9.4', $repository, $source)
  Invoke-Checked $git @('-C', $source, 'config', 'core.autocrlf', 'false')
  Invoke-Checked $git @('-C', $source, 'checkout', '--detach', $commit)
  $actual = (Invoke-Checked $git @('-C', $source, 'rev-parse', 'HEAD')).Trim()
  if ($actual -ne $commit) { throw 'WinSparkle source commit mismatch' }
  Invoke-Checked $git @('-C', $source, '-c', 'core.autocrlf=false', 'submodule', 'update', '--init', '--recursive')
  $submodules = @(Invoke-Checked $git @('-C', $source, 'submodule', 'status', '--recursive'))
  if (!$submodules.Count -or @($submodules | Where-Object { $_ -notmatch '^ [0-9a-f]{40} ' }).Count) {
    throw 'Submodule checkout does not match pinned gitlinks'
  }
  Invoke-Checked $python @($checks, '--source', $source)
  Invoke-Checked $python @($patch, $source)

  Push-Location $source
  try {
    Invoke-Checked $nuget @('restore', 'WinSparkle.sln', '-NonInteractive')
    # Build the library and its solution dependencies, not examples or CLI tools.
    Invoke-Checked $msbuild @('WinSparkle.sln', '/t:WinSparkle', '/m:2', '/nr:false',
      '/p:Configuration=Release', '/p:Platform=x64', '/p:PreferredToolArchitecture=x64',
      '/p:MultiProcessorCompilation=false')
  } finally {
    Pop-Location
  }

  New-Item -ItemType Directory -Path (Join-Path $stage 'include') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $stage 'x64\Release') | Out-Null
  Copy-Item (Join-Path $source 'include\winsparkle*.h') (Join-Path $stage 'include')
  Copy-Item (Join-Path $source 'COPYING') $stage
  foreach ($name in @('WinSparkle.dll', 'WinSparkle.lib')) {
    $built = Join-Path $source "x64\Release\$name"
    if (!(Test-Path -LiteralPath $built) -or (Get-Item -LiteralPath $built).Length -eq 0) {
      throw "Missing SDK output: $name"
    }
    Copy-Item $built (Join-Path $stage 'x64\Release')
  }
  $hashes = [ordered]@{}
  Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName | ForEach-Object {
    $relative = [IO.Path]::GetRelativePath($stage, $_.FullName).Replace('\', '/')
    $hashes[$relative] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  $bridgeHashes = [ordered]@{}
  Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'winsparkle') -File | Sort-Object Name | ForEach-Object {
    $bridgeHashes[$_.Name] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  $provenance = [ordered]@{
    repository = $repository
    commit = $commit
    submodules = $submodules
    extension = 'inline-ui'
    bridgeSHA256 = $bridgeHashes
    patchSHA256 = (Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant()
    buildScriptSHA256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    msbuildVersion = @(Invoke-Checked $msbuild @('-version', '-nologo'))
    configuration = 'Release'
    platform = 'x64'
    files = $hashes
  }
  [IO.File]::WriteAllText((Join-Path $stage 'provenance.json'),
    ($provenance | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
  # Stage beside the destination, then atomically rename the completed SDK.
  [IO.Directory]::Move($stage, $destinationPath)
  Write-Output "Built pinned WinSparkle SDK: $destinationPath"
} finally {
  # Only paths uniquely allocated by this invocation are ever removed.
  try {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
  } finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
  }
}
