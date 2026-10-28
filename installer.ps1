[CmdletBinding()]
param(
  [switch]$SelfTest,
  [switch]$SkipAppInstall,
  [string]$InstallerRoot = $PSScriptRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InstallerRoot)) {
  $InstallerRoot = (Get-Location).Path
}
$script:InstallerSourceRoot = [IO.Path]::GetFullPath($InstallerRoot)
$script:RunId = [Guid]::NewGuid().ToString('N')
$script:UserCancelled = $false
$script:ActiveProcess = $null
$script:ActiveWebClient = $null
$script:InstallationCompleted = $false
$script:ProgressPercentLabel = $null
$script:ProgressDetailLabel = $null

$script:Installer = [ordered]@{
  Name = 'Cloudforl Codex 多接入安装器'
  Version = '0.4.6'
  StoreProductId = '9PLM9XGG6VKS'
  PackageName = 'OpenAI.Codex'
  PackageAppId = 'OpenAI.Codex_2p2nqsd0c76g0!App'
  ProviderId = ''
  ProviderName = ''
  BaseUrl = ''
  ModelsUrl = ''
  RegisterUrl = ''
  TokenUrl = ''
  CredentialDirectoryName = ''
  StatsigClientKey = 'client-sYWqzCYMRkUg4DqqiZcR5DGTNl2iD7zNJY0HoeDLzxR'
  LevelDbWriterX64Sha256 = '90393ED3F4C1779B996B83D901993925507732DF5FA5D5F45F8148C5B0C1534F'
  LevelDbWriterArm64Sha256 = 'E2B02608A4279306409FE95675DE9BEDE96EA9622FB44A7DC46A50DA6B7F70E5'
  DefaultModel = 'gpt-5.6-sol'
  MinimumBuild = 19041
  MsixX64 = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix'
  MsixArm64 = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-arm64.msix'
}

$script:ProviderChoices = @(
  [pscustomobject]@{
    Id = 'cloudforl'
    Host = 'cloudforl.com'
    Name = 'Cloudforl'
    BaseUrl = 'https://cloudforl.com/v1'
    RegisterUrl = 'https://cloudforl.com/register'
    TokenUrl = 'https://cloudforl.com/console/token'
    CredentialDirectoryName = 'Cloudforl Codex'
  }
)

function Set-ProviderSelection {
  param([Parameter(Mandatory = $true)][string]$Id)

  $matching = @($script:ProviderChoices | Where-Object { $_.Id -ceq $Id })
  if ($matching.Count -ne 1) {
    throw ('不支持的接口选项：' + $Id)
  }
  $choice = $matching[0]
  $script:Installer.ProviderId = $choice.Id
  $script:Installer.ProviderName = $choice.Name
  $script:Installer.BaseUrl = $choice.BaseUrl
  $script:Installer.ModelsUrl = $choice.BaseUrl.TrimEnd('/') + '/models'
  $script:Installer.RegisterUrl = $choice.RegisterUrl
  $script:Installer.TokenUrl = $choice.TokenUrl
  $script:Installer.CredentialDirectoryName = $choice.CredentialDirectoryName
}

function ConvertTo-TomlBasicString {
  param([Parameter(Mandatory = $true)][string]$Value)

  $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
  $escaped = $escaped.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
  return '"' + $escaped + '"'
}

function Write-AtomicUtf8File {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
  )

  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) {
    [void](New-Item -ItemType Directory -Path $directory -Force)
  }

  $tempName = '.' + [IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
  $tempPath = Join-Path $directory $tempName
  $utf8NoBom = New-Object Text.UTF8Encoding($false)

  try {
    [IO.File]::WriteAllText($tempPath, $Content, $utf8NoBom)
    if (Test-Path -LiteralPath $Path) {
      [IO.File]::Copy($tempPath, $Path, $true)
      Remove-Item -LiteralPath $tempPath -Force
    } else {
      [IO.File]::Move($tempPath, $Path)
    }
  } finally {
    if (Test-Path -LiteralPath $tempPath) {
      Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-CodexPaths {
  $userProfilePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
  $localAppDataPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
  $roamingAppDataPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
  $codexDirectory = $null
  if (-not [string]::IsNullOrWhiteSpace([string]$env:CODEX_HOME)) {
    $codexDirectory = [IO.Path]::GetFullPath($env:CODEX_HOME)
  } else {
    $codexDirectory = Join-Path $userProfilePath '.codex'
  }
  if ([string]::IsNullOrWhiteSpace($script:Installer.CredentialDirectoryName)) {
    throw '请先选择要对接的接口。'
  }
  $credentialDirectory = Join-Path $localAppDataPath $script:Installer.CredentialDirectoryName
  $desktopStatePaths = New-Object Collections.Generic.List[string]
  [void]$desktopStatePaths.Add((Join-Path $codexDirectory '.codex-global-state.json'))

  # Store-packaged Electron builds can persist the desktop atom state under the
  # package's LocalCacheRoaming tree instead of CODEX_HOME.
  try {
    $package = Get-CodexPackage
    if ($null -ne $package -and -not [string]::IsNullOrWhiteSpace([string]$package.PackageFamilyName)) {
      $packageRoot = Join-Path $localAppDataPath ('Packages\' + [string]$package.PackageFamilyName)
      foreach ($relativeStatePath in @(
        'LocalCache\Roaming\.codex-global-state.json',
        'LocalCache\Roaming\.codex\.codex-global-state.json',
        'LocalState\.codex-global-state.json',
        'LocalState\.codex\.codex-global-state.json'
      )) {
        [void]$desktopStatePaths.Add((Join-Path $packageRoot $relativeStatePath))
      }
    }
  } catch {
  }

  foreach ($fallbackStatePath in @(
    (Join-Path $localAppDataPath 'OpenAI\Codex\.codex-global-state.json'),
    (Join-Path $roamingAppDataPath 'OpenAI\Codex\.codex-global-state.json')
  )) {
    [void]$desktopStatePaths.Add($fallbackStatePath)
  }

  $uniqueDesktopStatePaths = @($desktopStatePaths | Select-Object -Unique)

  return [pscustomobject]@{
    CodexDirectory = $codexDirectory
    ConfigPath = Join-Path $codexDirectory 'config.toml'
    DesktopStatePath = Join-Path $codexDirectory '.codex-global-state.json'
    DesktopStatePaths = $uniqueDesktopStatePaths
    RequirementsPath = Join-Path $codexDirectory 'requirements.toml'
    CredentialDirectory = $credentialDirectory
    KeyPath = Join-Path $credentialDirectory 'key.dat'
    KeyHelperPath = Join-Path $credentialDirectory 'get-key.ps1'
  }
}

function Set-CodexDesktopLocale {
  param([Parameter(Mandatory = $true)][string]$StatePath)

  $state = New-Object psobject
  $stateExists = Test-Path -LiteralPath $StatePath
  if ($stateExists) {
    $rawState = [IO.File]::ReadAllText($StatePath, [Text.Encoding]::UTF8).Trim()
    if (-not [string]::IsNullOrWhiteSpace($rawState)) {
      try {
        $state = $rawState | ConvertFrom-Json
      } catch {
        throw ('Codex 桌面设置文件不是有效 JSON，已停止修改以保护原文件：' + $StatePath)
      }
      if ($null -eq $state -or $state -isnot [psobject]) {
        throw ('Codex 桌面设置文件的内容格式无法识别，已停止修改：' + $StatePath)
      }
    }
  }

  $desktop = $null
  if ($null -ne $state.PSObject.Properties['desktop'] -and $null -ne $state.desktop -and
      $state.desktop -is [psobject] -and $state.desktop -isnot [array]) {
    $desktop = $state.desktop
  } else {
    $desktop = New-Object psobject
  }
  $currentLocale = $null
  if ($null -ne $desktop.PSObject.Properties['localeOverride']) {
    $currentLocale = [string]$desktop.localeOverride
  }

  $persistedState = $null
  if ($null -ne $state.PSObject.Properties['electron-persisted-atom-state'] -and
      $null -ne $state.'electron-persisted-atom-state' -and
      $state.'electron-persisted-atom-state' -is [psobject] -and
      $state.'electron-persisted-atom-state' -isnot [array]) {
    $persistedState = $state.'electron-persisted-atom-state'
  } else {
    $persistedState = New-Object psobject
  }

  $agentModeByHost = $null
  if ($null -ne $persistedState.PSObject.Properties['agent-mode-by-host-id'] -and
      $null -ne $persistedState.'agent-mode-by-host-id' -and
      $persistedState.'agent-mode-by-host-id' -is [psobject] -and
      $persistedState.'agent-mode-by-host-id' -isnot [array]) {
    $agentModeByHost = $persistedState.'agent-mode-by-host-id'
  } else {
    $agentModeByHost = New-Object psobject
  }

  $currentAgentMode = $null
  if ($null -ne $agentModeByHost.PSObject.Properties['local']) {
    $currentAgentMode = [string]$agentModeByHost.local
  }
  $skipFullAccessConfirm = $false
  if ($null -ne $persistedState.PSObject.Properties['skip-full-access-confirm']) {
    $skipFullAccessConfirm = [bool]$persistedState.'skip-full-access-confirm'
  }

  $permissionModeVisibility = $null
  if ($null -ne $persistedState.PSObject.Properties['composer-permission-mode-visibility'] -and
      $null -ne $persistedState.'composer-permission-mode-visibility' -and
      $persistedState.'composer-permission-mode-visibility' -is [psobject] -and
      $persistedState.'composer-permission-mode-visibility' -isnot [array]) {
    $permissionModeVisibility = $persistedState.'composer-permission-mode-visibility'
  } else {
    $permissionModeVisibility = New-Object psobject
  }
  $fullAccessVisible = $false
  if ($null -ne $permissionModeVisibility.PSObject.Properties['full-access']) {
    $fullAccessVisible = [bool]$permissionModeVisibility.'full-access'
  }

  if ($currentLocale -ceq 'zh-CN' -and $currentAgentMode -ceq 'full-access' -and
      $skipFullAccessConfirm -and $fullAccessVisible) {
    return $StatePath
  }

  if ($stateExists) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    Copy-Item -LiteralPath $StatePath -Destination ($StatePath + '.backup-' + $stamp) -Force
  }

  $desktop | Add-Member -NotePropertyName 'localeOverride' -NotePropertyValue 'zh-CN' -Force
  $state | Add-Member -NotePropertyName 'desktop' -NotePropertyValue $desktop -Force
  $agentModeByHost | Add-Member -NotePropertyName 'local' -NotePropertyValue 'full-access' -Force
  $persistedState | Add-Member -NotePropertyName 'agent-mode-by-host-id' -NotePropertyValue $agentModeByHost -Force
  $persistedState | Add-Member -NotePropertyName 'skip-full-access-confirm' -NotePropertyValue $true -Force
  $permissionModeVisibility | Add-Member -NotePropertyName 'full-access' -NotePropertyValue $true -Force
  $persistedState | Add-Member -NotePropertyName 'composer-permission-mode-visibility' -NotePropertyValue $permissionModeVisibility -Force
  $state | Add-Member -NotePropertyName 'electron-persisted-atom-state' -NotePropertyValue $persistedState -Force
  # Keep top-level aliases for newer packaged clients that moved the persisted
  # atom fields out of electron-persisted-atom-state.
  $state | Add-Member -NotePropertyName 'agent-mode-by-host-id' -NotePropertyValue $agentModeByHost -Force
  $state | Add-Member -NotePropertyName 'skip-full-access-confirm' -NotePropertyValue $true -Force
  $state | Add-Member -NotePropertyName 'composer-permission-mode-visibility' -NotePropertyValue $permissionModeVisibility -Force
  $serialized = $state | ConvertTo-Json -Compress -Depth 100
  Write-AtomicUtf8File -Path $StatePath -Content $serialized

  $verified = [IO.File]::ReadAllText($StatePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
  if ($null -eq $verified.PSObject.Properties['desktop'] -or $null -eq $verified.desktop.PSObject.Properties['localeOverride'] -or
      [string]$verified.desktop.localeOverride -cne 'zh-CN') {
    throw 'Codex 桌面简体中文偏好写入后未通过校验。'
  }
  if ($null -eq $verified.PSObject.Properties['electron-persisted-atom-state'] -or
      $null -eq $verified.'electron-persisted-atom-state'.PSObject.Properties['agent-mode-by-host-id'] -or
      $null -eq $verified.'electron-persisted-atom-state'.'agent-mode-by-host-id'.PSObject.Properties['local'] -or
      [string]$verified.'electron-persisted-atom-state'.'agent-mode-by-host-id'.local -cne 'full-access') {
    throw 'Codex 桌面完全访问模式写入后未通过校验。'
  }
  if ($null -eq $verified.'electron-persisted-atom-state'.PSObject.Properties['composer-permission-mode-visibility'] -or
      $null -eq $verified.'electron-persisted-atom-state'.'composer-permission-mode-visibility'.PSObject.Properties['full-access'] -or
      $verified.'electron-persisted-atom-state'.'composer-permission-mode-visibility'.'full-access' -ne $true) {
    throw 'Codex 桌面完全访问选项可见性写入后未通过校验。'
  }
  return $StatePath
}

function Install-KeyHelper {
  param([Parameter(Mandatory = $true)][string]$Path)

  $helper = @'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$keyFile = Join-Path $PSScriptRoot 'key.dat'
if (-not (Test-Path -LiteralPath $keyFile)) {
  throw 'The selected Cloudforl API key has not been configured.'
}
$encoded = [IO.File]::ReadAllText($keyFile, [Text.Encoding]::UTF8).Trim()
$protectedBytes = [Convert]::FromBase64String($encoded)
$plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
  $protectedBytes,
  $null,
  [Security.Cryptography.DataProtectionScope]::CurrentUser
)
try {
  [Console]::Out.Write([Text.Encoding]::UTF8.GetString($plainBytes))
} finally {
  [Array]::Clear($plainBytes, 0, $plainBytes.Length)
}
'@

  Write-AtomicUtf8File -Path $Path -Content ($helper.Trim() + "`r`n")
}

function Protect-AndSaveApiKey {
  param(
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [Parameter(Mandatory = $true)][string]$Path
  )

  Add-Type -AssemblyName System.Security
  $plainBytes = [Text.Encoding]::UTF8.GetBytes($ApiKey)
  try {
    $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
      $plainBytes,
      $null,
      [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $encoded = [Convert]::ToBase64String($protectedBytes)
    Write-AtomicUtf8File -Path $Path -Content $encoded
  } finally {
    [Array]::Clear($plainBytes, 0, $plainBytes.Length)
  }
}

function Set-CodexConfiguration {
  param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$KeyHelperPath,
    [Parameter(Mandatory = $true)][string]$Model
  )

  $existing = ''
  if (Test-Path -LiteralPath $ConfigPath) {
    $existing = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)
  }

  $normalized = $existing.Replace("`r`n", "`n").Replace("`r", "`n")
  $lines = @($normalized -split "`n")
  $kept = New-Object Collections.Generic.List[string]
  $atRoot = $true
  $skipProviderSection = $false
  $skipManagedRootBlock = $false
  $desktopSectionFound = $false
  $inDesktopSection = $false
  $desktopLocaleWritten = $false

  foreach ($line in $lines) {
    if ($line -match '^\s*#\s*BEGIN (?:SUB2 CLOUDFORL|CLOUDFORL) CODEX MANAGED ROOT\s*$') {
      $skipManagedRootBlock = $true
      continue
    }
    if ($line -match '^\s*#\s*END (?:SUB2 CLOUDFORL|CLOUDFORL) CODEX MANAGED ROOT\s*$') {
      $skipManagedRootBlock = $false
      continue
    }
    if ($skipManagedRootBlock) {
      continue
    }
    if ($line -match '^\s*#\s*(?:BEGIN|END) (?:SUB2 CLOUDFORL|CLOUDFORL) CODEX MANAGED PROVIDER\s*$') {
      continue
    }

    if ($line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
      if ($inDesktopSection -and -not $desktopLocaleWritten) {
        [void]$kept.Add('localeOverride = "zh-CN"')
        $desktopLocaleWritten = $true
      }

      $atRoot = $false
      $sectionName = $matches[1].Trim()
      $inDesktopSection = ($sectionName -ieq 'desktop')
      if ($inDesktopSection) {
        $desktopSectionFound = $true
      }
      $skipProviderSection = (
        $sectionName -ieq ('model_providers.' + $script:Installer.ProviderId) -or
        $sectionName -ilike ('model_providers.' + $script:Installer.ProviderId + '.*')
      )
      if ($skipProviderSection) {
        continue
      }
    }

    if ($skipProviderSection) {
      continue
    }

    if ($atRoot -and $line -match '^\s*(model|model_provider|default_permissions|approval_policy|sandbox_mode)\s*=') {
      continue
    }

    if ($inDesktopSection -and $line -match '^\s*localeOverride\s*=') {
      continue
    }

    [void]$kept.Add($line)
  }

  if ($inDesktopSection -and -not $desktopLocaleWritten) {
    [void]$kept.Add('localeOverride = "zh-CN"')
    $desktopLocaleWritten = $true
  }

  while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) {
    $kept.RemoveAt($kept.Count - 1)
  }
  while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[0])) {
    $kept.RemoveAt(0)
  }

  $rootBlock = @(
    '# BEGIN CLOUDFORL CODEX MANAGED ROOT',
    ('model = ' + (ConvertTo-TomlBasicString $Model)),
    ('model_provider = ' + (ConvertTo-TomlBasicString $script:Installer.ProviderId)),
    'default_permissions = ":danger-full-access"',
    '# END CLOUDFORL CODEX MANAGED ROOT'
  )

  $desktopBlock = @(
    '[desktop]',
    'localeOverride = "zh-CN"'
  )

  $providerBlock = @(
    '# BEGIN CLOUDFORL CODEX MANAGED PROVIDER',
    ('[model_providers.' + $script:Installer.ProviderId + ']'),
    ('name = ' + (ConvertTo-TomlBasicString $script:Installer.ProviderName)),
    ('base_url = ' + (ConvertTo-TomlBasicString $script:Installer.BaseUrl)),
    'wire_api = "responses"',
    '',
    ('[model_providers.' + $script:Installer.ProviderId + '.auth]'),
    'command = "powershell.exe"',
    ('args = ["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ' + (ConvertTo-TomlBasicString $KeyHelperPath) + ']'),
    'timeout_ms = 10000',
    '# END CLOUDFORL CODEX MANAGED PROVIDER'
  )

  $newLines = New-Object Collections.Generic.List[string]
  foreach ($item in $rootBlock) { [void]$newLines.Add($item) }
  if ($kept.Count -gt 0) {
    [void]$newLines.Add('')
    foreach ($item in $kept) { [void]$newLines.Add($item) }
  }
  if (-not $desktopSectionFound) {
    [void]$newLines.Add('')
    foreach ($item in $desktopBlock) { [void]$newLines.Add($item) }
  }
  [void]$newLines.Add('')
  foreach ($item in $providerBlock) { [void]$newLines.Add($item) }

  $newContent = (($newLines.ToArray() -join "`r`n").Trim() + "`r`n")
  if ($newContent -eq $existing) {
    return $null
  }

  $backupPath = $null
  if (Test-Path -LiteralPath $ConfigPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backupPath = $ConfigPath + '.backup-' + $stamp
    Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
  }

  Write-AtomicUtf8File -Path $ConfigPath -Content $newContent
  return $backupPath
}

function Select-PreferredModel {
  param([string[]]$AvailableModels)

  $priority = @(
    'gpt-5.6-sol',
    'gpt-5.6-terra',
    'gpt-5.6-luna',
    'gpt-5.5',
    'gpt-5.4'
  )
  foreach ($candidate in $priority) {
    if ($AvailableModels -contains $candidate) {
      return $candidate
    }
  }
  return $script:Installer.DefaultModel
}

function Get-CodexPackage {
  return Get-AppxPackage -Name $script:Installer.PackageName -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Assert-SupportedWindows {
  $os = Get-CimInstance Win32_OperatingSystem
  $build = [int]$os.BuildNumber
  if ($build -lt [int]$script:Installer.MinimumBuild) {
    throw ('需要 Windows 10 版本 2004 或更新系统（系统内部版本至少为 {0}）。当前内部版本：{1}。' -f $script:Installer.MinimumBuild, $build)
  }

  $architecture = $env:PROCESSOR_ARCHITECTURE
  if ($architecture -notin @('AMD64', 'ARM64')) {
    throw ('暂不支持此处理器架构：' + $architecture + '。请使用 x64 或 ARM64 Windows 设备。')
  }
}

function Set-UiStatus {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [int]$Progress = -1,
    [switch]$IsError
  )

  if ($null -ne $script:StatusLabel) {
    $script:StatusLabel.Text = $Text
    if ($IsError) {
      $script:StatusLabel.ForeColor = [Drawing.Color]::FromArgb(255, 117, 133)
    } else {
      $script:StatusLabel.ForeColor = [Drawing.Color]::FromArgb(190, 216, 228)
    }
  }
  if ($null -ne $script:ProgressBar -and $Progress -ge 0) {
    $script:ProgressBar.Style = [Windows.Forms.ProgressBarStyle]::Continuous
    $target = [Math]::Max(0, [Math]::Min(100, $Progress))
    $script:ProgressBar.Value = [Math]::Max([int]$script:ProgressBar.Value, $target)
    if ($null -ne $script:ProgressPercentLabel) {
      $script:ProgressPercentLabel.Text = ([string]$script:ProgressBar.Value + '%')
    }
  }
  [Windows.Forms.Application]::DoEvents()
}

function Set-UiProgressDetail {
  param([AllowEmptyString()][string]$Text)

  if ($null -ne $script:ProgressDetailLabel) {
    $script:ProgressDetailLabel.Text = $Text
  }
  [Windows.Forms.Application]::DoEvents()
}

function Format-TransferSize {
  param([long]$Bytes)

  if ($Bytes -lt 1KB) { return ([string]$Bytes + ' B') }
  if ($Bytes -lt 1MB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
  if ($Bytes -lt 1GB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
  return ('{0:N2} GB' -f ($Bytes / 1GB))
}

function Format-TransferRate {
  param([double]$BytesPerSecond)

  if ($BytesPerSecond -le 0) { return '等待数据…' }
  return ((Format-TransferSize -Bytes ([long]$BytesPerSecond)) + '/s')
}

function Wait-ProcessWithUi {
  param(
    [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
    [string]$ActivityText = '',
    [int]$Progress = -1
  )

  $script:ActiveProcess = $Process
  $startedAt = Get-Date
  $lastUiUpdate = $startedAt.AddSeconds(-2)
  try {
    while (-not $Process.HasExited) {
      if ($script:UserCancelled) {
        try { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue } catch {}
        throw (New-Object System.OperationCanceledException -ArgumentList '用户已关闭安装窗口。')
      }
      [Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 150
      $Process.Refresh()
      if (-not [string]::IsNullOrWhiteSpace($ActivityText) -and ((Get-Date) - $lastUiUpdate).TotalMilliseconds -ge 500) {
        $elapsed = (Get-Date) - $startedAt
        Set-UiStatus -Text ($ActivityText + ' · 已用时 ' + $elapsed.ToString('hh\:mm\:ss')) -Progress $Progress
        Set-UiProgressDetail -Text '微软安装服务通常不返回总大小和下载速度；进度条为等待状态，窗口仍在工作。'
        $lastUiUpdate = Get-Date
      }
    }
    return $Process.ExitCode
  } finally {
    $script:ActiveProcess = $null
  }
}

function Invoke-WingetInstall {
  $script:StoreInstallFailure = ''
  $wingetCommand = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($null -eq $wingetCommand) {
    $script:StoreInstallFailure = '未找到 winget.exe；可能未安装或未启用 App Installer'
    return $false
  }

  $logDirectory = Join-Path ([IO.Path]::GetTempPath()) 'Cloudforl-Codex-Installer'
  if (-not (Test-Path -LiteralPath $logDirectory)) {
    [void](New-Item -ItemType Directory -Path $logDirectory -Force)
  }
  $stdoutPath = Join-Path $logDirectory ('winget-output-' + $script:RunId + '.log')
  $stderrPath = Join-Path $logDirectory ('winget-error-' + $script:RunId + '.log')
  $arguments = @(
    'install',
    '--id', $script:Installer.StoreProductId,
    '--source', 'msstore',
    '--exact',
    '--accept-package-agreements',
    '--accept-source-agreements',
    '--silent',
    '--disable-interactivity'
  )

  Set-UiStatus -Text '正在通过微软可信安装渠道下载并安装 ChatGPT（内含 Codex）…' -Progress 22
  if ($null -ne $script:ProgressBar) {
    $script:ProgressBar.Style = [Windows.Forms.ProgressBarStyle]::Marquee
    $script:ProgressBar.MarqueeAnimationSpeed = 24
  }
  Set-UiProgressDetail -Text '正在等待微软安装服务响应；将显示已用时间。'
  try {
    $process = Start-Process -FilePath $wingetCommand.Source -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $exitCode = Wait-ProcessWithUi -Process $process -ActivityText '微软安装服务正在处理下载和安装' -Progress 22
  } catch {
    if ($script:UserCancelled) {
      throw
    }
    $script:StoreInstallFailure = 'winget 启动或运行异常：' + $_.Exception.Message
    return $false
  }
  if ($null -ne (Get-CodexPackage)) {
    Set-UiProgressDetail -Text '微软安装服务已完成客户端安装。'
    return $true
  }
  $script:StoreInstallFailure = ('winget 未完成安装，退出代码 ' + $exitCode)
  return $false
}

function Download-FileWithUi {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][string]$Destination
  )

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $client = New-Object Net.WebClient
  $script:ActiveWebClient = $client
  $client.Headers['User-Agent'] = 'Cloudforl-Codex-Installer/' + $script:Installer.Version
  $task = $client.DownloadFileTaskAsync([Uri]$Uri, $Destination)
  $lastReportedPercent = -1
  $startedAt = Get-Date
  $lastSampleAt = $startedAt
  $lastSampleBytes = [long]0
  $lastDetailAt = $startedAt.AddSeconds(-2)
  try {
    while (-not $task.IsCompleted) {
      if ($script:UserCancelled) {
        $client.CancelAsync()
        throw (New-Object System.OperationCanceledException -ArgumentList '用户已关闭安装窗口。')
      }
      $totalBytes = [long]0
      $contentLength = if ($null -ne $client.ResponseHeaders) { $client.ResponseHeaders['Content-Length'] } else { $null }
      if ([long]::TryParse([string]$contentLength, [ref]$totalBytes) -and $totalBytes -gt 0 -and (Test-Path -LiteralPath $Destination)) {
        $receivedBytes = (Get-Item -LiteralPath $Destination).Length
        $downloadPercent = [Math]::Min(100, [Math]::Floor(100.0 * $receivedBytes / $totalBytes))
        $now = Get-Date
        $sampleSeconds = [Math]::Max(0.1, ($now - $lastSampleAt).TotalSeconds)
        $rate = [Math]::Max(0, ($receivedBytes - $lastSampleBytes) / $sampleSeconds)
        if ($downloadPercent -gt $lastReportedPercent) {
          $lastReportedPercent = $downloadPercent
          $overallStep = 28 + [Math]::Floor(16.0 * $downloadPercent / 100)
          Set-UiStatus -Text ('正在下载官方安装包：' + $downloadPercent + '%') -Progress $overallStep
        }
        if (($now - $lastDetailAt).TotalMilliseconds -ge 500) {
          Set-UiProgressDetail -Text ('已下载 ' + (Format-TransferSize $receivedBytes) + ' / ' + (Format-TransferSize $totalBytes) + ' · ' + (Format-TransferRate $rate))
          $lastDetailAt = $now
        }
        $lastSampleAt = $now
        $lastSampleBytes = $receivedBytes
      } elseif (((Get-Date) - $lastDetailAt).TotalMilliseconds -ge 500) {
        $receivedBytes = if (Test-Path -LiteralPath $Destination) { (Get-Item -LiteralPath $Destination).Length } else { [long]0 }
        $now = Get-Date
        $sampleSeconds = [Math]::Max(0.1, ($now - $lastSampleAt).TotalSeconds)
        $rate = [Math]::Max(0, ($receivedBytes - $lastSampleBytes) / $sampleSeconds)
        Set-UiStatus -Text ('正在下载官方安装包：已下载 ' + (Format-TransferSize $receivedBytes)) -Progress 28
        Set-UiProgressDetail -Text ('已下载 ' + (Format-TransferSize $receivedBytes) + ' · 总大小暂不可用 · ' + (Format-TransferRate $rate))
        $lastDetailAt = $now
        $lastSampleAt = $now
        $lastSampleBytes = $receivedBytes
      }
      [Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 150
    }
    $task.GetAwaiter().GetResult()
    $finalBytes = if (Test-Path -LiteralPath $Destination) { (Get-Item -LiteralPath $Destination).Length } else { [long]0 }
    $elapsedSeconds = [Math]::Max(0.1, ((Get-Date) - $startedAt).TotalSeconds)
    Set-UiProgressDetail -Text ('下载完成：' + (Format-TransferSize $finalBytes) + ' · 平均 ' + (Format-TransferRate ($finalBytes / $elapsedSeconds)))
  } finally {
    $script:ActiveWebClient = $null
    $client.Dispose()
  }
}

function Invoke-DirectMsixInstall {
  $architecture = $env:PROCESSOR_ARCHITECTURE
  if ($architecture -eq 'ARM64') {
    $uri = $script:Installer.MsixArm64
    $fileName = 'ChatGPT-arm64.msix'
  } else {
    $uri = $script:Installer.MsixX64
    $fileName = 'ChatGPT-x64.msix'
  }

  $downloadRoot = Join-Path ([IO.Path]::GetTempPath()) 'Cloudforl-Codex-Installer'
  $downloadDirectory = Join-Path $downloadRoot ('download-' + $script:RunId)
  if (-not (Test-Path -LiteralPath $downloadDirectory)) {
    [void](New-Item -ItemType Directory -Path $downloadDirectory -Force)
  }
  $msixPath = Join-Path $downloadDirectory $fileName

  try {
    $fallbackText = '商店安装通道未成功；正在下载 OpenAI 官方签名安装包…'
    if (-not [string]::IsNullOrWhiteSpace([string]$script:StoreInstallFailure)) {
      $fallbackText = '商店通道未成功：' + $script:StoreInstallFailure + "`r`n" + '正在下载 OpenAI 官方签名安装包…'
      $diagnosticPath = Join-Path $downloadRoot 'store-fallback.log'
      try { Add-Content -LiteralPath $diagnosticPath -Value ((Get-Date).ToString('s') + ' ' + $script:StoreInstallFailure) -Encoding UTF8 } catch {}
    }
    Set-UiStatus -Text $fallbackText -Progress 28
    Download-FileWithUi -Uri $uri -Destination $msixPath
    Set-UiStatus -Text '官方安装包下载完成，正在检查文件…' -Progress 44

    $file = Get-Item -LiteralPath $msixPath
    if ($file.Length -lt 10MB) {
      throw '下载到的安装包大小异常。'
    }

    Set-UiStatus -Text '正在校验 OpenAI 官方安装包签名…' -Progress 45
    $signature = Get-AuthenticodeSignature -FilePath $msixPath
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
      throw ('安装包数字签名无效：' + $signature.Status)
    }

    Set-UiStatus -Text '签名校验通过，正在安装客户端和运行组件…' -Progress 58
    $escapedPath = $msixPath.Replace("'", "''")
    $installCommand = "& { Add-AppxPackage -Path '$escapedPath' -ForceApplicationShutdown -ErrorAction Stop }"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($installCommand))
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand) -WindowStyle Hidden -PassThru
    $exitCode = Wait-ProcessWithUi -Process $process
    if ($exitCode -ne 0 -or $null -eq (Get-CodexPackage)) {
      throw ('官方安装包安装失败，退出代码：' + $exitCode)
    }
  } finally {
    if (Test-Path -LiteralPath $msixPath) {
      Remove-Item -LiteralPath $msixPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $downloadDirectory) {
      Remove-Item -LiteralPath $downloadDirectory -Force -ErrorAction SilentlyContinue
    }
  }
}

function Install-CodexApplication {
  if ($SkipAppInstall) {
    return
  }

  if ($null -ne (Get-CodexPackage)) {
    Set-UiStatus -Text '已检测到官方客户端，正在继续配置…' -Progress 62
    return
  }

  if (-not (Invoke-WingetInstall)) {
    Invoke-DirectMsixInstall
  }

  if ($null -eq (Get-CodexPackage)) {
    throw '客户端安装后未能通过完整性检查。'
  }
}

function Test-SelectedProviderApiKey {
  param([Parameter(Mandatory = $true)][string]$ApiKey)

  Add-Type -AssemblyName System.Net.Http
  $client = New-Object Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds(30)
  $client.DefaultRequestHeaders.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer', $ApiKey)
  $client.DefaultRequestHeaders.UserAgent.ParseAdd('Cloudforl-Codex-Installer/' + $script:Installer.Version)

  try {
    $task = $client.GetAsync($script:Installer.ModelsUrl)
    while (-not $task.IsCompleted) {
      [Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 100
    }
    $response = $task.GetAwaiter().GetResult()
    if ([int]$response.StatusCode -eq 401 -or [int]$response.StatusCode -eq 403) {
      return [pscustomobject]@{ Success = $false; Unauthorized = $true; Models = @(); Message = '密钥无效或没有访问权限。' }
    }
    if (-not $response.IsSuccessStatusCode) {
      return [pscustomobject]@{ Success = $false; Unauthorized = $false; Models = @(); Message = ('平台返回 HTTP ' + [int]$response.StatusCode) }
    }

    $contentTask = $response.Content.ReadAsStringAsync()
    while (-not $contentTask.IsCompleted) {
      [Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 50
    }
    $payload = $contentTask.GetAwaiter().GetResult() | ConvertFrom-Json
    $models = @($payload.data | ForEach-Object { [string]$_.id } | Where-Object { $_ })
    return [pscustomobject]@{ Success = $true; Unauthorized = $false; Models = $models; Message = '验证成功。' }
  } catch {
    return [pscustomobject]@{ Success = $false; Unauthorized = $false; Models = @(); Message = '暂时无法连接密钥验证服务。' }
  } finally {
    $client.Dispose()
  }
}









function Get-CodexI18nLevelDbDirectories {
  $package = Get-CodexPackage
  if ($null -eq $package) {
    return @()
  }

  $localAppDataPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
  $packageRoot = Join-Path (Join-Path $localAppDataPath 'Packages') $package.PackageFamilyName
  $directories = New-Object Collections.Generic.List[string]
  $seen = New-Object Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  $knownPath = Join-Path $packageRoot 'LocalCache\Roaming\Codex\web\Codex\Default\Local Storage\leveldb'
  if ((Test-Path -LiteralPath $knownPath) -and $seen.Add($knownPath)) {
    [void]$directories.Add($knownPath)
  }

  $localCachePath = Join-Path $packageRoot 'LocalCache'
  if (Test-Path -LiteralPath $localCachePath) {
    try {
      foreach ($directory in @(Get-ChildItem -LiteralPath $localCachePath -Recurse -Directory -Filter 'leveldb' -ErrorAction SilentlyContinue)) {
        if ($directory.FullName -like '*Local Storage*' -and $seen.Add($directory.FullName)) {
          [void]$directories.Add($directory.FullName)
        }
      }
    } catch {
    }
  }

  return $directories.ToArray()
}

function Test-CodexI18nCache {
  $foundEnableI18n = $false
  $foundLocaleSource = $false

  foreach ($directory in @(Get-CodexI18nLevelDbDirectories)) {
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue)) {
      if ($file.Length -le 0 -or $file.Length -gt 67108864) {
        continue
      }

      $stream = $null
      try {
        $stream = New-Object IO.FileStream($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $bytes = New-Object byte[] $stream.Length
        $offset = 0
        while ($offset -lt $bytes.Length) {
          $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
          if ($read -le 0) { break }
          $offset += $read
        }

        $utf8Content = [Text.Encoding]::UTF8.GetString($bytes, 0, $offset)
        $unicodeEvenLength = $offset - ($offset % 2)
        $unicodeOddLength = [Math]::Max(0, ($offset - 1) - (($offset - 1) % 2))
        $unicodeEven = if ($unicodeEvenLength -gt 0) { [Text.Encoding]::Unicode.GetString($bytes, 0, $unicodeEvenLength) } else { '' }
        $unicodeOdd = if ($unicodeOddLength -gt 0) { [Text.Encoding]::Unicode.GetString($bytes, 1, $unicodeOddLength) } else { '' }

        if (
          $utf8Content -match '(?is)enable_i18n.{0,160}\btrue\b' -or
          $unicodeEven -match '(?is)enable_i18n.{0,160}\btrue\b' -or
          $unicodeOdd -match '(?is)enable_i18n.{0,160}\btrue\b'
        ) {
          $foundEnableI18n = $true
        }
        if (
          $utf8Content -match '(?is)locale_source.{0,120}\bIDE\b' -or
          $unicodeEven -match '(?is)locale_source.{0,120}\bIDE\b' -or
          $unicodeOdd -match '(?is)locale_source.{0,120}\bIDE\b'
        ) {
          $foundLocaleSource = $true
        }
        if ($foundEnableI18n -and $foundLocaleSource) {
          return $true
        }
      } catch {
      } finally {
        if ($null -ne $stream) {
          $stream.Dispose()
        }
      }
    }
  }

  return $false
}

function Wait-CodexI18nCache {
  param([int]$TimeoutSeconds = 60)

  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-CodexI18nCache) {
      return $true
    }
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 500
  }
  return (Test-CodexI18nCache)
}

function Get-AvailableLoopbackPort {
  $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  try {
    $listener.Start()
    return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  } finally {
    $listener.Stop()
  }
}

function Get-CodexApplicationUserModelId {
  $package = Get-CodexPackage
  if ($null -eq $package) {
    throw '没有找到已安装的官方 Codex 客户端。'
  }

  $applicationId = 'App'
  try {
    $manifest = Get-AppxPackageManifest -Package $package.PackageFullName
    $application = @($manifest.Package.Applications.Application) | Select-Object -First 1
    if ($null -ne $application -and -not [string]::IsNullOrWhiteSpace([string]$application.Id)) {
      $applicationId = [string]$application.Id
    }
  } catch {
  }

  $aumid = $package.PackageFamilyName + '!' + $applicationId
  try {
    $registeredApp = Get-StartApps | Where-Object { $_.AppID -like ($package.PackageFamilyName + '!*') } | Select-Object -First 1
    if ($null -ne $registeredApp -and -not [string]::IsNullOrWhiteSpace([string]$registeredApp.AppID)) {
      $aumid = [string]$registeredApp.AppID
    }
  } catch {
  }

  return $aumid
}

function Initialize-PackagedAppActivationType {
  if ($null -ne ('Cloudforl.CodexInstaller.PackagedAppActivation' -as [type])) {
    return
  }

  $activationSource = @'
using System;
using System.Runtime.InteropServices;

namespace Cloudforl.CodexInstaller
{
    [Flags]
    internal enum ActivateOptions
    {
        None = 0,
        DesignMode = 0x1,
        NoErrorUI = 0x2,
        NoSplashScreen = 0x4
    }

    [ComImport]
    [Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IApplicationActivationManager
    {
        [PreserveSig]
        int ActivateApplication(
            [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments,
            ActivateOptions options,
            out uint processId);

        [PreserveSig]
        int ActivateForFile(
            [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            IntPtr itemArray,
            [MarshalAs(UnmanagedType.LPWStr)] string verb,
            out uint processId);

        [PreserveSig]
        int ActivateForProtocol(
            [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            IntPtr itemArray,
            out uint processId);
    }

    [ComImport]
    [Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    internal class ApplicationActivationManager
    {
    }

    public static class PackagedAppActivation
    {
        public static uint Activate(string appUserModelId, string arguments)
        {
            object managerObject = new ApplicationActivationManager();
            try
            {
                IApplicationActivationManager manager = (IApplicationActivationManager)managerObject;
                uint processId;
                int result = manager.ActivateApplication(
                    appUserModelId,
                    arguments ?? String.Empty,
                    ActivateOptions.None,
                    out processId);
                if (result < 0)
                {
                    Marshal.ThrowExceptionForHR(result);
                }
                return processId;
            }
            finally
            {
                if (Marshal.IsComObject(managerObject))
                {
                    Marshal.FinalReleaseComObject(managerObject);
                }
            }
        }
    }
}
'@

  Add-Type -TypeDefinition $activationSource -Language CSharp -ErrorAction Stop
}

function Start-CodexPackagedApplication {
  param([AllowEmptyString()][string]$Arguments = '')

  Initialize-PackagedAppActivationType
  $aumid = Get-CodexApplicationUserModelId
  return [Cloudforl.CodexInstaller.PackagedAppActivation]::Activate($aumid, $Arguments)
}

function Get-LoopbackJson {
  param([Parameter(Mandatory = $true)][string]$Url)

  Add-Type -AssemblyName System.Net.Http
  $handler = New-Object Net.Http.HttpClientHandler
  $handler.UseProxy = $false
  $client = New-Object Net.Http.HttpClient($handler)
  $client.Timeout = [TimeSpan]::FromSeconds(2)
  try {
    $task = $client.GetStringAsync($Url)
    while (-not $task.IsCompleted) {
      [Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 50
    }
    return ($task.GetAwaiter().GetResult() | ConvertFrom-Json)
  } finally {
    $client.Dispose()
  }
}

function Wait-CodexDevToolsTarget {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [int]$TimeoutSeconds = 25
  )

  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      $targets = @(Get-LoopbackJson -Url ('http://127.0.0.1:' + $Port + '/json/list'))
      $preferred = @($targets | Where-Object {
        $_.type -eq 'page' -and
        -not [string]::IsNullOrWhiteSpace([string]$_.webSocketDebuggerUrl)
      }) | Select-Object -First 1
      if ($null -ne $preferred) {
        return $preferred
      }
    } catch {
    }
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 250
  }

  return $null
}

function Invoke-CodexDevToolsCommand {
  param(
    [Parameter(Mandatory = $true)][string]$WebSocketUrl,
    [Parameter(Mandatory = $true)][string]$Method,
    [AllowNull()][object]$Parameters = $null
  )

  Add-Type -AssemblyName System
  $socket = New-Object Net.WebSockets.ClientWebSocket
  $cancellation = New-Object Threading.CancellationTokenSource
  $cancellation.CancelAfter([TimeSpan]::FromSeconds(15))
  try {
    $webSocketUri = New-Object Uri($WebSocketUrl)
    $origin = 'http://127.0.0.1:' + $webSocketUri.Port
    $socket.Options.SetRequestHeader('Origin', $origin)
    $connectTask = $socket.ConnectAsync($webSocketUri, $cancellation.Token)
    while (-not $connectTask.IsCompleted) {
      [Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 50
    }
    $connectTask.GetAwaiter().GetResult()

    $request = [ordered]@{
      id = 1
      method = $Method
    }
    if ($null -ne $Parameters) {
      $request['params'] = $Parameters
    }
    $request = $request | ConvertTo-Json -Compress -Depth 20
    $requestBytes = [Text.Encoding]::UTF8.GetBytes($request)
    $sendSegment = New-Object 'ArraySegment[byte]' -ArgumentList (, $requestBytes)
    $sendTask = $socket.SendAsync($sendSegment, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancellation.Token)
    while (-not $sendTask.IsCompleted) {
      [Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 25
    }
    $sendTask.GetAwaiter().GetResult()

    $buffer = New-Object byte[] 65536
    while ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
      $messageStream = New-Object IO.MemoryStream
      try {
        do {
          $receiveSegment = New-Object 'ArraySegment[byte]' -ArgumentList (, $buffer)
          $receiveTask = $socket.ReceiveAsync($receiveSegment, $cancellation.Token)
          while (-not $receiveTask.IsCompleted) {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 25
          }
          $receiveResult = $receiveTask.GetAwaiter().GetResult()
          if ($receiveResult.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
            throw '本机离线存储通道提前关闭。'
          }
          $messageStream.Write($buffer, 0, $receiveResult.Count)
        } while (-not $receiveResult.EndOfMessage)

        $messageText = [Text.Encoding]::UTF8.GetString($messageStream.ToArray())
        $message = $messageText | ConvertFrom-Json
        if ($null -ne $message.PSObject.Properties['id'] -and [int]$message.id -eq 1) {
          if ($null -ne $message.PSObject.Properties['error']) {
            throw ('本机离线存储命令失败：' + ($message.error | ConvertTo-Json -Compress))
          }
          return $message.result
        }
      } finally {
        $messageStream.Dispose()
      }
    }
  } finally {
    try {
      if ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
        $closeTask = $socket.CloseAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', [Threading.CancellationToken]::None)
        while (-not $closeTask.IsCompleted) {
          Start-Sleep -Milliseconds 20
        }
      }
    } catch {
    }
    $socket.Dispose()
    $cancellation.Dispose()
  }

  throw '没有收到本机离线存储通道的确认结果。'
}

function Get-CodexChromiumUserDataRoot {
  $package = Get-CodexPackage
  if ($null -eq $package) {
    throw '没有找到已安装的官方 Codex 客户端。'
  }

  $localAppDataPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
  $packageRoot = Join-Path (Join-Path $localAppDataPath 'Packages') $package.PackageFamilyName
  return (Join-Path $packageRoot 'LocalCache\Roaming\Codex\web\Codex')
}

function Get-LocalChromiumExecutablePath {
  $candidates = New-Object Collections.Generic.List[string]
  foreach ($registryPath in @(
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
    'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
  )) {
    try {
      $registryValue = [string](Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop).'(default)'
      if (-not [string]::IsNullOrWhiteSpace($registryValue)) {
        [void]$candidates.Add($registryValue)
      }
    } catch {
    }
  }

  foreach ($root in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$root)) {
      [void]$candidates.Add((Join-Path $root 'Microsoft\Edge\Application\msedge.exe'))
      [void]$candidates.Add((Join-Path $root 'Google\Chrome\Application\chrome.exe'))
    }
  }

  try {
    $edgeCommand = Get-Command msedge.exe -ErrorAction Stop
    [void]$candidates.Add([string]$edgeCommand.Source)
  } catch {
  }

  $seen = New-Object Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
  foreach ($candidate in $candidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and $seen.Add($candidate) -and (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }

  throw '没有找到 Windows 自带的 Microsoft Edge Chromium，无法执行离线中文存储写入。'
}

function ConvertTo-StatsigDjb2Hash {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

  [uint64]$hash = 0
  foreach ($character in $Value.ToCharArray()) {
    $hash = (($hash * 31) + [int][char]$character) -band [uint64]4294967295
  }
  return ([uint32]$hash).ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Get-StatsigEvaluationCacheKey {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$UserId,
    [Parameter(Mandatory = $true)][Collections.IDictionary]$CustomIds
  )

  [string[]]$names = @($CustomIds.Keys | ForEach-Object { [string]$_ })
  [Array]::Sort($names, [StringComparer]::Ordinal)
  $customIdParts = New-Object Collections.Generic.List[string]
  foreach ($name in $names) {
    [void]$customIdParts.Add($name + '-' + [string]$CustomIds[$name])
  }
  $hashInput = 'uid:' + $UserId + '|cids:' + ($customIdParts -join ',') + '|k:' + $script:Installer.StatsigClientKey
  return ('statsig.cached.evaluations.' + (ConvertTo-StatsigDjb2Hash -Value $hashInput))
}

function Get-CodexDomStorageEntries {
  param([Parameter(Mandatory = $true)][string]$WebSocketUrl)

  $storageId = [ordered]@{ securityOrigin = 'app://-'; isLocalStorage = $true }
  $result = Invoke-CodexDevToolsCommand -WebSocketUrl $WebSocketUrl -Method 'DOMStorage.getDOMStorageItems' -Parameters ([ordered]@{ storageId = $storageId })
  $entries = @{}
  foreach ($entry in @($result.entries)) {
    if ($null -ne $entry -and $entry.Count -ge 2) {
      $entries[[string]$entry[0]] = [string]$entry[1]
    }
  }
  return $entries
}

function Set-CodexDomStorageItem {
  param(
    [Parameter(Mandatory = $true)][string]$WebSocketUrl,
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
  )

  $parameters = [ordered]@{
    storageId = [ordered]@{ securityOrigin = 'app://-'; isLocalStorage = $true }
    key = $Key
    value = $Value
  }
  [void](Invoke-CodexDevToolsCommand -WebSocketUrl $WebSocketUrl -Method 'DOMStorage.setDOMStorageItem' -Parameters $parameters)
}

function Get-CodexLevelDbWriterPath {
  $architecture = [string]$env:PROCESSOR_ARCHITECTURE
  if (-not [string]::IsNullOrWhiteSpace([string]$env:PROCESSOR_ARCHITEW6432)) {
    $architecture = [string]$env:PROCESSOR_ARCHITEW6432
  }

  if ($architecture -ieq 'ARM64') {
    $fileName = 'codex-leveldb-writer-arm64.exe'
    $expectedHash = $script:Installer.LevelDbWriterArm64Sha256
  } else {
    $fileName = 'codex-leveldb-writer-x64.exe'
    $expectedHash = $script:Installer.LevelDbWriterX64Sha256
  }

  $writerPath = Join-Path (Join-Path $script:InstallerSourceRoot 'tools') $fileName
  if (-not (Test-Path -LiteralPath $writerPath)) {
    throw ('离线中文数据库工具缺失：' + $fileName + '。请完整解压安装包后重试。')
  }
  $actualHash = (Get-FileHash -LiteralPath $writerPath -Algorithm SHA256).Hash
  if ($actualHash -ne $expectedHash) {
    throw ('离线中文数据库工具完整性校验失败：' + $fileName)
  }
  return $writerPath
}

function Invoke-CodexLevelDbWriter {
  param(
    [Parameter(Mandatory = $true)][string]$WriterPath,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $output = @(& $WriterPath @Arguments 2>&1)
  $exitCode = $LASTEXITCODE
  $outputText = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
  if ($exitCode -ne 0) {
    if ([string]::IsNullOrWhiteSpace($outputText)) {
      $outputText = '数据库工具没有返回错误详情。'
    }
    throw ('离线中文数据库写入失败：' + $outputText)
  }
  try {
    return ($outputText | ConvertFrom-Json)
  } catch {
    throw ('离线中文数据库工具返回了无法识别的结果：' + $outputText)
  }
}

function Get-CodexLevelDbItem {
  param(
    [Parameter(Mandatory = $true)][string]$WriterPath,
    [Parameter(Mandatory = $true)][string]$DatabasePath,
    [Parameter(Mandatory = $true)][string]$Key
  )

  return (Invoke-CodexLevelDbWriter -WriterPath $WriterPath -Arguments @('-db', $DatabasePath, '-origin', 'app://-', '-get-key', $Key))
}

function Select-CodexLevelDbPath {
  param([Parameter(Mandatory = $true)][string]$WriterPath)

  $directories = @(Get-CodexI18nLevelDbDirectories | Where-Object { Test-Path -LiteralPath $_ })
  if ($directories.Count -eq 0) {
    return $null
  }

  $stableStorageKey = 'statsig.stable_id.' + (ConvertTo-StatsigDjb2Hash -Value ('k:' + $script:Installer.StatsigClientKey))
  foreach ($key in @($stableStorageKey, 'statsig.last_modified_time.evaluations')) {
    foreach ($directory in $directories) {
      try {
        $receipt = Get-CodexLevelDbItem -WriterPath $WriterPath -DatabasePath $directory -Key $key
        if ($null -ne $receipt.PSObject.Properties['found'] -and [bool]$receipt.found) {
          return $directory
        }
      } catch {
      }
    }
  }

  $preferred = @($directories | Where-Object {
    $_ -like '*\Default\Local Storage\leveldb' -and $_ -notlike '*\Partitions\*'
  }) | Select-Object -First 1
  if ($null -eq $preferred) {
    $preferred = @($directories | Where-Object {
      $_ -like '*\codex-browser-app\Local Storage\leveldb' -and $_ -notlike '*\Partitions\*'
    }) | Select-Object -First 1
  }
  if ($null -ne $preferred) {
    return [string]$preferred
  }
  return [string]$directories[0]
}

function Initialize-CodexOfflineI18nCacheLegacy {
  $port = Get-AvailableLoopbackPort
  $arguments = @(
    ('--remote-debugging-address=127.0.0.1'),
    ('--remote-debugging-port=' + $port),
    ('--remote-allow-origins=http://127.0.0.1:' + $port),
    '--no-first-run'
  )
  $argumentLine = $arguments -join ' '

  Stop-CodexApplication
  $bootstrapProcessId = 0
  try {
    $bootstrapProcessId = Start-CodexPackagedApplication -Arguments $argumentLine
    $target = Wait-CodexDevToolsTarget -Port $port
    if ($null -eq $target) {
      throw '官方客户端没有开放临时的本机离线配置通道。'
    }

    $expression = @'
(() => {
  try {
    const sdkKey = '__STATSIG_CLIENT_KEY__';
    const djb2 = (value) => {
      let hash = 0;
      for (let index = 0; index < value.length; index += 1) {
        hash = ((hash << 5) - hash + value.charCodeAt(index)) | 0;
      }
      return String(hash >>> 0);
    };
    const makeUuid = () => {
      if (globalThis.crypto && typeof globalThis.crypto.randomUUID === 'function') {
        return globalThis.crypto.randomUUID();
      }
      return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (character) => {
        const random = Math.floor(Math.random() * 16);
        const value = character === 'x' ? random : ((random & 3) | 8);
        return value.toString(16);
      });
    };
    const sdkStorageHash = djb2(`k:${sdkKey}`);
    const stableStorageKey = `statsig.stable_id.${sdkStorageHash}`;
    let stableId = null;
    try {
      stableId = JSON.parse(localStorage.getItem(stableStorageKey) || 'null');
    } catch (_) {
      stableId = null;
    }
    if (typeof stableId !== 'string' || stableId.length < 20) {
      stableId = makeUuid();
    }
    localStorage.setItem(stableStorageKey, JSON.stringify(stableId));

    const now = Date.now();
    const payload = JSON.stringify({
      feature_gates: {},
      dynamic_configs: {
        '118392242': {
          name: '118392242',
          rule_id: 'offline_i18n',
          secondary_exposures: [],
          version: 18,
          id_type: 'userID',
          value: { enable_i18n: true, locale_source: 'IDE' },
          is_device_based: false,
          is_in_layer: true,
          explicit_parameters: ['enable_i18n', 'locale_source'],
          is_experiment_active: false,
          is_user_in_experiment: false
        }
      },
      layer_configs: {
        '72216192': {
          name: '72216192',
          rule_id: 'offline_i18n',
          secondary_exposures: [],
          version: 11,
          value: { enable_i18n: true, locale_source: 'IDE' },
          id_type: 'userID',
          is_device_based: false,
          explicit_parameters: [],
          undelegated_secondary_exposures: []
        }
      },
      param_stores: {},
      time: now,
      has_updates: true,
      sdkParams: {},
      hash_used: 'djb2'
    });
    const wrapper = JSON.stringify({
      source: 'Network',
      data: payload,
      receivedAt: now,
      stableID: stableId
    });
    const cacheKey = (userId, customIds) => {
      const entries = Object.keys(customIds)
        .sort((left, right) => left.localeCompare(right))
        .map((name) => `${name}-${customIds[name]}`)
        .join(',');
      const hash = djb2(`uid:${userId}|cids:${entries}|k:${sdkKey}`);
      return `statsig.cached.evaluations.${hash}`;
    };
    const bothIds = { stableID: stableId, source_surface_stable_id: stableId };
    const cacheKeys = Array.from(new Set([
      cacheKey('', bothIds),
      cacheKey('', { stableID: stableId }),
      cacheKey('', {}),
      cacheKey(`ua-${stableId}`, bothIds),
      cacheKey(stableId, bothIds)
    ]));
    let modified = {};
    try {
      modified = JSON.parse(localStorage.getItem('statsig.last_modified_time.evaluations') || '{}');
    } catch (_) {
      modified = {};
    }
    for (const key of cacheKeys) {
      localStorage.setItem(key, wrapper);
      modified[key] = now;
    }
    localStorage.setItem('statsig.last_modified_time.evaluations', JSON.stringify(modified));
    const verified = cacheKeys.every((key) => {
      const value = localStorage.getItem(key) || '';
      return value.includes('enable_i18n') && value.includes('locale_source');
    });
    return { success: verified, cacheCount: cacheKeys.length };
  } catch (error) {
    return { success: false, error: String(error && error.message ? error.message : error) };
  }
})()
'@
    $expression = $expression.Replace('__STATSIG_CLIENT_KEY__', $script:Installer.StatsigClientKey)
    $result = Invoke-CodexDevToolsExpression -WebSocketUrl ([string]$target.webSocketDebuggerUrl) -Expression $expression
    if ($null -eq $result -or -not [bool]$result.success) {
      $reason = if ($null -ne $result -and $null -ne $result.PSObject.Properties['error']) { [string]$result.error } else { '本地缓存写入后未通过校验。' }
      throw $reason
    }

    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 900
    return $true
  } finally {
    Stop-CodexApplication
    if ($bootstrapProcessId -gt 0 -and $null -ne (Get-Process -Id $bootstrapProcessId -ErrorAction SilentlyContinue)) {
      try { Stop-Process -Id $bootstrapProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
  }
}

function Initialize-CodexOfflineI18nCacheViaChromiumLegacy {
  Stop-CodexApplication
  $userDataRoot = Get-CodexChromiumUserDataRoot
  $defaultProfilePath = Join-Path $userDataRoot 'Default'
  $profileProcessId = 0

  if (-not (Test-Path -LiteralPath $defaultProfilePath)) {
    try {
      $profileProcessId = Start-CodexPackagedApplication -Arguments ''
      for ($index = 0; $index -lt 40; $index++) {
        if (Test-Path -LiteralPath $defaultProfilePath) {
          break
        }
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 250
      }
    } finally {
      Stop-CodexApplication
      if ($profileProcessId -gt 0 -and $null -ne (Get-Process -Id $profileProcessId -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $profileProcessId -Force -ErrorAction SilentlyContinue } catch {}
      }
    }
  }

  if (-not (Test-Path -LiteralPath $defaultProfilePath)) {
    [void](New-Item -ItemType Directory -Path $defaultProfilePath -Force)
  }

  $port = Get-AvailableLoopbackPort
  $chromiumPath = Get-LocalChromiumExecutablePath
  $arguments = @(
    '--headless',
    '--disable-gpu',
    '--disable-background-networking',
    '--disable-sync',
    '--no-first-run',
    '--no-default-browser-check',
    '--no-proxy-server',
    '--remote-debugging-address=127.0.0.1',
    ('--remote-debugging-port=' + $port),
    ('--remote-allow-origins=http://127.0.0.1:' + $port),
    ('--user-data-dir="' + $userDataRoot + '"'),
    '--profile-directory=Default',
    'about:blank'
  )

  $chromiumProcess = $null
  try {
    $chromiumProcess = Start-Process -FilePath $chromiumPath -ArgumentList $arguments -WindowStyle Hidden -PassThru -ErrorAction Stop
    $target = Wait-CodexDevToolsTarget -Port $port
    if ($null -eq $target) {
      throw 'Windows 本机离线存储引擎没有成功启动。'
    }

    $webSocketUrl = [string]$target.webSocketDebuggerUrl
    $entries = Get-CodexDomStorageEntries -WebSocketUrl $webSocketUrl
    $stableStorageKey = 'statsig.stable_id.' + (ConvertTo-StatsigDjb2Hash -Value ('k:' + $script:Installer.StatsigClientKey))
    $stableId = $null
    if ($entries.ContainsKey($stableStorageKey)) {
      try {
        $stableId = $entries[$stableStorageKey] | ConvertFrom-Json
      } catch {
        $stableId = $null
      }
    }
    if ($stableId -isnot [string] -or ([string]$stableId).Length -lt 20) {
      $stableId = [Guid]::NewGuid().ToString()
    }
    Set-CodexDomStorageItem -WebSocketUrl $webSocketUrl -Key $stableStorageKey -Value ($stableId | ConvertTo-Json -Compress)

    $now = [int64]([DateTime]::UtcNow - [DateTime]'1970-01-01T00:00:00Z').TotalMilliseconds
    $payloadObject = [ordered]@{
      feature_gates = [ordered]@{}
      dynamic_configs = [ordered]@{
        '118392242' = [ordered]@{
          name = '118392242'; rule_id = 'offline_i18n'; secondary_exposures = @(); version = 18; id_type = 'userID'
          value = [ordered]@{ enable_i18n = $true; locale_source = 'IDE' }
          is_device_based = $false; is_in_layer = $true; explicit_parameters = @('enable_i18n', 'locale_source')
          is_experiment_active = $false; is_user_in_experiment = $false
        }
      }
      layer_configs = [ordered]@{
        '72216192' = [ordered]@{
          name = '72216192'; rule_id = 'offline_i18n'; secondary_exposures = @(); version = 11
          value = [ordered]@{ enable_i18n = $true; locale_source = 'IDE' }
          id_type = 'userID'; is_device_based = $false; explicit_parameters = @(); undelegated_secondary_exposures = @()
        }
      }
      param_stores = [ordered]@{}
      time = $now
      has_updates = $true
      sdkParams = [ordered]@{}
      hash_used = 'djb2'
    }
    $payload = $payloadObject | ConvertTo-Json -Compress -Depth 20
    $wrapper = [ordered]@{ source = 'Network'; data = $payload; receivedAt = $now; stableID = $stableId } | ConvertTo-Json -Compress -Depth 20

    $bothIds = [ordered]@{ stableID = $stableId; source_surface_stable_id = $stableId }
    $candidateKeys = @(
      (Get-StatsigEvaluationCacheKey -UserId '' -CustomIds $bothIds),
      (Get-StatsigEvaluationCacheKey -UserId '' -CustomIds ([ordered]@{ stableID = $stableId })),
      (Get-StatsigEvaluationCacheKey -UserId '' -CustomIds ([ordered]@{})),
      (Get-StatsigEvaluationCacheKey -UserId ('ua-' + $stableId) -CustomIds $bothIds),
      (Get-StatsigEvaluationCacheKey -UserId $stableId -CustomIds $bothIds)
    )
    $cacheKeys = New-Object Collections.Generic.List[string]
    $seenKeys = New-Object Collections.Generic.HashSet[string]([StringComparer]::Ordinal)
    foreach ($candidateKey in $candidateKeys) {
      if ($seenKeys.Add($candidateKey)) {
        [void]$cacheKeys.Add($candidateKey)
      }
    }

    $lastModified = [ordered]@{}
    if ($entries.ContainsKey('statsig.last_modified_time.evaluations')) {
      try {
        $existingModified = $entries['statsig.last_modified_time.evaluations'] | ConvertFrom-Json
        foreach ($property in $existingModified.PSObject.Properties) {
          $lastModified[$property.Name] = $property.Value
        }
      } catch {
      }
    }
    foreach ($cacheKey in $cacheKeys) {
      Set-CodexDomStorageItem -WebSocketUrl $webSocketUrl -Key $cacheKey -Value $wrapper
      $lastModified[$cacheKey] = $now
    }
    Set-CodexDomStorageItem -WebSocketUrl $webSocketUrl -Key 'statsig.last_modified_time.evaluations' -Value ($lastModified | ConvertTo-Json -Compress -Depth 8)

    $verifiedEntries = Get-CodexDomStorageEntries -WebSocketUrl $webSocketUrl
    foreach ($cacheKey in $cacheKeys) {
      if (-not $verifiedEntries.ContainsKey($cacheKey) -or $verifiedEntries[$cacheKey] -notmatch 'enable_i18n' -or $verifiedEntries[$cacheKey] -notmatch 'locale_source') {
        throw '离线中文缓存写入后未通过校验。'
      }
    }

    return $true
  } finally {
    try {
      $browserTarget = Get-LoopbackJson -Url ('http://127.0.0.1:' + $port + '/json/version')
      if ($null -ne $browserTarget -and -not [string]::IsNullOrWhiteSpace([string]$browserTarget.webSocketDebuggerUrl)) {
        [void](Invoke-CodexDevToolsCommand -WebSocketUrl ([string]$browserTarget.webSocketDebuggerUrl) -Method 'Browser.close')
      }
    } catch {
    }
    if ($null -ne $chromiumProcess -and -not $chromiumProcess.HasExited) {
      try { Stop-Process -Id $chromiumProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Milliseconds 500
  }
}

function Initialize-CodexOfflineI18nCache {
  Stop-CodexApplication
  $writerPath = Get-CodexLevelDbWriterPath
  $userDataRoot = Get-CodexChromiumUserDataRoot
  $createDatabases = $false
  $existingDatabasePaths = @(Get-CodexI18nLevelDbDirectories | Where-Object { Test-Path -LiteralPath $_ })

  if ($existingDatabasePaths.Count -eq 0) {
    $createDatabases = $true
    $databasePaths = @(
      (Join-Path $userDataRoot 'Default\Local Storage\leveldb'),
      (Join-Path $userDataRoot 'codex-browser-app\Local Storage\leveldb'),
      (Join-Path $userDataRoot 'Default\Partitions\codex-browser-app\Local Storage\leveldb')
    )
  } else {
    # The packaged app can keep more than one Local Storage profile. Write the
    # same offline evaluation cache to every matching profile so startup cannot
    # select a different English-only database.
    $databasePaths = @($existingDatabasePaths)
  }

  $databasePath = Select-CodexLevelDbPath -WriterPath $writerPath
  if ([string]::IsNullOrWhiteSpace([string]$databasePath)) {
    $databasePath = $databasePaths[0]
  }

  Stop-CodexApplication
  Start-Sleep -Milliseconds 700

  $stableStorageKey = 'statsig.stable_id.' + (ConvertTo-StatsigDjb2Hash -Value ('k:' + $script:Installer.StatsigClientKey))
  $stableId = $null
  try {
    $stableReceipt = Get-CodexLevelDbItem -WriterPath $writerPath -DatabasePath $databasePath -Key $stableStorageKey
    if ($null -ne $stableReceipt.PSObject.Properties['found'] -and [bool]$stableReceipt.found) {
      $stableId = $stableReceipt.value | ConvertFrom-Json
    }
  } catch {
    $stableId = $null
  }
  if ($stableId -isnot [string] -or ([string]$stableId).Length -lt 20) {
    $stableId = [Guid]::NewGuid().ToString()
  }

  $now = [int64]([DateTime]::UtcNow - [DateTime]'1970-01-01T00:00:00Z').TotalMilliseconds
  $payloadObject = [ordered]@{
    feature_gates = [ordered]@{}
    dynamic_configs = [ordered]@{
      '118392242' = [ordered]@{
        name = '118392242'; rule_id = 'offline_i18n'; secondary_exposures = @(); version = 18; id_type = 'userID'
        value = [ordered]@{ enable_i18n = $true; locale_source = 'IDE' }
        is_device_based = $false; is_in_layer = $true; explicit_parameters = @('enable_i18n', 'locale_source')
        is_experiment_active = $false; is_user_in_experiment = $false
      }
    }
    layer_configs = [ordered]@{
      '72216192' = [ordered]@{
        name = '72216192'; rule_id = 'offline_i18n'; secondary_exposures = @(); version = 11
        value = [ordered]@{ enable_i18n = $true; locale_source = 'IDE' }
        id_type = 'userID'; is_device_based = $false; explicit_parameters = @(); undelegated_secondary_exposures = @()
      }
    }
    param_stores = [ordered]@{}
    time = $now
    has_updates = $true
    sdkParams = [ordered]@{}
    hash_used = 'djb2'
  }
  $payload = $payloadObject | ConvertTo-Json -Compress -Depth 20
  $wrapper = [ordered]@{ source = 'Network'; data = $payload; receivedAt = $now; stableID = $stableId } | ConvertTo-Json -Compress -Depth 20

  $bothIds = [ordered]@{ stableID = $stableId; source_surface_stable_id = $stableId }
  $candidateKeys = @(
    (Get-StatsigEvaluationCacheKey -UserId '' -CustomIds $bothIds),
    (Get-StatsigEvaluationCacheKey -UserId '' -CustomIds ([ordered]@{ stableID = $stableId })),
    (Get-StatsigEvaluationCacheKey -UserId '' -CustomIds ([ordered]@{})),
    (Get-StatsigEvaluationCacheKey -UserId ('ua-' + $stableId) -CustomIds $bothIds),
    (Get-StatsigEvaluationCacheKey -UserId $stableId -CustomIds $bothIds)
  )
  $cacheKeys = New-Object Collections.Generic.List[string]
  $seenKeys = New-Object Collections.Generic.HashSet[string]([StringComparer]::Ordinal)
  foreach ($candidateKey in $candidateKeys) {
    if ($seenKeys.Add($candidateKey)) {
      [void]$cacheKeys.Add($candidateKey)
    }
  }

  $lastModified = [ordered]@{}
  try {
    $modifiedReceipt = Get-CodexLevelDbItem -WriterPath $writerPath -DatabasePath $databasePath -Key 'statsig.last_modified_time.evaluations'
    if ($null -ne $modifiedReceipt.PSObject.Properties['found'] -and [bool]$modifiedReceipt.found) {
      $existingModified = $modifiedReceipt.value | ConvertFrom-Json
      foreach ($property in $existingModified.PSObject.Properties) {
        $lastModified[$property.Name] = $property.Value
      }
    }
  } catch {
  }

  $items = [ordered]@{}
  $items[$stableStorageKey] = ($stableId | ConvertTo-Json -Compress)
  foreach ($cacheKey in $cacheKeys) {
    $items[$cacheKey] = $wrapper
    $lastModified[$cacheKey] = $now
  }
  $items['statsig.last_modified_time.evaluations'] = ($lastModified | ConvertTo-Json -Compress -Depth 8)

  $workDirectory = Join-Path ([IO.Path]::GetTempPath()) 'Cloudforl-Codex-Installer'
  if (-not (Test-Path -LiteralPath $workDirectory)) {
    [void](New-Item -ItemType Directory -Path $workDirectory -Force)
  }
  $inputPath = Join-Path $workDirectory ('i18n-leveldb-' + [Guid]::NewGuid().ToString('N') + '.json')
  $inputObject = [ordered]@{ origin = 'app://-'; items = $items }
  $inputJson = $inputObject | ConvertTo-Json -Compress -Depth 30
  [IO.File]::WriteAllText($inputPath, $inputJson, (New-Object Text.UTF8Encoding($false)))

  try {
    foreach ($targetDatabasePath in $databasePaths) {
      $completed = $false
      $lastFailure = $null
      $needsCreate = $createDatabases -or -not (Test-Path -LiteralPath (Join-Path $targetDatabasePath 'CURRENT'))
      if ($needsCreate) {
        $targetParentPath = Split-Path -Parent $targetDatabasePath
        if (-not (Test-Path -LiteralPath $targetParentPath)) {
          [void](New-Item -ItemType Directory -Path $targetParentPath -Force)
        }
      }
      for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
          Stop-CodexApplication
          Start-Sleep -Milliseconds (500 + ($attempt * 350))
          $writerArguments = @('-db', $targetDatabasePath, '-input', $inputPath)
          if ($needsCreate) {
            $writerArguments += '-create'
          }
          $receipt = Invoke-CodexLevelDbWriter -WriterPath $writerPath -Arguments $writerArguments
          if ($null -eq $receipt.PSObject.Properties['success'] -or -not [bool]$receipt.success) {
            throw '数据库工具没有确认写入成功。'
          }
          $completed = $true
          break
        } catch {
          $lastFailure = $_
        }
      }
      if (-not $completed) {
        throw $lastFailure
      }

      $verification = Get-CodexLevelDbItem -WriterPath $writerPath -DatabasePath $targetDatabasePath -Key $cacheKeys[0]
      if ($null -eq $verification.PSObject.Properties['found'] -or -not [bool]$verification.found -or
          [string]$verification.value -notmatch 'enable_i18n' -or
          [string]$verification.value -notmatch 'locale_source') {
        throw ('离线中文缓存写入后未通过校验：' + $targetDatabasePath)
      }
    }
    return $true
  } finally {
    if (Test-Path -LiteralPath $inputPath) {
      Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Open-WebPage {
  param([Parameter(Mandatory = $true)][string]$Url)

  try {
    Start-Process $Url
  } catch {
    [Windows.Forms.MessageBox]::Show('无法打开浏览器，请手动访问：' + "`r`n" + $Url, '无法打开网页', 'OK', 'Warning') | Out-Null
  }
}

function Show-KeyTutorial {
  $text = @"
获取密钥只需要四步：

1. 注册或登录所选接口对应的平台账号。
2. 进入“令牌”页面，点击新建令牌。
3. 复制完整密钥；请勿截图或发给他人。
4. 回到此窗口粘贴密钥，点击“保存并启动 Codex”。

是否现在打开密钥管理页面？
"@
  $choice = [Windows.Forms.MessageBox]::Show($text, '获取密钥教程', 'YesNo', 'Information')
  if ($choice -eq [Windows.Forms.DialogResult]::Yes) {
    Open-WebPage -Url $script:Installer.TokenUrl
  }
}

function Stop-CodexApplication {
  if ($SkipAppInstall) {
    return
  }

  $package = Get-CodexPackage
  if ($null -eq $package) {
    return
  }

  $processNames = New-Object Collections.Generic.List[string]
  [void]$processNames.Add('ChatGPT')
  [void]$processNames.Add('Codex')
  try {
    $manifest = Get-AppxPackageManifest -Package $package.PackageFullName
    $application = @($manifest.Package.Applications.Application) | Select-Object -First 1
    if ($null -ne $application -and -not [string]::IsNullOrWhiteSpace([string]$application.Executable)) {
      $manifestProcessName = [IO.Path]::GetFileNameWithoutExtension([string]$application.Executable)
      if (-not [string]::IsNullOrWhiteSpace($manifestProcessName) -and -not $processNames.Contains($manifestProcessName)) {
        [void]$processNames.Add($manifestProcessName)
      }
    }
  } catch {
  }

  $targetProcesses = New-Object Collections.Generic.List[object]
  $targetProcessIds = New-Object Collections.Generic.HashSet[int]
  $installLocation = [string]$package.InstallLocation
  foreach ($processName in $processNames) {
    foreach ($runningProcess in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
      $isTargetProcess = ($processName -ieq 'ChatGPT')
      if (-not $isTargetProcess -and -not [string]::IsNullOrWhiteSpace($installLocation)) {
        try {
          $processPath = [string]$runningProcess.Path
          $isTargetProcess = (
            -not [string]::IsNullOrWhiteSpace($processPath) -and
            $processPath.StartsWith($installLocation, [StringComparison]::OrdinalIgnoreCase)
          )
        } catch {
        }
      }
      if (-not $isTargetProcess) {
        try {
          $isTargetProcess = ($runningProcess.MainWindowHandle -ne [IntPtr]::Zero)
        } catch {
        }
      }

      if ($isTargetProcess -and $targetProcessIds.Add([int]$runningProcess.Id)) {
        [void]$targetProcesses.Add($runningProcess)
      }
    }
  }

  foreach ($runningProcess in $targetProcesses) {
    try {
      [void]$runningProcess.CloseMainWindow()
    } catch {
    }
  }

  for ($index = 0; $index -lt 20; $index++) {
    $remaining = @($targetProcessIds | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
    if ($remaining.Count -eq 0) {
      return
    }
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 250
  }

  foreach ($processId in $targetProcessIds) {
    try {
      Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    } catch {
    }
  }
}

function Start-CodexApplication {
  if ($SkipAppInstall) {
    return $true
  }

  $package = Get-CodexPackage
  if ($null -eq $package) {
    return $false
  }

  $applicationId = 'App'
  $processNames = New-Object Collections.Generic.List[string]
  [void]$processNames.Add('ChatGPT')
  [void]$processNames.Add('Codex')

  try {
    $manifest = Get-AppxPackageManifest -Package $package.PackageFullName
    $application = @($manifest.Package.Applications.Application) | Select-Object -First 1
    if ($null -ne $application -and -not [string]::IsNullOrWhiteSpace([string]$application.Id)) {
      $applicationId = [string]$application.Id
    }
    if ($null -ne $application -and -not [string]::IsNullOrWhiteSpace([string]$application.Executable)) {
      $manifestProcessName = [IO.Path]::GetFileNameWithoutExtension([string]$application.Executable)
      if (-not [string]::IsNullOrWhiteSpace($manifestProcessName) -and -not $processNames.Contains($manifestProcessName)) {
        [void]$processNames.Add($manifestProcessName)
      }
    }
  } catch {
  }

  $aumid = $package.PackageFamilyName + '!' + $applicationId
  try {
    $registeredApp = Get-StartApps | Where-Object { $_.AppID -like ($package.PackageFamilyName + '!*') } | Select-Object -First 1
    if ($null -ne $registeredApp -and -not [string]::IsNullOrWhiteSpace([string]$registeredApp.AppID)) {
      $aumid = [string]$registeredApp.AppID
    }
  } catch {
  }

  $launchTarget = 'shell:AppsFolder\' + $aumid

  # A running Electron process keeps the language resources that were loaded
  # at startup. An overwrite install must therefore close the old packaged app
  # before launching it again, otherwise the existing English process can be
  # mistaken for a successful new launch.
  $targetProcesses = New-Object Collections.Generic.List[object]
  $targetProcessIds = New-Object Collections.Generic.HashSet[int]
  $installLocation = [string]$package.InstallLocation

  foreach ($processName in $processNames) {
    $runningProcesses = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
    foreach ($runningProcess in $runningProcesses) {
      $isTargetProcess = ($processName -ieq 'ChatGPT')
      if (-not $isTargetProcess -and -not [string]::IsNullOrWhiteSpace($installLocation)) {
        try {
          $processPath = [string]$runningProcess.Path
          $isTargetProcess = (
            -not [string]::IsNullOrWhiteSpace($processPath) -and
            $processPath.StartsWith($installLocation, [StringComparison]::OrdinalIgnoreCase)
          )
        } catch {
        }
      }
      if (-not $isTargetProcess) {
        try {
          $isTargetProcess = ($runningProcess.MainWindowHandle -ne [IntPtr]::Zero)
        } catch {
        }
      }

      if ($isTargetProcess -and $targetProcessIds.Add([int]$runningProcess.Id)) {
        [void]$targetProcesses.Add($runningProcess)
      }
    }
  }

  if ($targetProcesses.Count -gt 0) {
    foreach ($runningProcess in $targetProcesses) {
      try {
        [void]$runningProcess.CloseMainWindow()
      } catch {
      }
    }

    for ($index = 0; $index -lt 24; $index++) {
      $remainingCount = 0
      foreach ($processId in $targetProcessIds) {
        if ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
          $remainingCount++
        }
      }
      if ($remainingCount -eq 0) {
        break
      }
      [Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 250
    }

    foreach ($processId in $targetProcessIds) {
      if ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
      }
    }

    for ($index = 0; $index -lt 20; $index++) {
      $remainingCount = 0
      foreach ($processId in $targetProcessIds) {
        if ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
          $remainingCount++
        }
      }
      if ($remainingCount -eq 0) {
        break
      }
      [Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 250
    }

    foreach ($processId in $targetProcessIds) {
      if ($null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
        return $false
      }
    }
  }

  $attempts = @(
    {
      Start-Process -FilePath $launchTarget -ErrorAction Stop | Out-Null
    },
    {
      Start-Process -FilePath 'explorer.exe' -ArgumentList $launchTarget -ErrorAction Stop | Out-Null
    },
    {
      $shellApplication = New-Object -ComObject Shell.Application
      $appsFolder = $shellApplication.Namespace('shell:AppsFolder')
      $appItem = $appsFolder.ParseName($aumid)
      if ($null -eq $appItem) {
        throw 'Windows AppsFolder could not resolve the installed app identity.'
      }
      $appItem.InvokeVerb('open')
    }
  )

  foreach ($attempt in $attempts) {
    try {
      & $attempt
      for ($index = 0; $index -lt 40; $index++) {
        foreach ($processName in $processNames) {
          if ($null -ne (Get-Process -Name $processName -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            return $true
          }
        }
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 250
      }
    } catch {
    }
  }

  return $false
}

function Assert-CodexFullAccessAllowed {
  param([Parameter(Mandatory = $true)][string]$RequirementsPath)

  if (-not (Test-Path -LiteralPath $RequirementsPath)) {
    return
  }

  $requirements = [IO.File]::ReadAllText($RequirementsPath, [Text.Encoding]::UTF8)
  $hasAllowedProfiles = $requirements -match '(?im)^\s*\[allowed_permission_profiles\]\s*$'
  $fullAccessAllowed = $requirements -match '(?im)^\s*["'']?:danger-full-access["'']?\s*=\s*true\s*$'
  $hasRestrictedSandboxList = $requirements -match '(?im)^\s*allowed_sandbox_modes\s*='
  $sandboxAllowsFullAccess = $requirements -match '(?i)danger-full-access'
  if (($hasAllowedProfiles -and -not $fullAccessAllowed) -or ($hasRestrictedSandboxList -and -not $sandboxAllowsFullAccess)) {
    throw ('Codex 的 requirements.toml 禁止 :danger-full-access，安装器不会绕过该管理限制：' + $RequirementsPath)
  }
}

function Ensure-CodexSimplifiedChinese {
  Set-UiStatus -Text '正在使用离线方式写入简体中文偏好和功能开关，不需要系统代理…' -Progress 94
  try {
    $paths = Get-CodexPaths
    Assert-CodexFullAccessAllowed -RequirementsPath $paths.RequirementsPath
    Stop-CodexApplication
    $statePaths = @($paths.DesktopStatePaths)
    if ($statePaths.Count -eq 0) {
      $statePaths = @($paths.DesktopStatePath)
    }
    [void](Set-CodexDesktopLocale -StatePath $paths.DesktopStatePath)
    foreach ($statePath in $statePaths) {
      if ([string]$statePath -ieq [string]$paths.DesktopStatePath) {
        continue
      }
      try {
        [void](Set-CodexDesktopLocale -StatePath ([string]$statePath))
      } catch {
        # A stale or read-only alternate cache must not hide a verified primary
        # state, but an existing alternate file is still reported to the user.
        if (Test-Path -LiteralPath ([string]$statePath)) {
          throw ('备用 Codex 桌面状态写入失败：' + [string]$statePath + '；' + $_.Exception.Message)
        }
      }
    }
    if (-not (Initialize-CodexOfflineI18nCache)) {
      return $false
    }
  Set-UiStatus -Text '离线中文偏好和功能开关已写入，正在准备正常启动…' -Progress 95
    return $true
  } catch {
    [Windows.Forms.MessageBox]::Show(
      ("离线中文配置没有完成：`r`n`r`n" + $_.Exception.Message + "`r`n`r`n官方客户端版本可能已改变本地存储方式，请把此提示截图发给安装包维护人员。"),
      '离线中文配置失败',
      'OK',
      'Error'
    ) | Out-Null
    return $false
  }
}

function Invoke-SelfTest {
  $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Cloudforl-Codex-SelfTest-' + [Guid]::NewGuid().ToString('N'))
  [void](New-Item -ItemType Directory -Path $testRoot)
  $configPath = Join-Path $testRoot 'config.toml'
  $desktopStatePath = Join-Path $testRoot '.codex-global-state.json'
  $helperPath = Join-Path $testRoot '带 空格\get-key.ps1'

  try {
    Set-ProviderSelection -Id 'cloudforl'
    $sample = @'
model = "old-model"
model_provider = "old-provider"
default_permissions = ":read-only"
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[projects.'C:\工作区\示例']
trust_level = "trusted"

[model_providers.cloudforl]
base_url = "https://old.invalid/v1"

[mcp_servers.example]
url = "https://example.invalid/mcp"

[desktop]
appearanceTheme = "system"
localeOverride = "en-US"
'@
    Write-AtomicUtf8File -Path $configPath -Content ($sample.Trim() + "`r`n")
    Install-KeyHelper -Path $helperPath
    [void](Set-CodexConfiguration -ConfigPath $configPath -KeyHelperPath $helperPath -Model $script:Installer.DefaultModel)
    [void](Set-CodexConfiguration -ConfigPath $configPath -KeyHelperPath $helperPath -Model $script:Installer.DefaultModel)

    $result = [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8)
    if ($result -notmatch 'model_provider\s*=\s*"cloudforl"') { throw 'Self-test failed: model provider was not set.' }
    if ($result -notmatch '(?m)^default_permissions\s*=\s*":danger-full-access"\s*$') { throw 'Self-test failed: the built-in full-access permission profile was not selected.' }
    if (([regex]::Matches($result, '(?m)^default_permissions\s*=')).Count -ne 1) { throw 'Self-test failed: default permissions are not idempotent.' }
    if ($result -match '(?m)^approval_policy\s*=') { throw 'Self-test failed: approval policy must be controlled by the desktop full-access preset.' }
    if ($result -match '(?m)^sandbox_mode\s*=') { throw 'Self-test failed: sandbox mode must be controlled by the desktop full-access preset.' }
    if ($result -notmatch [regex]::Escape("[projects.'C:\工作区\示例']")) { throw 'Self-test failed: unrelated Unicode TOML content was not preserved.' }
    if ($result -notmatch '\[mcp_servers\.example\]') { throw 'Self-test failed: unrelated MCP configuration was not preserved.' }
    if ($result -notmatch '(?m)^localeOverride\s*=\s*"zh-CN"\s*$') { throw 'Self-test failed: Simplified Chinese was not selected.' }
    if ($result -notmatch '(?m)^appearanceTheme\s*=\s*"system"\s*$') { throw 'Self-test failed: unrelated desktop settings were not preserved.' }
    if (([regex]::Matches($result, '\[desktop\]')).Count -ne 1) { throw 'Self-test failed: desktop configuration is not idempotent.' }
    if (([regex]::Matches($result, '(?m)^localeOverride\s*=')).Count -ne 1) { throw 'Self-test failed: locale override is not idempotent.' }
    if (([regex]::Matches($result, '\[model_providers\.cloudforl\]')).Count -ne 1) { throw 'Self-test failed: provider configuration is not idempotent.' }
    if (([regex]::Matches($result, '\[model_providers\.cloudforl\.auth\]')).Count -ne 1) { throw 'Self-test failed: auth configuration is not idempotent.' }
    $helperResult = [IO.File]::ReadAllText($helperPath, [Text.Encoding]::UTF8)
    if ($helperResult -notmatch 'ProtectedData.*Unprotect') { throw 'Self-test failed: DPAPI helper is missing.' }
    if ($script:Installer.BaseUrl -ne 'https://cloudforl.com/v1') { throw 'Self-test failed: unexpected API base URL.' }
    if ($script:Installer.StoreProductId -ne '9PLM9XGG6VKS') { throw 'Self-test failed: unexpected Store product ID.' }

    foreach ($choice in $script:ProviderChoices) {
      Set-ProviderSelection -Id $choice.Id
      [void](Set-CodexConfiguration -ConfigPath $configPath -KeyHelperPath $helperPath -Model $script:Installer.DefaultModel)
      [void](Set-CodexConfiguration -ConfigPath $configPath -KeyHelperPath $helperPath -Model $script:Installer.DefaultModel)
      $switchedConfig = [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8)
      if ($script:Installer.BaseUrl -cne $choice.BaseUrl -or
          $script:Installer.ModelsUrl -cne ($choice.BaseUrl + '/models') -or
          $script:Installer.CredentialDirectoryName -cne $choice.CredentialDirectoryName) {
        throw ('Self-test failed: provider selection mismatch for ' + $choice.Id)
      }
      if ($switchedConfig -notmatch ('(?m)^model_provider\s*=\s*"' + [regex]::Escape($choice.Id) + '"\s*$') -or
          $switchedConfig -notmatch [regex]::Escape('base_url = "' + $choice.BaseUrl + '"')) {
        throw ('Self-test failed: provider configuration mismatch for ' + $choice.Id)
      }
      if (([regex]::Matches($switchedConfig, '(?m)^model_provider\s*=')).Count -ne 1 -or
          ([regex]::Matches($switchedConfig, '(?m)^default_permissions\s*=')).Count -ne 1 -or
          ([regex]::Matches($switchedConfig, '(?m)^\[model_providers\.' + [regex]::Escape($choice.Id) + '\]')).Count -ne 1) {
        throw ('Self-test failed: provider switch is not idempotent for ' + $choice.Id)
      }
    }
    try {
      Set-ProviderSelection -Id 'not-a-provider'
      throw 'Self-test failed: unsupported provider was accepted.'
    } catch {
      if ($_.Exception.Message -match 'Self-test failed') { throw }
    }

    Write-AtomicUtf8File -Path $desktopStatePath -Content '{"preserved":{"value":true},"localeOverride":"en-US","electron-persisted-atom-state":{"composer-permission-mode-visibility":{"guardian-approvals":false,"full-access":false}}}'
    [void](Set-CodexDesktopLocale -StatePath $desktopStatePath)
    [void](Set-CodexDesktopLocale -StatePath $desktopStatePath)
    $desktopState = [IO.File]::ReadAllText($desktopStatePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string]$desktopState.desktop.localeOverride -cne 'zh-CN') { throw 'Self-test failed: desktop locale state was not selected.' }
    if ($null -eq $desktopState.PSObject.Properties['preserved'] -or -not [bool]$desktopState.preserved.value) { throw 'Self-test failed: desktop locale state did not preserve unrelated settings.' }
    if ([string]$desktopState.'electron-persisted-atom-state'.'agent-mode-by-host-id'.local -cne 'full-access') { throw 'Self-test failed: desktop full-access preset was not selected.' }
    if ($desktopState.'electron-persisted-atom-state'.'skip-full-access-confirm' -ne $true) { throw 'Self-test failed: desktop full-access confirmation state was not selected.' }
    if ($desktopState.'electron-persisted-atom-state'.'composer-permission-mode-visibility'.'full-access' -ne $true) { throw 'Self-test failed: the full-access menu option remains hidden.' }
    if ($desktopState.'electron-persisted-atom-state'.'composer-permission-mode-visibility'.'guardian-approvals' -ne $false) { throw 'Self-test failed: unrelated permission visibility was not preserved.' }
    if ($desktopState.'composer-permission-mode-visibility'.'full-access' -ne $true) { throw 'Self-test failed: top-level full-access visibility compatibility state was not selected.' }

    Write-Output ('SELF_TEST_OK version=' + $script:Installer.Version)
  } finally {
    if ($testRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $testRoot)) {
      Get-ChildItem -LiteralPath $testRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
      }
      Get-ChildItem -LiteralPath $testRoot -Recurse -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
      }
      Remove-Item -LiteralPath $testRoot -Force -ErrorAction SilentlyContinue
    }
  }
}

if ($SelfTest) {
  Invoke-SelfTest
  exit 0
}

# The v0.3 wizard runs after the reusable installation functions above have loaded.
. (Join-Path $script:InstallerSourceRoot 'wizard.ps1')
return

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

function Show-ProviderSelectionDialog {
  $choiceForm = New-Object Windows.Forms.Form
  $choiceForm.Text = '选择 Codex 对接接口'
  $choiceForm.ClientSize = New-Object Drawing.Size(560, 300)
  $choiceForm.StartPosition = 'CenterScreen'
  $choiceForm.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
  $choiceForm.MaximizeBox = $false
  $choiceForm.MinimizeBox = $false
  $choiceForm.TopMost = $true
  $choiceForm.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

  $prompt = New-Object Windows.Forms.Label
  $prompt.Location = New-Object Drawing.Point(24, 20)
  $prompt.Size = New-Object Drawing.Size(510, 42)
  $prompt.Text = '请选择此设备要对接的接口。确认后才会开始安装；最后一步请输入该接口对应的密钥 Key。'
  $choiceForm.Controls.Add($prompt)

  $confirm = New-Object Windows.Forms.Button
  $confirm.Location = New-Object Drawing.Point(340, 248)
  $confirm.Size = New-Object Drawing.Size(94, 32)
  $confirm.Text = '确认并安装'
  $confirm.Enabled = $false
  $confirm.DialogResult = [Windows.Forms.DialogResult]::OK
  $choiceForm.Controls.Add($confirm)

  $cancel = New-Object Windows.Forms.Button
  $cancel.Location = New-Object Drawing.Point(444, 248)
  $cancel.Size = New-Object Drawing.Size(90, 32)
  $cancel.Text = '取消'
  $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
  $choiceForm.Controls.Add($cancel)
  $choiceForm.AcceptButton = $confirm
  $choiceForm.CancelButton = $cancel

  for ($index = 0; $index -lt $script:ProviderChoices.Count; $index++) {
    $choice = $script:ProviderChoices[$index]
    $radio = New-Object Windows.Forms.RadioButton
    $radio.Location = New-Object Drawing.Point(28, (78 + $index * 52))
    $radio.Size = New-Object Drawing.Size(510, 44)
    $radio.Text = ('接口' + @('一', '二', '三')[$index] + '：' + $choice.Host + '    ' + $choice.BaseUrl)
    $radio.Tag = $choice.Id
    $radio.Add_CheckedChanged({
      if ($this.Checked) {
        $choiceForm.Tag = [string]$this.Tag
        $confirm.Enabled = $true
      }
    })
    $choiceForm.Controls.Add($radio)
  }

  try {
    $result = $choiceForm.ShowDialog()
    if ($result -eq [Windows.Forms.DialogResult]::OK) {
      return [string]$choiceForm.Tag
    }
    return $null
  } finally {
    $choiceForm.Dispose()
  }
}

$selectedProviderId = Show-ProviderSelectionDialog
if ([string]::IsNullOrWhiteSpace($selectedProviderId)) {
  exit 0
}
Set-ProviderSelection -Id $selectedProviderId

$script:StatusLabel = $null
$script:ProgressBar = $null
$script:InstallationReady = $false

$form = New-Object Windows.Forms.Form
$form.Text = 'Codex 一键安装'
$form.ClientSize = New-Object Drawing.Size(600, 470)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.BackColor = [Drawing.Color]::FromArgb(247, 249, 252)
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

$headerPanel = New-Object Windows.Forms.Panel
$headerPanel.Location = New-Object Drawing.Point(0, 0)
$headerPanel.Size = New-Object Drawing.Size(600, 104)
$headerPanel.BackColor = [Drawing.Color]::FromArgb(28, 34, 48)
$form.Controls.Add($headerPanel)

$titleLabel = New-Object Windows.Forms.Label
$titleLabel.Location = New-Object Drawing.Point(30, 22)
$titleLabel.Size = New-Object Drawing.Size(530, 36)
$titleLabel.Text = 'Codex 新机一键安装'
$titleLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 19, [Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [Drawing.Color]::White
$headerPanel.Controls.Add($titleLabel)

$subtitleLabel = New-Object Windows.Forms.Label
$subtitleLabel.Location = New-Object Drawing.Point(32, 64)
$subtitleLabel.Size = New-Object Drawing.Size(530, 24)
$subtitleLabel.Text = '自动安装官方客户端、激活简体中文并连接 ' + $script:Installer.ProviderName
$subtitleLabel.ForeColor = [Drawing.Color]::FromArgb(190, 199, 215)
$headerPanel.Controls.Add($subtitleLabel)

$contentPanel = New-Object Windows.Forms.Panel
$contentPanel.Location = New-Object Drawing.Point(28, 124)
$contentPanel.Size = New-Object Drawing.Size(544, 320)
$contentPanel.BackColor = [Drawing.Color]::White
$contentPanel.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($contentPanel)

$script:StatusLabel = New-Object Windows.Forms.Label
$script:StatusLabel.Location = New-Object Drawing.Point(24, 22)
$script:StatusLabel.Size = New-Object Drawing.Size(494, 44)
$script:StatusLabel.Text = '正在检查这台新设备，请稍候…'
$script:StatusLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
$script:StatusLabel.ForeColor = [Drawing.Color]::FromArgb(74, 85, 104)
$contentPanel.Controls.Add($script:StatusLabel)

$script:ProgressBar = New-Object Windows.Forms.ProgressBar
$script:ProgressBar.Location = New-Object Drawing.Point(24, 70)
$script:ProgressBar.Size = New-Object Drawing.Size(494, 10)
$script:ProgressBar.Minimum = 0
$script:ProgressBar.Maximum = 100
$script:ProgressBar.Value = 4
$script:ProgressBar.Style = [Windows.Forms.ProgressBarStyle]::Continuous
$contentPanel.Controls.Add($script:ProgressBar)

$keyPanel = New-Object Windows.Forms.Panel
$keyPanel.Location = New-Object Drawing.Point(24, 98)
$keyPanel.Size = New-Object Drawing.Size(494, 196)
$keyPanel.Visible = $false
$contentPanel.Controls.Add($keyPanel)

$keyLabel = New-Object Windows.Forms.Label
$keyLabel.Location = New-Object Drawing.Point(0, 0)
$keyLabel.Size = New-Object Drawing.Size(494, 28)
$keyLabel.Text = '最后一步：输入密钥 Key'
$keyLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 11, [Drawing.FontStyle]::Bold)
$keyLabel.ForeColor = [Drawing.Color]::FromArgb(28, 34, 48)
$keyPanel.Controls.Add($keyLabel)

$keyHint = New-Object Windows.Forms.Label
$keyHint.Location = New-Object Drawing.Point(0, 31)
$keyHint.Size = New-Object Drawing.Size(494, 22)
$keyHint.Text = '密钥只会加密保存在当前 Windows 用户中；当前接口：' + $script:Installer.ProviderName
$keyHint.ForeColor = [Drawing.Color]::FromArgb(105, 115, 135)
$keyPanel.Controls.Add($keyHint)

$keyTextBox = New-Object Windows.Forms.TextBox
$keyTextBox.Location = New-Object Drawing.Point(0, 59)
$keyTextBox.Size = New-Object Drawing.Size(494, 31)
$keyTextBox.Font = New-Object Drawing.Font('Segoe UI', 11)
$keyTextBox.UseSystemPasswordChar = $true
$keyPanel.Controls.Add($keyTextBox)

$saveButton = New-Object Windows.Forms.Button
$saveButton.Location = New-Object Drawing.Point(0, 101)
$saveButton.Size = New-Object Drawing.Size(494, 40)
$saveButton.Text = '保存密钥并启动 Codex'
$saveButton.FlatStyle = [Windows.Forms.FlatStyle]::Flat
$saveButton.FlatAppearance.BorderSize = 0
$saveButton.BackColor = [Drawing.Color]::FromArgb(42, 105, 220)
$saveButton.ForeColor = [Drawing.Color]::White
$saveButton.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10, [Drawing.FontStyle]::Bold)
$keyPanel.Controls.Add($saveButton)

$registerButton = New-Object Windows.Forms.Button
$registerButton.Location = New-Object Drawing.Point(0, 152)
$registerButton.Size = New-Object Drawing.Size(239, 36)
$registerButton.Text = '注册账号'
$registerButton.FlatStyle = [Windows.Forms.FlatStyle]::Flat
$registerButton.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(205, 211, 222)
$registerButton.BackColor = [Drawing.Color]::White
$keyPanel.Controls.Add($registerButton)

$tutorialButton = New-Object Windows.Forms.Button
$tutorialButton.Location = New-Object Drawing.Point(255, 152)
$tutorialButton.Size = New-Object Drawing.Size(239, 36)
$tutorialButton.Text = '获取密钥教程'
$tutorialButton.FlatStyle = [Windows.Forms.FlatStyle]::Flat
$tutorialButton.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(205, 211, 222)
$tutorialButton.BackColor = [Drawing.Color]::White
$keyPanel.Controls.Add($tutorialButton)

$registerButton.Add_Click({ Open-WebPage -Url $script:Installer.RegisterUrl })
$tutorialButton.Add_Click({ Show-KeyTutorial })

$form.Add_FormClosing({
  if (-not $script:InstallationCompleted) {
    $script:UserCancelled = $true
    if ($null -ne $script:ActiveWebClient) {
      try { $script:ActiveWebClient.CancelAsync() } catch {}
    }
    if ($null -ne $script:ActiveProcess -and -not $script:ActiveProcess.HasExited) {
      try { Stop-Process -Id $script:ActiveProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
  }
})

$saveButton.Add_Click({
  if (-not $script:InstallationReady) {
    return
  }

  $apiKey = $keyTextBox.Text.Trim()
  if ($apiKey.Length -lt 8) {
    [Windows.Forms.MessageBox]::Show('请输入完整密钥 Key。', '密钥不能为空', 'OK', 'Warning') | Out-Null
    $keyTextBox.Focus()
    return
  }

  $saveButton.Enabled = $false
  $keyTextBox.Enabled = $false
  Set-UiStatus -Text '正在验证密钥并读取可用模型…' -Progress 88
  $validation = Test-SelectedProviderApiKey -ApiKey $apiKey

  if (-not $validation.Success -and $validation.Unauthorized) {
    Set-UiStatus -Text '密钥验证失败，请检查后重试。' -Progress 82 -IsError
    [Windows.Forms.MessageBox]::Show('密钥无效、已过期或没有访问权限。请重新复制完整 Key。', '密钥验证失败', 'OK', 'Warning') | Out-Null
    $saveButton.Enabled = $true
    $keyTextBox.Enabled = $true
    $keyTextBox.SelectAll()
    $keyTextBox.Focus()
    return
  }

  if (-not $validation.Success) {
    $choice = [Windows.Forms.MessageBox]::Show(
      '暂时无法连接验证服务。可以先加密保存密钥并继续，稍后在 Codex 中重试。是否继续？',
      '网络暂时不可用',
      'YesNo',
      'Question'
    )
    if ($choice -ne [Windows.Forms.DialogResult]::Yes) {
      Set-UiStatus -Text '请检查网络后重新保存密钥。' -Progress 82
      $saveButton.Enabled = $true
      $keyTextBox.Enabled = $true
      return
    }
  }

  try {
    $paths = Get-CodexPaths
    $selectedModel = Select-PreferredModel -AvailableModels $validation.Models
    Protect-AndSaveApiKey -ApiKey $apiKey -Path $paths.KeyPath
    [void](Set-CodexConfiguration -ConfigPath $paths.ConfigPath -KeyHelperPath $paths.KeyHelperPath -Model $selectedModel)
    if (-not (Ensure-CodexSimplifiedChinese)) {
      Set-UiStatus -Text '离线中文配置没有完成，请查看错误提示后重试。' -Progress 90 -IsError
      $saveButton.Enabled = $true
      $keyTextBox.Enabled = $true
      $keyTextBox.Focus()
      return
    }

    $keyTextBox.Text = ''
    Set-UiStatus -Text ('中文功能开关已确认，正在重新启动 Codex（模型：' + $selectedModel + '）…') -Progress 100
    $saveButton.Text = '安装完成'
    $launchSucceeded = Start-CodexApplication
    if ($launchSucceeded) {
      [Windows.Forms.MessageBox]::Show(('Codex 已安装，已确认简体中文功能开关，已完成 ' + $script:Installer.ProviderName + ' 配置并成功启动。以后直接从开始菜单打开 ChatGPT 或 Codex 即可。'), '安装完成', 'OK', 'Information') | Out-Null
    } else {
      [Windows.Forms.MessageBox]::Show(('Codex 已安装并完成 ' + $script:Installer.ProviderName + ' 配置，但 Windows 没有响应自动启动请求。请从开始菜单手动打开 ChatGPT 或 Codex；配置不会丢失。'), '配置完成，请手动启动', 'OK', 'Warning') | Out-Null
    }
    $script:InstallationCompleted = $true
    $form.Close()
  } catch {
    Set-UiStatus -Text '保存配置失败，请重试。' -Progress 88 -IsError
    [Windows.Forms.MessageBox]::Show(('保存失败：' + $_.Exception.Message), '无法完成配置', 'OK', 'Error') | Out-Null
    $saveButton.Enabled = $true
    $keyTextBox.Enabled = $true
  } finally {
    $apiKey = $null
  }
})

$form.Add_Shown({
  try {
    Set-UiStatus -Text '正在检查 Windows 版本和处理器架构…' -Progress 8
    Assert-SupportedWindows
    Set-UiStatus -Text '系统检查通过，正在准备官方客户端…' -Progress 14
    Install-CodexApplication

    Set-UiStatus -Text '正在创建安全的本机密钥存储…' -Progress 72
    $paths = Get-CodexPaths
    Install-KeyHelper -Path $paths.KeyHelperPath

    Set-UiStatus -Text ('正在写入简体中文偏好和 ' + $script:Installer.ProviderName + ' 接口参数…') -Progress 77
    [void](Set-CodexConfiguration -ConfigPath $paths.ConfigPath -KeyHelperPath $paths.KeyHelperPath -Model $script:Installer.DefaultModel)

    Set-UiStatus -Text '客户端和运行组件已就绪，请输入密钥；简体中文将通过离线方式启用。' -Progress 82
    $script:InstallationReady = $true
    $keyPanel.Visible = $true
    $keyTextBox.Focus()
  } catch {
    if ($script:UserCancelled) {
      return
    }
    Set-UiStatus -Text '自动安装未完成。' -Progress 20 -IsError
    $message = "自动安装遇到问题：`r`n`r`n" + $_.Exception.Message + "`r`n`r`n请确认网络正常并重新双击安装脚本。"
    [Windows.Forms.MessageBox]::Show($message, '安装失败', 'OK', 'Error') | Out-Null
  }
})

[void][Windows.Forms.Application]::Run($form)
