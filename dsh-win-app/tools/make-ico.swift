import AppKit
import Foundation

// DSH Launcher (Windows) App 图标生成器
//
// 与 macOS 版 tools/make-icon.swift 同一套逻辑：直接解析 dsh 官方图标
// （DeepSeek Harness 源码 apps/web/public/favicon.svg）的 <path> 路径数据，
// 渲染为透明底 + 黑色鲸鱼 logo，输出 Windows .ico（PNG 压缩的多尺寸条目，
// Win10/11 资源管理器与任务栏均支持）。
//
// 用法: make-ico <favicon.svg> <输出.ico>

func extractPathData(_ svg: String) -> (d: String, vbWidth: CGFloat, vbHeight: CGFloat)? {
    // viewBox="0 0 W H"
    var vbW: CGFloat = 50, vbH: CGFloat = 50
    if let r = svg.range(of: "viewBox=\"") {
        let rest = svg[r.upperBound...]
        if let end = rest.firstIndex(of: "\"") {
            let nums = rest[..<end].split(separator: " ").compactMap { Double($0) }
            if nums.count == 4 {
                vbW = CGFloat(nums[2]); vbH = CGFloat(nums[3])
            }
        }
    }
    // <path ... d="..." ...>  —— 取 path 元素内的 d 属性
    guard let pStart = svg.range(of: "<path")?.lowerBound else { return nil }
    let element = svg[pStart...]
    guard let dStart = element.range(of: " d=\"")?.upperBound else { return nil }
    let afterD = element[dStart...]
    guard let dEnd = afterD.firstIndex(of: "\"") else { return nil }
    return (String(afterD[..<dEnd]), vbW, vbH)
}

let args = CommandLine.arguments
guard args.count >= 2,
      let svgText = try? String(contentsOfFile: args[1], encoding: .utf8),
      let icon = extractPathData(svgText) else {
    print("usage: make-ico <favicon.svg> <out.ico>  (cannot read SVG)")
    exit(1)
}

let LOGO_PATH = icon.d
let VB_H = icon.vbHeight

func logoBezier() -> (path: NSBezierPath, bounds: NSRect) {
    enum Tok { case cmd(Character); case num(CGFloat) }
    var toks: [Tok] = []
    var cur = ""
    for ch in LOGO_PATH {
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
                x = p[0]; y = VB_H - p[1] // SVG y 向下，翻转
                let pt = NSPoint(x: x, y: y); track(pt)
                path.move(to: pt)
            case "C", "c":
                let p = next(6); guard p.count == 6 else { break }
                let c1 = NSPoint(x: p[0], y: VB_H - p[1])
                let c2 = NSPoint(x: p[2], y: VB_H - p[3])
                let e  = NSPoint(x: p[4], y: VB_H - p[5])
                track(c1); track(c2); track(e)
                path.curve(to: e, controlPoint1: c1, controlPoint2: c2)
                x = p[4]; y = VB_H - p[5]
            case "Z", "z":
                path.close()
            default:
                break
            }
        } else {
            i += 1
        }
    }
    return (path, NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
}

func renderPNG(px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let size = CGFloat(px)
    let (logo, bounds) = logoBezier()
    let scale = (size * 0.86) / bounds.width
    let t = NSAffineTransform()
    t.translateX(by: (size - bounds.width * scale) / 2 - bounds.minX * scale,
                 yBy: (size - bounds.height * scale) / 2 - bounds.minY * scale)
    t.scale(by: scale)
    NSColor.black.setFill() // favicon 浅色模式 = 黑色鲸鱼
    t.transform(logo).fill()

    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func writeICO(pngs: [(size: Int, data: Data)], to path: String) {
    var out = Data()
    // ICONDIR: reserved(2)=0, type(2)=1, count(2)
    out.append(contentsOf: [0, 0, 1, 0])
    out.append(contentsOf: [UInt8(pngs.count & 0xFF), UInt8((pngs.count >> 8) & 0xFF)])
    var offset = 6 + 16 * pngs.count
    for p in pngs {
        let sizeByte: UInt8 = p.size >= 256 ? 0 : UInt8(p.size)
        out.append(sizeByte)                 // width
        out.append(sizeByte)                 // height
        out.append(0)                        // color count
        out.append(0)                        // reserved
        out.append(contentsOf: [1, 0])       // planes = 1 (LE)
        out.append(contentsOf: [32, 0])      // bit count = 32 (LE)
        let len = p.data.count
        out.append(contentsOf: [UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF),
                                UInt8((len >> 16) & 0xFF), UInt8((len >> 24) & 0xFF)]) // size (LE)
        out.append(contentsOf: [UInt8(offset & 0xFF), UInt8((offset >> 8) & 0xFF),
                                UInt8((offset >> 16) & 0xFF), UInt8((offset >> 24) & 0xFF)]) // offset (LE)
        offset += len
    }
    for p in pngs { out.append(p.data) }
    try? out.write(to: URL(fileURLWithPath: path))
}

let outPath = args.count > 2 ? args[2] : "Resources/AppIcon.ico"
var pngs: [(Int, Data)] = []
for px in [16, 32, 48, 64, 128, 256] {
    if let data = renderPNG(px: px) { pngs.append((px, data)) }
}
guard !pngs.isEmpty else { print("failed to render"); exit(1) }
writeICO(pngs: pngs, to: outPath)
print("ico written to \(outPath): \(pngs.map { "\($0.0)px" }.joined(separator: ", "))")
