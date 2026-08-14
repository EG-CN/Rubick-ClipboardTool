import AppKit
import SwiftUI

// MARK: - 面板状态（搜索 + 分类过滤）

final class PanelState: ObservableObject {
    enum FilterKind: Int, CaseIterable {
        case all = 0, text = 1, image = 2

        var label: String {
            switch self {
            case .all: return "全部"
            case .text: return "文本"
            case .image: return "图片"
            }
        }
    }

    @Published var searchText = ""
    @Published var filter: FilterKind = .all

    func matches(_ item: ClipboardItem) -> Bool {
        switch filter {
        case .all: break
        case .text: if item.kind != .text { return false }
        case .image: if item.kind != .image { return false }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            guard item.kind == .text, let t = item.text else { return false }
            return t.localizedCaseInsensitiveContains(q)
        }
        return true
    }
}

// MARK: - 历史面板控制器（悬浮置顶、键盘导航、失焦自动关闭、焦点还原、保持打开/仅复制）

final class HistoryPanelController: NSObject, NSWindowDelegate {
    static let shared = HistoryPanelController()

    private let store = HistoryStore.shared
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var suppressAutoClose = false
    private(set) var selectedIndex = 0
    let panelState = PanelState()
    /// 由 AppDelegate 注入：用于把面板锚定在菜单栏图标下方
    weak var statusButton: NSStatusBarButton?

    private override init() { super.init() }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 设置项：粘贴后保持面板打开（可连续粘贴多条，⎋ 关闭）
    var keepOpen: Bool { UserDefaults.standard.object(forKey: "keepPanelOpen") as? Bool ?? true }

    func toggle(fromHotkey: Bool = false) {
        if isVisible { close() } else { show(fromHotkey: fromHotkey) }
    }

    func filteredItems() -> [ClipboardItem] {
        store.items.filter { panelState.matches($0) }
    }

    func resetSelection() {
        selectedIndex = filteredItems().isEmpty ? -1 : 0
        notifySelection()
    }

    func show(fromHotkey: Bool = false) {
        if panel == nil {
            let host = NSHostingView(rootView: HistoryPanelView()
                .environmentObject(store)
                .environmentObject(panelState))
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
                            styleMask: [.titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = false
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.standardWindowButton(.closeButton)?.isHidden = true
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            p.contentView = host
            p.delegate = self
            panel = p
        }
        if fromHotkey { positionNearMouse() } else { positionNearStatusItem() }
        panelState.searchText = ""
        panelState.filter = .all
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        resetSelection()
        installMonitors()
    }

    func close() {
        guard isVisible else { return }
        panel?.orderOut(nil)
        removeMonitors()
        restoreFocus()
    }

    func windowDidResignKey(_ notification: Notification) {
        if !suppressAutoClose { close() }
    }

    /// 粘贴完成后把面板重新变为 key，继续选择下一条
    private func reactivatePanel() {
        guard let p = panel, p.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    /// 还原焦点到呼出面板前的 App（⎋ / 点击外部关闭时使用）
    private func restoreFocus() {
        guard let target = targetAppForRestore() else { return }
        activateApp(target)
    }

    /// 粘贴前的焦点还原：轮询等待目标 App 真正成为前台后再回调（修复粘贴落空）
    private func restoreFocusAndWait(completion: @escaping () -> Void) {
        guard let target = targetAppForRestore() else {
            completion()
            return
        }
        activateApp(target)
        waitUntilFrontmost(target, attempts: 20, interval: 0.05) { _ in
            completion()
        }
    }

    /// 还原目标：优先呼出面板前的 App；兜底取最靠前的普通应用（排除自己）
    private func targetAppForRestore() -> NSRunningApplication? {
        if let prev = previousApp,
           prev.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           !prev.isTerminated {
            return prev
        }
        return NSWorkspace.shared.runningApplications.first { app in
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            app.activationPolicy == .regular && !app.isTerminated
        }
    }

    private func activateApp(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
        }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    private func waitUntilFrontmost(_ app: NSRunningApplication, attempts: Int, interval: TimeInterval, done: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier || attempts <= 0 {
            done(true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.waitUntilFrontmost(app, attempts: attempts - 1, interval: interval, done: done)
        }
    }

    // MARK: 面板位置

    private func positionNearStatusItem() {
        guard let p = panel else { return }
        if let btn = statusButton, let btnWin = btn.window, let screen = btnWin.screen {
            let vis = screen.visibleFrame
            var x = btnWin.frame.maxX - p.frame.width + 8
            x = min(x, vis.maxX - 12)
            x = max(x, vis.minX + 12)
            let y = btnWin.frame.minY - p.frame.height - 4
            p.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        guard let screen = NSScreen.main else { return }
        let vis = screen.visibleFrame
        let x = vis.maxX - p.frame.width - 12
        let y = vis.maxY - p.frame.height - 8
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// 快捷键呼出时跟随鼠标所在屏幕弹出
    private func positionNearMouse() {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(m) }) ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        var x = m.x + 16
        var y = m.y - p.frame.height - 12
        if x + p.frame.width > vis.maxX { x = m.x - p.frame.width - 16 }
        if x < vis.minX { x = vis.minX + 12 }
        if y < vis.minY { y = vis.minY + 12 }
        if y + p.frame.height > vis.maxY { y = vis.maxY - p.frame.height - 12 }
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: 键盘（全部走 PanelKeyConfig，可配置）+ 点击外部关闭

    private func installMonitors() {
        removeMonitors()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            // 搜索框编辑中：按键放行给输入框（仅 ⎋ 仍关闭面板）
            if let fr = NSApp.keyWindow?.firstResponder, fr is NSTextView {
                if event.keyCode == 53 { self.close() }
                return event
            }
            let pk = PanelKeyConfig.shared
            if pk.matches(.navUp, event: event) { self.moveSelection(-1); return nil }
            if pk.matches(.navDown, event: event) { self.moveSelection(1); return nil }
            if pk.matches(.paste, event: event) { self.activateSelected(); return nil }
            if pk.matches(.close, event: event) { self.close(); return nil }
            if pk.matches(.deleteItem, event: event) { self.deleteSelected(); return nil }
            if pk.matches(.pin, event: event) {
                if self.filteredItems().indices.contains(self.selectedIndex) {
                    let item = self.filteredItems()[self.selectedIndex]
                    if item.kind == .image { self.pin(item) }
                }
                return nil
            }
            if pk.matches(.quick, event: event), let n = pk.quickDigit(event) {
                self.activate(at: n - 1)
                return nil
            }
            return event
        }

        // 本应用内部点击在面板外 → 关闭面板并吞掉该次点击；面板内点击放行（按钮/手势）
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let p = self.panel, p.isVisible else { return event }
            if !self.suppressAutoClose, !p.frame.contains(NSEvent.mouseLocation) {
                self.close()
                return nil
            }
            return event
        }
        // 其他应用的点击 → 关闭
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let p = self.panel, p.isVisible, !self.suppressAutoClose else { return }
            if !p.frame.contains(NSEvent.mouseLocation) {
                self.close()
            }
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
    }

    // MARK: 选择 / 操作（作用于过滤后的列表）

    func moveSelection(_ d: Int) {
        let items = filteredItems()
        guard !items.isEmpty else { return }
        selectedIndex = max(0, min(items.count - 1, selectedIndex + d))
        notifySelection()
    }

    func activateSelected() {
        let items = filteredItems()
        guard items.indices.contains(selectedIndex) else { return }
        activate(items[selectedIndex], copyOnly: false)
    }

    func deleteSelected() {
        let items = filteredItems()
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        store.remove(item.id)
        if selectedIndex >= filteredItems().count { selectedIndex = max(0, filteredItems().count - 1) }
        if filteredItems().isEmpty { selectedIndex = -1 }
        notifySelection()
        Toast.shared.show("已删除该条历史")
    }

    func activate(at index: Int, copyOnly: Bool = false) {
        let items = filteredItems()
        guard items.indices.contains(index) else { return }
        activate(items[index], copyOnly: copyOnly)
    }

    func setSelected(_ index: Int) {
        let items = filteredItems()
        guard items.indices.contains(index) else { return }
        selectedIndex = index
        notifySelection()
    }

    func delete(at index: Int) {
        let items = filteredItems()
        guard items.indices.contains(index) else { return }
        store.remove(items[index].id)
        if selectedIndex >= filteredItems().count { selectedIndex = max(0, filteredItems().count - 1) }
        if filteredItems().isEmpty { selectedIndex = -1 }
        notifySelection()
        Toast.shared.show("已删除该条历史")
    }

    /// 点选：复制到剪贴板 → 还原焦点 →（可选）自动粘贴
    private func activate(_ item: ClipboardItem, copyOnly: Bool) {
        let keepOpenNow = keepOpen
        if !keepOpenNow { close() }

        switch item.kind {
        case .text:
            writeTextToPasteboard(item.text ?? "")
        case .image:
            if let img = store.imageFor(item) {
                writeImageToPasteboard(img)
            }
        }

        let pasteAuto = UserDefaults.standard.object(forKey: "pasteAuto") as? Bool ?? true
        let doPaste = !copyOnly && pasteAuto && AXIsProcessTrusted()

        if doPaste {
            suppressAutoClose = true
            restoreFocusAndWait { [weak self] in
                simulatePaste()
                Toast.shared.show("已粘贴到当前输入框")
                guard let self = self else { return }
                if keepOpenNow { self.reactivatePanel() }
                self.suppressAutoClose = false
            }
        } else {
            if !(copyOnly && keepOpenNow) {
                if keepOpenNow {
                    suppressAutoClose = true
                    restoreFocus()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        self?.suppressAutoClose = false
                    }
                }
            }
            if !copyOnly && pasteAuto && !AXIsProcessTrusted() {
                Toast.shared.show("已复制 · 请手动 ⌘V（系统设置→隐私与安全性→辅助功能 授权后重启应用可自动粘贴）")
            } else {
                Toast.shared.show(copyOnly ? "已复制（未粘贴）" : "已复制，可手动粘贴")
            }
        }

        if !keepOpenNow { store.touch(item) }
    }

    func pin(_ item: ClipboardItem) {
        guard item.kind == .image, let img = store.imageFor(item) else { return }
        PinController.shared.pin(image: img)
        store.remove(item.id)
        var t = item
        t.pinned = true
        t.timestamp = Date()
        store.items.insert(t, at: 0)
        store.save()
        if selectedIndex >= filteredItems().count { selectedIndex = max(0, filteredItems().count - 1) }
        notifySelection()
        Toast.shared.show("已钉在桌面 · 双击贴图取消")
    }

    private func notifySelection() {
        NotificationCenter.default.post(name: .panelSelectionChanged, object: nil)
    }
}

// MARK: - 面板视图（Stitch 设计还原：搜索 + 筛选 + 发光卡片 + 状态栏）

struct HistoryPanelView: View {
    @EnvironmentObject var store: HistoryStore
    @EnvironmentObject var panelState: PanelState
    @ObservedObject var panelKeys = PanelKeyConfig.shared
    @Environment(\.colorScheme) private var scheme
    @State private var selected: Int = 0

    private var items: [ClipboardItem] { store.items.filter { panelState.matches($0) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            filterChips
            if items.isEmpty {
                emptyView
            } else {
                list
            }
            footer
        }
        .frame(width: 360, height: 500)
        .background(.ultraThinMaterial)
        .background(RubickTheme.darkBackground.opacity(scheme == .dark ? 0.55 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .onReceive(NotificationCenter.default.publisher(for: .panelSelectionChanged)) { _ in
            selected = HistoryPanelController.shared.selectedIndex
        }
        .onAppear { selected = HistoryPanelController.shared.selectedIndex }
        .onChange(of: panelState.searchText) { _ in
            HistoryPanelController.shared.resetSelection()
        }
        .onChange(of: panelState.filter) { _ in
            HistoryPanelController.shared.resetSelection()
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(RubickTheme.primary(scheme))
            Text("拉比克")
                .font(.system(size: 13, weight: .bold))
            Text("\(store.items.count) / \(store.limit) 条")
                .font(.system(size: 10.5))
                .foregroundStyle(RubickTheme.muted(scheme))
            Spacer()
            Button(action: { SettingsController.shared.show() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(RubickTheme.muted(scheme))
            .help("设置")
            Button(action: { confirmClearHistory() }) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(RubickTheme.muted(scheme))
            .help("清空历史")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 搜索

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(RubickTheme.muted(scheme))
            TextField("搜索法术…", text: $panelState.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(RubickTheme.surfaceHigh(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RubickTheme.primary(scheme).opacity(0.25), lineWidth: 0.5))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: 筛选

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(PanelState.FilterKind.allCases, id: \.rawValue) { kind in
                let active = panelState.filter == kind
                Button(kind.label) {
                    panelState.filter = kind
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(active
                                          ? RubickTheme.primary(scheme).opacity(0.15)
                                          : RubickTheme.surfaceHigh(scheme)))
                .overlay(Capsule().strokeBorder(active
                                                ? RubickTheme.primary(scheme).opacity(0.5)
                                                : Color.primary.opacity(0.06), lineWidth: 1))
                .foregroundStyle(active ? RubickTheme.primary(scheme) : RubickTheme.muted(scheme))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: 空态

    private var emptyView: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "book.closed")
                .font(.system(size: 26))
                .foregroundStyle(RubickTheme.muted(scheme).opacity(0.6))
            Text(items.isEmpty && !store.items.isEmpty ? "没有匹配的条目" : "魔典空空如也 — 复制文字或截图试试")
                .font(.system(size: 12))
                .foregroundStyle(RubickTheme.muted(scheme))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 列表

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .onChange(of: selected) { newValue in
                if items.indices.contains(newValue) {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(items[newValue].id)
                    }
                }
            }
        }
    }

    // MARK: 行（Stitch 卡片）

    @State private var hoveringIds: Set<String> = []

    private func row(_ item: ClipboardItem, index: Int) -> some View {
        HStack(alignment: .top, spacing: 4) {
            // 内容区（承载点击 / ⌥点击）
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    typeChip(item)
                    Spacer()
                    Text(timeAgo(item.timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(RubickTheme.muted(scheme))
                        .fontWeight(item.kind == .text && (item.text ?? "").contains("\n") ? .regular : .regular)
                }
                if item.kind == .text {
                    Text(item.text ?? "")
                        .font(.system(size: 11.5, design: (item.text ?? "").contains("\n") ? .monospaced : .default))
                        .foregroundStyle(RubickTheme.onSurface(scheme))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Group {
                        if let img = store.imageFor(item) {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Rectangle().fill(RubickTheme.surfaceHigh(scheme))
                        }
                    }
                    .frame(height: 92)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if NSApp.currentEvent?.modifierFlags.contains(.option) == true { return }
                HistoryPanelController.shared.activate(at: index)
            }
            .simultaneousGesture(
                TapGesture().modifiers(.option).onEnded {
                    HistoryPanelController.shared.activate(at: index, copyOnly: true)
                }
            )

            // 悬停操作按钮（独立命中区域）
            VStack(spacing: 4) {
                if item.kind == .image {
                    actionButton("pin.fill") { HistoryPanelController.shared.pin(item) }
                        .help("钉图")
                }
                actionButton("trash") { HistoryPanelController.shared.delete(at: index) }
                    .help("删除")
            }
            .opacity(hoveringIds.contains(item.id) ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: hoveringIds.contains(item.id))
        }
        .padding(10)
        .glowCard(hovering: hoveringIds.contains(item.id), selected: selected == index, cornerRadius: 8)
        .onHover { hovering in
            if hovering {
                hoveringIds.insert(item.id)
                HistoryPanelController.shared.setSelected(index)
            } else {
                hoveringIds.remove(item.id)
            }
        }
    }

    private func typeChip(_ item: ClipboardItem) -> some View {
        let color: Color
        let label: String
        switch item.kind {
        case .text:
            color = RubickTheme.primary(scheme)
            label = "文本"
        case .image:
            color = .blue
            label = "图片"
        }
        return Text(label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }

    private func actionButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedIsCurrent(symbol) ? Color.white : RubickTheme.muted(scheme))
        .frame(width: 24, height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(RubickTheme.surfaceContainer(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private func selectedIsCurrent(_ symbol: String) -> Bool { false }

    // MARK: 底部状态栏

    private var footer: some View {
        VStack(spacing: 4) {
            Text(panelKeys.hintText() + " · ⌥点=仅复制")
                .font(.system(size: 9.5))
                .foregroundStyle(RubickTheme.muted(scheme).opacity(0.8))
                .lineLimit(1)
            HStack(spacing: 5) {
                Circle()
                    .fill(RubickTheme.emerald)
                    .frame(width: 6, height: 6)
                    .shadow(color: RubickTheme.emerald.opacity(0.8), radius: 2)
                Text("运行中")
                    .font(.system(size: 10))
                    .foregroundStyle(RubickTheme.muted(scheme))
                Spacer()
                Text("\(store.items.count) 条")
                    .font(.system(size: 10))
                    .foregroundStyle(RubickTheme.muted(scheme))
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
    }
}
