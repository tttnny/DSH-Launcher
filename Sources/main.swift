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
func runProcess(_ launchPath: String, _ args: [String]) -> (code: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let outPipe = Pipe(); let errPipe = Pipe()
    p.standardOutput = outPipe; p.standardError = errPipe
    do { try p.run() } catch { return (-1, "", "spawn failed: \(error.localizedDescription)") }
    p.waitUntilExit()
    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, out, err)
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
let appSupportDir = homeDir.appendingPathComponent("Library/Application Support/DSHLauncher", isDirectory: true)
let forwarderPath = appSupportDir.appendingPathComponent("forwarder.js")
let serviceLabel = "com.dsh.web"
let appLabel = "com.dsh.menubar"
let servicePlistURL = launchAgentsDir.appendingPathComponent("\(serviceLabel).plist")
let appPlistURL = launchAgentsDir.appendingPathComponent("\(appLabel).plist")
let guiDomain = "gui/\(getuid())"
let webURL = URL(string: "http://127.0.0.1:3080")!
let defaults = UserDefaults.standard

/// 远程访问（局域网）开关的持久化键
let remoteAccessKey = "remoteAccessEnabled"

/// 获取本机局域网 IPv4 地址（en0/en1，如 192.168.x.x）；未联网/无网卡时返回 nil
func lanIPAddress() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        let family = interface.ifa_addr.pointee.sa_family
        guard family == UInt8(AF_INET) else { continue }
        let name = String(cString: interface.ifa_name)
        guard name == "en0" || name == "en1" else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                          &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let ip = String(cString: host)
        if !ip.isEmpty { return ip }
    }
    return nil
}

/// 局域网访问地址（开启远程访问时用本机 IP，否则用本地回环）
func lanAccessURLString() -> String {
    let host = lanIPAddress() ?? "127.0.0.1"
    return "http://\(host):3080"
}

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
    if let saved = defaults.string(forKey: "workspacePath"), !saved.isEmpty { return saved }
    let candidate = homeDir.appendingPathComponent("Desktop/work/ds_test").path
    return fs.fileExists(atPath: candidate) ? candidate : homeDir.path
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

/// 找出占用 3080 端口的进程描述（lsof + ps），用于启动前提示
func port3080Occupier() -> String {
    let r = runProcess("/usr/sbin/lsof", ["-nP", "-iTCP:3080", "-sTCP:LISTEN"])
    var lines = r.out.components(separatedBy: .newlines)
    if let first = lines.first, first.hasPrefix("COMMAND") { lines.removeFirst() }
    guard let first = lines.first else { return "未知进程" }
    let fields = first.split(separator: " ").map(String.init)
    guard fields.count >= 2, let pid = Int32(fields[1]) else { return "未知进程" }
    let p = runProcess("/bin/ps", ["-p", "\(pid)", "-o", "command="])
    let cmd = p.out.trimmingCharacters(in: .whitespacesAndNewlines)
    return "PID \(pid)（\(cmd.isEmpty ? "未知命令" : cmd)）"
}

/// 服务日志尾部，用于启动失败时弹窗展示
func logTail(_ n: Int = 25) -> String {
    guard let data = fs.contents(atPath: logFile.path),
          let text = String(data: data, encoding: .utf8) else { return "(日志为空)" }
    return text.components(separatedBy: .newlines).suffix(n).joined(separator: "\n")
}

enum ServiceState { case running, starting, external, crashed, stopped }

/// 服务正在启动（App 自动拉起 / 手动重启的窗口期），期间状态显示“正在启动”
var isStarting = false

func serviceState() -> ServiceState {
    if serviceRunning() { return .running }
    if isStarting { return .starting }
    if portServing() { return .external }
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

/// forwarder.js 源码：以子进程方式启动 dsh web 并透传日志（launchd 直接运行本脚本），
/// 传 --remote 时额外监听 0.0.0.0:3080 并把局域网连接转发到 127.0.0.1:3080。
/// dsh 启动命令通过环境变量 DSH_CMD（JSON 数组）传入。
let forwarderScript = """
#!/usr/bin/env node
// DSH Launcher 托管的 dsh web 监督 + 局域网转发器（由 launchd 直接运行）
// - 以子进程启动 dsh web（官方仅允许绑定 127.0.0.1），stdio 透传进 launchd 日志
// - 传 --remote 时额外监听 0.0.0.0:3080，把局域网连接转发到 127.0.0.1:3080
//   （macOS 按最精确匹配路由：本机直连 127.0.0.1 直达 dsh，互不影响）
const { spawn } = require('node:child_process');
const net = require('node:net');

const cmd = JSON.parse(process.env.DSH_CMD || '[]');
if (!Array.isArray(cmd) || cmd.length === 0) {
  console.error('forwarder: missing DSH_CMD env');
  process.exit(1);
}

const child = spawn(cmd[0], cmd.slice(1), { stdio: 'inherit' });
child.on('error', (err) => {
  console.error('forwarder: 无法启动 dsh: ' + err.message);
  process.exit(1);
});

let server = null;
if (process.argv.includes('--remote')) {
  server = net.createServer((src) => {
    const dst = net.connect(3080, '127.0.0.1', () => {
      src.pipe(dst);
      dst.pipe(src);
    });
    src.on('error', () => { dst.destroy(); src.destroy(); });
    dst.on('error', () => { src.destroy(); dst.destroy(); });
  });
  server.on('error', (err) => {
    console.error('forwarder: ' + err.message);
    child.kill('SIGTERM');
  });
  server.listen(3080, '0.0.0.0', () => {
    console.log('dsh web LAN 转发已开启: 0.0.0.0:3080 -> 127.0.0.1:3080');
  });
}

// launchd bootout（停止服务）时转发终止信号，确保 dsh 一起退出
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    child.kill(sig);
    if (server) server.close();
    setTimeout(() => process.exit(0), 2000);
  });
}

// dsh 退出后本进程也随之退出，退出码沿用子进程，供 launchd 记录 last exit code
child.on('exit', (code, signal) => {
  if (server) server.close();
  if (signal) process.kill(process.pid, signal);
  process.exit(code === null ? 1 : code);
});
"""

/// 把 forwarder.js 写入 Application Support（每次启动服务前更新，保证与 App 版本同步）
func writeForwarderScript() -> Bool {
    do {
        try fs.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try forwarderScript.write(to: forwarderPath, atomically: true, encoding: .utf8)
        return true
    } catch {
        return false
    }
}

/// dsh web 的实际启动命令（JSON 数组，经 DSH_CMD 环境变量传给 forwarder.js 执行）。
/// 注意：dsh 目前只允许绑定 127.0.0.1 —— `--host 0.0.0.0` 会被官方
/// 以“暴露远程代码执行”为由拒绝，具体局域网 IP 也会被配置校验拦下，
/// 所以远程访问改由 forwarder.js 在 0.0.0.0:3080 转发实现。
func dshWebCommandJSON() -> String? {
    let node = resolveNodePath()
    var entry: [String]
    if let dsh = resolveDshLauncher(nodePath: node) {
        entry = [node, dsh]
    } else if let npx = resolveNpxPath(nodePath: node) {
        entry = [node, npx, "--yes", "@deepseek-ai/dsh"]
    } else {
        return nil
    }
    let cmd = entry + ["web", "--port", "3080"]
    guard let data = try? JSONSerialization.data(withJSONObject: cmd) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// 生成服务的完整启动命令（launchd 直接执行 forwarder.js，由它拉起 dsh）。
/// 优先直接跑缓存的 dsh bin.js；没有缓存时退回 `npx --yes @deepseek-ai/dsh`
/// （首次会联网下载，之后就有缓存了），保证朋友的机器开箱即用。
/// 远程访问开启时加 `--remote`（forwarder.js 监听 0.0.0.0:3080 转发到本机）。
func buildProgram() -> [String]? {
    let node = resolveNodePath()
    guard dshWebCommandJSON() != nil else { return nil }
    guard writeForwarderScript() else { return nil }
    let remote = defaults.bool(forKey: remoteAccessKey)
    return [node, forwarderPath.path] + (remote ? ["--remote"] : [])
}

func servicePlistXML(program: [String], workspace: String, dshCommand: String) -> String {
    let argsXML = program.map { "        <string>\(escapeXml($0))</string>" }.joined(separator: "\n")
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
      <key>EnvironmentVariables</key>
      <dict>
        <key>DSH_CMD</key>
        <string>\(escapeXml(dshCommand))</string>
      </dict>
      <key>WorkingDirectory</key><string>\(escapeXml(workspace))</string>
      <key>RunAtLoad</key><false/>
      <key>KeepAlive</key><false/>
      <key>StandardOutPath</key><string>\(escapeXml(logFile.path))</string>
      <key>StandardErrorPath</key><string>\(escapeXml(logFile.path))</string>
    </dict>
    </plist>
    """
}

func startService() -> Bool {
    guard let program = buildProgram(),
          let dshCommand = dshWebCommandJSON() else { return false }
    try? fs.createDirectory(at: logDir, withIntermediateDirectories: true)
    guard writePlist(servicePlistURL, servicePlistXML(program: program, workspace: workspacePath(), dshCommand: dshCommand)) else { return false }
    if serviceLoaded() && !serviceRunning() {
        launchctl(["bootout", "\(guiDomain)/\(serviceLabel)"])
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

// MARK: - App 主体

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var restartItem: NSMenuItem!
    private var remoteItem: NSMenuItem!
    private var lanAddrItem: NSMenuItem!
    private var copyURLItem: NSMenuItem!
    private var autoAppItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例守卫：菜单栏 App 重复打开会出现多个图标，保留最早的那个。
        // 不能用 bundle id 查询（launchd 直启的进程可能无法关联 bundle），
        // 改为按“可执行文件路径相同”匹配所有运行中的应用。
        let myExe = Bundle.main.executableURL?.standardizedFileURL.path
        let dupes = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            $0.executableURL?.standardizedFileURL.path == myExe
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
        updateDot()
        buildMenu()
        // 生命周期绑定：App 在 → 服务在，启动即自动拉起服务；
        // 先启动（内部立即刷新为“正在启动”），避免闪一帧“未运行”
        autoStartService()
        refresh()
        let t = Timer(timeInterval: 3, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func updateDot() {
        guard let button = statusItem.button else { return }
        let color: NSColor = {
            switch serviceState() {
            case .running: return .systemGreen
            case .starting: return .systemGray
            case .external: return .systemOrange
            case .crashed: return .systemRed
            case .stopped: return .systemGray
            }
        }()
        // dsh 鲸鱼图标按状态着色
        if let image = whaleMenuImage(color: color) {
            button.image = image
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            // 兜底：图标资源缺失时退回旧圆点
            let (char, _): (String, NSColor) = {
                switch serviceState() {
                case .running: return ("●", .systemGreen)
                case .starting: return ("◌", .systemGray)
                case .external: return ("◍", .systemOrange)
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

        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "打开 Web UI", action: #selector(openUI), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        restartItem = NSMenuItem(title: "重启服务", action: #selector(doRestart), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        menu.addItem(.separator())

        remoteItem = NSMenuItem(title: "远程访问（局域网）", action: #selector(toggleRemote(_:)), keyEquivalent: "")
        remoteItem.target = self
        menu.addItem(remoteItem)

        // 仅远程开启且有局域网 IP 时显示当前访问地址
        lanAddrItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        lanAddrItem.isEnabled = false
        menu.addItem(lanAddrItem)

        copyURLItem = NSMenuItem(title: "复制访问地址", action: #selector(copyAccessURL), keyEquivalent: "l")
        copyURLItem.target = self
        menu.addItem(copyURLItem)

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
    /// 端口被外部实例占用时不弹窗打扰（状态行显示橙色即可）；启动窗口期显示“正在启动”，
    /// kickstart 后 3.5 秒健康检查，进程没起来才弹日志尾部。
    func autoStartService() {
        if serviceRunning() || portServing() { return }
        isStarting = true
        refresh()
        if !startService() {
            isStarting = false
            showAlert(title: "服务启动失败", message: "无法写入 LaunchAgent 或启动服务。\n\n日志尾部：\n\(logTail())")
            refresh()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self = self else { return }
            isStarting = false
            if !serviceRunning() && !portServing() {
                self.showAlert(title: "服务启动失败", message: "服务进程已退出，日志尾部：\n\(logTail())")
            }
            self.refresh()
        }
    }

    @objc func openUI() {
        NSWorkspace.shared.open(webURL)
    }

    /// 重启服务 = 无论当前状态如何都能把服务拉起来：
    /// 运行中 → 停止后重新拉起；启动失败/未运行 → 直接启动；
    /// 端口被外部实例占用 → 弹窗说明占用者（不破坏外部实例）。
    @objc func doRestart() {
        if !serviceRunning() && portServing() {
            showAlert(title: "端口 3080 已被占用",
                      message: "占用者：\(port3080Occupier())\n\n请先停止占用端口的进程（如果是终端里跑的 dsh web，在终端按 Ctrl+C），再点“重启服务”。")
            refresh()
            return
        }
        stopService()
        isStarting = true
        refresh()
        var attempts = 0
        func tryStart() {
            attempts += 1
            if startService() || attempts >= 6 {
                // 无论成败，3.5 秒后结束“正在启动”状态并做健康检查
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                    guard let self = self else { return }
                    isStarting = false
                    if !serviceRunning() && !portServing() {
                        self.showAlert(title: "服务重启失败", message: "日志尾部：\n\(logTail())")
                    }
                    self.refresh()
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tryStart() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tryStart() }
    }

    /// 远程访问开关：dsh web 官方禁止直接绑定 0.0.0.0，所以开启时改为由
    /// forwarder.js 额外监听 0.0.0.0:3080 并转发到本机 3080（局域网可访问），
    /// 关闭时仅本机。切换后若服务在运行，自动重启使配置生效。
    @objc func toggleRemote(_ item: NSMenuItem) {
        let on = item.state == .off
        defaults.set(on, forKey: remoteAccessKey)
        refresh()
        if on {
            if lanIPAddress() == nil {
                showAlert(title: "未检测到局域网 IP",
                          message: "看起来当前网络没有可用的局域网地址（en0/en1）。远程访问已开启，但其他设备可能无法连接，请检查 Wi-Fi/网线。")
            }
        }
        if serviceLoaded() || serviceRunning() {
            doRestart()
        }
    }

    /// 复制局域网访问地址到剪贴板：http://<本机IP>:3080
    @objc func copyAccessURL() {
        let ip = lanIPAddress()
        let remoteOn = defaults.bool(forKey: remoteAccessKey)
        let url: String
        if remoteOn, let ip = ip {
            url = "http://\(ip):3080"
        } else if let ip = ip {
            url = "http://\(ip):3080"
        } else {
            url = "http://127.0.0.1:3080"
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url, forType: .string)
        // 菜单项标题短暂变为“已复制”，给用户视觉反馈
        let original = copyURLItem.title
        copyURLItem.title = "已复制：\(url) ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copyURLItem.title = original
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

    /// 退出前自动停止服务（launchctl bootout；只停本 App 托管的 launchd 任务，
    /// 不影响其他进程占用的端口）。被单实例守卫淘汰的重复实例不执行此逻辑。
    func applicationWillTerminate(_ notification: Notification) {
        if !isDuplicateExit {
            stopService()
        }
    }

    @objc func refresh() {
        let state = serviceState()
        switch state {
        case .running: statusLine.title = "服务：运行中 · 端口 3080"
        case .starting: statusLine.title = "服务：正在启动…"
        case .external: statusLine.title = "服务：外部实例运行中（端口 3080 被占用）"
        case .crashed: statusLine.title = "服务：启动失败（点“重启服务”重试）"
        case .stopped: statusLine.title = "服务：未运行"
        }
        // 重启服务永远可用：运行中=重启，失败/未运行=启动，外部占用=弹窗说明
        restartItem.isEnabled = true
        autoAppItem.state = appAutoStartEnabled() ? .on : .off
        let remoteOn = defaults.bool(forKey: remoteAccessKey)
        remoteItem.state = remoteOn ? .on : .off
        if remoteOn, let ip = lanIPAddress() {
            lanAddrItem.title = "局域网地址：http://\(ip):3080"
            lanAddrItem.isHidden = false
        } else {
            lanAddrItem.isHidden = true
        }
        updateDot()
    }

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
