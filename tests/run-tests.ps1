[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectDirectory = Split-Path -Parent $PSScriptRoot
$installerPath = Join-Path $projectDirectory 'installer.ps1'
$wizardPath = Join-Path $projectDirectory 'wizard.ps1'
$switcherPath = Join-Path $projectDirectory 'provider-switcher.ps1'
$choiceUiPath = Join-Path $projectDirectory 'choice-window.ps1'
$bootstrapPath = Join-Path $projectDirectory 'bootstrap.ps1'
$buildPath = Join-Path $projectDirectory 'build-release.ps1'
$exeBuildPath = Join-Path $projectDirectory 'build-exe.ps1'
$repairPath = Join-Path $projectDirectory 'repair.ps1'
$repairBuildPath = Join-Path $projectDirectory 'build-repair.ps1'
$repairLauncherPath = Join-Path $projectDirectory '无损修复 Cloudforl Codex.cmd'
$launcherPath = Join-Path $projectDirectory '安装 Cloudforl Codex.cmd'
$launcherSourcePath = Join-Path $projectDirectory 'exe-bootstrapper\Program.cs'
$manifestPath = Join-Path $projectDirectory 'exe-bootstrapper\app.manifest'
$writerX64Path = Join-Path $projectDirectory 'tools\codex-leveldb-writer-x64.exe'
$writerArm64Path = Join-Path $projectDirectory 'tools\codex-leveldb-writer-arm64.exe'

if (-not (Test-Path -LiteralPath $installerPath)) {
  throw 'installer.ps1 is missing.'
}
if (-not (Test-Path -LiteralPath $wizardPath) -or -not (Test-Path -LiteralPath $switcherPath) -or -not (Test-Path -LiteralPath $choiceUiPath)) {
  throw 'The v0.3 wizard or provider switcher is missing.'
}
if (-not (Test-Path -LiteralPath $launcherPath)) {
  throw 'The double-click launcher is missing.'
}
if (-not (Test-Path -LiteralPath $bootstrapPath)) {
  throw 'The PowerShell 5.1 bootstrap is missing.'
}
if (-not (Test-Path -LiteralPath $buildPath)) {
  throw 'The release builder is missing.'
}
if (-not (Test-Path -LiteralPath $exeBuildPath)) {
  throw 'The EXE builder is missing.'
}
if (-not (Test-Path -LiteralPath $repairPath) -or -not (Test-Path -LiteralPath $repairBuildPath) -or -not (Test-Path -LiteralPath $repairLauncherPath)) {
  throw 'The non-destructive repair package is missing.'
}
if (-not (Test-Path -LiteralPath $launcherSourcePath)) {
  throw 'The EXE launcher source is missing.'
}
if (-not (Test-Path -LiteralPath $manifestPath)) {
  throw 'The EXE launcher manifest is missing.'
}
if (-not (Test-Path -LiteralPath $writerX64Path)) {
  throw 'The x64 offline LevelDB writer is missing.'
}
if (-not (Test-Path -LiteralPath $writerArm64Path)) {
  throw 'The ARM64 offline LevelDB writer is missing.'
}

foreach ($scriptPath in @($installerPath, $wizardPath, $switcherPath, $choiceUiPath, $bootstrapPath, $buildPath, $exeBuildPath, $repairPath, $repairBuildPath, $PSCommandPath)) {
  $bytes = [IO.File]::ReadAllBytes($scriptPath)
  if ($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) {
    throw ('Windows PowerShell 5.1 requires a UTF-8 BOM for Chinese source text: ' + $scriptPath)
  }
  $tokens = $null
  $parseErrors = $null
  [void][Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object { Write-Error ($scriptPath + ': ' + $_.Message) }
    throw ('PowerShell syntax validation failed: ' + $scriptPath)
  }
}

$launcherSource = [IO.File]::ReadAllText($launcherSourcePath, [Text.Encoding]::UTF8)
$requiredLauncherValues = @(
  'Cloudforl.CodexInstaller.payload.zip',
  '__VERSION__',
  '__ASSEMBLY_VERSION__',
  '__PAYLOAD_SHA256__',
  'GetManifestResourceStream',
  'SHA256.Create()',
  'ZipArchive',
  'StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase)',
  'codex-leveldb-writer-x64.exe',
  'codex-leveldb-writer-arm64.exe',
  'Mutex',
  'WindowStyle Hidden',
  'launcher-error.log',
  'ProcessWindowStyle.Hidden'
)
foreach ($requiredLauncherValue in $requiredLauncherValues) {
  if (-not $launcherSource.Contains($requiredLauncherValue)) {
    throw ('Required EXE launcher value is missing: ' + $requiredLauncherValue)
  }
}

$manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)
if (-not $manifest.Contains('requestedExecutionLevel level="asInvoker"')) {
  throw 'The EXE launcher must run without elevation by default.'
}

$exeBuildSource = [IO.File]::ReadAllText($exeBuildPath, [Text.Encoding]::UTF8)
foreach ($requiredBuildValue in @(
  'Framework64\v4.0.30319\csc.exe',
  '/target:winexe',
  'Cloudforl.CodexInstaller.payload.zip',
  'EMBEDDED_ZIP_SHA256='
)) {
  if (-not $exeBuildSource.Contains($requiredBuildValue)) {
    throw ('Required EXE build value is missing: ' + $requiredBuildValue)
  }
}

$source = [IO.File]::ReadAllText($installerPath, [Text.Encoding]::UTF8)
$requiredValues = @(
  '9PLM9XGG6VKS',
  'https://cloudforl.com/v1',
  'Show-ProviderSelectionDialog',
  'Set-ProviderSelection -Id $selectedProviderId',
  'CredentialDirectoryName',
  'ProtectedData',
  'ChatGPT-x64.msix',
  'ChatGPT-arm64.msix',
  'localeOverride = "zh-CN"',
  'agent-mode-by-host-id',
  "'full-access'",
  'skip-full-access-confirm',
  'composer-permission-mode-visibility',
  'default_permissions = ":danger-full-access"',
  'DesktopStatePath',
  'DesktopStatePaths',
  'RequirementsPath',
  'Assert-CodexFullAccessAllowed',
  'LocalCache\Roaming',
  'Set-CodexDesktopLocale',
  '.codex-global-state.json',
  'enable_i18n',
  'locale_source',
  '118392242',
  '72216192',
  'Initialize-CodexOfflineI18nCache',
  'Get-CodexLevelDbWriterPath',
  'Select-CodexLevelDbPath',
  "'download-' + `$script:RunId",
  'UserCancelled',
  'CancelAsync()',
  'OperationCanceledException',
  'codex-browser-app\Local Storage\leveldb',
  'codex-leveldb-writer-x64.exe',
  'codex-leveldb-writer-arm64.exe',
  'Local Storage\leveldb',
  "origin = 'app://-'",
  '90393ED3F4C1779B996B83D901993925507732DF5FA5D5F45F8148C5B0C1534F',
  'E2B02608A4279306409FE95675DE9BEDE96EA9622FB44A7DC46A50DA6B7F70E5',
  "`$writerArguments += '-create'",
  'IApplicationActivationManager',
  'PackagedAppActivation',
  '45BA127D-10A8-46EA-8AB7-56EA9078943C',
  '2e941141-7f97-4756-ba1d-9decde894a3d',
  'statsig.stable_id.',
  'statsig.cached.evaluations.',
  'Test-CodexI18nCache',
  "Version = '0.4.6'",
  'store-fallback.log',
  'CloseMainWindow()'
)
foreach ($requiredValue in $requiredValues) {
  if (-not $source.Contains($requiredValue)) {
    throw ('Required installer value is missing: ' + $requiredValue)
  }
}

$selectionIndex = $source.IndexOf('$selectedProviderId = Show-ProviderSelectionDialog', [StringComparison]::Ordinal)
$installerWindowIndex = $source.IndexOf('$form = New-Object Windows.Forms.Form', [StringComparison]::Ordinal)
if ($selectionIndex -lt 0 -or $installerWindowIndex -lt 0 -or $selectionIndex -ge $installerWindowIndex) {
  throw 'The provider choice must be shown before the installation window.'
}

$forbiddenValues = @(
  'ProxyEnable',
  'ProxyServer',
  'AutoConfigURL',
  'Set-TemporarySystemProxy',
  'ab.chatgpt.com/v1/initialize',
  'Get-CodexExecutablePath',
  'Start-Process -FilePath $executablePath'
)
foreach ($forbiddenValue in $forbiddenValues) {
  if ($source.Contains($forbiddenValue)) {
    throw ('The offline installer must not contain system-proxy activation code: ' + $forbiddenValue)
  }
}

$offlineCacheFunction = [regex]::Match(
  $source,
  '(?s)function Initialize-CodexOfflineI18nCache\s*\{.*?(?=\r?\nfunction Open-WebPage)'
).Value
if ([string]::IsNullOrWhiteSpace($offlineCacheFunction)) {
  throw 'The active offline i18n cache function could not be located.'
}
if ($offlineCacheFunction.Contains('Start-CodexPackagedApplication')) {
  throw 'The active offline i18n cache path must not pre-launch Codex.'
}
if (-not $offlineCacheFunction.Contains('$databasePaths = @($existingDatabasePaths)')) {
  throw 'The active offline i18n cache path must update every discovered database.'
}

if ($source -match '(?i)sk-[A-Za-z0-9_-]{20,}') {
  throw 'A value resembling an API key is embedded in the installer.'
}

$wizardSource = [IO.File]::ReadAllText($wizardPath, [Text.Encoding]::UTF8)
$switcherSource = [IO.File]::ReadAllText($switcherPath, [Text.Encoding]::UTF8)
$choiceUiSource = [IO.File]::ReadAllText($choiceUiPath, [Text.Encoding]::UTF8)
$repairSource = [IO.File]::ReadAllText($repairPath, [Text.Encoding]::UTF8)
$modelSelectionFunction = [regex]::Match($switcherSource, '(?s)function Get-CodexTestModels\s*\{.*?(?=\r?\nfunction Test-Provider)').Value
if ([string]::IsNullOrWhiteSpace($modelSelectionFunction)) { throw 'Automatic model ranking function is missing.' }
. ([scriptblock]::Create($modelSelectionFunction))
$rankedModels = @(Get-CodexTestModels -AvailableModels @('gpt-image-2', 'codex-auto-review', 'gpt-5.6-sol', 'gpt-6-astra', 'gpt-6.1-sol', 'gpt-6-luna', 'gpt-6.1-sol'))
if ($rankedModels.Count -ne 4 -or $rankedModels[0] -cne 'gpt-6.1-sol' -or $rankedModels[1] -cne 'gpt-6-astra') {
  throw 'Automatic selection must prefer the newest suitable Codex model and exclude image/review models.'
}
$futureModels = @(Get-CodexTestModels -AvailableModels @('gpt-6.1-sol', 'gpt-7-sol'))
if ($futureModels[0] -cne 'gpt-7-sol') { throw 'Automatic model selection must not be fixed to the current catalog.' }
foreach ($value in @('Invoke-SwitcherStep', 'Install-CodexApplication', 'Ensure-CodexSimplifiedChinese', 'Install-DesktopLauncher', '安装完成后运行 Codex', '在桌面创建', "Step 'Apply'")) {
  if (-not $wizardSource.Contains($value)) { throw ('Wizard feature is missing: ' + $value) }
}
foreach ($value in @('$fill.BackColor = $cyan', '$pulse.Add_Tick', "Codex 一键安装 v0.4.6", 'choice-window.ps1')) {
  if (-not $wizardSource.Contains($value)) { throw ('New wizard theme is missing: ' + $value) }
}
foreach ($value in @('Install-OfficialCodexIcon', 'Square44x44Logo', "Join-Path `$desktopPath 'Codex.lnk'", '$shortcut.IconLocation = $iconPath', 'Codex.ico', 'ProgressPercentLabel', '在桌面创建“Codex”图标')) {
  if (-not $wizardSource.Contains($value)) { throw ('Desktop icon or progress percentage feature is missing: ' + $value) }
}
foreach ($value in @('$script:ProgressPercentLabel.Text', '$script:ProgressDetailLabel', 'Content-Length', '$downloadPercent', 'Format-TransferRate', 'MarqueeAnimationSpeed', '已用时')) {
  if (-not $source.Contains($value) -and -not $wizardSource.Contains($value)) {
    throw ('Installation download progress detail is missing: ' + $value)
  }
}
foreach ($value in @('官方账号登录', 'CloudForl 平台接入', '自定义接入', 'https://cloudforl.com/v1', 'Sub2API', '测试连通', '下一步', "'/models'", "'/responses'", 'ProtectedData', 'switch-backup-', 'firstLaunchPending', 'model_providers.', 'Start-Codex', "'cloudchatai','aiskillmcp','kekuokuo'")) {
  if (-not $switcherSource.Contains($value)) { throw ('Switcher feature is missing: ' + $value) }
}
foreach ($value in @('CatalogOnly', 'KnownModels', '$modelBox.Items.Add', '验证所选模型', '$frameSpec.control.Add_Enter', '$button.Add_MouseDown')) {
  if (-not $switcherSource.Contains($value)) { throw ('Model picker or focus effect is missing: ' + $value) }
}
if ($switcherSource -match '(?i)sk-[A-Za-z0-9_-]{20,}') { throw 'A value resembling an API key is embedded in the switcher.' }
foreach ($value in @('Show-NewPlatformDialog', '步骤 02 / 03', '选择 Codex 接入方式', '900, 728', 'CloudForl 平台', '测试连通', '保存并返回', 'Get-SafeChoiceError')) {
  if (-not $choiceUiSource.Contains($value)) { throw ('Redesigned choice UI is missing: ' + $value) }
}
if ($choiceUiSource -match '(?i)sk-[A-Za-z0-9_-]{20,}') { throw 'A value resembling an API key is embedded in the choice UI.' }
foreach ($value in @('Get-CodexTestModels -AvailableModels @($catalog.models)', '正在验证 ', '已自动尝试 ', "`$testButton.Text -eq '测试中…'")) {
  if (-not $choiceUiSource.Contains($value)) { throw ('Automatic model verification flow is missing: ' + $value) }
}
if ($choiceUiSource.Contains('请选择模型后再次点击测试连通')) { throw 'Model discovery must not stop and require a second click.' }
if ($source.Contains('sub2.cloudforl.com') -or $source.Contains('api.cloudforl.com/v1') -or
    $switcherSource.Contains('sub2.cloudforl.com') -or $switcherSource.Contains('api.cloudforl.com/v1') -or
    $choiceUiSource.Contains('sub2.cloudforl.com') -or $choiceUiSource.Contains('api.cloudforl.com/v1')) {
  throw 'Only the CloudForl card may have a fixed third-party endpoint.'
}
if (-not $choiceUiSource.Contains('if (-not $Installation) {') -or
    -not $choiceUiSource.Contains('$script:ChoiceInstallationMode = [bool]$Installation') -or
    -not $choiceUiSource.Contains('$saved.Visible = ($isCustom -and -not $script:ChoiceInstallationMode)') -or
    -not $choiceUiSource.Contains('Codex 安装 v0.4.6 · 选择接入方式') -or
    -not $choiceUiSource.Contains("`$urlBox.Text = ''")) {
  throw 'Installer custom access must start blank without loading previous profiles.'
}
foreach ($value in @('$script:SavedReady', '$script:LaunchSavedProfile', 'verified = $true', '$testButton.Visible = ($script:ChoiceKind -cne', '已保存的接入配置未改动，可直接启动 Codex。')) {
  if (-not $choiceUiSource.Contains($value)) { throw ('Saved provider fast launch feature is missing: ' + $value) }
}
foreach ($value in @('$modelBox.Tag = $false', '$save.Enabled = $false', 'Test-Provider -BaseUrl $url -Key $key -RequestedModel', '完成模型和 Responses 接口验证', '平台已完成连通验证并保存')) {
  if (-not $choiceUiSource.Contains($value)) { throw ('New platform full verification flow is missing: ' + $value) }
}
if ($choiceUiSource.Contains('返回主窗口仍需测试')) { throw 'New platform dialog must complete verification before returning.' }
foreach ($value in @('repair-backups', 'provider-switcher.ps1', 'choice-window.ps1', '没有卸载 Codex', '没有删除项目、会话、配置或密钥')) {
  if (-not $repairSource.Contains($value)) { throw ('Non-destructive repair safeguard is missing: ' + $value) }
}
if ($repairSource -match '(?i)Remove-Item\s+.*(?:sessions|projects|profiles|accounts|config\.toml)') {
  throw 'Repair script must not delete projects, sessions, profiles, accounts, or config.'
}
$launchBranch = $switcherSource.Substring($switcherSource.LastIndexOf("if (`$Mode -eq 'Launch')"))
if ($launchBranch.Contains('$check = Test-Provider')) { throw 'Saved provider launch must not repeat a network test.' }
if ($choiceUiSource -match '\(if\s*\(') { throw 'PowerShell if cannot be used as a parenthesized expression in a UI event.' }
if (-not $choiceUiSource.Contains('FlatAppearance.CheckedBackColor')) { throw 'Selected provider cards need an explicit dark checked color.' }
if ($switcherSource -match '(?i)Remove-Item\s+.*(?:sessions|projects)' -or $wizardSource -match '(?i)Remove-Item\s+.*(?:sessions|projects)') {
  throw 'Project or conversation deletion is forbidden.'
}

$writerX64Hash = (Get-FileHash -LiteralPath $writerX64Path -Algorithm SHA256).Hash
$writerArm64Hash = (Get-FileHash -LiteralPath $writerArm64Path -Algorithm SHA256).Hash
if ($writerX64Hash -ne '90393ED3F4C1779B996B83D901993925507732DF5FA5D5F45F8148C5B0C1534F') {
  throw 'The x64 offline LevelDB writer hash is unexpected.'
}
if ($writerArm64Hash -ne 'E2B02608A4279306409FE95675DE9BEDE96EA9622FB44A7DC46A50DA6B7F70E5') {
  throw 'The ARM64 offline LevelDB writer hash is unexpected.'
}

Write-Output 'ALL_STATIC_TESTS_PASSED'
