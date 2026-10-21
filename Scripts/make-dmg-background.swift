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

// 1. 基础优雅中性浅灰白渐变（自然契合 macOS Finder）
let bgGradient = NSGradient(
    starting: NSColor(red: 0.985, green: 0.988, blue: 0.995, alpha: 1.0),
    ending: NSColor(red: 0.945, green: 0.952, blue: 0.965, alpha: 1.0)
)!
bgGradient.draw(in: bounds, angle: -90)

// 2. 边缘 1px 极微弱内描边（增加通透精致感）
NSColor(white: 0.0, alpha: 0.05).setStroke()
let borderPath = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
borderPath.lineWidth = 1.0
borderPath.stroke()

// 3. 左右留白区（App 中心 180, 210；Applications 中心 480, 210）
let midX: CGFloat = 330
let midY: CGFloat = 210

// 4. 中间现代圆润向右指示箭头
let arrowPath = NSBezierPath()
let arrowLen: CGFloat = 76
let startX = midX - arrowLen / 2
let endX = midX + arrowLen / 2

arrowPath.move(to: CGPoint(x: startX, y: midY + 4))
arrowPath.line(to: CGPoint(x: endX, y: midY + 4))
arrowPath.line(to: CGPoint(x: endX - 12, y: midY + 14))
arrowPath.move(to: CGPoint(x: endX, y: midY + 4))
arrowPath.line(to: CGPoint(x: endX - 12, y: midY - 6))

NSColor(white: 0.42, alpha: 0.85).setStroke()
arrowPath.lineWidth = 2.5
arrowPath.lineCapStyle = .round
arrowPath.lineJoinStyle = .round
arrowPath.stroke()

// 5. 提示说明小字（居中在箭头下方）
let text = "拖移至 Applications 即可安装" as NSString
let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(white: 0.35, alpha: 0.85)
]
let textSize = text.size(withAttributes: attrs)
text.draw(at: CGPoint(x: midX - textSize.width / 2, y: midY - 26), withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()

// 导出 PNG
let outputURL = URL(fileURLWithPath: "Design/dmg-background@2x.png")
let pngData = rep.representation(using: .png, properties: [:])!
try! pngData.write(to: outputURL)
print("✓ 已生成背景图: \(outputURL.path)")
