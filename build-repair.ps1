[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectDirectory = $PSScriptRoot
$releaseDirectory = Join-Path $projectDirectory 'dist'
$version = '0.1.0'
$zipPath = Join-Path $releaseDirectory ('Cloudforl-Codex-无损修复-v' + $version + '.zip')
if (-not (Test-Path -LiteralPath $releaseDirectory)) { [void](New-Item -ItemType Directory -Path $releaseDirectory -Force) }
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

$files = @(
  (Join-Path $projectDirectory '无损修复 Cloudforl Codex.cmd'),
  (Join-Path $projectDirectory 'repair.ps1'),
  (Join-Path $projectDirectory 'provider-switcher.ps1'),
  (Join-Path $projectDirectory 'choice-window.ps1'),
  (Join-Path $projectDirectory '无损修复说明.md')
)
foreach ($file in $files) { if (-not (Test-Path -LiteralPath $file)) { throw ('修复包文件缺失：' + $file) } }
Compress-Archive -LiteralPath $files -DestinationPath $zipPath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
Write-Output ('REPAIR_ZIP=' + $zipPath)
Write-Output ('SHA256=' + $hash)
