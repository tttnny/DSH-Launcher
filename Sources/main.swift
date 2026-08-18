import AppKit
import Foundation
import Darwin

// ============================================================
// DSH Launcher — DeepSeek Harness 菜单栏控制 App
// 通过 launchd LaunchAgent 管理 dsh web 服务（com.dsh.web），
// 以及本 App 的登录自启（com.dsh.menubar）。
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
let serviceLabel = "com.dsh.web"
let appLabel = "com.dsh.menubar"
let servicePlistURL = launchAgentsDir.appendingPathComponent("\(serviceLabel).plist")
let appPlistURL = launchAgentsDir.appendingPathComponent("\(appLabel).plist")
let guiDomain = "gui/\(getuid())"
let webURL = URL(string: "http://127.0.0.1:3080")!
let npmLatestURL = URL(string: "https://registry.npmjs.org/@deepseek-ai/dsh/latest")!
let defaults = UserDefaults.standard

/// 单实例守卫淘汰的重复实例：退出时不应触发“停止服务”
var isDuplicateExit = false

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
/// 通过命令行关键字识别：dsh 进程形如 `node .../lib/bin.js web --port 3080`
/// 或 `dsh web --port 3080`，命令行必含 "dsh" 或 "deepseek-ai"。
func port3080IsDsh() -> Bool {
    guard let (_, cmd) = port3080Process() else { return false }
    return cmd.localizedCaseInsensitiveContains("dsh") ||
           cmd.localizedCaseInsensitiveContains("deepseek-ai")
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

enum ServiceState: Hashable { case running, starting, installing, notInstalled, portBusy, crashed, stopped }

/// 服务正在启动（App 自动拉起 / 手动重启的窗口期），期间状态显示“正在启动”
var isStarting = false
/// 启动时本地无 dsh 缓存 → 正在通过 npx 首次联网安装 dsh（区别于普通启动）
var isInstallingDsh = false

/// 本地是否已安装 dsh（全局安装或 npx 缓存任一命中）。
/// 安装完成后此函数返回 true，UI 自动从“未安装”进入正常流程。
func dshInstalled() -> Bool {
    resolveDshLauncher(nodePath: resolveNodePath()) != nil
}

/// 读取 package.json 的 version 字段
func versionFromPackage(_ pkgPath: String) -> String? {
    guard let data = fs.contents(atPath: pkgPath),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let v = obj["version"] as? String, !v.isEmpty else { return nil }
    return v
}

/// 本地已安装的 dsh 版本号（全局 npm 安装或 npx 缓存任一命中）。
/// 全局安装：<node 安装前缀>/lib/node_modules/@deepseek-ai/dsh/package.json
/// （fnm: ~/.local/share/fnm/node-versions/<v>/installation/lib/node_modules/...
///  nvm: ~/.nvm/versions/node/<v>/lib/node_modules/...）
/// npx 缓存：~/.npm/_npx/<hash>/node_modules/@deepseek-ai/dsh/package.json（取最新 mtime）。
func localDshVersion() -> String? {
    let node = resolveNodePath()
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

/// 简易 semver 比较：忽略 prerelease/build 后缀，逐段比较主/次/修订号。
func isNewerVersion(_ a: String, than b: String) -> Bool {
    func core(_ v: String) -> [Int] {
        let head = v.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        return head.split(separator: ".").compactMap { Int($0) }
    }
    let x = core(a), y = core(b)
    for i in 0..<max(x.count, y.count) {
        let xi = i < x.count ? x[i] : 0
        let yi = i < y.count ? y[i] : 0
        if xi != yi { return xi > yi }
    }
    return false
}

/// 查询 npm registry 上 @deepseek-ai/dsh 的 latest 版本号；失败（网络/解析）返回 nil。
func fetchLatestDshVersion(completion: @escaping (String?) -> Void) {
    var req = URLRequest(url: npmLatestURL)
    req.timeoutInterval = 10
    URLSession.shared.dataTask(with: req) { data, _, error in
        guard error == nil, let data = data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["version"] as? String, !v.isEmpty else {
            completion(nil)
            return
        }
        completion(v)
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

/// 生成服务的完整启动命令。
/// 优先直接跑缓存的 dsh bin.js；没有缓存时退回 `npx --yes @deepseek-ai/dsh`
/// （首次会联网下载，之后就有缓存了），保证朋友的机器开箱即用。
/// 注意：dsh 只允许绑定 127.0.0.1（官方禁止 `--host 0.0.0.0`），
/// 局域网访问请安装社区插件 moxisuki/dsh-lan，与本 App 无关。
func buildProgram() -> [String]? {
    let node = resolveNodePath()
    var base: [String]
    if let dsh = resolveDshLauncher(nodePath: node) {
        base = [node, dsh]
    } else if let npx = resolveNpxPath(nodePath: node) {
        base = [node, npx, "--yes", "@deepseek-ai/dsh"]
    } else {
        return nil
    }
    return base + ["web", "--port", "3080"]
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
      <key>KeepAlive</key><false/>
      <key>StandardOutPath</key><string>\(escapeXml(logFile.path))</string>
      <key>StandardErrorPath</key><string>\(escapeXml(logFile.path))</string>
    </dict>
    </plist>
    """
}

func startService() -> Bool {
    guard let program = buildProgram() else { return false }
    try? fs.createDirectory(at: logDir, withIntermediateDirectories: true)
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
        // RunAtLoad 恒为 false（不做登录自启），bootstrap 只注册不启动，需 kickstart 手动拉起
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

/// dsh 安装进度面板：spinner + 实时日志（来自服务日志文件尾部）+ 后台运行按钮。
final class InstallPanel: NSPanel {
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "正在安装 dsh…")
    private let statusLabel = NSTextField(labelWithString: "首次安装需联网下载，请稍候…")
    private let logView = NSTextView()
    private let bgButton = NSButton(title: "后台运行", target: nil, action: nil)
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
                   styleMask: [.titled, .closable],
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

        bgButton.frame = NSRect(x: 20, y: 12, width: 110, height: 28)
        bgButton.bezelStyle = .rounded
        bgButton.target = self
        bgButton.action = #selector(backgroundTapped)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        content.addSubview(spinner)
        content.addSubview(titleLabel)
        content.addSubview(statusLabel)
        content.addSubview(scroll)
        content.addSubview(bgButton)
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

    @objc private func backgroundTapped() {
        close() // 面板关闭，流程继续在后台执行，完成后自动处理
    }
}

// MARK: - App 主体

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var openItem: NSMenuItem!
    private var restartItem: NSMenuItem!
    private var installItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var versionItem: NSMenuItem!
    private var autoAppItem: NSMenuItem!

    /// dsh 更新检测/升级流程状态
    private var latestRemoteVersion: String?      // npm 最新版本
    private var updateAvailable = false           // 是否存在可升级的新版本
    private var checkingUpdates = false           // 正在查询 npm registry
    private var updatingInProgress = false        // 正在执行 npm 升级
    private var updatePanel: InstallPanel?
    private var updateLogTimer: Timer?

    /// dsh 安装流程状态
    private var installInProgress = false
    private var installPanel: InstallPanel?
    private var installLogTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例守卫：菜单栏 App 重复打开会出现多个图标，保留最早的那个。
        // 不能用 bundle id 查询（launchd 直启的进程可能无法关联 bundle），
        // 改为按“可执行文件路径相同”匹配所有运行中的应用。
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
                isDuplicateExit = true // 被淘汰的实例退出时不要停止服务
                NSApp.terminate(nil)
                return
            }
        }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateDot(serviceState())
        buildMenu()
        // 生命周期绑定：App 在 → 服务在，启动即自动拉起服务；
        // 先启动（内部立即刷新为“正在启动”），避免闪一帧“未运行”
        autoStartService()
        refresh()
        let t = Timer(timeInterval: 5, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // 自动检查 dsh 更新：启动 10 秒后查一次，之后每 6 小时自动查一次（静默，不打扰）
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.checkForUpdates(notifyIfUpToDate: false)
        }
        let updateTimer = Timer(timeInterval: 6 * 3600, target: self,
                                selector: #selector(autoCheckUpdates), userInfo: nil, repeats: true)
        RunLoop.main.add(updateTimer, forMode: .common)
    }

    private var whaleIconCache: [ServiceState: NSImage] = [:]

    /// 按状态缓存着色的鲸鱼图标（避免每 5 秒重新渲染位图）。
    func cachedWhaleIcon(_ state: ServiceState) -> NSImage? {
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

    func updateDot(_ state: ServiceState) {
        guard let button = statusItem.button else { return }
        // dsh 鲸鱼图标按状态着色（缓存复用，不重复渲染）
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
    }

    func buildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "DSH Launcher", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // 当前 dsh 版本（只读信息行，紧跟在标题下方）
        versionItem = NSMenuItem(title: "dsh 版本：-", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(.separator())

        openItem = NSMenuItem(title: "打开 Web UI", action: #selector(openUI), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        installItem = NSMenuItem(title: "安装 dsh", action: #selector(installDsh), keyEquivalent: "")
        installItem.target = self
        menu.addItem(installItem)

        restartItem = NSMenuItem(title: "重启服务", action: #selector(doRestart), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        updateItem = NSMenuItem(title: "检查更新", action: #selector(checkUpdateTapped), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        autoAppItem = NSMenuItem(title: "登录时自动启动本 App", action: #selector(toggleAutoApp(_:)), keyEquivalent: "")
        autoAppItem.target = self
        menu.addItem(autoAppItem)

        menu.addItem(.separator())

        let dataItem = NSMenuItem(title: "打开数据目录 ~/.dsh", action: #selector(showDataDir), keyEquivalent: "")
        dataItem.target = self
        menu.addItem(dataItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出（同时停止服务）", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: 动作

    /// App 启动时自动拉起服务（生命周期绑定：App 在 → 服务在，App 退出 → 服务停止）。
    /// 端口被外部实例占用时不弹窗打扰（状态行显示橙色即可）；
    /// dsh 未安装时不自动下载，等待用户点击「安装 dsh」。
    func autoStartService() {
        if !dshInstalled() {
            refresh()
            return
        }
        if serviceRunning() || portServing() { return }
        isStarting = true
        refresh()
        launchService()
    }

    @objc func openUI() {
        NSWorkspace.shared.open(webURL)
    }

    /// 统一的启动/重启流程：先处理端口占用（dsh 实例直接结束接管、其他程序确认后结束），
    /// 再停掉旧实例（幂等）、拉起并做轮询健康检查。
    /// 运行中 → 停止后重新拉起；启动失败/未运行 → 直接启动。
    func launchService() {
        if !dshInstalled() {
            showAlert(title: "dsh 未安装",
                      message: "请先点击菜单栏「安装 dsh」完成安装，再启动服务。")
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
                              message: "占用者：\(port3080Occupier())\n\n无法自动结束该进程，请手动处理后再点“重启服务”。")
                    refresh()
                }
            } else {
                // 非 dsh 程序占用：确认后再结束，避免误杀其他工作
                let alert = NSAlert()
                alert.messageText = "端口 3080 被其他程序占用"
                alert.informativeText = "占用者：\(port3080Occupier())\n\n是否结束该进程并重启 dsh 服务？"
                alert.addButton(withTitle: "结束并重启")
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
        performRestart()
    }

    /// 实际执行重启：停旧实例 + 兜底杀端口（幂等），再拉起并轮询健康检查。
    func performRestart() {
        stopService()     // 幂等：停 launchd 任务（App 托管时）
        killPort3080()    // 兜底：无论谁占 3080，重启前都释放端口
        isStarting = true
        // 无本地 dsh 缓存说明是首次使用，需要 npx 联网下载 → 显示“dsh 安装中”
        isInstallingDsh = resolveDshLauncher(nodePath: resolveNodePath()) == nil
        refresh()
        var attempts = 0
        func tryStart() {
            attempts += 1
            guard startService() else {
                if attempts < 6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tryStart() }
                } else {
                    finishStartup(ok: false, message: "无法写入 LaunchAgent 或启动服务（已重试 6 次）。\n\n日志尾部：\n\(logTail())")
                }
                return
            }
            // 复用 isInstallingDsh：无本地 dsh 缓存 → 首次联网下载，放宽健康检查窗口
            let hasCache = !isInstallingDsh
            let window: TimeInterval = hasCache ? 8 : 120
            healthCheck(timeout: window) { [weak self] ok in
                self?.finishStartup(ok: ok, message: ok ? nil :
                    "服务未能启动\(hasCache ? "。" : "，首次使用需联网下载 dsh，请确认网络可用。")\n\n日志尾部：\n\(logTail())")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tryStart() }
    }

    /// 结束“正在启动/安装中”状态：失败时弹日志尾部，随后刷新 UI。
    func finishStartup(ok: Bool, message: String?) {
        isStarting = false
        isInstallingDsh = false
        if !ok, let message = message {
            showAlert(title: "服务启动失败", message: message)
        }
        refresh()
    }

    /// 轮询健康检查：每秒探测一次 HTTP 3080，直到可用或超时。
    func healthCheck(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if portServing() { completion(true); return }
            if Date() >= deadline { completion(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { poll() }
        }
        poll()
    }

    @objc func doRestart() {
        launchService()
    }

    // MARK: 安装 dsh（首次使用）

    /// 菜单「安装 dsh」：弹进度面板，后台执行 `npm install -g` 全局安装，
    /// 完成后自动拉起服务（无需重启 App）。与官方全局安装方式一致，
    /// 安装后 `which dsh` 可找到，App 的 resolveDshLauncher 也会优先复用全局版。
    @objc func installDsh() {
        guard !installInProgress else { return }
        let node = resolveNodePath()
        guard let npm = resolveNpmPath(nodePath: node) else {
            showAlert(title: "无法安装 dsh",
                      message: "未找到 npm（Node.js 可能未安装）。\n\n请先安装 Node.js（fnm / nvm / Homebrew 均可），再点击「安装 dsh」。")
            return
        }
        installInProgress = true
        isInstallingDsh = true
        refresh()

        // 清空旧安装日志，避免面板显示上一次的内容
        try? "".write(to: installLogFile, atomically: true, encoding: .utf8)

        let panel = InstallPanel()
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
        // 关键：使用完整终端环境（以 App 当前环境为底，叠加 zsh 抓取的完整环境），
        // 保证依赖 native 编译（make/clang/python）的包能和服务运行时一样正常安装。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var env = ProcessInfo.processInfo.environment
            for (k, v) in serviceEnvironment(nodePath: node) {
                env[k] = v
            }
            let code = runProcessLogging(node, [npm, "install", "-g", "@deepseek-ai/dsh"],
                                         timeout: 180, env: env, logURL: installLogFile)
            DispatchQueue.main.async { self?.installFinished(code: code) }
        }
    }

    @objc func refreshInstallLog() {
        installPanel?.updateLog(installLogTail(30))
    }

    private func installFinished(code: Int32) {
        installLogTimer?.invalidate()
        installLogTimer = nil
        installInProgress = false
        isInstallingDsh = false
        refresh()

        if code == 0 && dshInstalled() {
            installPanel?.setSuccess()
            // 稍作停留展示“安装完成”，然后自动关闭面板并拉起服务
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.installPanel?.close()
                self?.installPanel = nil
                self?.launchService()
            }
        } else {
            let tail = installLogTail(20)
            installPanel?.setFailure("安装失败（退出码 \(code)），请检查网络后重试。\n\n\(tail)")
        }
    }

    // MARK: dsh 更新（自动检测 + 一键升级）

    /// 菜单「更新 dsh / 检查更新」：已有可用更新则直接执行升级，否则手动检查一次。
    @objc func checkUpdateTapped() {
        if updateAvailable {
            performUpdate()
        } else {
            checkForUpdates(notifyIfUpToDate: true)
        }
    }

    /// 每 6 小时定时自动检查（静默，不打扰）。
    @objc func autoCheckUpdates() {
        checkForUpdates(notifyIfUpToDate: false)
    }

    /// 查询 npm registry 最新版并与本地版本对比；发现新版本时仅更新菜单（不弹窗打扰），
    /// 手动检查（notifyIfUpToDate）时反馈结果。
    func checkForUpdates(notifyIfUpToDate: Bool) {
        guard !updatingInProgress else { return }
        guard let local = localDshVersion() else {
            // 未安装 dsh 时无需检查更新（菜单项此时也隐藏）
            latestRemoteVersion = nil
            updateAvailable = false
            refresh()
            return
        }
        guard !checkingUpdates else { return }
        checkingUpdates = true
        refresh()
        fetchLatestDshVersion { [weak self] remote in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checkingUpdates = false
                if let remote = remote, isNewerVersion(remote, than: local) {
                    // 发现新版本：菜单按钮变「更新 dsh → vX」作为提示，不打扰用户
                    self.latestRemoteVersion = remote
                    self.updateAvailable = true
                } else {
                    self.latestRemoteVersion = nil
                    self.updateAvailable = false
                    if notifyIfUpToDate {
                        if let remote = remote {
                            self.showAlert(title: "已是最新版本",
                                           message: "当前已安装 dsh \(local)，npm 最新版本也是 \(remote)。")
                        } else {
                            self.showAlert(title: "检查更新失败",
                                           message: "无法连接 npm registry，请检查网络后重试。")
                        }
                    }
                }
                self.refresh()
            }
        }
    }

    /// 一键升级：`npm install -g @deepseek-ai/dsh@latest`（与「安装 dsh」相同的官方
    /// 全局安装方式），进度面板实时展示日志，完成后自动重启服务加载新版。
    func performUpdate() {
        guard !updatingInProgress else { return }
        let node = resolveNodePath()
        guard let npm = resolveNpmPath(nodePath: node) else {
            showAlert(title: "无法更新 dsh",
                      message: "未找到 npm（Node.js 可能未安装）。")
            return
        }
        updatingInProgress = true
        refresh()

        // 清空旧更新日志，避免面板显示上一次的内容
        try? "".write(to: updateLogFile, atomically: true, encoding: .utf8)

        let panel = InstallPanel(panelTitle: "更新 dsh",
                                 statusTitle: "正在更新 dsh…",
                                 statusText: "正在从 npm 下载并安装最新版本…",
                                 doneTitle: "dsh 更新完成",
                                 doneStatus: "即将自动重启服务…",
                                 failTitle: "dsh 更新失败")
        updatePanel = panel
        panel.center()
        panel.orderFrontRegardless()
        panel.makeKey()

        let t = Timer(timeInterval: 1, target: self, selector: #selector(refreshUpdateLog), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        updateLogTimer = t

        // 后台执行全局升级（timeout 180s 防卡死），使用完整终端环境
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var env = ProcessInfo.processInfo.environment
            for (k, v) in serviceEnvironment(nodePath: node) {
                env[k] = v
            }
            let code = runProcessLogging(node, [npm, "install", "-g", "@deepseek-ai/dsh@latest"],
                                         timeout: 180, env: env, logURL: updateLogFile)
            DispatchQueue.main.async { self?.updateFinished(code: code) }
        }
    }

    @objc func refreshUpdateLog() {
        updatePanel?.updateLog(updateLogTail(30))
    }

    private func updateFinished(code: Int32) {
        updateLogTimer?.invalidate()
        updateLogTimer = nil
        updatingInProgress = false
        refresh()

        if code == 0, localDshVersion() != nil {
            latestRemoteVersion = nil
            updateAvailable = false
            updatePanel?.setSuccess()
            // 稍作停留展示“更新完成”，然后自动关闭面板并重启服务加载新版
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.updatePanel?.close()
                self?.updatePanel = nil
                self?.launchService()
            }
        } else {
            let tail = updateLogTail(20)
            updatePanel?.setFailure("更新失败（退出码 \(code)），请检查网络后重试。\n\n\(tail)")
        }
    }

    @objc func toggleAutoApp(_ item: NSMenuItem) {
        let on = item.state == .off
        if on {
            // 只写 plist，不 bootstrap：RunAtLoad=true 时 bootstrap 会立刻再拉起一个实例，
            // 且 launchd 直启的进程无法被单实例守卫识别（见 applicationDidFinishLaunching），
            // 导致菜单栏出现两个图标。launchd 会在下次登录时自动加载该 plist。
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

    @objc func showDataDir() {
        NSWorkspace.shared.open(homeDir.appendingPathComponent(".dsh"))
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    /// 退出前停止服务：先 bootout 停掉 App 托管的 launchd 任务，
    /// 再杀掉 3080 端口上的进程（覆盖外部实例/孤儿进程，保证退出后端口必释放）。
    /// 被单实例守卫淘汰的重复实例不执行此逻辑。
    func applicationWillTerminate(_ notification: Notification) {
        if !isDuplicateExit {
            stopService()
            // bootout 是异步卸载：等待任务完全消失再退出，避免服务进程残留（最多等 1 秒）
            for _ in 0..<10 where serviceLoaded() { usleep(100_000) }
            // 兜底：无论谁在跑 3080，退出都杀掉，确保「退出 App → 服务停止」
            killPort3080()
        }
    }

    @objc func refresh() {
        let state = serviceState()
        // shell 环境抓取失败时给出提示：服务能跑，但终端工具链（node/npm 等）可能不可用
        let envNote = lastEnvCaptureFailed ? "（⚠ shell 环境抓取失败，工具链可能不可用）" : ""
        switch state {
        case .running: statusLine.title = "服务：运行中 · 端口 3080\(envNote)"
        case .starting: statusLine.title = "服务：正在启动…"
        case .installing: statusLine.title = "服务：dsh 安装中…"
        case .notInstalled: statusLine.title = "服务：dsh 未安装"
        case .portBusy: statusLine.title = "服务：端口 3080 被其他程序占用"
        case .crashed: statusLine.title = "服务：启动失败（点“重启服务”重试）"
        case .stopped: statusLine.title = "服务：未运行\(envNote)"
        }
        // 「安装 dsh」：仅未安装/安装失败时显示；安装中禁用并改名
        if installInProgress {
            installItem.title = "dsh 安装中…"
            installItem.isEnabled = false
            installItem.isHidden = false
        } else if state == .notInstalled {
            installItem.title = "安装 dsh"
            installItem.isEnabled = true
            installItem.isHidden = false
        } else {
            installItem.isHidden = true
        }
        // 服务未安装时重启/打开 UI 不可用
        restartItem.isEnabled = state != .notInstalled
        openItem.isEnabled = state != .notInstalled && state != .installing
        // 「更新 dsh / 检查更新」：dsh 未安装时隐藏；升级中/检查中禁用并改名
        if !dshInstalled() {
            updateItem.isHidden = true
        } else if updatingInProgress {
            updateItem.title = "dsh 更新中…"
            updateItem.isEnabled = false
            updateItem.isHidden = false
        } else if checkingUpdates {
            updateItem.title = "检查更新…"
            updateItem.isEnabled = false
            updateItem.isHidden = false
        } else if updateAvailable, let remote = latestRemoteVersion {
            updateItem.title = "更新 dsh → \(remote)"
            updateItem.isEnabled = true
            updateItem.isHidden = false
        } else {
            updateItem.title = "检查更新"
            updateItem.isEnabled = true
            updateItem.isHidden = false
        }
        // 当前 dsh 版本（未安装时显示“未安装”）
        if let v = localDshVersion() {
            versionItem.title = "dsh 版本：v\(v)"
        } else {
            versionItem.title = "dsh 版本：未安装"
        }
        autoAppItem.state = appAutoStartEnabled() ? .on : .off
        updateDot(state)
    }

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
        // 延迟到下一个 runloop 展示，避免阻塞当前调用栈；菜单栏 App 无主窗口，不能用 sheet
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            alert.runModal()
            self?.alertShowing = false
            self?.refresh()
            self?.drainAlerts()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
