using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Cloudforl Codex Windows Installer")]
[assembly: AssemblyDescription("Cloudforl Codex multi-provider installer for Windows")]
[assembly: AssemblyCompany("Cloudforl")]
[assembly: AssemblyProduct("Cloudforl Codex Windows Installer")]
[assembly: AssemblyVersion("__ASSEMBLY_VERSION__")]
[assembly: AssemblyFileVersion("__ASSEMBLY_VERSION__")]

namespace Cloudforl.CodexInstaller
{
    internal static class Program
    {
        private const string ProductName = "Cloudforl Codex 多接入安装器";
        private const string Version = "__VERSION__";
        private const string PayloadResourceName = "Cloudforl.CodexInstaller.payload.zip";
        private const string PayloadSha256 = "__PAYLOAD_SHA256__";
        private const string MutexName = "Local\\Cloudforl-Codex-Windows-Installer";

        [STAThread]
        private static void Main()
        {
            bool ownsMutex = false;
            Mutex installerMutex = null;
            Form preparingWindow = null;
            string extractionDirectory = null;

            try
            {
                installerMutex = new Mutex(true, MutexName, out ownsMutex);
                if (!ownsMutex)
                {
                    ShowMessage("安装器已在运行。请完成或关闭当前安装窗口后再试。", MessageBoxIcon.Information);
                    return;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                preparingWindow = CreatePreparingWindow();
                preparingWindow.Show();
                Application.DoEvents();

                SetPreparingMessage(preparingWindow, "正在校验并准备安装文件，请稍候...");
                extractionDirectory = CreateExtractionDirectory();
                ExtractPayload(extractionDirectory);
                ValidatePayload(extractionDirectory);

                SetPreparingMessage(preparingWindow, "正在启动安装界面...");
                Process installerProcess = StartInstaller(extractionDirectory);
                preparingWindow.Close();
                preparingWindow.Dispose();
                preparingWindow = null;

                installerProcess.WaitForExit();
                if (installerProcess.ExitCode != 0)
                {
                    throw new InvalidOperationException("安装脚本异常退出，退出代码：" + installerProcess.ExitCode + "。请查看安装日志获取详细原因。");
                }
            }
            catch (Exception exception)
            {
                if (preparingWindow != null)
                {
                    preparingWindow.Close();
                    preparingWindow.Dispose();
                }

                WriteErrorLog(exception);
                ShowMessage(
                    "安装器无法启动。\r\n\r\n详细原因已保存到：\r\n" + GetErrorLogPath() +
                    "\r\n\r\n请将该日志文件发给安装包维护人员。",
                    MessageBoxIcon.Error);
            }
            finally
            {
                if (!String.IsNullOrEmpty(extractionDirectory))
                {
                    TryDeleteDirectory(extractionDirectory);
                }

                if (installerMutex != null)
                {
                    if (ownsMutex)
                    {
                        installerMutex.ReleaseMutex();
                    }
                    installerMutex.Dispose();
                }
            }
        }

        private static Form CreatePreparingWindow()
        {
            Form window = new Form();
            window.Text = ProductName;
            window.ClientSize = new System.Drawing.Size(420, 122);
            window.FormBorderStyle = FormBorderStyle.FixedDialog;
            window.MaximizeBox = false;
            window.MinimizeBox = false;
            window.ControlBox = false;
            window.ShowInTaskbar = true;
            window.StartPosition = FormStartPosition.CenterScreen;
            window.TopMost = true;

            Label title = new Label();
            title.AutoSize = true;
            title.Font = new System.Drawing.Font("Microsoft YaHei UI", 10.0F, System.Drawing.FontStyle.Bold);
            title.Location = new System.Drawing.Point(20, 18);
            title.Text = "Cloudforl Codex 正在准备安装";
            window.Controls.Add(title);

            Label detail = new Label();
            detail.Name = "detail";
            detail.AutoSize = false;
            detail.Location = new System.Drawing.Point(22, 49);
            detail.Size = new System.Drawing.Size(376, 22);
            detail.Text = "正在校验安装文件，请稍候...";
            window.Controls.Add(detail);

            ProgressBar progress = new ProgressBar();
            progress.Location = new System.Drawing.Point(22, 79);
            progress.Size = new System.Drawing.Size(376, 18);
            progress.Style = ProgressBarStyle.Marquee;
            progress.MarqueeAnimationSpeed = 30;
            window.Controls.Add(progress);

            return window;
        }

        private static void SetPreparingMessage(Form window, string message)
        {
            Control[] controls = window.Controls.Find("detail", false);
            if (controls.Length == 1)
            {
                controls[0].Text = message;
            }
            Application.DoEvents();
        }

        private static string CreateExtractionDirectory()
        {
            string baseDirectory = Path.Combine(Path.GetTempPath(), "Cloudforl-Codex-Installer", "payload");
            Directory.CreateDirectory(baseDirectory);
            string directory = Path.Combine(baseDirectory, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            return directory;
        }

        private static void ExtractPayload(string destinationDirectory)
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            Stream resourceStream = assembly.GetManifestResourceStream(PayloadResourceName);
            if (resourceStream == null)
            {
                throw new InvalidOperationException("安装包资源缺失：" + PayloadResourceName);
            }

            string payloadPath = Path.Combine(destinationDirectory, "payload.zip");
            using (resourceStream)
            using (FileStream payloadFile = new FileStream(payloadPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                CopyStream(resourceStream, payloadFile);
            }

            string actualHash = GetFileSha256(payloadPath);
            if (!String.Equals(actualHash, PayloadSha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("内嵌安装包完整性校验失败。期望 SHA256：" + PayloadSha256 + "，实际 SHA256：" + actualHash);
            }

            string normalizedRoot = EnsureTrailingDirectorySeparator(Path.GetFullPath(destinationDirectory));
            using (FileStream payloadFile = new FileStream(payloadPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (ZipArchive archive = new ZipArchive(payloadFile, ZipArchiveMode.Read, false))
            {
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string fullPath = Path.GetFullPath(Path.Combine(destinationDirectory, entry.FullName));
                    if (!fullPath.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidOperationException("安装包中包含不安全的文件路径：" + entry.FullName);
                    }

                    if (String.IsNullOrEmpty(entry.Name))
                    {
                        Directory.CreateDirectory(fullPath);
                        continue;
                    }

                    string parentDirectory = Path.GetDirectoryName(fullPath);
                    if (!String.IsNullOrEmpty(parentDirectory))
                    {
                        Directory.CreateDirectory(parentDirectory);
                    }

                    using (Stream entryStream = entry.Open())
                    using (FileStream output = new FileStream(fullPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        CopyStream(entryStream, output);
                    }
                }
            }

            File.Delete(payloadPath);
        }

        private static void ValidatePayload(string extractionDirectory)
        {
            string[] requiredPaths = new string[]
            {
                "bootstrap.ps1",
                "installer.ps1",
                "wizard.ps1",
                "provider-switcher.ps1",
                "tools\\codex-leveldb-writer-x64.exe",
                "tools\\codex-leveldb-writer-arm64.exe"
            };

            foreach (string relativePath in requiredPaths)
            {
                string fullPath = Path.Combine(extractionDirectory, relativePath);
                if (!File.Exists(fullPath))
                {
                    throw new InvalidOperationException("安装包文件缺失：" + relativePath);
                }
            }
        }

        private static Process StartInstaller(string extractionDirectory)
        {
            string powershellPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell\\v1.0\\powershell.exe");
            if (!File.Exists(powershellPath))
            {
                powershellPath = "powershell.exe";
            }

            string bootstrapPath = Path.Combine(extractionDirectory, "bootstrap.ps1");
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = powershellPath;
            startInfo.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File " + QuoteArgument(bootstrapPath);
            startInfo.WorkingDirectory = extractionDirectory;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.WindowStyle = ProcessWindowStyle.Hidden;

            Process process = Process.Start(startInfo);
            if (process == null)
            {
                throw new InvalidOperationException("无法启动 PowerShell 安装进程。");
            }
            return process;
        }

        private static string QuoteArgument(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static string GetFileSha256(string path)
        {
            using (SHA256 sha256 = SHA256.Create())
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                byte[] hash = sha256.ComputeHash(stream);
                StringBuilder builder = new StringBuilder(hash.Length * 2);
                foreach (byte value in hash)
                {
                    builder.Append(value.ToString("X2"));
                }
                return builder.ToString();
            }
        }

        private static string EnsureTrailingDirectorySeparator(string path)
        {
            if (!path.EndsWith(Path.DirectorySeparatorChar.ToString(), StringComparison.Ordinal))
            {
                return path + Path.DirectorySeparatorChar;
            }
            return path;
        }

        private static void CopyStream(Stream source, Stream destination)
        {
            byte[] buffer = new byte[81920];
            int count;
            while ((count = source.Read(buffer, 0, buffer.Length)) > 0)
            {
                destination.Write(buffer, 0, count);
            }
        }

        private static void WriteErrorLog(Exception exception)
        {
            try
            {
                string directory = Path.GetDirectoryName(GetErrorLogPath());
                Directory.CreateDirectory(directory);
                string details =
                    "Time: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\r\n" +
                    "Launcher version: " + Version + "\r\n" +
                    "Windows: " + Environment.OSVersion.VersionString + "\r\n\r\n" +
                    exception;
                File.WriteAllText(GetErrorLogPath(), details, new UTF8Encoding(true));
            }
            catch
            {
            }
        }

        private static string GetErrorLogPath()
        {
            return Path.Combine(Path.GetTempPath(), "Cloudforl-Codex-Installer", "launcher-error.log");
        }

        private static void TryDeleteDirectory(string path)
        {
            try
            {
                if (Directory.Exists(path))
                {
                    Directory.Delete(path, true);
                }
            }
            catch
            {
            }
        }

        private static void ShowMessage(string message, MessageBoxIcon icon)
        {
            MessageBox.Show(message, ProductName, MessageBoxButtons.OK, icon);
        }
    }
}
