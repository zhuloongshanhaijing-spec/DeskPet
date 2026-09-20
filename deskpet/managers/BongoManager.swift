//
//  BongoManager.swift
//  boringNotch
//
//  Bongo Companion：键盘/鼠标节奏反馈模块。
//
//  与 Whale Girl（PetManager）完全独立：独立窗口、独立状态、独立设置、独立退出路径，
//  不共享外观状态机。它只观察本机真实输入来驱动动画：
//    - 不记录、不保存、不上传输入内容；
//    - 不读取输入文本，不读剪贴板；
//    - 不向任何应用注入/模拟事件。
//
//  视觉：App 内嵌 WKWebView（同进程、同生命周期）渲染 upstream/BongoCat 的原猫
//  Live2D 模型；技术边界见工作台 `BONGO_BASELINE.md`。
//

import AppKit
import Combine
import CoreGraphics
import Defaults
import Foundation
import SwiftUI

/// 输入反馈的可用状态（用于界面明确降级，而不是静默失效）
enum BongoInputStatus: Equatable {
    /// 已授权且监听中
    case active
    /// 模块关闭
    case disabled
    /// 缺少 macOS 输入监控授权
    case notAuthorized

    var shortLabel: String {
        switch self {
        case .active: return "键盘/鼠标反馈：已开启"
        case .disabled: return "Bongo 已关闭"
        case .notAuthorized: return "键盘/鼠标反馈：未授权"
        }
    }
}

#if DEBUG
/// 输入链路诊断日志（/tmp/bongo-input.log）。
/// 只记录事件类型与键码数字，绝不记录字符内容（隐私边界见文件头注释）。
/// 用途：区分"键盘事件未送达（权限/TCC）"与"送达后链路断裂（我们的 bug）"。
enum BongoInputDiagLog {
    static let url = URL(fileURLWithPath: "/tmp/bongo-input.log")
    static func log(_ line: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(ts) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
#endif

@MainActor
final class BongoManager: ObservableObject {
    static let shared = BongoManager()

    // MARK: - 对外状态

    @Published private(set) var inputStatus: BongoInputStatus = .disabled
    /// 最近一次输入的高层分类（仅用于界面提示，不含任何按键内容）
    @Published private(set) var lastInputKind: String = ""

    /// 自身点击的按压缩放反馈（与 Whale Girl 同款"压下→回弹"，但状态独立）
    @Published private(set) var pressScaleX: CGFloat = 1
    @Published private(set) var pressScaleY: CGFloat = 1

    /// 模型是否已在 WebView 中就绪
    @Published private(set) var modelLoaded = false
    @Published private(set) var loadError: String?

    /// 可选 Live2D 资源未安装的固定错误标识（deskpet/BongoResources 不随公开仓库分发）
    static let optionalResourcesMissingError = "optional-live2d-resources-missing"

    /// 可选 Live2D 资源（deskpet/BongoResources/）是否未安装。
    /// 此时 Bongo 明确降级并在界面展示安装指引，而不是崩溃或假装可用。
    var optionalResourcesMissing: Bool {
        loadError == Self.optionalResourcesMissingError
    }

    // MARK: - 内部

    private var globalMonitor: Any?
    private var pressedHands: Set<Int> = []          // 0 = 左手, 1 = 右手
    private var pressedKeyToHand: [UInt16: Int] = [:]
    private var mouseLeftDown = false
    private var mouseRightDown = false
    /// 归一化鼠标位置（y 向下，与上游 Tauri PhysicalPosition 约定一致）；nil = 不发送追踪参数
    private var lastMouseX: Double?
    private var lastMouseY: Double?

    private enum InputControl: Hashable {
        case hand(Int)
        case mouseLeft
        case mouseRight
    }

    /// 只保存瞬时按压时间，不包含按键字符或文本内容。
    private var pressedAt: [InputControl: TimeInterval] = [:]
    private var releaseAt: [InputControl: TimeInterval] = [:]
    /// 自上次向 WebView 推送以来的脏标记（合并高频输入，避免 evaluateJavaScript 洪水）
    private var pendingFlush = false
    private var flushTimer: Timer?
    private var pressElapsed: Double?
    private var pressTimer: Timer?

    private let tick: Double = 1.0 / 60.0
    private static let pressDuration: Double = 0.24
    private static let pressDepthY: CGFloat = 0.10
    private static let pressWidenX: CGFloat = 0.05
    /// 按键释放后保持"按下"的最短时间，避免极快的敲击完全看不到反馈
    private static let minHoldSeconds: Double = 0.06

    private init() {}

    // MARK: - 权限

    /// 是否已获得 macOS 输入监控授权。未授权时全局键盘/鼠标事件不会送达。
    nonisolated static var hasInputMonitoringAccess: Bool {
        CGPreflightListenEventAccess()
    }

    /// 主动请求输入监控授权（只在用户显式点击时调用，遵循"默认关闭并说明原因"）。
    nonisolated static func requestInputMonitoringAccess() {
        CGRequestListenEventAccess()
    }

    nonisolated static func systemSettingsInputMonitoringURL() -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    // MARK: - 生命周期

    /// 根据设置与授权状态启动/停止全局监听。
    func syncWithSettings() {
        guard Defaults[.bongoEnabled] else {
            #if DEBUG
            BongoInputDiagLog.log("sync: bongoEnabled=false → disabled")
            #endif
            stopMonitoring()
            inputStatus = .disabled
            return
        }
        guard Self.hasInputMonitoringAccess else {
            #if DEBUG
            BongoInputDiagLog.log("sync: preflight DENIED（输入监控授权未生效/未授予）")
            #endif
            stopMonitoring()
            inputStatus = .notAuthorized
            Logger.log("Bongo: input monitoring not authorized — degraded mode", category: .warning)
            return
        }
        #if DEBUG
        BongoInputDiagLog.log("sync: preflight OK → startMonitoring")
        #endif
        startMonitoring()
    }

    private func startMonitoring() {
        guard globalMonitor == nil else {
            inputStatus = .active
            return
        }
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .keyUp,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
        ]
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            // NSEvent 文档：全局监视器的回调在主线程投递。
            MainActor.assumeIsolated {
                BongoManager.shared.handle(event: event)
            }
        }
        guard let monitor else {
            #if DEBUG
            BongoInputDiagLog.log("monitor: FAILED（addGlobalMonitorForEvents 返回 nil）")
            #endif
            inputStatus = .notAuthorized
            Logger.log("Bongo: global input monitor could not start", category: .warning)
            return
        }
        globalMonitor = monitor
        inputStatus = .active
        #if DEBUG
        BongoInputDiagLog.log("monitor: STARTED（keyDown/keyUp + 4 鼠标按键；如只收到鼠标事件 = 键盘被权限/安全输入阻断）")
        #endif
        Logger.log("Bongo: global input monitor started", category: .lifecycle)

        if flushTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushIfNeeded() }
            }
            RunLoop.main.add(timer, forMode: .common)
            flushTimer = timer
        }
    }

    private func stopMonitoring() {
        let wasMonitoring = globalMonitor != nil || flushTimer != nil
        #if DEBUG
        if wasMonitoring { BongoInputDiagLog.log("monitor: STOPPED") }
        #endif
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        flushTimer?.invalidate()
        flushTimer = nil
        resetInputState()
        if modelLoaded {
            applyPoseToWebView()
        }
        if wasMonitoring {
            Logger.log("Bongo: global input monitor stopped", category: .lifecycle)
        }
    }

    // MARK: - 输入处理（只做瞬时动画，不保留内容）

    private func handle(event: NSEvent) {
        #if DEBUG
        BongoInputDiagLog.log("EV: \(event.type == .keyDown ? "keyDown" : event.type == .keyUp ? "keyUp" : event.type == .leftMouseDown ? "leftMouseDown" : event.type == .leftMouseUp ? "leftMouseUp" : event.type == .rightMouseDown ? "rightMouseDown" : "rightMouseUp") code=\(event.keyCode)\(event.type == .keyDown && event.isARepeat ? " (repeat)" : "")")
        #endif
        switch event.type {
        case .keyDown:
            if event.isARepeat { return }
            let hand = Self.hand(forKeyCode: event.keyCode)
            let handWasAlreadyDown = pressedKeyToHand.values.contains(hand)
            pressedKeyToHand[event.keyCode] = hand
            if !handWasAlreadyDown {
                press(.hand(hand))
            }
            lastInputKind = "键盘"
        case .keyUp:
            if let hand = pressedKeyToHand.removeValue(forKey: event.keyCode),
               !pressedKeyToHand.values.contains(hand) {
                release(.hand(hand))
            }
        case .leftMouseDown:
            press(.mouseLeft)
            lastInputKind = "鼠标"
        case .leftMouseUp:
            release(.mouseLeft)
        case .rightMouseDown:
            press(.mouseRight)
            lastInputKind = "鼠标"
        case .rightMouseUp:
            release(.mouseRight)
        default:
            break
        }

        // 防止系统丢失 keyUp 后瞬时映射无限增长。
        if pressedKeyToHand.count > 32 {
            resetInputState()
            pendingFlush = true
        }
    }

    private func press(_ control: InputControl) {
        let now = ProcessInfo.processInfo.systemUptime
        if releaseAt.removeValue(forKey: control) != nil || pressedAt[control] == nil {
            pressedAt[control] = now
        }
        setPressed(control, true)
        pendingFlush = true
    }

    private func release(_ control: InputControl) {
        guard let downAt = pressedAt[control] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        releaseAt[control] = max(now, downAt + Self.minHoldSeconds)
        pendingFlush = true
    }

    private func applyDueReleases() {
        let now = ProcessInfo.processInfo.systemUptime
        let due = releaseAt.compactMap { entry in
            entry.value <= now ? entry.key : nil
        }
        for control in due {
            releaseAt.removeValue(forKey: control)
            pressedAt.removeValue(forKey: control)
            setPressed(control, false)
            pendingFlush = true
        }
    }

    private func setPressed(_ control: InputControl, _ pressed: Bool) {
        switch control {
        case let .hand(hand):
            if pressed { pressedHands.insert(hand) } else { pressedHands.remove(hand) }
        case .mouseLeft:
            mouseLeftDown = pressed
        case .mouseRight:
            mouseRightDown = pressed
        }
    }

    private func resetInputState() {
        pressedHands.removeAll()
        pressedKeyToHand.removeAll()
        mouseLeftDown = false
        mouseRightDown = false
        lastMouseX = nil
        lastMouseY = nil
        pressedAt.removeAll()
        releaseAt.removeAll()
        pendingFlush = false
    }

    /// 按物理键位把键盘左右两半映射到左右猫爪。
    /// 上游 BongoCat 依赖模型目录里的 left*/right* 命名，`standard` 模型没有该信息，
    /// 因此这里用键位近似（见 BONGO_BASELINE.md 第 6 节）。
    private static func hand(forKeyCode code: UInt16) -> Int {
        switch code {
        // 左半区：` 1-5, Tab, Q W E R T, A S D F G, Z X C V B, Esc, 修饰键
        case 50, 18, 19, 20, 21, 23, 48,
             12, 13, 14, 15, 17,
             0, 1, 2, 3, 5,
             6, 7, 8, 9, 11,
             53, 56, 59, 57, 55:
            return 0
        default:
            return 1
        }
    }

    private func flushIfNeeded() {
        applyDueReleases()
        // 鼠标位置追踪：NSEvent.mouseLocation 无需额外权限，30Hz 采样；
        // 只在移动超过阈值时置脏，鼠标静止时不推送。
        if inputStatus == .active {
            if let r = Self.mouseRatios() {
                if abs((lastMouseX ?? Double.infinity) - r.x) > 0.01
                    || abs((lastMouseY ?? Double.infinity) - r.y) > 0.01 {
                    lastMouseX = r.x
                    lastMouseY = r.y
                    pendingFlush = true
                }
            }
        } else if lastMouseX != nil {
            lastMouseX = nil
            lastMouseY = nil
        }
        guard pendingFlush else { return }
        pendingFlush = false
        applyPoseToWebView()
    }

    /// 鼠标在所在屏幕内的归一化位置（x,y ∈ [0,1]，y 向下，
    /// 与上游 BongoCat `useModel.handleMouseMove` 的 Tauri 坐标约定一致）。
    private static func mouseRatios() -> (x: Double, y: Double)? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              screen.frame.width > 0, screen.frame.height > 0 else { return nil }
        let f = screen.frame
        let x = Double((mouse.x - f.minX) / f.width)
        let y = Double(1 - (mouse.y - f.minY) / f.height)
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    /// 把当前按压状态推给 WebView。参数名与被复用的原猫模型一致。
    /// 右手键盘参数在无 CatParamRightHandDown 的模型上由 JS 端折叠进左手
    /// （见 index.html __bongoPose 与 BONGO_BASELINE.md §2.2/§6）。
    private func applyPoseToWebView() {
        let left = pressedHands.contains(0)
        let right = pressedHands.contains(1)
        var pose: [String: Double] = [
            "CatParamLeftHandDown": left ? 1 : 0,
            "CatParamRightHandDown": right ? 1 : 0,
            "ParamMouseLeftDown": mouseLeftDown ? 1 : 0,
            "ParamMouseRightDown": mouseRightDown ? 1 : 0,
        ]
        if let x = lastMouseX, let y = lastMouseY {
            pose["MouseRatioX"] = x
            pose["MouseRatioY"] = y
        }
        #if DEBUG
        BongoInputDiagLog.log("pose: L=\(left ? 1 : 0) R=\(right ? 1 : 0) mL=\(mouseLeftDown ? 1 : 0) mR=\(mouseRightDown ? 1 : 0) mouse=\(lastMouseX != nil ? "on" : "off")")
        #endif
        BongoWebViewBridge.shared.apply(pose: pose)
        // [P4] 键盘图层：按住的键码集合 → 页面端键位爪子贴图
        BongoWebViewBridge.shared.applyKeys(pressedKeyToHand.keys.map { Int($0) })
    }

    /// WebView 就绪后同步一次当前状态
    func webViewDidBecomeReady() {
        #if DEBUG
        BongoInputDiagLog.log("webview: READY（模型加载完成，桥接可用）")
        #endif
        modelLoaded = true
        loadError = nil
        applyPoseToWebView()
    }

    func webViewDidFail(_ message: String) {
        #if DEBUG
        BongoInputDiagLog.log("webview: FAIL \(message)")
        #endif
        modelLoaded = false
        loadError = message
        Logger.log("Bongo model load failed: \(message)", category: .warning)
    }

    // MARK: - 自身按压反馈（无需任何授权）

    /// 点击 Bongo 本体的解压反馈：短促"压下 → 回弹" + 可关闭占位音效。
    /// 连续点击合并/限频，不排队。
    func pressFeedback() {
        pressElapsed = 0
        playPlaceholderSound()
        if pressTimer == nil {
            let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advancePress() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pressTimer = timer
        }
    }

    private func advancePress() {
        guard let elapsed = pressElapsed else {
            pressTimer?.invalidate()
            pressTimer = nil
            pressScaleX = 1
            pressScaleY = 1
            return
        }
        let next = elapsed + tick
        if next >= Self.pressDuration {
            pressElapsed = nil
            pressScaleX = 1
            pressScaleY = 1
            return
        }
        pressElapsed = next
        let t = next / Self.pressDuration
        let downFraction = 0.34
        let amount = t < downFraction ? t / downFraction : 1 - (t - downFraction) / (1 - downFraction)
        pressScaleY = 1 - Self.pressDepthY * CGFloat(amount)
        pressScaleX = 1 + Self.pressWidenX * CGFloat(amount)
    }

    private var placeholderPlayer: NSSound?

    /// 复用与 Whale Girl 相同的可关闭系统占位音效策略（无授权音频可用）。
    private func playPlaceholderSound() {
        guard Defaults[.petPlaceholderSound] else { return }
        let paths = [
            "/System/Library/Sounds/Tink.aiff",
            "/System/Library/Sounds/Pop.aiff",
            "/System/Library/Sounds/Blow.aiff",
        ]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let sound = NSSound(contentsOfFile: path, byReference: true)
        else { return }
        placeholderPlayer?.stop()
        placeholderPlayer = sound
        sound.volume = Float(Defaults[.petSoundVolume])
        sound.play()
    }

    func shutdown() {
        stopMonitoring()
        pressTimer?.invalidate()
        pressTimer = nil
        pressElapsed = nil
        pressScaleX = 1
        pressScaleY = 1
        modelLoaded = false
        loadError = nil
        inputStatus = .disabled
        placeholderPlayer?.stop()
        placeholderPlayer = nil
    }
}
