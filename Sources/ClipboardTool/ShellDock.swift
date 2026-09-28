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
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 72),
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
            let width = min(720, vis.width - 24)
            let frame = CGRect(x: vis.midX - width / 2, y: vis.minY + 10,
                               width: width, height: 72)
            p.setFrame(frame, display: true)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Dock 视图（方案 C 标签页：激活卡从底线升起一层）

struct ShellDockView: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var panelState: PanelState
    @State private var selected = 0
    @State private var hoveringIndex: Int?
    @State private var dockHovering = false
    @Environment(\.colorScheme) private var scheme

    private var items: [ClipboardItem] { store.items.filter { panelState.matches($0) } }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ArcaneSparkle(size: 13, glow: true)
                .padding(.bottom, 10)
            Rectangle()
                .fill(RubickTheme.hairline(scheme))
                .frame(width: 1, height: 26)
            if items.isEmpty {
                Text("魔典空空如也 — 复制点东西试试")
                    .font(.system(size: 11))
                    .foregroundStyle(RubickTheme.muted(scheme))
                    .padding(.bottom, 10)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(Array(items.prefix(12).enumerated()), id: \.element.id) { index, item in
                            tabCard(item, index: index, isActive: selected == index)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 0)
        .frame(height: 72)
        .background(.ultraThinMaterial)
        .background(RubickTheme.panelAurora(scheme))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(RubickTheme.panelGradientBorder(scheme), lineWidth: 0.8)
        )
        // 手动关闭（悬停时右上角浮现）：必须用 overlay——之前是 HStack 子元素，
        // 出现时被挤到 720pt 面板边界外裁掉，永远看不见
        .overlay(alignment: .topTrailing) {
            if dockHovering {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(RubickTheme.muted(scheme))
                    .padding(.top, 6)
                    .padding(.trailing, 12)
                    .contentShape(Rectangle())
                    // 非激活面板里 Button/onTapGesture 不触发，只能用 DragGesture(0)
                    .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                        if hypot(v.translation.width, v.translation.height) < 6 {
                            ShellDockController.shared.hide()
                        }
                    })
                    .help("关闭弹壳（⎋ / ⌘⇧V 也可收起）")
                    .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { dockHovering = hovering }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelSelectionChanged)) { _ in
            selected = HistoryPanelController.shared.selectedIndex
        }
        .onAppear {
            selected = HistoryPanelController.shared.selectedIndex
        }
    }

    @ViewBuilder
    private func tabCard(_ item: ClipboardItem, index: Int, isActive: Bool) -> some View {
        let hovering = hoveringIndex == index
        Group {
            switch item.kind {
            case .text:
                textOrLinkTab(item, isActive: isActive)
            case .image:
                imageTab(item, isActive: isActive)
            case .file:
                fileTab(item, isActive: isActive)
            }
        }
        .padding(.top, isActive ? 9 : 6)
        .padding(.bottom, isActive ? 12 : 7)
        .padding(.horizontal, isActive ? 13 : 10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isActive ? RubickTheme.primary(scheme).opacity(0.10)
                      : (hovering ? RubickTheme.surfaceHigh(scheme).opacity(0.7) : RubickTheme.surfaceContainer(scheme)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isActive ? RubickTheme.primary(scheme).opacity(0.8)
                              : (hovering ? RubickTheme.primary(scheme).opacity(0.35) : RubickTheme.hairline(scheme)),
                              lineWidth: isActive ? 1.2 : 1)
        )
        // 标签页「升起」感：激活卡下缘探到底线之下（更高的卡片 + 负底边距）
        .offset(y: isActive ? 4 : 0)
        .contentShape(Rectangle())
        // 非激活面板永不成为 key，onTapGesture 在其中不触发（点卡片全无反应的根因）；
        // DragGesture(0) 不依赖 key 窗口，位移 <6pt 视为点击
        .gesture(DragGesture(minimumDistance: 0).onEnded { v in
            if hypot(v.translation.width, v.translation.height) < 6 {
                HistoryPanelController.shared.activateDockItem(at: index)
            }
        })
        .onHover { hovering in
            hoveringIndex = hovering ? index : (hoveringIndex == index ? nil : hoveringIndex)
            if hovering { HistoryPanelController.shared.setSelected(index) }
        }
        .animation(.easeOut(duration: 0.12), value: isActive)
        .animation(.easeOut(duration: 0.1), value: hoveringIndex)
    }

    /// 文本标签：首行标题为主视觉，激活态带第二行（方案 C）
    private func textTab(_ item: ClipboardItem, isActive: Bool) -> some View {
        let lines = (item.text ?? "").components(separatedBy: .newlines)
        let title = lines.first ?? ""
        return VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: isActive ? 11 : 10.5, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? RubickTheme.onSurface(scheme) : RubickTheme.onSurface(scheme).opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, alignment: .leading)
            if isActive, lines.count > 1, !lines[1].trimmingCharacters(in: .whitespaces).isEmpty {
                Text(lines[1])
                    .font(.system(size: 10))
                    .foregroundStyle(RubickTheme.muted(scheme))
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
            }
        }
    }

    /// 链接标签：域名主视觉（绿）+ 激活态路径第二行
    @ViewBuilder
    private func linkTab(_ item: ClipboardItem, isActive: Bool) -> some View {
        let text = item.text ?? ""
        let domain = PanelState.displayDomain(text)
        let path = URL(string: text.hasPrefix("http") ? text : "https://" + text)?.path ?? ""
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: "link")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(RubickTheme.primary(scheme))
                Text(domain)
                    .font(.system(size: isActive ? 11 : 10.5, weight: .semibold))
                    .foregroundStyle(RubickTheme.primary(scheme))
                    .lineLimit(1)
            }
            if isActive, !path.isEmpty, path != "/" {
                Text(path)
                    .font(.system(size: 10))
                    .foregroundStyle(RubickTheme.muted(scheme))
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
            }
        }
    }

    /// 文本/链接分派（链接走专属视觉）
    @ViewBuilder
    private func textOrLinkTab(_ item: ClipboardItem, isActive: Bool) -> some View {
        if let t = item.text, PanelState.isLink(t) {
            linkTab(item, isActive: isActive)
        } else {
            textTab(item, isActive: isActive)
        }
    }

    /// 文件标签：文件图标 + 文件名主视觉
    private func fileTab(_ item: ClipboardItem, isActive: Bool) -> some View {
        let name = (item.filePath as NSString?)?.lastPathComponent ?? ""
        return HStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.filePath ?? ""))
                .resizable()
                .frame(width: 16, height: 16)
            Text(name)
                .font(.system(size: isActive ? 11 : 10.5, weight: .semibold))
                .foregroundStyle(RubickTheme.onSurface(scheme).opacity(isActive ? 1 : 0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .leading)
        }
    }

    /// 图片标签：圆角缩略图
    @ViewBuilder
    private func imageTab(_ item: ClipboardItem, isActive: Bool) -> some View {
        Group {
            if let img = store.thumbnail(for: item, maxPixel: 140) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 54, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(RubickTheme.surfaceHigh(scheme))
                    .frame(width: 54, height: 30)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}
