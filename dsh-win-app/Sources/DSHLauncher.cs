// ============================================================
// DSH Launcher — DeepSeek Harness 系统托盘控制 App（Windows 版）
//
// 对应 macOS 版 DSH Launcher（launchd 托管）的 Windows 实现：
//   · App 在 → 服务在：启动 App 自动拉起 dsh web，退出 App 自动停止
//   · 托盘鲸鱼图标按状态着色：绿=运行中 / 橙=端口被外部占用 /
//     红=启动失败 / 灰=未运行（或正在启动）
//   · 进程模型：以隐藏窗口直接启动 <node.exe> <dsh bin.js> web --port 3080，
//     停止时 taskkill /T 整棵进程树（先温和后强制，等价 launchctl bootout）
//   · 单文件 exe：.NET Framework 4.8（Windows 10/11 自带），
//     用系统自带 csc.exe 编译（build.bat），无需安装任何 SDK
// ============================================================

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DSHLauncher
{
    internal enum ServiceState { Running, Starting, External, Crashed, Stopped }

    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            bool createdNew;
            using (var mutex = new Mutex(true, @"Local\DSHLauncher.SingleInstance", out createdNew))
            {
                if (!createdNew)
                {
                    MessageBox.Show("DSH Launcher 已在运行（请在系统托盘中找鲸鱼图标）。",
                        "DSH Launcher", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayApp());
            }
        }
    }

    internal static class NativeMethods
    {
        [DllImport("user32.dll")]
        internal static extern bool DestroyIcon(IntPtr hIcon);
    }

    // ============================================================
    // 服务管理：解析 node/dsh 路径、拉起/停止 dsh web 进程、状态检测
    // ============================================================

    internal static class ServiceManager
    {
        public static Process Proc;          // 当前托管的 dsh web 进程（或 null）
        public static bool IsStarting;       // 启动窗口期（App 自动拉起 / 手动重启）
        public static int? LastExitCode;     // 最近一次进程退出码（null = 尚未退出过）

        private const string RegRoot = @"HKEY_CURRENT_USER\Software";
        private const string RegApp = @"Software\DSHLauncher";
        private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValueName = "DSHLauncher";

        public static readonly string LocalAppData =
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        public static readonly string AppData =
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        public static readonly string UserProfile =
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

        public static readonly string LogDir = Path.Combine(LocalAppData, "DSHLauncher");
        public static readonly string LogFile = Path.Combine(LogDir, "dsh-web.log");
        public static readonly string WebUrl = "http://127.0.0.1:3080";

        private static readonly object LogLock = new object();

        // ---- 通用进程执行 ----

        /// Windows 命令行参数引用：含空格/引号才加引号
        private static string QuoteArg(string a)
        {
            if (a.Length == 0) return "\"\"";
            if (a.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return a;
            return "\"" + a.Replace("\"", "\\\"") + "\"";
        }

        private static string JoinArgs(string[] args)
        {
            var sb = new StringBuilder();
            for (int i = 0; i < args.Length; i++)
            {
                if (i > 0) sb.Append(' ');
                sb.Append(QuoteArg(args[i]));
            }
            return sb.ToString();
        }

        private static int RunProcess(string exe, string[] args, out string stdout, out string stderr, int timeoutMs = 8000)
        {
            stdout = ""; stderr = "";
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = exe,
                    Arguments = JoinArgs(args),
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };
                using (var p = new Process { StartInfo = psi })
                {
                    p.Start();
                    var outTask = p.StandardOutput.ReadToEndAsync();
                    var errTask = p.StandardError.ReadToEndAsync();
                    if (!p.WaitForExit(timeoutMs))
                    {
                        try { p.Kill(); } catch { }
                        p.WaitForExit(3000);
                        return -1;
                    }
                    stdout = outTask.Result ?? "";
                    stderr = errTask.Result ?? "";
                    return p.ExitCode;
                }
            }
            catch
            {
                return -1;
            }
        }

        // ---- 日志 ----

        private static void AppendLog(string line)
        {
            try
            {
                lock (LogLock)
                {
                    Directory.CreateDirectory(LogDir);
                    using (var w = new StreamWriter(LogFile, true, new UTF8Encoding(false)))
                    {
                        w.WriteLine(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + line);
                    }
                }
            }
            catch { }
        }

        public static string LogTail(int n = 25)
        {
            try
            {
                if (!File.Exists(LogFile)) return "(日志为空)";
                string[] lines = File.ReadAllLines(LogFile, Encoding.UTF8);
                int take = Math.Min(n, lines.Length);
                var sb = new StringBuilder();
                for (int i = lines.Length - take; i < lines.Length; i++) sb.AppendLine(lines[i]);
                return sb.ToString();
            }
            catch { return "(日志为空)"; }
        }

        // ---- 路径解析（与 macOS 版同一策略）----
        // node 解析顺序：注册表记忆 → fnm → nvm-windows → 官方安装目录 → PATH

        private static string BestVersionDir(string baseDir)
        {
            string bestName = null;
            Version bestVer = null;
            try
            {
                foreach (string dir in Directory.GetDirectories(baseDir))
                {
                    string name = Path.GetFileName(dir).TrimStart('v', 'V');
                    Version v;
                    if (!Version.TryParse(name, out v)) continue;
                    if (bestVer == null || v > bestVer)
                    {
                        bestVer = v;
                        bestName = Path.GetFileName(dir);
                    }
                }
            }
            catch { }
            return bestName;
        }

        public static string ResolveNodePath()
        {
            try
            {
                var saved = Registry.GetValue(RegRoot + "\\DSHLauncher", "nodePath", null) as string;
                if (!string.IsNullOrEmpty(saved) && File.Exists(saved)) return saved;
            }
            catch { }

            // fnm (Windows): %LOCALAPPDATA%\fnm\node-versions\<v>\installation\node.exe
            string fnmBase = Path.Combine(LocalAppData, "fnm", "node-versions");
            string best = BestVersionDir(fnmBase);
            if (best != null)
            {
                string cand = Path.Combine(fnmBase, best, "installation", "node.exe");
                if (File.Exists(cand)) return cand;
            }

            // nvm-windows: %NVM_HOME%\v<version>\node.exe 或 %NVM_HOME%\current\node.exe
            string nvmHome = Environment.GetEnvironmentVariable("NVM_HOME");
            if (string.IsNullOrEmpty(nvmHome)) nvmHome = Path.Combine(AppData, "nvm");
            if (Directory.Exists(nvmHome))
            {
                best = BestVersionDir(nvmHome);
                if (best != null)
                {
                    string cand = Path.Combine(nvmHome, best, "node.exe");
                    if (File.Exists(cand)) return cand;
                }
                string cur = Path.Combine(nvmHome, "current", "node.exe");
                if (File.Exists(cur)) return cur;
            }

            // 官方安装包
            string pf = Environment.GetEnvironmentVariable("ProgramFiles");
            string pf86 = Environment.GetEnvironmentVariable("ProgramFiles(x86)");
            string[] candidates =
            {
                Path.Combine(string.IsNullOrEmpty(pf) ? @"C:\Program Files" : pf, "nodejs", "node.exe"),
                Path.Combine(string.IsNullOrEmpty(pf86) ? @"C:\Program Files (x86)" : pf86, "nodejs", "node.exe"),
                Path.Combine(LocalAppData, "Programs", "nodejs", "node.exe")
            };
            foreach (string c in candidates)
            {
                if (File.Exists(c)) return c;
            }

            // PATH（where node）
            string stdout, stderr;
            if (RunProcess("where.exe", new[] { "node" }, out stdout, out stderr) == 0)
            {
                foreach (string line in stdout.Split('\n'))
                {
                    string t = line.Trim();
                    if (t.Length > 0 && File.Exists(t)) return t;
                }
            }
            return null;
        }

        // dsh 包解析：npm 全局安装 → npx 缓存（取最新的）
        public static string ResolveDshBinJs()
        {
            string best = null;
            DateTime bestTime = DateTime.MinValue;

            Action<string> consider = delegate (string cand)
            {
                try
                {
                    if (File.Exists(cand))
                    {
                        DateTime t = File.GetLastWriteTime(cand);
                        if (t > bestTime) { bestTime = t; best = cand; }
                    }
                }
                catch { }
            };

            consider(Path.Combine(AppData, "npm", "node_modules", "@deepseek-ai", "dsh", "lib", "bin.js"));

            string[] npxRoots =
            {
                Path.Combine(LocalAppData, "npm-cache", "_npx"),
                Path.Combine(AppData, "npm-cache", "_npx")
            };
            foreach (string root in npxRoots)
            {
                if (!Directory.Exists(root)) continue;
                try
                {
                    foreach (string hashDir in Directory.GetDirectories(root))
                    {
                        consider(Path.Combine(hashDir, "node_modules", "@deepseek-ai", "dsh", "lib", "bin.js"));
                    }
                }
                catch { }
            }
            return best;
        }

        private sealed class ProgramSpec
        {
            public string Exe;
            public List<string> Args;
            public string NodePath; // 用于记忆到注册表
        }

        // 首选：<node.exe> <npx缓存 dsh bin.js> web --port 3080
        // 兜底：cmd /c npx.cmd --yes @deepseek-ai/dsh web --port 3080（首次联网下载）
        private static ProgramSpec BuildProgram()
        {
            string node = ResolveNodePath();
            if (node == null) return null;

            string binJs = ResolveDshBinJs();
            if (binJs != null)
            {
                return new ProgramSpec
                {
                    Exe = node,
                    NodePath = node,
                    Args = new List<string> { binJs, "web", "--port", "3080" }
                };
            }

            string npx = Path.Combine(Path.GetDirectoryName(node), "npx.cmd");
            if (File.Exists(npx))
            {
                return new ProgramSpec
                {
                    Exe = "cmd.exe",
                    NodePath = node,
                    Args = new List<string> { "/c", npx, "--yes", "@deepseek-ai/dsh", "web", "--port", "3080" }
                };
            }
            return null;
        }

        public static string WorkspacePath()
        {
            try
            {
                var saved = Registry.GetValue(RegRoot + "\\DSHLauncher", "workspacePath", null) as string;
                if (!string.IsNullOrEmpty(saved)) return saved;
            }
            catch { }
            string candidate = Path.Combine(UserProfile, "Desktop", "work", "ds_test");
            return Directory.Exists(candidate) ? candidate : UserProfile;
        }

        // ---- 启动 / 停止 ----

        public static bool StartService(out string error)
        {
            error = null;
            ProgramSpec spec = BuildProgram();
            if (spec == null)
            {
                error = "未找到 node.exe 与 dsh 包。\n请确认已安装 Node.js（nvm-windows / fnm / 官方安装包均可），\n并至少执行过一次 npx @deepseek-ai/dsh（产生缓存后本 App 即可自动找到）。";
                return false;
            }

            var psi = new ProcessStartInfo
            {
                FileName = spec.Exe,
                Arguments = JoinArgs(spec.Args.ToArray()),
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = WorkspacePath(),
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };

            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            try
            {
                p.Start();
            }
            catch (Exception ex)
            {
                error = "启动进程失败：" + ex.Message;
                return false;
            }

            p.OutputDataReceived += OnOutputData;
            p.ErrorDataReceived += OnOutputData;
            p.Exited += OnProcessExited;
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();

            Proc = p;
            LastExitCode = null;
            try { Registry.SetValue(RegRoot + "\\DSHLauncher", "lastPid", p.Id); } catch { }
            if (!string.IsNullOrEmpty(spec.NodePath))
            {
                try { Registry.SetValue(RegRoot + "\\DSHLauncher", "nodePath", spec.NodePath); } catch { }
            }
            AppendLog("===== dsh web 启动（PID " + p.Id + "）=====");
            return true;
        }

        private static void OnOutputData(object sender, DataReceivedEventArgs e)
        {
            if (!string.IsNullOrEmpty(e.Data)) AppendLog(e.Data);
        }

        private static void OnProcessExited(object sender, EventArgs e)
        {
            try
            {
                var p = (Process)sender;
                if (p.HasExited) LastExitCode = p.ExitCode;
            }
            catch { }
            AppendLog("===== dsh web 进程已退出 =====");
        }

        private static void KillTree(int pid, bool graceful)
        {
            var args = new List<string> { "/PID", pid.ToString(), "/T" };
            if (!graceful) args.Add("/F");
            string so, se;
            RunProcess("taskkill.exe", args.ToArray(), out so, out se, 8000);
        }

        /// 停止托管服务：先温和后强制，杀掉整棵进程树（dsh web 的会话数据会落盘）。
        /// 若当前没有托管进程但端口被“上一轮被强杀遗留的孤儿”占着，也一并回收。
        public static void StopService()
        {
            Process p = Proc;
            if (p != null)
            {
                try
                {
                    if (!p.HasExited) KillTree(p.Id, true);
                    p.WaitForExit(3000);
                    if (!p.HasExited) KillTree(p.Id, false);
                    p.WaitForExit(3000);
                }
                catch { }
                Proc = null;
                try { p.Dispose(); } catch { }
            }
            else if (OccupierIsOrphan())
            {
                KillOrphan();
            }
            ClearLastPid();
        }

        // ---- 状态检测 ----

        public static ServiceState CurrentState()
        {
            bool alive = Proc != null && !Proc.HasExited;
            if (alive) return ServiceState.Running;
            if (IsStarting) return ServiceState.Starting;
            if (PortServing()) return ServiceState.External;
            if (LastExitCode != null && LastExitCode != 0) return ServiceState.Crashed;
            return ServiceState.Stopped;
        }

        /// 端口健康检查：127.0.0.1:3080 有 HTTP 响应（含 4xx/5xx）即视为有服务
        public static bool PortServing()
        {
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(WebUrl);
                req.Method = "GET";
                req.Timeout = 2000;
                using (var resp = (HttpWebResponse)req.GetResponse()) { return true; }
            }
            catch (WebException we)
            {
                return we.Response != null;
            }
            catch
            {
                return false;
            }
        }

        /// netstat 找占用 3080 的进程 PID
        public static bool TryGetOccupierPid(out int pid)
        {
            pid = 0;
            string so, se;
            if (RunProcess("netstat.exe", new[] { "-ano", "-p", "tcp" }, out so, out se, 8000) != 0) return false;
            foreach (string raw in so.Split('\n'))
            {
                string line = raw.Trim();
                if (line.IndexOf(":3080", StringComparison.Ordinal) < 0) continue;
                if (line.IndexOf("LISTENING", StringComparison.Ordinal) < 0) continue;
                string[] parts = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length < 5) continue;
                if (int.TryParse(parts[parts.Length - 1], out pid) && pid > 0) return true;
            }
            return false;
        }

        private static string ProcessNameOf(int pid)
        {
            try
            {
                using (var p = Process.GetProcessById(pid))
                {
                    return p.ProcessName.ToLowerInvariant() + ".exe";
                }
            }
            catch { return ""; }
        }

        public static string Port3080Occupier()
        {
            int pid;
            if (!TryGetOccupierPid(out pid)) return "未知进程";
            string name = ProcessNameOf(pid);
            return "PID " + pid + "（" + (string.IsNullOrEmpty(name) ? "未知命令" : name) + "）";
        }

        private static int GetSavedLastPid()
        {
            try
            {
                var v = Registry.GetValue(RegRoot + "\\DSHLauncher", "lastPid", 0);
                return Convert.ToInt32(v);
            }
            catch { return 0; }
        }

        private static void ClearLastPid()
        {
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(RegApp, true))
                {
                    if (k != null) k.DeleteValue("lastPid", false);
                }
            }
            catch { }
        }

        /// 端口占用者是不是“上一轮 App 被强杀后遗留的 dsh 进程”：
        /// PID 与注册表记忆一致，且进程名是 node/npx/cmd（避免误杀同名 PID 的其它程序）
        public static bool OccupierIsOrphan()
        {
            int pid;
            if (!TryGetOccupierPid(out pid) || pid <= 0) return false;
            if (pid != GetSavedLastPid()) return false;
            string name = ProcessNameOf(pid);
            return name == "node.exe" || name == "npx.exe" || name == "cmd.exe";
        }

        private static void KillOrphan()
        {
            int pid;
            if (TryGetOccupierPid(out pid) && pid > 0) KillTree(pid, false);
        }

        // ---- 开机自启（注册表 Run 键）----

        public static bool AutoStartEnabled()
        {
            try
            {
                return Registry.GetValue(@"HKEY_CURRENT_USER\" + RunKeyPath, RunValueName, null) != null;
            }
            catch { return false; }
        }

        public static void SetAutoStart(bool on)
        {
            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(RunKeyPath))
                {
                    if (on) key.SetValue(RunValueName, "\"" + Application.ExecutablePath + "\"");
                    else key.DeleteValue(RunValueName, false);
                }
            }
            catch { }
        }
    }

    // ============================================================
    // 鲸鱼图标：解析打包在 exe 内的官方 favicon.svg，按状态着色渲染
    // ============================================================

    internal static class WhaleIcon
    {
        private static GraphicsPath _path;

        private static GraphicsPath ParsePath(string d, float vbH)
        {
            // 分词：字母=命令，数字=参数（支持 M/m、C/c、L/l、Z/z 与隐式重复）
            var toks = new List<object>();
            var cur = new StringBuilder();
            Action flush = delegate
            {
                if (cur.Length > 0)
                {
                    toks.Add(float.Parse(cur.ToString(), CultureInfo.InvariantCulture));
                    cur.Clear();
                }
            };
            foreach (char ch in d)
            {
                if (char.IsLetter(ch)) { flush(); toks.Add(ch); }
                else if (char.IsDigit(ch) || ch == '-' || ch == '.' || ch == '+') cur.Append(ch);
                else flush();
            }
            flush();

            var path = new GraphicsPath();
            int i = 0;
            float x = 0, y = 0, sx = 0, sy = 0;
            char last = '\0';

            while (i < toks.Count)
            {
                char c;
                if (toks[i] is char)
                {
                    c = (char)toks[i];
                    i++;
                    last = c;
                }
                else if (last != '\0')
                {
                    c = last; // 隐式重复：省略命令字母
                }
                else break;

                switch (c)
                {
                    case 'M':
                    case 'm':
                    {
                        List<float> p = TakeNums(toks, ref i, 2);
                        if (p.Count < 2) return path;
                        float mx = p[0], my = vbH - p[1]; // SVG y 向下，翻转
                        if (c == 'm') { mx += x; my += y; }
                        x = mx; y = my; sx = mx; sy = my;
                        path.StartFigure();
                        break;
                    }
                    case 'C':
                    case 'c':
                    {
                        List<float> p = TakeNums(toks, ref i, 6);
                        if (p.Count < 6) return path;
                        float c1x = p[0], c1y = vbH - p[1], c2x = p[2], c2y = vbH - p[3], ex = p[4], ey = vbH - p[5];
                        if (c == 'c') { c1x += x; c1y += y; c2x += x; c2y += y; ex += x; ey += y; }
                        path.AddBezier(x, y, c1x, c1y, c2x, c2y, ex, ey);
                        x = ex; y = ey;
                        break;
                    }
                    case 'L':
                    case 'l':
                    {
                        List<float> p = TakeNums(toks, ref i, 2);
                        if (p.Count < 2) return path;
                        float lx = p[0], ly = vbH - p[1];
                        if (c == 'l') { lx += x; ly += y; }
                        path.AddLine(x, y, lx, ly);
                        x = lx; y = ly;
                        break;
                    }
                    case 'Z':
                    case 'z':
                        path.CloseFigure();
                        x = sx; y = sy;
                        break;
                    default:
                        return path;
                }
            }
            return path;
        }

        private static List<float> TakeNums(List<object> toks, ref int i, int k)
        {
            var res = new List<float>(k);
            while (res.Count < k && i < toks.Count)
            {
                if (toks[i] is float) res.Add((float)toks[i]);
                i++;
            }
            return res;
        }

        private static GraphicsPath GetWhalePath()
        {
            if (_path != null) return _path;
            try
            {
                var asm = Assembly.GetExecutingAssembly();
                using (var s = asm.GetManifestResourceStream("DSHLauncher.favicon.svg"))
                {
                    if (s == null) return null;
                    string svg;
                    using (var r = new StreamReader(s, Encoding.UTF8)) svg = r.ReadToEnd();

                    float vbH = 50;
                    int vi = svg.IndexOf("viewBox=\"", StringComparison.Ordinal);
                    if (vi >= 0)
                    {
                        int vs = vi + 9, ve = svg.IndexOf('"', vs);
                        if (ve > vs)
                        {
                            string[] nums = svg.Substring(vs, ve - vs)
                                .Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                            if (nums.Length == 4)
                                float.TryParse(nums[3], NumberStyles.Float, CultureInfo.InvariantCulture, out vbH);
                        }
                    }

                    int pi = svg.IndexOf("<path", StringComparison.Ordinal);
                    int ds = pi >= 0 ? svg.IndexOf(" d=\"", pi, StringComparison.Ordinal) : -1;
                    if (ds < 0) return null;
                    ds += 4;
                    int de = svg.IndexOf('"', ds);
                    if (de < 0) return null;

                    var path = ParsePath(svg.Substring(ds, de - ds), vbH);
                    path.FillMode = FillMode.Winding; // 与浏览器一致的非零环绕
                    _path = path;
                    return path;
                }
            }
            catch
            {
                return null;
            }
        }

        /// 渲染 32px 鲸鱼图标（2x 渲染保证高分屏清晰），透明底 + 状态色
        public static Icon Render(Color color)
        {
            const int px = 32;
            using (var bmp = new Bitmap(px, px))
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                GraphicsPath path = GetWhalePath();
                if (path != null)
                {
                    RectangleF b = path.GetBounds();
                    if (b.Width > 0 && b.Height > 0)
                    {
                        float scale = (px * 0.86f) / b.Width; // 鲸鱼按 favicon 原比例（宽约占 86%）居中
                        g.TranslateTransform((px - b.Width * scale) / 2f - b.X * scale,
                                             (px - b.Height * scale) / 2f - b.Y * scale);
                        g.ScaleTransform(scale, scale);
                        using (var brush = new SolidBrush(color)) g.FillPath(brush, path);
                    }
                }
                else
                {
                    using (var brush = new SolidBrush(color)) g.FillEllipse(brush, 4, 4, 24, 24);
                }
                return Icon.FromHandle(bmp.GetHicon());
            }
        }
    }

    // ============================================================
    // 托盘 App 主体
    // ============================================================

    internal sealed class TrayApp : ApplicationContext
    {
        private readonly NotifyIcon _tray = new NotifyIcon { Visible = true };
        private readonly Control _ui = new Control(); // 后台线程向 UI 线程封送的桥梁
        private readonly System.Windows.Forms.Timer _timer;
        private readonly ToolStripMenuItem _statusLine = new ToolStripMenuItem();
        private readonly ToolStripMenuItem _autoStartItem = new ToolStripMenuItem();
        private readonly List<Icon> _icons = new List<Icon>(); // 持有的 HICON，退出时统一销毁
        private ServiceState _lastState = ServiceState.Stopped;
        private bool _hintChecked;

        public TrayApp()
        {
            _ = _ui.Handle; // 现在就创建窗口句柄（UI 线程），供后台线程 Invoke

            var menu = new ContextMenuStrip();
            menu.Items.Add(new ToolStripMenuItem("DSH Launcher") { Enabled = false });
            _statusLine.Enabled = false;
            menu.Items.Add(_statusLine);
            menu.Items.Add(new ToolStripSeparator());

            var openItem = new ToolStripMenuItem("打开 Web UI");
            openItem.Click += delegate { OpenWebUI(); };
            menu.Items.Add(openItem);

            var restartItem = new ToolStripMenuItem("重启服务");
            restartItem.Click += delegate { DoRestart(); };
            menu.Items.Add(restartItem);

            menu.Items.Add(new ToolStripSeparator());

            _autoStartItem.Text = "开机自动启动本 App";
            _autoStartItem.Click += delegate { ToggleAutoStart(); };
            menu.Items.Add(_autoStartItem);

            menu.Items.Add(new ToolStripSeparator());

            var dataDirItem = new ToolStripMenuItem("打开数据目录 %USERPROFILE%\\.dsh");
            dataDirItem.Click += delegate { OpenDataDir(); };
            menu.Items.Add(dataDirItem);

            menu.Items.Add(new ToolStripSeparator());

            var quitItem = new ToolStripMenuItem("退出（同时停止服务）");
            quitItem.Click += delegate { Quit(); };
            menu.Items.Add(quitItem);

            _tray.ContextMenuStrip = menu;
            _tray.Text = "DSH Launcher";
            _tray.DoubleClick += delegate { OpenWebUI(); };

            _timer = new System.Windows.Forms.Timer { Interval = 3000 };
            _timer.Tick += delegate { RefreshUi(); };
            _timer.Start();

            AppDomain.CurrentDomain.ProcessExit += delegate { Shutdown(); };

            AutoStartService();
            RefreshUi();
        }

        // ---- 启动流程 ----

        /// App 启动即拉起服务（生命周期绑定：App 在 → 服务在）。
        /// 端口被外部实例占用时不打扰（橙色状态行）；上一轮被强杀的孤儿进程自动回收。
        private void AutoStartService()
        {
            if (ServiceManager.PortServing())
            {
                if (ServiceManager.OccupierIsOrphan())
                {
                    ServiceManager.StopService(); // 回收孤儿
                    Thread.Sleep(1200);           // 等端口释放
                }
                else
                {
                    RefreshUi(); // 橙色：外部实例
                    return;
                }
            }

            ServiceManager.IsStarting = true;
            RefreshUi();

            string err;
            if (!ServiceManager.StartService(out err))
            {
                ServiceManager.IsStarting = false;
                MessageBox.Show("服务启动失败\n\n" + err + "\n\n日志尾部：\n" + ServiceManager.LogTail(),
                    "DSH Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
                RefreshUi();
                return;
            }
            ThreadPool.QueueUserWorkItem(delegate { HealthCheck(3500); });
        }

        /// 启动后健康检查：进程没起来才弹日志尾部
        private void HealthCheck(int delayMs)
        {
            Thread.Sleep(delayMs);
            bool dead = ServiceManager.Proc == null || ServiceManager.Proc.HasExited;
            bool serving = ServiceManager.PortServing();
            ServiceManager.IsStarting = false;
            try
            {
                _ui.Invoke((Action)delegate
                {
                    if (dead && !serving)
                    {
                        MessageBox.Show("服务启动失败：进程已退出。\n\n日志尾部：\n" + ServiceManager.LogTail(),
                            "DSH Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                    RefreshUi();
                });
            }
            catch { }
        }

        // ---- 菜单动作 ----

        private void OpenWebUI()
        {
            try { Process.Start(ServiceManager.WebUrl); }
            catch { }
        }

        /// 重启服务 = 无论当前状态如何都能把服务拉起来：
        /// 运行中 → 停止后重新拉起；启动失败/未运行 → 直接启动；
        /// 端口被外部实例占用 → 弹窗说明占用者（不破坏外部实例）。
        private void DoRestart()
        {
            bool running = ServiceManager.Proc != null && !ServiceManager.Proc.HasExited;
            if (!running && ServiceManager.PortServing() && !ServiceManager.OccupierIsOrphan())
            {
                MessageBox.Show("端口 3080 已被占用\n\n占用者：" + ServiceManager.Port3080Occupier() +
                    "\n\n请先停止占用端口的进程（如果是终端里跑的 dsh web，在终端按 Ctrl+C），再点「重启服务」。",
                    "DSH Launcher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                RefreshUi();
                return;
            }

            ServiceManager.IsStarting = true;
            RefreshUi();

            ThreadPool.QueueUserWorkItem(delegate
            {
                ServiceManager.StopService(); // 运行中=停；孤儿=回收；未运行=无操作
                string err = null;
                bool ok = false;
                for (int i = 0; i < 6 && !ok; i++)
                {
                    ok = ServiceManager.StartService(out err);
                    if (!ok) Thread.Sleep(500);
                }
                Thread.Sleep(3500);
                bool dead = ServiceManager.Proc == null || ServiceManager.Proc.HasExited;
                bool serving = ServiceManager.PortServing();
                ServiceManager.IsStarting = false;
                try
                {
                    _ui.Invoke((Action)delegate
                    {
                        if (!ok)
                        {
                            MessageBox.Show("服务启动失败\n\n" + err + "\n\n日志尾部：\n" + ServiceManager.LogTail(),
                                "DSH Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                        else if (dead && !serving)
                        {
                            MessageBox.Show("服务启动失败：进程已退出。\n\n日志尾部：\n" + ServiceManager.LogTail(),
                                "DSH Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                        RefreshUi();
                    });
                }
                catch { }
            });
        }

        private void ToggleAutoStart()
        {
            bool on = !ServiceManager.AutoStartEnabled();
            ServiceManager.SetAutoStart(on);
            _autoStartItem.Checked = on;
        }

        private void OpenDataDir()
        {
            string dir = Path.Combine(ServiceManager.UserProfile, ".dsh");
            try
            {
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                Process.Start("explorer.exe", "\"" + dir + "\"");
            }
            catch { }
        }

        private void Quit()
        {
            ServiceManager.StopService();
            _timer.Stop();
            _tray.Visible = false;
            _tray.Dispose();
            DisposeIcons();
            Application.Exit();
        }

        private void Shutdown()
        {
            try { ServiceManager.StopService(); } catch { }
            try { DisposeIcons(); } catch { }
        }

        // ---- 刷新 ----

        private void RefreshUi()
        {
            ServiceState state = ServiceManager.CurrentState();
            string text;
            Color color;
            switch (state)
            {
                case ServiceState.Running:
                    text = "服务：运行中 · 端口 3080";
                    color = Color.FromArgb(34, 160, 74);    // 绿
                    break;
                case ServiceState.Starting:
                    text = "服务：正在启动…";
                    color = Color.FromArgb(128, 128, 128);  // 灰
                    break;
                case ServiceState.External:
                    text = "服务：外部实例运行中（端口 3080 被占用）";
                    color = Color.FromArgb(237, 137, 54);   // 橙
                    break;
                case ServiceState.Crashed:
                    text = "服务：启动失败（点「重启服务」重试）";
                    color = Color.FromArgb(220, 53, 69);    // 红
                    break;
                default:
                    text = "服务：未运行";
                    color = Color.FromArgb(128, 128, 128);  // 灰
                    break;
            }

            _statusLine.Text = text;
            _autoStartItem.Checked = ServiceManager.AutoStartEnabled();
            _tray.Text = "DSH Launcher — " + text;

            if (state != _lastState)
            {
                _lastState = state;
                try
                {
                    Icon icon = WhaleIcon.Render(color);
                    _icons.Add(icon);
                    _tray.Icon = icon;
                }
                catch { }
            }

            if (!_hintChecked)
            {
                _hintChecked = true;
                try
                {
                    if (Registry.GetValue(@"HKEY_CURRENT_USER\Software\DSHLauncher", "hintShown", 0) == null)
                    {
                        Registry.SetValue(@"HKEY_CURRENT_USER\Software\DSHLauncher", "hintShown", 1);
                        _tray.BalloonTipTitle = "DSH Launcher";
                        _tray.BalloonTipText = "服务托管已就绪：鲸鱼图标 绿=运行中 / 橙=端口被外部占用 / 红=启动失败 / 灰=未运行。点击图标打开菜单。";
                        _tray.ShowBalloonTip(6000);
                    }
                }
                catch { }
            }
        }

        private void DisposeIcons()
        {
            foreach (Icon icon in _icons)
            {
                try { NativeMethods.DestroyIcon(icon.Handle); } catch { }
                try { icon.Dispose(); } catch { }
            }
            _icons.Clear();
        }
    }
}
