[CmdletBinding()]
param(
  [ValidateSet('Select','Apply','Launch','Key')][string]$Mode = 'Launch',
  [string]$SelectionPath,
  [string]$ProfileId
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:DataRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Cloudforl Codex Switcher'
$script:RegistryPath = Join-Path $script:DataRoot 'profiles.json'
$script:AppId = 'OpenAI.Codex_2p2nqsd0c76g0!App'
$script:BuiltIn = 'cloudforl'
$script:OfficialUrl = 'https://chatgpt.com/backend-api/codex'

function Write-AtomicText {
  param([string]$Path, [string]$Content)
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
  $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [IO.File]::WriteAllText($temporary, $Content, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) {
      [IO.File]::Copy($temporary, $Path, $true)
      Remove-Item -LiteralPath $temporary -Force
    } else {
      [IO.File]::Move($temporary, $Path)
    }
  } finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
  }
}

function Get-Registry {
  if (-not (Test-Path -LiteralPath $script:RegistryPath)) {
    return [pscustomobject]@{ version = 1; lastId = ''; firstLaunchPending = $true; profiles = @() }
  }
  $registry = [IO.File]::ReadAllText($script:RegistryPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
  if ($null -eq $registry -or $null -eq $registry.PSObject.Properties['profiles'] -or $null -eq $registry.profiles) { throw '接入平台列表损坏；没有覆盖原文件。' }
  if ($null -eq $registry.PSObject.Properties['lastId']) { $registry | Add-Member -NotePropertyName lastId -NotePropertyValue '' }
  if ($null -eq $registry.PSObject.Properties['firstLaunchPending']) { $registry | Add-Member -NotePropertyName firstLaunchPending -NotePropertyValue $true }
  return $registry
}

function Save-Registry {
  param($Registry)
  Write-AtomicText -Path $script:RegistryPath -Content (($Registry | ConvertTo-Json -Depth 12) + "`r`n")
}

function Get-Profile {
  param($Registry, [string]$Id)
  $found = @($Registry.profiles | Where-Object { [string]$_.id -ceq $Id } | Select-Object -First 1)
  if ($found.Count -eq 0) { return $null }
  return $found[0]
}

function Get-SecretPath {
  param([string]$Id)
  if ($Id -notmatch '^[A-Za-z0-9_-]{2,64}$') { throw '无效的接入平台标识。' }
  return (Join-Path $script:DataRoot ('accounts\' + $Id + '\key.dat'))
}

function Protect-Secret {
  param([string]$Id, [string]$Secret)
  Add-Type -AssemblyName System.Security
  $raw = [Text.Encoding]::UTF8.GetBytes($Secret)
  try {
    $encrypted = [Security.Cryptography.ProtectedData]::Protect($raw, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    Write-AtomicText -Path (Get-SecretPath -Id $Id) -Content ([Convert]::ToBase64String($encrypted))
  } finally { [Array]::Clear($raw, 0, $raw.Length) }
}

function Unprotect-Secret {
  param([string]$Id)
  Add-Type -AssemblyName System.Security
  $path = Get-SecretPath -Id $Id
  if (-not (Test-Path -LiteralPath $path)) { throw '此平台尚未保存密钥，请重新输入。' }
  $encrypted = [Convert]::FromBase64String([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8).Trim())
  $raw = [Security.Cryptography.ProtectedData]::Unprotect($encrypted, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
  try { return [Text.Encoding]::UTF8.GetString($raw) }
  finally { [Array]::Clear($raw, 0, $raw.Length) }
}

if ($Mode -eq 'Key') {
  if ([string]::IsNullOrWhiteSpace($ProfileId)) { throw '缺少平台标识。' }
  [Console]::Out.Write((Unprotect-Secret -Id $ProfileId))
  return
}

function Normalize-ApiUrl {
  param([string]$InputUrl)
  $value = $InputUrl.Trim()
  if ($value -notmatch '^https?://') { $value = 'https://' + $value }
  $uri = $null
  if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) { throw '接口地址格式错误。' }
  if ($uri.Scheme -cne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host) -or
      -not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or
      -not [string]::IsNullOrWhiteSpace($uri.Query) -or -not [string]::IsNullOrWhiteSpace($uri.Fragment)) {
    throw '请使用完整的 HTTPS 接口地址，且不要包含用户名、参数或锚点。'
  }
  $path = $uri.AbsolutePath.TrimEnd('/')
  if ([string]::IsNullOrWhiteSpace($path)) { $path = '/v1' }
  if ($path -cne '/v1') { throw 'Sub2API 接口地址应以 /v1 结尾。' }
  return ($uri.GetLeftPart([UriPartial]::Authority).TrimEnd('/') + '/v1')
}

function Wait-HttpTask {
  param($Task)
  while (-not $Task.IsCompleted) {
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 80
  }
  return $Task.GetAwaiter().GetResult()
}

function Get-CodexTestModels {
  param([string[]]$AvailableModels)
  $ranked = foreach ($item in @($AvailableModels)) {
    $id = [string]$item
    if ($id -notmatch '^gpt-(\d+)(?:\.(\d+))?(?:-(.+))?$') { continue }
    $major = [int]$Matches[1]
    $minor = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
    $suffix = [string]$Matches[3]
    if ($suffix -match '(?i)image|audio|realtime|transcrib|tts|embed|moderation|review|search|chat|cyber|spark|preview') { continue }
    $variant = switch -Regex ($suffix) {
      '^sol$' { 5; break }
      '^astra$' { 4; break }
      '^codex$' { 3; break }
      '^terra$' { 2; break }
      '^luna$' { 1; break }
      '^(?:pro|mini|nano)$' { 0; break }
      '^$' { 3; break }
      default { -1 }
    }
    if ($variant -lt 0) { continue }
    [pscustomobject]@{
      id = $id
      major = $major
      minor = $minor
      variant = $variant
    }
  }
  return @($ranked | Sort-Object -Property @{ Expression = 'major'; Descending = $true }, @{ Expression = 'minor'; Descending = $true }, @{ Expression = 'variant'; Descending = $true } | Select-Object -ExpandProperty id -Unique)
}

function Test-Provider {
  param([string]$BaseUrl, [string]$Key, [string]$RequestedModel = '', [string[]]$KnownModels = @(), [switch]$CatalogOnly)
  Add-Type -AssemblyName System.Net.Http
  $client = New-Object Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds(25)
  $client.DefaultRequestHeaders.Authorization = New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer', $Key)
  $client.DefaultRequestHeaders.UserAgent.ParseAdd('Cloudforl-Codex-Switcher/0.4.5')
  try {
    if ($KnownModels.Count -gt 0) {
      $models = @($KnownModels)
    } else {
      $modelsResponse = Wait-HttpTask -Task ($client.GetAsync($BaseUrl + '/models'))
      if (-not $modelsResponse.IsSuccessStatusCode) { throw ('模型列表返回 HTTP ' + [int]$modelsResponse.StatusCode) }
      $json = Wait-HttpTask -Task ($modelsResponse.Content.ReadAsStringAsync())
      $catalog = $json | ConvertFrom-Json
      $models = @($catalog.data | ForEach-Object { [string]$_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    }
    if ($models.Count -eq 0) { throw '平台没有返回可用模型。' }
    $preferred = @(Get-CodexTestModels -AvailableModels $models)
    if (-not [string]::IsNullOrWhiteSpace($RequestedModel)) {
      if ($models -notcontains $RequestedModel) { $models += $RequestedModel }
      $model = $RequestedModel
    } else {
      if ($preferred.Count -eq 0) { throw '模型列表没有适合 Codex 的通用 GPT 模型；请联系平台确认 Responses 模型支持情况。' }
      $model = [string]$preferred[0]
    }
    if ($CatalogOnly) { return [pscustomobject]@{ model = $model; models = @($models) } }
    $body = @{ model = $model; input = 'Reply OK.'; max_output_tokens = 64; stream = $false } | ConvertTo-Json -Compress
    $content = New-Object Net.Http.StringContent($body, [Text.Encoding]::UTF8, 'application/json')
    try { $reply = Wait-HttpTask -Task ($client.PostAsync($BaseUrl + '/responses', $content)) }
    finally { $content.Dispose() }
    if (-not $reply.IsSuccessStatusCode) { throw ('Responses 接口返回 HTTP ' + [int]$reply.StatusCode) }
    $replyBody = Wait-HttpTask -Task ($reply.Content.ReadAsStringAsync())
    $result = $replyBody | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$result.id) -or [string]$result.object -cne 'response' -or [string]$result.status -cne 'completed') {
      throw 'Responses 接口未完成有效回复。'
    }
    return [pscustomobject]@{ model = $model; models = @($models); message = ('连接成功 · 返回 ' + $models.Count + ' 个模型 · 已验证：' + $model) }
  } finally { $client.Dispose() }
}

function ConvertTo-TomlString {
  param([string]$Value)
  return ('"' + $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n') + '"')
}

function Get-CodexConfigPath {
  $homePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
  $codexHome = if ([string]::IsNullOrWhiteSpace([string]$env:CODEX_HOME)) { Join-Path $homePath '.codex' } else { [IO.Path]::GetFullPath($env:CODEX_HOME) }
  return (Join-Path $codexHome 'config.toml')
}

function Get-ProviderIdsInConfig {
  param([string]$Content)
  $ids = New-Object Collections.Generic.List[string]
  foreach ($match in [regex]::Matches($Content, '(?im)^\s*\[model_providers\.([A-Za-z0-9_-]+)(?:\.[^\]]+)?\]\s*(?:#.*)?$')) {
    $id = [string]$match.Groups[1].Value
    if ($id -notin @('openai','ollama','lmstudio','amazon-bedrock') -and -not $ids.Contains($id)) { [void]$ids.Add($id) }
  }
  return @($ids.ToArray())
}

function Update-RouteConfig {
  param($Profile, $Registry)
  if ([string]$Profile.id -cne 'openai') {
    if ([string]$Profile.id -notmatch '^[A-Za-z0-9_-]{2,64}$') { throw '平台标识格式错误。' }
    $Profile.url = Normalize-ApiUrl -InputUrl ([string]$Profile.url)
  }
  $configPath = Get-CodexConfigPath
  $existing = if (Test-Path -LiteralPath $configPath) { [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8) } else { '' }
  $oldIds = @(Get-ProviderIdsInConfig -Content $existing)
  $activeId = [string]$Profile.id
  $isOfficial = $activeId -ceq 'openai'
  $redirectIds = New-Object Collections.Generic.List[string]
  if (-not $isOfficial) {
    $legacyIds = @('cloudchatai','aiskillmcp','kekuokuo','cloudforl','cloudforl_api','sub2')
    foreach ($id in @($oldIds) + @($legacyIds) + @($Registry.profiles | ForEach-Object { [string]$_.id })) {
      if ($id -match '^[A-Za-z0-9_-]{2,64}$' -and $id -cne 'openai' -and -not $redirectIds.Contains($id)) { [void]$redirectIds.Add($id) }
    }
    if (-not $redirectIds.Contains($activeId)) { [void]$redirectIds.Add($activeId) }
  }
  $lines = @($existing.Replace("`r`n", "`n").Replace("`r", "`n") -split "`n")
  $kept = New-Object Collections.Generic.List[string]
  $atRoot = $true
  $skipSection = $false
  $skipManaged = $false
  foreach ($line in $lines) {
    if ($line -match '^\s*#\s*BEGIN (?:SUB2 CLOUDFORL|CLOUDFORL) CODEX MANAGED ROOT\s*$') { $skipManaged = $true; continue }
    if ($line -match '^\s*#\s*END (?:SUB2 CLOUDFORL|CLOUDFORL) CODEX MANAGED ROOT\s*$') { $skipManaged = $false; continue }
    if ($skipManaged -or $line -match '^\s*#\s*(?:BEGIN|END) (?:SUB2 CLOUDFORL|CLOUDFORL) CODEX MANAGED PROVIDER\s*$') { continue }
    if ($line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
      $atRoot = $false
      $section = [string]$matches[1]
      $skipSection = $false
      if (-not $isOfficial -and $section -match '^model_providers\.([A-Za-z0-9_-]+)(?:\..*)?$') {
        $skipSection = $redirectIds.Contains([string]$matches[1])
      }
      if ($skipSection) { continue }
    }
    if ($skipSection) { continue }
    if ($atRoot -and $line -match '^\s*(model|model_provider|openai_base_url)\s*=') { continue }
    [void]$kept.Add($line)
  }
  while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[0])) { $kept.RemoveAt(0) }
  while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) { $kept.RemoveAt($kept.Count - 1) }
  $output = New-Object Collections.Generic.List[string]
  if ($isOfficial) {
    [void]$output.Add('model_provider = "openai"')
  } else {
    [void]$output.Add(('model = ' + (ConvertTo-TomlString -Value ([string]$Profile.model))))
    [void]$output.Add(('model_provider = ' + (ConvertTo-TomlString -Value $activeId)))
  }
  [void]$output.Add('')
  foreach ($line in $kept) { [void]$output.Add($line) }
  if (-not $isOfficial) {
    $helper = Join-Path $script:DataRoot 'provider-switcher.ps1'
    foreach ($id in $redirectIds) {
      [void]$output.Add('')
      [void]$output.Add(('[model_providers.' + $id + ']'))
      [void]$output.Add(('name = ' + (ConvertTo-TomlString -Value ([string]$Profile.name))))
      [void]$output.Add(('base_url = ' + (ConvertTo-TomlString -Value ([string]$Profile.url))))
      [void]$output.Add('wire_api = "responses"')
      [void]$output.Add('supports_websockets = false')
      [void]$output.Add('')
      [void]$output.Add(('[model_providers.' + $id + '.auth]'))
      [void]$output.Add('command = "powershell.exe"')
      [void]$output.Add(('args = ["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ' + (ConvertTo-TomlString -Value $helper) + ', "-Mode", "Key", "-ProfileId", ' + (ConvertTo-TomlString -Value $activeId) + ']'))
      [void]$output.Add('timeout_ms = 10000')
    }
  }
  $newContent = $output.ToArray() -join "`r`n"
  if ($newContent -ceq $existing.Trim()) { return }
  if (Test-Path -LiteralPath $configPath) {
    $backup = $configPath + '.switch-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    Copy-Item -LiteralPath $configPath -Destination $backup
  }
  Write-AtomicText -Path $configPath -Content ($newContent.Trim() + "`r`n")
}

function Confirm-CodexClosed {
  $processes = @(Get-Process -Name 'Codex','ChatGPT' -ErrorAction SilentlyContinue)
  if ($processes.Count -eq 0) { return }
  $answer = [Windows.Forms.MessageBox]::Show('切换接口前需要关闭正在运行的 Codex。是否现在尝试正常关闭？请先保存未完成的输入。', '关闭 Codex', 'YesNo', 'Question')
  if ($answer -ne [Windows.Forms.DialogResult]::Yes) { throw '用户取消了接口切换。' }
  foreach ($process in $processes) { try { [void]$process.CloseMainWindow() } catch {} }
  $until = (Get-Date).AddSeconds(15)
  do { Start-Sleep -Milliseconds 300; $processes = @(Get-Process -Name 'Codex','ChatGPT' -ErrorAction SilentlyContinue) }
  while ($processes.Count -gt 0 -and (Get-Date) -lt $until)
  if ($processes.Count -gt 0) { throw 'Codex 仍在运行，请手动关闭后重试；旧配置没有改动。' }
}

function Start-Codex {
  $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $package) {
    throw '未找到已安装的 OpenAI 官方 Codex 客户端；请重新运行安装器。'
  }
  $app = @(Get-StartApps -ErrorAction SilentlyContinue | Where-Object { $_.AppID -like ($package.PackageFamilyName + '!*') } | Select-Object -First 1)
  $appId = if ($app.Count -gt 0) { [string]$app[0].AppID } else { [string]$package.PackageFamilyName + '!App' }
  $target = 'shell:AppsFolder\' + $appId
  $attempts = @(
    { Start-Process -FilePath $target -ErrorAction Stop | Out-Null },
    { Start-Process -FilePath 'explorer.exe' -ArgumentList $target -ErrorAction Stop | Out-Null },
    {
      $shell = New-Object -ComObject Shell.Application
      $folder = $shell.Namespace('shell:AppsFolder')
      $item = $folder.ParseName($appId)
      if ($null -eq $item) { throw 'Windows 无法定位已安装的 Codex 应用。' }
      $item.InvokeVerb('open')
    }
  )
  foreach ($attempt in $attempts) {
    try {
      & $attempt
      for ($i = 0; $i -lt 32; $i++) {
        if ($null -ne (Get-Process -Name 'ChatGPT','Codex' -ErrorAction SilentlyContinue | Select-Object -First 1)) { return }
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 250
      }
    } catch {}
  }
  throw 'Windows 未确认 Codex 已启动；请从开始菜单手动打开，接入配置仍已保存。'
}

function Show-ChoiceWindow {
  param($Registry, [bool]$Installation)
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  [Windows.Forms.Application]::EnableVisualStyles()
  $script:ChoiceKind = ''
  $script:Validated = $null
  $form = New-Object Windows.Forms.Form
  $form.Text = if ($Installation) { 'Codex 安装 · 选择接入方式' } else { 'Codex 启动 · 选择接入方式' }
  $form.ClientSize = New-Object Drawing.Size(650, 625)
  $form.StartPosition = 'CenterScreen'
  $form.FormBorderStyle = 'FixedDialog'
  $form.MaximizeBox = $false
  $form.TopMost = $true
  $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
  $navy = [Drawing.Color]::FromArgb(11, 21, 37)
  $surface = [Drawing.Color]::FromArgb(20, 37, 57)
  $cyan = [Drawing.Color]::FromArgb(37, 215, 232)
  $muted = [Drawing.Color]::FromArgb(150, 179, 197)
  $white = [Drawing.Color]::FromArgb(235, 246, 250)
  $form.BackColor = $navy
  $form.ForeColor = $white
  $form.Add_Paint({
    $brush = New-Object Drawing.SolidBrush($cyan)
    try { $_.Graphics.FillRectangle($brush, 0, 0, 650, 3) } finally { $brush.Dispose() }
  })
  $header = New-Object Windows.Forms.Label
  $header.Text = '选择 Codex 接入方式'
  $header.Font = New-Object Drawing.Font('Microsoft YaHei UI', 15, [Drawing.FontStyle]::Bold)
  $header.Location = New-Object Drawing.Point(22, 17)
  $header.Size = New-Object Drawing.Size(600, 34)
  $header.ForeColor = $white
  $form.Controls.Add($header)
  $warning = New-Object Windows.Forms.Label
  $warning.Text = '第三方必须是兼容 Codex Responses API 的 Sub2API 系统。切换后旧会话内容可能发送给新平台；本地项目和记录不会删除。'
  $warning.ForeColor = [Drawing.Color]::FromArgb(255, 184, 112)
  $warning.Location = New-Object Drawing.Point(22, 52)
  $warning.Size = New-Object Drawing.Size(606, 49)
  $form.Controls.Add($warning)
  $official = New-Object Windows.Forms.RadioButton
  $official.Appearance = 'Button'; $official.Text = '官方账号登录'; $official.TextAlign = 'TopLeft'
  $official.Padding = New-Object Windows.Forms.Padding(15, 5, 0, 0)
  $official.Location = New-Object Drawing.Point(22, 112); $official.Size = New-Object Drawing.Size(605, 50)
  $official.FlatStyle = 'Flat'; $official.FlatAppearance.BorderSize = 1
  $official.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(55, 85, 105)
  $official.BackColor = $surface; $official.ForeColor = $white; $official.Cursor = 'Hand'
  $form.Controls.Add($official)
  $officialHint = New-Object Windows.Forms.Label
  $officialHint.Text = $script:OfficialUrl + '（登录由官方客户端完成）'
  $officialHint.Font = New-Object Drawing.Font('Microsoft YaHei UI', 8)
  $officialHint.Location = New-Object Drawing.Point(17, 27); $officialHint.Size = New-Object Drawing.Size(565, 19)
  $officialHint.ForeColor = $muted; $officialHint.BackColor = [Drawing.Color]::Transparent
  $official.Controls.Add($officialHint)
  $officialHint.Add_Click({ $official.Checked = $true })
  $cloud = New-Object Windows.Forms.RadioButton
  $cloud.Appearance = 'Button'; $cloud.Text = 'CloudForl 平台接入'; $cloud.TextAlign = 'TopLeft'
  $cloud.Padding = New-Object Windows.Forms.Padding(15, 5, 0, 0)
  $cloud.Location = New-Object Drawing.Point(22, 169); $cloud.Size = New-Object Drawing.Size(605, 50)
  $cloud.FlatStyle = 'Flat'; $cloud.FlatAppearance.BorderSize = 1
  $cloud.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(55, 85, 105)
  $cloud.BackColor = $surface; $cloud.ForeColor = $white; $cloud.Cursor = 'Hand'
  $form.Controls.Add($cloud)
  $cloudHint = New-Object Windows.Forms.Label
  $cloudHint.Text = 'https://cloudforl.com/v1'
  $cloudHint.Font = New-Object Drawing.Font('Microsoft YaHei UI', 8)
  $cloudHint.Location = New-Object Drawing.Point(17, 27); $cloudHint.Size = New-Object Drawing.Size(565, 19)
  $cloudHint.ForeColor = $muted; $cloudHint.BackColor = [Drawing.Color]::Transparent
  $cloud.Controls.Add($cloudHint)
  $cloudHint.Add_Click({ $cloud.Checked = $true })
  $custom = New-Object Windows.Forms.RadioButton
  $custom.Appearance = 'Button'; $custom.Text = '自定义接入'; $custom.TextAlign = 'TopLeft'
  $custom.Padding = New-Object Windows.Forms.Padding(15, 5, 0, 0)
  $custom.Location = New-Object Drawing.Point(22, 226); $custom.Size = New-Object Drawing.Size(605, 50)
  $custom.FlatStyle = 'Flat'; $custom.FlatAppearance.BorderSize = 1
  $custom.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(55, 85, 105)
  $custom.BackColor = $surface; $custom.ForeColor = $white; $custom.Cursor = 'Hand'
  $form.Controls.Add($custom)
  $customHint = New-Object Windows.Forms.Label
  $customHint.Text = '选择已添加的平台，或添加新的 Sub2API 平台'
  $customHint.Font = New-Object Drawing.Font('Microsoft YaHei UI', 8)
  $customHint.Location = New-Object Drawing.Point(17, 27); $customHint.Size = New-Object Drawing.Size(565, 19)
  $customHint.ForeColor = $muted; $customHint.BackColor = [Drawing.Color]::Transparent
  $custom.Controls.Add($customHint)
  $customHint.Add_Click({ $custom.Checked = $true })
  $savedLabel = New-Object Windows.Forms.Label
  $savedLabel.Text = '已添加平台：'; $savedLabel.Location = New-Object Drawing.Point(22, 294); $savedLabel.Size = New-Object Drawing.Size(93, 23)
  $savedLabel.ForeColor = $muted
  $form.Controls.Add($savedLabel)
  $saved = New-Object Windows.Forms.ComboBox
  $saved.DropDownStyle = 'DropDownList'; $saved.Location = New-Object Drawing.Point(114, 291); $saved.Size = New-Object Drawing.Size(390, 28)
  $saved.FlatStyle = 'Flat'; $saved.BackColor = $surface; $saved.ForeColor = $white
  $form.Controls.Add($saved)
  $newButton = New-Object Windows.Forms.Button
  $newButton.Text = '新添加'; $newButton.Location = New-Object Drawing.Point(514, 289); $newButton.Size = New-Object Drawing.Size(113, 31)
  $newButton.FlatStyle = 'Flat'; $newButton.FlatAppearance.BorderColor = $cyan
  $newButton.BackColor = $surface; $newButton.ForeColor = $cyan; $newButton.Cursor = 'Hand'
  $form.Controls.Add($newButton)
  $urlLabel = New-Object Windows.Forms.Label
  $urlLabel.Text = '接口地址：'; $urlLabel.Location = New-Object Drawing.Point(22, 336); $urlLabel.Size = New-Object Drawing.Size(92, 23)
  $urlLabel.ForeColor = $muted
  $form.Controls.Add($urlLabel)
  $urlBox = New-Object Windows.Forms.TextBox
  $urlBox.Location = New-Object Drawing.Point(114, 332); $urlBox.Size = New-Object Drawing.Size(513, 28)
  $urlBox.BorderStyle = 'FixedSingle'; $urlBox.BackColor = $surface; $urlBox.ForeColor = $white
  $form.Controls.Add($urlBox)
  $keyLabel = New-Object Windows.Forms.Label
  $keyLabel.Text = '密钥 Key：'; $keyLabel.Location = New-Object Drawing.Point(22, 376); $keyLabel.Size = New-Object Drawing.Size(92, 23)
  $keyLabel.ForeColor = $muted
  $form.Controls.Add($keyLabel)
  $keyBox = New-Object Windows.Forms.TextBox
  $keyBox.Location = New-Object Drawing.Point(114, 372); $keyBox.Size = New-Object Drawing.Size(513, 28)
  $keyBox.BorderStyle = 'FixedSingle'; $keyBox.BackColor = $surface; $keyBox.ForeColor = $white
  $keyBox.UseSystemPasswordChar = $true
  $form.Controls.Add($keyBox)
  $keyHint = New-Object Windows.Forms.Label
  $keyHint.Location = New-Object Drawing.Point(114, 405); $keyHint.Size = New-Object Drawing.Size(513, 20)
  $keyHint.ForeColor = $muted
  $form.Controls.Add($keyHint)
  $modelLabel = New-Object Windows.Forms.Label
  $modelLabel.Text = '选择模型：'; $modelLabel.Location = New-Object Drawing.Point(22, 442)
  $modelLabel.Size = New-Object Drawing.Size(92, 23); $modelLabel.ForeColor = $muted
  $form.Controls.Add($modelLabel)
  $modelBox = New-Object Windows.Forms.ComboBox
  $modelBox.DropDownStyle = 'DropDownList'; $modelBox.FlatStyle = 'Flat'
  $modelBox.Location = New-Object Drawing.Point(114, 438); $modelBox.Size = New-Object Drawing.Size(513, 28)
  $modelBox.BackColor = $surface; $modelBox.ForeColor = $white
  $form.Controls.Add($modelBox)
  foreach ($frameSpec in @(
    @{ control = $saved; x = 113; y = 290; width = 392; height = 30 },
    @{ control = $urlBox; x = 113; y = 331; width = 515; height = 30 },
    @{ control = $keyBox; x = 113; y = 371; width = 515; height = 30 },
    @{ control = $modelBox; x = 113; y = 437; width = 515; height = 30 }
  )) {
    $frame = New-Object Windows.Forms.Panel
    $frame.Location = New-Object Drawing.Point($frameSpec.x, $frameSpec.y)
    $frame.Size = New-Object Drawing.Size($frameSpec.width, $frameSpec.height)
    $frame.BackColor = [Drawing.Color]::FromArgb(48, 83, 105)
    $form.Controls.Add($frame)
    $frame.SendToBack()
    $frameSpec.control.Tag = $frame
    $frameSpec.control.Add_Enter({ $this.Tag.BackColor = $cyan })
    $frameSpec.control.Add_Leave({ $this.Tag.BackColor = [Drawing.Color]::FromArgb(48, 83, 105) })
  }
  $status = New-Object Windows.Forms.Label
  $status.Location = New-Object Drawing.Point(22, 484); $status.Size = New-Object Drawing.Size(605, 45)
  $form.Controls.Add($status)
  $testButton = New-Object Windows.Forms.Button
  $testButton.Text = '测试连通'; $testButton.Location = New-Object Drawing.Point(22, 548); $testButton.Size = New-Object Drawing.Size(130, 42)
  $testButton.FlatStyle = 'Flat'; $testButton.FlatAppearance.BorderColor = $cyan
  $testButton.BackColor = $surface; $testButton.ForeColor = $cyan; $testButton.Cursor = 'Hand'
  $form.Controls.Add($testButton)
  $nextButton = New-Object Windows.Forms.Button
  $nextButton.Text = if ($Installation) { '下一步' } else { '启动 Codex' }
  $nextButton.Location = New-Object Drawing.Point(471, 548); $nextButton.Size = New-Object Drawing.Size(156, 42)
  $nextButton.FlatStyle = 'Flat'; $nextButton.FlatAppearance.BorderSize = 0
  $nextButton.BackColor = $cyan; $nextButton.ForeColor = $navy; $nextButton.Cursor = 'Hand'
  $nextButton.Enabled = $false
  $form.Controls.Add($nextButton)
  foreach ($button in @($newButton, $testButton, $nextButton)) {
    $button.Tag = 'rest'
    $button.Add_MouseEnter({ if ($this.Enabled -and $this.Tag -ne 'hover') { $this.Tag = 'hover'; $this.Top -= 2; $this.FlatAppearance.BorderSize = 2 } })
    $button.Add_MouseLeave({ if ($this.Tag -eq 'hover') { $this.Tag = 'rest'; $this.Top += 2; $this.FlatAppearance.BorderSize = if ($this -eq $nextButton) { 0 } else { 1 } } })
    $button.Add_MouseDown({ if ($this.Enabled) { $this.BackColor = [Drawing.Color]::FromArgb(46, 158, 189) } })
    $button.Add_MouseUp({ if ($this.Enabled) { $this.BackColor = if ($this -eq $nextButton) { $cyan } else { $surface } } })
  }
  foreach ($card in @($official, $cloud, $custom)) {
    $card.Add_MouseEnter({ if (-not $this.Checked) { $this.FlatAppearance.BorderColor = $cyan } })
    $card.Add_MouseLeave({ if (-not $this.Checked) { $this.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(55, 85, 105) } })
  }
  $customProfiles = @($Registry.profiles | Where-Object { [string]$_.id -cne $script:BuiltIn })
  foreach ($profile in $customProfiles) { [void]$saved.Items.Add(([string]$profile.name + ' · ' + [string]$profile.url)) }
  $preferredIndex = 0
  if ($customProfiles.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$Registry.lastId)) {
    for ($i = 0; $i -lt $customProfiles.Count; $i++) { if ([string]$customProfiles[$i].id -ceq [string]$Registry.lastId) { $preferredIndex = $i; break } }
  }
  if ($customProfiles.Count -gt 0) { $saved.SelectedIndex = $preferredIndex }
  $script:ActiveCustomProfile = $null
  $script:NewCustom = $false
  $refresh = {
    $script:Validated = $null
    $status.Text = ''
    $testButton.Text = '测试连通'
    $testButton.ForeColor = $cyan
    $nextButton.Enabled = ($script:ChoiceKind -ceq 'openai')
    $script:PopulatingModels = $true
    $modelBox.Items.Clear()
    $script:PopulatingModels = $false
    $modelLabel.Visible = ($script:ChoiceKind -cne 'openai' -and $script:ChoiceKind -ne '')
    $modelBox.Visible = $modelLabel.Visible
    $saved.Tag.Visible = ($script:ChoiceKind -ceq 'custom')
    $urlBox.Tag.Visible = ($script:ChoiceKind -ceq 'custom')
    $keyBox.Tag.Visible = $modelLabel.Visible
    $modelBox.Tag.Visible = $modelLabel.Visible
    $savedLabel.Visible = ($script:ChoiceKind -ceq 'custom')
    $saved.Visible = ($script:ChoiceKind -ceq 'custom')
    $newButton.Visible = ($script:ChoiceKind -ceq 'custom')
    $urlLabel.Visible = ($script:ChoiceKind -ceq 'custom')
    $urlBox.Visible = ($script:ChoiceKind -ceq 'custom')
    $keyLabel.Visible = ($script:ChoiceKind -cne 'openai' -and $script:ChoiceKind -ne '')
    $keyBox.Visible = $keyLabel.Visible
    $keyHint.Visible = $keyLabel.Visible
    $testButton.Visible = $keyLabel.Visible
    $saved.Enabled = ($script:ChoiceKind -ceq 'custom')
    $newButton.Enabled = ($script:ChoiceKind -ceq 'custom')
    $urlBox.Enabled = ($script:ChoiceKind -ceq 'custom' -and $script:NewCustom)
    $keyBox.Enabled = ($script:ChoiceKind -cne 'openai')
    $testButton.Enabled = ($script:ChoiceKind -cne 'openai' -and $script:ChoiceKind -ne '')
    if ($script:ChoiceKind -ceq 'cloudforl') { $urlBox.Text = 'https://cloudforl.com/v1' }
    elseif ($script:ChoiceKind -ceq 'openai') { $urlBox.Text = ''; $keyBox.Text = '' }
    elseif ($script:ChoiceKind -ceq 'custom' -and $customProfiles.Count -gt 0 -and -not $script:NewCustom) {
      $script:ActiveCustomProfile = $customProfiles[$saved.SelectedIndex]
      $urlBox.Text = [string]$script:ActiveCustomProfile.url
      $keyBox.Text = ''
    } elseif ($script:ChoiceKind -ceq 'custom') { $urlBox.Text = ''; $keyBox.Text = '' }
    $keyHint.Text = if ($script:ChoiceKind -eq 'custom' -and $null -ne $script:ActiveCustomProfile -and -not $script:NewCustom) { '已保存密钥；留空可使用已保存的密钥重新测试。' } else { '密钥只加密保存在当前 Windows 用户下。' }
  }
  $official.Add_CheckedChanged({ if ($this.Checked) { $script:ChoiceKind = 'openai'; & $refresh } })
  $cloud.Add_CheckedChanged({ if ($this.Checked) { $script:ChoiceKind = 'cloudforl'; & $refresh } })
  $custom.Add_CheckedChanged({ if ($this.Checked) { $script:ChoiceKind = 'custom'; $script:NewCustom = ($customProfiles.Count -eq 0); & $refresh } })
  foreach ($card in @($official, $cloud, $custom)) {
    $card.Add_CheckedChanged({
      $this.BackColor = if ($this.Checked) { [Drawing.Color]::FromArgb(24, 70, 91) } else { $surface }
      $this.FlatAppearance.BorderColor = if ($this.Checked) { $cyan } else { [Drawing.Color]::FromArgb(55, 85, 105) }
    })
  }
  $saved.Add_SelectedIndexChanged({
    if ($script:ChoiceKind -eq 'custom' -and $saved.SelectedIndex -ge 0) { $script:NewCustom = $false; & $refresh }
  })
  $newButton.Add_Click({
    $script:NewCustom = $true; $script:ActiveCustomProfile = $null
    $urlBox.Enabled = $true
    $urlBox.Text = ''; $keyBox.Text = ''; $urlBox.Focus()
    $script:Validated = $null; $nextButton.Enabled = $false
    $status.Text = '请输入新的 Sub2API 平台地址和密钥。'
  })
  $keyBox.Add_TextChanged({ $script:Validated = $null; if ($script:ChoiceKind -ne 'openai') { $nextButton.Enabled = $false; $testButton.Text = '测试连通'; $modelBox.Items.Clear() } })
  $urlBox.Add_TextChanged({ $script:Validated = $null; if ($script:ChoiceKind -ne 'openai') { $nextButton.Enabled = $false; $testButton.Text = '测试连通'; $modelBox.Items.Clear() } })
  $modelBox.Add_SelectedIndexChanged({
    if (-not $script:PopulatingModels -and $script:ChoiceKind -ne 'openai') {
      $script:Validated = $null; $nextButton.Enabled = $false; $testButton.Text = '验证所选模型'
      $status.Text = '模型已更改，请重新验证所选模型的 Responses 接口。'; $status.ForeColor = $muted
    }
  })
  $testButton.Add_Click({
    $testButton.Enabled = $false; $status.Text = '正在验证 /models 和 /responses，可能产生少量 API 用量…'
    $status.ForeColor = $muted
    try {
      $url = if ($script:ChoiceKind -eq 'cloudforl') { 'https://cloudforl.com/v1' } else { Normalize-ApiUrl -InputUrl $urlBox.Text }
      $id = if ($script:ChoiceKind -eq 'cloudforl') { $script:BuiltIn } elseif ($script:NewCustom -or $null -eq $script:ActiveCustomProfile) { 'custom_' + [Guid]::NewGuid().ToString('N') } else { [string]$script:ActiveCustomProfile.id }
      $key = $keyBox.Text.Trim()
      if ([string]::IsNullOrWhiteSpace($key)) { $key = Unprotect-Secret -Id $id }
      if ($key.Length -lt 8) { throw '请输入完整密钥。' }
      if ($modelBox.Items.Count -eq 0) {
        $catalogResult = Test-Provider -BaseUrl $url -Key $key -CatalogOnly
        $script:PopulatingModels = $true
        $modelBox.Items.Clear()
        foreach ($availableModel in @($catalogResult.models)) { [void]$modelBox.Items.Add([string]$availableModel) }
        $modelBox.SelectedItem = [string]$catalogResult.model
        $script:PopulatingModels = $false
      }
      $requestedModel = [string]$modelBox.SelectedItem
      $verified = Test-Provider -BaseUrl $url -Key $key -RequestedModel $requestedModel -KnownModels @($modelBox.Items | ForEach-Object { [string]$_ })
      $name = if ($script:ChoiceKind -eq 'cloudforl') { 'CloudForl' } else { ([Uri]$url).Host }
      $script:Validated = [pscustomobject]@{ id = $id; name = $name; url = $url; model = [string]$verified.model; key = $key }
      $testButton.Text = '✓ 连通成功'; $testButton.ForeColor = [Drawing.Color]::FromArgb(95, 240, 194)
      $status.Text = [string]$verified.message; $status.ForeColor = [Drawing.Color]::FromArgb(95, 240, 194)
      $nextButton.Enabled = $true
    } catch {
      $script:Validated = $null
      $script:PopulatingModels = $false
      $testButton.Text = '✕ 测试失败'; $testButton.ForeColor = [Drawing.Color]::FromArgb(255, 117, 133)
      $status.Text = '验证失败：' + $_.Exception.Message
      $status.ForeColor = [Drawing.Color]::FromArgb(255, 117, 133)
      $nextButton.Enabled = $false
    } finally { $testButton.Enabled = $true; $key = $null }
  })
  $nextButton.Add_Click({
    try {
      if ($script:ChoiceKind -eq 'openai') {
        $form.Tag = [pscustomobject]@{ id = 'openai'; name = '官方账号登录'; url = $script:OfficialUrl; model = '' }
      } else {
        if ($null -eq $script:Validated) { throw '请先测试连通。' }
        $profile = [pscustomobject]@{ id = [string]$script:Validated.id; name = [string]$script:Validated.name; url = [string]$script:Validated.url; model = [string]$script:Validated.model }
        Protect-Secret -Id $profile.id -Secret ([string]$script:Validated.key)
        $updated = New-Object Collections.Generic.List[object]
        foreach ($old in @($Registry.profiles)) { if ([string]$old.id -cne $profile.id) { [void]$updated.Add($old) } }
        [void]$updated.Add($profile)
        $Registry.profiles = @($updated.ToArray())
        Save-Registry -Registry $Registry
        $form.Tag = $profile
      }
      $form.DialogResult = [Windows.Forms.DialogResult]::OK
      $form.Close()
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法继续', 'OK', 'Error') | Out-Null }
  })
  if (-not $Installation -and [string]$Registry.lastId -ceq 'openai') { $official.Checked = $true }
  elseif (-not $Installation -and [string]$Registry.lastId -ceq 'cloudforl') { $cloud.Checked = $true }
  elseif (-not $Installation -and $customProfiles.Count -gt 0) { $custom.Checked = $true }
  else { & $refresh }
  try {
    if ($form.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { return $form.Tag }
    return $null
  } finally { $form.Dispose() }
}

$choiceUiPath = Join-Path $PSScriptRoot 'choice-window.ps1'
if (-not (Test-Path -LiteralPath $choiceUiPath)) { throw '安装包缺少 choice-window.ps1。' }
. $choiceUiPath

try {
  if ($Mode -eq 'Select') {
    if ([string]::IsNullOrWhiteSpace($SelectionPath)) { throw '缺少选择结果路径。' }
    $registry = Get-Registry
    $selected = Show-ChoiceWindow -Registry $registry -Installation $true
    if ($null -ne $selected) { Write-AtomicText -Path $SelectionPath -Content (($selected | ConvertTo-Json -Compress) + "`r`n") }
    return
  }
  if ($Mode -eq 'Apply') {
    if (-not (Test-Path -LiteralPath $SelectionPath)) { throw '缺少安装时选择的接入方式。' }
    $selected = [IO.File]::ReadAllText($SelectionPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $registry = Get-Registry
    if ([string]$selected.id -cne 'openai' -and $null -eq (Get-Profile -Registry $registry -Id ([string]$selected.id))) { throw '所选平台未保存。' }
    Update-RouteConfig -Profile $selected -Registry $registry
    $registry.lastId = [string]$selected.id
    Save-Registry -Registry $registry
    return
  }
  if ($Mode -eq 'Launch') {
    Add-Type -AssemblyName System.Windows.Forms
    $registry = Get-Registry
    $selected = $null
    $reusePrevious = $false
    if (-not [bool]$registry.firstLaunchPending -and -not [string]::IsNullOrWhiteSpace([string]$registry.lastId)) {
      $previous = if ([string]$registry.lastId -ceq 'openai') { [pscustomobject]@{ id = 'openai'; name = '官方账号登录'; url = $script:OfficialUrl; model = '' } } else { Get-Profile -Registry $registry -Id ([string]$registry.lastId) }
      if ($null -ne $previous) {
        $answer = [Windows.Forms.MessageBox]::Show(('上一次使用：' + [string]$previous.name + "`r`n" + [string]$previous.url + "`r`n`r`n是否继续使用？"), 'Codex 接入方式', 'YesNoCancel', 'Question')
        if ($answer -eq [Windows.Forms.DialogResult]::Cancel) { return }
        if ($answer -eq [Windows.Forms.DialogResult]::Yes) { $selected = $previous; $reusePrevious = $true }
      }
    }
    if ($null -eq $selected) { $selected = Show-ChoiceWindow -Registry $registry -Installation $false }
    if ($null -eq $selected) { return }
    if ($reusePrevious) { Start-Codex; return }
    Confirm-CodexClosed
    if ([string]$selected.id -cne 'openai') {
      $stored = Get-Profile -Registry $registry -Id ([string]$selected.id)
      if ($null -eq $stored) { throw '平台配置不存在，请重新添加。' }
      $key = Unprotect-Secret -Id ([string]$selected.id)
      if ([string]::IsNullOrWhiteSpace($key)) { throw '已保存密钥不可用，请重新配置该接口。' }
      $key = $null
    }
    Update-RouteConfig -Profile $selected -Registry $registry
    $registry.lastId = [string]$selected.id
    $registry.firstLaunchPending = $false
    Save-Registry -Registry $registry
    Start-Codex
    return
  }
} catch {
  if ($Mode -eq 'Launch' -or $Mode -eq 'Select') {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show(('操作没有完成：' + $_.Exception.Message + "`r`n本地项目和会话记录未删除。"), 'Codex 接入切换失败', 'OK', 'Error') | Out-Null
  }
  throw
}
