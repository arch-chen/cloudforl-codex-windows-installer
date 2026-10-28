# Native Windows Forms UI for the installation and desktop provider selector.
# Loaded by provider-switcher.ps1; no network call runs before the user clicks a test button.

function Get-ChoiceColor {
  param([string]$Hex)
  return [Drawing.ColorTranslator]::FromHtml($Hex)
}

function New-ChoiceLabel {
  param([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height, [int]$Size = 9, [bool]$Bold = $false, [Drawing.Color]$Color)
  $label = New-Object Windows.Forms.Label
  $label.Text = $Text
  $label.Location = New-Object Drawing.Point($X, $Y)
  $label.Size = New-Object Drawing.Size($Width, $Height)
  $label.ForeColor = $Color
  $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
  $label.Font = New-Object Drawing.Font('Microsoft YaHei UI', $Size, $style)
  return $label
}

function Set-ChoiceButtonStyle {
  param([Windows.Forms.Button]$Button, [Drawing.Color]$Background, [Drawing.Color]$Foreground, [Drawing.Color]$Border)
  $Button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
  $Button.FlatAppearance.BorderSize = 1
  $Button.FlatAppearance.BorderColor = $Border
  $Button.BackColor = $Background
  $Button.ForeColor = $Foreground
  $Button.Cursor = [Windows.Forms.Cursors]::Hand
  $Button.Add_MouseEnter({ if ($this.Enabled) { $this.FlatAppearance.BorderSize = 2 } })
  $Button.Add_MouseLeave({ $this.FlatAppearance.BorderSize = 1 })
  $Button.Add_MouseDown({ if ($this.Enabled) { $this.Top += 1 } })
  $Button.Add_MouseUp({ if ($this.Enabled) { $this.Top -= 1 } })
}

function Get-SafeChoiceError {
  param([string]$Message)
  if ($Message -match '401|403|Unauthorized|Forbidden') { return '认证被拒绝（401/403）。请检查密钥及平台权限。' }
  if ($Message -match '404') { return '接口不存在（404）。请核对 /v1 地址及 Responses 兼容性。' }
  if ($Message -match '模型列表未包含|模型不存在|model') { return '所选模型不可用。请从列表选择其他模型或核对模型标识。' }
  if ($Message -match 'timeout|timed out|超时|cancel') { return '连接超时。请检查网络或平台状态后重试。' }
  if ($Message -match 'SSL|TLS|certificate|证书') { return 'TLS 或证书校验失败。请核对平台证书与网络环境。' }
  if ($Message -match '接口未完成|协议') { return '接口未返回有效的 Responses 完成结果，可能不兼容 Codex。' }
  if ($Message -match '5[0-9][0-9]') { return '平台服务器异常。请稍后重试。' }
  return '连接测试失败。请检查地址、密钥、模型和网络后重试。'
}

function Show-NewPlatformDialog {
  param([Windows.Forms.Form]$Owner)
  $bg = Get-ChoiceColor '#0B1019'; $card = Get-ChoiceColor '#141D29'
  $inputBg = Get-ChoiceColor '#192635'; $accent = Get-ChoiceColor '#65CDD2'
  $textColor = Get-ChoiceColor '#EEF3FA'; $muted = Get-ChoiceColor '#A8B8CA'
  $dialog = New-Object Windows.Forms.Form
  $dialog.Text = '新添加 Sub2API 平台'
  $dialog.ClientSize = New-Object Drawing.Size(560, 410)
  $dialog.StartPosition = [Windows.Forms.FormStartPosition]::CenterParent
  $dialog.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
  $dialog.MaximizeBox = $false
  $dialog.MinimizeBox = $false
  $dialog.BackColor = $bg
  $dialog.ForeColor = $textColor
  $dialog.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
  $dialog.Controls.Add((New-ChoiceLabel '新添加 Sub2API 平台' 24 20 500 33 15 $true $textColor))
  $dialog.Controls.Add((New-ChoiceLabel '平台资料会保存在当前 Windows 用户下；连接仍须返回主窗口测试。' 24 56 505 35 8 $false $muted))
  $dialog.Controls.Add((New-ChoiceLabel '平台名称' 24 96 160 20 9 $false $muted))
  $dialog.Controls.Add((New-ChoiceLabel '接口地址' 24 155 160 20 9 $false $muted))
  $dialog.Controls.Add((New-ChoiceLabel '密钥 Key' 24 214 160 20 9 $false $muted))
  $dialog.Controls.Add((New-ChoiceLabel '模型标识' 24 273 160 20 9 $false $muted))
  $nameBox = New-Object Windows.Forms.TextBox
  $urlBox = New-Object Windows.Forms.TextBox
  $keyBox = New-Object Windows.Forms.TextBox
  $modelBox = New-Object Windows.Forms.ComboBox
  $nameBox.Location = New-Object Drawing.Point(24, 118); $nameBox.Size = New-Object Drawing.Size(510, 32)
  $urlBox.Location = New-Object Drawing.Point(24, 177); $urlBox.Size = New-Object Drawing.Size(510, 32)
  $keyBox.Location = New-Object Drawing.Point(24, 236); $keyBox.Size = New-Object Drawing.Size(510, 32)
  $modelBox.Location = New-Object Drawing.Point(24, 295); $modelBox.Size = New-Object Drawing.Size(390, 32)
  $modelBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDown
  $keyBox.UseSystemPasswordChar = $true
  foreach ($field in @($nameBox,$urlBox,$keyBox,$modelBox)) {
    $field.BackColor = $inputBg; $field.ForeColor = $textColor
    $dialog.Controls.Add($field)
  }
  $fetch = New-Object Windows.Forms.Button
  $fetch.Text = '获取模型'; $fetch.Location = New-Object Drawing.Point(424, 293)
  $fetch.Size = New-Object Drawing.Size(110, 35)
  Set-ChoiceButtonStyle $fetch $card $accent $accent
  $dialog.Controls.Add($fetch)
  $message = New-ChoiceLabel '' 24 335 360 40 8 $false $muted
  $dialog.Controls.Add($message)
  $cancel = New-Object Windows.Forms.Button
  $cancel.Text = '取消'; $cancel.Location = New-Object Drawing.Point(385, 363)
  $cancel.Size = New-Object Drawing.Size(70, 36)
  Set-ChoiceButtonStyle $cancel $card $textColor (Get-ChoiceColor '#354556')
  $dialog.Controls.Add($cancel)
  $save = New-Object Windows.Forms.Button
  $save.Text = '保存并返回'; $save.Location = New-Object Drawing.Point(462, 363)
  $save.Size = New-Object Drawing.Size(95, 36)
  Set-ChoiceButtonStyle $save $accent (Get-ChoiceColor '#08242B') $accent
  $dialog.Controls.Add($save)
  $cancel.Add_Click({ $dialog.DialogResult = [Windows.Forms.DialogResult]::Cancel; $dialog.Close() })
  $dialog.CancelButton = $cancel
  $fetch.Add_Click({
    $fetch.Enabled = $false
    $message.Text = '正在读取平台模型列表…'
    try {
      $url = Normalize-ApiUrl -InputUrl $urlBox.Text
      $key = $keyBox.Text.Trim()
      if ($key.Length -lt 8) { throw '请先填写完整密钥。' }
      $catalog = Test-Provider -BaseUrl $url -Key $key -CatalogOnly
      $modelBox.Items.Clear()
      foreach ($model in @($catalog.models)) { [void]$modelBox.Items.Add([string]$model) }
      $modelBox.Text = [string]$catalog.model
      $message.Text = ('发现 ' + $modelBox.Items.Count + ' 个模型，已预选 ' + $catalog.model + '；返回主窗口仍需测试。')
      $message.ForeColor = $accent
    } catch {
      $message.Text = Get-SafeChoiceError -Message $_.Exception.Message
      $message.ForeColor = Get-ChoiceColor '#F2A9A9'
    } finally { $fetch.Enabled = $true; $key = $null }
  })
  $save.Add_Click({
    try {
      $name = $nameBox.Text.Trim()
      if ([string]::IsNullOrWhiteSpace($name)) { throw '请输入平台名称。' }
      $url = Normalize-ApiUrl -InputUrl $urlBox.Text
      $key = $keyBox.Text.Trim()
      if ($key.Length -lt 8) { throw '请输入完整密钥。' }
      $model = $modelBox.Text.Trim()
      if ([string]::IsNullOrWhiteSpace($model)) { throw '请输入或选择模型标识。' }
      $dialog.Tag = [pscustomobject]@{ id = 'custom_' + [Guid]::NewGuid().ToString('N'); name = $name; url = $url; model = $model; key = $key }
      $dialog.DialogResult = [Windows.Forms.DialogResult]::OK
      $dialog.Close()
    } catch {
      $message.Text = $_.Exception.Message
      $message.ForeColor = Get-ChoiceColor '#F2A9A9'
    }
  })
  try {
    if ($dialog.ShowDialog($Owner) -eq [Windows.Forms.DialogResult]::OK) { return $dialog.Tag }
    return $null
  } finally { $keyBox.Clear(); $dialog.Dispose() }
}

function Show-ChoiceWindow {
  param($Registry, [bool]$Installation)
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  [Windows.Forms.Application]::EnableVisualStyles()
  $bg = Get-ChoiceColor '#0B1019'; $card = Get-ChoiceColor '#141D29'
  $configBg = Get-ChoiceColor '#111A26'; $inputBg = Get-ChoiceColor '#192635'
  $accent = Get-ChoiceColor '#65CDD2'; $textColor = Get-ChoiceColor '#EEF3FA'
  $muted = Get-ChoiceColor '#A8B8CA'; $dim = Get-ChoiceColor '#8195A8'
  $border = Get-ChoiceColor '#2A3848'
  $script:ChoiceKind = 'custom'
  $script:ChoiceInstallationMode = [bool]$Installation
  $script:Validated = $null
  $script:ActiveCustomProfile = $null
  $script:LaunchSavedProfile = $null
  $script:PendingNewProfileId = ''
  $script:SavedReady = $false
  $script:UiUpdating = $false
  $script:UiTesting = $false
  $form = New-Object Windows.Forms.Form
  $form.Text = if ($script:ChoiceInstallationMode) { 'Codex 安装 v0.4.6 · 选择接入方式' } else { 'Codex 启动 v0.4.6 · 选择接入方式' }
  $form.ClientSize = New-Object Drawing.Size(900, 728)
  $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
  $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
  $form.MaximizeBox = $false
  $form.BackColor = $bg; $form.ForeColor = $textColor
  $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
  $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
  $top = New-Object Windows.Forms.Panel
  $top.Location = New-Object Drawing.Point(0,0); $top.Size = New-Object Drawing.Size(900,78)
  $top.BackColor = $card; $form.Controls.Add($top)
  $top.Controls.Add((New-ChoiceLabel 'Codex 安装助手 v0.4.6' 48 20 340 30 12 $true $textColor))
  $step = New-ChoiceLabel '步骤 02 / 03' 750 21 102 25 9 $false $muted
  $step.TextAlign = [Drawing.ContentAlignment]::MiddleRight; $top.Controls.Add($step)
  foreach ($part in 0..2) {
    $segment = New-Object Windows.Forms.Panel
    $segment.Location = New-Object Drawing.Point((48 + $part * 272), 68)
    $segment.Size = New-Object Drawing.Size(260,3)
    $segment.BackColor = if ($part -lt 2) { $accent } else { $border }
    $top.Controls.Add($segment)
  }
  $footer = New-Object Windows.Forms.Panel
  $footer.Location = New-Object Drawing.Point(0,650); $footer.Size = New-Object Drawing.Size(900,78)
  $footer.BackColor = $bg; $form.Controls.Add($footer)
  $separator = New-Object Windows.Forms.Panel
  $separator.Location = New-Object Drawing.Point(0,0); $separator.Size = New-Object Drawing.Size(900,1)
  $separator.BackColor = $border; $footer.Controls.Add($separator)
  $status = New-ChoiceLabel '请选择接入方式并完成配置。' 48 18 510 48 9 $false $muted
  $status.AccessibleName = '连接测试状态'; $footer.Controls.Add($status)
  $testButton = New-Object Windows.Forms.Button
  $testButton.Text = '测试连通'; $testButton.Location = New-Object Drawing.Point(565,18)
  $testButton.Size = New-Object Drawing.Size(132,42)
  Set-ChoiceButtonStyle $testButton $inputBg $textColor (Get-ChoiceColor '#354556')
  $footer.Controls.Add($testButton)
  $nextButton = New-Object Windows.Forms.Button
  $nextButton.Text = if ($Installation) { '下一步 →' } else { '启动 Codex →' }
  $nextButton.Location = New-Object Drawing.Point(709,18); $nextButton.Size = New-Object Drawing.Size(143,42)
  Set-ChoiceButtonStyle $nextButton $accent (Get-ChoiceColor '#08242B') $accent
  $nextButton.Enabled = $false; $footer.Controls.Add($nextButton)
  $main = New-Object Windows.Forms.Panel
  $main.Location = New-Object Drawing.Point(0,78); $main.Size = New-Object Drawing.Size(900,572)
  $main.BackColor = $bg; $main.AutoScroll = $true
  $main.AutoScrollMinSize = New-Object Drawing.Size(860,560)
  $form.Controls.Add($main)
  $main.Controls.Add((New-ChoiceLabel '选择 Codex 接入方式' 48 18 620 45 20 $true $textColor))
  $main.Controls.Add((New-ChoiceLabel '连接你的 Codex 服务。选择一种接入方式，完成配置后即可测试连接。' 48 61 804 25 9 $false $muted))
  $warning = New-Object Windows.Forms.Panel
  $warning.Location = New-Object Drawing.Point(48,91); $warning.Size = New-Object Drawing.Size(804,49)
  $warning.BackColor = Get-ChoiceColor '#282419'; $main.Controls.Add($warning)
  $warning.Controls.Add((New-ChoiceLabel '注意' 12 13 42 22 9 $true (Get-ChoiceColor '#E6BB76')))
  $warning.Controls.Add((New-ChoiceLabel '第三方必须是兼容 Codex Responses API 的 Sub2API 系统。切换后旧会话内容可能发送给新平台；本地项目和记录不会删除。' 57 7 733 38 8 $false (Get-ChoiceColor '#DDC596')))
  $main.Controls.Add((New-ChoiceLabel '接入来源' 48 151 230 22 9 $true $textColor))
  $choiceHint = New-ChoiceLabel '请选择一项' 738 151 114 22 8 $false $dim
  $choiceHint.TextAlign = [Drawing.ContentAlignment]::MiddleRight; $main.Controls.Add($choiceHint)
  $cards = @()
  $cardNames = @('官方账号登录','CloudForl 平台','自定义接入')
  $cardSubtitles = @('通过官方客户端完成授权','使用平台提供的接口服务','连接已有或新的 Sub2API 平台')
  $cardIcons = @('◎','↗','⌘')
  for ($i = 0; $i -lt 3; $i++) {
    $radio = New-Object Windows.Forms.RadioButton
    $radio.Appearance = [Windows.Forms.Appearance]::Button
    $radio.Text = ''
    $radio.Location = New-Object Drawing.Point((48 + $i * 272), 180)
    $radio.Size = New-Object Drawing.Size(260,116)
    $radio.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $radio.FlatAppearance.BorderSize = 1
    $radio.FlatAppearance.BorderColor = $border
    $radio.FlatAppearance.CheckedBackColor = Get-ChoiceColor '#152F3A'
    $radio.FlatAppearance.MouseOverBackColor = Get-ChoiceColor '#1B2C38'
    $radio.FlatAppearance.MouseDownBackColor = Get-ChoiceColor '#20424B'
    $radio.UseVisualStyleBackColor = $false
    $radio.BackColor = $card; $radio.ForeColor = $textColor
    $radio.Cursor = [Windows.Forms.Cursors]::Hand
    $radio.AccessibleName = $cardNames[$i]
    $main.Controls.Add($radio)
    $icon = New-ChoiceLabel $cardIcons[$i] 16 14 34 31 14 $true $accent
    $icon.BackColor = Get-ChoiceColor '#203641'
    $icon.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
    $radio.Controls.Add($icon)
    $title = New-ChoiceLabel $cardNames[$i] 16 51 228 25 10 $true $textColor
    $radio.Controls.Add($title)
    $hint = New-ChoiceLabel $cardSubtitles[$i] 16 81 228 25 8 $false $muted
    $radio.Controls.Add($hint)
    $indicator = New-ChoiceLabel '○' 225 16 24 24 13 $false $dim
    $radio.Controls.Add($indicator)
    foreach ($child in @($icon,$title,$hint,$indicator)) {
      $child.Tag = $radio
      $child.Add_Click({ $this.Tag.Checked = $true })
    }
    $radio.Tag = $indicator
    $radio.Add_MouseEnter({ if (-not $this.Checked) { $this.FlatAppearance.BorderColor = $accent } })
    $radio.Add_MouseLeave({ if (-not $this.Checked) { $this.FlatAppearance.BorderColor = $border } })
    $radio.Add_KeyDown({ if ($_.KeyCode -eq [Windows.Forms.Keys]::Enter) { $this.Checked = $true } })
    $cards += $radio
  }
  $config = New-Object Windows.Forms.Panel
  $config.Location = New-Object Drawing.Point(48,306); $config.Size = New-Object Drawing.Size(804,252)
  $config.BackColor = $configBg; $config.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
  $main.Controls.Add($config)
  $configTitle = New-ChoiceLabel '配置自定义接入' 20 12 760 26 10 $true $textColor
  $config.Controls.Add($configTitle)
  $configHint = New-ChoiceLabel '填写平台信息并选择模型；密钥仅用于接入配置。' 20 38 760 23 8 $false $muted
  $config.Controls.Add($configHint)
  $savedLabel = New-ChoiceLabel '已添加平台' 20 65 200 20 8 $false $muted
  $config.Controls.Add($savedLabel)
  $saved = New-Object Windows.Forms.ComboBox
  $saved.Location = New-Object Drawing.Point(20,86); $saved.Size = New-Object Drawing.Size(650,35)
  $saved.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
  $saved.FlatStyle = [Windows.Forms.FlatStyle]::Flat
  $saved.BackColor = $inputBg; $saved.ForeColor = $textColor
  $saved.AccessibleName = '已添加平台'; $config.Controls.Add($saved)
  $newButton = New-Object Windows.Forms.Button
  $newButton.Text = '新添加'; $newButton.Location = New-Object Drawing.Point(682,84)
  $newButton.Size = New-Object Drawing.Size(100,38)
  Set-ChoiceButtonStyle $newButton (Get-ChoiceColor '#1C404B') $accent (Get-ChoiceColor '#45616B')
  $config.Controls.Add($newButton)
  $urlLabel = New-ChoiceLabel '接口地址' 20 131 370 20 8 $false $muted
  $keyLabel = New-ChoiceLabel '密钥 Key' 408 131 374 20 8 $false $muted
  $config.Controls.Add($urlLabel); $config.Controls.Add($keyLabel)
  $urlBox = New-Object Windows.Forms.TextBox
  $urlBox.Location = New-Object Drawing.Point(20,152); $urlBox.Size = New-Object Drawing.Size(370,35)
  $urlBox.BackColor = $inputBg; $urlBox.ForeColor = $textColor
  $urlBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
  $urlBox.AccessibleName = '接口地址'; $config.Controls.Add($urlBox)
  $keyBox = New-Object Windows.Forms.TextBox
  $keyBox.Location = New-Object Drawing.Point(408,152); $keyBox.Size = New-Object Drawing.Size(374,35)
  $keyBox.BackColor = $inputBg; $keyBox.ForeColor = $textColor
  $keyBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
  $keyBox.UseSystemPasswordChar = $true
  $keyBox.AccessibleName = '密钥 Key'; $config.Controls.Add($keyBox)
  $modelLabel = New-ChoiceLabel '选择模型' 20 193 300 20 8 $false $muted
  $config.Controls.Add($modelLabel)
  $modelBox = New-Object Windows.Forms.ComboBox
  $modelBox.Location = New-Object Drawing.Point(20,209); $modelBox.Size = New-Object Drawing.Size(762,35)
  $modelBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDown
  $modelBox.FlatStyle = [Windows.Forms.FlatStyle]::Flat
  $modelBox.BackColor = $inputBg; $modelBox.ForeColor = $textColor
  $modelBox.AccessibleName = '选择模型，也可输入其他模型标识'
  $config.Controls.Add($modelBox)
  $urlPlaceholder = New-ChoiceLabel 'https://example.com/v1' 29 159 340 22 8 $false $dim
  $urlPlaceholder.BackColor = $inputBg; $config.Controls.Add($urlPlaceholder)
  $urlPlaceholder.Add_Click({ $urlBox.Focus() })
  $keyPlaceholder = New-ChoiceLabel '输入密钥（可留空使用已保存密钥）' 417 159 345 22 8 $false $dim
  $keyPlaceholder.BackColor = $inputBg; $config.Controls.Add($keyPlaceholder)
  $keyPlaceholder.Add_Click({ $keyBox.Focus() })
  $modelPlaceholder = New-ChoiceLabel '请选择模型或输入其他模型标识' 29 216 640 22 8 $false $dim
  $modelPlaceholder.BackColor = $inputBg; $config.Controls.Add($modelPlaceholder)
  $modelPlaceholder.Add_Click({ $modelBox.Focus() })
  $customProfiles = New-Object Collections.Generic.List[object]
  if (-not $Installation) {
    foreach ($profile in @($Registry.profiles | Where-Object { [string]$_.id -cne $script:BuiltIn })) {
      [void]$customProfiles.Add($profile)
      [void]$saved.Items.Add(([string]$profile.name + ' · ' + [string]$profile.url))
    }
    if ($customProfiles.Count -eq 0) { [void]$saved.Items.Add('暂无已添加平台') }
  } else {
    # An installer run always starts with an empty custom endpoint. Existing profiles
    # remain on disk for the desktop launcher, but are never preselected here.
    foreach ($control in @($savedLabel,$saved,$newButton)) { $control.Visible = $false }
    $urlLabel.Top = 71; $keyLabel.Top = 71
    $urlBox.Top = 92; $keyBox.Top = 92
    $urlPlaceholder.Top = 99; $keyPlaceholder.Top = 99
    $modelLabel.Top = 137; $modelBox.Top = 153; $modelPlaceholder.Top = 160
    $keyPlaceholder.Text = '请输入密钥'
  }
  $updatePlaceholders = {
    $urlPlaceholder.Visible = ($script:ChoiceKind -ceq 'custom' -and [string]::IsNullOrWhiteSpace($urlBox.Text) -and -not $urlBox.Focused)
    $keyPlaceholder.Visible = ($script:ChoiceKind -cne 'openai' -and [string]::IsNullOrWhiteSpace($keyBox.Text) -and -not $keyBox.Focused)
    $modelPlaceholder.Visible = ($script:ChoiceKind -cne 'openai' -and [string]::IsNullOrWhiteSpace($modelBox.Text) -and -not $modelBox.Focused)
  }
  $invalidate = {
    $script:Validated = $null
    $script:SavedReady = (-not $script:ChoiceInstallationMode -and
      $null -ne $script:LaunchSavedProfile -and
      ($null -eq $script:LaunchSavedProfile.PSObject.Properties['verified'] -or $script:LaunchSavedProfile.verified -eq $true) -and
      [string]$script:LaunchSavedProfile.id -cne $script:PendingNewProfileId -and
      -not [string]::IsNullOrWhiteSpace([string]$script:LaunchSavedProfile.model) -and
      [string]$urlBox.Text -ceq [string]$script:LaunchSavedProfile.url -and
      [string]$modelBox.Text -ceq [string]$script:LaunchSavedProfile.model -and
      [string]::IsNullOrWhiteSpace($keyBox.Text))
    $nextButton.Enabled = ($script:ChoiceKind -ceq 'openai' -or $script:SavedReady)
    $testButton.Visible = ($script:ChoiceKind -cne 'openai' -and -not $script:SavedReady)
    $status.Text = if ($script:ChoiceKind -ceq 'openai') {
      if ($script:ChoiceInstallationMode) { '继续安装后，由官方客户端完成登录；此处不验证官方账号。' } else { '点击启动后，由官方客户端完成登录。' }
    } elseif ($script:SavedReady) { '已保存的接入配置未改动，可直接启动 Codex。' }
    else { '新接入或配置已修改，请测试连通后继续。' }
    $status.ForeColor = $muted
    $testButton.Text = '测试连通'
  }
  $refresh = {
    $script:UiUpdating = $true
    $keyBox.Clear()
    $modelBox.Items.Clear()
    $script:ActiveCustomProfile = $null
    $script:LaunchSavedProfile = $null
    $isCustom = $script:ChoiceKind -ceq 'custom'
    $isOfficial = $script:ChoiceKind -ceq 'openai'
    $savedLabel.Visible = ($isCustom -and -not $script:ChoiceInstallationMode)
    $saved.Visible = ($isCustom -and -not $script:ChoiceInstallationMode)
    $newButton.Visible = ($isCustom -and -not $script:ChoiceInstallationMode)
    $urlBox.ReadOnly = -not $isCustom
    $keyLabel.Visible = -not $isOfficial; $keyBox.Visible = -not $isOfficial
    $modelLabel.Visible = -not $isOfficial; $modelBox.Visible = -not $isOfficial
    $testButton.Visible = -not $isOfficial
    if ($isOfficial) {
      $configTitle.Text = '官方账号登录'
      $configHint.Text = '登录由官方客户端完成；安装器不会收集官方密码。'
      $urlBox.Text = $script:OfficialUrl
      $urlLabel.Text = '官方服务地址（只读说明）'
    } elseif ($script:ChoiceKind -ceq 'cloudforl') {
      $configTitle.Text = '配置 CloudForl 平台'
      $configHint.Text = '固定接入地址；输入密钥后获取模型并测试连通。'
      $urlBox.Text = 'https://cloudforl.com/v1'
      $urlLabel.Text = '接口地址（只读）'
      if (-not $script:ChoiceInstallationMode) {
        $script:LaunchSavedProfile = Get-Profile -Registry $Registry -Id $script:BuiltIn
        if ($null -ne $script:LaunchSavedProfile) {
          $modelBox.Text = [string]$script:LaunchSavedProfile.model
          $configHint.Text = '已保存配置可直接启动；修改密钥或模型后需重新测试。'
        }
      }
    } else {
      $configTitle.Text = '配置自定义接入'
      $configHint.Text = if ($script:ChoiceInstallationMode) { '请自行填写接口地址和密钥；不会预设第三方接口。' } else { '选择已添加的平台，或输入地址和密钥后新建接入。' }
      $urlLabel.Text = '接口地址'
      $urlBox.Text = ''
      if ($saved.SelectedIndex -ge 0 -and $saved.SelectedIndex -lt $customProfiles.Count) {
        $script:ActiveCustomProfile = $customProfiles[$saved.SelectedIndex]
        $script:LaunchSavedProfile = $script:ActiveCustomProfile
        $urlBox.Text = [string]$script:ActiveCustomProfile.url
        $modelBox.Text = [string]$script:ActiveCustomProfile.model
        $configHint.Text = '已保存配置可直接启动；修改地址、密钥或模型后需重新测试。'
      }
    }
    $script:UiUpdating = $false
    & $invalidate
    & $updatePlaceholders
  }
  for ($i = 0; $i -lt 3; $i++) {
    $cards[$i].Add_CheckedChanged({
      if (-not $this.Checked) { return }
      for ($j = 0; $j -lt $cards.Count; $j++) {
        $cards[$j].BackColor = if ($cards[$j].Checked) { Get-ChoiceColor '#152F3A' } else { $card }
        $cards[$j].FlatAppearance.BorderColor = if ($cards[$j].Checked) { $accent } else { $border }
        $cards[$j].Tag.Text = if ($cards[$j].Checked) { '◉' } else { '○' }
        $cards[$j].Tag.ForeColor = if ($cards[$j].Checked) { $accent } else { $dim }
      }
      $script:ChoiceKind = @('openai','cloudforl','custom')[[Array]::IndexOf($cards, $this)]
      & $refresh
    })
  }
  $saved.Add_SelectedIndexChanged({ if (-not $script:UiUpdating -and $script:ChoiceKind -ceq 'custom') { & $refresh } })
  foreach ($field in @($urlBox,$keyBox,$modelBox)) {
    $field.Add_TextChanged({ & $updatePlaceholders; if (-not $script:UiUpdating -and $script:ChoiceKind -cne 'openai') { & $invalidate } })
    $field.Add_Enter({ & $updatePlaceholders })
    $field.Add_Leave({ & $updatePlaceholders })
  }
  $newButton.Add_Click({
    $draft = Show-NewPlatformDialog -Owner $form
    if ($null -eq $draft) { $newButton.Focus(); return }
    try {
      Protect-Secret -Id ([string]$draft.id) -Secret ([string]$draft.key)
      $profile = [pscustomobject]@{ id = [string]$draft.id; name = [string]$draft.name; url = [string]$draft.url; model = [string]$draft.model; verified = $false }
      $updated = New-Object Collections.Generic.List[object]
      foreach ($old in @($Registry.profiles)) { [void]$updated.Add($old) }
      [void]$updated.Add($profile)
      $Registry.profiles = @($updated.ToArray())
      Save-Registry -Registry $Registry
      $script:PendingNewProfileId = [string]$profile.id
      $script:UiUpdating = $true
      if ($customProfiles.Count -eq 0) { $saved.Items.Clear() }
      [void]$customProfiles.Add($profile)
      [void]$saved.Items.Add(([string]$profile.name + ' · ' + [string]$profile.url))
      $saved.SelectedIndex = $customProfiles.Count - 1
      $script:UiUpdating = $false
      & $refresh
      $status.Text = '平台已保存；请测试连通后继续。'
    } catch {
      $script:UiUpdating = $false
      $status.Text = '平台保存失败；请检查当前用户目录权限后重试。'
      $status.ForeColor = Get-ChoiceColor '#F2A9A9'
    } finally { $draft.key = ''; $draft = $null }
  })
  $testButton.Add_Click({
    if ($script:UiTesting) { return }
    $script:UiTesting = $true
    $script:Validated = $null
    $nextButton.Enabled = $false
    $testButton.Enabled = $false
    $testButton.Text = '测试中…'
    $status.Text = '正在检查模型和 Responses 接口；可能产生少量 API 用量。'
    $status.ForeColor = $muted
    try {
      $kind = $script:ChoiceKind
      $url = if ($kind -ceq 'cloudforl') { 'https://cloudforl.com/v1' } else { Normalize-ApiUrl -InputUrl $urlBox.Text }
      $profile = if ($kind -ceq 'custom') { $script:ActiveCustomProfile } else { $null }
      $id = if ($kind -ceq 'cloudforl') { $script:BuiltIn } elseif ($null -ne $profile) { [string]$profile.id } else { 'custom_' + [Guid]::NewGuid().ToString('N') }
      $keyInput = $keyBox.Text.Trim()
      $key = if ($keyInput.Length -gt 0) { $keyInput } else { Unprotect-Secret -Id $id }
      if ($key.Length -lt 8) { throw '请输入完整密钥。' }
      $manualModel = $modelBox.Text.Trim()
      $before = $kind + '|' + $urlBox.Text + '|' + $keyBox.Text + '|' + $modelBox.Text
      $catalog = Test-Provider -BaseUrl $url -Key $key -CatalogOnly
      if ($before -cne ($script:ChoiceKind + '|' + $urlBox.Text + '|' + $keyBox.Text + '|' + $modelBox.Text)) { throw '配置已变化，请重新测试。' }
      $script:UiUpdating = $true
      $modelBox.Items.Clear()
      foreach ($candidate in @($catalog.models)) { [void]$modelBox.Items.Add([string]$candidate) }
      $modelBox.Text = $manualModel
      $script:UiUpdating = $false
      $candidates = if ([string]::IsNullOrWhiteSpace($manualModel)) {
        @(Get-CodexTestModels -AvailableModels @($catalog.models) | Select-Object -First 3)
      } else { @($manualModel) }
      if ($candidates.Count -eq 0) { throw '模型列表没有适合 Codex 的通用 GPT 模型；请联系平台确认 Responses 模型支持情况。' }
      $verified = $null
      $lastError = $null
      foreach ($candidate in $candidates) {
        $script:UiUpdating = $true
        $modelBox.Text = [string]$candidate
        $script:UiUpdating = $false
        $before = $kind + '|' + $urlBox.Text + '|' + $keyBox.Text + '|' + $modelBox.Text
        $status.Text = ('已读取 ' + $modelBox.Items.Count + ' 个模型，正在验证 ' + $candidate + ' 的 Responses 接口…')
        try {
          $verified = Test-Provider -BaseUrl $url -Key $key -RequestedModel ([string]$candidate) -KnownModels @($modelBox.Items | ForEach-Object { [string]$_ })
          if ($before -cne ($script:ChoiceKind + '|' + $urlBox.Text + '|' + $keyBox.Text + '|' + $modelBox.Text)) { throw '配置已变化，请重新测试。' }
          break
        } catch {
          if ($before -cne ($script:ChoiceKind + '|' + $urlBox.Text + '|' + $keyBox.Text + '|' + $modelBox.Text)) { throw '配置已变化，请重新测试。' }
          $lastError = $_.Exception.Message
          if ($manualModel -or $lastError -match '401|403|404') { throw }
        }
      }
      if ($null -eq $verified) { throw ('已自动尝试 ' + $candidates.Count + ' 个模型，均未通过 Responses 测试。' + (Get-SafeChoiceError -Message $lastError)) }
      $name = if ($kind -ceq 'cloudforl') { 'CloudForl' } elseif ($null -ne $profile) { [string]$profile.name } else { ([Uri]$url).Host }
      $script:Validated = [pscustomobject]@{ id = $id; name = $name; url = $url; model = [string]$verified.model; key = $key; fingerprint = $before }
      $status.Text = ('✓ 已验证 ' + $verified.model + ' 的 Responses 接口；列表共 ' + $modelBox.Items.Count + ' 项。')
      $status.ForeColor = Get-ChoiceColor '#9ED6D1'
      $testButton.Text = '✓ 连通成功'
      $nextButton.Enabled = $true
    } catch {
      $script:Validated = $null
      $script:UiUpdating = $false
      $message = [string]$_.Exception.Message
      $status.Text = if ($message -match '接口地址|密钥|配置已变化|已自动尝试|模型列表没有') { $message } else { Get-SafeChoiceError -Message $message }
      $status.ForeColor = Get-ChoiceColor '#F2A9A9'
      $testButton.Text = '重新测试'
      $nextButton.Enabled = $false
    } finally {
      $script:UiTesting = $false
      $testButton.Enabled = $true
      if ($testButton.Text -eq '测试中…') { $testButton.Text = '重新测试' }
      $key = $null
    }
  })
  $nextButton.Add_Click({
    try {
      if ($script:ChoiceKind -ceq 'openai') {
        $form.Tag = [pscustomobject]@{ id = 'openai'; name = '官方账号登录'; url = $script:OfficialUrl; model = '' }
      } elseif ($script:SavedReady) {
        $item = $script:LaunchSavedProfile
        try {
          $storedKey = Unprotect-Secret -Id ([string]$item.id)
          if ([string]::IsNullOrWhiteSpace($storedKey)) { throw '密钥为空。' }
        } catch { throw '已保存密钥不可用，请输入新密钥并测试连通。' }
        finally { $storedKey = $null }
        $form.Tag = $item
      } else {
        if ($null -eq $script:Validated) { throw '请先完成所选模型的连通测试。' }
        $current = $script:ChoiceKind + '|' + $urlBox.Text + '|' + $keyBox.Text + '|' + $modelBox.Text
        if ($current -cne [string]$script:Validated.fingerprint) { throw '配置已变化，请重新测试。' }
        $item = [pscustomobject]@{ id = [string]$script:Validated.id; name = [string]$script:Validated.name; url = [string]$script:Validated.url; model = [string]$script:Validated.model; verified = $true }
        Protect-Secret -Id $item.id -Secret ([string]$script:Validated.key)
        $updated = New-Object Collections.Generic.List[object]
        foreach ($old in @($Registry.profiles)) { if ([string]$old.id -cne $item.id) { [void]$updated.Add($old) } }
        [void]$updated.Add($item)
        $Registry.profiles = @($updated.ToArray())
        Save-Registry -Registry $Registry
        $form.Tag = $item
      }
      $form.DialogResult = [Windows.Forms.DialogResult]::OK
      $form.Close()
    } catch {
      $status.Text = [string]$_.Exception.Message
      $status.ForeColor = Get-ChoiceColor '#F2A9A9'
      $nextButton.Enabled = $false
    }
  })
  $form.Add_FormClosing({ $keyBox.Clear(); $script:Validated = $null })
  $form.Add_Shown({
    $work = [Windows.Forms.Screen]::FromControl($form).WorkingArea
    if ($form.Width -gt $work.Width - 24) { $form.Width = [Math]::Max(400, $work.Width - 24) }
    if ($form.Height -gt $work.Height - 24) { $form.Height = [Math]::Max(450, $work.Height - 24) }
    $width = $form.ClientSize.Width
    if ($width -lt 620) {
      $footer.Height = 112
      $status.Left = 20; $status.Top = 7; $status.Width = $width - 40; $status.Height = 42
      $testButton.Top = 59; $nextButton.Top = 59
    }
    $top.Width = $width; $footer.Width = $width; $separator.Width = $width
    $main.Width = $width
    $footer.Top = $form.ClientSize.Height - $footer.Height
    $main.Height = $footer.Top - $main.Top
    $step.Left = [Math]::Max(290, $width - 150)
    $rightMargin = if ($width -lt 620) { 20 } else { 48 }
    $nextButton.Left = $width - $rightMargin - $nextButton.Width
    $testButton.Left = $nextButton.Left - 12 - $testButton.Width
    if ($width -ge 620) { $status.Width = [Math]::Max(160, $testButton.Left - $status.Left - 14) }
    $form.Left = $work.Left + [Math]::Max(0, [Math]::Floor(($work.Width - $form.Width) / 2))
    $form.Top = $work.Top + [Math]::Max(0, [Math]::Floor(($work.Height - $form.Height) / 2))
  })
  if (-not $Installation -and [string]$Registry.lastId -ceq 'openai') { $cards[0].Checked = $true }
  elseif (-not $Installation -and [string]$Registry.lastId -ceq 'cloudforl') { $cards[1].Checked = $true }
  else {
    if (-not $Installation -and $customProfiles.Count -gt 0) {
      for ($i = 0; $i -lt $customProfiles.Count; $i++) {
        if ([string]$customProfiles[$i].id -ceq [string]$Registry.lastId) { $saved.SelectedIndex = $i; break }
      }
      if ($saved.SelectedIndex -lt 0) { $saved.SelectedIndex = 0 }
    }
    $cards[2].Checked = $true
  }
  try {
    if ($form.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { return $form.Tag }
    return $null
  } finally { $form.Dispose() }
}
