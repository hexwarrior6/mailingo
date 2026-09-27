import Foundation
import XCTest
import CoreGraphics

@testable import TranslationCore

/// 图片压缩器的契约：压得进目标大小、结果仍可解码、无损旁路（小图原样）、
/// 垃圾输入返回 nil。
final class ImageCompressorTests: XCTestCase {

    /// 生成噪声图 —— 噪声的 JPEG 压缩率极差，天然就是大文件
    private func makeNoisyImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let buffer = context.data!.assumingMemoryBound(to: UInt8.self)
        for index in 0..<(width * height * 4) {
            buffer[index] = UInt8.random(in: 0...255)
        }
        return context.makeImage()!
    }

    func testCompressesToTargetSizeAndStaysDecodable() throws {
        let big = try XCTUnwrap(ImageCompressor.jpegData(from: makeNoisyImage(width: 2000, height: 1500), quality: 0.95))
        // 测试前提：噪声 JPEG 要超过目标值，否则测的是"小图直通"
        XCTAssertGreaterThan(big.count, 500_000, "噪声图应当压不大（实际 \(big.count) 字节）")

        let compressed = try XCTUnwrap(ImageCompressor.jpegData(fitting: big, maxBytes: 500_000))
        XCTAssertLessThanOrEqual(compressed.count, 500_000)
        // 压缩结果必须仍是可解码的图片
        XCTAssertNotNil(ImageCompressor.cgImage(from: compressed))
    }

    func testClampsLongEdgeToMaxDimension() throws {
        let big = try XCTUnwrap(ImageCompressor.jpegData(from: makeNoisyImage(width: 3000, height: 1500), quality: 0.9))
        let compressed = try XCTUnwrap(ImageCompressor.jpegData(fitting: big, maxBytes: 100_000, maxDimension: 800))
        let decoded = try XCTUnwrap(ImageCompressor.cgImage(from: compressed))
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 800, "长边必须被限制住")
    }

    func testGarbageInputReturnsNil() {
        XCTAssertNil(ImageCompressor.jpegData(fitting: Data("not an image".utf8), maxBytes: 100_000))
    }
}
