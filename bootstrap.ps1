[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$mainScriptPath = Join-Path $PSScriptRoot 'installer.ps1'
$logDirectory = Join-Path ([IO.Path]::GetTempPath()) 'Cloudforl-Codex-Installer'
$logPath = Join-Path $logDirectory 'startup-error.log'

try {
  if (-not (Test-Path -LiteralPath $mainScriptPath)) {
    throw 'installer.ps1 is missing. Extract the complete ZIP package before running the installer.'
  }

  if (-not (Test-Path -LiteralPath $logDirectory)) {
    [void](New-Item -ItemType Directory -Path $logDirectory -Force)
  }

  $utf8 = New-Object Text.UTF8Encoding($true)
  $source = [IO.File]::ReadAllText($mainScriptPath, $utf8)
  $scriptBlock = [ScriptBlock]::Create($source)
  & $scriptBlock -InstallerRoot $PSScriptRoot
} catch {
  try {
    if (-not (Test-Path -LiteralPath $logDirectory)) {
      [void](New-Item -ItemType Directory -Path $logDirectory -Force)
    }
    $details = @(
      ('Time: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
      ('PowerShell: ' + $PSVersionTable.PSVersion.ToString()),
      ('Windows: ' + [Environment]::OSVersion.VersionString),
      '',
      ($_ | Out-String)
    ) -join "`r`n"
    [IO.File]::WriteAllText($logPath, $details, (New-Object Text.UTF8Encoding($true)))
  } catch {
  }

  try {
    Add-Type -AssemblyName System.Windows.Forms
    $message = "The installer could not start.`r`n`r`nError details were saved to:`r`n$logPath`r`n`r`nPlease send this log file to the installer developer."
    [Windows.Forms.MessageBox]::Show($message, 'Cloudforl Codex Installer', 'OK', 'Error') | Out-Null
    if (Test-Path -LiteralPath $logPath) {
      Start-Process -FilePath 'notepad.exe' -ArgumentList $logPath
    }
  } catch {
  }
  exit 1
}
