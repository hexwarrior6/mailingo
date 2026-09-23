#!/usr/bin/env swift
//
// 渲染冒烟检查：确认「邮件渲染器」真的能把 cid: 内嵌图显示出来。
//
// 为什么需要它：渲染是唯一**没法靠单元测试覆盖**的一环 —— 它要跑真的
// WKWebView、真的走一遍 WKURLSchemeHandler。没有这个脚本时，
// 改了渲染代码只能靠人眼看。
//
//   swift Scripts/render-check.swift [输出路径.png]
//
// 退出码 0 = 内嵌图成功渲染；非 0 = 根本没走到 scheme handler。
//
import AppKit
import WebKit
import Foundation

/// 一张 60x60、左红右蓝的图，用来肉眼确认"确实渲染出来了"。
/// 内联在这里，脚本自包含、不依赖外部文件。
let testPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAADwAAAA8CAIAAAC1nk4lAAAATElEQVR4nO3OQQ0AAAgEIONcHPvPMKbQFxsBqEmOpOdISUtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t/pBfJP5UACBKu3QAAAABJRU5ErkJggg=="

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/mailingo-render-check.png"
let imageData = Data(base64Encoded: testPNGBase64)!

final class CIDHandler: NSObject, WKURLSchemeHandler {
    private(set) var hits = 0
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        hits += 1
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let response = URLResponse(url: url, mimeType: "image/png",
                                   expectedContentLength: imageData.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(imageData)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let handler = CIDHandler()
let configuration = WKWebViewConfiguration()
configuration.defaultWebpagePreferences.allowsContentJavaScript = false
configuration.setURLSchemeHandler(handler, forURLScheme: "mailingo-cid")

let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 140), configuration: configuration)
let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = webView
window.orderFrontRegardless()

webView.loadHTMLString("""
<html><body style="font:14px -apple-system;padding:8px">
<p>cid: 内嵌图应渲染出<b>左红右蓝</b>的方块</p>
<img src="mailingo-cid://test%40x" width="60" height="60">
</body></html>
""", baseURL: nil)

DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
    webView.takeSnapshot(with: nil) { image, error in
        defer { NSApp.terminate(nil) }

        guard handler.hits > 0 else {
            print("❌ WKURLSchemeHandler 从未被调用 —— cid: 改写或 scheme 注册有问题")
            exit(1)
        }
        guard let image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("❌ 截图失败：\(error?.localizedDescription ?? "unknown")")
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: outputPath))
        print("✅ scheme handler 命中 \(handler.hits) 次，截图已写入 \(outputPath)")
        print("   （打开看看：应当是一个左红右蓝的方块）")
        exit(0)
    }
}
app.run()
