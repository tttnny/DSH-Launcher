import AppKit
import Foundation

// DSH Launcher App 图标生成器
//
// 直接使用 dsh 官方图标（DeepSeek Harness 源码 apps/web/public/favicon.svg，
// 即 @deepseek-ai/dsh-web-frontend/dist/favicon.svg）：
// 运行时解析该 SVG 的 <path> 路径数据，按官方 favicon 原样绘制——
// 透明底 + 黑色鲸鱼 logo（浅色模式下的 favicon 样式），输出 iconset 各尺寸 PNG。
//
// 用法: make-icon <favicon.svg> <iconset输出目录>

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
    print("usage: make-icon <favicon.svg> <iconset dir>  (cannot read SVG)")
    exit(1)
}

let LOGO_PATH = icon.d
let VB_W = icon.vbWidth
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

func renderIcon(path: String, px: Int) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        print("failed to create context for \(px)")
        return
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let size = CGFloat(px)
    // 透明底，与官方 favicon 一致；鲸鱼按 favicon 原比例（宽约占总宽 86%）居中
    let (logo, bounds) = logoBezier()
    let scale = (size * 0.86) / bounds.width
    let t = NSAffineTransform()
    t.translateX(by: (size - bounds.width * scale) / 2 - bounds.minX * scale,
                 yBy: (size - bounds.height * scale) / 2 - bounds.minY * scale)
    t.scale(by: scale)
    let final = t.transform(logo)
    NSColor.black.setFill() // favicon 浅色模式 = 黑色鲸鱼
    final.fill()

    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("failed to encode \(path)")
        return
    }
    try? png.write(to: URL(fileURLWithPath: path))
}

let outDir = args.count > 2 ? args[2] : "build/AppIcon.iconset"
let specs: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x")
]
for (px, name) in specs {
    renderIcon(path: "\(outDir)/\(name).png", px: px)
}
print("icon set written to \(outDir) (logo from \(args[1]))")
