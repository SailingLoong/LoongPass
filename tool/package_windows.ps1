$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
$release = (Get-Content "$root\pubspec.yaml" | Where-Object { $_ -match '^version:' }) -replace '^version:\s*', ''
$name, $build = $release.Trim().Split('+')
$bundle = Join-Path $root 'build\windows\x64\runner\Release'
$dist = Join-Path $root 'dist-windows'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$exe = Join-Path $bundle 'LoongPass.exe'
$expectedVersion = ($name -split '-')[0] + '.' + $build
$info = (Get-Item $exe).VersionInfo
$actualVersion = '{0}.{1}.{2}.{3}' -f $info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart,$info.FilePrivatePart
if ($actualVersion -ne $expectedVersion) {
  throw 'Windows binary version does not match pubspec.yaml'
}
$binary = [IO.File]::ReadAllBytes($exe)
$pe = [BitConverter]::ToInt32($binary, 0x3c)
if ([BitConverter]::ToUInt16($binary, $pe + 4) -ne 0x8664) { throw 'Expected Windows x64 executable' }

# Distribute the Microsoft runtime beside the application, as Flutter requires.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$runtime = Get-ChildItem "$vs\VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT" -Directory | Sort-Object FullName -Descending | Select-Object -First 1
if (!$runtime) { throw 'Visual C++ distributable runtime unavailable' }
Copy-Item "$($runtime.FullName)\*.dll" $bundle
& python "$PSScriptRoot\bundle_licenses.py" $root $bundle
if ($LASTEXITCODE -ne 0) { throw 'Windows license bundling failed' }
$source = (& git -C $root rev-parse HEAD).Trim()
[IO.File]::WriteAllText((Join-Path $dist 'SOURCE_COMMIT.windows'), "$source`n", [Text.UTF8Encoding]::new($false))
$metadata = @{ version=$name; build=$build; architecture='x64'; source=$source; executableSHA256=(Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant() }
[IO.File]::WriteAllText((Join-Path $dist 'WINDOWS-BUILD.json'), ($metadata | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
Compress-Archive -Path "$bundle\*" -DestinationPath "$dist\LoongPass-Windows-x64.zip" -Force
$iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
if (!(Test-Path $iscc)) { throw 'Inno Setup 6 is required' }
& $iscc "/DReleaseVersion=$name" "/DBundleDirectory=$bundle" "/DOutputDirectory=$dist" "$PSScriptRoot\windows-installer.iss"
if ($LASTEXITCODE -ne 0) { throw 'Windows installer packaging failed' }
$checksums = @('LoongPass-Windows-x64.zip','LoongPass-Windows-x64-Setup.exe') | ForEach-Object {
  (Get-FileHash (Join-Path $dist $_) -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_
}
[IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.windows'), (($checksums -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
Write-Output "Packaged source-matched Windows $name ($build)"
