# DSH Launcher — DeepSeek Harness 托盘 App（Windows 版）

[English](README.en.md) | **中文**

Windows 系统托盘小应用：把 `dsh web` 服务交给本 App 后台托管，**不再需要开着终端**。
**App 在 → 服务就在：启动 App 自动拉起服务，退出 App 自动停止服务。**
点击托盘鲸鱼图标（🐋 绿=运行中 / 橙=端口被外部占用 / 红=启动失败 / 灰=未运行，
图标为官方 dsh 鲸鱼 logo 按状态着色）即可控制。启动后 3.5 秒健康检查，进程退出则弹日志尾部。

对应 macOS 版 [DSH Launcher](https://github.com/tttnny/DSH-Launcher)（菜单栏 + launchd）的 Windows 实现，
功能与交互保持一致。

## 安装

单文件 exe，无需安装：

1. 下载 `DSH Launcher.exe`（[Releases](https://github.com/tttnny/DSH-Launcher/releases) 或构建产物），
   放到任意目录（如桌面或 `%LOCALAPPDATA%\DSHLauncher\`）双击运行
2. 首次运行若出现 SmartScreen 提示：点「更多信息」→「仍要运行」
   （未签名 exe 的常规提示，与 macOS 版 Gatekeeper 拦截同理）
3. 托盘出现鲸鱼图标即就绪，首次会弹一条气泡说明

要求：Windows 10/11 · 已安装 Node.js（nvm-windows / fnm / 官方安装包均可）。

> 不需要先手动跑过 `npx @deepseek-ai/dsh web`：
> 本 App 会自动找到 node 与 dsh 包（全局安装或 npx 缓存），
> 都没有时首次启动自动执行 `npx --yes @deepseek-ai/dsh` 联网下载（之后有缓存）。
> 若你确实在终端里跑过 `dsh web`，那个进程占着 3080 端口，App 会显示橙色「外部实例」，
> 在终端按 `Ctrl+C` 停掉后让 App 接管即可（见下文「从终端实例切换」）。

## 构建

```bat
build.bat        :: 产出 dist\DSH Launcher.exe
```

- 使用 Windows 自带的 .NET Framework 4.8 `csc.exe` 编译，**无需安装任何 SDK**
- 产物为单文件 exe（内嵌图标、DPI 清单与官方鲸鱼 SVG），拷贝到任何 Win10/11 即可运行
- 装了 .NET SDK 的机器也可用 `dotnet build -c Release`（同一份源码，`DSHLauncher.csproj`）

## 菜单功能

| 菜单项 | 作用 |
|---|---|
| 状态行 | 服务是否运行（本 App 托管 / 外部实例占用 3080） |
| 打开 Web UI | 浏览器打开 http://127.0.0.1:3080 |
| 重启服务 | 永远可用：运行中=重启；启动失败/未运行=直接启动；端口被外部实例占用=弹窗说明占用者 |
| 开机自动启动本 App | 写入注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，登录后自动拉起服务 |
| 打开数据目录 | `%USERPROFILE%\.dsh` |
| 退出 | 退出 App **并停止服务**（终止整棵进程树，数据已落盘，下次打开 App 即恢复） |

## 从终端实例切换（第一次使用）

现在端口 3080 可能还被终端里的 `dsh web` 占着（App 会显示橙色「外部实例」）。切换步骤：

1. 在终端按 `Ctrl+C` 停掉旧的 `dsh web`（本次会话会离线，但历史记录都在 `%USERPROFILE%\.dsh\sessions\`）
2. 重启 DSH Launcher（或点 **重启服务**），服务自动拉起
3. 状态变绿后点 **打开 Web UI**，历史会话完整可续

## 局域网访问（可选，使用社区插件）

本 App 只托管本机服务（dsh 官方出于安全考虑禁止绑定 `0.0.0.0`，且浏览器
非安全上下文下部分功能不可用）。局域网访问请使用社区插件
[moxisuki/dsh-lan](https://github.com/moxisuki/dsh-lan)（已实测兼容 rc.6，
页面、API、添加工作区均正常），安装后**无需改启动命令**：

```bat
rem 1. 一次性安装插件
dsh plugin --profile web add "%USERPROFILE%\.dsh\plugins\dsh-lan"

rem 2. 一次性把 dsh-lan 的 overlay 写进 profile 补丁层（每次 dsh web 启动自动应用）
copy "%USERPROFILE%\.dsh\plugins\dsh-lan\cordis.yml" "%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml"

rem 3. 重启服务（App 菜单里点「重启服务」即可），启动命令保持 dsh web --port 3080 不变
```

启动后按日志打印的 `(LAN: http://<本机IP>:3080)` 地址访问即可。
想关闭局域网访问：把 `%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml` 恢复为 `[]` 并重启服务。
已知限制（上游刻意钉在回环客户端）：设置、凭据、agent 预设编辑在 LAN 下会 403，界面自动降级。
⚠️ dsh web 没有认证层，局域网访问会把远程代码执行能力暴露给整个局域网，仅限可信网络使用。

## 技术要点

- **进程模型**：App 以隐藏窗口直接启动 `<node.exe> <npx缓存 dsh bin.js> web --port 3080`
  （首选）；没有 dsh 缓存时退回 `cmd /c npx.cmd --yes @deepseek-ai/dsh web --port 3080`。
  停止服务 = `taskkill /PID <pid> /T`（先温和后强制，杀掉整棵进程树并落盘会话，等价 macOS 的
  `launchctl bootout`）。App 被强杀（任务管理器）遗留的孤儿进程，下次启动会自动识别并回收。
- **node 解析顺序**：注册表记忆 → fnm（`%LOCALAPPDATA%\fnm\node-versions`）→
  nvm-windows（`%NVM_HOME%` 或 `%APPDATA%\nvm`）→ 官方安装目录 → `where node`。
  每次「启动服务」重新解析并记忆，升级 node/dsh 后无需手动改配置。
- **dsh 包解析**：npm 全局安装（`%APPDATA%\npm\node_modules`）→
  npx 缓存（`%LOCALAPPDATA%\npm-cache\_npx` 与 `%APPDATA%\npm-cache\_npx`，取最新）。
- **状态检测**：进程存活 → HTTP 健康检查（127.0.0.1:3080，含 4xx/5xx）→
  `netstat -ano` 找端口占用者（弹窗展示 PID 与进程名）。
- **API key**：harness 直接从 `%USERPROFILE%\.dsh\.credentials.yaml` 读取，无需额外配置。
- **开机自启**：注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`（仅 App 自启；
  服务不做登录自启，由 App 启动时拉起）。
- **单实例**：命名 Mutex，重复启动会提示并退出。
- **日志**：`%LOCALAPPDATA%\DSHLauncher\dsh-web.log`。

## 卸载

1. 托盘菜单里取消勾选「开机自动启动本 App」（或手动删注册表 Run 键）
2. 点「退出（同时停止服务）」
3. 删除 exe 与 `%LOCALAPPDATA%\DSHLauncher` 目录即可
