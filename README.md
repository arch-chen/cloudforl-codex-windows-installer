# Cloudforl Codex Windows Installer

Windows 安装器与桌面接入切换器。安装器在目标设备上安装 OpenAI 官方签名的 Codex 客户端，并支持官方账号、CloudForl 固定接口和兼容 Codex Responses API 的 Sub2API 自定义接口。

## 下载

推荐使用最新版本：

- [v0.4.6 EXE](dist/Cloudforl-Codex-Windows-Installer-v0.4.6.exe)
- [v0.4.6 ZIP](dist/Cloudforl-Codex-Windows-Installer-v0.4.6.zip)
- [已安装设备无损修复 ZIP](dist/Cloudforl-Codex-无损修复-v0.1.0.zip)
- [SHA256 校验文件](dist/SHA256SUMS.txt)

`dist/` 中保留了 v0.2.0、v0.3.0、v0.3.1、v0.4.0–v0.4.6 的历史 EXE/ZIP 包，便于回滚和对比。当前最新版本会在下载阶段显示直连 MSIX 的大小、百分比和速度；微软 Store/winget 通道则显示动态等待状态和已用时间。

如果设备已经安装并开始使用，不需要卸载或重新安装，可下载“无损修复 ZIP”。解压后双击 `无损修复 Cloudforl Codex.cmd`，它只更新当前用户的启动器脚本，并把旧脚本备份到 `%LOCALAPPDATA%\Cloudforl Codex Switcher\repair-backups`；不会删除项目、会话、配置、平台列表或密钥。

## 运行要求

- Windows 10 版本 2004（内部版本 19041）或 Windows 11
- x64 或 ARM64
- 安装时需要网络访问 Microsoft Store/winget 或 OpenAI 官方签名 MSIX 下载地址

请在新设备上运行安装器；本仓库不包含开发设备的账号、密钥、项目或会话数据。第三方接入必须是兼容 Codex Responses API 的 Sub2API 系统。切换接口不会删除本地项目或会话，但旧会话能否继续取决于目标平台的模型、协议和权限兼容性。

## 从源码构建

在 Windows PowerShell 5.1 中执行：

```powershell
Set-Location .
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\build-release.ps1
```

构建脚本先运行静态测试，然后生成 ZIP 和 GUI EXE。按照项目约定，开发电脑只做静态检查和构建，不运行安装器。

## 安全提示

公开仓库中的脚本不会内置 API 密钥。用户输入的密钥仅在目标 Windows 用户下加密保存。发布前请核对 `dist/SHA256SUMS.txt`，并建议对正式分发的 EXE 进行代码签名。
