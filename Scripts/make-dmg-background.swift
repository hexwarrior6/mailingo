#!/usr/bin/env swift
import AppKit
import Foundation

let width: CGFloat = 660
let height: CGFloat = 400
let scale: CGFloat = 2.0 // Retina @2x
let canvasSize = CGSize(width: width * scale, height: height * scale)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
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
cg.scaleBy(x: scale, y: scale)

let bounds = CGRect(x: 0, y: 0, width: width, height: height)

// 1. 纯净极简中性浅灰底色（与 macOS 浅色 Finder 完全融为一体）
let bgGradient = NSGradient(
    starting: NSColor(red: 0.985, green: 0.988, blue: 0.995, alpha: 1.0),
    ending: NSColor(red: 0.945, green: 0.952, blue: 0.965, alpha: 1.0)
)!
bgGradient.draw(in: bounds, angle: -90)

// 2. 边缘 1px 极微弱内描边
NSColor(white: 0.0, alpha: 0.04).setStroke()
let borderPath = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
borderPath.lineWidth = 1.0
borderPath.stroke()

// 3. 绘制简洁、粗粗的「>」指示箭头（Lungo 经典风格）
// 图标中心在 X: 180 与 480，正中为 X: 330
// appdmg 内容区高度 400，从上往下 Y: 170 相当于从下往上 Y: 230
let midX: CGFloat = 330
let midY: CGFloat = 230

let arrowPath = NSBezierPath()
let halfH: CGFloat = 30  // 箭头垂直跨度
let spanW: CGFloat = 26  // 箭头水平跨度

// 经典的粗圆角向右大于号 >
arrowPath.move(to: CGPoint(x: midX - spanW / 2, y: midY + halfH))
arrowPath.line(to: CGPoint(x: midX + spanW / 2, y: midY))
arrowPath.line(to: CGPoint(x: midX - spanW / 2, y: midY - halfH))

// 饱满粗细 + 圆角
arrowPath.lineWidth = 8.5
arrowPath.lineCapStyle = .round
arrowPath.lineJoinStyle = .round

// 通透中性灰（质感高级且不突兀）
NSColor(white: 0.20, alpha: 0.25).setStroke()
arrowPath.stroke()

NSGraphicsContext.restoreGraphicsState()

// 导出 2x 高清图与 1x 标清图
let output2x = URL(fileURLWithPath: "Design/dmg-background@2x.png")
let pngData = rep.representation(using: .png, properties: [:])!
try! pngData.write(to: output2x)
print("✓ 已生成高清背景图: \(output2x.path)")

// 生成 1x 图
let rep1x = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width),
    pixelsHigh: Int(height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let ctx1x = NSGraphicsContext(bitmapImageRep: rep1x)!
NSGraphicsContext.current = ctx1x
let img = NSImage(data: pngData)!
img.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
NSGraphicsContext.restoreGraphicsState()

let output1x = URL(fileURLWithPath: "Design/dmg-background.png")
let data1x = rep1x.representation(using: .png, properties: [:])!
try! data1x.write(to: output1x)
print("✓ 已生成标清背景图: \(output1x.path)")
