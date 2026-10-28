[CmdletBinding()]
param(
  [string]$Version = '0.4.6',
  [string]$PayloadPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectDirectory = $PSScriptRoot
$releaseDirectory = Join-Path $projectDirectory 'dist'
if ([string]::IsNullOrWhiteSpace($PayloadPath)) {
  $PayloadPath = Join-Path $releaseDirectory ('Cloudforl-Codex-Windows-Installer-v' + $Version + '.zip')
}

$sourcePath = Join-Path $projectDirectory 'exe-bootstrapper\Program.cs'
$manifestPath = Join-Path $projectDirectory 'exe-bootstrapper\app.manifest'
$windowsDirectory = $env:WINDIR
if ([string]::IsNullOrWhiteSpace($windowsDirectory)) {
  $windowsDirectory = $env:SystemRoot
}
if ([string]::IsNullOrWhiteSpace($windowsDirectory)) {
  throw 'The Windows directory environment variable is unavailable.'
}
$compilerPath = Join-Path $windowsDirectory 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$outputPath = Join-Path $releaseDirectory ('Cloudforl-Codex-Windows-Installer-v' + $Version + '.exe')

foreach ($requiredPath in @($PayloadPath, $sourcePath, $manifestPath, $compilerPath)) {
  if (-not (Test-Path -LiteralPath $requiredPath)) {
    throw ('Required build file is missing: ' + $requiredPath)
  }
}

if (-not (Test-Path -LiteralPath $releaseDirectory)) {
  [void](New-Item -ItemType Directory -Path $releaseDirectory -Force)
}

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Cloudforl-Codex-ExeBuild-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temporaryDirectory -Force)

try {
  $payloadHash = (Get-FileHash -LiteralPath $PayloadPath -Algorithm SHA256).Hash
  $versionParts = @($Version.Split('.'))
  while ($versionParts.Count -lt 4) {
    $versionParts += '0'
  }
  if ($versionParts.Count -ne 4 -or @($versionParts | Where-Object { $_ -notmatch '^\d+$' }).Count -gt 0) {
    throw ('Version must contain two to four numeric components: ' + $Version)
  }
  $assemblyVersion = $versionParts -join '.'
  $generatedSourcePath = Join-Path $temporaryDirectory 'Program.cs'
  $generatedManifestPath = Join-Path $temporaryDirectory 'app.manifest'
  $temporaryPayloadPath = Join-Path $temporaryDirectory 'payload.zip'
  $temporaryOutputPath = Join-Path $temporaryDirectory 'Cloudforl-Codex-Installer.exe'

  $source = [IO.File]::ReadAllText($sourcePath, [Text.Encoding]::UTF8)
  $source = $source.Replace('__VERSION__', $Version).Replace('__ASSEMBLY_VERSION__', $assemblyVersion).Replace('__PAYLOAD_SHA256__', $payloadHash)
  [IO.File]::WriteAllText($generatedSourcePath, $source, (New-Object Text.UTF8Encoding($true)))
  Copy-Item -LiteralPath $manifestPath -Destination $generatedManifestPath -Force
  Copy-Item -LiteralPath $PayloadPath -Destination $temporaryPayloadPath -Force

  $compilerArguments = @(
    '/nologo',
    '/target:winexe',
    '/platform:anycpu',
    '/optimize+',
    '/warn:4',
    ('/out:' + $temporaryOutputPath),
    ('/win32manifest:' + $generatedManifestPath),
    ('/resource:' + $temporaryPayloadPath + ',Cloudforl.CodexInstaller.payload.zip'),
    '/reference:System.dll',
    '/reference:System.Core.dll',
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.IO.Compression.dll',
    '/reference:System.IO.Compression.FileSystem.dll',
    $generatedSourcePath
  )

  & $compilerPath @compilerArguments
  if ($LASTEXITCODE -ne 0) {
    throw ('C# compiler failed with exit code ' + $LASTEXITCODE + '.')
  }
  if (-not (Test-Path -LiteralPath $temporaryOutputPath)) {
    throw 'C# compiler completed without creating the EXE.'
  }

  Copy-Item -LiteralPath $temporaryOutputPath -Destination $outputPath -Force
  $outputHash = Get-FileHash -LiteralPath $outputPath -Algorithm SHA256
  Write-Output ('EXE=' + $outputPath)
  Write-Output ('EMBEDDED_ZIP_SHA256=' + $payloadHash)
  Write-Output ('EXE_SHA256=' + $outputHash.Hash)
} finally {
  if (Test-Path -LiteralPath $temporaryDirectory) {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
  }
}
