//
//  BongoContentView.swift
//  boringNotch
//
//  Bongo Companion 的面板内容：WebView 里的猫 + 状态提示 + 自身按压反馈。
//  点击/拖拽由这里统一处理（WebView 不接收鼠标事件）。
//

import AppKit
import SwiftUI

struct BongoContentView: View {
    @ObservedObject var bongo = BongoManager.shared
    @State private var rightClickMonitor: Any?
    @State private var dragging = false
    @State private var dragStartOrigin: CGPoint?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BongoWebView()
                .scaleEffect(x: bongo.pressScaleX, y: bongo.pressScaleY, anchor: .bottom)
                .allowsHitTesting(false)

            if bongo.optionalResourcesMissing {
                statusBadge(
                    text: "可选 Live2D 资源未安装：Bongo 已降级。安装步骤见 docs/OPTIONAL_LIVE2D_SETUP.md",
                    tint: .orange
                )
                .padding(6)
            } else if let error = bongo.loadError {
                statusBadge(text: "模型加载失败：\(error)", tint: .red)
                    .padding(6)
            } else if bongo.inputStatus == .notAuthorized {
                statusBadge(text: "键盘/鼠标反馈未授权（点击仍可用）", tint: .orange)
                    .padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !dragging,
                       hypot(value.translation.width, value.translation.height) > 3,
                       let origin = BongoWindowController.shared.currentOrigin {
                        dragging = true
                        dragStartOrigin = origin
                    }
                    if dragging, let origin = dragStartOrigin {
                        // SwiftUI 视图坐标 Y 向下，NSWindow 全局坐标 Y 向上。
                        BongoWindowController.shared.moveWindow(
                            to: CGPoint(
                                x: origin.x + value.translation.width,
                                y: origin.y - value.translation.height
                            )
                        )
                    }
                }
                .onEnded { value in
                    if dragging {
                        dragging = false
                        BongoWindowController.shared.persistOrigin()
                    } else if hypot(value.translation.width, value.translation.height) < 3 {
                        handleClick()
                    }
                    dragStartOrigin = nil
                }
        )
        .onAppear {
            if rightClickMonitor == nil {
                rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { event in
                    guard BongoWindowController.shared.isBongoWindow(event.window) else { return event }
                    BongoManager.shared.pressFeedback()
                    return nil
                }
            }
        }
        .onDisappear {
            if let monitor = rightClickMonitor {
                NSEvent.removeMonitor(monitor)
                rightClickMonitor = nil
            }
        }
    }

    private func handleClick() {
        // 单击/双击都只做按压反馈（Bongo 没有回窝概念），因此不需要双击判定窗口。
        BongoManager.shared.pressFeedback()
    }

    private func statusBadge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(2)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.85)))
    }
}
