//
//  BongoWindow.swift
//  boringNotch
//
//  Bongo Companion 面板：无边框非激活面板，可拖动，默认停在右下角安全区。
//  与 PetWindowController 完全独立：自己的默认位置、自己的开关、自己的生命周期。
//

import AppKit
import Defaults
import SwiftUI

@MainActor
final class BongoWindowController {
    static let shared = BongoWindowController()

    private(set) var panel: NSPanel?

    var currentOrigin: CGPoint? {
        panel?.frame.origin
    }

    /// 面板尺寸 = 基础尺寸 × 用户缩放
    var panelSize: CGSize {
        let base = CGSize(width: 260, height: 170)
        let scale = Defaults[.bongoScale]
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    func show() {
        guard panel == nil else { return }

        let size = panelSize
        let panel = NSPanel(
            contentRect: NSRect(origin: defaultOrigin(for: size), size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // 低于刘海（.mainMenu+3）与 Whale Girl（.mainMenu+1），高于普通窗口
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: BongoContentView())
        self.panel = panel
        panel.orderFrontRegardless()

        BongoManager.shared.syncWithSettings()
    }

    func hide() {
        BongoManager.shared.shutdown()
        panel?.orderOut(nil)
        panel = nil
    }

    func moveWindow(to origin: CGPoint) {
        guard let panel else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? panel.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? panel.frame
        panel.setFrameOrigin(constrainedOrigin(origin, size: panel.frame.size, visibleFrame: visible))
    }

    func isBongoWindow(_ candidate: NSWindow?) -> Bool {
        guard let panel, let candidate else { return false }
        return candidate === panel
    }

    /// 拖动结束后记住位置（用户偏好，不自行改动）
    func persistOrigin() {
        guard let origin = panel?.frame.origin else { return }
        Defaults[.bongoOriginX] = Double(origin.x)
        Defaults[.bongoOriginY] = Double(origin.y)
    }

    /// 缩放变化 → 调整面板尺寸，锚定右下角，避免面板漂出屏幕。
    func applyScale() {
        guard let panel else { return }
        let size = panelSize
        var frame = panel.frame
        frame.origin = CGPoint(x: frame.maxX - size.width, y: frame.minY)
        frame.size = size
        let visible = panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? frame
        frame.origin = constrainedOrigin(frame.origin, size: size, visibleFrame: visible)
        panel.setFrame(frame, display: true)
        persistOrigin()
    }

    /// 恢复默认位置。关闭状态也要先清除持久化坐标，下次开启才会回到默认位置。
    func resetPosition() {
        Defaults[.bongoOriginX] = 0
        Defaults[.bongoOriginY] = 0
        guard let panel else { return }
        panel.setFrameOrigin(defaultOrigin(for: panel.frame.size))
    }

    /// 默认位置：主屏 visibleFrame 右下角留 24pt 边距（确认单允许的安全默认值）。
    /// 若用户拖动过则使用记住的位置，并做一次可见性校验。
    private func defaultOrigin(for size: CGSize) -> CGPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 24
        let fallback = CGPoint(
            x: visible.maxX - size.width - margin,
            y: visible.minY + margin
        )
        let savedX = Defaults[.bongoOriginX]
        let savedY = Defaults[.bongoOriginY]
        guard savedX != 0 || savedY != 0 else { return fallback }
        let saved = CGPoint(x: savedX, y: savedY)
        let frame = CGRect(origin: saved, size: size)
        guard let savedScreen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else {
            return fallback
        }
        return constrainedOrigin(saved, size: size, visibleFrame: savedScreen.visibleFrame)
    }

    private func constrainedOrigin(_ origin: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        return CGPoint(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY)
        )
    }
}
