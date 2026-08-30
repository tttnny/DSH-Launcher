# DSH Launcher — DeepSeek Harness 菜单栏 App

[English](README.en.md) | **中文**

macOS 菜单栏小应用 + 主窗口控制台：把 dsh 服务交给 launchd 托管，**不再需要开着终端**。

**v2.0 起，服务全手动控制（契约变更）**：dsh 服务是独立的 launchd LaunchAgent（`com.dsh.web`）——

- App 启动**不会**自动拉起服务；
- 退出 App **不会**停止服务；
- 服务崩溃**不会**自动重启（plist 无 KeepAlive）。

一切启动/重启/关闭都在主窗口操作，菜单栏只保留最常用的三件事。
点击菜单栏鲸鱼图标（🐋 绿=运行中 / 橙=端口被外部占用 / 红=异常退出 / 灰=未运行，官方 dsh 鲸鱼 logo 按状态着色）：**打开 Web**、**显示主窗口**、**退出 App**。
> 绿色 = launchd 托管进程在运行 **且** HTTP 3080 实际可访问，双条件缺一不亮绿。
服务进程继承你终端的 zsh 环境（PATH 等），agent 的 shell 工具直接可用 node/npm/pnpm/bun 等工具链。

![DSH 主窗口](docs/screenshot.png)

## 需要先手动执行 `npx @deepseek-ai/dsh web` 吗？

**不需要。** 前提只是"机器上装有 Node.js"：

- 首次打开 App：本地没有 dsh 时会自动弹出主窗口引导安装。点「安装 dsh」（实时显示下载日志），装完点「启动」即可，全程无需终端。
- 已有 dsh（全局安装或 npx 缓存）直接复用，无需重复安装。
- 如果端口 3080 被终端里手动跑的 `dsh web` 占着，点「启动」时 App 会结束它并接管（无需 Ctrl+C）；占用者不是 dsh 时会先弹确认，绝不误杀。

## 菜单栏（仅 3 项）

| 菜单项 | 作用 |
|---|---|
| 打开 Web (⌘O) | 浏览器打开 http://127.0.0.1:3080（服务未运行时置灰，先去主窗口「启动」） |
| 显示主窗口 | 打开/找回 DSH 控制台主窗口（关窗仅隐藏，可随时找回） |
| 退出 App (⌘Q) | 仅退出本 App，**不影响 dsh 服务**（服务常驻 launchd） |

## 主窗口（DSH 控制台）

| 区块 | 内容 |
|---|---|
| dsh 信息 | 服务状态、本地版本、npm 最新版、GitHub Release 最新版（npm 未发布的版本会标注「npm 未发布」并可跳转 Release 页）、运行中的 Profile、安装位置、Node 路径、端口 |
| 服务控制 | **启动 / 重启 / 关闭**；未安装时显示「安装 dsh」，已安装时显示「卸载 dsh」与「检查更新 / 更新 → vX」（安装、更新均有实时日志进度面板） |
| Profile | 列出 `~/.dsh/profiles/` 下的 profile（含 package.json 的子目录），显示各 profile 的 bundles 插件列表；选中后点「启动」即以该 profile 运行；「打开目录」直达 profile 文件夹 |
| 服务日志 | `~/Library/Logs/DSHLauncher/dsh-web.log` 尾部实时刷新，启动失败不用开终端排查 |
| 设置 | 登录时自动启动本 App（只影响 App 自身，不影响服务）、打开 `~/.dsh` 数据目录、打开日志目录 |

### 服务生命周期（v2.0 全手动）

| 动作 | 行为 |
|---|---|
| 启动 | 以当前选中的 profile 启动服务（端口被外部 dsh 占用 → 结束接管；被其他程序占用 → 确认后结束；运行中切换 profile → 弹确认后重启） |
| 重启 | 以当前 profile 停旧拉新，不弹确认 |
| 关闭 | 停止服务（`launchctl bootout` + 兜底结束端口上的 dsh 进程），保持停止直到再次手动启动 |
| 崩溃 | 状态红色「异常退出」，**不会自动重启**，需手动点「重启」 |
| 退出 / 重开 App | 服务照常运行 / 不会自动拉起，一切以主窗口按钮为准 |
| 更新 dsh | 更新前服务在跑 → 装完自动重启加载新版；更新前停着 → 保持停止 |

### 关于 Profile

dsh 的 profile 是「插件组合包按顺序叠加 + 个人覆盖层」的启动单元，位于 `~/.dsh/profiles/<name>`。
App 启动时扫描该目录（含 package.json 的子目录，跳过 `node_modules`）；`web`/`headless` 由 dsh
首次运行自动从模板初始化，其他 profile 需用 `dsh plugin --profile <name> ...` 创建（终端操作）。

- 选中 profile 只影响下一次「启动 / 重启」；同一时刻只有一个 profile 占用 3080 端口，**切换 = 用新 profile 重启服务**。
- 上次选中的 profile 会被记住；「运行 Profile」行显示当前实际运行（由本 App 启动）的 profile。
- 启动命令即 `dsh --profile <name> --port 3080 --no-open`（`dsh web` 只是 `--profile web` 的别名）。

## 安装（DMG 发行版）

从 [Releases](https://github.com/tttnny/DSH-Launcher/releases) 下载 `DSH-Launcher-*.dmg`：

1. 打开 DMG，把 `DSH Launcher.app` 拖进 **Applications**
2. 首次打开（未签名/未公证，Gatekeeper 会拦截）：Finder 里右键 `DSH Launcher.app` → **打开**；或执行
   ```bash
   xattr -dr com.apple.quarantine /Applications/DSH\ Launcher.app
   ```

要求：Apple Silicon Mac（M1/M2/M3/M4）· macOS 13 或更高 · 装有 Node.js（fnm / nvm / Homebrew 均可）。

## 构建

```bash
./build.sh        # 产出 dist/DSH Launcher.app（ad-hoc 签名，无需开发者账号）
```

产物为可直接运行的 `dist/DSH Launcher.app`，拷贝到任意位置（如 `~/Applications/`）即可使用。
源码结构：`Sources/main.swift`（launchd 托管、安装/更新、AppModel 状态模型）+
`Sources/MainWindow.swift`（SwiftUI 主窗口）。

## 技术要点

- **全手动生命周期**：服务 LaunchAgent（`com.dsh.web`）不带 `RunAtLoad`/`KeepAlive`——
  不登录自启、不崩溃自愈，启停完全由主窗口控制；App 退出不销毁服务。
- **环境继承**：launchd 本身没有你的 shell 配置，所以每次启动服务前，App 会用
  `zsh -lic` 抓取你的完整环境写入 plist 的 `EnvironmentVariables`（PATH 剔除易失的
  fnm multishell 临时目录、node 目录置顶）。服务进程与 agent 的 shell 工具因此
  直接可用终端同款工具链（node/npm/pnpm/bun 等），改 `.zshrc` 后重启服务即生效。
  **注意**：含 token/secret/password/api key/凭据等关键字的环境变量（如
  `DASHSCOPE_API_KEY`、`AWS_SECRET_ACCESS_KEY`）会被主动剔除，**不会**写入 plist
  明文落盘——请把 API key 配置在 `~/.dsh` 的 dsh 配置里（dsh 原生做法），
  不要依赖 .zshrc 环境变量传给服务内的 agent。
- **升级 dsh 无需改配置**：每次启动服务都会重新解析 node 与最新 dsh 包路径并
  重写 `~/Library/LaunchAgents/com.dsh.web.plist`。
- **双通道更新检测**：App 启动 10 秒后及每 6 小时各检查两个渠道（静默，不打扰）：
  · **npm registry**（`@deepseek-ai/dsh` 的 `latest` + `next` 两个 dist-tag，取版本更高者）——
  唯一可一键升级的渠道，与本地已装版本按 SemVer 2.0 比较（正确识别 rc/alpha/beta 预发布号），
  发现新版本时主窗口出现「更新 → vX」按钮（来自 `next` 预发布通道的目标版本会标注「（预发布）」），
  点击一键执行 `npm install -g @deepseek-ai/dsh@<目标版本>`（装确切版本，不写死 @latest）。
  · **GitHub Releases**（deepseek-ai/deepseek-harness）——官方 release 偶有领先 npm 的预发布
  （如 alpha 版，npm 上没有），信息区会显示「GitHub Release」最新版并标注「npm 未发布」，
  附「查看 Release」跳转链接；该频道仅提示，不提供自动安装（release 无产物）。
  更新日志：`~/Library/Logs/DSHLauncher/dsh-update.log`。
- **日志轮转**：`dsh-web.log` 超过 20MB 时在下次重启服务前自动轮转为 `.1`，
  防止无限增长占满磁盘。

## 卸载 dsh

不想继续用 dsh 了？主窗口点 **「卸载 dsh」**（仅已安装时显示），确认框里二选一：

- **仅卸载，保留 ~/.dsh**：停止服务 → `npm uninstall -g @deepseek-ai/dsh`
  并清理 npx 缓存，回到「未安装」状态。数据目录 `~/.dsh`（会话历史、配置）原样
  保留，之后可随时点「安装 dsh」无缝重装。
- **完全卸载，删除 ~/.dsh**：在仅卸载的基础上，连数据目录 `~/.dsh` 与服务
  LaunchAgent 配置（`com.dsh.web.plist`）一并删除——适合彻底不用、不想留任何
  数据的场景。**删除不可恢复，请先备份需要的会话记录。**

卸载日志：`~/Library/Logs/DSHLauncher/dsh-uninstall.log`。

## 卸载本 App

服务是独立 LaunchAgent，卸载 App 前先在主窗口点「关闭」停止服务（或直接用下面的 bootout）：

```bash
launchctl bootout gui/$(id -u)/com.dsh.web 2>/dev/null
launchctl bootout gui/$(id -u)/com.dsh.menubar 2>/dev/null
rm -f ~/Library/LaunchAgents/com.dsh.web.plist ~/Library/LaunchAgents/com.dsh.menubar.plist
rm -rf ~/Applications/DSH\ Launcher.app
```
