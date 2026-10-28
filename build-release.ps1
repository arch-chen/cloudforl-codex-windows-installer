[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectDirectory = $PSScriptRoot
$testPath = Join-Path $projectDirectory 'tests\run-tests.ps1'
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $testPath
if ($LASTEXITCODE -ne 0) {
  throw 'Tests failed; release package was not created.'
}

$version = '0.4.6'
$releaseDirectory = Join-Path $projectDirectory 'dist'
if (-not (Test-Path -LiteralPath $releaseDirectory)) {
  [void](New-Item -ItemType Directory -Path $releaseDirectory)
}

$zipPath = Join-Path $releaseDirectory ('Cloudforl-Codex-Windows-Installer-v' + $version + '.zip')
if (Test-Path -LiteralPath $zipPath) {
  Remove-Item -LiteralPath $zipPath -Force
}

$releaseFiles = @(
  (Join-Path $projectDirectory '安装 Cloudforl Codex.cmd'),
  (Join-Path $projectDirectory 'bootstrap.ps1'),
  (Join-Path $projectDirectory 'installer.ps1'),
  (Join-Path $projectDirectory 'wizard.ps1'),
  (Join-Path $projectDirectory 'provider-switcher.ps1'),
  (Join-Path $projectDirectory 'choice-window.ps1'),
  (Join-Path $projectDirectory '使用说明.md'),
  (Join-Path $projectDirectory '更新说明_v0.4.6.md'),
  (Join-Path $projectDirectory 'tools')
)
Compress-Archive -LiteralPath $releaseFiles -DestinationPath $zipPath -CompressionLevel Optimal

$hash = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
Write-Output ('RELEASE=' + $zipPath)
Write-Output ('SHA256=' + $hash.Hash)

$exeBuildPath = Join-Path $projectDirectory 'build-exe.ps1'
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $exeBuildPath -Version $version -PayloadPath $zipPath
if ($LASTEXITCODE -ne 0) {
  throw 'EXE installer build failed.'
}
