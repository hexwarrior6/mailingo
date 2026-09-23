#!/usr/bin/env swift
//
// 把一张 1024×1024 的方形画稿，变成 macOS 能直接用的 App 图标资源。
//
//   swift Scripts/make-appicon.swift <画稿.png>
//   swift Scripts/make-appicon.swift <画稿.png> --flat        # 不烘焙投影
//
// 为什么需要这个脚本，而不是把 AI 出的图直接丢进 Assets.xcassets：
//
// ① **macOS 不会帮你裁圆角。** 和 iOS 不同，Mac 的 App 图标必须在图片里
//    自带圆角与留白，系统原样显示。所以直接放一张满幅方图，Dock 里会是
//    一个方角块，紧挨着原生图标一眼就露馅。
//
// ② **圆角不是圆角矩形。** 实测 Apple 自带图标（备忘录/提醒事项/照片，
//    三者像素级一致）：
//        · 形状占地 824×824，居中，四边留白 100px（1024 画布）
//        · 但圆角是**连续曲率的 squircle**，不是 NSBezierPath 的圆角矩形
//    证据：顶边往下 40px 处，真实形状宽 679，而半径 185 的圆角矩形在那个
//    深度只有 469 宽。两者"切掉的面积"却几乎一样（圆角半径 185.4 的圆角
//    矩形切掉约 2.8% 画布面积，实测形状占 61.9%，正好吻合）——也就是说
//    squircle 把同样的圆角做得**更饱满**，用圆角矩形近似会明显偏尖。
//    → 所以这里不自己拟合曲线，而是**直接从系统图标里抠出官方形状当蒙版**，
//      这是唯一能做到像素级正确的办法。
//
// ③ **Apple 确实烘焙了投影。** 实测实心底边之下还有约 44px 的投影，
//    紧贴边缘处 alpha ≈ 73（约 29%），到 +44px 衰减为 0。Mac 系统不会
//    替图标加投影，所以这层得自己画。
//
// 用法上只需要给一张图：蒙版里已经自带 100px 的留白了，
// 画稿铺满 1024 画布即可，不需要自己缩到 824。
//
import AppKit
import Foundation

// MARK: - 常量

/// 官方形状的基准画布。所有几何都以蒙版为准，这里只用于校验。
let canvasSize = 1024

/// appiconset 的 10 个槽位 → 像素阶梯只有 7 档。
/// (像素尺寸, size 字段, scale 字段)
let slots: [(pixels: Int, size: String, scale: String)] = [
    (16,   "16x16",     "1x"),
    (32,   "16x16",     "2x"),
    (32,   "32x32",     "1x"),
    (64,   "32x32",     "2x"),
    (128,  "128x128",   "1x"),
    (256,  "128x128",   "2x"),
    (256,  "256x256",   "1x"),
    (512,  "256x256",   "2x"),
    (512,  "512x512",   "1x"),
    (1024, "512x512",   "2x"),
]

/// 系统图标的候选来源。任意一个 Mac 上都有，用来取官方形状。
/// 优先挑形状最"标准"的（备忘录/提醒事项/照片三者像素级一致）。
let maskSources = [
    "/System/Applications/Notes.app/Contents/Resources/AppIcon.icns",
    "/System/Applications/Reminders.app/Contents/Resources/AppIcon.icns",
    "/System/Applications/Photos.app/Contents/Resources/AppIcon.icns",
]

// MARK: - 命令行

let args = Array(CommandLine.arguments.dropFirst())

/// 顺序解析。有带值的选项（--shrink），所以不能简单按前缀找位置参数。
var artPath: String?
var bakeShadow = true
var makePreview = true
var shrinkPercent = 100.0
var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "--flat":        bakeShadow = false
    case "--no-preview":  makePreview = false
    case "--shrink":
        guard i + 1 < args.count, let v = Double(args[i + 1]), v > 0, v <= 100 else {
            FileHandle.standardError.write("❌ --shrink 需要一个 1…100 的数值\n".data(using: .utf8)!)
            exit(2)
        }
        shrinkPercent = v
        i += 1
    default:
        if a.hasPrefix("--") {
            FileHandle.standardError.write("❌ 不认识的选项：\(a)\n".data(using: .utf8)!)
            exit(2)
        }
        artPath = a
    }
    i += 1
}

guard let artPath else {
    FileHandle.standardError.write("""
    用法：swift Scripts/make-appicon.swift <画稿.png> [--shrink 100] [--flat] [--no-preview]

      画稿.png      方形图片（1024 或更大最好；非正方形会居中裁成正方形）
      --shrink N    把画稿缩到画布的 N% 并居中，四周用边缘延展补背景。
                    默认 100（不动）。**主体画得太满时用这个还呼吸感** ——
                    App 图标的形状只占画布 824/1024，四周 100px 天然看不见，
                    所以主体占满画布的画稿套上蒙版后会显得贴边。
                    实测本项目的画稿用 88 比较合适。
      --flat        不烘焙投影（默认烘焙，与 Apple 自带图标一致）
      --no-preview  不生成小尺寸/明暗对照图

    """.data(using: .utf8)!)
    exit(2)
}

/// 仓库根目录 = 本脚本所在目录的上一级。这样从任何目录跑都写对地方。
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

// MARK: - 像素缓冲

/// 把 CGImage 画进一个 RGBA8 缓冲。
///
/// **行序**：CGBitmapContext 的用户坐标原点在左下，但内存里第一行对应
/// 图像的**顶部**。所以 buffer[0] 是最上面一行——下面所有代码都按
/// "行号越小越靠上"来理解。
func rgbaBuffer(_ image: CGImage, size: Int) -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: size * size * 4)
    guard let ctx = CGContext(
        data: &buffer, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return buffer
}

/// 居中裁成正方形（非正方形画稿的唯一合理处理方式：不拉伸、不裁内容以外的东西）。
func centerCropped(_ image: CGImage) -> CGImage {
    let w = image.width, h = image.height
    guard w != h else { return image }
    let side = min(w, h)
    let rect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
    return image.cropping(to: rect) ?? image
}

// MARK: - 官方形状蒙版

/// 从系统图标里取出 macOS 官方圆角形状，做成一张灰度蒙版。
///
/// 关键一步是**把投影和形状分开**。系统图标的 alpha 是"形状 叠在 投影 上"
/// 的合成结果，直接拿来当蒙版会把投影一起套到新图标上（变成一圈彩色晕）。
///
/// 做法是阈值 128：
///   · 形状本体内部 alpha = 255
///   · 抗锯齿边缘是一条 0→255 的斜坡，取 128（50%）正好落在真实边界上
///   · 投影紧贴形状边缘处最高只有 alpha ≈ 73，**低于 128，会被整体滤掉**
/// 再补一次极轻的模糊，把二值化的硬边还原成平滑边缘。
func officialShapeMask() -> [UInt8]? {
    guard let source = maskSources.first(where: { FileManager.default.fileExists(atPath: $0) }),
          let image = NSImage(contentsOfFile: source),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let alpha = rgbaBuffer(cg, size: canvasSize) else {
        return nil
    }

    // ① 阈值化 + 取 alpha 通道
    var mask = [UInt8](repeating: 0, count: canvasSize * canvasSize)
    for i in 0..<(canvasSize * canvasSize) {
        mask[i] = alpha[i * 4 + 3] >= 128 ? 255 : 0
    }

    // ② 两次 3-tap 盒式模糊 ≈ 高斯 σ≈1，只为把硬边磨平
    for _ in 0..<2 { mask = boxBlur3(mask) }
    return mask
}

/// 3-tap 盒式模糊（水平+垂直），足够把二值边缘变成平滑过渡。
func boxBlur3(_ src: [UInt8]) -> [UInt8] {
    let n = canvasSize
    var tmp = [UInt8](repeating: 0, count: n * n)
    var out = [UInt8](repeating: 0, count: n * n)
    for y in 0..<n {
        for x in 0..<n {
            let l = src[y * n + max(0, x - 1)], c = src[y * n + x], r = src[y * n + min(n - 1, x + 1)]
            tmp[y * n + x] = UInt8((Int(l) + Int(c) + Int(r)) / 3)
        }
    }
    for y in 0..<n {
        for x in 0..<n {
            let u = tmp[max(0, y - 1) * n + x], c = tmp[y * n + x], d = tmp[min(n - 1, y + 1) * n + x]
            out[y * n + x] = UInt8((Int(u) + Int(c) + Int(d)) / 3)
        }
    }
    return out
}

/// 找不到系统图标时的兜底：824×824 居中 + 圆角 185.4 的普通圆角矩形。
/// 形状比官方的略"尖"（见文件头 ②），但总比直接出方角好。
func fallbackMask() -> [UInt8] {
    let inset = 100.0, radius = 185.4
    let side = Double(canvasSize) - inset * 2
    var mask = [UInt8](repeating: 0, count: canvasSize * canvasSize)
    for y in 0..<canvasSize {
        for x in 0..<canvasSize {
            // 到圆角矩形中心的归一化距离（用圆角矩形的有符号距离场）
            let px = Double(x) + 0.5 - Double(canvasSize) / 2
            let py = Double(y) + 0.5 - Double(canvasSize) / 2
            let half = side / 2
            let dx = abs(px) - (half - radius)
            let dy = abs(py) - (half - radius)
            let dist: Double
            if dx > 0 && dy > 0 { dist = (dx * dx + dy * dy).squareRoot() }
            else { dist = max(dx, dy) }
            // 1px 过渡带做抗锯齿
            let coverage = min(max(radius + 0.5 - dist, 0), 1)
            mask[y * canvasSize + x] = UInt8(coverage * 255)
        }
    }
    return mask
}

/// 把画稿按百分比缩到画布中央，四周用**边缘延展**补齐。
///
/// 为什么需要这一步：App 图标的形状只占画布的 824/1024，画稿四周那 100px
/// 天然在形状之外。如果画稿主体本来就画得很满（AI 出图常常如此），套上蒙版
/// 后主体边缘就只剩很窄一条背景，观感上像"被切了"。
///
/// 缩完之后四周会空出来，不能留透明。补背景用**镜像**（把边缘往里反射），
/// 不用"把最外圈像素往外拉"的那种延展 —— 本项目的画稿是**中心发光**，
/// 亮度从中心往四周衰减，延展会把边缘那圈亮度直接拉出去，围出一道比中心
/// 还亮的蓝环；镜像则让亮度继续朝外衰减，接缝看不出来。
func shrunkToCanvas(_ image: CGImage, percent: Double) -> [UInt8]? {
    guard percent < 100 else { return rgbaBuffer(image, size: canvasSize) }
    let inner = max(1, Int((Double(canvasSize) * percent / 100).rounded()))
    guard let small = rgbaBuffer(image, size: inner) else { return nil }
    let offset = (canvasSize - inner) / 2

    /// 把画布坐标反射回 [0, inner) 之内。周期 2·inner。
    func reflect(_ v: Int) -> Int {
        var t = v % (2 * inner)
        if t < 0 { t += 2 * inner }
        return t < inner ? t : 2 * inner - 1 - t
    }

    var out = [UInt8](repeating: 0, count: canvasSize * canvasSize * 4)
    for y in 0..<canvasSize {
        let sy = reflect(y - offset)
        for x in 0..<canvasSize {
            let sx = reflect(x - offset)
            let src = (sy * inner + sx) * 4
            let dst = (y * canvasSize + x) * 4
            out[dst]     = small[src]
            out[dst + 1] = small[src + 1]
            out[dst + 2] = small[src + 2]
            out[dst + 3] = small[src + 3]
        }
    }
    return out
}

// MARK: - 主流程

print("== Mailingo App 图标 ==")

// ① 读画稿
guard let artImage = NSImage(contentsOfFile: artPath)?.cgImage(
    forProposedRect: nil, context: nil, hints: nil
) else {
    FileHandle.standardError.write("❌ 读不出画稿：\(artPath)\n".data(using: .utf8)!)
    exit(1)
}
if artImage.width != artImage.height {
    print("⚠️  画稿不是正方形（\(artImage.width)×\(artImage.height)），已居中裁剪")
}
if artImage.width < canvasSize {
    print("⚠️  画稿只有 \(artImage.width)px，放大到 \(canvasSize)px 会变糊，建议重新生成更大的")
}

let squared = centerCropped(artImage)
guard var art = shrunkToCanvas(squared, percent: shrinkPercent) else {
    FileHandle.standardError.write("❌ 无法把画稿转成像素缓冲\n".data(using: .utf8)!)
    exit(1)
}
if shrinkPercent < 100 {
    print("· 画稿已缩到 \(Int(shrinkPercent))% 并居中，四周用镜像反射补背景")
}

// ② 取官方形状
let mask: [UInt8]
if let official = officialShapeMask() {
    mask = official
    print("✓ 已从系统图标取得 macOS 官方圆角形状")
} else {
    mask = fallbackMask()
    print("⚠️  系统图标不可读，改用圆角矩形兜底（形状会略尖于原生图标）")
}

// ③ 把形状套到画稿上。
//    缓冲是 premultipliedLast，所以四个通道一起乘蒙版值才是对的。
for i in 0..<(canvasSize * canvasSize) {
    let m = Int(mask[i])
    guard m < 255 else { continue }
    for c in 0..<4 { art[i * 4 + c] = UInt8(Int(art[i * 4 + c]) * m / 255) }
}

guard let maskedProvider = CGDataProvider(data: Data(art) as CFData),
      let masked = CGImage(
        width: canvasSize, height: canvasSize,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: canvasSize * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: maskedProvider, decode: nil, shouldInterpolate: true,
        intent: .defaultIntent
      ) else {
    FileHandle.standardError.write("❌ 构建蒙版后的图像失败\n".data(using: .utf8)!)
    exit(1)
}

// ④ 烘焙投影，得到最终 1024 母版。
//    参数按实测的系统图标投影轮廓拟合：紧贴边缘 alpha≈73、到 +44px 归零。
//    画法上先蒙版后投影（而不是先画形状再用阴影填充），这样投影的轮廓
//    就是圆角形状本身，不会在边缘留下一圈深色描边。
func renderMaster() -> CGImage {
    guard bakeShadow else { return masked }
    var buffer = [UInt8](repeating: 0, count: canvasSize * canvasSize * 4)
    guard let ctx = CGContext(
        data: &buffer, width: canvasSize, height: canvasSize,
        bitsPerComponent: 8, bytesPerRow: canvasSize * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return masked }
    ctx.interpolationQuality = .high
    // 参数是**对着系统图标量出来的**，不是拍脑袋：以实心底边为 0，
    // 逐点比对 alpha 轮廓收敛到这套值（+8px→50 对比系统 53，+16→30 对 34，
    // +24→13 对 16，+32→4 对 5）。用户坐标原点在左下，向下偏移 = y 取负。
    ctx.setShadow(offset: CGSize(width: 0, height: -8),
                  blur: 28,
                  color: NSColor.black.withAlphaComponent(0.34).cgColor)
    ctx.draw(masked, in: CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
    guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return masked }
    return CGImage(width: canvasSize, height: canvasSize, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: canvasSize * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true,
                   intent: .defaultIntent) ?? masked
}
let master = renderMaster()
print("✓ 母版已生成（1024×1024，\(bakeShadow ? "含烘焙投影" : "无投影")）")

// ⑤ 缩放并写出
func scaled(_ image: CGImage, to pixels: Int) -> CGImage? {
    guard pixels != image.width else { return image }
    var buffer = [UInt8](repeating: 0, count: pixels * pixels * 4)
    guard let ctx = CGContext(
        data: &buffer, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: pixels * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
    return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true,
                   intent: .defaultIntent)
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-appicon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG 编码失败"])
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try data.write(to: url)
}

/// 两个 target 都要一份：容器 App 用在自己的图标上，
/// appex 用在自己那份（Mail 设置里的扩展列表会读它）。
let catalogRoots = [
    repoRoot.appendingPathComponent("App/Resources/Assets.xcassets"),
    repoRoot.appendingPathComponent("MailExtension/Resources/Assets.xcassets"),
]

let contentsJSON = """
{
  "images" : [
\(slots.map { slot in
    let suffix = slot.scale == "1x" ? "" : "@2x"
    return """
        {
          "filename" : "icon_\(slot.size)\(suffix).png",
          "idiom" : "mac",
          "scale" : "\(slot.scale)",
          "size" : "\(slot.size)"
        }
    """
}.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

var written = 0
for catalog in catalogRoots {
    let setDir = catalog.appendingPathComponent("AppIcon.appiconset")
    try? FileManager.default.removeItem(at: setDir)
    try FileManager.default.createDirectory(at: setDir, withIntermediateDirectories: true)
    for slot in slots {
        guard let img = scaled(master, to: slot.pixels) else { continue }
        let suffix = slot.scale == "1x" ? "" : "@2x"
        try writePNG(img, to: setDir.appendingPathComponent("icon_\(slot.size)\(suffix).png"))
        written += 1
    }
    try contentsJSON.write(to: setDir.appendingPathComponent("Contents.json"),
                           atomically: true, encoding: .utf8)
    // Catalog 自己的 Info（不是必须，但能让 Xcode 少猜）
    try """
    {
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """.write(to: catalog.appendingPathComponent("Contents.json"),
              atomically: true, encoding: .utf8)
    print("✓ \(catalog.path.replacingOccurrences(of: repoRoot.path + "/", with: ""))")
}
print("  共写出 \(written) 个 PNG（\(slots.count) 档 × \(catalogRoots.count) 个 catalog）")

// ⑥ 对照图：小尺寸 + 明暗底。
//    白/浅色图标在小尺寸下最容易"糊成一团"，这一步就是为了不装到系统里也能看出来。
if makePreview {
    let sizes = [16, 32, 64, 128, 256]
    let pad = 28, rowH = 300, width = 1180, height = rowH * 2
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    if let ctx = CGContext(data: &buffer, width: width, height: height,
                           bitsPerComponent: 8, bytesPerRow: width * 4,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        // 上排浅底、下排深底。用户坐标原点在左下，所以先画的是**下排**。
        ctx.setFillColor(NSColor(white: 0.13, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: rowH))
        ctx.setFillColor(NSColor(white: 0.98, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: rowH, width: width, height: rowH))

        for yBase in [rowH, 0] {
            var x = pad
            for size in sizes {
                if let img = scaled(master, to: size) {
                    let y = yBase + (rowH - size) / 2
                    ctx.draw(img, in: CGRect(x: x, y: y, width: size, height: size))
                }
                x += size + pad
            }
        }
    }
    if let provider = CGDataProvider(data: Data(buffer) as CFData),
       let preview = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: false,
                             intent: .defaultIntent) {
        let out = repoRoot.appendingPathComponent(".build/appicon-preview.png")
        try? writePNG(preview, to: out)
        print("✓ 对照图（上浅底下深底，16/32/64/128/256）：\(out.path)")
    }
}

print("""

下一步：
  1. make gen && make build    # project.yml 已挂上 Assets.xcassets 与 AppIcon
  2. 看 .build/appicon-preview.png，确认 16px 下还认得出形状
""")
