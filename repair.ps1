[CmdletBinding()]
param([string]$SourceRoot = $PSScriptRoot)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

function Show-RepairMessage {
  param([string]$Text, [ValidateSet('Information','Error','Warning')][string]$Kind = 'Information')
  [Windows.Forms.MessageBox]::Show($Text, 'Cloudforl Codex 无损修复', 'OK', $Kind) | Out-Null
}

try {
  $sourceRoot = [IO.Path]::GetFullPath($SourceRoot)
  $sourceSwitcher = Join-Path $sourceRoot 'provider-switcher.ps1'
  $sourceChoice = Join-Path $sourceRoot 'choice-window.ps1'
  if (-not (Test-Path -LiteralPath $sourceSwitcher) -or -not (Test-Path -LiteralPath $sourceChoice)) {
    throw '修复包不完整，请解压完整 ZIP 后再运行。'
  }

  $dataRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Cloudforl Codex Switcher'
  $installedSwitcher = Join-Path $dataRoot 'provider-switcher.ps1'
  $installedChoice = Join-Path $dataRoot 'choice-window.ps1'
  if (-not (Test-Path -LiteralPath $installedSwitcher) -and -not (Test-Path -LiteralPath $installedChoice)) {
    throw '没有找到已安装的 Cloudforl Codex 启动器。请先完成一次安装，或确认当前 Windows 用户与安装时相同。'
  }

  $backupRoot = Join-Path $dataRoot ('repair-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
  [void](New-Item -ItemType Directory -Path $backupRoot -Force)
  foreach ($path in @($installedSwitcher, $installedChoice)) {
    if (Test-Path -LiteralPath $path) {
      Copy-Item -LiteralPath $path -Destination (Join-Path $backupRoot ([IO.Path]::GetFileName($path))) -Force
    }
  }

  if (-not (Test-Path -LiteralPath $dataRoot)) { [void](New-Item -ItemType Directory -Path $dataRoot -Force) }
  Copy-Item -LiteralPath $sourceSwitcher -Destination $installedSwitcher -Force
  Copy-Item -LiteralPath $sourceChoice -Destination $installedChoice -Force

  $logPath = Join-Path $dataRoot 'repair.log'
  $log = @(
    ('时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    ('修复目录：' + $dataRoot),
    ('旧脚本备份：' + $backupRoot),
    '仅替换 provider-switcher.ps1 和 choice-window.ps1；未删除项目、会话、配置或密钥。'
  ) -join "`r`n"
  [IO.File]::WriteAllText($logPath, $log, (New-Object Text.UTF8Encoding($true)))
  Show-RepairMessage ('无损修复完成。`r`n`r`n已备份旧脚本：`r`n' + $backupRoot + '`r`n`r`n没有卸载 Codex，也没有删除项目、会话、配置或密钥。请重新双击桌面“Codex”图标测试。')
} catch {
  Show-RepairMessage ('修复未完成：`r`n`r`n' + $_.Exception.Message) 'Error'
  exit 1
}
