import AppKit
import SwiftUI

// MARK: - 面板状态（搜索 + 分类过滤）

final class PanelState: ObservableObject {
    enum FilterKind: Int, CaseIterable {
        case all = 0, text = 1, image = 2, link = 3, file = 4

        var label: String {
            switch self {
            case .all: return "全部"
            case .text: return "文本"
            case .image: return "图片"
            case .link: return "链接"
            case .file: return "文件"
            }
        }
    }

    /// 链接判定（纯函数）：单行且以 http(s):// 或 www. 开头
    static func isLink(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("\n") else { return false }
        return t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("www.")
    }

    /// 链接展示域名（纯函数）：剥协议/www,任何结果截断 24 字兜底
    static func displayDomain(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String
        if let url = URL(string: t.hasPrefix("http") ? t : "https://" + t), let host = url.host {
            resolved = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        } else {
            resolved = t
        }
        return String(resolved.prefix(24))
    }

    @Published var searchText = ""
    @Published var filter: FilterKind = .all
    /// 标签筛选（设置后优先于类型筛选）
    @Published var tagFilter: String?
    /// ⌘F 聚焦搜索（控制器 +1，视图监听后置焦）
    @Published var searchFocusRequest = 0

    /// 标签圆点颜色（按标签名哈希取色相，稳定可辨识）
    static func tagColor(_ tag: String) -> Color {
        let hue = Double(abs(tag.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) } % 360)) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.8)
    }

    func matches(_ item: ClipboardItem) -> Bool {
        if let tf = tagFilter {
            guard item.tag == tf else { return false }
        } else {
            switch filter {
            case .all: break
            case .text: if item.kind != .text { return false }
            case .image: if item.kind != .image { return false }
            case .file: if item.kind != .file { return false }
            case .link:
                guard item.kind == .text, let t = item.text, Self.isLink(t) else { return false }
            }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            switch item.kind {
            case .text:
                return item.text?.localizedCaseInsensitiveContains(q) == true
            case .file:
                return item.filePath?.localizedCaseInsensitiveContains(q) == true
            case .image:
                return false
            }
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
    private var globalSearchMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var suppressAutoClose = false
    /// 粘贴会话代际号：粘贴等待期间再点条目/重开面板时，旧会话的 completion 一律作废，防止双粘
    private var pasteSession = 0
    /// 调试自拍用：抑制失焦自动关闭
    var debugHoldOpen = false
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

    /// 记录当前前台应用（粘贴目标判定用；必须在面板自身激活之前调用）
    func captureFrontmost() {
        previousApp = NSWorkspace.shared.frontmostApplication
    }

    /// ⌘F 聚焦搜索：面板非 key 时先拉回 key 再置焦（焦点在别的应用里按下也生效）
    func focusSearch() {
        panelState.searchFocusRequest += 1
        if let p = panel, p.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            p.makeKeyAndOrderFront(nil)
        }
    }

    func show(fromHotkey: Bool = false) {
        pasteSession += 1          // 上一次粘贴会话若仍在等待，立即作废
        suppressAutoClose = false  // 新会话不继承旧会话的抑制态
        // 必须在下方激活之前抓取：激活后 frontmost 是自己，
        // previousApp 记成自己会让粘贴目标选择彻底失灵（dock 正常/面板坏的根因）
        captureFrontmost()
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
        // macOS 26/27：accessory App 的 NSApp.activate 不再生效，未激活时面板
        // 不显示在当前（全屏）空间、点击也不可靠——临时转 regular 激活，关闭还原
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panelState.searchText = ""
        panelState.filter = .all
        panelState.tagFilter = nil   // 呼出即重置筛选（含标签），上次会话的筛选不残留
        panel?.makeKeyAndOrderFront(nil)
        // 保持 regular 常驻（面板可见于全屏空间的前提）；粘贴后由
        // reactivatePanel 重新激活，避免首次点击被激活消费
        resetSelection()
        installMonitors()
        NotificationCenter.default.post(name: .panelShown, object: nil)
    }

    /// restoresFocus=false 用于失焦/点击面板外的被动关闭：用户已自行切走，再把 previousApp
    /// 弹回前台会和用户的应用切换打架（"被弹回"）；⎋/热键主动关闭才还原焦点
    func close(restoresFocus: Bool = true) {
        guard isVisible else { return }
        panel?.orderOut(nil)
        removeMonitors()
        NSApp.setActivationPolicy(.accessory)
        if restoresFocus { restoreFocus() }
    }

    /// 拖动面板（头部拖动条调用；视图 y 向下 → 窗口坐标 y 向上）
    func move(by delta: CGPoint) {
        guard let p = panel else { return }
        var f = p.frame
        f.origin.x += delta.x
        f.origin.y -= delta.y
        p.setFrameOrigin(f.origin)
    }

    /// 面板当前全局 frame（拖动用）
    var currentFrame: CGRect? { panel?.frame }

    /// 直接定位：跟随鼠标实时坐标（1:1 跟手）
    func moveTo(x: CGFloat, y: CGFloat) {
        panel?.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func windowDidResignKey(_ notification: Notification) {
        if !suppressAutoClose && !debugHoldOpen { close(restoresFocus: false) }
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

    /// 粘贴前的焦点还原：轮询等待目标 App 真正成为前台后再回调（修复粘贴落空）。
    /// macOS 常见「首次 activate 被忽略」→ 等待过半仍未前台时再激活一次，总窗口 2.5s。
    /// completion 的 Bool = 目标是否真的到了前台；超时必须如实上报，宁可不粘也不能粘错窗口。
    private func restoreFocusAndWait(dockPreferred: Bool = false, completion: @escaping (Bool) -> Void) {
        guard let target = targetAppForRestore(dockPreferred: dockPreferred) else {
            completion(false)
            return
        }
        let session = pasteSession
        activateApp(target)
        waitUntilFrontmost(target, attempts: 50, interval: 0.05, reActivateAt: 25, target: target) { [weak self] ok in
            guard let self = self, session == self.pasteSession else { return }
            completion(ok)
        }
    }

    /// 还原目标：优先呼出面板前的 App；兜底取最靠前的普通应用（排除自己）。
    /// dockPreferred=true（弹壳 Dock）：dock 不抢焦点，previousApp 往往陈旧——
    /// 以当前前台应用为准（用户正在输入的 App 就是它），自身前台时才退回 previousApp
    private func targetAppForRestore(dockPreferred: Bool = false) -> NSRunningApplication? {
        let myPID = ProcessInfo.processInfo.processIdentifier
        if dockPreferred {
            if let f = NSWorkspace.shared.frontmostApplication,
               f.processIdentifier != myPID, f.activationPolicy == .regular {
                return f
            }
            if let prev = previousApp, prev.processIdentifier != myPID, !prev.isTerminated {
                return prev
            }
        } else if let prev = previousApp,
                  prev.processIdentifier != myPID, !prev.isTerminated {
            return prev
        }
        return NSWorkspace.shared.runningApplications.first { app in
            app.processIdentifier != myPID &&
            app.activationPolicy == .regular && !app.isTerminated
        }
    }

    private func activateApp(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
        }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    private func waitUntilFrontmost(_ app: NSRunningApplication, attempts: Int, interval: TimeInterval, reActivateAt: Int = -1, target: NSRunningApplication? = nil, done: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            done(true)
            return
        }
        if attempts <= 0 {
            done(false)   // 超时仍未到前台：如实上报（调用方放弃粘贴）
            return
        }
        if reActivateAt > 0, attempts == reActivateAt, let target = target {
            activateApp(target)   // 二次激活：突破系统忽略首次 activate 的情况
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.waitUntilFrontmost(app, attempts: attempts - 1, interval: interval,
                                     reActivateAt: reActivateAt, target: target, done: done)
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
            let pk = PanelKeyConfig.shared
            // 搜索框编辑中：字符/删除放行给输入框（Maccy 式即打即搜）；
            // 但导航/粘贴/快选/关闭仍被面板拦截，纯键盘流不中断（P/T/O 等单键动作编辑态让位于输入）
            if let fr = NSApp.keyWindow?.firstResponder, fr is NSTextView {
                if pk.matches(.close, event: event) { self.close(); return nil }
                if pk.matches(.navUp, event: event) { self.moveSelection(-1); return nil }
                if pk.matches(.navDown, event: event) { self.moveSelection(1); return nil }
                if pk.matches(.paste, event: event) { self.activateSelected(); return nil }
                if pk.matches(.quick, event: event), let n = pk.quickDigit(event) {
                    self.activate(at: n - 1)
                    return nil
                }
                return event
            }
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
            if pk.matches(.translate, event: event) { self.translateSelected(); return nil }
            if pk.matches(.ocr, event: event) { self.ocrSelected(); return nil }
            if pk.matches(.searchFocus, event: event) {
                focusSearch()
                return nil
            }
            if pk.matches(.quick, event: event), let n = pk.quickDigit(event) {
                self.activate(at: n - 1)
                return nil
            }
            return event
        }

        // 本应用内部点击在面板外 → 关闭面板并吞掉该次点击；面板内点击放行（按钮/手势）
        // 全局 ⌘F：面板可见但焦点在别的应用时，⌘F 也能拉回面板并聚焦搜索
        globalSearchMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel?.isVisible == true, !self.suppressAutoClose, !self.debugHoldOpen else { return }
            guard PanelKeyConfig.shared.matches(.searchFocus, event: event) else { return }
            DispatchQueue.main.async { self.focusSearch() }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let p = self.panel, p.isVisible else { return event }
            if !self.suppressAutoClose, !self.debugHoldOpen, !p.frame.contains(NSEvent.mouseLocation) {
                self.close(restoresFocus: false)
                return nil
            }
            return event
        }
        // 其他应用的点击 → 关闭
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let p = self.panel, p.isVisible, !self.suppressAutoClose, !self.debugHoldOpen else { return }
            if !p.frame.contains(NSEvent.mouseLocation) {
                self.close(restoresFocus: false)
            }
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = globalSearchMonitor { NSEvent.removeMonitor(m); globalSearchMonitor = nil }
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
        delete(items[index])
    }

    /// 按条目删除（闭包捕获 id 而非 index：后台新入册导致列表重排时不会删错条目）
    func delete(_ item: ClipboardItem) {
        store.remove(item.id)
        if selectedIndex >= filteredItems().count { selectedIndex = max(0, filteredItems().count - 1) }
        if filteredItems().isEmpty { selectedIndex = -1 }
        notifySelection()
        Toast.shared.show("已删除该条历史")
    }

    /// 设置/移除条目标签
    func setTag(_ tag: String?, id: String) {
        store.setTag(tag, id: id)
    }

    /// 点选：复制到剪贴板 → 还原焦点 →（可选）自动粘贴
    /// dismissAfterPaste=true（弹壳 Dock 用）：粘贴完成后隐藏 dock
    func activateDockItem(at index: Int) {
        let items = filteredItems()
        guard items.indices.contains(index) else { return }
        activate(items[index], copyOnly: false, dismissAfterPaste: true)
    }

    private func activate(_ item: ClipboardItem, copyOnly: Bool, dismissAfterPaste: Bool = false) {
        let keepOpenNow = keepOpen && !dismissAfterPaste
        if !keepOpenNow { close() }
        if dismissAfterPaste { ShellDockController.shared.hide() }

        switch item.kind {
        case .text:
            writeTextToPasteboard(item.text ?? "")
        case .image:
            guard let img = store.imageFor(item) else {
                // 读图失败绝不能继续走粘贴：否则粘出去的是剪贴板里的旧内容
                Toast.shared.showImportant("该条目已失效（源图可能已被清理）")
                return
            }
            copyImageToClipboardSuppressingMonitor(img)
        case .file:
            guard let path = item.filePath, FileManager.default.fileExists(atPath: path) else {
                Toast.shared.showImportant("该条目已失效（源文件可能已被移动或删除）")
                return
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([NSURL(fileURLWithPath: path)])
        }
        // 统一显式置顶：文本此前依赖监听回声、图片被 suppress 无从更新，行为不一致
        store.touch(item)

        let pasteAuto = UserDefaults.standard.object(forKey: "pasteAuto") as? Bool ?? true
        let doPaste = !copyOnly && pasteAuto && AXIsProcessTrusted()

        if doPaste {
            suppressAutoClose = true
            pasteSession += 1
            let session = pasteSession
            restoreFocusAndWait(dockPreferred: dismissAfterPaste) { [weak self] ok in
                guard let self = self, session == self.pasteSession else { return }
                if ok {
                    // 目标刚被激活（首次会有"跳一下"），等它恢复文本插入焦点再发 ⌘V，
                    // 否则首次粘贴会落空（用户需点两次）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        guard let self = self, session == self.pasteSession else { return }
                        simulatePaste()
                        Toast.shared.show("已粘贴到当前输入框")
                        if keepOpenNow { self.reactivatePanel() }
                        // 取放完成：清空筛选回到全量列表，便于连续取下一条
                        self.panelState.searchText = ""
                        self.panelState.filter = .all
                        self.panelState.tagFilter = nil
                        self.resetSelection()
                    }
                } else {
                    Toast.shared.showImportant("已复制 · 未能自动粘贴（目标窗口未就绪），请手动 ⌘V")
                }
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
                Toast.shared.showImportant("已复制 · 请手动 ⌘V（系统设置→隐私与安全性→辅助功能 授权后重启应用可自动粘贴）")
            } else {
                Toast.shared.show(copyOnly ? "已复制（未粘贴）" : "已复制，可手动粘贴")
            }
        }
    }

    func pin(_ item: ClipboardItem) {
        guard item.kind == .image, let img = store.imageFor(item) else { return }
        PinController.shared.pin(image: img)
        // 保留图片文件：紧接着用同一文件回插为 pinned 条目
        store.remove(item.id, keepingFile: true)
        var t = item
        t.pinned = true
        t.timestamp = Date()
        store.items.insert(t, at: 0)
        store.save()
        if selectedIndex >= filteredItems().count { selectedIndex = max(0, filteredItems().count - 1) }
        notifySelection()
        Toast.shared.show("已钉在桌面 · 双击贴图取消")
    }

    // MARK: v2.0 翻译 / OCR

    func translateSelected() {
        let items = filteredItems()
        guard items.indices.contains(selectedIndex) else {
            Toast.shared.show("请先选中一条文本")
            return
        }
        translate(items[selectedIndex])
    }

    func translate(_ item: ClipboardItem) {
        guard item.kind == .text, let text = item.text, !text.isEmpty else {
            Toast.shared.show("该条目不是文本")
            return
        }
        Toast.shared.show("翻译中…（\(TranslationService.shared.engineLabel)）")
        TranslationService.shared.translate(text) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let translated):
                    TextResultPanel.shared.show(kind: .translation, source: text, result: translated)
                case .failure(let err):
                    Toast.shared.show("翻译失败：\(err.localizedDescription)")
                }
            }
        }
    }

    func ocrSelected() {
        let items = filteredItems()
        guard items.indices.contains(selectedIndex) else {
            Toast.shared.show("请先选中一张图片")
            return
        }
        ocr(items[selectedIndex])
    }

    func ocr(_ item: ClipboardItem) {
        guard item.kind == .image, let img = store.imageFor(item) else {
            Toast.shared.show("该条目不是图片")
            return
        }
        close()
        ImageOCRController.shared.show(image: img)
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
    @FocusState private var searchFocused: Bool

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
        .background(RubickTheme.panelAurora(scheme))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(RubickTheme.panelGradientBorder(scheme), lineWidth: 0.8)
        )
        .onReceive(NotificationCenter.default.publisher(for: .panelSelectionChanged)) { _ in
            selected = HistoryPanelController.shared.selectedIndex
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelShown)) { _ in
            // 呼出即聚焦搜索框：直接输入即可筛选（Maccy/CleanClip 式）
            DispatchQueue.main.async { searchFocused = true }
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

    @State private var grabOffset: CGPoint?

    private var header: some View {
        HStack(spacing: 7) {
            ArcaneSparkle(size: 13, glow: true)
            Text("拉比克")
                .font(.system(size: 13.5, weight: .semibold, design: .serif))
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9))
                .foregroundStyle(RubickTheme.muted(scheme).opacity(0.5))
                .help("按住标题栏拖动面板")
            Text("\(store.items.count) / \(store.limit) 条")
                .font(.system(size: 10.5))
                .foregroundStyle(RubickTheme.muted(scheme))
            Spacer()
            Image(systemName: "character.bubble")
                .font(.system(size: 11))
                .foregroundStyle(RubickTheme.primary(scheme))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .nonKeyTap { HistoryPanelController.shared.translateSelected() }
                .help("翻译选中条目")
            Image(systemName: "text.viewfinder")
                .font(.system(size: 11))
                .foregroundStyle(RubickTheme.primary(scheme))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .nonKeyTap { HistoryPanelController.shared.ocrSelected() }
                .help("识别选中图片文字")
            Image(systemName: "gearshape")
                .font(.system(size: 11))
                .foregroundStyle(RubickTheme.muted(scheme))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .nonKeyTap { SettingsController.shared.show() }
                .help("设置")
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(RubickTheme.muted(scheme))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .nonKeyTap { confirmClearHistory() }
                .help("清空历史")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { _ in
                    let m = NSEvent.mouseLocation
                    if let off = grabOffset {
                        HistoryPanelController.shared.moveTo(x: m.x - off.x, y: m.y - off.y)
                    } else if let f = HistoryPanelController.shared.currentFrame {
                        grabOffset = CGPoint(x: m.x - f.minX, y: m.y - f.minY)
                    }
                }
                .onEnded { _ in grabOffset = nil }
        )
    }

    // MARK: 搜索

    private var searchField: some View {
        HStack(spacing: 6) {
            ArcaneSparkle(size: 10)
            TextField("搜索法术…", text: $panelState.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onChange(of: panelState.searchFocusRequest) { _ in
                    searchFocused = true
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(RubickTheme.surfaceHigh(scheme).opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RubickTheme.hairline(scheme), lineWidth: 0.5))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: 筛选

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(PanelState.FilterKind.allCases, id: \.rawValue) { kind in
                let active = panelState.filter == kind && panelState.tagFilter == nil
                Text(kind.label)
                    .font(.system(size: 11))
                    .nonKeyTap {
                        panelState.filter = kind
                        panelState.tagFilter = nil
                    }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(active
                                          ? RubickTheme.primary(scheme).opacity(0.07)
                                          : Color.clear))
                .overlay(Capsule().strokeBorder(active
                                                ? RubickTheme.primary(scheme)
                                                : RubickTheme.hairline(scheme), lineWidth: 1))
                .foregroundStyle(active ? RubickTheme.primary(scheme) : RubickTheme.muted(scheme))
            }
            // 用户标签 chips（有打标签的条目时出现）
            ForEach(userTags, id: \.self) { t in
                let active = panelState.tagFilter == t
                HStack(spacing: 3) {
                    Circle().fill(PanelState.tagColor(t)).frame(width: 6, height: 6)
                    Text(t)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(PanelState.tagColor(t).opacity(active ? 0.14 : 0.05)))
                .overlay(Capsule().strokeBorder(PanelState.tagColor(t).opacity(active ? 0.9 : 0.35), lineWidth: 1))
                .foregroundStyle(PanelState.tagColor(t))
                .nonKeyTap { panelState.tagFilter = active ? nil : t }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    /// 全部历史中出现过的用户标签
    private var userTags: [String] {
        Array(Set(store.items.compactMap { $0.tag })).sorted()
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
                    if let tag = item.tag {
                        HStack(spacing: 3) {
                            Circle().fill(PanelState.tagColor(tag)).frame(width: 6, height: 6)
                            Text(tag).font(.system(size: 10))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(PanelState.tagColor(tag).opacity(0.1)))
                        .foregroundStyle(PanelState.tagColor(tag))
                    }
                    Spacer()
                    Text(timeAgo(item.timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(RubickTheme.muted(scheme))
                }
                if item.kind == .text {
                    Text((item.text ?? "").prefix(4000))
                        .font(.system(size: 11.5, design: (item.text ?? "").contains("\n") ? .monospaced : .default))
                        .foregroundStyle(RubickTheme.onSurface(scheme))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if item.kind == .file {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.filePath ?? ""))
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text((item.filePath as NSString?)?.lastPathComponent ?? "（无效路径）")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(RubickTheme.onSurface(scheme))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text((item.filePath as NSString?)?.deletingLastPathComponent ?? "")
                                .font(.system(size: 10))
                                .foregroundStyle(RubickTheme.muted(scheme))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(RubickTheme.surfaceHigh(scheme).opacity(0.5)))
                } else {
                    Group {
                        if let img = store.thumbnail(for: item, maxPixel: 800) {
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
            .nonKeyTap {
                if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                    HistoryPanelController.shared.activate(at: index, copyOnly: true)
                } else {
                    HistoryPanelController.shared.activate(at: index)
                }
            }
            .contextMenu {
                if item.kind == .text {
                    Button("翻译") { HistoryPanelController.shared.translate(item) }
                } else if item.kind == .image {
                    Button("识别文字…") { HistoryPanelController.shared.ocr(item) }
                    Button("钉图") { HistoryPanelController.shared.pin(item) }
                }
                Menu("标记") {
                    ForEach(["重要", "工作", "灵感"], id: \.self) { t in
                        Button(t) { HistoryPanelController.shared.setTag(t, id: item.id) }
                    }
                    if item.tag != nil {
                        Divider()
                        Button("移除标记") { HistoryPanelController.shared.setTag(nil, id: item.id) }
                    }
                }
                Divider()
                Button("删除", role: .destructive) { HistoryPanelController.shared.delete(item) }
            }

            // 悬停操作按钮（独立命中区域；仅悬停该行时出现，保持列表安静）
            VStack(spacing: 4) {
                if item.kind == .text {
                    actionButton("character.bubble") { HistoryPanelController.shared.translate(item) }
                        .help("翻译")
                } else if item.kind == .image {
                    actionButton("text.viewfinder") { HistoryPanelController.shared.ocr(item) }
                        .help("识别文字")
                    actionButton("pin.fill") { HistoryPanelController.shared.pin(item) }
                        .help("钉图")
                } else {
                    actionButton("arrow.down.circle") {
                        if let p = item.filePath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                    }
                    .help("在 Finder 中显示")
                }
                actionButton("trash") { HistoryPanelController.shared.delete(item) }
                    .help("删除")
            }
            .opacity(hoveringIds.contains(item.id) ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hoveringIds.contains(item.id))
        }
        .padding(10)
        .spellSlot(hovering: hoveringIds.contains(item.id), selected: selected == index, cornerRadius: 8)
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
        typeChipView(item: item, isLink: item.kind == .text && PanelState.isLink(item.text ?? ""))
    }

    private func typeChipView(item: ClipboardItem, isLink: Bool) -> some View {
        let color: Color
        let label: String
        switch item.kind {
        case .text:
            color = RubickTheme.primary(scheme)
            label = isLink ? "链接" : "文本"
        case .image:
            color = .blue
            label = "图片"
        case .file:
            color = .red
            label = "文件"
        }
        return Text(label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }

    private func actionButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10))
            .foregroundStyle(RubickTheme.muted(scheme))
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(RubickTheme.surfaceContainer(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .contentShape(Rectangle())
            .nonKeyTap(perform: action)
    }

    private func selectedIsCurrent(_ symbol: String) -> Bool { false }

    // MARK: 底部状态栏

    private var footer: some View {
        VStack(spacing: 4) {
            Text(panelKeys.hintText() + " · 输入即筛选 · ⌥点=仅复制")
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
