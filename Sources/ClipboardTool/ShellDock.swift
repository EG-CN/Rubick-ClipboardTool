import AppKit
import SwiftUI

// MARK: - 弹壳 Dock（奥术夜幕：贴屏幕底部的标签页式快捷切换条）
// 形态二：⌘⇧V 按设置呼出（panel.form = "dock"）；标签卡从底线升起，激活卡更高一层；
// 单击卡片 = 复制 + 自动粘贴（与主面板点选一致）；失焦不关闭，仅快捷键再按收起

final class ShellDockController {
    static let shared = ShellDockController()

    private var panel: NSPanel?
    private(set) var isVisible = false
    private var escMonitor: Any?

    private init() {}

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        // 激活前抓取前台应用：dockPreferred 粘贴目标判定依赖它
        HistoryPanelController.shared.captureFrontmost()
        let store = HistoryStore.shared
        let panelState = HistoryPanelController.shared.panelState
        // 与主面板同语义：呼出即重置筛选，展示全量最近
        panelState.searchText = ""
        panelState.filter = .all
        panelState.tagFilter = nil
        HistoryPanelController.shared.resetSelection()

        if panel == nil {
            let host = NSHostingView(rootView: ShellDockView()
                .environmentObject(store)
                .environmentObject(panelState))
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 226),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = false
            p.contentView = host
            panel = p
        }

        // 贴鼠标所在屏幕底部居中
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main
        if let screen = screen, let p = panel {
            let vis = screen.visibleFrame
            let width = min(880, vis.width - 24)
            let frame = CGRect(x: vis.midX - width / 2, y: vis.minY + 10,
                               width: width, height: 226)
            p.setFrame(frame, display: true)
        }
        ActivationPolicyKeeper.shared.acquire("dock")
        panel?.orderFrontRegardless()
        isVisible = true
        // 全局键盘监听：⎋ 收起（dock 非激活面板、永不成为 key，只能靠全局监听）
        // ⌘1-9 直取第 N 条（与主面板数字键心智一致）
        if escMonitor == nil {
            escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return }
                if event.keyCode == 53 {
                    DispatchQueue.main.async { self.hide() }
                    return
                }
                if event.modifierFlags.contains(.command),
                   let ch = event.charactersIgnoringModifiers, let n = ch.first?.wholeNumberValue,
                   (1...9).contains(n) {
                    DispatchQueue.main.async {
                        HistoryPanelController.shared.activateDockItem(at: n - 1)
                        self.hide()
                    }
                }
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        ActivationPolicyKeeper.shared.release("dock")
    }
}

// MARK: - Dock 视图（照 Stitch「随手夹 Dock 模式」1:1：提示胶囊 + 拍立得卡片托盘）

struct ShellDockView: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var panelState: PanelState
    @State private var selected = 0
    @State private var hoverIndex: Int?
    @Environment(\.colorScheme) private var scheme

    private var items: [ClipboardItem] { store.items.filter { panelState.matches($0) } }

    /// 稿面微旋角序列：相邻卡交替自然倾角，悬停/激活归正
    private let rotations: [Double] = [-1.5, 1.0, 1.5, -2.0, -1.2, 2.0, -1.0, 1.2, -1.8]

    var body: some View {
        VStack(spacing: 10) {
            hintPill
            tray
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelSelectionChanged)) { _ in
            selected = HistoryPanelController.shared.selectedIndex
        }
        .onAppear {
            selected = HistoryPanelController.shared.selectedIndex
        }
    }

    // MARK: 顶部提示胶囊（绿点 · 标题 · 分隔 · 快捷键提示）

    private var hintPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(RubickTheme.emerald)
                .frame(width: 6, height: 6)
                .shadow(color: RubickTheme.emerald, radius: 3)
            Text("随手夹 · Dock 模式")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
            Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 10)
            Text("\(HotkeyManager.shared.panelShortcutDisplay) 收起 · 拖拽卡片至任意应用")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color(red: 0.05, green: 0.06, blue: 0.078).opacity(0.82)))
        .overlay(Capsule().strokeBorder(RubickTheme.emerald.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
    }

    // MARK: 主托盘（深玻璃 + 顶部翡翠缘光 + 左 Hub + 卡片序列）

    private var tray: some View {
        HStack(alignment: .bottom, spacing: 0) {
            leftHub
            if items.isEmpty {
                Text("魔典空空如也 — 复制点东西试试")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 12) {
                        ForEach(Array(items.prefix(9).enumerated()), id: \.element.id) { index, item in
                            shelfCard(item, index: index)
                        }
                    }
                    // 顶部留白容纳激活卡抬升 + 快捷工具条
                    .padding(.top, 44)
                    .padding(.bottom, 8)
                    .padding(.horizontal, 6)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.043, green: 0.052, blue: 0.07).opacity(0.86))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
        // 顶部翡翠缘光线（稿 inset-x-8 via-primary/70）
        .overlay(alignment: .top) {
            LinearGradient(colors: [.clear, RubickTheme.emerald.opacity(0.7), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1.5)
                .padding(.horizontal, 32)
        }
        .shadow(color: .black.opacity(0.75), radius: 24, y: 10)
    }

    private var leftHub: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [RubickTheme.emerald.opacity(0.5), Color.white.opacity(0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: RubickTheme.emerald.opacity(0.35), radius: 6)
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color(red: 0.06, green: 0.07, blue: 0.09))
                    .padding(1)
                Image(systemName: "diamond")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(RubickTheme.emerald)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("拉比克")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.95))
                Text("DOCK")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(RubickTheme.emerald)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 44)
        }
        .padding(.trailing, 10)
    }

    // MARK: 拍立得卡（微旋 + 顶部夹子 + 内容框 + 图注；激活抬升 + 翡翠环 + 快捷工具条）

    @ViewBuilder
    private func shelfCard(_ item: ClipboardItem, index: Int) -> some View {
        let isActive = selected == index
        let hovering = hoverIndex == index
        Group {
            VStack(spacing: 0) {
                if isActive {
                    quickActions(item, index: index)
                        .offset(y: -14)
                        .padding(.bottom, 4)
                }
                ZStack(alignment: .top) {
                    cardBody(item, isActive: isActive)
                        .padding(.top, 5)
                    cardClip(variant: isActive ? .emerald : (index % 3 == 2 ? .brass : .chrome), isActive: isActive)
                }
            }
            .rotationEffect(.degrees(hovering || isActive ? 0 : rotations[index % rotations.count]))
            .offset(y: isActive ? -12 : 0)
            .scaleEffect(hovering && !isActive ? 1.03 : 1)
        }
        .zIndex(isActive ? 30 : 0)
        .contentShape(Rectangle())
        // 非激活面板里 Button/onTapGesture 不触发，DragGesture(0) 位移 <6pt 视为点击
        .gesture(DragGesture(minimumDistance: 0).onEnded { v in
            if hypot(v.translation.width, v.translation.height) < 6 {
                HistoryPanelController.shared.activateDockItem(at: index)
                ShellDockController.shared.hide()
            }
        })
        .onHover { hovering in
            hoverIndex = hovering ? index : (hoverIndex == index ? nil : hoverIndex)
            if hovering { HistoryPanelController.shared.setSelected(index) }
        }
        .animation(.easeOut(duration: 0.18), value: isActive)
        .animation(.easeOut(duration: 0.12), value: hoverIndex)
    }

    /// 卡内容 + 图注（稿：暖白相纸 #FBF9F5，深色图注文字）
    @ViewBuilder
    private func cardBody(_ item: ClipboardItem, isActive: Bool) -> some View {
        VStack(spacing: 0) {
            content(item, isActive: isActive)
                .frame(width: 118, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isActive ? RubickTheme.emerald.opacity(0.4) : Color.black.opacity(0.12), lineWidth: 1)
                )
            shelfCaption(item, isActive: isActive)
                .padding(.horizontal, 2)
                .padding(.top, 5)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 0.984, green: 0.976, blue: 0.961)))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isActive ? RubickTheme.emerald : Color.black.opacity(0.18), lineWidth: isActive ? 2 : 0.8)
        )
        .shadow(color: .black.opacity(0.5), radius: 9, y: 5)
    }

    @ViewBuilder
    private func content(_ item: ClipboardItem, isActive: Bool) -> some View {
        switch item.kind {
        case .image:
            ZStack(alignment: .topLeading) {
                Group {
                    if let img = store.thumbnail(for: item, maxPixel: 300) {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        Color(red: 0.1, green: 0.11, blue: 0.14)
                    }
                }
                .frame(width: 118, height: 78)
                .clipped()
                if isActive {
                    Text("LIVE")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 3).fill(RubickTheme.emerald))
                        .padding(3)
                }
            }
        case .file:
            VStack(spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.filePath ?? ""))
                    .resizable().frame(width: 26, height: 26)
                Text(((item.filePath as NSString?)?.pathExtension ?? "").uppercased())
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.72, green: 0.29, blue: 0.25))
            }
            .frame(width: 118, height: 78)
            .background(Color(red: 0.06, green: 0.07, blue: 0.09))
        case .text:
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(PanelState.isLink(item.text ?? "") ? PanelState.displayDomain(item.text ?? "") : "snippet")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(RubickTheme.emerald)
                    Spacer()
                    Image(systemName: PanelState.isLink(item.text ?? "") ? "link" : "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
                Text((item.text ?? "").replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }
            .padding(6)
            .frame(width: 118, height: 78, alignment: .topLeading)
            .background(Color(red: 0.06, green: 0.07, blue: 0.09))
        }
    }

    private static let captionTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private func shelfCaption(_ item: ClipboardItem, isActive: Bool) -> some View {
        let title: String
        let meta: String
        switch item.kind {
        case .image:
            title = "图片"
            meta = Self.captionTimeFormatter.string(from: item.timestamp ?? Date())
        case .file:
            title = (item.filePath as NSString?)?.lastPathComponent ?? "文件"
            if let path = item.filePath, let attr = try? FileManager.default.attributesOfItem(atPath: path),
               let bytes = attr[.size] as? Int64 {
                meta = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            } else {
                meta = "文件"
            }
        case .text:
            title = String((item.text ?? "").prefix(40))
            meta = Self.captionTimeFormatter.string(from: item.timestamp ?? Date())
        }
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color(red: 0.1, green: 0.1, blue: 0.1))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(meta)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(Color(red: 0.4, green: 0.4, blue: 0.4))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isActive {
                Circle()
                    .fill(RubickTheme.emerald)
                    .frame(width: 7, height: 7)
                    .shadow(color: RubickTheme.emerald, radius: 3)
                    .padding(.top, 3)
            }
        }
    }

    // MARK: 夹子（铬 / 祖母绿珐琅 / 黄铜）

    private enum ClipVariant { case chrome, emerald, brass }

    private func cardClip(variant: ClipVariant, isActive: Bool) -> some View {
        Group {
            switch variant {
            case .chrome:
                LinearGradient(colors: [Color(white: 0.88), Color(white: 0.6)], startPoint: .top, endPoint: .bottom)
            case .emerald:
                LinearGradient(colors: [RubickTheme.emerald, RubickTheme.emerald.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            case .brass:
                LinearGradient(colors: [Color(red: 0.96, green: 0.78, blue: 0.36), Color(red: 0.85, green: 0.6, blue: 0.16)], startPoint: .top, endPoint: .bottom)
            }
        }
        .frame(width: 16, height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Color.black.opacity(0.35), lineWidth: 0.8)
        )
        .overlay(Rectangle().fill(Color.black.opacity(0.5)).frame(width: 5, height: 2).offset(y: -3.5))
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1.5)
    }

    // MARK: 激活卡快捷工具条（复制 / 置顶）

    private func quickActions(_ item: ClipboardItem, index: Int) -> some View {
        HStack(spacing: 10) {
            tapZone(symbol: "content_copy", help: "复制") {
                HistoryPanelController.shared.activateDockItem(at: index)
                ShellDockController.shared.hide()
            }
            tapZone(symbol: "push_pin", help: "钉贴图") {
                HistoryPanelController.shared.pin(item)
                ShellDockController.shared.hide()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color(red: 0.12, green: 0.14, blue: 0.17).opacity(0.92)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
    }

    private func tapZone(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .foregroundStyle(Color.white.opacity(0.85))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                if hypot(v.translation.width, v.translation.height) < 6 { action() }
            })
            .help(help)
    }
}
