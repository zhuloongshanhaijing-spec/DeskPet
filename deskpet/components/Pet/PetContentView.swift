//
//  PetContentView.swift
//  boringNotch
//
//  宠物视图与交互：序列帧渲染、单击戳、双击回窝/出窝、拖拽拎起、右键菜单。
//

import AppKit
import Defaults
import SwiftUI

/// 序列帧渲染视图（素材即动画，不做程序化旋转/翻转变换）
/// 使用 .drawingGroup() 将帧渲染合并到单个 Metal 位图，避免 CoreAnimation
/// 为每帧创建独立图层缓存（实测 739 层累积 215MB → 合并后大幅降低）。
struct PetSpriteView: View {
    @ObservedObject var pet = PetManager.shared

    var body: some View {
        Group {
            if let frame = pet.currentFrame {
                Image(nsImage: frame)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(x: pet.facingLeft ? -1 : 1, y: 1, anchor: .center)
                    // 按压反馈：以精灵底部为锚点压低 Y、微扩 X（程序化缩放，不新增帧）
                    .scaleEffect(x: pet.pressScaleX, y: pet.pressScaleY, anchor: .bottom)
                    .drawingGroup()  // 合并到单个 Metal 位图，减少 CoreAnimation 图层累积
            } else {
                // 无素材时的占位（默认皮肤未安装）
                ZStack {
                    Circle()
                        .fill(Color(nsColor: .systemOrange))
                        .frame(width: 72, height: 72)
                    Image(systemName: "cat.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

/// 宠物主视图（窗口内容）
struct PetContentView: View {
    @ObservedObject var pet = PetManager.shared
    /// 单击/双击判定：SwiftUI 的 onTapGesture(count:1)+count:2 并存时，
    /// 单击要等双击判定窗口（~0.4s）才触发——点击响应被延迟。
    /// 改用统一 DragGesture + 时间戳自行判定，单击立即响应。
    /// 连续快速点击只给按压反馈；只有"两击后停顿"才触发回窝/出窝。
    @State private var lastClickTime = Date.distantPast
    @State private var pendingDoubleAction: DispatchWorkItem?
    /// 右键监听句柄（仅命中宠物窗口时才响应）
    @State private var rightClickMonitor: Any?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PetSpriteView()
        }
        .frame(width: pet.windowSize.width, height: pet.windowSize.height)
        .contentShape(Rectangle())
        // 去掉 .shadow()：每帧 24fps 让 CoreAnimation 生成带阴影的离屏 raster，
        // 是 CoreAnimation 内存累积的主要来源之一（739层 215MB）。
        // drawingGroup() 已合并渲染，宠物轮廓本身的视觉清晰度不受影响。
        .gesture(
            // 统一手势：不移动=点击（单击按压反馈/双击回窝），移动=拖拽拎起
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !pet.isDragging, hypot(value.translation.width, value.translation.height) > 3 {
                        pet.startDrag()
                    }
                    if pet.isDragging {
                        let mouse = NSEvent.mouseLocation
                        let size = pet.windowSize
                        PetWindowController.shared.moveWindow(
                            to: CGPoint(
                                x: mouse.x - size.width / 2,
                                y: mouse.y - size.height / 2
                            )
                        )
                        // 拖拽投放刘海：鼠标进入刘海展开区时打开 Pet 页 + 提级宠物窗口
                        pet.evaluateNotchDropHover(at: mouse)
                    }
                }
                .onEnded { value in
                    if pet.isDragging {
                        pet.endDrag()
                        // 拖拽结束后同步内部位置，避免继续走动时跳回旧位置
                        pet.syncWindowPosition(PetWindowController.shared.currentOrigin)
                        // 松手处理：在刘海投放区内 → 进窝归位（goHome，刘海保持 Pet 页打开）；
                        // 否则 → 宠物在松手位置落地。
                        if !pet.exitNotchDropHover() {
                            // 未在刘海区域：恢复窗口层级（若曾被提级），宠物正常落地
                            PetWindowController.shared.restoreLevel()
                        }
                    } else if hypot(value.translation.width, value.translation.height) < 3 {
                        handleClick()
                    } else {
                        Logger.log("Pet drag ended without start (translation \(String(format: "%.0f,%.0f", value.translation.width, value.translation.height)))", category: .debug)
                    }
                }
        )
        .onAppear {
            if pet.skin == nil {
                Logger.log("Pet skin missing — placeholder shown. See PET.md for skin setup.", category: .warning)
            }
            // 右键"打招呼"反馈：仅当事件落在宠物面板上时消费。
            // 用本地监视器而不是 contextMenu —— nonactivating 面板上的 NSMenu 会闪退。
            if rightClickMonitor == nil {
                rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { event in
                    guard PetWindowController.shared.isPetWindow(event.window), !pet.isDragging else {
                        return event
                    }
                    pet.gentlePetFeedback()
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

    /// 单击/双击判定（时间戳，单击零延迟）。
    /// 每次点击都立即给按压反馈。双击回窝/出窝只在第二击后没有第三击时才触发——
    /// 连续快速点击只累积按压反馈，不会误回窝。
    private func handleClick() {
        let now = Date()
        // 每击都立即反馈，连续点击也每次都响应
        pet.pressFeedback()

        // 取消上一次挂起的双击动作（第三击及以上 = 连续按压，不回窝）
        pendingDoubleAction?.cancel()
        pendingDoubleAction = nil

        if now.timeIntervalSince(lastClickTime) < 0.4 {
            // 第二击落在窗口内：如果 0.3s 内没有第三击，才算真正双击
            lastClickTime = .distantPast
            let wasAtHome = pet.lifeState == .atHome
            let work = DispatchWorkItem {
                if wasAtHome {
                    pet.leaveHome()
                } else {
                    pet.goHome()
                }
                Logger.log("Pet double-click confirmed (\(wasAtHome ? "leave" : "go") home)", category: .debug)
            }
            pendingDoubleAction = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else {
            // 新序列第一击
            lastClickTime = now
        }
    }
}

/// 回窝状态时在刘海关闭态显示：睡着的猫趴在黑色刘海条上（点击可出窝）。
/// 黑色条是刘海本体（保留 hover/点击区域）。
/// 无刘海屏：猫 + 💤 居中趴在条上；
/// 真刘海屏：刘海区域物理无像素，猫 + 💤 移到刘海右侧的可见区（auxiliary 区域）。
struct PetHomeView: View {
    @ObservedObject var pet = PetManager.shared
    /// 刘海关闭态条宽/高（由 ContentView 传入，与其他关闭态分支保持一致）
    var barWidth: CGFloat = 154
    var barHeight: CGFloat = 34
    @State private var hovering = false
    @State private var zzzPulse = false

    /// 当前 Notch 所在屏是否为真刘海屏（safeAreaInsets.top > 0）
    private var hasRealNotch: Bool {
        let uuid = BoringViewCoordinator.shared.selectedScreenUUID
        let screen = uuid.isEmpty ? NSScreen.main : NSScreen.screen(withUUID: uuid)
        return (screen?.safeAreaInsets.top ?? 0) > 0
    }

    var body: some View {
        // 设计：假刘海不显示任何宠物内容（与真刘海等大，不拓宽、不占辅助区）。
        // 宠物回家后关闭态按原版 notch 规则渲染；宠物内容只在打开态 Pet 页展示。
        Rectangle()
            .fill(.black)
            .frame(width: barWidth, height: barHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                pet.leaveHome()
            }
            .onHover { inside in
                hovering = inside
                if inside {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .help("Click to let your pet out")
    }

    /// 睡猫 + 💤（可点击出窝的视觉主体）
    private var catAndZzz: some View {
        HStack(spacing: 3) {
            if let frame = pet.skin?.frames(for: .home)?.first {
                Image(nsImage: frame)
                    .resizable()
                    .scaledToFit()
                    .frame(height: barHeight)
            } else {
                Image(systemName: "cat.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
            }

            Text("💤")
                .font(.system(size: 13))
                .offset(y: -barHeight * 0.28)
                .scaleEffect(zzzPulse ? 1.0 : 0.7)
                .opacity(zzzPulse ? 1 : 0.4)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: zzzPulse)
        }
        .scaleEffect(hovering ? 1.15 : 1)
        .shadow(color: hovering ? .white.opacity(0.5) : .clear, radius: 5)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
        .onAppear { zzzPulse = true }
    }
}
