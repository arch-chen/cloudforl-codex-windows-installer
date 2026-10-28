# Runs inside installer.ps1 after its installation functions have loaded.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$switcherSource = Join-Path $script:InstallerSourceRoot 'provider-switcher.ps1'
if (-not (Test-Path -LiteralPath $switcherSource)) { throw '安装包缺少 provider-switcher.ps1。' }
$choiceUiSource = Join-Path $script:InstallerSourceRoot 'choice-window.ps1'
if (-not (Test-Path -LiteralPath $choiceUiSource)) { throw '安装包缺少 choice-window.ps1。' }
$choiceRoot = Join-Path ([IO.Path]::GetTempPath()) ('Cloudforl-Codex-Choice-' + $script:RunId)
[void](New-Item -ItemType Directory -Path $choiceRoot -Force)
$choicePath = Join-Path $choiceRoot 'selection.json'
$powershellExe = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'

function Invoke-SwitcherStep {
  param([string]$SourcePath, [string]$Step, [string]$ResultPath)
  & $powershellExe -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File $SourcePath -Mode $Step -SelectionPath $ResultPath
  if ($LASTEXITCODE -ne 0) { throw ('接入方式步骤失败：' + $Step) }
}

function Install-OfficialCodexIcon {
  param([string]$DestinationDirectory)
  $package = Get-CodexPackage
  if ($null -eq $package -or [string]::IsNullOrWhiteSpace([string]$package.InstallLocation)) {
    throw '无法找到已安装的官方 Codex 图标资源。'
  }
  $manifestPath = Join-Path $package.InstallLocation 'AppxManifest.xml'
  if (-not (Test-Path -LiteralPath $manifestPath)) { throw '官方 Codex 包缺少 AppxManifest.xml，无法提取图标。' }
  [xml]$manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)
  $visual = @($manifest.SelectNodes('//*[local-name()="VisualElements"]') | Where-Object { -not [string]::IsNullOrWhiteSpace($_.GetAttribute('Square44x44Logo')) } | Select-Object -First 1)
  if ($visual.Count -eq 0) { throw '官方 Codex 包未声明应用图标。' }
  $relativeLogo = [string]$visual[0].GetAttribute('Square44x44Logo')
  $logoPath = [IO.Path]::GetFullPath((Join-Path $package.InstallLocation ($relativeLogo.Replace('/', '\'))))
  $packageRoot = [IO.Path]::GetFullPath([string]$package.InstallLocation).TrimEnd('\') + '\'
  if (-not $logoPath.StartsWith($packageRoot, [StringComparison]::OrdinalIgnoreCase)) { throw '官方图标路径不在应用包内。' }
  $logoDirectory = Split-Path -Parent $logoPath
  $logoStem = [IO.Path]::GetFileNameWithoutExtension($logoPath)
  $candidates = @()
  foreach ($size in @(16, 32, 48, 256)) {
    $candidates += (Join-Path $logoDirectory ($logoStem + '.targetsize-' + $size + '_altform-unplated.png'))
  }
  $candidates += $logoPath
  $frames = New-Object Collections.Generic.List[object]
  foreach ($candidate in $candidates) {
    if (-not (Test-Path -LiteralPath $candidate)) { continue }
    $png = [IO.File]::ReadAllBytes($candidate)
    if ($png.Length -lt 24 -or [BitConverter]::ToString($png, 0, 8) -cne '89-50-4E-47-0D-0A-1A-0A') { continue }
    $width = ([int]$png[16] * 16777216) + ([int]$png[17] * 65536) + ([int]$png[18] * 256) + [int]$png[19]
    $height = ([int]$png[20] * 16777216) + ([int]$png[21] * 65536) + ([int]$png[22] * 256) + [int]$png[23]
    if ($width -lt 1 -or $width -gt 256 -or $height -ne $width) { continue }
    [void]$frames.Add([pscustomobject]@{ Size = $width; Bytes = $png })
  }
  if ($frames.Count -eq 0) { throw '官方 Codex 图标 PNG 无法转换为 Windows 图标。' }

  $memory = New-Object IO.MemoryStream
  $writer = New-Object IO.BinaryWriter -ArgumentList $memory
  try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$frames.Count)
    $offset = 6 + (16 * $frames.Count)
    foreach ($frame in $frames) {
      $dimension = if ($frame.Size -eq 256) { 0 } else { [int]$frame.Size }
      $writer.Write([byte]$dimension)
      $writer.Write([byte]$dimension)
      $writer.Write([byte]0)
      $writer.Write([byte]0)
      $writer.Write([uint16]1)
      $writer.Write([uint16]32)
      $writer.Write([uint32]$frame.Bytes.Length)
      $writer.Write([uint32]$offset)
      $offset += $frame.Bytes.Length
    }
    foreach ($frame in $frames) { $writer.Write([byte[]]$frame.Bytes) }
    $iconBytes = $memory.ToArray()
  } finally {
    $writer.Dispose()
    $memory.Dispose()
  }
  if (-not (Test-Path -LiteralPath $DestinationDirectory)) { [void](New-Item -ItemType Directory -Path $DestinationDirectory -Force) }
  $iconPath = Join-Path $DestinationDirectory 'Codex.ico'
  $temporaryIcon = Join-Path $DestinationDirectory ('.Codex-' + [Guid]::NewGuid().ToString('N') + '.ico.tmp')
  try {
    [IO.File]::WriteAllBytes($temporaryIcon, $iconBytes)
    [IO.File]::Copy($temporaryIcon, $iconPath, $true)
  } finally {
    if (Test-Path -LiteralPath $temporaryIcon) { Remove-Item -LiteralPath $temporaryIcon -Force -ErrorAction SilentlyContinue }
  }
  return $iconPath
}

function Install-DesktopLauncher {
  param([string]$SwitcherPath)
  $desktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
  $shortcutPath = Join-Path $desktopPath 'Codex.lnk'
  $iconPath = Install-OfficialCodexIcon -DestinationDirectory (Split-Path -Parent $SwitcherPath)
  $shell = New-Object -ComObject WScript.Shell
  if (Test-Path -LiteralPath $shortcutPath) {
    $existing = $shell.CreateShortcut($shortcutPath)
    $sameLauncher = ([string]$existing.TargetPath -ieq $powershellExe -and
      ([string]$existing.Arguments).IndexOf($SwitcherPath, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    if (-not $sameLauncher) {
      $backupDirectory = Join-Path (Split-Path -Parent $SwitcherPath) 'desktop-shortcut-backups'
      if (-not (Test-Path -LiteralPath $backupDirectory)) { [void](New-Item -ItemType Directory -Path $backupDirectory -Force) }
      $backupPath = Join-Path $backupDirectory ('Codex-original-' + (Get-Date -Format 'yyyyMMddHHmmssfff') + '.lnk')
      Copy-Item -LiteralPath $shortcutPath -Destination $backupPath -ErrorAction Stop
    }
  }
  $shortcut = $shell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = $powershellExe
  $shortcut.Arguments = ('-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $SwitcherPath + '" -Mode Launch')
  $shortcut.WorkingDirectory = Split-Path -Parent $SwitcherPath
  $shortcut.Description = '每次启动前可选择官方账号、CloudForl 或自定义 Sub2API 接口'
  $shortcut.IconLocation = $iconPath + ',0'
  $shortcut.Save()
  $oldShortcutPath = Join-Path $desktopPath 'Codex · 选择接入方式.lnk'
  if (Test-Path -LiteralPath $oldShortcutPath) {
    $oldShortcut = $shell.CreateShortcut($oldShortcutPath)
    if ([string]$oldShortcut.TargetPath -ieq $powershellExe -and
        ([string]$oldShortcut.Arguments).IndexOf($SwitcherPath, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
      $backupDirectory = Join-Path (Split-Path -Parent $SwitcherPath) 'desktop-shortcut-backups'
      if (-not (Test-Path -LiteralPath $backupDirectory)) { [void](New-Item -ItemType Directory -Path $backupDirectory -Force) }
      $backupPath = Join-Path $backupDirectory ('Codex-old-launcher-' + (Get-Date -Format 'yyyyMMddHHmmssfff') + '.lnk')
      Move-Item -LiteralPath $oldShortcutPath -Destination $backupPath -ErrorAction Stop
    }
  }
  return $shortcutPath
}

function Confirm-CodexClosedForInstall {
  $running = @(Get-Process -Name 'Codex','ChatGPT' -ErrorAction SilentlyContinue)
  if ($running.Count -eq 0) { return }
  $answer = [Windows.Forms.MessageBox]::Show('检测到 Codex 正在运行。为保护未完成输入，请先保存当前工作。是否尝试正常关闭后继续安装？', '安装前关闭 Codex', 'YesNo', 'Question')
  if ($answer -ne [Windows.Forms.DialogResult]::Yes) { throw '用户取消关闭正在运行的 Codex。' }
  foreach ($process in $running) { try { [void]$process.CloseMainWindow() } catch {} }
  $until = (Get-Date).AddSeconds(15)
  do { Start-Sleep -Milliseconds 300; $running = @(Get-Process -Name 'Codex','ChatGPT' -ErrorAction SilentlyContinue) }
  while ($running.Count -gt 0 -and (Get-Date) -lt $until)
  if ($running.Count -gt 0) { throw 'Codex 仍在运行，请手动关闭后重试；安装器没有强制终止。' }
}

try {
  Invoke-SwitcherStep -SourcePath $switcherSource -Step 'Select' -ResultPath $choicePath
  if (-not (Test-Path -LiteralPath $choicePath)) { return }
  $selectedChoice = [IO.File]::ReadAllText($choicePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
  $script:Installer.ProviderId = [string]$selectedChoice.id
  $script:Installer.ProviderName = [string]$selectedChoice.name
  $script:Installer.BaseUrl = [string]$selectedChoice.url
  $script:Installer.CredentialDirectoryName = 'Cloudforl Codex Switcher'

  $script:StatusLabel = $null
  $script:ProgressBar = $null
  $script:ProgressPercentLabel = $null
  $script:ProgressDetailLabel = $null
  $script:InstallationCompleted = $false
  $script:InstallationReady = $false
  $script:UserCancelled = $false
  $script:PermanentSwitcherPath = $null

  $form = New-Object Windows.Forms.Form
  $form.Text = 'Codex 一键安装 v0.4.6'
  $form.ClientSize = New-Object Drawing.Size(620, 435)
  $form.StartPosition = 'CenterScreen'
  $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
  $form.MaximizeBox = $false
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
    try { $_.Graphics.FillRectangle($brush, 0, 0, 620, 3) } finally { $brush.Dispose() }
  })

  $title = New-Object Windows.Forms.Label
  $title.Text = 'Codex 新机一键安装'
  $title.Font = New-Object Drawing.Font('Microsoft YaHei UI', 18, [Drawing.FontStyle]::Bold)
  $title.Location = New-Object Drawing.Point(26, 19)
  $title.Size = New-Object Drawing.Size(565, 42)
  $title.ForeColor = $white
  $form.Controls.Add($title)

  $subtitle = New-Object Windows.Forms.Label
  $subtitle.Text = ('当前接入：' + [string]$selectedChoice.name + '  ·  ' + [string]$selectedChoice.url)
  $subtitle.Location = New-Object Drawing.Point(28, 66)
  $subtitle.Size = New-Object Drawing.Size(565, 45)
  $subtitle.ForeColor = $muted
  $form.Controls.Add($subtitle)

  $script:StatusLabel = New-Object Windows.Forms.Label
  $script:StatusLabel.Text = '正在准备安装…'
  $script:StatusLabel.Location = New-Object Drawing.Point(28, 127)
  $script:StatusLabel.Size = New-Object Drawing.Size(560, 62)
  $script:StatusLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10)
  $script:StatusLabel.ForeColor = $white
  $form.Controls.Add($script:StatusLabel)

  $script:ProgressBar = New-Object Windows.Forms.ProgressBar
  $script:ProgressBar.Location = New-Object Drawing.Point(28, 187)
  $script:ProgressBar.Size = New-Object Drawing.Size(560, 17)
  $script:ProgressBar.Minimum = 0
  $script:ProgressBar.Maximum = 100
  $script:ProgressBar.Value = 4
  $script:ProgressBar.Visible = $false
  $form.Controls.Add($script:ProgressBar)
  $track = New-Object Windows.Forms.Panel
  $track.Location = New-Object Drawing.Point(28, 195)
  $track.Size = New-Object Drawing.Size(500, 10)
  $track.BackColor = $surface
  $form.Controls.Add($track)
  $fill = New-Object Windows.Forms.Panel
  $fill.Location = New-Object Drawing.Point(0, 0)
  $fill.Size = New-Object Drawing.Size(22, 10)
  $fill.BackColor = $cyan
  $track.Controls.Add($fill)
  $script:ProgressPercentLabel = New-Object Windows.Forms.Label
  $script:ProgressPercentLabel.Text = '4%'
  $script:ProgressPercentLabel.Location = New-Object Drawing.Point(535, 185)
  $script:ProgressPercentLabel.Size = New-Object Drawing.Size(53, 27)
  $script:ProgressPercentLabel.TextAlign = [Drawing.ContentAlignment]::MiddleRight
  $script:ProgressPercentLabel.ForeColor = $cyan
  $script:ProgressPercentLabel.AccessibleName = '安装步骤进度百分比'
  $form.Controls.Add($script:ProgressPercentLabel)
  $script:ProgressDetailLabel = New-Object Windows.Forms.Label
  $script:ProgressDetailLabel.Text = '正在准备下载信息…'
  $script:ProgressDetailLabel.Location = New-Object Drawing.Point(28, 208)
  $script:ProgressDetailLabel.Size = New-Object Drawing.Size(560, 20)
  $script:ProgressDetailLabel.ForeColor = $muted
  $script:ProgressDetailLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 8)
  $script:ProgressDetailLabel.AutoEllipsis = $true
  $script:ProgressDetailLabel.AccessibleName = '下载进度和速度'
  $form.Controls.Add($script:ProgressDetailLabel)
  $pulse = New-Object Windows.Forms.Timer
  $pulse.Interval = 65
  $pulse.Add_Tick({
    $targetWidth = [Math]::Max(22, [Math]::Round($track.Width * $script:ProgressBar.Value / 100))
    if ($fill.Width -lt $targetWidth) { $fill.Width = [Math]::Min($targetWidth, $fill.Width + [Math]::Max(3, [Math]::Round(($targetWidth - $fill.Width) / 4))) }
    elseif ($fill.Width -gt $targetWidth) { $fill.Width = $targetWidth }
  })
  $pulse.Start()

  $finishPanel = New-Object Windows.Forms.Panel
  $finishPanel.Location = New-Object Drawing.Point(28, 221)
  $finishPanel.Size = New-Object Drawing.Size(560, 188)
  $finishPanel.Visible = $false
  $finishPanel.BackColor = $surface
  $form.Controls.Add($finishPanel)

  $doneLabel = New-Object Windows.Forms.Label
  $doneLabel.Text = '安装完毕。点击“完成”后关闭安装窗口。'
  $doneLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 11, [Drawing.FontStyle]::Bold)
  $doneLabel.Location = New-Object Drawing.Point(0, 2)
  $doneLabel.Size = New-Object Drawing.Size(560, 31)
  $doneLabel.ForeColor = $cyan
  $finishPanel.Controls.Add($doneLabel)

  $dataHint = New-Object Windows.Forms.Label
  $dataHint.Text = '本地项目和会话目录未清理。跨平台继续旧会话仍取决于新平台是否支持对应模型和协议。'
  $dataHint.Location = New-Object Drawing.Point(0, 36)
  $dataHint.Size = New-Object Drawing.Size(550, 42)
  $dataHint.ForeColor = $muted
  $finishPanel.Controls.Add($dataHint)

  $runCheck = New-Object Windows.Forms.CheckBox
  $runCheck.Text = '安装完成后运行 Codex'
  $runCheck.Checked = $true
  $runCheck.Location = New-Object Drawing.Point(0, 82)
  $runCheck.Size = New-Object Drawing.Size(400, 26)
  $runCheck.ForeColor = $white
  $finishPanel.Controls.Add($runCheck)

  $shortcutCheck = New-Object Windows.Forms.CheckBox
  $shortcutCheck.Text = '在桌面创建“Codex”图标'
  $shortcutCheck.Checked = $true
  $shortcutCheck.Location = New-Object Drawing.Point(0, 111)
  $shortcutCheck.Size = New-Object Drawing.Size(480, 27)
  $shortcutCheck.ForeColor = $white
  $finishPanel.Controls.Add($shortcutCheck)

  $finishButton = New-Object Windows.Forms.Button
  $finishButton.Text = '完成'
  $finishButton.Location = New-Object Drawing.Point(438, 149)
  $finishButton.Size = New-Object Drawing.Size(122, 37)
  $finishButton.FlatStyle = 'Flat'; $finishButton.FlatAppearance.BorderSize = 0
  $finishButton.BackColor = $cyan; $finishButton.ForeColor = $navy; $finishButton.Cursor = 'Hand'
  $finishButton.Add_MouseEnter({ $this.Top -= 1; $this.BackColor = [Drawing.Color]::FromArgb(98, 235, 245) })
  $finishButton.Add_MouseLeave({ $this.Top += 1; $this.BackColor = $cyan })
  $finishPanel.Controls.Add($finishButton)

  $finishButton.Add_Click({
    try {
      if ($shortcutCheck.Checked) { [void](Install-DesktopLauncher -SwitcherPath $script:PermanentSwitcherPath) }
      $script:InstallationCompleted = $true
      if ($runCheck.Checked) {
        $launched = Start-CodexApplication
        if (-not $launched) { [Windows.Forms.MessageBox]::Show('Codex 已安装，但自动启动未得到 Windows 确认；请使用桌面图标启动。', '请手动启动', 'OK', 'Warning') | Out-Null }
      }
      $form.Close()
    } catch {
      [Windows.Forms.MessageBox]::Show(('完成步骤失败：' + $_.Exception.Message), '请重试', 'OK', 'Error') | Out-Null
    }
  })

  $form.Add_FormClosing({
    $pulse.Stop()
    if (-not $script:InstallationCompleted) {
      $script:UserCancelled = $true
      if ($null -ne $script:ActiveWebClient) { try { $script:ActiveWebClient.CancelAsync() } catch {} }
      if ($null -ne $script:ActiveProcess -and -not $script:ActiveProcess.HasExited) { try { Stop-Process -Id $script:ActiveProcess.Id -Force -ErrorAction SilentlyContinue } catch {} }
    }
  })

  $form.Add_Shown({
    try {
      Set-UiStatus -Text '正在检查 Windows 版本和架构…' -Progress 8
      Assert-SupportedWindows
      Confirm-CodexClosedForInstall
      Set-UiStatus -Text '正在安装或核对 OpenAI 官方 Codex 客户端…' -Progress 16
      Install-CodexApplication
      Confirm-CodexClosedForInstall

      $dataRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Cloudforl Codex Switcher'
      if (-not (Test-Path -LiteralPath $dataRoot)) { [void](New-Item -ItemType Directory -Path $dataRoot -Force) }
      $script:PermanentSwitcherPath = Join-Path $dataRoot 'provider-switcher.ps1'
      Copy-Item -LiteralPath $switcherSource -Destination $script:PermanentSwitcherPath -Force
      Copy-Item -LiteralPath $choiceUiSource -Destination (Join-Path $dataRoot 'choice-window.ps1') -Force

      Set-UiStatus -Text '正在启用简体中文并保留原有项目、会话数据…' -Progress 83
      if (-not (Ensure-CodexSimplifiedChinese)) { throw '简体中文配置未完成；请根据错误提示修复后重试。' }

      Set-UiStatus -Text '正在应用选定接入方式…' -Progress 96
      Invoke-SwitcherStep -SourcePath $script:PermanentSwitcherPath -Step 'Apply' -ResultPath $choicePath
      Set-UiStatus -Text 'Codex 安装与接入配置完毕。' -Progress 100
      $script:InstallationReady = $true
      $finishPanel.Visible = $true
    } catch {
      if ($script:UserCancelled) { return }
      Set-UiStatus -Text '自动安装未完成。' -Progress 20 -IsError
      [Windows.Forms.MessageBox]::Show(('安装遇到问题：' + $_.Exception.Message + "`r`n`r`n请修复后重新运行安装器；旧项目和会话不会被清理。"), '安装失败', 'OK', 'Error') | Out-Null
    }
  })

  [void][Windows.Forms.Application]::Run($form)
} finally {
  if (Test-Path -LiteralPath $choicePath) { Remove-Item -LiteralPath $choicePath -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $choiceRoot) { Remove-Item -LiteralPath $choiceRoot -Force -ErrorAction SilentlyContinue }
}
