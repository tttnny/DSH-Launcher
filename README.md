# DSH Launcher — DeepSeek Harness 菜单栏 App

macOS 菜单栏小应用：把 `dsh web` 服务交给 launchd 托管，**不再需要开着终端**。
**App 在 → 服务就在：启动 App 自动拉起服务，退出 App 自动停止服务。**
点击菜单栏鲸鱼图标（🐋 绿=运行中 / 橙=端口被外部占用 / 红=启动失败 / 灰=未运行，图标为官方 dsh 鲸鱼 logo 按状态着色）即可控制。
启动后 3.5 秒健康检查，进程退出则弹日志尾部。

![DSH Launcher 菜单栏效果](docs/screenshot.png)

## 构建

```bash
./build.sh        # 产出 dist/DSH Launcher.app（ad-hoc 签名，无需开发者账号）
```

构建产物已安装到 `~/Applications/DSH Launcher.app`。改代码后重新 `./build.sh`，
再 `cp -R dist/DSH\ Launcher.app ~/Applications/` 覆盖即可。

## 菜单功能

| 菜单项 | 作用 |
|---|---|
| 状态行 | 服务是否运行（launchd 托管 / 外部实例占用 3080） |
| 打开 Web UI (⌘O) | 浏览器打开 http://127.0.0.1:3080 |
| 重启服务 | 永远可用：运行中=重启；启动失败/未运行=直接启动；端口被外部实例占用=弹窗说明占用者 |
| 登录时自动启动本 App | 登录后自动出现菜单栏图标并拉起服务 |
| 打开数据目录 | `~/.dsh` |
| 退出 | 退出 App **并停止服务**（`launchctl bootout`，数据已落盘，下次打开 App 即恢复） |

## 从终端实例切换（第一次使用）

现在端口 3080 可能还被终端里的 `dsh web` 占着（App 会显示橙色"外部实例"）。
切换步骤：

1. 在终端按 `Ctrl+C` 停掉旧的 `dsh web`（本次会话会离线，但历史记录都在 `~/.dsh/sessions/`）
2. 退出再打开 DSH Launcher（或点 **重启服务**），服务自动拉起
3. 状态变绿后点 **打开 Web UI**，历史会话完整可续

## 技术要点

- **服务定义**：`~/Library/LaunchAgents/com.dsh.web.plist`（600 权限），
  直接运行 `<fnm node> <npx缓存 dsh bin.js> web --port 3080`，不依赖 PATH——
  因为 launchd 登录环境里没有 node（你的 node 是 fnm 的临时 shim）。
- **自启定义**：`~/Library/LaunchAgents/com.dsh.menubar.plist`（仅 App 自启；服务不做登录自启，`RunAtLoad` 恒为 false，由用户手动启动）。
- **API key**：harness 直接从 `~/.dsh/.credentials.yaml` 读取，launchd 环境无需额外配置。
- 每次"启动服务"会重新解析 node 路径与最新的 dsh 包路径并重写 plist，
  升级 dsh（npx 缓存换目录）后无需手动改配置。
- 服务停止 = `launchctl bootout`，launchd 会终止整个进程树并落盘会话。
- 日志：`~/Library/Logs/DSHLauncher/dsh-web.log`。

## 卸载

```bash
launchctl bootout gui/$(id -u)/com.dsh.web 2>/dev/null
launchctl bootout gui/$(id -u)/com.dsh.menubar 2>/dev/null
rm -f ~/Library/LaunchAgents/com.dsh.web.plist ~/Library/LaunchAgents/com.dsh.menubar.plist
rm -rf ~/Applications/DSH\ Launcher.app
```
