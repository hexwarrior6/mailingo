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

// 目标画布尺寸 (PommePlate 官方标准 16-inch MacBook Pro 规格)
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
let shadowPath = NSBezierPath(ovalIn: CGRect(x: 200, y: 20, width: totalW - 400, height: 120))
NSColor(white: 0.0, alpha: 0.18).setFill()
shadowPath.fill()

// 2. 绘制屏幕上盖外壳 (Lid / Display Assembly)
// 原点在左下角 (Cocoa 坐标系)
// 在 SVG 坐标系里 (从上往下)：Top=0, Height=2236
// 上盖位于 X: 365, W: 3181. 屏幕区域在 SVG: X=419, Y=95, W=3072, H=1920
let lidX: CGFloat = 365
let lidW: CGFloat = 3181
let lidH: CGFloat = 2072
let lidY: CGFloat = totalH - lidH - 60 // 离顶部约 60px

// 上盖外框 (深空灰铝合金)
let lidOuterRect = CGRect(x: lidX, y: lidY, width: lidW, height: lidH)
let lidOuterPath = NSBezierPath(roundedRect: lidOuterRect, xRadius: 46, yRadius: 46)
NSColor(red: 0.58, green: 0.59, blue: 0.61, alpha: 1.0).setFill() // 外壳铝合金银灰
lidOuterPath.fill()

// 内侧中框
let lidMidRect = lidOuterRect.insetBy(dx: 10, dy: 10)
let lidMidPath = NSBezierPath(roundedRect: lidMidRect, xRadius: 40, yRadius: 40)
NSColor(red: 0.18, green: 0.19, blue: 0.20, alpha: 1.0).setFill()
lidMidPath.fill()

// 屏幕黑色边框 (Bezel)
let bezelRect = lidOuterRect.insetBy(dx: 22, dy: 22)
let bezelPath = NSBezierPath(roundedRect: bezelRect, xRadius: 32, yRadius: 32)
NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1.0).setFill()
bezelPath.fill()

// 3. 屏幕显示区域 (Active Display Area)
let screenW: CGFloat = 3072
let screenH: CGFloat = 1920
let screenX: CGFloat = lidX + (lidW - screenW) / 2
let screenY: CGFloat = lidY + 80

let screenRect = CGRect(x: screenX, y: screenY, width: screenW, height: screenH)
let screenClipPath = NSBezierPath(roundedRect: screenRect, xRadius: 10, yRadius: 10)

cg.saveGState()
screenClipPath.addClip()

// 黑色背景底色
NSColor.black.setFill()
screenRect.fill()

// 绘制截图内容 (顶部完全对齐，严禁裁切顶上内容，多余高度在底部自然裁切)
let srcSize = screenshotImage.size
let scaleX = screenW / srcSize.width
let scaleY = screenH / srcSize.height
let fillScale = max(scaleX, scaleY)
let drawW = srcSize.width * fillScale
let drawH = srcSize.height * fillScale
let drawX = screenX + (screenW - drawW) / 2
// 在 Cocoa 坐标系中 (原点在左下角)：
// 屏幕顶部为 screenY + screenH
// 图像绘制区域的顶部为 drawY + drawH
// 要保证顶部完全对齐、绝不裁切顶上内容：drawY + drawH = screenY + screenH => drawY = screenY + screenH - drawH
let drawY = screenY + screenH - drawH

screenshotImage.draw(in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH), from: .zero, operation: .sourceOver, fraction: 1.0)

// 屏幕轻微玻璃内阴影 (提升立体真实感)
let innerShadow = NSBezierPath(rect: screenRect)
NSColor(white: 0.0, alpha: 0.06).setStroke()
innerShadow.lineWidth = 2.0
innerShadow.stroke()

cg.restoreGState()

// 4. 摄像头区域 (FaceTime HD Camera)
let cameraY = lidY + lidH - 42
let cameraRect = CGRect(x: totalW / 2 - 8, y: cameraY - 8, width: 16, height: 16)
let cameraPath = NSBezierPath(ovalIn: cameraRect)
NSColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1.0).setFill()
cameraPath.fill()
// 镜头微弱反光
let lensPath = NSBezierPath(ovalIn: CGRect(x: totalW / 2 - 3, y: cameraY - 3, width: 6, height: 6))
NSColor(red: 0.15, green: 0.25, blue: 0.40, alpha: 0.8).setFill()
lensPath.fill()

// 5. 下方机身底座 (Base / Chin)
let baseY: CGFloat = lidY - 44
let baseRect = CGRect(x: 0, y: baseY, width: totalW, height: 88)

// 底座梯形与铝合金渐变
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
let notchW: CGFloat = 380
let notchH: CGFloat = 24
let notchRect = CGRect(x: (totalW - notchW) / 2, y: baseY + 88 - notchH, width: notchW, height: notchH)
let notchPath = NSBezierPath(roundedRect: notchRect, xRadius: 10, yRadius: 10)
NSColor(red: 0.38, green: 0.39, blue: 0.41, alpha: 1.0).setFill()
notchPath.fill()

NSGraphicsContext.restoreGraphicsState()

// 裁剪周围多余透明区域 (保留适当呼吸留白)
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

print("✅ 成功生成 MacBook 带壳渲染图：\(outputURL.path)")
print("   新尺寸：\(croppedRep.pixelsWide) × \(croppedRep.pixelsHigh)")
