//
//  BongoWebView.swift
//  boringNotch
//
//  Bongo Companion 的渲染视图：App 内嵌 WKWebView（同进程、同生命周期）加载
//  BongoResources/index.html，用 Live2D Cubism Core + 自写最小 WebGL 渲染器绘制原猫模型。
//
//  与原生端的唯一接口是固定参数名的 pose 推送，不传递任何输入内容。
//

import AppKit
import SwiftUI
import WebKit

/// 原生 → WebView 的桥。只做参数推送，不含任何用户输入内容。
@MainActor
final class BongoWebViewBridge {
    static let shared = BongoWebViewBridge()

    private weak var webView: WKWebView?
    private var isReady = false
    /// 最近一次 pose：WebView 尚未就绪时缓存，就绪后补发
    private var lastPose: [String: Double] = [:]

    private init() {}

    func attach(_ webView: WKWebView) {
        self.webView = webView
        isReady = false
    }

    func detach(_ webView: WKWebView) {
        if self.webView === webView {
            self.webView = nil
            isReady = false
        }
    }

    func markReady() {
        isReady = true
        if !lastPose.isEmpty { push(lastPose) }
    }

    func markNotReady() {
        isReady = false
    }

    func apply(pose: [String: Double]) {
        lastPose = pose
        guard isReady else { return }
        push(pose)
    }

    private func push(_ pose: [String: Double]) {
        guard let webView else { return }
        // 参数名与数值都来自本文件内的固定常量，注入风险可控。
        let body = pose
            .map { key, value in "\"\(key)\": \(String(format: "%.4f", value))" }
            .joined(separator: ", ")
        webView.evaluateJavaScript("window.__bongoPose && window.__bongoPose({\(body)});")
    }

    /// [P4] 键盘图层：转发当前按住的键码集合（macOS vk 码，逗号分隔字符串）。
    /// 页面端 keyboard-overlay.js 据此在各键位叠加官方素材的猫爪贴图。
    /// 与 apply(pose:) 同一投递时机（ready 之前静默丢弃，由
    /// applyPoseToWebView 在 ready 后重建重发）。
    func applyKeys(_ codes: [Int]) {
        guard isReady, let webView else { return }
        let joined = codes.map(String.init).joined(separator: ",")
        webView.evaluateJavaScript(
            "window.__bongoPose && window.__bongoPose({\"PressedKeys\": \"\(joined)\"});")
    }

    #if DEBUG
    /// 供诊断使用：读取页面内部状态（drawable/parameter 数量、错误信息）。
    func readDiagnostics() async -> String {
        guard let webView else { return "no-webview" }
        do {
            let value = try await webView.evaluateJavaScript(
                "(function(){" +
                " if (window.__bongoError) return 'ERROR: ' + window.__bongoError;" +
                " if (!window.__bongoReady) return 'not-ready';" +
                " var diag = document.getElementById('diagnostics');" +
                " var info = diag ? diag.textContent || '' : '';" +
                " var debug = window.__bongoDebug || '';" +
                " return 'DEBUG:' + debug + ';;INFO:' + info;" +
                "})()"
            )
            return String(describing: value ?? "nil")
        } catch {
            return "diagnostics-error: \(error.localizedDescription)"
        }
    }
    #endif
}

/// Bongo 资源目录定位：可选 Live2D 资源不随公开仓库/应用包分发（授权受限，
/// 见 docs/OPTIONAL_LIVE2D_SETUP.md）。用户自行取得资源后，用
/// BONGO_RESOURCES_DIR 指向本地已安装目录（tools/setup_optional_live2d.sh 安装）。
enum BongoResources {
    static var directoryURL: URL? {
        if let override = ProcessInfo.processInfo.environment["BONGO_RESOURCES_DIR"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path) {
                return url
            }
        }
        guard let url = Bundle.main.url(forResource: "BongoResources", withExtension: nil) else {
            return nil
        }
        return url
    }

    static var startURL: URL? {
        URL(string: "\(BongoSchemeHandler.scheme)://local/index.html")
    }
}

/// 通过自定义 scheme 提供 BongoResources。
/// 不用 file://：WKWebView 会拦截 file:// 下的 fetch/XHR，模型与核心 JS 都读不到。
/// 自定义 scheme 是公开 API，且天然把资源访问限制在资源目录内。
final class BongoSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "bongo"
    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "js": return "text/javascript"
        case "json": return "application/json"
        case "png": return "image/png"
        case "css": return "text/css"
        default: return "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == Self.scheme,
              url.host == "local"
        else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        var relative = url.path
        if relative.isEmpty || relative == "/" { relative = "/index.html" }
        // 目录穿越防护：解析后必须等于资源根目录或位于 root/ 之下。
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPrefix) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        do {
            let data = try Data(contentsOf: candidate)
            // 普通 URLResponse 的 status 为 0，会让 fetch() 的 response.ok 为 false。
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": Self.mimeType(for: candidate.pathExtension),
                    "Content-Length": String(data.count),
                ]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            let response = HTTPURLResponse(
                url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data())
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/// WKWebView 包装。透明背景、无滚动、无交互（点击/拖拽由 SwiftUI 层处理）。
struct BongoWebView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "bongo")

        // WKWebView 在 init 时复制 configuration，scheme handler 必须先注册。
        guard let root = BongoResources.directoryURL, let startURL = BongoResources.startURL else {
            let webView = WKWebView(frame: .zero, configuration: config)
            configure(webView, coordinator: context.coordinator)
            BongoWebViewBridge.shared.attach(webView)
            BongoManager.shared.webViewDidFail(BongoManager.optionalResourcesMissingError)
            return webView
        }
        config.setURLSchemeHandler(BongoSchemeHandler(root: root), forURLScheme: BongoSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: config)
        configure(webView, coordinator: context.coordinator)
        BongoWebViewBridge.shared.attach(webView)
        webView.load(URLRequest(url: startURL))
        return webView
    }

    private func configure(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "bongo")
        BongoWebViewBridge.shared.detach(nsView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "bongo", let body = message.body as? [String: Any] else { return }
            let kind = body["kind"] as? String ?? ""
            MainActor.assumeIsolated {
                switch kind {
                case "ready":
                    Logger.log("Bongo: WebView model ready", category: .lifecycle)
                    BongoManager.shared.webViewDidBecomeReady()
                    BongoWebViewBridge.shared.markReady()
                    #if DEBUG
                    BongoDiagnostics.scheduleSnapshotIfRequested()
                    #endif
                case "error":
                    BongoManager.shared.webViewDidFail(body["message"] as? String ?? "unknown")
                    BongoWebViewBridge.shared.markNotReady()
                default:
                    break
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  url.scheme == BongoSchemeHandler.scheme,
                  url.host == "local"
            else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Logger.log("Bongo: WebView didFinish", category: .debug)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                BongoManager.shared.webViewDidFail(error.localizedDescription)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                BongoManager.shared.webViewDidFail(error.localizedDescription)
            }
        }
    }
}

#if DEBUG
/// 渲染自检钩子：仅当设置 BONGO_SNAPSHOT_PATH 时激活，用于在无法交互的环境里
/// 把 WebView 的实际渲染结果落盘供人工核对。正常运行路径完全不触发。
enum BongoDiagnostics {
    @MainActor
    static func scheduleSnapshotIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["BONGO_SNAPSHOT_PATH"], !path.isEmpty else { return }
        let delay = Double(env["BONGO_SNAPSHOT_DELAY"] ?? "") ?? 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in
                let diagnostics = await BongoWebViewBridge.shared.readDiagnostics()
                NSLog("[BongoDiag] %@", diagnostics)
                BongoDiagnostics.writeSnapshot(to: path) {
                    if env["BONGO_SNAPSHOT_EXIT"] == "1" {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
    }

    @MainActor
    private static func writeSnapshot(to path: String, completion: @escaping () -> Void) {
        guard let window = BongoWindowController.shared.panel,
              let view = window.contentView else {
            NSLog("[BongoDiag] no window to snapshot")
            completion()
            return
        }
        // 抓实际 WebView（含透明度），确认猫是否真的绘制。
        if let webView = findWebView(in: view) {
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            webView.takeSnapshot(with: config) { image, error in
                MainActor.assumeIsolated {
                    defer { completion() }
                    guard let image,
                          let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:])
                    else {
                        NSLog("[BongoDiag] snapshot failed: %@", error?.localizedDescription ?? "no image")
                        return
                    }
                    do {
                        try png.write(to: URL(fileURLWithPath: path))
                        NSLog("[BongoDiag] snapshot written to %@", path)
                    } catch {
                        NSLog("[BongoDiag] snapshot write failed: %@", error.localizedDescription)
                    }
                }
            }
        } else {
            NSLog("[BongoDiag] no webview found")
            completion()
        }
    }

    private static func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = findWebView(in: subview) { return found }
        }
        return nil
    }
}
#endif
