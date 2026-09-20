//
//  boringNotchApp.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import Sparkle
import SwiftUI
import WebKit

@main
struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    @Environment(\.openWindow) var openWindow

    let updaterController: SPUStandardUpdaterController

    init() {
        // startingUpdater: false —— 公开源码构建无 Sparkle 更新源（未配置 SUFeedURL），
        // 不自动检查更新；是否提供更新入口由最终维护者自行决定。
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

        // Initialize the settings window controller with the updater controller
        SettingsWindowController.shared.setUpdaterController(updaterController)
    }

    var body: some Scene {
        MenuBarExtra("BoringNotch", systemImage: "sparkle", isInserted: $showMenuBarIcon) {
            Button("Settings") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            if Defaults[.petEnabled] {
                Divider()
                if PetManager.shared.lifeState == .atHome {
                    Button("Let pet out") {
                        PetManager.shared.leaveHome()
                    }
                } else {
                    Button("Send pet home") {
                        PetManager.shared.goHome()
                    }
                }
            }
            Divider()
            Button("Restart DeskPet") {
                ApplicationRelauncher.restart()
            }
            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var windows: [String: NSWindow] = [:] // UUID -> NSWindow
    var viewModels: [String: BoringViewModel] = [:] // UUID -> BoringViewModel
    var window: NSWindow?
    let vm: BoringViewModel = .init()
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    var quickShareService = QuickShareService.shared
    var whatsNewWindow: NSWindow?
    var timer: Timer?
    var closeNotchTask: Task<Void, Never>?
    private var previousScreens: [NSScreen]?
    private var onboardingWindowController: NSWindowController?
    private var screenLockedObserver: Any?
    private var screenUnlockedObserver: Any?
    private var isScreenLocked: Bool = false
    private var windowScreenDidChangeObserver: Any?
    private var dragDetectors: [String: DragDetector] = [:] // UUID -> DragDetector

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Boring Notch is a menu-bar/agent app, so opening it again should also
    /// surface the desktop pet. If the pet was sleeping in its Home, Wake it
    /// back to Free instead of leaving the user with only the notch panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Defaults[.petEnabled] {
            PetWindowController.shared.show()
            if PetManager.shared.lifeState == .atHome {
                PetManager.shared.leaveHome()
            }
        }
        if Defaults[.bongoEnabled] {
            BongoWindowController.shared.show()
        }
        return true
    }

    /// Explicitly tear down the pet panel as part of the Boring Notch
    /// termination sequence. applicationWillTerminate still performs the final
    /// cleanup for termination paths that do not consult this delegate method.
    /// Bongo Companion is torn down here too: it is an in-app module, not a
    /// separate process, so it must share the Boring Notch exit lifecycle.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        PetWindowController.shared.hide()
        BongoWindowController.shared.hide()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        MusicManager.shared.destroy()
        cleanupDragDetectors()
        cleanupWindows()
        PetWindowController.shared.hide()
        BongoWindowController.shared.hide()
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()
    }

    @MainActor
    func onScreenLocked(_ notification: Notification) {
        isScreenLocked = true
        if !Defaults[.showOnLockScreen] {
            cleanupWindows()
        } else {
            enableSkyLightOnAllWindows()
        }
    }

    @MainActor
    func onScreenUnlocked(_ notification: Notification) {
        isScreenLocked = false
        if !Defaults[.showOnLockScreen] {
            adjustWindowPosition(changeAlpha: true)
        } else {
            disableSkyLightOnAllWindows()
        }
    }
    
    @MainActor
    private func enableSkyLightOnAllWindows() {
        if Defaults[.showOnAllDisplays] {
            windows.values.forEach { window in
                if let skyWindow = window as? BoringNotchSkyLightWindow {
                    skyWindow.enableSkyLight()
                }
            }
        } else {
            if let skyWindow = window as? BoringNotchSkyLightWindow {
                skyWindow.enableSkyLight()
            }
        }
    }
    
    @MainActor
    private func disableSkyLightOnAllWindows() {
        // Delay disabling SkyLight to avoid flicker during unlock transition
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await MainActor.run {
                if Defaults[.showOnAllDisplays] {
                    self.windows.values.forEach { window in
                        if let skyWindow = window as? BoringNotchSkyLightWindow {
                            skyWindow.disableSkyLight()
                        }
                    }
                } else {
                    if let skyWindow = self.window as? BoringNotchSkyLightWindow {
                        skyWindow.disableSkyLight()
                    }
                }
            }
        }
    }

    private func cleanupWindows(shouldInvert: Bool = false) {
        let shouldCleanupMulti = shouldInvert ? !Defaults[.showOnAllDisplays] : Defaults[.showOnAllDisplays]
        
        if shouldCleanupMulti {
            windows.values.forEach { window in
                window.close()
                NotchSpaceManager.shared.notchSpace.windows.remove(window)
            }
            windows.removeAll()
            viewModels.removeAll()
        } else if let window = window {
            window.close()
            NotchSpaceManager.shared.notchSpace.windows.remove(window)
            if let obs = windowScreenDidChangeObserver {
                NotificationCenter.default.removeObserver(obs)
                windowScreenDidChangeObserver = nil
            }
            self.window = nil
        }
    }

    private func cleanupDragDetectors() {
        dragDetectors.values.forEach { detector in
            detector.stopMonitoring()
        }
        dragDetectors.removeAll()
    }

    private func setupDragDetectors() {
        cleanupDragDetectors()

        guard Defaults[.expandedDragDetection] else { return }

        if Defaults[.showOnAllDisplays] {
            for screen in NSScreen.screens {
                setupDragDetectorForScreen(screen)
            }
        } else {
            let preferredScreen: NSScreen? = window?.screen
                ?? NSScreen.screen(withUUID: coordinator.selectedScreenUUID)
                ?? NSScreen.main

            if let screen = preferredScreen {
                setupDragDetectorForScreen(screen)
            }
        }
    }

    private func setupDragDetectorForScreen(_ screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        
        let screenFrame = screen.frame
        let notchHeight = openNotchSize.height
        let notchWidth = openNotchSize.width
        
        // Create notch region at the top-center of the screen where an open notch would occupy
        let notchRegion = CGRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
        
        let detector = DragDetector(notchRegion: notchRegion)
        
        detector.onDragEntersNotchRegion = { [weak self] in
            Task { @MainActor in
                self?.handleDragEntersNotchRegion(onScreen: screen)
            }
        }
        
        dragDetectors[uuid] = detector
        detector.startMonitoring()
    }

    private func handleDragEntersNotchRegion(onScreen screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        
        if Defaults[.showOnAllDisplays], let viewModel = viewModels[uuid] {
            viewModel.open()
            coordinator.currentView = .shelf
        } else if !Defaults[.showOnAllDisplays], let windowScreen = window?.screen, screen == windowScreen {
            vm.open()
            coordinator.currentView = .shelf
        }
    }

    private func createBoringNotchWindow(for screen: NSScreen, with viewModel: BoringViewModel) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
        
        let window = BoringNotchSkyLightWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
        
        // Enable SkyLight only when screen is locked
        if isScreenLocked {
            window.enableSkyLight()
        } else {
            window.disableSkyLight()
        }

        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(viewModel)
        )

        window.orderFrontRegardless()
        NotchSpaceManager.shared.notchSpace.windows.insert(window)

        // Observe when the window's screen changes so we can update drag detectors
        windowScreenDidChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setupDragDetectors()
                }
        }
        return window
    }

    @MainActor
    private func positionWindow(_ window: NSWindow, on screen: NSScreen, changeAlpha: Bool = false) {
        if changeAlpha {
            window.alphaValue = 0
        }

        let screenFrame = screen.frame
        window.setFrameOrigin(
            NSPoint(
                x: screenFrame.origin.x + (screenFrame.width / 2) - window.frame.width / 2,
                y: screenFrame.origin.y + screenFrame.height - window.frame.height
            ))
        window.alphaValue = 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        // ——— TEST MODE（诊断工具，仅 Debug 构建编译；依赖 #if DEBUG 下的
        // BongoWebViewBridge.readDiagnostics / PetManager.audioDebug* ）———
        #if DEBUG
        if CommandLine.arguments.contains("--test-bongo") {
            testBongoAndExit()
            return
        }

        // ——— TEST MODE: --test-pet-audio ———
        if CommandLine.arguments.contains("--test-pet-audio") {
            testPetAudioAndExit()
            return
        }
        #endif

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            forName: Notification.Name.selectedScreenChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition(changeAlpha: true)
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.notchHeightChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.automaticallySwitchDisplayChanged, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            Task { @MainActor in
                window.alphaValue = self.coordinator.selectedScreenUUID == self.coordinator.preferredScreenUUID ? 1 : 0
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.showOnAllDisplaysChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.cleanupWindows(shouldInvert: true)
                self.adjustWindowPosition(changeAlpha: true)
                self.setupDragDetectors()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.expandedDragDetectionChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setupDragDetectors()
            }
        }

        // 拖宠物进入刘海展开区 → 打开刘海并切到 Pet 页（对应 handleDragEntersNotchRegion，
        // 但目标视图是 .pet）。通知 object 可携带屏幕 UUID 用于多屏；省略时用主 vm。
        NotificationCenter.default.addObserver(
            forName: Notification.Name.openNotchToPet, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self = self else { return }
                if let uuid = notification.object as? String,
                   Defaults[.showOnAllDisplays], let viewModel = self.viewModels[uuid] {
                    viewModel.open()
                } else {
                    self.vm.open()
                }
                self.coordinator.currentView = .pet
            }
        }

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenLocked(notification)
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenUnlocked(notification)
                }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self = self else { return }
            if Defaults[.sneakPeekStyles] == .inline {
                let newStatus = !self.coordinator.expandingView.show
                self.coordinator.toggleExpandingView(status: newStatus, type: .music)
            } else {
                self.coordinator.toggleSneakPeek(
                    status: !self.coordinator.sneakPeek.show,
                    type: .music,
                    duration: 3.0
                )
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { [weak self] in
                guard let self = self else { return }

                let mouseLocation = NSEvent.mouseLocation

                var viewModel = self.vm

                if Defaults[.showOnAllDisplays] {
                    for screen in NSScreen.screens {
                        if screen.frame.contains(mouseLocation) {
                            if let uuid = screen.displayUUID, let screenViewModel = self.viewModels[uuid] {
                                viewModel = screenViewModel
                                break
                            }
                        }
                    }
                }

                self.closeNotchTask?.cancel()
                self.closeNotchTask = nil

                switch viewModel.notchState {
                case .closed:
                    await MainActor.run {
                        viewModel.open()
                    }

                    let task = Task { [weak viewModel] in
                        do {
                            try await Task.sleep(for: .seconds(3))
                            await MainActor.run {
                                viewModel?.close()
                            }
                        } catch { }
                    }
                    self.closeNotchTask = task
                case .open:
                    await MainActor.run {
                        viewModel.close()
                    }
                }
            }
        }

        if !Defaults[.showOnAllDisplays] {
            let viewModel = self.vm
            let window = createBoringNotchWindow(
                for: NSScreen.main ?? NSScreen.screens.first!, with: viewModel)
            self.window = window
            adjustWindowPosition(changeAlpha: true)
        } else {
            adjustWindowPosition(changeAlpha: true)
        }

        setupDragDetectors()

        if Defaults[.petEnabled] {
            PetWindowController.shared.show()
        }

        // Bongo Companion：同一进程内的独立模块，默认关闭，用户显式开启后才显示。
        var shouldShowBongo = Defaults[.bongoEnabled]
        #if DEBUG
        // 仅供 App 自有 WKWebView 的渲染自检使用，不进入 Release 路径。
        shouldShowBongo = shouldShowBongo
            || ProcessInfo.processInfo.environment["BONGO_FORCE_SHOW"] == "1"
        #endif
        if shouldShowBongo {
            BongoWindowController.shared.show()
        }

        if coordinator.firstLaunch {
            DispatchQueue.main.async {
                self.showOnboardingWindow()
            }
            playWelcomeSound()
        } else if MusicManager.shared.isNowPlayingDeprecated
            && Defaults[.mediaController] == .nowPlaying
        {
            DispatchQueue.main.async {
                self.showOnboardingWindow(step: .musicPermission)
            }
        }

        previousScreens = NSScreen.screens
    }

    func playWelcomeSound() {
        let audioPlayer = AudioPlayer()
        audioPlayer.play(fileName: "boring", fileExtension: "m4a")
    }

    func deviceHasNotch() -> Bool {
        if #available(macOS 12.0, *) {
            for screen in NSScreen.screens {
                if screen.safeAreaInsets.top > 0 {
                    return true
                }
            }
        }
        return false
    }

    @objc func screenConfigurationDidChange() {
        let currentScreens = NSScreen.screens

        let screensChanged =
            currentScreens.count != previousScreens?.count
            || Set(currentScreens.compactMap { $0.displayUUID })
                != Set(previousScreens?.compactMap { $0.displayUUID } ?? [])
            || Set(currentScreens.map { $0.frame }) != Set(previousScreens?.map { $0.frame } ?? [])

        previousScreens = currentScreens

        if screensChanged {
            DispatchQueue.main.async { [weak self] in
                self?.cleanupWindows()
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }
    }

    @objc func adjustWindowPosition(changeAlpha: Bool = false) {
        if Defaults[.showOnAllDisplays] {
            let currentScreenUUIDs = Set(NSScreen.screens.compactMap { $0.displayUUID })

            // Remove windows for screens that no longer exist
            for uuid in windows.keys where !currentScreenUUIDs.contains(uuid) {
                if let window = windows[uuid] {
                    window.close()
                    NotchSpaceManager.shared.notchSpace.windows.remove(window)
                    windows.removeValue(forKey: uuid)
                    viewModels.removeValue(forKey: uuid)
                }
            }

            // Create or update windows for all screens
            for screen in NSScreen.screens {
                guard let uuid = screen.displayUUID else { continue }
                
                if windows[uuid] == nil {
                    let viewModel = BoringViewModel(screenUUID: uuid)
                    let window = createBoringNotchWindow(for: screen, with: viewModel)

                    windows[uuid] = window
                    viewModels[uuid] = viewModel
                }

                if let window = windows[uuid], let viewModel = viewModels[uuid] {
                    positionWindow(window, on: screen, changeAlpha: changeAlpha)

                    if viewModel.notchState == .closed {
                        viewModel.close()
                    }
                }
            }
        } else {
            let selectedScreen: NSScreen

            if let preferredScreen = NSScreen.screen(withUUID: coordinator.preferredScreenUUID ?? "") {
                coordinator.selectedScreenUUID = coordinator.preferredScreenUUID ?? ""
                selectedScreen = preferredScreen
            } else if Defaults[.automaticallySwitchDisplay], let mainScreen = NSScreen.main,
                      let mainUUID = mainScreen.displayUUID {
                coordinator.selectedScreenUUID = mainUUID
                selectedScreen = mainScreen
            } else {
                if let window = window {
                    window.alphaValue = 0
                }
                return
            }

            vm.screenUUID = selectedScreen.displayUUID
            vm.notchSize = getClosedNotchSize(screenUUID: selectedScreen.displayUUID)

            if window == nil {
                window = createBoringNotchWindow(for: selectedScreen, with: vm)
            }

            if let window = window {
                positionWindow(window, on: selectedScreen, changeAlpha: changeAlpha)

                if vm.notchState == .closed {
                    vm.close()
                }
            }
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    @objc func showMenu() {
        statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(self)
    }

    private func showOnboardingWindow(step: OnboardingStep = .welcome) {
        if onboardingWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "Onboarding"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    step: step,
                    onFinish: {
                        window.orderOut(nil)
//                        NSApp.setActivationPolicy(.accessory)
                        window.close()
                        NSApp.deactivate()
                    },
                    onOpenSettings: {
                        window.close()
                        SettingsWindowController.shared.showWindow()
                    }
                ))
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")

            onboardingWindowController = NSWindowController(window: window)
        }

//        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
    }

    // 以下两个无头测试入口仅 Debug 构建编译（调用 #if DEBUG 限定成员）
    #if DEBUG
    /// --test-bongo: 无头诊断模式。显示 Bongo → 等待 ready → 截取 canvas → 写出 PNG → 退出。
    /// 输出路径 /tmp/bongo-snap.png，超时 30 秒。
    func testBongoAndExit() {
        let outPath = "/tmp/bongo-snap.png"
        let timeoutSec = 30.0
        print("[bongo-test] Starting test mode, output: \(outPath)")

        Defaults[.bongoEnabled] = true
        BongoWindowController.shared.show()

        let deadline = Date().addingTimeInterval(timeoutSec)
        func captureAndExit() {
            guard let wv = BongoWindowController.shared.panel?.contentView?.findWKWebView() else {
                print("[bongo-test] FAIL: WKWebView not found")
                NSApp.terminate(nil); return
            }
            wv.evaluateJavaScript("""
                (function(){
                    var c=document.getElementById('live2dCanvas');
                    if(!c) return 'no-canvas';
                    try { return c.toDataURL('image/png'); }
                    catch(e){ return 'error:'+e.message; }
                })()
            """) { result, error in
                if let err = error {
                    print("[bongo-test] JS error: \(err.localizedDescription)")
                    NSApp.terminate(nil); return
                }
                guard let dataURL = result as? String, dataURL.hasPrefix("data:image/png;base64,") else {
                    print("[bongo-test] Unexpected: \(String(describing: result))")
                    NSApp.terminate(nil); return
                }
                let b64 = String(dataURL.dropFirst("data:image/png;base64,".count))
                if let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                    try? data.write(to: URL(fileURLWithPath: outPath))
                    print("[bongo-test] SUCCESS: \(outPath) (\(data.count) bytes)")
                } else {
                    print("[bongo-test] FAIL: base64 decode")
                }
                NSApp.terminate(nil)
            }
        }

        func poll() {
            Task {
                let diag = await BongoWebViewBridge.shared.readDiagnostics()
                print("[bongo-test] poll: \(diag)")
                if diag != "no-webview" && diag != "not-ready" && !diag.hasPrefix("ERROR") {
                    await MainActor.run { captureAndExit() }
                } else if diag.hasPrefix("ERROR") {
                    print("[bongo-test] Page error: \(diag)")
                    NSApp.terminate(nil)
                } else if Date() > deadline {
                    print("[bongo-test] TIMEOUT — last: \(diag)")
                    await MainActor.run { captureAndExit() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { poll() }
    }

    /// --test-pet-audio: 无头音频诊断模式（临时 [DEBUG-petaudio] 工具）。
    /// 复现回窝全路径（双击回窝 远/近、拖拽投放、出窝再回窝），靠 PetManager
    /// 内的 [DEBUG-petaudio] 日志重建音效时间线，测重叠。跑完自动退出。
    func testPetAudioAndExit() {
        print("[pet-audio-test] mode started")
        let pet = PetManager.shared
        pet.audioDebugSampling = true

        // 宠物窗口 + 动画循环（PetWindow.show 内部会 PetManager.start()）
        PetWindowController.shared.show()

        // —— 场景调度：顺序执行，每步带标签（asyncAfter 回调必在主线程 → assumeIsolated）——
        func step(_ delay: Double, _ label: String, _ block: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    PetManager.audioDebugLog("STEP ▶︎ \(label)")
                    block()
                }
            }
        }

        // 主线程延迟执行（场景内小步）
        func onMain(_ delay: Double, _ block: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { block() }
            }
        }

        // 窝口目标点（与 goHome 同算法）
        func notchTarget() -> CGPoint? {
            let uuid = BoringViewCoordinator.shared.selectedScreenUUID
            let screen = uuid.isEmpty ? NSScreen.main : NSScreen.screen(withUUID: uuid)
            guard let screen else { return nil }
            let size = pet.windowSize
            let inset = screen.safeAreaInsets.top
            return CGPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - inset - size.height - 4
            )
        }

        // 把宠物放到窝口正下方 offset 点处（走回耗时 ≈ offset/70 秒）
        func placeNearNotch(offset: CGFloat) {
            guard let t = notchTarget() else { return }
            pet.syncWindowPosition(CGPoint(x: t.x, y: t.y - offset))
        }

        func placeFarFromNotch() {
            guard let screen = NSScreen.main else { return }
            let size = pet.windowSize
            pet.syncWindowPosition(CGPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.visibleFrame.minY + 40
            ))
        }

        // 双击回窝序列（与 PetContentView.handleClick 等价：两击按压反馈 + 0.3s 后 goHome）
        func doubleClickGoHome() {
            pet.pressFeedback()
            onMain(0.25) {
                pet.pressFeedback()
                onMain(0.3) { pet.goHome() }
            }
        }

        // t=1.0 环境报告
        step(1.0, "env-report") {
            let sounds = pet.skin?.sounds.map { "\($0.key.rawValue)=\($0.value.lastPathComponent)" }
                .sorted().joined(separator: ", ") ?? "nil"
            PetManager.audioDebugLog("ENV volume=\(Defaults[.petSoundVolume]) placeholder=\(Defaults[.petPlaceholderSound]) sounds=[\(sounds)]")
        }

        // 场景A：首次回窝 + 宠物就在窝边（首播 NSSound 初始化竞态窗口）
        step(2.0, "A double-click goHome, pet NEAR notch (first sound)") {
            placeNearNotch(offset: 60)
            onMain(0.5) { doubleClickGoHome() }
        }

        // 场景B：出窝 → 走远 → 双击回窝（长走回）
        step(14.0, "B leaveHome (fall)") { pet.leaveHome() }
        step(21.0, "B double-click goHome, pet FAR (long walk)") {
            placeFarFromNotch()
            onMain(0.5) { doubleClickGoHome() }
        }

        // 场景C：出窝 → 窝边 → 双击回窝（二次竞态）
        step(36.0, "C leaveHome (fall)") { pet.leaveHome() }
        step(43.0, "C double-click goHome, pet NEAR notch (again)") {
            placeNearNotch(offset: 60)
            onMain(0.5) { doubleClickGoHome() }
        }

        // 场景D：出窝 → 拖拽投放进窝（drag 语音 → snapHome）
        step(56.0, "D leaveHome (fall)") { pet.leaveHome() }
        step(63.0, "D drag → drop on notch (snapHome)") {
            pet.startDrag()
            if let t = notchTarget() {
                pet.evaluateNotchDropHover(at: CGPoint(x: t.x + 30, y: t.y + 30))
            }
            onMain(0.8) {
                pet.endDrag()
                pet.exitNotchDropHover()
            }
        }

        // 场景F：出窝后立刻拎起（fall 语音 play-call 后微秒级被 drag 取代，
        // 加载中的 fall 回调必须按代际丢弃 → 期望日志出现 play-DROPPED action=fall）
        step(68.0, "F leaveHome+startDrag back-to-back (guard test)") {
            pet.leaveHome()
            pet.startDrag()
            onMain(1.0) { pet.endDrag() }
        }

        // 结束：汇总退出
        step(78.0, "END terminate") {
            PetManager.audioDebugLog("END test complete — terminating")
            print("[pet-audio-test] complete")
            NSApp.terminate(nil)
        }
    }
    #endif
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")
}

extension CGRect: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(origin.x)
        hasher.combine(origin.y)
        hasher.combine(size.width)
        hasher.combine(size.height)
    }

    public static func == (lhs: CGRect, rhs: CGRect) -> Bool {
        return lhs.origin == rhs.origin && lhs.size == rhs.size
    }
}

extension NSView {
    func findWKWebView() -> WKWebView? {
        if let wv = self as? WKWebView { return wv }
        for sv in subviews {
            if let wv = sv.findWKWebView() { return wv }
        }
        return nil
    }
}
