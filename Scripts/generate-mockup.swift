#!/usr/bin/env swift
import AppKit
import Foundation

let rawPath = "docs/assets/screenshot-raw.png"
let fallbackPath = "docs/assets/screenshot-main.png"
let screenshotPath = FileManager.default.fileExists(atPath: rawPath) ? rawPath : fallbackPath
guard let screenshotImage = NSImage(contentsOfFile: screenshotPath) else {
    print("❌ 无法读取截图：\(screenshotPath)")
    exit(1)
}

// 目标画布尺寸 (PommePlate / Modern MacBook Pro 16 规格)
let totalW: CGFloat = 3910
let totalH: CGFloat = 2236

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(totalW),
    pixelsHigh: Int(totalH),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
let cg = context.cgContext

// 1. 底部机身投影 (Ambient drop shadow)
let shadowPath = NSBezierPath(ovalIn: CGRect(x: 240, y: 15, width: totalW - 480, height: 110))
NSColor(white: 0.0, alpha: 0.20).setFill()
shadowPath.fill()

// 2. 现代全面屏规格 (Ultra-thin bezel 全面屏)
let lidW: CGFloat = 3180
let lidX: CGFloat = (totalW - lidW) / 2 // 365

// 适度加粗边框 (Top: 40px, Left: 40px, Right: 40px, Chin: 48px，比例更稳重大气)
let bezelSize: CGFloat = 40
let chinSize: CGFloat = 48

let screenW: CGFloat = lidW - (bezelSize * 2) // 3100
let srcSize = screenshotImage.size
let scale = screenW / srcSize.width // 3100 / 2940 = 1.05442
let screenH: CGFloat = round(srcSize.height * scale) // 2016

let lidH: CGFloat = screenH + bezelSize + chinSize // 2104
let lidY: CGFloat = 74 // 距离底部底座的位置

// 上盖外框 (深空灰铝合金)
let lidOuterRect = CGRect(x: lidX, y: lidY, width: lidW, height: lidH)
let lidOuterPath = NSBezierPath(roundedRect: lidOuterRect, xRadius: 40, yRadius: 40)
NSColor(red: 0.58, green: 0.59, blue: 0.61, alpha: 1.0).setFill() // 外壳铝合金银灰
lidOuterPath.fill()

// 屏幕外圈纯黑窄边框 (全面屏薄中框)
let bezelRect = lidOuterRect.insetBy(dx: 8, dy: 8)
let bezelPath = NSBezierPath(roundedRect: bezelRect, xRadius: 36, yRadius: 36)
NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1.0).setFill()
bezelPath.fill()

// 3. 屏幕显示区域 (Active Display Area)
let screenX: CGFloat = lidX + bezelSize // 405
let screenY: CGFloat = lidY + chinSize  // 122
let screenRect = CGRect(x: screenX, y: screenY, width: screenW, height: screenH)

// 现代 MacBook 屏幕顶部弧度 (Liquid Retina XDR 圆角)
let screenClipPath = NSBezierPath()
let screenRadius: CGFloat = 18
let left = screenRect.minX
let right = screenRect.maxX
let bottom = screenRect.minY
let top = screenRect.maxY

screenClipPath.move(to: CGPoint(x: left, y: bottom + 4))
screenClipPath.line(to: CGPoint(x: left, y: top - screenRadius))
screenClipPath.appendArc(from: CGPoint(x: left, y: top),
                         to: CGPoint(x: left + screenRadius, y: top),
                         radius: screenRadius)
screenClipPath.line(to: CGPoint(x: right - screenRadius, y: top))
screenClipPath.appendArc(from: CGPoint(x: right, y: top),
                         to: CGPoint(x: right, y: top - screenRadius),
                         radius: screenRadius)
screenClipPath.line(to: CGPoint(x: right, y: bottom + 4))
screenClipPath.line(to: CGPoint(x: left, y: bottom + 4))
screenClipPath.close()

cg.saveGState()
screenClipPath.addClip()

// 黑色底色
NSColor.black.setFill()
screenRect.fill()

// 绘制截图内容 (顶部完全对齐，严禁裁切顶上内容)
let drawW = screenW
let drawH = screenH
let drawX = screenX
let drawY = screenY // drawY + drawH == screenY + screenH (精确贴合)

screenshotImage.draw(in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH),
                     from: .zero,
                     operation: .sourceOver,
                     fraction: 1.0)

// 4. 现代 MacBook 经典标志：居中刘海 (Camera Notch)
let notchW: CGFloat = 216
let notchH: CGFloat = 78 // 与菜单栏高度精确契合
let notchRadius: CGFloat = 12
let notchX = screenX + (screenW - notchW) / 2
let notchTop = top
let notchBottom = top - notchH

let notchPath = NSBezierPath()
notchPath.move(to: CGPoint(x: notchX, y: notchTop))
notchPath.line(to: CGPoint(x: notchX, y: notchBottom + notchRadius))
notchPath.appendArc(from: CGPoint(x: notchX, y: notchBottom),
                    to: CGPoint(x: notchX + notchRadius, y: notchBottom),
                    radius: notchRadius)
notchPath.line(to: CGPoint(x: notchX + notchW - notchRadius, y: notchBottom))
notchPath.appendArc(from: CGPoint(x: notchX + notchW, y: notchBottom),
                    to: CGPoint(x: notchX + notchW, y: notchBottom + notchRadius),
                    radius: notchRadius)
notchPath.line(to: CGPoint(x: notchX + notchW, y: notchTop))
notchPath.close()

NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1.0).setFill()
notchPath.fill()

// 5. 刘海内部摄像头与指示灯 (FaceTime HD Camera in Notch)
let cameraCenterY = notchTop - (notchH / 2) + 2
let cameraCenterX = totalW / 2

// 镜头外圈
let cameraOuter = NSBezierPath(ovalIn: CGRect(x: cameraCenterX - 7, y: cameraCenterY - 7, width: 14, height: 14))
NSColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1.0).setFill()
cameraOuter.fill()

// 镜头高光反光 (深蓝紫镀膜)
let lensInner = NSBezierPath(ovalIn: CGRect(x: cameraCenterX - 3, y: cameraCenterY - 3, width: 6, height: 6))
NSColor(red: 0.18, green: 0.28, blue: 0.45, alpha: 0.85).setFill()
lensInner.fill()

// 微弱环境光传感器孔
let sensorHole = NSBezierPath(ovalIn: CGRect(x: cameraCenterX + 28, y: cameraCenterY - 2, width: 4, height: 4))
NSColor(red: 0.08, green: 0.09, blue: 0.10, alpha: 0.9).setFill()
sensorHole.fill()

// 屏幕边缘轻微内边框高光
let screenEdgeHighlight = NSBezierPath(rect: screenRect)
NSColor(white: 1.0, alpha: 0.04).setStroke()
screenEdgeHighlight.lineWidth = 1.0
screenEdgeHighlight.stroke()

cg.restoreGState()

// 6. 下方机身底座 (Base / Chin)
let baseY: CGFloat = lidY - 44
let basePath = NSBezierPath()
basePath.move(to: CGPoint(x: 240, y: baseY))
basePath.line(to: CGPoint(x: totalW - 240, y: baseY))
basePath.curve(to: CGPoint(x: totalW, y: baseY + 50),
               controlPoint1: CGPoint(x: totalW - 100, y: baseY + 5),
               controlPoint2: CGPoint(x: totalW, y: baseY + 25))
basePath.line(to: CGPoint(x: totalW, y: baseY + 88))
basePath.line(to: CGPoint(x: 0, y: baseY + 88))
basePath.line(to: CGPoint(x: 0, y: baseY + 50))
basePath.curve(to: CGPoint(x: 240, y: baseY),
               controlPoint1: CGPoint(x: 0, y: baseY + 25),
               controlPoint2: CGPoint(x: 100, y: baseY + 5))
basePath.close()

let baseGradient = NSGradient(
    colorsAndLocations:
    (NSColor(red: 0.52, green: 0.53, blue: 0.55, alpha: 1.0), 0.0),
    (NSColor(red: 0.68, green: 0.69, blue: 0.71, alpha: 1.0), 0.4),
    (NSColor(red: 0.60, green: 0.61, blue: 0.63, alpha: 1.0), 1.0)
)!
baseGradient.draw(in: basePath, angle: 90)

// 顶部高光细线
let highlightPath = NSBezierPath()
highlightPath.move(to: CGPoint(x: 0, y: baseY + 88))
highlightPath.line(to: CGPoint(x: totalW, y: baseY + 88))
NSColor(white: 1.0, alpha: 0.35).setStroke()
highlightPath.lineWidth = 1.5
highlightPath.stroke()

// 开盖凹槽 (Opening Notch / Thumb groove)
let thumbNotchW: CGFloat = 380
let thumbNotchH: CGFloat = 24
let thumbNotchRect = CGRect(x: (totalW - thumbNotchW) / 2, y: baseY + 88 - thumbNotchH, width: thumbNotchW, height: thumbNotchH)
let thumbNotchPath = NSBezierPath(roundedRect: thumbNotchRect, xRadius: 10, yRadius: 10)
NSColor(red: 0.38, green: 0.39, blue: 0.41, alpha: 1.0).setFill()
thumbNotchPath.fill()

NSGraphicsContext.restoreGraphicsState()

// 裁剪周围多余透明区域 (保留自然呼吸留白)
let cropRect = CGRect(x: 160, y: 10, width: totalW - 320, height: totalH - 10)
let croppedRep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(cropRect.width),
    pixelsHigh: Int(cropRect.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let cropCtx = NSGraphicsContext(bitmapImageRep: croppedRep)!
NSGraphicsContext.current = cropCtx
let croppedImage = NSImage(data: rep.representation(using: .png, properties: [:])!)!
croppedImage.draw(in: CGRect(origin: .zero, size: cropRect.size),
                  from: cropRect,
                  operation: .copy,
                  fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

let outputURL = URL(fileURLWithPath: "docs/assets/screenshot-main.png")
let finalData = croppedRep.representation(using: .png, properties: [:])!
try! finalData.write(to: outputURL)

print("✅ 成功生成现代全面屏 MacBook 带壳渲染图：\(outputURL.path)")
print("   尺寸：\(croppedRep.pixelsWide) × \(croppedRep.pixelsHigh)")
print("   顶部窄边框：\(bezelSize)px, 刘海尺寸：\(notchW)×\(notchH)px")
