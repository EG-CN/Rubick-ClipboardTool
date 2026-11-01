import AppKit
import ApplicationServices

/// Persist the old values so existing installations retain their chosen style.
enum ClipboardPresentation: String, CaseIterable {
    case native = "panel", dock, clothesline
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: "panel.form") ?? "panel") ?? .native }
    static func apply() {
        HistoryPanelController.shared.close()
        ShellDockController.shared.hide()
        ClotheslineController.shared.refreshStyle()
    }
    static func toggle(fromHotkey: Bool = false) {
        switch current {
        case .native: ShellDockController.shared.hide(); HistoryPanelController.shared.toggle(fromHotkey: fromHotkey)
        case .dock: HistoryPanelController.shared.close(); ShellDockController.shared.toggle()
        case .clothesline: HistoryPanelController.shared.close(); ShellDockController.shared.hide(); ClotheslineController.shared.toggle(fromHotkey: fromHotkey)
        }
    }
}

struct ClotheslineLayout {
    static func frame(screen: CGRect, visible: CGRect, expanded: Bool, cutout: CGRect? = nil) -> CGRect {
        let width: CGFloat = expanded ? max(120, visible.width - 32) : 96
        let height: CGFloat = expanded ? min(416, visible.height - 6) : 26
        let top = min(visible.maxY, cutout?.minY ?? screen.maxY) - 2
        let center = expanded ? visible.midX : (cutout?.midX ?? screen.midX)
        let x = min(max(center - width / 2, visible.minX), visible.maxX - width)
        return CGRect(x: x, y: max(visible.minY, top - height), width: width, height: height)
    }
    static func cutout(on screen: NSScreen) -> CGRect? {
        guard screen.safeAreaInsets.top > 0 else { return nil }
        let left = screen.auxiliaryTopLeftArea, right = screen.auxiliaryTopRightArea
        let start = left?.maxX ?? (screen.frame.midX - 100)
        let end = right?.minX ?? (screen.frame.midX + 100)
        return CGRect(x: start, y: screen.frame.maxY - screen.safeAreaInsets.top,
                      width: max(1, end - start), height: screen.safeAreaInsets.top)
    }
    static func cardSize(image: CGSize?, text: String?) -> CGSize {
        if let image, image.width > 0, image.height > 0 {
            let ratio = image.width / image.height
            let height = min(220, max(100, 170 / sqrt(ratio)))
            let width = min(300, max(104, height * ratio))
            return CGSize(width: width + 20, height: height + 54)
        }
        let value = String((text ?? "").prefix(600))
        let width: CGFloat = value.count < 35 ? 164 : (value.count < 120 ? 210 : 250)
        let measured = (value as NSString).boundingRect(with: CGSize(width: width - 20, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 13)])
        return CGSize(width: width, height: min(220, max(78, ceil(measured.height) + 35)) + 54)
    }
    static func pages(sizes: [CGSize], width: CGFloat) -> [Range<Int>] {
        guard !sizes.isEmpty else { return [] }
        let available = max(1, width - 32)
        var pages: [Range<Int>] = [], lower = 0, used: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let itemWidth = min(size.width, available)
            if index > lower, used + 18 + itemWidth > available {
                pages.append(lower..<index); lower = index; used = 0
            }
            used += (index == lower ? 0 : 18) + itemWidth
        }
        pages.append(lower..<sizes.count)
        return pages
    }
    static func expandsOnInvocation(hidden: Bool, visible: Bool, expanded: Bool) -> Bool {
        hidden || !visible || !expanded
    }
    static func items(_ items: [ClipboardItem]) -> [ClipboardItem] { items }
    static func isEditable(role: String?, valueSettable: Bool, explicitlyEditable: Bool) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role ?? "") || valueSettable || explicitlyEditable
    }
}

final class ClotheslinePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A non-key window preserves the actual target's first responder; no stale application bookmark is used.
final class ClotheslineController {
    static let shared = ClotheslineController()
    private var entries: [(screen: NSScreen, panel: ClotheslinePanel, view: ClotheslineView)] = []
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var suspended = false
    private var hidden = false
    private var eventMonitors: [Any] = []
    private init() {}

    func start() {
        guard timer == nil else { return }
        observers.append(NotificationCenter.default.addObserver(forName: .clipboardHistoryChanged, object: nil, queue: .main) { [weak self] _ in
            self?.entries.forEach { $0.view.reload() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshStyle() })
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in self?.handleDismissal(event) }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            self?.handleDismissal(event); return event
        }) { eventMonitors.append(monitor) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.02
        refreshStyle()
    }
    var layoutDiagnostics: [[String: Any]] {
        entries.map { entry in
            ["display": (entry.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0,
             "hasCutout": ClotheslineLayout.cutout(on: entry.screen) != nil,
             "screenFrame": NSStringFromRect(entry.screen.frame),
             "entryFrame": NSStringFromRect(entry.panel.frame),
             "expanded": entry.view.expanded]
        }
    }
    func refreshStyle() {
        entries.forEach { $0.panel.orderOut(nil) }; entries.removeAll()
        guard ClipboardPresentation.current == .clothesline else { return }
        hidden = false
        for screen in NSScreen.screens {
            let frame = ClotheslineLayout.frame(screen: screen.frame, visible: screen.visibleFrame, expanded: false, cutout: ClotheslineLayout.cutout(on: screen))
            let panel = ClotheslinePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.level = .floating; panel.hidesOnDeactivate = false; panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = ClotheslineView(frame: CGRect(origin: .zero, size: frame.size))
            view.controller = self; view.entryCenterX = (ClotheslineLayout.cutout(on: screen)?.midX ?? screen.frame.midX) - frame.minX; panel.contentView = view
            panel.isReleasedWhenClosed = false
            entries.append((screen, panel, view))
            if !suspended { panel.orderFrontRegardless() }
        }
    }
    func suspendForCapture() {
        suspended = true
        entries.forEach { $0.panel.orderOut(nil) }
    }
    func resumeAfterCapture() {
        suspended = false
        guard ClipboardPresentation.current == .clothesline, !hidden else { return }
        entries.forEach { entry in setExpanded(false, view: entry.view); entry.panel.orderFrontRegardless() }
    }
    func toggle(fromHotkey: Bool = false) {
        if entries.isEmpty { refreshStyle() }
        guard !suspended else { Toast.shared.show("请先完成或取消截图，再打开随手夹"); return }
        let entry = entries.first { $0.screen.frame.contains(NSEvent.mouseLocation) } ?? entries.first
        guard let entry else { return }
        guard !entry.view.dragging, !entry.view.receivingFiles else { return }
        let expand = ClotheslineLayout.expandsOnInvocation(hidden: hidden, visible: entry.panel.isVisible, expanded: entry.view.expanded)
        if hidden {
            for other in entries where other.panel !== entry.panel { other.panel.orderFrontRegardless() }
        }
        hidden = false
        entry.panel.orderFrontRegardless()
        setExpanded(expand, view: entry.view, feedback: true)

    }
    func hide() {
        hidden = true
        entries.forEach { entry in
            setExpanded(false, view: entry.view)
            entry.panel.orderOut(nil)
        }
    }
    func setExpanded(_ expanded: Bool, view: ClotheslineView, feedback: Bool = false, manual: Bool = true) {
        guard let entry = entries.first(where: { $0.view === view }), !view.dragging else { return }
        if manual { view.interaction.showManually(expanded) }
        if expanded {
            for other in entries where other.view !== view && other.view.expanded && !other.view.dragging {
                setExpanded(false, view: other.view)
            }
        }
        if feedback && view.expanded != expanded { InteractionHaptics.perform() }
        view.expanded = expanded
        view.reveal(expanded)
        let frame = ClotheslineLayout.frame(screen: entry.screen.frame, visible: entry.screen.visibleFrame, expanded: expanded, cutout: ClotheslineLayout.cutout(on: entry.screen))
        entry.panel.setFrame(frame, display: true)
        entry.panel.ignoresMouseEvents = false
        view.entryCenterX = (ClotheslineLayout.cutout(on: entry.screen)?.midX ?? entry.screen.frame.midX) - frame.minX
        view.frame = CGRect(origin: .zero, size: frame.size); view.needsDisplay = true
    }
    private func handleDismissal(_ event: NSEvent) {
        guard !suspended, !hidden else { return }
        let escape = event.type == .keyDown && event.keyCode == 53
        guard escape || event.type == .leftMouseDown || event.type == .rightMouseDown else { return }
        for entry in entries where entry.view.expanded {
            let view = entry.view
            guard !view.dragging, !view.receivingFiles, !view.menuOpen else { continue }
            let local = view.convert(entry.panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if escape || !entry.panel.frame.contains(NSEvent.mouseLocation) || !view.isInteractive(local) {
                setExpanded(false, view: view)
            }
        }
    }
    private func tick() {
        guard !suspended, !hidden, ClipboardPresentation.current == .clothesline else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for entry in entries {
            let view = entry.view
            if view.dragging || view.menuOpen { continue }
            view.interaction.advance(to: now)
            if view.interaction.isOpen != view.expanded {
                setExpanded(view.interaction.isOpen, view: view, feedback: view.interaction.isOpen, manual: false)
            }
            let local = view.convert(entry.panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            view.updateHover(at: local)
            entry.panel.ignoresMouseEvents = view.expanded && !view.receivingFiles && !view.isInteractive(local)
        }
    }
    func use(_ item: ClipboardItem, from view: ClotheslineView, copyOnly: Bool = false, fileSelection: [ClipboardItem] = []) {
        let target = NSWorkspace.shared.frontmostApplication
        let focused = Self.editableFocus(in: target)
        switch item.kind {
        case .text: writeTextToPasteboard(item.text ?? "")
        case .image:
            guard let image = HistoryStore.shared.imageFor(item) else { Toast.shared.showImportant("图片已失效"); return }
            writeImageToPasteboard(image)
        case .file:
            guard let urls = FileTransfer.urls(for: fileSelection.isEmpty ? [item] : fileSelection) else { Toast.shared.showImportant("源文件已移动或删除，请重新挂入"); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls.map { $0 as NSURL })
        }
        ClipboardMonitor.shared.acknowledgeCurrentWrite()
        let automatic = UserDefaults.standard.object(forKey: "pasteAuto") as? Bool ?? true
        guard !copyOnly, automatic, let target, let focused else {
            Toast.shared.show(AXIsProcessTrusted() ? "已复制 · 在输入框中按 ⌘V" : "已复制 · 开启辅助功能权限后可单击粘贴")
            return
        }
        let version = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak view] in
            guard NSPasteboard.general.changeCount == version,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  let current = Self.editableFocus(in: target), CFEqual(focused, current) else {
                Toast.shared.show("已复制 · 输入位置已变化，请手动粘贴"); return
            }
            simulatePaste()
            if let view { view.completeTaking(accepted: true) }
            // A key event cannot prove that another app accepted the payload.
            Toast.shared.show("已发送粘贴指令")
        }
    }
    private static func editableFocus(in app: NSRunningApplication?) -> AXUIElement? {
        guard AXIsProcessTrusted(), let app, !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &result) == .success,
              let result, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        let element = result as! AXUIElement
        var role: CFTypeRef?, editable: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable)
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard ClotheslineLayout.isEditable(role: role as? String, valueSettable: settable.boolValue, explicitlyEditable: (editable as? Bool) == true) else { return nil }
        return element
    }
}

final class ClotheslineView: NSView, NSDraggingSource {
    weak var controller: ClotheslineController?
    var expanded = false
    var dragging = false
    private var items: [ClipboardItem] = []
    private var start = 0
    private var cardSizes: [CGSize] = []
    private var ranges: [Range<Int>] = []
    private var frames: [CGRect] = []
    private(set) var tabPressed = false
    private var lastScroll = Date.distantPast
    private let store: HistoryStore
    private var pressed: ClipboardItem?
    private var downPoint = CGPoint.zero
    private var beganDrag = false
    private var pins: [String: NSPanel] = [:]
    private var selectedFiles = Set<String>()
    var interaction = PhotoWallInteraction()
    var entryCenterX: CGFloat?
    var receivingFiles: Bool { interaction.incoming }
    private var receiptCount = 0
    private var hoveredID: String?
    private var hoverClipID: String?
    private var hoverTracking: NSTrackingArea?
    private var undoDeletion: (() -> Void)?
    private var undoTimer: Timer?
    private var revealTimer: Timer?
    private var revealAlpha: CGFloat = 1
    private var hoverTimer: Timer?
    private var shade: [String: CGFloat] = [:]
    private var outlineAlpha: [String: CGFloat] = [:]

    deinit { hoverTimer?.invalidate(); undoTimer?.invalidate(); revealTimer?.invalidate() }

    func completeTaking(accepted: Bool) {
        receiptCount = 0
        interaction.finishTaking(accepted: accepted, at: ProcessInfo.processInfo.systemUptime)
        needsDisplay = true
    }
    func reveal(_ expanded: Bool) {
        revealTimer?.invalidate(); revealTimer = nil; revealAlpha = 1
        guard expanded, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { needsDisplay = true; return }
        revealAlpha = 0
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.18)
            self.revealAlpha = CGFloat(1 - pow(1 - t, 3)); self.needsDisplay = true
            if t >= 1 { timer.invalidate(); self.revealTimer = nil }
        }
        revealTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func animateHover() {
        hoverTimer?.invalidate()
        let ids = shown.map(\.id)
        let fromShade = shade, fromOutline = outlineAlpha
        let target = hoveredID
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.0 : 0.16
        let began = ProcessInfo.processInfo.systemUptime
        let update: (Double) -> Void = { [weak self] now in
            guard let self else { return }
            let t = duration == 0 ? 1 : min(1, (now - began) / duration)
            let eased = CGFloat(t * t * (3 - 2 * t))
            for id in ids {
                let dim: CGFloat = target != nil && target != id ? 0.30 : 0
                let border: CGFloat = target == id ? 1 : 0
                self.shade[id] = (fromShade[id] ?? 0) + (dim - (fromShade[id] ?? 0)) * eased
                self.outlineAlpha[id] = (fromOutline[id] ?? 0) + (border - (fromOutline[id] ?? 0)) * eased
            }
            self.needsDisplay = true
            if t >= 1 { self.hoverTimer?.invalidate(); self.hoverTimer = nil }
        }
        if duration == 0 { update(began); return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in update(ProcessInfo.processInfo.systemUptime) }
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area); hoverTracking = area
    }
    func updateHover(at point: CGPoint) {
        guard !dragging else { return }
        let hint: String
        if !expanded { hint = "点击展开照片墙 · 拖文件到这里暂存" }
        else if entryRect.contains(point) { hint = "点击收起照片墙 · Esc 也可收起" }
        else if shown.indices.contains(where: { clipRect($0).contains(point) }) { hint = "移除此记录 · 5 秒内可撤销" }
        else if shown.indices.contains(where: { shown[$0].kind == .file && cardRect($0).contains(point) }) { hint = "拖入其他应用使用 · ⌘点击多选文件" }
        else if undoDeletion != nil && undoRect.contains(point) { hint = "撤销刚才的移除操作" }
        else if moreRect.contains(point) { hint = "更多选项：设置、隐藏入口和操作提示" }
        else if allRect.contains(point) { hint = "打开完整历史记录并搜索" }
        else if toggleRect.contains(point) { hint = "收回到刘海下沿 · 点击或快捷键展开" }
        else { hint = "单击粘贴 · 拖入使用 · ⌥点击仅复制" }
        if toolTip != hint { toolTip = hint }
        let clip = expanded ? shown.enumerated().first(where: { clipRect($0.offset).contains(point) })?.element.id : nil
        if clip != hoverClipID { hoverClipID = clip; needsDisplay = true }
        let id = expanded ? shown.enumerated().first(where: { cardRect($0.offset).contains(point) || clipRect($0.offset).contains(point) })?.element.id : nil
        guard id != hoveredID else { return }
        hoveredID = id; animateHover()
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        (entryRect.contains(point) ? NSCursor.pointingHand : NSCursor.arrow).set()
        updateHover(at: point)
    }
    override func mouseExited(with event: NSEvent) { updateHover(at: CGPoint(x: -1, y: -1)) }
    private let green = NSColor(calibratedRed: 0.14, green: 0.52, blue: 0.36, alpha: 1)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(frame: NSRect, store: HistoryStore = .shared) { self.store = store; super.init(frame: frame); registerForDraggedTypes([.fileURL]); reload() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var capacity: Int { shown.count }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); reflow() }
    private func reflow() {
        ranges = ClotheslineLayout.pages(sizes: cardSizes, width: bounds.width)
        let range = ranges.first { $0.contains(start) } ?? ranges.first
        start = range?.lowerBound ?? 0
        frames = []
        var x: CGFloat = 16
        for index in range ?? 0..<0 {
            let size = cardSizes[index]
            let width = min(size.width, max(1, bounds.width - 32))
            let t = (x + width / 2) / max(1, bounds.width)
            let top = 54 + 48 * t * (1 - t)
            frames.append(CGRect(x: x, y: top, width: width, height: min(size.height, max(100, bounds.height - top - 45))))
            x += width + 18
        }
        needsDisplay = true
    }
    func reload() {
        guard !dragging else { return }
        let updated = ClotheslineLayout.items(store.items)
        if updated.first?.id != items.first?.id { start = 0 }
        items = updated
        selectedFiles.formIntersection(Set(items.filter { $0.kind == .file }.map(\.id)))
        hoveredID = nil
        hoverTimer?.invalidate(); hoverTimer = nil; shade.removeAll(); outlineAlpha.removeAll()
        cardSizes = items.map { item in
            let image: CGSize? = item.kind == .image ? {
                if let w = item.metaWidth, let h = item.metaHeight { return CGSize(width: w, height: h) }
                return store.thumbnail(for: item, maxPixel: 64)?.size
            }() : nil
            if item.kind == .file { return CGSize(width: 186, height: 196) }
            return ClotheslineLayout.cardSize(image: image, text: item.text)
        }
        reflow()
        pins = pins.filter { $0.value.isVisible }
        needsDisplay = true
    }
    private var shown: [ClipboardItem] {
        guard let range = ranges.first(where: { $0.lowerBound == start }) else { return [] }
        return Array(items[range])
    }
    private var entryRect: CGRect { CGRect(x: (entryCenterX ?? bounds.midX) - 48, y: 0, width: 96, height: 26) }
    private func cardRect(_ i: Int) -> CGRect { frames[i] }
    private func clipRect(_ i: Int) -> CGRect { let r = cardRect(i); return CGRect(x: r.midX - 12, y: r.minY - 22, width: 24, height: 36) }
    private func pinRect(_ i: Int) -> CGRect {
        let card = cardRect(i)
        return CGRect(x: card.maxX - 65, y: card.maxY - 29, width: 59, height: 25)
    }
    private var toolbarRect: CGRect {
        let width = min(408, bounds.width - 24)
        let reserve: CGFloat = 46
        let y = min(bounds.height - reserve, max(110, (frames.map(\.maxY).max() ?? 90) + 16))
        return CGRect(x: bounds.midX - width / 2, y: y, width: width, height: 40)
    }
    private var previousRect: CGRect { CGRect(x: toolbarRect.minX + 6, y: toolbarRect.minY + 4, width: 32, height: 32) }
    private var nextRect: CGRect { previousRect.offsetBy(dx: 146, dy: 0) }
    private var allRect: CGRect { CGRect(x: toolbarRect.minX + 199, y: toolbarRect.minY + 4, width: 78, height: 32) }
    private var moreRect: CGRect { CGRect(x: toolbarRect.minX + 281, y: toolbarRect.minY + 4, width: 42, height: 32) }
    private var toggleRect: CGRect { CGRect(x: toolbarRect.maxX - 76, y: toolbarRect.minY + 4, width: 70, height: 32) }
    private var undoRect: CGRect { CGRect(x: toolbarRect.minX + 110, y: toolbarRect.minY + 4, width: 68, height: 32) }
    private var pageIndex: Int { ranges.firstIndex(where: { $0.lowerBound == start }) ?? 0 }
    private(set) var menuOpen = false
    func isInteractive(_ point: CGPoint) -> Bool {
        !expanded || toolbarRect.contains(point) || (undoDeletion != nil && undoRect.contains(point)) ||
        entryRect.contains(point) || shown.indices.contains { cardRect($0).contains(point) || clipRect($0).contains(point) }
    }
    private func changePage(_ delta: Int) {
        guard !ranges.isEmpty else { return }
        let next = min(max(0, pageIndex + delta), ranges.count - 1)
        start = ranges[next].lowerBound; reflow()
        hoveredID = nil
        hoverTimer?.invalidate(); hoverTimer = nil; shade.removeAll(); outlineAlpha.removeAll()
        needsDisplay = true
    }
    private func drawToolbar() {
        let rect = toolbarRect
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 12; shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.14); shadow.set()
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        let outline = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14); outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke(); outline.lineWidth = 0.5; outline.stroke()
        func action(_ title: String, _ box: CGRect, enabled: Bool = true) {
            label(title, in: box.insetBy(dx: 7, dy: 8), size: 12, color: enabled ? .labelColor : .tertiaryLabelColor)
        }
        func symbol(_ name: String, in box: CGRect, enabled: Bool = true) {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [enabled ? NSColor.labelColor : .tertiaryLabelColor])) {
                let scale = min(13 / max(image.size.width, 1), 13 / max(image.size.height, 1))
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        if undoDeletion != nil {
            label("已删除", in: CGRect(x: rect.minX + 16, y: rect.minY + 12, width: 66, height: 20), color: .secondaryLabelColor)
            label("撤销", in: CGRect(x: rect.minX + 118, y: rect.minY + 12, width: 50, height: 20), color: green, bold: true)
        } else {
            symbol("chevron.left", in: previousRect, enabled: pageIndex > 0)
            symbol("chevron.right", in: nextRect, enabled: pageIndex + 1 < ranges.count)
            let count = selectedFiles.count > 1 ? "已选 \(selectedFiles.count) 个文件" : (items.isEmpty ? "暂无记录" : "\(start + 1)–\(start + capacity) / \(items.count)")
            label(count, in: CGRect(x: rect.minX + 47, y: rect.minY + 13, width: 101, height: 20), size: 11, color: .secondaryLabelColor)
        }
        let divider = NSBezierPath(); divider.move(to: CGPoint(x: rect.minX + 190, y: rect.minY + 11)); divider.line(to: CGPoint(x: rect.minX + 190, y: rect.maxY - 11))
        NSColor.separatorColor.setStroke(); divider.lineWidth = 0.6; divider.stroke()
        symbol("clock.arrow.circlepath", in: CGRect(x: allRect.minX + 3, y: allRect.minY, width: 20, height: 32))
        action("历史", allRect.offsetBy(dx: 18, dy: 0))
        symbol("ellipsis", in: moreRect)
        action("收起", toggleRect)
        symbol("chevron.up", in: CGRect(x: toggleRect.maxX - 22, y: toggleRect.minY, width: 18, height: 32))

    }
    private func showMoreMenu(with event: NSEvent) {
        interaction.showManually(true)
        menuOpen = true
        defer { menuOpen = false }
        let menu = NSMenu()
        let settings = NSMenuItem(title: "打开设置…", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        settings.target = self; menu.addItem(settings)
        let help = NSMenuItem(title: "操作提示", action: #selector(showUsage), keyEquivalent: "")
        help.target = self; menu.addItem(help)
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏随手夹入口", action: #selector(hideFromMenu), keyEquivalent: "")
        hide.target = self; menu.addItem(hide)
        let hint = NSMenuItem(title: "\(HotkeyManager.shared.panelShortcutDisplay) 可重新显示", action: nil, keyEquivalent: ""); hint.isEnabled = false; menu.addItem(hint)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func showUsage() { Toast.shared.showImportant("入口：点击或快捷键展开，点外部或 Esc 收起。拖文件停留后展开接收；拖出取消时保持打开。卡片夹子：移除记录。") }
    @objc private func openSettingsFromMenu() { controller?.setExpanded(false, view: self); SettingsController.shared.show() }
    @objc private func hideFromMenu() { controller?.hide(); Toast.shared.show("随手夹入口已隐藏 · \(HotkeyManager.shared.panelShortcutDisplay) 可显示") }
    private func label(_ text: String, in rect: CGRect, size: CGFloat = 12, color: NSColor = .labelColor, bold: Bool = false, wrap: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .medium : .regular), .foregroundColor: color, .paragraphStyle: paragraph])
    }
    /// Small spring photo clip: a rear jaw, a narrower front jaw and a metal hinge.
    private func drawPhotoClip(in rect: CGRect, dim: CGFloat = 0) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / 12, yBy: rect.height / 36)
        transform.concat()
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(calibratedRed: r * (1 - dim), green: g * (1 - dim), blue: b * (1 - dim), alpha: 1)
        }
        let back = NSBezierPath()
        back.move(to: CGPoint(x: 3, y: 0)); back.line(to: CGPoint(x: 10, y: 1))
        back.line(to: CGPoint(x: 12, y: 33)); back.line(to: CGPoint(x: 8, y: 36))
        back.line(to: CGPoint(x: 2, y: 34)); back.close()
        color(0.09, 0.33, 0.24).setFill(); back.fill()
        let front = NSBezierPath()
        front.move(to: CGPoint(x: 1, y: 1)); front.line(to: CGPoint(x: 8, y: 2))
        front.line(to: CGPoint(x: 9, y: 33)); front.line(to: CGPoint(x: 1, y: 32)); front.close()
        color(0.22, 0.53, 0.40).setFill(); front.fill()
        let edge = NSBezierPath(); edge.move(to: CGPoint(x: 3, y: 5)); edge.line(to: CGPoint(x: 3, y: 28))
        edge.lineWidth = 0.7; color(0.45, 0.68, 0.55).setStroke(); edge.stroke()
        let spring = NSBezierPath(); spring.move(to: CGPoint(x: 0, y: 17)); spring.line(to: CGPoint(x: 10, y: 17))
        spring.move(to: CGPoint(x: 0, y: 19)); spring.line(to: CGPoint(x: 10, y: 19))
        spring.lineWidth = 1; color(0.60, 0.67, 0.63).setStroke(); spring.stroke()
        color(0.78, 0.82, 0.79).setFill(); NSBezierPath(ovalIn: CGRect(x: 3, y: 16, width: 4, height: 4)).fill()
        color(0.30, 0.41, 0.35).setFill(); NSBezierPath(ovalIn: CGRect(x: 4.5, y: 17.5, width: 1, height: 1)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func draw(_ dirtyRect: NSRect) {
        let entry = entryRect
        let hover = window.map { entry.contains(convert($0.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)) } ?? false
        NSColor(calibratedWhite: hover || receivingFiles ? 0.16 : 0.09, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: entry, xRadius: 9, yRadius: 9).fill()
        drawPhotoClip(in: CGRect(x: entry.minX + 10, y: 3, width: 7, height: 20))
        let title = interaction.phase == .receipt && receiptCount > 0 ? "✓ 收下 \(receiptCount)" : "随手夹 \(items.count > 99 ? "99+" : "\(items.count)")"
        label(title, in: CGRect(x: entry.minX + 26, y: 7, width: 68, height: 17), size: 11, color: NSColor(calibratedRed: 0.63, green: 0.88, blue: 0.72, alpha: 1))
        if !expanded { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(revealAlpha)
        let rope = NSBezierPath(); rope.move(to: CGPoint(x: 6, y: 44)); rope.curve(to: CGPoint(x: bounds.width - 6, y: 44), controlPoint1: CGPoint(x: bounds.width * 0.35, y: 60), controlPoint2: CGPoint(x: bounds.width * 0.65, y: 60)); rope.lineWidth = 2.4
        NSColor(calibratedRed: 0.59, green: 0.55, blue: 0.45, alpha: 1).setStroke(); rope.stroke()
        let thread = rope.copy() as! NSBezierPath
        thread.lineWidth = 0.9; thread.setLineDash([2, 3], count: 2, phase: 0)
        NSColor(calibratedRed: 0.88, green: 0.84, blue: 0.74, alpha: 1).setStroke(); thread.stroke()
        for x in [CGFloat(6), bounds.width - 6] {
            green.setFill(); NSBezierPath(ovalIn: CGRect(x: x - 2, y: 42, width: 4, height: 4)).fill()
        }
        for (i, item) in shown.enumerated() {
            let rect = cardRect(i)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowBlurRadius = 8; shadow.shadowOffset = NSSize(width: 0, height: -3); shadow.shadowColor = NSColor.black.withAlphaComponent(0.17); shadow.set()
            NSColor(calibratedRed: 0.99, green: 0.985, blue: 0.97, alpha: 1).setFill(); NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            let content = CGRect(x: rect.minX + 10, y: rect.minY + 10, width: rect.width - 20, height: rect.height - 54)
            NSColor(calibratedWhite: 0.94, alpha: 1).setFill(); content.fill()
            if item.kind == .image, let image = store.thumbnail(for: item, maxPixel: 320) {
                let scale = min(content.width / max(image.size.width, 1), content.height / max(image.size.height, 1))
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: content.midX - size.width / 2, y: content.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else if item.kind == .file {
                let filename = FileTransfer.filename(item)
                let exists = item.filePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                let icon = item.filePath.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSImage(size: CGSize(width: 64, height: 64))
                icon.draw(in: CGRect(x: content.midX - 26, y: content.minY + 8, width: 52, height: 52), from: .zero, operation: .sourceOver, fraction: exists ? 1 : 0.35, respectFlipped: true, hints: nil)
                label(filename, in: CGRect(x: content.minX + 5, y: content.minY + 67, width: content.width - 10, height: 46), size: 12, color: NSColor(calibratedWhite: 0.18, alpha: 1), wrap: true)
                let kind = URL(fileURLWithPath: item.filePath ?? "").pathExtension.uppercased()
                label(exists ? (kind.isEmpty ? "文件" : kind) : "源文件已移动或删除", in: CGRect(x: content.minX + 5, y: content.maxY - 20, width: content.width - 10, height: 18), size: 10, color: exists ? green : .systemRed)
            } else if item.kind == .text {
                label("Aa  文字", in: CGRect(x: content.minX, y: content.minY, width: content.width, height: 18), color: green, bold: true)
                label(String((item.text ?? "").prefix(600)), in: CGRect(x: content.minX, y: content.minY + 23, width: content.width, height: max(20, content.height - 27)), size: 13, color: NSColor(calibratedWhite: 0.18, alpha: 1), wrap: true)
            }
            label(item.kind == .image ? "图片" : (item.kind == .file ? "文件 · ⌘点击多选" : "文字 · 点按粘贴"), in: CGRect(x: rect.minX + 8, y: rect.maxY - 22, width: rect.width - 16, height: 18), size: 11, color: NSColor(calibratedWhite: 0.48, alpha: 1))
            if item.kind == .image {
                let button = pinRect(i)
                let pinned = pins[item.id]?.isVisible == true
                green.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: button, xRadius: 6, yRadius: 6).fill()
                if let icon = NSImage(systemSymbolName: pinned ? "pin.slash" : "pin", accessibilityDescription: pinned ? "收回贴图" : "钉图")?.withSymbolConfiguration(.init(paletteColors: [green])) {
                    icon.draw(in: CGRect(x: button.minX + 6, y: button.minY + 6, width: 13, height: 13), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                label(pinned ? "收回" : "钉图", in: CGRect(x: button.minX + 23, y: button.minY + 5, width: 32, height: 18), size: 12, color: green)
            }
            let clip = clipRect(i).insetBy(dx: 6, dy: 0)
            let dim = shade[item.id] ?? 0
            if dim > 0 {
                NSColor.black.withAlphaComponent(dim).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()

            }
            if item.kind == .file, selectedFiles.contains(item.id) {
                green.withAlphaComponent(0.10).setFill(); NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                green.setFill(); NSBezierPath(ovalIn: CGRect(x: rect.maxX - 23, y: rect.minY + 4, width: 18, height: 18)).fill()
                label("✓", in: CGRect(x: rect.maxX - 20, y: rect.minY + 5, width: 15, height: 17), size: 11, color: .white)
                green.setStroke(); let selection = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 4, yRadius: 4); selection.lineWidth = 1.5; selection.stroke()
            }
            let alpha = outlineAlpha[item.id] ?? 0
            if alpha > 0 {
                green.withAlphaComponent(alpha).setStroke()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 6, yRadius: 6)
                outline.lineWidth = 2; outline.stroke()
            }
            drawPhotoClip(in: clip, dim: shade[item.id] ?? 0)
            if hoverClipID == item.id {
                let badge = CGRect(x: clip.maxX + 5, y: clip.minY + 3, width: 45, height: 24)
                NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
                NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
                label("移除", in: badge.insetBy(dx: 8, dy: 5), size: 11, color: .systemRed)
            }
        }
        if items.isEmpty { label("截图、复制文字或拖入文件，就会挂到这里", in: CGRect(x: 28, y: 70, width: bounds.width - 56, height: 40), size: 15, color: .secondaryLabelColor) }
        if receivingFiles {
            green.withAlphaComponent(0.10).setFill(); bounds.fill()
            label("松手挂入文件", in: CGRect(x: bounds.midX - 90, y: bounds.height - 78, width: 180, height: 28), size: 15, color: green, bold: true)
        }
        drawToolbar()
        NSGraphicsContext.restoreGraphicsState()
    }
    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil); beganDrag = false; pressed = nil
        tabPressed = !expanded || entryRect.contains(downPoint)
        if expanded { pressed = shown.enumerated().first(where: { cardRect($0.offset).contains(downPoint) && !clipRect($0.offset).contains(downPoint) && !($0.element.kind == .image && pinRect($0.offset).contains(downPoint)) })?.element }
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; tabPressed = false }
        guard !beganDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) < 6 else { return }
        if !expanded || entryRect.contains(point) || toggleRect.contains(point) {
            controller?.setExpanded(!expanded, view: self, feedback: true); return
        }
        if undoDeletion != nil, undoRect.contains(point) {
            let undo = undoDeletion; undoDeletion = nil; undoTimer?.invalidate(); undoTimer = nil
            undo?(); needsDisplay = true
            return
        }
        if undoDeletion == nil, previousRect.contains(point) { changePage(-1); return }
        if undoDeletion == nil, nextRect.contains(point) { changePage(1); return }
        if moreRect.contains(point) { showMoreMenu(with: event); return }
        if allRect.contains(point) { controller?.setExpanded(false, view: self); HistoryPanelController.shared.show(fromHotkey: true); return }
        for (i, item) in shown.enumerated() {
            if clipRect(i).contains(point) {
                undoTimer?.invalidate()
                InteractionHaptics.perform(.generic)
                undoDeletion = store.removeUndoable(item.id)
                undoTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                    self?.undoDeletion = nil; self?.needsDisplay = true
                }
                needsDisplay = true
                return
            }
            if item.kind == .image, pinRect(i).contains(point) {
                if let pin = pins.removeValue(forKey: item.id), pin.isVisible { PinController.shared.close(pin) }
                else if let image = store.imageFor(item) { pins[item.id] = PinController.shared.pin(image: image); Toast.shared.show("已钉图 · 点「收回」可关闭贴图") }
                needsDisplay = true
                return
            }
        }
        if let pressed {
            if pressed.kind == .file, event.modifierFlags.contains(.command) {
                if selectedFiles.contains(pressed.id) { selectedFiles.remove(pressed.id) } else { selectedFiles.insert(pressed.id) }
                needsDisplay = true; return
            }
            let group = pressed.kind == .file && selectedFiles.contains(pressed.id) ? items.filter { selectedFiles.contains($0.id) } : []
            selectedFiles.removeAll(); needsDisplay = true
            controller?.use(pressed, from: self, copyOnly: event.modifierFlags.contains(.option), fileSelection: group)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if tabPressed {
            let point = convert(event.locationInWindow, from: nil)
            if hypot(point.x - downPoint.x, point.y - downPoint.y) >= 6 { beganDrag = true }
            return  // The notch entry is fixed; dragging it never moves or toggles it.
        }
        guard !beganDrag, let item = pressed else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - downPoint.x, p.y - downPoint.y) >= 6 else { return }
        if item.kind == .file {
            let selected = selectedFiles.contains(item.id) ? items.filter { selectedFiles.contains($0.id) } : [item]
            guard let urls = FileTransfer.urls(for: selected) else {
                Toast.shared.showImportant("选中的文件有已移动或删除的项目，请重新挂入后再拖出")
                return
            }
            let transfers = urls.enumerated().map { index, url -> NSDraggingItem in
                let drag = NSDraggingItem(pasteboardWriter: url as NSURL)
                drag.setDraggingFrame(CGRect(x: p.x - 32 + CGFloat(index) * 3, y: p.y - 32 + CGFloat(index) * 3, width: 64, height: 64), contents: NSWorkspace.shared.icon(forFile: url.path))
                return drag
            }
            beganDrag = true; dragging = true; interaction.startTaking()
            let session = beginDraggingSession(with: transfers, event: event, source: self)
            session.draggingFormation = .stack
            return
        }
        let writer: NSPasteboardWriting
        let preview: NSImage
        if item.kind == .image {
            guard let image = store.imageFor(item), let name = item.imageFile else { return }
            // File URL supports chat attachments; PNG/TIFF also support rich document editors.
            let payload = NSPasteboardItem()
            payload.setString(store.imagesDir.appendingPathComponent(name).absoluteString, forType: .fileURL)
            if let png = image.pngData() { payload.setData(png, forType: .png) }
            if let tiff = image.tiffRepresentation { payload.setData(tiff, forType: .tiff) }
            writer = payload; preview = store.thumbnail(for: item, maxPixel: 320) ?? image
        } else {
            writer = (item.text ?? "") as NSString
            preview = NSImage(size: NSSize(width: 144, height: 80), flipped: false) { rect in
                NSColor.windowBackgroundColor.setFill(); rect.fill()
                (String((item.text ?? "").prefix(80)) as NSString).draw(in: rect.insetBy(dx: 8, dy: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]); return true
            }
        }
        let drag = NSDraggingItem(pasteboardWriter: writer)
        drag.setDraggingFrame(CGRect(x: p.x - 70, y: p.y - 40, width: 140, height: 90), contents: preview)
        beganDrag = true; dragging = true; interaction.startTaking()
        beginDraggingSession(with: [drag], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false; pressed = nil; reload()
        completeTaking(accepted: operation != [])
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !(sender.draggingSource is ClotheslineView), !FileTransfer.files(from: sender.draggingPasteboard).isEmpty else { return [] }
        interaction.enterDrop(at: ProcessInfo.processInfo.systemUptime); needsDisplay = true
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard receivingFiles else { return [] }
        interaction.enterDrop(at: ProcessInfo.processInfo.systemUptime)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        interaction.leaveDrop(at: ProcessInfo.processInfo.systemUptime); needsDisplay = true
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { receivingFiles }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = FileTransfer.files(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { interaction.cancelDrop(); return false }
        InteractionHaptics.perform(.levelChange)
        let count = store.addFiles(urls.map(\.path), sourceApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        guard count > 0 else { interaction.cancelDrop(); return false }
        receiptCount = count
        interaction.received(at: ProcessInfo.processInfo.systemUptime)
        controller?.setExpanded(true, view: self, manual: false)
        reload()
        Toast.shared.show("已暂存 \(count) 个文件")
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { needsDisplay = true }

    override func scrollWheel(with event: NSEvent) {
        guard Date().timeIntervalSince(lastScroll) > 0.18 else { return }
        lastScroll = Date()
        guard expanded, !dragging, abs(event.scrollingDeltaY) > 1 || abs(event.scrollingDeltaX) > 1 else { return }
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        changePage(delta < 0 ? 1 : -1)
    }
}
