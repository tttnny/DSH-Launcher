import AppKit
import Combine
import Foundation
import Darwin

// ============================================================
// DSH Launcher — DeepSeek Harness 菜单栏控制 App
// 菜单栏只保留：打开 Web / 显示主窗口 / 退出 App；
// 其余能力（dsh 信息、安装/卸载/更新、启动/重启/关闭服务、
// profile 选择启动、日志、设置）全部在 SwiftUI 主窗口（MainWindow.swift）。
//
// 服务生命周期（v2.0 起）：dsh 服务是独立的 launchd LaunchAgent
// （com.dsh.web），全手动控制——App 启动不自动拉起、退出不停服务、
// 崩溃不自愈（plist 无 KeepAlive）。UI 状态由 AppModel 发布，
// 菜单栏图标与主窗口共享。
// ============================================================

// MARK: - 小工具

func escapeXml(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

@discardableResult
func runProcess(_ launchPath: String, _ args: [String], timeout: TimeInterval? = nil, env: [String: String]? = nil) -> (code: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    if let env = env {
        p.environment = env
    }
    let outPipe = Pipe(); let errPipe = Pipe()
    p.standardOutput = outPipe; p.standardError = errPipe
    do { try p.run() } catch { return (-1, "", "spawn failed: \(error.localizedDescription)") }
    if let timeout {
        // 防止用户 shell 配置里有交互等待类命令导致启动流程卡死
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { p.terminate() }
        }
    }
    p.waitUntilExit()
    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, out, err)
}

/// 执行命令并把 stdout/stderr 实时追加写入日志文件（供安装面板展示进度）。
/// 返回退出码；调用方从日志文件尾部读取实时输出。
func runProcessLogging(_ launchPath: String, _ args: [String], timeout: TimeInterval, env: [String: String], logURL: URL) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    p.environment = env

    // 确保日志文件的父目录存在（否则 createFile 静默失败，安装/更新会报失败且无日志）
    let logDir = logURL.deletingLastPathComponent()
    try? fs.createDirectory(at: logDir, withIntermediateDirectories: true)
    // 确保日志文件存在，并以追加写模式打开（子进程 stdout/stderr 直接落盘）
    fs.createFile(atPath: logURL.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: logURL) else { return -1 }
    handle.seekToEndOfFile()
    p.standardOutput = handle
    p.standardError = handle

    do { try p.run() } catch { handle.closeFile(); return -1 }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        if p.isRunning { p.terminate() }
    }
    p.waitUntilExit()
    handle.closeFile()
    return p.terminationStatus
}

/// 清理全局 `@deepseek-ai` 包目录下的 npm 残留临时目录。
/// npm 安装/卸载异常中断时，会在包目录下留下 `<包名>-<6位随机>` 形式目录
/// （如 `.dsh-Attf9w6e`），内部可能堆积数万个文件。一旦超过 npm 的安全删除阈值
/// （SAFE_DELETE_BULK_CONFIRM_REQUIRED，默认 500 个），后续 `npm install -g` 升级
/// 会被安全保护拒绝、直接退出码 1，且不产生任何安装输出——用户看到的就是
/// 「更新失败且无日志」。安装/更新 dsh 前调用，删除 @deepseek-ai 下除 `dsh` 外的
/// 所有条目（含这类残留与历史版本），保证 npm 写目录时不会被拦截。
func cleanDshStagingResidue() {
    let node = resolveNodePath()
    let nodeDir = (node as NSString).deletingLastPathComponent
    guard nodeDir != "/usr/bin" else { return }
    let scopeDir = (nodeDir as NSString).deletingLastPathComponent + "/lib/node_modules/@deepseek-ai"
    guard let entries = try? fs.contentsOfDirectory(atPath: scopeDir) else { return }
    // 仅清理 npm 中断留下的隐藏临时目录（如 .dsh-Attf9w6e 或 .dsh.DELETE 等），不误删同一 scope 下的其他合法包
    for e in entries where e.hasPrefix(".dsh-") || (e.hasPrefix(".") && e.contains("dsh")) {
        try? fs.removeItem(atPath: "\(scopeDir)/\(e)")
    }
}

/// 向卸载日志追加一行（卸载面板实时展示进度用）。
func appendToUninstallLog(_ text: String) {
    guard let handle = try? FileHandle(forWritingTo: uninstallLogFile) else { return }
    handle.seekToEndOfFile()
    handle.write("[DSH Launcher] \(text)\n".data(using: .utf8) ?? Data())
    handle.closeFile()
}

/// 清理 npx 缓存（~/.npm/_npx/<hash>）里的 dsh 包目录。
/// 只删 dsh 包本身，不动缓存目录里可能存在的其他包。
/// 背景：App 判定「已安装」的条件是全局安装或 npx 缓存任一命中，
/// 只卸载全局包而留下 npx 缓存，会让 App 一直视为已安装、
/// 菜单回不到「安装 dsh」的首次安装流程。卸载流程收尾时调用。
func removeNpxCachedDsh() {
    let npxRoot = homeDir.appendingPathComponent(".npm/_npx").path
    guard let entries = try? fs.contentsOfDirectory(atPath: npxRoot) else { return }
    for e in entries {
        let pkg = "\(npxRoot)/\(e)/node_modules/@deepseek-ai/dsh"
        guard fs.fileExists(atPath: pkg) else { continue }
        if (try? fs.removeItem(atPath: pkg)) != nil {
            appendToUninstallLog("已清理 npx 缓存：\(pkg)")
        }
    }
}

/// 卸载后清理 `@deepseek-ai` 作用域残留：npm uninstall -g 移除 dsh 后，
/// 作用域目录常残留空壳（用户看到的"卸载不干净"），个别情况还会留下
/// `.package-lock.json` / `package-lock.json` 辅助文件。
/// 只清辅助文件与空壳目录，绝不碰同作用域下其他合法包。卸载流程收尾时调用。
func cleanDshScopeResidue(node: String) {
    let nodeDir = (node as NSString).deletingLastPathComponent
    guard nodeDir != "/usr/bin" else { return }
    let scopeDir = (nodeDir as NSString).deletingLastPathComponent + "/lib/node_modules/@deepseek-ai"
    guard let entries = try? fs.contentsOfDirectory(atPath: scopeDir) else { return }
    for e in entries where e == ".package-lock.json" || e == "package-lock.json" {
        try? fs.removeItem(atPath: "\(scopeDir)/\(e)")
        appendToUninstallLog("已清理作用域残留文件：\(scopeDir)/\(e)")
    }
    // 作用域已空 → 移除空壳目录（重装时 npm 会重建）
    if (try? fs.contentsOfDirectory(atPath: scopeDir))?.isEmpty == true {
        try? fs.removeItem(atPath: scopeDir)
        appendToUninstallLog("已清理 npm 卸载后的空作用域目录：\(scopeDir)")
    }
}

// MARK: - dsh 官方鲸鱼图标（菜单栏状态图标）
// 直接解析打包在 App 内的官方 favicon.svg（DeepSeek Harness 源码
// apps/web/public/favicon.svg，即 @deepseek-ai/dsh-web-frontend/dist/favicon.svg），
// 渲染为按状态着色的鲸鱼图标。

struct WhaleGlyph {
    let path: NSBezierPath
    let bounds: NSRect
}

func loadWhaleGlyph() -> WhaleGlyph? {
    guard let url = Bundle.main.url(forResource: "favicon", withExtension: "svg"),
          let svg = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    // viewBox="0 0 W H"
    var vbH: CGFloat = 50
    if let r = svg.range(of: "viewBox=\"") {
        let rest = svg[r.upperBound...]
        if let end = rest.firstIndex(of: "\"") {
            let nums = rest[..<end].split(separator: " ").compactMap { Double($0) }
            if nums.count == 4 { vbH = CGFloat(nums[3]) }
        }
    }
    // <path ... d="..." ...>  —— 取 path 元素内的 d 属性
    guard let pStart = svg.range(of: "<path")?.lowerBound else { return nil }
    let element = svg[pStart...]
    guard let dStart = element.range(of: " d=\"")?.upperBound else { return nil }
    let afterD = element[dStart...]
    guard let dEnd = afterD.firstIndex(of: "\"") else { return nil }
    return whaleBezier(String(afterD[..<dEnd]), viewBoxHeight: vbH)
}

func whaleBezier(_ d: String, viewBoxHeight: CGFloat) -> WhaleGlyph? {
    enum Tok { case cmd(Character); case num(CGFloat) }
    var toks: [Tok] = []
    var cur = ""
    for ch in d {
        if ch.isLetter {
            if !cur.isEmpty { toks.append(.num(CGFloat(Double(cur) ?? 0))); cur = "" }
            toks.append(.cmd(ch))
        } else if ch.isNumber || ch == "-" || ch == "." || ch == "+" {
            cur.append(ch)
        } else {
            if !cur.isEmpty { toks.append(.num(CGFloat(Double(cur) ?? 0))); cur = "" }
        }
    }
    if !cur.isEmpty { toks.append(.num(CGFloat(Double(cur) ?? 0))) }

    let path = NSBezierPath()
    var i = 0
    var x: CGFloat = 0, y: CGFloat = 0
    var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
    var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
    func track(_ p: NSPoint) {
        minX = min(minX, p.x); minY = min(minY, p.y)
        maxX = max(maxX, p.x); maxY = max(maxY, p.y)
    }
    func next(_ k: Int) -> [CGFloat] {
        var out: [CGFloat] = []
        while out.count < k && i < toks.count {
            if case .num(let v) = toks[i] { out.append(v) }
            i += 1
        }
        return out
    }
    while i < toks.count {
        if case .cmd(let c) = toks[i] {
            i += 1
            switch c {
            case "M", "m":
                let p = next(2); guard p.count == 2 else { break }
                x = p[0]; y = viewBoxHeight - p[1] // SVG y 向下，翻转
                let pt = NSPoint(x: x, y: y); track(pt)
                path.move(to: pt)
            case "C", "c":
                let p = next(6); guard p.count == 6 else { break }
                let c1 = NSPoint(x: p[0], y: viewBoxHeight - p[1])
                let c2 = NSPoint(x: p[2], y: viewBoxHeight - p[3])
                let e  = NSPoint(x: p[4], y: viewBoxHeight - p[5])
                track(c1); track(c2); track(e)
                path.curve(to: e, controlPoint1: c1, controlPoint2: c2)
                x = p[4]; y = viewBoxHeight - p[5]
            case "Z", "z":
                path.close()
            default:
                break
            }
        } else {
            i += 1
        }
    }
    return WhaleGlyph(path: path,
                      bounds: NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
}

private var cachedWhaleGlyph: WhaleGlyph?

/// 渲染指定颜色的鲸鱼菜单栏图标（2x 渲染保证 Retina 清晰）
func whaleMenuImage(color: NSColor, pointSize: CGFloat = 18) -> NSImage? {
    if cachedWhaleGlyph == nil { cachedWhaleGlyph = loadWhaleGlyph() }
    guard let glyph = cachedWhaleGlyph else { return nil }
    let scale: CGFloat = 2
    let px = Int(pointSize * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let size = CGFloat(px)
    let s = (size * 0.86) / glyph.bounds.width // 鲸鱼按官方 favicon 原比例（宽约占 86%）居中
    let t = NSAffineTransform()
    t.translateX(by: (size - glyph.bounds.width * s) / 2 - glyph.bounds.minX * s,
                 yBy: (size - glyph.bounds.height * s) / 2 - glyph.bounds.minY * s)
    t.scale(by: s)
    color.setFill()
    t.transform(glyph.path).fill()
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    let img = NSImage(size: NSSize(width: pointSize, height: pointSize))
    img.addRepresentation(rep)
    return img
}

// MARK: - 路径与常量

let fs = FileManager.default
let homeDir = fs.homeDirectoryForCurrentUser
let launchAgentsDir = homeDir.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
let logDir = homeDir.appendingPathComponent("Library/Logs/DSHLauncher", isDirectory: true)
let logFile = logDir.appendingPathComponent("dsh-web.log")
let installLogFile = logDir.appendingPathComponent("dsh-install.log")
let updateLogFile = logDir.appendingPathComponent("dsh-update.log")
let uninstallLogFile = logDir.appendingPathComponent("dsh-uninstall.log")
let serviceLabel = "com.dsh.web"
let appLabel = "com.dsh.menubar"
let servicePlistURL = launchAgentsDir.appendingPathComponent("\(serviceLabel).plist")
let appPlistURL = launchAgentsDir.appendingPathComponent("\(appLabel).plist")
let guiDomain = "gui/\(getuid())"
let webURL = URL(string: "http://127.0.0.1:3080")!
// 完整包元数据端点：含 dist-tags（latest / next 等），用于检测 dsh 更新
let npmRegistryURL = URL(string: "https://registry.npmjs.org/@deepseek-ai/dsh")!
// GitHub Releases：dsh 官方发布页。注意所有 dsh release 都是 prerelease（rc/alpha），
// `releases/latest` 端点会排除 prerelease，因此拉列表取 tag 语义版本最高者。
// 未认证配额 60 次/小时/IP，每次检查只用 1 个请求，足够。
let githubReleasesURL = URL(string: "https://api.github.com/repos/deepseek-ai/deepseek-harness/releases?per_page=10")!
let defaults = UserDefaults.standard

// MARK: - node / dsh web 路径解析
// 用户的 node 来自 fnm（登录 shell 临时 shim，launchd 环境里没有），
// 所以必须解析出真实绝对路径写进 LaunchAgent。

func firstExisting(_ paths: [String]) -> String? {
    paths.first { fs.fileExists(atPath: $0) }
}

func resolveNodePath() -> String {
    if let saved = defaults.string(forKey: "nodePath"), fs.fileExists(atPath: saved) {
        return saved
    }
    // fnm：~/.local/share/fnm/node-versions/<版本>/installation/bin/node
    let fnmBase = homeDir.appendingPathComponent(".local/share/fnm/node-versions").path
    if let versions = try? fs.contentsOfDirectory(atPath: fnmBase) {
        let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in sorted {
            let candidate = "\(fnmBase)/\(v)/installation/bin/node"
            if fs.fileExists(atPath: candidate) { return candidate }
        }
    }
    // nvm：~/.nvm/versions/node/<版本>/bin/node
    let nvmBase = homeDir.appendingPathComponent(".nvm/versions/node").path
    if let versions = try? fs.contentsOfDirectory(atPath: nvmBase) {
        let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in sorted {
            let candidate = "\(nvmBase)/\(v)/bin/node"
            if fs.fileExists(atPath: candidate) { return candidate }
        }
    }
    if let found = firstExisting(["/opt/homebrew/bin/node", "/usr/local/bin/node"]) { return found }
    return "/usr/bin/env" // 最后兜底：靠 PATH 找 node（launchd 里通常没有）
}

func resolveDshLauncher(nodePath: String) -> String? {
    let nodeDir = (nodePath as NSString).deletingLastPathComponent
    if nodeDir != "/usr/bin" {
        let global = "\(nodeDir)/dsh"
        if fs.fileExists(atPath: global) { return global }
    }
    // npx 缓存：~/.npm/_npx/<hash>/node_modules/@deepseek-ai/dsh/lib/bin.js，取最新的
    let npxRoot = homeDir.appendingPathComponent(".npm/_npx").path
    if let entries = try? fs.contentsOfDirectory(atPath: npxRoot) {
        var best: (path: String, mtime: Date)? = nil
        for e in entries {
            let candidate = "\(npxRoot)/\(e)/node_modules/@deepseek-ai/dsh/lib/bin.js"
            guard fs.fileExists(atPath: candidate),
                  let attrs = try? fs.attributesOfItem(atPath: candidate) else { continue }
            let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            if best == nil || mtime > best!.mtime { best = (candidate, mtime) }
        }
        if let b = best { return b.path }
    }
    return nil
}

// MARK: - 偏好设置

func workspacePath() -> String {
    // 默认工作目录固定为 home；若用户显式设置过 workspacePath 且目录存在则用自定义值
    if let saved = defaults.string(forKey: "workspacePath"), !saved.isEmpty,
       fs.fileExists(atPath: saved) {
        return saved
    }
    return homeDir.path
}

// MARK: - LaunchAgent 操作

@discardableResult
func launchctl(_ args: [String]) -> (code: Int32, text: String) {
    let r = runProcess("/bin/launchctl", args)
    return (r.code, r.out + r.err)
}

func serviceLoaded() -> Bool {
    let (code, text) = launchctl(["print", "\(guiDomain)/\(serviceLabel)"])
    return code == 0 && text.contains("state = ")
}

func serviceRunning() -> Bool {
    let (code, text) = launchctl(["print", "\(guiDomain)/\(serviceLabel)"])
    return code == 0 && text.contains("state = running")
}

func portServing() -> Bool {
    let r = runProcess("/usr/bin/curl", ["-s", "-o", "/dev/null", "-m", "2", "-w", "%{http_code}", "http://127.0.0.1:3080/"])
    let code = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    return !code.isEmpty && code != "000"
}

/// 找出占用 3080 端口的进程（lsof + ps），返回 PID 与完整命令行；无占用返回 nil。
func port3080Process() -> (pid: Int32, cmd: String)? {
    let r = runProcess("/usr/sbin/lsof", ["-nP", "-iTCP:3080", "-sTCP:LISTEN"])
    var lines = r.out.components(separatedBy: .newlines)
    if let first = lines.first, first.hasPrefix("COMMAND") { lines.removeFirst() }
    guard let first = lines.first else { return nil }
    let fields = first.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
    guard fields.count >= 2, let pid = Int32(fields[1]) else { return nil }
    let p = runProcess("/bin/ps", ["-p", "\(pid)", "-o", "command="])
    let cmd = p.out.trimmingCharacters(in: .whitespacesAndNewlines)
    return (pid, cmd)
}

/// 找出占用 3080 端口的进程描述，用于启动前提示
func port3080Occupier() -> String {
    guard let (pid, cmd) = port3080Process() else { return "未知进程" }
    return "PID \(pid)（\(cmd.isEmpty ? "未知命令" : cmd)）"
}

/// 判断占用 3080 端口的进程是否是 dsh（外部实例，如终端里手动跑的 dsh web）。
/// 通过命令行识别：dsh 进程形如 `node .../@deepseek-ai/dsh/lib/bin.js web --port 3080`
/// 或 `dsh web --port 3080`。
/// 识别规则（尽量精确，减少误判）：
/// - 命令行含 "deepseek-ai"（dsh 包路径特征，最可靠）
/// - "dsh" 作为独立命令词出现（前后非字母数字），排除 `--dsh-mode` 之类含子串的无关进程
func port3080IsDsh() -> Bool {
    guard let (_, cmd) = port3080Process() else { return false }
    let lower = cmd.lowercased()
    if lower.contains("deepseek-ai") { return true }
    return lower.range(of: "(^|[^a-z0-9])dsh([^a-z0-9]|$)", options: .regularExpression) != nil
}

/// 结束占用 3080 端口的进程（先 SIGTERM 优雅退出，2 秒后仍未释放则 SIGKILL）。
/// 返回端口是否已释放（无占用时视为成功）。
@discardableResult
func killPort3080() -> Bool {
    guard let (pid, _) = port3080Process() else { return true }
    runProcess("/bin/kill", ["\(pid)"]) // SIGTERM 优雅退出
    for _ in 0..<20 {                    // 最多等 2 秒
        if port3080Process() == nil { return true }
        usleep(100_000)
    }
    runProcess("/bin/kill", ["-9", "\(pid)"]) // SIGKILL 兜底
    for _ in 0..<10 {                    // 再等 1 秒
        if port3080Process() == nil { return true }
        usleep(100_000)
    }
    return port3080Process() == nil
}

/// 只结束「dsh 占用 3080」的进程（先 SIGTERM，2 秒未释放再 SIGKILL）。
/// 与 killPort3080 不同：绝不碰非 dsh 程序，保证「退出 App → 只停 dsh」的契约。
/// 返回是否已无 dsh 占用（无 dsh 占用时视为成功）。
@discardableResult
func killDshOnPort3080() -> Bool {
    guard let (pid, cmd) = port3080Process() else { return true }
    guard cmd.localizedCaseInsensitiveContains("dsh") ||
          cmd.localizedCaseInsensitiveContains("deepseek-ai") else { return true }
    runProcess("/bin/kill", ["\(pid)"])
    for _ in 0..<20 {
        if !port3080IsDsh() { return true }
        usleep(100_000)
    }
    runProcess("/bin/kill", ["-9", "\(pid)"])
    for _ in 0..<10 {
        if !port3080IsDsh() { return true }
        usleep(100_000)
    }
    return !port3080IsDsh()
}

/// 日志文件尾部（通用），用于弹窗展示 / 面板实时进度
func tail(of url: URL, n: Int = 25, placeholder: String = "(日志为空)") -> String {
    guard let data = fs.contents(atPath: url.path),
          let text = String(data: data, encoding: .utf8) else { return placeholder }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? placeholder : text.components(separatedBy: .newlines).suffix(n).joined(separator: "\n")
}

/// 服务日志尾部，用于启动失败时弹窗展示
func logTail(_ n: Int = 25) -> String {
    tail(of: logFile, n: n, placeholder: "(日志为空)")
}

/// 安装日志尾部，用于安装面板实时展示下载/安装进度
func installLogTail(_ n: Int = 30) -> String {
    tail(of: installLogFile, n: n, placeholder: "(等待输出…)")
}

/// 更新日志尾部，用于更新面板实时展示进度
func updateLogTail(_ n: Int = 30) -> String {
    tail(of: updateLogFile, n: n, placeholder: "(等待输出…)")
}

/// 卸载日志尾部，用于卸载面板实时展示进度
func uninstallLogTail(_ n: Int = 30) -> String {
    tail(of: uninstallLogFile, n: n, placeholder: "(等待输出…)")
}

enum ServiceState: Hashable { case running, starting, installing, notInstalled, portBusy, crashed, stopped }

/// 服务正在启动（App 自动拉起 / 手动重启的窗口期），期间状态显示“正在启动”
var isStarting = false
/// 启动时本地无 dsh 缓存 → 正在通过 npx 首次联网安装 dsh（区别于普通启动）
var isInstallingDsh = false

/// dsh 本地安装信息缓存：dshInstalled/localDshVersion 每次调用都要扫 fnm/npx 目录
/// 并读 package.json，而 refresh() 每 5 秒各调一次——用缓存避免无谓的重复扫盘。
/// key 是 node 路径：node 没变时安装状态与版本视为不变；安装/更新完成后显式失效。
private var dshInfoCache: (node: String, installed: Bool, version: String?)?

/// 安装/更新完成后调用：dsh 版本或安装状态已变化，下次读取重新扫描。
func invalidateDshInfo() {
    dshInfoCache = nil
}

func cachedDshInfo() -> (node: String, installed: Bool, version: String?) {
    let node = resolveNodePath()
    if let c = dshInfoCache, c.node == node { return c }
    let installed = resolveDshLauncher(nodePath: node) != nil
    let version = localDshVersionUncached(node: node)
    let info = (node, installed, version)
    dshInfoCache = info
    return info
}

/// 本地是否已安装 dsh（全局安装或 npx 缓存任一命中）。
/// 安装完成后此函数返回 true，UI 自动从“未安装”进入正常流程。
func dshInstalled() -> Bool {
    cachedDshInfo().installed
}

/// 读取 package.json 的 version 字段
func versionFromPackage(_ pkgPath: String) -> String? {
    guard let data = fs.contents(atPath: pkgPath),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let v = obj["version"] as? String, !v.isEmpty else { return nil }
    return v
}

/// 本地已安装的 dsh 版本号（全局 npm 安装或 npx 缓存任一命中，带缓存）。
func localDshVersion() -> String? {
    cachedDshInfo().version
}

/// 实际扫描逻辑（无缓存）：全局安装或 npx 缓存任一命中。
/// 全局安装：<node 安装前缀>/lib/node_modules/@deepseek-ai/dsh/package.json
/// （fnm: ~/.local/share/fnm/node-versions/<v>/installation/lib/node_modules/...
///  nvm: ~/.nvm/versions/node/<v>/lib/node_modules/...）
/// npx 缓存：~/.npm/_npx/<hash>/node_modules/@deepseek-ai/dsh/package.json（取最新 mtime）。
func localDshVersionUncached(node: String) -> String? {
    let nodeDir = (node as NSString).deletingLastPathComponent
    var candidates: [String] = []
    if nodeDir != "/usr/bin" {
        let prefix = (nodeDir as NSString).deletingLastPathComponent
        candidates.append("\(prefix)/lib/node_modules/@deepseek-ai/dsh/package.json")
    }
    let npxRoot = homeDir.appendingPathComponent(".npm/_npx").path
    if let entries = try? fs.contentsOfDirectory(atPath: npxRoot) {
        var best: (path: String, mtime: Date)? = nil
        for e in entries {
            let pkg = "\(npxRoot)/\(e)/node_modules/@deepseek-ai/dsh/package.json"
            guard fs.fileExists(atPath: pkg),
                  let attrs = try? fs.attributesOfItem(atPath: pkg) else { continue }
            let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            if best == nil || mtime > best!.mtime { best = (pkg, mtime) }
        }
        if let b = best { candidates.append(b.path) }
    }
    for c in candidates where fs.fileExists(atPath: c) {
        if let v = versionFromPackage(c) { return v }
    }
    return nil
}

/// Semver 2.0 比较。正确处理 prerelease（rc/alpha/beta 等）：
/// - `0.1.0-rc.6` < `0.1.0-rc.7`（逐段比较 prerelease 标识，数字按数字比、字符串按 ASCII 比）
/// - `0.1.0-rc.1` < `0.1.0`（无 prerelease 的版本 > 有 prerelease 的版本）
/// - 忽略 `+build` 后缀（按 spec build 不参与排序）
func isNewerVersion(_ a: String, than b: String) -> Bool {
    // 解析为 (核心号 [Int], prerelease 标识 [String])
    func parse(_ raw: String) -> ([Int], [String]) {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        let main = v.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = String(main[0]).split(separator: ".").compactMap { Int($0) }
        let pre = main.count > 1 ? String(main[1]) : ""
        let preClean = pre.split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
        let preIds = preClean.isEmpty ? [] : preClean.split(separator: ".").map(String.init)
        return (core, preIds)
    }
    // 比较核心号，-1/0/1
    func cmpCore(_ x: [Int], _ y: [Int]) -> Int {
        for i in 0..<max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0
            let yi = i < y.count ? y[i] : 0
            if xi != yi { return xi < yi ? -1 : 1 }
        }
        return 0
    }
    // 比较 prerelease 标识列表，-1/0/1（spec：无 prerelease > 有 prerelease）
    func cmpPre(_ x: [String], _ y: [String]) -> Int {
        if x.isEmpty && y.isEmpty { return 0 }
        if x.isEmpty { return 1 }
        if y.isEmpty { return -1 }
        for i in 0..<max(x.count, y.count) {
            if i >= x.count { return -1 } // 短的更小
            if i >= y.count { return 1 }
            let xi = x[i], yi = y[i]
            let xIsNum = Int(xi) != nil, yIsNum = Int(yi) != nil
            if xIsNum && yIsNum {
                let xn = Int(xi)!, yn = Int(yi)!
                if xn != yn { return xn < yn ? -1 : 1 }
            } else if xIsNum {
                return -1 // 数字标识 < 字符串标识
            } else if yIsNum {
                return 1
            } else if xi != yi {
                return xi < yi ? -1 : 1
            }
        }
        return 0
    }
    let (ac, ap) = parse(a), (bc, bp) = parse(b)
    let c = cmpCore(ac, bc)
    if c != 0 { return c > 0 }
    return cmpPre(ap, bp) > 0
}

/// 查询 npm registry 上 @deepseek-ai/dsh 的目标更新版本；失败（网络/解析）返回 nil。
/// 遍历所有 dist-tag（latest, next, alpha, beta, rc, canary 等）以及 versions 列表，取最高语义版本。
/// 返回 `(版本, 是否预发布通道, 对应的 tag 名称)`。
func fetchLatestDshVersion(completion: @escaping (_ version: String?, _ isPreview: Bool, _ tag: String?) -> Void) {
    var req = URLRequest(url: npmRegistryURL)
    req.timeoutInterval = 10
    URLSession.shared.dataTask(with: req) { data, _, error in
        guard error == nil, let data = data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            completion(nil, false, nil)
            return
        }
        let tags = obj["dist-tags"] as? [String: Any] ?? [:]
        let latest = tags["latest"] as? String

        // 收集所有候选版本（来自所有 dist-tag 以及 versions 字典）
        var candidateVersions = Set<String>()
        for (_, val) in tags {
            if let v = val as? String, !v.isEmpty {
                candidateVersions.insert(v)
            }
        }
        if let versionsDict = obj["versions"] as? [String: Any] {
            for v in versionsDict.keys where !v.isEmpty {
                candidateVersions.insert(v)
            }
        }

        // 挑选最高语义版本
        var best: String? = latest
        for v in candidateVersions {
            if best == nil || isNewerVersion(v, than: best!) {
                best = v
            }
        }

        guard let bestVersion = best else {
            completion(nil, false, nil)
            return
        }

        let isPreview = (latest == nil || bestVersion != latest)
        // 查找对应的 tag 名称（优先非 latest 的 tag，例如 "alpha", "next"）
        var matchedTag: String? = nil
        for (tagKey, val) in tags {
            if let v = val as? String, v == bestVersion {
                if tagKey != "latest" {
                    matchedTag = tagKey
                    break
                } else if matchedTag == nil {
                    matchedTag = "latest"
                }
            }
        }

        completion(bestVersion, isPreview, matchedTag)
    }.resume()
}

/// 查询 GitHub Release 频道的最新版本（tag 形如 `dsh-v0.1.2-alpha.1`）。
/// npm 上未发布的版本（如 alpha 预发布）只能在这里检测到；仅作信息展示，
/// 不参与一键升级（GitHub release 无产物，装不了）。
/// 返回 `(版本, release 页面 URL, 是否 prerelease)`；失败（网络/限流/解析）返回 nil。
func fetchLatestGithubRelease(completion: @escaping (_ version: String?, _ url: String?, _ isPrerelease: Bool) -> Void) {
    var req = URLRequest(url: githubReleasesURL)
    req.timeoutInterval = 10
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: req) { data, _, error in
        guard error == nil, let data = data,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            completion(nil, nil, false)
            return
        }
        var best: (version: String, url: String, pre: Bool)? = nil
        for item in list {
            guard let tag = item["tag_name"] as? String else { continue }
            // 兼容多种 tag 命名：dsh-v0.1.2、dsh@0.1.2、v0.1.2、0.1.2
            var v = tag
            if v.hasPrefix("dsh-v") {
                v = String(v.dropFirst("dsh-v".count))
            } else if v.hasPrefix("dsh@v") {
                v = String(v.dropFirst("dsh@v".count))
            } else if v.hasPrefix("dsh@") {
                v = String(v.dropFirst("dsh@".count))
            } else if v.hasPrefix("v") || v.hasPrefix("V") {
                v = String(v.dropFirst(1))
            }
            guard !v.isEmpty else { continue }
            let url = item["html_url"] as? String ?? "https://github.com/deepseek-ai/deepseek-harness/releases"
            let pre = item["prerelease"] as? Bool ?? true
            if best == nil || isNewerVersion(v, than: best!.version) {
                best = (v, url, pre)
            }
        }
        completion(best?.version, best?.url, best?.pre ?? false)
    }.resume()
}

/// 服务状态判定。核心原则：只看 3080 端口上跑的是不是 dsh，不关心谁在托管。
/// - 端口上是 dsh → 绿色（无论 App 托管 / 终端手动 / 孤儿进程，本质同一个服务）
/// - 端口被非 dsh 程序占用 → 橙色（dsh 真的不可用）
func serviceState() -> ServiceState {
    // 手动安装进行中（installDsh 设置了 isInstallingDsh），优先显示“安装中”
    if isStarting || isInstallingDsh { return isInstallingDsh ? .installing : .starting }
    if !dshInstalled() { return .notInstalled }
    if port3080IsDsh() { return .running }
    // 端口被非 dsh 程序占用：dsh 不可用
    if portServing() { return .portBusy }
    // launchd 任务在跑但端口上无 dsh：启动失败或进程崩溃（窗口期外）
    if serviceRunning() { return .crashed }
    if serviceLoaded() {
        // 只有“任务已加载、进程没在跑、且上次退出码非 0”才算真失败；
        // 刚启动的过渡期（bootstrap 后进程尚未就绪）会显示 last exit code =
        // (never exited) 或 0，不应误报为失败。
        let (_, text) = launchctl(["print", "\(guiDomain)/\(serviceLabel)"])
        if let range = text.range(of: "last exit code = "),
           let value = text[range.upperBound...].split(separator: " ").first,
           value != "(never exited)", value != "0" {
            return .crashed
        }
        return .stopped
    }
    return .stopped
}

func writePlist(_ url: URL, _ xml: String) -> Bool {
    do {
        try fs.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try xml.write(to: url, atomically: true, encoding: .utf8)
        try fs.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    } catch {
        return false
    }
}

func resolveNpxPath(nodePath: String) -> String? {
    let nodeDir = (nodePath as NSString).deletingLastPathComponent
    let npx = "\(nodeDir)/npx"
    return fs.fileExists(atPath: npx) ? npx : nil
}

func resolveNpmPath(nodePath: String) -> String? {
    let nodeDir = (nodePath as NSString).deletingLastPathComponent
    let npm = "\(nodeDir)/npm"
    return fs.fileExists(atPath: npm) ? npm : nil
}

// MARK: - shell 环境继承
// launchd 拉起的进程只有精简环境（PATH=/usr/bin:/bin:/usr/sbin:/sbin），
// 用户的 node/pnpm/bun 等工具都配置在 shell 启动文件（.zprofile/.zshrc）里。
// 因此写 LaunchAgent 前用 `zsh -lic` 抓一次用户完整环境，写入
// EnvironmentVariables，让 dsh web 服务进程（及其所有子进程）继承终端的全部配置。

/// 敏感环境变量判定：含 token/secret/password/api key/凭据等关键字的一律剔除，
/// 不写入 LaunchAgent plist（文件虽为 0600，但明文落盘仍是泄露面）。
func isSensitiveEnvKey(_ key: String) -> Bool {
    let upper = key.uppercased()
    return ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "APIKEY", "API_KEY",
            "PRIVATE_KEY", "CREDENTIAL", "AUTH", "AWS_ACCESS", "AWS_SECRET"]
        .contains { upper.contains($0) }
}

/// 上次抓取 shell 环境是否失败。失败意味着服务只能拿到精简环境，
/// 用户终端里的 node/npm/pnpm/bun 等工具链可能不可用，用于 UI 提示。
var lastEnvCaptureFailed = false

/// 抓取用户登录 shell 的完整环境（`zsh -lic` 会读 .zprofile + .zshrc）。
/// 返回 [:] 表示抓取失败（调用方自行降级）。
func captureShellEnvironment(timeout: TimeInterval = 8) -> [String: String] {
    let r = runProcess("/bin/zsh", ["-lic", "env -0"], timeout: timeout)
    guard r.code == 0 else {
        lastEnvCaptureFailed = true
        return [:]
    }
    lastEnvCaptureFailed = false
    var env: [String: String] = [:]
    for chunk in r.out.split(separator: "\0") {
        guard let eq = chunk.firstIndex(of: "=") else { continue }
        let key = String(chunk[..<eq])
        let value = String(chunk[chunk.index(after: eq)...])
        if key.isEmpty { continue }
        env[key] = value
    }
    // 会话专属/易失变量：PWD 等由 launchd 自设；TERM 由 dsh 的 bash 工具强制覆盖；
    // FNM_MULTISHELL_PATH 指向的 fnm 临时目录随抓取进程退出即被清理，绝不能写进 plist
    for junk in ["PWD", "OLDPWD", "SHLVL", "_", "TERM", "FNM_MULTISHELL_PATH"] {
        env.removeValue(forKey: junk)
    }
    // 敏感变量（token/密钥/口令/凭据等）不写入明文 plist，防止泄露到磁盘
    for key in Array(env.keys) where isSensitiveEnvKey(key) {
        env.removeValue(forKey: key)
    }
    return env
}

/// 修复 PATH：剔除随 shell 会话失效的 fnm multishell 临时目录，
/// 并保证 node 所在的稳定 bin 目录排在 PATH 最前。
func repairedPATH(from raw: String, nodeDir: String) -> String {
    var parts = raw.split(separator: ":").map(String.init)
    parts.removeAll { $0.contains("fnm_multishells") }
    if !parts.contains(nodeDir) { parts.insert(nodeDir, at: 0) }
    return parts.joined(separator: ":")
}

/// 组装服务进程要继承的环境：抓取 zsh 完整环境并修复 PATH；
/// 抓取失败时降级为「node bin 目录 + 系统默认 PATH」。
func serviceEnvironment(nodePath: String) -> [String: String] {
    let nodeDir = (nodePath as NSString).deletingLastPathComponent
    var env = captureShellEnvironment()
    if let path = env["PATH"], !path.isEmpty {
        env["PATH"] = repairedPATH(from: path, nodeDir: nodeDir)
    } else {
        env["PATH"] = "\(nodeDir):/usr/bin:/bin:/usr/sbin:/sbin"
    }
    return env
}

/// 生成服务的完整启动命令：以 `--profile <name>` 启动 ~/.dsh/profiles/<name>
/// （`dsh web` 只是 `--profile web` 的别名）。优先直接跑缓存的 dsh bin.js；
/// 没有缓存时退回 `npx --yes @deepseek-ai/dsh`（首次会联网下载，之后就有缓存了），
/// 保证朋友的机器开箱即用。
/// 注意：dsh 只允许绑定 127.0.0.1（官方禁止 `--host 0.0.0.0`），
/// 局域网访问请安装社区插件 moxisuki/dsh-lan，与本 App 无关。
/// 启动器的 flag 必须写在最前面，其后的 `--port`/`--no-open` 属于 web 应用。
func buildProgram(profile: String) -> [String]? {
    let node = resolveNodePath()
    var base: [String]
    if let dsh = resolveDshLauncher(nodePath: node) {
        base = [node, dsh]
    } else if let npx = resolveNpxPath(nodePath: node) {
        base = [node, npx, "--yes", "@deepseek-ai/dsh"]
    } else {
        return nil
    }
    // --no-open：服务由 launchd 托管拉起时不应每次弹浏览器；
    // 需要打开 UI 时用户直接点菜单栏「打开 Web」。
    return base + ["--profile", profile, "--port", "3080", "--no-open"]
}

func servicePlistXML(program: [String], workspace: String, env: [String: String]) -> String {
    let argsXML = program.map { "        <string>\(escapeXml($0))</string>" }.joined(separator: "\n")
    let envXML = env.keys.sorted()
        .map { "        <key>\(escapeXml($0))</key><string>\(escapeXml(env[$0]!))</string>" }
        .joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(serviceLabel)</string>
      <key>ProgramArguments</key>
      <array>
    \(argsXML)
      </array>
      <key>WorkingDirectory</key><string>\(escapeXml(workspace))</string>
      <key>EnvironmentVariables</key>
      <dict>
    \(envXML)
      </dict>
      <key>RunAtLoad</key><false/>
      <key>ThrottleInterval</key><integer>10</integer>
      <key>StandardOutPath</key><string>\(escapeXml(logFile.path))</string>
      <key>StandardErrorPath</key><string>\(escapeXml(logFile.path))</string>
    </dict>
    </plist>
    """
}

/// 日志轮转：超过上限（默认 20MB）时把当前日志改名为 `.1`（覆盖旧备份），下次启动重建。
/// 在重启服务前调用：launchd 会在 bootstrap 时按 StandardOutPath 重建文件。
func rotateLogIfNeeded(_ url: URL, maxBytes: UInt64 = 20 * 1024 * 1024) {
    guard let attrs = try? fs.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? UInt64, size > maxBytes else { return }
    let backup = URL(fileURLWithPath: url.path + ".1")
    try? fs.removeItem(at: backup)
    try? fs.moveItem(at: url, to: backup)
}

/// 向服务日志追加一行（供补丁等启动期事件留痕）。
func appendToServiceLog(_ text: String) {
    try? fs.createDirectory(at: logDir, withIntermediateDirectories: true)
    guard let handle = try? FileHandle(forWritingTo: logFile) else { return }
    handle.seekToEndOfFile()
    handle.write("[DSH Launcher] \(text)\n".data(using: .utf8) ?? Data())
    handle.closeFile()
}

/// 定位 @deepseek-ai/dsh-tool-cordis 的 lib/index.js（npm 全局 / pnpm 布局均覆盖）。
func dshToolCordisIndexPath() -> String? {
    let node = resolveNodePath()
    let nodeDir = (node as NSString).deletingLastPathComponent
    guard nodeDir != "/usr/bin" else { return nil }
    let globalScope = (nodeDir as NSString).deletingLastPathComponent + "/lib/node_modules/@deepseek-ai"
    // 候选 1：扁平全局布局 node_modules/@deepseek-ai/dsh-tool-cordis/lib/index.js
    let flat = "\(globalScope)/dsh-tool-cordis/lib/index.js"
    if fs.fileExists(atPath: flat) { return flat }
    // 候选 2：dsh 嵌套依赖 node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-tool-cordis/lib/index.js
    let nested = "\(globalScope)/dsh/node_modules/@deepseek-ai/dsh-tool-cordis/lib/index.js"
    if fs.fileExists(atPath: nested) { return nested }
    // 候选 3：pnpm 布局 node_modules/@deepseek-ai/dsh/node_modules/.pnpm/@deepseek-ai+dsh-tool-cordis@*/node_modules/@deepseek-ai/dsh-tool-cordis/lib/index.js
    let pnpmDir = "\(globalScope)/dsh/node_modules/.pnpm"
    if let entries = try? fs.contentsOfDirectory(atPath: pnpmDir) {
        for e in entries where e.hasPrefix("@deepseek-ai+dsh-tool-cordis@") {
            let cand = "\(pnpmDir)/\(e)/node_modules/@deepseek-ai/dsh-tool-cordis/lib/index.js"
            if fs.fileExists(atPath: cand) { return cand }
        }
    }
    return nil
}

/// 适配「创造模式」多预设共存：给 @deepseek-ai/dsh-tool-cordis 打幂等补丁。
///
/// 背景：dsh-tool-cordis 挂载时向进程全局单例 cordisInspect 注册一组 Host
/// inspect provider（Service/Event/Builtin/Tool）。第二个带 tool-cordis 的 agent
/// preset（如「PTC-创造 混合模式」ptc-cordis 与「创造模式」cordis 并存）再挂载时，
/// 注册表已含同名 provider，抛 "Host Cordis inspect provider ... already registered"，
/// 导致第二个预设挂载失败、Web 会话秒退为标准模式。
///
/// 修复：apply() 注册前先列出已注册的 host provider，同 id 幂等跳过。
/// provider 是同一包的静态目录描述，重复注册无意义也无害；
/// 工具（cordis_define 等）与提示按 scope 分层各自注册，不受影响。
///
/// dsh 升级（npm install -g）会覆盖 node_modules 使补丁丢失，因此每次
/// 启动/重启服务前自动检查并重打，保证「创造模式」始终可用。
/// @returns true=本次应用了补丁；false=无需应用（已打过 / dsh 缺失 / 结构不匹配）。
func applyToolCordisPatchIfNeeded() -> Bool {
    let marker = "PATCH: inspect provider 注册表是进程全局单例"
    let oldLine = "\tfor (const provider of hostInspectProviders(ctx)) ctx.effect(() => ctx.cordisInspect.register(provider), `tool-cordis: inspect ${provider.manifest.id}`);"
    let newBlock = """
    \t// PATCH: inspect provider 注册表是进程全局单例（dsh-cordis-host-runner），
    \t// 同 id 已被其他预设（如 cordis / ptc-cordis）注册时直接抛
    \t// "already registered"，导致第二个带 tool-cordis 的预设挂载失败。
    \t// provider 是同一包的静态目录描述，重复注册无意义也无害；
    \t// 工具与提示仍按 scope 分层各自注册，不受影响。这里幂等跳过。
    \tconst existingHostInspect = new Set(ctx.cordisInspect.list().filter(p => p.platform === "host").map(p => p.id));
    \tfor (const provider of hostInspectProviders(ctx)) {
    \t\tif (existingHostInspect.has(provider.manifest.id)) continue;
    \t\tctx.effect(() => ctx.cordisInspect.register(provider), `tool-cordis: inspect ${provider.manifest.id}`);
    \t}
    """
    guard let target = dshToolCordisIndexPath() else { return false }
    guard let content = try? String(contentsOfFile: target, encoding: .utf8) else { return false }
    if content.contains(marker) { return false } // 已打过补丁，幂等跳过
    guard content.contains(oldLine) else {
        appendToServiceLog("tool-cordis 补丁：未匹配到注册行（dsh 版本结构可能已变化），跳过，创造模式多预设可能不可用")
        return false
    }
    let backup = target + ".bak"
    try? fs.removeItem(atPath: backup)
    try? fs.copyItem(atPath: target, toPath: backup)
    let patched = content.replacingOccurrences(of: oldLine, with: newBlock)
    do {
        try patched.write(toFile: target, atomically: true, encoding: .utf8)
        return true
    } catch {
        appendToServiceLog("tool-cordis 补丁写入失败：\(error.localizedDescription)")
        return false
    }
}

/// 以指定 profile 启动服务：重写 LaunchAgent plist（无 KeepAlive，崩溃不自愈）
/// 并 bootstrap + kickstart。RunAtLoad 恒为 false（服务全手动控制），
/// bootstrap 只注册不启动，需 kickstart 手动拉起。
func startService(profile: String) -> Bool {
    // 适配创造模式：每次启动/重启服务前检查并应用 dsh-tool-cordis 幂等补丁
    // （dsh 升级覆盖 node_modules 后自动重打，保证 cordis / ptc-cordis 多预设共存）
    if applyToolCordisPatchIfNeeded() {
        appendToServiceLog("已应用 dsh-tool-cordis 幂等补丁（适配创造模式多预设共存）")
    }
    guard let program = buildProgram(profile: profile) else { return false }
    try? fs.createDirectory(at: logDir, withIntermediateDirectories: true)
    // 轮转服务日志（launchd 的 StandardOutPath 无限增长，防止磁盘被日志占满）
    rotateLogIfNeeded(logFile)
    let env = serviceEnvironment(nodePath: resolveNodePath())
    guard writePlist(servicePlistURL, servicePlistXML(program: program, workspace: workspacePath(), env: env)) else { return false }
    if serviceLoaded() {
        // bootout 是异步卸载：必须等旧任务彻底消失再 bootstrap，
        // 否则 bootstrap 会因时序冲突失败（Bootstrap failed: 5: Input/output error）。
        launchctl(["bootout", "\(guiDomain)/\(serviceLabel)"])
        for _ in 0..<10 where serviceLoaded() { usleep(100_000) } // 最多等 1 秒
    }
    if !serviceLoaded() {
        let (code, _) = launchctl(["bootstrap", guiDomain, servicePlistURL.path])
        if code != 0 { return false }
    }
    if !serviceRunning() {
        let (code, _) = launchctl(["kickstart", "\(guiDomain)/\(serviceLabel)"])
        if code != 0 { return false }
    }
    return true
}

func stopService() {
    launchctl(["bootout", "\(guiDomain)/\(serviceLabel)"])
}

func appPlistXML() -> String {
    let exe = Bundle.main.executablePath ?? ""
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(appLabel)</string>
      <key>ProgramArguments</key>
      <array>
        <string>\(escapeXml(exe))</string>
      </array>
      <key>RunAtLoad</key><true/>
    </dict>
    </plist>
    """
}

func appAutoStartEnabled() -> Bool {
    fs.fileExists(atPath: appPlistURL.path)
}

// MARK: - 安装进度面板

/// dsh 安装/更新进度面板：spinner + 实时日志（来自日志文件尾部），可最小化。
final class InstallPanel: NSPanel {
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "正在安装 dsh…")
    private let statusLabel = NSTextField(labelWithString: "首次安装需联网下载，请稍候…")
    private let logView = NSTextView()
    private let doneTitle: String
    private let doneStatus: String
    private let failTitle: String

    /// 进度面板，文案可定制（安装 / 更新共用）。
    init(panelTitle: String = "安装 dsh",
         statusTitle: String = "正在安装 dsh…",
         statusText: String = "首次安装需联网下载，请稍候…",
         doneTitle: String = "dsh 安装完成",
         doneStatus: String = "即将自动启动服务…",
         failTitle: String = "dsh 安装失败") {
        self.doneTitle = doneTitle
        self.doneStatus = doneStatus
        self.failTitle = failTitle
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                   styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
        self.title = panelTitle
        isFloatingPanel = true
        // 关键：isFloatingPanel 默认会让面板在 App 失活时自动隐藏（切到其他 App 就消失）。
        // 这里显式关闭该行为，让进度面板始终停留，直到用户手动关闭或流程完成。
        hidesOnDeactivate = false
        isReleasedWhenClosed = false // 关闭后不自动释放（生命周期由 App 手动管理）
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary] // 跨空间/全屏时仍可见
        level = .floating

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        spinner.frame = NSRect(x: 20, y: 278, width: 24, height: 24)

        titleLabel.stringValue = statusTitle
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.frame = NSRect(x: 56, y: 281, width: 360, height: 18)

        statusLabel.stringValue = statusText
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 56, y: 261, width: 400, height: 16)

        logView.isEditable = false
        logView.isRichText = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 50, width: 440, height: 196))
        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        logView.frame = NSRect(x: 0, y: 0, width: 424, height: 196)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        content.addSubview(spinner)
        content.addSubview(titleLabel)
        content.addSubview(statusLabel)
        content.addSubview(scroll)
        contentView = content
    }

    /// 刷新日志（调用方传日志尾部）。
    func updateLog(_ text: String) {
        guard !logView.string.isEmpty || !text.isEmpty else { return }
        logView.string = text
        logView.scrollToEndOfDocument(nil)
    }

    /// 成功：停 spinner，1 秒后由外部关闭面板。
    func setSuccess() {
        spinner.stopAnimation(nil)
        titleLabel.stringValue = doneTitle
        statusLabel.stringValue = doneStatus
    }

    /// 失败：展示错误信息，面板保留供查看日志，可关闭后重试。
    func setFailure(_ reason: String) {
        spinner.stopAnimation(nil)
        titleLabel.stringValue = failTitle
        statusLabel.stringValue = reason
    }
}

// MARK: - dsh profile（~/.dsh/profiles）

/// 一个 dsh profile：~/.dsh/profiles/<name> 目录，package.json 的
/// `dsh.profile.bundles` 声明它叠加的插件组合包（顺序即叠加顺序）。
struct DshProfile: Identifiable, Hashable {
    let name: String
    let dir: String
    let bundles: [String]
    var id: String { name }
}

/// 扫描 ~/.dsh/profiles 下含 package.json 的子目录（跳过 dotfiles 与
/// 共享 node_modules）。目录不存在或为空时兜底返回「web」——dsh 首次以
/// `--profile web` 启动时会自动从随包模板初始化该 profile。
func scanDshProfiles() -> [DshProfile] {
    let root = homeDir.appendingPathComponent(".dsh/profiles", isDirectory: true)
    var out: [DshProfile] = []
    if let entries = try? fs.contentsOfDirectory(atPath: root.path) {
        for e in entries.sorted() {
            guard !e.hasPrefix("."), e != "node_modules" else { continue }
            let dir = root.appendingPathComponent(e, isDirectory: true)
            var isDir: ObjCBool = false
            guard fs.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  fs.fileExists(atPath: dir.appendingPathComponent("package.json").path) else { continue }
            var bundles: [String] = []
            if let data = fs.contents(atPath: dir.appendingPathComponent("package.json").path),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dsh = obj["dsh"] as? [String: Any],
               let profile = dsh["profile"] as? [String: Any],
               let list = profile["bundles"] as? [String] {
                bundles = list
            }
            out.append(DshProfile(name: e, dir: dir.path, bundles: bundles))
        }
    }
    if out.isEmpty {
        out = [DshProfile(name: "web", dir: root.appendingPathComponent("web").path,
                          bundles: ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"])]
    }
    return out
}

// MARK: - App 状态模型（菜单栏图标与主窗口共享）

/// 全部 UI 状态与操作入口。菜单栏 AppDelegate 与 SwiftUI 主窗口都观察它。
/// 服务生命周期契约（v2.0）：全手动——App 启动不自动拉起服务、退出不停服务、
/// 崩溃不自愈（plist 无 KeepAlive），一切启停由用户在主窗口操作。
final class AppModel: NSObject, ObservableObject {
    static let shared = AppModel()

    // 服务与 dsh 状态（5 秒定时刷新 + 操作后即时刷新）
    @Published var state: ServiceState = .stopped
    @Published var envNote = ""
    @Published var localVersion: String?
    @Published var autoAppOn = false

    // profile
    @Published var profiles: [DshProfile] = []
    @Published var selectedProfile: String
    /// 最近一次由本 App 成功启动的 profile（持久化；服务独立于 App 存活，
    /// App 重开后据此展示"当前运行的是哪个 profile"，尽力追踪）
    @Published var runningProfile: String? = nil

    // dsh 更新（npm 频道：唯一可一键升级的渠道）
    @Published var latestRemoteVersion: String?
    @Published var updateAvailable = false
    @Published var updateIsPreview = false
    @Published var checkingUpdates = false
    @Published var updatingInProgress = false
    /// npm registry 上实际最新版本（不区分是否比本地新，供信息区展示）
    @Published var npmLatestVersion: String?
    @Published var npmIsPrerelease = false
    @Published var npmTag: String?
    /// 用户主动忽略的升级版本（等上游修复期间避免误点升级）；
    /// 忽略后该版本不再亮「更新」按钮，npm 信息区照常展示。
    @Published var ignoredUpgradeVersion: String? {
        didSet {
            if let v = ignoredUpgradeVersion { defaults.set(v, forKey: "ignoredUpgradeVersion") }
            else { defaults.removeObject(forKey: "ignoredUpgradeVersion") }
        }
    }

    /// 最近一次启动/重启失败的详细原因（主窗口展示，不弹模态窗）
    @Published var lastStartError: String?

    // dsh 更新（GitHub Release 频道：仅信息展示 + 跳转，npm 未发布的版本装不了）
    @Published var githubLatestVersion: String?
    @Published var githubReleaseURL: String?
    @Published var githubIsPrerelease = false
    @Published var checkingGithub = false

    // 长流程互斥与进行中标志（驱动按钮禁用/改名）：安装/卸载/更新/重启/停止互斥
    @Published var busy = false
    @Published var installInProgress = false
    @Published var uninstallInProgress = false

    // 服务日志尾部（主窗口日志区，1 秒流式刷新）
    @Published var logText = ""

    private var refreshTimer: Timer?
    private var updateTimer: Timer?
    private var installLogTimer: Timer?
    private var updateLogTimer: Timer?
    private var uninstallLogTimer: Timer?
    private var logStreamTimer: Timer?

    private(set) var installPanel: InstallPanel?
    private(set) var updatePanel: InstallPanel?
    private(set) var uninstallPanel: InstallPanel?

    override private init() {
        let saved = defaults.string(forKey: "selectedProfile")
        selectedProfile = saved ?? "web"
        super.init()
        ignoredUpgradeVersion = defaults.string(forKey: "ignoredUpgradeVersion")
        runningProfile = defaults.string(forKey: "runningProfile")
    }

    /// 定时器：5 秒状态刷新 + 6 小时静默检查更新
    func startTimers() {
        let t = Timer(timeInterval: 5, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
        let u = Timer(timeInterval: 6 * 3600, target: self, selector: #selector(autoCheckUpdates), userInfo: nil, repeats: true)
        RunLoop.main.add(u, forMode: .common)
        updateTimer = u
    }

    @objc func refresh() {
        state = serviceState()
        envNote = lastEnvCaptureFailed ? "⚠ shell 环境抓取失败，服务内工具链（node/npm 等）可能不可用" : ""
        localVersion = localDshVersion()
        profiles = scanDshProfiles()
        if !profiles.contains(where: { $0.name == selectedProfile }) {
            selectProfile(profiles[0].name)
        }
        autoAppOn = appAutoStartEnabled()
    }

    func selectProfile(_ name: String) {
        selectedProfile = name
        defaults.set(name, forKey: "selectedProfile")
    }

    // MARK: 打开入口

    func openWeb() { NSWorkspace.shared.open(webURL) }
    func openDataDir() { NSWorkspace.shared.open(homeDir.appendingPathComponent(".dsh")) }
    func openLogDir() {
        try? fs.createDirectory(at: logDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logDir)
    }
    func openProfileDir(_ profile: DshProfile) {
        NSWorkspace.shared.open(URL(fileURLWithPath: profile.dir))
    }

    // MARK: 启动 / 重启 / 停止

    /// 「启动」：确保服务以当前选中 profile 运行。
    /// 端口被外部 dsh 占用 → 结束并接管；被其他程序占用 → 确认后结束；
    /// 服务运行中且切换了 profile → 确认后重启。
    func startRequested() { launchFlow(confirmSwitch: true) }

    /// 「重启」：以当前选中 profile 停旧拉新，不弹确认。
    func restartRequested() { launchFlow(confirmSwitch: false) }

    private func launchFlow(confirmSwitch: Bool) {
        guard dshInstalled() else {
            showAlert(title: "dsh 未安装",
                      message: "请先完成「安装 dsh」，再启动服务。")
            refresh()
            return
        }
        if !serviceRunning() && portServing() {
            if port3080IsDsh() {
                // 外部/孤儿 dsh 实例：直接结束并接管（无需用户手动 Ctrl+C）
                if killPort3080() {
                    performRestart()
                } else {
                    showAlert(title: "无法结束占用进程",
                              message: "占用者：\(port3080Occupier())\n\n无法自动结束该进程，请手动处理后再试。")
                    refresh()
                }
            } else {
                // 非 dsh 程序占用：确认后再结束，避免误杀其他工作
                let alert = NSAlert()
                alert.messageText = "端口 3080 被其他程序占用"
                alert.informativeText = "占用者：\(port3080Occupier())\n\n是否结束该进程并启动 dsh 服务？"
                alert.addButton(withTitle: "结束并启动")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn {
                    if killPort3080() {
                        performRestart()
                    } else {
                        showAlert(title: "无法结束占用进程",
                                  message: "占用者：\(port3080Occupier())\n\n无法自动结束该进程，请手动处理后再试。")
                    }
                }
                refresh()
            }
            return
        }
        if confirmSwitch, serviceRunning(), let running = runningProfile, running != selectedProfile {
            let alert = NSAlert()
            alert.messageText = "切换 profile 并重启服务？"
            alert.informativeText = "服务正在以「\(running)」运行，将切换为「\(selectedProfile)」并重启。"
            alert.addButton(withTitle: "切换并重启")
            alert.addButton(withTitle: "取消")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        performRestart()
    }

    /// 实际执行重启：停旧实例 + 兜底杀端口（幂等），再以选中 profile 拉起并轮询健康检查。
    /// 整个流程在后台队列执行：startService 里的 `zsh -lic` 抓环境最多可等 8 秒，
    /// 健康检查每秒 curl 一次，绝不能阻塞主线程（菜单栏 App 会假死）。
    private func performRestart() {
        guard !busy else { return } // 安装/更新/卸载/重启互斥
        busy = true
        isStarting = true
        refresh()
        let profile = selectedProfile
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            stopService()   // 幂等：停 launchd 任务
            killPort3080()  // 兜底：无论谁占 3080，启动前都释放端口
            var attempts = 0
            while true {
                attempts += 1
                if startService(profile: profile) { break }
                if attempts >= 6 {
                    DispatchQueue.main.async {
                        self.finishStartup(ok: false, message: "无法写入 LaunchAgent 或启动服务（已重试 6 次）。\n\n日志尾部：\n\(logTail())")
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            self.healthCheck(timeout: 8) { ok in
                DispatchQueue.main.async {
                    if ok {
                        self.runningProfile = profile
                        defaults.set(profile, forKey: "runningProfile")
                    }
                    self.finishStartup(ok: ok, message: ok ? nil : "服务未能启动。\n\n日志尾部：\n\(logTail())")
                }
            }
        }
    }

    /// 结束"正在启动"状态：失败时不弹模态窗（accessory 应用里模态窗常无法获得焦点），
    /// 只在主窗口展示失败摘要，详情看服务日志区。
    private func finishStartup(ok: Bool, message: String?) {
        isStarting = false
        busy = false
        lastStartError = ok ? nil : message
        refresh()
    }

    /// 后台轮询健康检查：每秒探测一次 HTTP 3080，直到可用或超时。
    private func healthCheck(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(timeout)
            while !portServing() && Date() < deadline {
                Thread.sleep(forTimeInterval: 1)
            }
            let ok = portServing()
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// 「关闭」：bootout 停掉 launchd 任务，再兜底结束端口上的 dsh 进程
    /// （只杀 dsh，绝不碰其他程序）。崩溃不自愈：关闭后保持停止，直到手动启动。
    func stopRequested() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            stopService()
            for _ in 0..<10 where serviceLoaded() { usleep(100_000) }
            killDshOnPort3080()
            DispatchQueue.main.async {
                self?.runningProfile = nil
                defaults.removeObject(forKey: "runningProfile")
                self?.busy = false
                self?.refresh()
            }
        }
    }

    // MARK: 安装 dsh（首次使用）

    /// 「安装 dsh」：弹进度面板，后台执行 `npm install -g` 全局安装。
    /// v2.0 服务全手动：完成后不自动启动，由用户点「启动」。
    func installRequested() {
        // 安装面板被最小化时先恢复显示（菜单栏 App 无 Dock 图标，靠按钮找回）
        if let panel = installPanel, panel.isMiniaturized {
            panel.deminiaturize(nil)
            panel.orderFrontRegardless()
            panel.makeKey()
            return
        }
        guard !installInProgress, !busy else { return }
        let node = resolveNodePath()
        guard let npm = resolveNpmPath(nodePath: node) else {
            showAlert(title: "无法安装 dsh",
                      message: "未找到 npm（Node.js 可能未安装）。\n\n请先安装 Node.js（fnm / nvm / Homebrew 均可），再点击「安装 dsh」。")
            return
        }
        installInProgress = true
        busy = true
        isInstallingDsh = true
        refresh()

        // 清空旧安装日志，避免面板显示上一次的内容
        try? "".write(to: installLogFile, atomically: true, encoding: .utf8)

        let panel = InstallPanel(panelTitle: "安装 dsh",
                                 statusTitle: "正在安装 dsh…",
                                 statusText: "首次安装需联网下载，请稍候…",
                                 doneTitle: "dsh 安装完成",
                                 doneStatus: "可在主窗口点击「启动」运行服务",
                                 failTitle: "dsh 安装失败")
        installPanel = panel
        panel.center()
        // orderFrontRegardless 强制置顶显示（不依赖激活状态）；
        // 不调用 NSApp.activate，避免 accessory 应用激活/失活导致窗口行为异常
        panel.orderFrontRegardless()
        panel.makeKey()

        let t = Timer(timeInterval: 1, target: self, selector: #selector(refreshInstallLog), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        installLogTimer = t

        // 后台执行全局安装（timeout 180s 防卡死）。
        // 使用完整终端环境（以 App 当前环境为底，叠加 zsh 抓取的完整环境），
        // 保证依赖 native 编译（make/clang/python）的包能正常安装。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 先清理 @deepseek-ai 目录下的 npm 残留（如 .dsh-xxxxxx 临时目录），
            // 避免残留文件数超过 npm 安全删除阈值导致 install 被拒绝
            cleanDshStagingResidue()
            var env = ProcessInfo.processInfo.environment
            for (k, v) in serviceEnvironment(nodePath: node) {
                env[k] = v
            }
            let code = runProcessLogging(node, [npm, "install", "-g", "@deepseek-ai/dsh"],
                                         timeout: 180, env: env, logURL: installLogFile)
            DispatchQueue.main.async { self?.installFinished(code: code) }
        }
    }

    @objc private func refreshInstallLog() {
        installPanel?.updateLog(installLogTail(30))
    }

    private func installFinished(code: Int32) {
        installLogTimer?.invalidate()
        installLogTimer = nil
        installInProgress = false
        busy = false
        isInstallingDsh = false
        invalidateDshInfo() // 安装完成，dsh 版本/状态已变化，清除缓存
        refresh()

        if code == 0 && dshInstalled() {
            installPanel?.setSuccess()
            // 稍作停留展示"安装完成"，然后自动关闭面板（不自动启动服务）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.installPanel?.close()
                self?.installPanel = nil
            }
        } else {
            let tailText = installLogTail(20)
            installPanel?.setFailure("安装失败（退出码 \(code)），请检查网络后重试。\n\n\(tailText)")
        }
    }

    // MARK: 卸载 dsh

    /// 「卸载 dsh」（仅已安装时可用）：确认后先停止服务，再后台执行
    /// `npm uninstall -g` 全局卸载，并清理 npx 缓存中的 dsh（否则 App 会因
    /// 缓存命中误判为仍已安装）。两种模式由确认框选择：
    /// · 仅卸载 —— 保留数据目录 ~/.dsh，重装后无缝恢复；
    /// · 完全卸载 —— 连 ~/.dsh 与服务 LaunchAgent 配置一并删除（不可恢复）。
    func uninstallRequested() {
        if let panel = uninstallPanel, panel.isMiniaturized {
            panel.deminiaturize(nil)
            panel.orderFrontRegardless()
            panel.makeKey()
            return
        }
        guard !uninstallInProgress, !busy else { return }
        let node = resolveNodePath()
        guard let npm = resolveNpmPath(nodePath: node) else {
            showAlert(title: "无法卸载 dsh",
                      message: "未找到 npm（Node.js 可能未安装），无法执行 npm uninstall。\n\n如需手动卸载：npm uninstall -g @deepseek-ai/dsh")
            return
        }
        let ver = localDshVersion().map { "v\($0)" } ?? "未知版本"
        let alert = NSAlert()
        alert.messageText = "卸载 dsh？"
        alert.informativeText = "将停止正在运行的 dsh web 服务，执行 npm uninstall -g @deepseek-ai/dsh（\(ver)），并清理 npx 缓存。\n\n"
            + "· 仅卸载：保留数据目录 ~/.dsh（会话历史、配置），重装后无缝恢复\n"
            + "· 完全卸载：连同 ~/.dsh 数据与服务 LaunchAgent 配置一并删除，不可恢复"
        alert.addButton(withTitle: "仅卸载，保留 ~/.dsh")
        alert.addButton(withTitle: "完全卸载，删除 ~/.dsh")
        alert.buttons[1].hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        let choice = alert.runModal()
        guard choice != .alertThirdButtonReturn else { return }
        let fullWipe = (choice == .alertSecondButtonReturn)

        uninstallInProgress = true
        busy = true
        refresh()

        try? "".write(to: uninstallLogFile, atomically: true, encoding: .utf8)

        let panel = InstallPanel(panelTitle: fullWipe ? "完全卸载 dsh" : "卸载 dsh",
                                 statusTitle: fullWipe ? "正在完全卸载 dsh…" : "正在卸载 dsh…",
                                 statusText: "正在停止服务、卸载包并清理文件…",
                                 doneTitle: fullWipe ? "dsh 已完全卸载" : "dsh 已卸载",
                                 doneStatus: fullWipe
                                     ? "服务与数据目录 ~/.dsh 已删除。"
                                     : "服务已停止，数据目录 ~/.dsh 已保留。",
                                 failTitle: "dsh 卸载失败")
        uninstallPanel = panel
        panel.center()
        panel.orderFrontRegardless()
        panel.makeKey()

        let t = Timer(timeInterval: 1, target: self, selector: #selector(refreshUninstallLog), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        uninstallLogTimer = t

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 1. 先停服务：launchd 任务 + 兜底结束端口上残留的 dsh 实例
            stopService()
            for _ in 0..<10 where serviceLoaded() { usleep(100_000) }
            killDshOnPort3080()
            // 2. 全局卸载（timeout 120s 防卡死）；使用完整终端环境
            var env = ProcessInfo.processInfo.environment
            for (k, v) in serviceEnvironment(nodePath: node) {
                env[k] = v
            }
            let code = runProcessLogging(node, [npm, "uninstall", "-g", "@deepseek-ai/dsh"],
                                         timeout: 120, env: env, logURL: uninstallLogFile)
            // 3. 收尾清理：npm 残留临时目录 + npx 缓存里的 dsh + 作用域空壳残留
            //    （保证回到「未安装」状态且不留文件）
            cleanDshStagingResidue()
            removeNpxCachedDsh()
            cleanDshScopeResidue(node: node)
            // 4. 完全卸载：删除数据目录 ~/.dsh 与服务 LaunchAgent 配置
            if fullWipe {
                let dataDir = homeDir.appendingPathComponent(".dsh")
                do {
                    try fs.removeItem(at: dataDir)
                    appendToUninstallLog("完全卸载：已删除数据目录 \(dataDir.path)")
                } catch {
                    if fs.fileExists(atPath: dataDir.path) {
                        appendToUninstallLog("删除 \(dataDir.path) 失败：\(error.localizedDescription)")
                    }
                }
                try? fs.removeItem(at: servicePlistURL)
            }
            DispatchQueue.main.async { self?.uninstallFinished(code: code) }
        }
    }

    @objc private func refreshUninstallLog() {
        uninstallPanel?.updateLog(uninstallLogTail(30))
    }

    private func uninstallFinished(code: Int32) {
        uninstallLogTimer?.invalidate()
        uninstallLogTimer = nil
        uninstallInProgress = false
        busy = false
        invalidateDshInfo()   // 卸载完成，安装状态已变化，清除缓存
        latestRemoteVersion = nil
        updateAvailable = false
        updateIsPreview = false
        runningProfile = nil
        defaults.removeObject(forKey: "runningProfile")
        refresh()

        // 成功判定：退出码 0 且本地已检测不到 dsh（全局包与 npx 缓存都已清理）
        if code == 0 && !dshInstalled() {
            uninstallPanel?.setSuccess()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.uninstallPanel?.close()
                self?.uninstallPanel = nil
            }
        } else {
            let tailText = uninstallLogTail(20)
            let detail = dshInstalled() ? "\n本地仍检测到 dsh（全局包或 npx 缓存未清干净）。" : ""
            uninstallPanel?.setFailure("卸载失败（退出码 \(code)）\(detail)\n\n\(tailText)")
        }
    }

    // MARK: dsh 更新（自动检测 + 一键升级）

    /// 忽略当前可更新版本（等上游修复期间避免误升级）；忽略后不再亮「更新」按钮。
    func ignoreLatestUpgrade() {
        guard let v = latestRemoteVersion else { return }
        ignoredUpgradeVersion = v
        updateAvailable = false
        latestRemoteVersion = nil
        updateIsPreview = false
        refresh()
    }

    /// 取消忽略：恢复对该版本升级的提示。
    func unignoreUpgrade() {
        ignoredUpgradeVersion = nil
        refresh()
        checkForUpdates(notifyIfUpToDate: false) // 重新按当前状态亮按钮
    }

    /// 「检查更新 / 更新 → vX」按钮：面板被最小化时先恢复显示；
    /// 已有可用更新则直接执行升级，否则手动检查一次。
    func updateRequested() {
        if let panel = updatePanel, panel.isMiniaturized {
            panel.deminiaturize(nil)
            panel.orderFrontRegardless()
            panel.makeKey()
            return
        }
        guard !checkingUpdates, !checkingGithub else { return } // 检查进行中忽略连点
        if updateAvailable {
            performUpdate()
        } else {
            checkForUpdates(notifyIfUpToDate: true)
        }
    }

    /// 每 6 小时定时自动检查（静默，不打扰；结果只在主窗口提示）。
    @objc func autoCheckUpdates() {
        checkForUpdates(notifyIfUpToDate: false)
    }

    /// 双通道检查 dsh 更新：
    /// · npm registry（遍历所有 dist-tag 与 versions 列表）—— 唯一可一键升级的渠道；
    /// · GitHub Releases —— 仅信息展示（npm 未发布的版本如 alpha 预发布在这里提示）。
    /// 两条通道并行请求，各自回填 UI；手动检查（notifyIfUpToDate）时在 npm 结果
    /// 落定后反馈一次（若 GitHub 频道有 npm 没有的版本，附在提示里）。
    func checkForUpdates(notifyIfUpToDate: Bool) {
        guard !updatingInProgress else { return }
        guard !checkingUpdates, !checkingGithub else { return }
        let local = localDshVersion()
        checkingUpdates = true
        checkingGithub = true
        refresh()

        var pending = 2 // 等待 npm 和 GitHub 两条通道都回落
        func channelDone() {
            pending -= 1
            if pending == 0 { reportCheckResult(notify: notifyIfUpToDate, local: local) }
        }

        fetchLatestDshVersion { [weak self] remote, isPreview, tag in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checkingUpdates = false
                self.npmLatestVersion = remote
                self.npmIsPrerelease = isPreview
                self.npmTag = tag
                // 用户忽略过的版本：信息区照常展示，但不再亮「更新」按钮
                if let ignored = self.ignoredUpgradeVersion, let remote = remote, ignored == remote {
                    self.latestRemoteVersion = nil
                    self.updateIsPreview = false
                    self.updateAvailable = false
                } else if let local = local, let remote = remote, isNewerVersion(remote, than: local) {
                    self.latestRemoteVersion = remote
                    self.updateIsPreview = isPreview
                    self.updateAvailable = true
                } else {
                    self.latestRemoteVersion = nil
                    self.updateIsPreview = false
                    self.updateAvailable = false
                }
                self.refresh()
                channelDone()
            }
        }

        fetchLatestGithubRelease { [weak self] version, url, pre in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checkingGithub = false
                self.githubLatestVersion = version
                self.githubReleaseURL = url
                self.githubIsPrerelease = pre
                self.refresh()
                channelDone()
            }
        }
    }

    /// 手动检查的结果反馈（npm 频道为准；GitHub 频道仅附带提示）。
    private func reportCheckResult(notify: Bool, local: String?) {
        guard notify, let local = local else { return }
        if updateAvailable { return } // 窗口已出现「更新 → vX」按钮，不打扰
        guard let npmRemote = npmLatestVersion else {
            showAlert(title: "检查更新失败",
                      message: "无法连接 npm registry，请检查网络后重试。")
            return
        }
        var message = "当前已安装 dsh \(local)，npm 最新版本是 \(npmRemote)。"
        if let gh = githubLatestVersion, isNewerVersion(gh, than: local) {
            message += "\n\nGitHub Release 有更新的版本 v\(gh)（npm 未发布），可在信息区点「查看 Release」了解。"
        }
        showAlert(title: "已是最新版本", message: message)
    }

    /// 一键升级：安装检测到的目标版本（`npm install -g @deepseek-ai/dsh@<目标版本>`），
    /// 进度面板实时展示日志。更新前服务在跑 → 完成后自动重启加载新版；
    /// 更新前停着 → 保持停止（不自动启动）。
    /// 注意：必须安装确切的目标版本（可能是 next 通道的 rc 版），不能写死 @latest，
    /// 否则 latest 标签与检测目标不一致，会导致装完仍提示更新。
    func performUpdate() {
        guard !updatingInProgress, !busy else { return }
        guard let target = latestRemoteVersion, !target.isEmpty else {
            showAlert(title: "无法更新 dsh",
                      message: "未找到目标更新版本，请先点击「检查更新」。")
            return
        }
        let node = resolveNodePath()
        guard let npm = resolveNpmPath(nodePath: node) else {
            showAlert(title: "无法更新 dsh",
                      message: "未找到 npm（Node.js 可能未安装）。")
            return
        }
        let wasRunning = port3080IsDsh()
        updatingInProgress = true
        busy = true
        refresh()

        try? "".write(to: updateLogFile, atomically: true, encoding: .utf8)

        let panel = InstallPanel(panelTitle: "更新 dsh",
                                 statusTitle: "正在更新 dsh…",
                                 statusText: "正在下载并安装 \(target)…",
                                 doneTitle: "dsh 更新完成",
                                 doneStatus: wasRunning ? "即将自动重启服务加载新版…" : "服务未在运行，已保持停止。",
                                 failTitle: "dsh 更新失败")
        updatePanel = panel
        panel.center()
        panel.orderFrontRegardless()
        panel.makeKey()

        let t = Timer(timeInterval: 1, target: self, selector: #selector(refreshUpdateLog), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        updateLogTimer = t

        // 后台执行全局升级（timeout 180s 防卡死），使用完整终端环境
        let pkg = "@deepseek-ai/dsh@\(target)"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 先清理 @deepseek-ai 目录下的 npm 残留，防止 safe-delete 阈值拦截升级
            cleanDshStagingResidue()
            var env = ProcessInfo.processInfo.environment
            for (k, v) in serviceEnvironment(nodePath: node) {
                env[k] = v
            }
            let code = runProcessLogging(node, [npm, "install", "-g", pkg],
                                         timeout: 180, env: env, logURL: updateLogFile)
            DispatchQueue.main.async { self?.updateFinished(code: code, target: target, wasRunning: wasRunning) }
        }
    }

    @objc private func refreshUpdateLog() {
        updatePanel?.updateLog(updateLogTail(30))
    }

    private func updateFinished(code: Int32, target: String, wasRunning: Bool) {
        updateLogTimer?.invalidate()
        updateLogTimer = nil
        updatingInProgress = false
        invalidateDshInfo() // 升级完成，dsh 版本已变化，清除缓存
        refresh()

        // 成功判定：退出码 0 且本地版本确实达到目标版本（防止装到错误版本还报成功）
        let installed = localDshVersion()
        let reached = installed != nil && !isNewerVersion(target, than: installed!)
        if code == 0, reached {
            latestRemoteVersion = nil
            updateAvailable = false
            updateIsPreview = false
            updatePanel?.setSuccess()
            // 保持 busy = true 直到面板关闭并触发重启（若需要），防止 1 秒展示期内的并发操作
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self = self else { return }
                self.updatePanel?.close()
                self.updatePanel = nil
                self.busy = false
                if wasRunning {
                    self.restartRequested() // 更新前在跑 → 重启加载新版
                }
            }
        } else {
            busy = false
            let tailText = updateLogTail(20)
            let detail = installed.map { "（当前本地版本：\($0)）" } ?? "（未检测到本地版本）"
            updatePanel?.setFailure("更新失败（退出码 \(code)）\(detail)。\n\n\(tailText)")
        }
    }

    // MARK: 设置

    /// 登录时自动启动本 App（只影响 App 自己，不影响 dsh 服务）。
    func setAutoApp(_ on: Bool) {
        if on {
            // 只写 plist，不 bootstrap：RunAtLoad=true 时 bootstrap 会立刻再拉起一个实例，
            // 且 launchd 直启的进程无法被单实例守卫识别，导致菜单栏出现两个图标。
            // launchd 会在下次登录时自动加载该 plist。
            if writePlist(appPlistURL, appPlistXML()) {
                // 清理旧版本可能已 bootstrap 的 agent（未加载时无副作用）
                launchctl(["bootout", "\(guiDomain)/\(appLabel)"])
            }
        } else {
            launchctl(["bootout", "\(guiDomain)/\(appLabel)"])
            try? fs.removeItem(at: appPlistURL)
        }
        refresh()
    }

    // MARK: 服务日志流（主窗口日志区）

    func startLogStream() {
        guard logStreamTimer == nil else { return }
        updateLogText()
        let t = Timer(timeInterval: 1, target: self, selector: #selector(updateLogText), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        logStreamTimer = t
    }

    func stopLogStream() {
        logStreamTimer?.invalidate()
        logStreamTimer = nil
    }

    @objc private func updateLogText() {
        logText = tail(of: logFile, n: 40, placeholder: "(暂无服务日志 —— 服务启动后这里会实时显示输出)")
    }

    // MARK: 弹窗队列

    private var pendingAlerts: [(title: String, message: String)] = []
    private var alertShowing = false

    /// 非模态弹窗：异步展示，不阻塞调用栈；连续相同标题的弹窗合并去重，
    /// 关闭后自动刷新状态并继续处理队列中剩余的弹窗。
    func showAlert(title: String, message: String) {
        if let lastIdx = pendingAlerts.indices.last, pendingAlerts[lastIdx].title == title {
            pendingAlerts[lastIdx].message = message // 合并：保留最新内容
            return
        }
        pendingAlerts.append((title, message))
        drainAlerts()
    }

    private func drainAlerts() {
        guard !alertShowing, let next = pendingAlerts.first else { return }
        alertShowing = true
        pendingAlerts.removeFirst()
        let alert = NSAlert()
        alert.messageText = next.title
        alert.informativeText = next.message
        alert.addButton(withTitle: "好")
        // 延迟到下一个 runloop 展示，避免阻塞当前调用栈
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            alert.runModal()
            self?.alertShowing = false
            self?.refresh()
            self?.drainAlerts()
        }
    }
}

// MARK: - App 主体（菜单栏 + 主窗口宿主）

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?
    private var openWebItem: NSMenuItem!
    private let model = AppModel.shared
    private var cancellables = Set<AnyCancellable>()
    private var whaleIconCache: [ServiceState: NSImage] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例守卫：菜单栏 App 重复打开会出现多个图标，保留最早的那个。
        // 不能用 bundle id 查询（launchd 直启的进程可能无法关联 bundle），
        // 改为按"可执行文件路径相同"匹配所有运行中的应用。
        let myExe = Bundle.main.executableURL?.standardizedFileURL.path
        let myBundleId = Bundle.main.bundleIdentifier
        let dupes = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            (($0.bundleIdentifier != nil && $0.bundleIdentifier == myBundleId) ||
             $0.executableURL?.standardizedFileURL.path == myExe)
        }
        if !dupes.isEmpty {
            let earliest = dupes.min { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
            if let earliest, (earliest.launchDate ?? .distantPast) < (NSRunningApplication.current.launchDate ?? .distantPast) {
                NSApp.terminate(nil)
                return
            }
        }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        model.refresh()
        updateStatusIcon()
        model.startTimers()
        // 状态变化 → 菜单栏图标着色与「打开 Web」可用性
        model.$state.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateStatusIcon()
        }.store(in: &cancellables)
        // 静默检查 dsh 更新：启动 10 秒后查一次，之后每 6 小时（结果只在主窗口提示）
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.model.checkForUpdates(notifyIfUpToDate: false)
        }
        // 首次使用（dsh 未安装）自动打开主窗口引导安装
        if !dshInstalled() {
            showMainWindow()
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false // 手动控制 isEnabled（默认自动校验会忽略禁用）
        openWebItem = NSMenuItem(title: "打开 Web", action: #selector(openUI), keyEquivalent: "o")
        openWebItem.target = self
        menu.addItem(openWebItem)
        let winItem = NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        winItem.target = self
        menu.addItem(winItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 App", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    /// 按状态缓存着色的鲸鱼图标（避免每 5 秒重新渲染位图）。
    private func cachedWhaleIcon(_ state: ServiceState) -> NSImage? {
        if let img = whaleIconCache[state] { return img }
        let color: NSColor = {
            switch state {
            case .running: return .systemGreen
            case .starting, .installing, .notInstalled: return .systemGray
            case .portBusy: return .systemOrange
            case .crashed: return .systemRed
            case .stopped: return .systemGray
            }
        }()
        guard let img = whaleMenuImage(color: color) else { return nil }
        whaleIconCache[state] = img
        return img
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let state = model.state
        if let image = cachedWhaleIcon(state) {
            button.image = image
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            // 兜底：图标资源缺失时退回旧圆点
            let (char, color): (String, NSColor) = {
                switch state {
                case .running: return ("●", .systemGreen)
                case .starting, .installing, .notInstalled: return ("◌", .systemGray)
                case .portBusy: return ("◍", .systemOrange)
                case .crashed: return ("✕", .systemRed)
                case .stopped: return ("○", .systemGray)
                }
            }()
            button.attributedTitle = NSAttributedString(string: char, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: color
            ])
        }
        // 服务在跑才能打开 Web；未运行时置灰（主窗口可启动服务）
        openWebItem?.isEnabled = (state == .running)
    }

    @objc func openUI() {
        model.openWeb()
    }

    /// 显示主窗口（单例：关窗仅隐藏，可随时找回）
    @objc func showMainWindow() {
        if mainWindow == nil {
            mainWindow = MainWindowFactory.makeWindow()
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    // 注意：没有 applicationWillTerminate 停服逻辑 —— v2.0 起服务是独立的
    // LaunchAgent（全手动控制），退出 App 不影响服务运行。
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
