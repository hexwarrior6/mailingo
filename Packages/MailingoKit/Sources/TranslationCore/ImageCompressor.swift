import Foundation
import CoreGraphics
import ImageIO

/// 把图片压到厂商接口的大小限制以内。
///
/// 策略：先限制最长边（OCR/贴合对 2000~4000px 足够），再按 JPEG 质量逐级压缩，
/// 仍超标就继续降分辨率，直到达标或压到底线。
///
/// 有损 JPEG 会丢透明通道 —— 透明区域垫白底。翻译场景可接受：
/// 厂商返回的贴合图本身就是不透明的 JPG/PNG。
public enum ImageCompressor {

    /// 压缩到 `maxBytes` 以内。压不到底线时返回 nil，由调用方给出明确报错。
    public static func jpegData(
        fitting data: Data,
        maxBytes: Int,
        maxDimension: Int = 4096
    ) -> Data? {
        guard let source = cgImage(from: data) else { return nil }

        let longEdge = max(source.width, source.height)
        var scale = min(1.0, CGFloat(maxDimension) / CGFloat(max(longEdge, 1)))

        while scale > 0.12 {
            let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
            let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
            if let resized = resized(source, width: width, height: height) {
                // 同一分辨率下按质量逐级压
                for quality in [0.8, 0.65, 0.5, 0.35, 0.25] {
                    if let jpeg = jpegData(from: resized, quality: quality), jpeg.count <= maxBytes {
                        return jpeg
                    }
                }
            }
            scale *= 0.75
        }
        return nil
    }

    /// 任意图片数据 → CGImage（PNG/JPEG/GIF 首帧等都走 ImageIO 统一解码）。
    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 等比重绘（白底、去透明、高插值）。
    private static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        // JPEG 无透明通道 —— 垫白底，避免透明区域变黑
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.jpeg" as CFString, 1, nil
        ) else { return nil }

        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
