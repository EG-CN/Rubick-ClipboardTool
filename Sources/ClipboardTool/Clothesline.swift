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
    /// 挂绳面板：宽约 62% 屏（上限 1080），贴屏幕上缘水平居中。
    /// 收起分支（96×26）仅为 ClotheslinePreview 兼容保留，运行时不再有常驻入口。
    static func frame(screen: CGRect, visible: CGRect, expanded: Bool, cutout: CGRect? = nil) -> CGRect {
        let width = expanded ? min(1080, max(560, visible.width * 0.62)) : 96
        let height = expanded ? min(420, visible.height - 8) : 26
        let top = visible.maxY - 4
        let x = min(max(visible.midX - width / 2, visible.minX), visible.maxX - width)
        return CGRect(x: x, y: max(visible.minY, top - height), width: width, height: height)
    }
    /// 诊断与外接屏验证用；布局本身不再避让刘海。
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
    /// 连续挂绳：内容总宽（卡片 + 间距 + 两端留白）。
    static func railWidth(widths: [CGFloat], gap: CGFloat = 18, margin: CGFloat = 16) -> CGFloat {
        guard !widths.isEmpty else { return 0 }
        return margin + widths.reduce(0, +) + gap * CGFloat(widths.count - 1) + margin
    }
    /// 卡片沿绳排布：x 随滚动偏移平移，y 跟随悬链下垂弧度。
    static func railFrames(sizes: [CGSize], offset: CGFloat, boundsWidth: CGFloat, gap: CGFloat = 18, margin: CGFloat = 16) -> [CGRect] {
        let content = railWidth(widths: sizes.map(\.width), gap: gap, margin: margin)
        let maxOffset = max(0, content - boundsWidth)
        let clamped = min(max(0, offset), maxOffset)
        var frames: [CGRect] = []
        var x = margin
        for size in sizes {
            let railX = x + size.width / 2
            let t = content > 1 ? railX / content : 0.5
            let top = 54 + 48 * t * (1 - t)
            frames.append(CGRect(x: x - clamped, y: top, width: size.width, height: size.height))
            x += size.width + gap
        }
        return frames
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
    private var lastItemCount = 0
    private init() {}

    func start() {
        guard timer == nil else { return }
        lastItemCount = ClotheslineLayout.items(HistoryStore.shared.items).count
        observers.append(NotificationCenter.default.addObserver(forName: .clipboardHistoryChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let count = ClotheslineLayout.items(HistoryStore.shared.items).count
            let grew = count > self.lastItemCount
            self.lastItemCount = count
            self.entries.forEach { $0.view.reload() }
            // 有内容才垂下：新增暂存内容时绳子在鼠标所在屏幕垂下。
            if grew, ClipboardPresentation.current == .clothesline, !self.suspended {
                self.presentAtMouse()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshStyle() })
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in self?.handleDismissal(event) }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            self?.handleDismissal(event); return event
        }) { eventMonitors.append(monitor) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.008
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
        for screen in NSScreen.screens {
            let frame = ClotheslineLayout.frame(screen: screen.frame, visible: screen.visibleFrame, expanded: false)
            let panel = ClotheslinePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.level = .floating; panel.hidesOnDeactivate = false; panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = ClotheslineView(frame: CGRect(origin: .zero, size: frame.size))
            view.controller = self; panel.contentView = view
            panel.isReleasedWhenClosed = false
            entries.append((screen, panel, view))
            // 不再常驻：有内容或快捷键调用时才显示。
        }
    }
    func suspendForCapture() {
        suspended = true
        entries.forEach { $0.panel.orderOut(nil) }
    }
    func resumeAfterCapture() {
        suspended = false
        guard ClipboardPresentation.current == .clothesline, !hidden else { return }
        entries.forEach { if $0.view.expanded { $0.panel.orderFrontRegardless() } }
    }
    func toggle(fromHotkey: Bool = false) {
        if entries.isEmpty { refreshStyle() }
        guard !suspended else { Toast.shared.show("请先完成或取消截图，再打开随手夹"); return }
        let entry = entries.first { $0.screen.frame.contains(NSEvent.mouseLocation) } ?? entries.first
        guard let entry, !entry.view.dragging, !entry.view.receivingFiles else { return }
        if entry.view.expanded {
            hide()
        } else {
            hidden = false
            for other in entries where other.view !== entry.view && other.view.expanded {
                setExpanded(false, view: other.view)
            }
            setExpanded(true, view: entry.view, feedback: true)
        }
    }
    private func presentAtMouse() {
        if entries.isEmpty { refreshStyle() }
        guard ClipboardPresentation.current == .clothesline, !suspended else { return }
        let entry = entries.first { $0.screen.frame.contains(NSEvent.mouseLocation) } ?? entries.first
        guard let entry, !entry.view.dragging, !entry.view.receivingFiles else { return }
        hidden = false
        setExpanded(true, view: entry.view, feedback: true)
    }
    func hide() {
        hidden = true
        entries.forEach { entry in
            if entry.view.expanded { setExpanded(false, view: entry.view) }
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
        if feedback && view.expanded != expanded { InteractionHaptics.perform(expanded ? .alignment : .levelChange) }
        view.expanded = expanded
        view.reveal(expanded)
        let frame = ClotheslineLayout.frame(screen: entry.screen.frame, visible: entry.screen.visibleFrame, expanded: expanded)
        if expanded {
            entry.panel.setFrame(frame, display: true)
            entry.panel.orderFrontRegardless()
        } else {
            entry.panel.orderOut(nil)
        }
        view.frame = CGRect(origin: .zero, size: frame.size); view.needsDisplay = true
    }
    private func handleDismissal(_ event: NSEvent) {
        guard !suspended, !hidden else { return }
        let escape = event.type == .keyDown && event.keyCode == 53
        guard escape || event.type == .leftMouseDown || event.type == .rightMouseDown else { return }
        for entry in entries where entry.view.expanded {
            let view = entry.view
            guard !view.dragging, !view.receivingFiles, !view.menuOpen else { continue }
            // 面板内的右键是呼出上下文菜单，不算收起。
            if event.type == .rightMouseDown, entry.panel.frame.contains(NSEvent.mouseLocation) { continue }
            let local = view.convert(entry.panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if escape || !entry.panel.frame.contains(NSEvent.mouseLocation) || !view.isInteractive(local) {
                setExpanded(false, view: view)
            }
        }
    }
    private func tick() {
        guard !suspended, ClipboardPresentation.current == .clothesline else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for entry in entries {
            let view = entry.view
            if view.dragging || view.menuOpen { continue }
            view.interaction.advance(to: now)
            if view.interaction.isOpen != view.expanded {
                setExpanded(view.interaction.isOpen, view: view, manual: false)
            }
            guard view.expanded, entry.panel.isVisible else { continue }
            let local = view.convert(entry.panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            view.advanceSway(at: local, now: now)
            view.updateHover(at: local)
            entry.panel.ignoresMouseEvents = !view.receivingFiles && !view.isInteractive(local)
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
    private var cardSizes: [CGSize] = []
    private var frames: [CGRect] = []
    private var contentWidth: CGFloat = 0
    private var scrollOffset: CGFloat = 0
    private var maxOffset: CGFloat = 0
    private var lastScroll = Date.distantPast
    private let store: HistoryStore
    private var pressed: ClipboardItem?
    private var downPoint = CGPoint.zero
    private var beganDrag = false
    private var panStart: CGPoint?
    private var panOffset: CGFloat = 0
    private var pins: [String: NSPanel] = [:]
    private var selectedFiles = Set<String>()
    var interaction = PhotoWallInteraction()
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
    private var wind: [String: CGFloat] = [:]
    private var tilt: [String: CGFloat] = [:]
    private var swayPhase: [String: Double] = [:]
    private var counterText = ""
    private var counterAlpha: CGFloat = 0
    private var counterTimer: Timer?

    deinit { hoverTimer?.invalidate(); undoTimer?.invalidate(); revealTimer?.invalidate(); counterTimer?.invalidate() }

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
        let ids = items.map(\.id)
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
        if undoDeletion != nil && undoRect.contains(point) { hint = "撤销刚才的移除操作" }
        else if items.indices.contains(where: { clipRect($0).contains(point) }) { hint = "移除此记录 · 5 秒内可撤销" }
        else if items.indices.contains(where: { items[$0].kind == .file && cardRect($0).contains(point) }) { hint = "拖入其他应用使用 · ⌘点击多选文件" }
        else if point.y < 100 { hint = "按住拨绳滑动 · 右键更多操作 · Esc 收起" }
        else if undoDeletion != nil { hint = "已移除一条记录" }
        else { hint = "单击粘贴 · 拖入使用 · ⌥点击仅复制 · Esc 收起" }
        if toolTip != hint { toolTip = hint }
        let clip = items.indices.contains(where: { clipRect($0).contains(point) })
            ? items.enumerated().first(where: { clipRect($0.offset).contains(point) })?.element.id : nil
        if clip != hoverClipID { hoverClipID = clip; needsDisplay = true }
        let id = items.enumerated().first(where: { cardRect($0.offset).contains(point) || clipRect($0.offset).contains(point) })?.element.id
        guard id != hoveredID else { return }
        hoveredID = id; animateHover()
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        NSCursor.arrow.set()
        updateHover(at: point)
    }
    override func mouseExited(with event: NSEvent) { updateHover(at: CGPoint(x: -1, y: -1)) }
    private let green = NSColor(calibratedRed: 0.14, green: 0.52, blue: 0.36, alpha: 1)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(frame: NSRect, store: HistoryStore = .shared) { self.store = store; super.init(frame: frame); registerForDraggedTypes([.fileURL]); reload() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var capacity: Int { items.count }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); reflow() }
    private func reflow() {
        contentWidth = ClotheslineLayout.railWidth(widths: cardSizes.map(\.width))
        maxOffset = max(0, contentWidth - bounds.width)
        scrollOffset = min(max(0, scrollOffset), maxOffset)
        frames = ClotheslineLayout.railFrames(sizes: cardSizes, offset: scrollOffset, boundsWidth: bounds.width)
        needsDisplay = true
    }
    func reload() {
        guard !dragging else { return }
        let updated = ClotheslineLayout.items(store.items)
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
        let known = Set(items.map(\.id))
        wind = wind.filter { known.contains($0.key) }
        for item in items where !tilt.keys.contains(item.id) {
            let h = abs(item.id.hashValue)
            tilt[item.id] = CGFloat(h % 60) / 10 - 3
            swayPhase[item.id] = Double(h % 628) / 100
        }
        tilt = tilt.filter { known.contains($0.key) }
        swayPhase = swayPhase.filter { known.contains($0.key) }
        // 取空自动收绳：历史清空（或最后一条被移除）时绳子自己收走。
        if items.isEmpty, expanded, !dragging { interaction.showManually(false) }
        reflow()
        pins = pins.filter { $0.value.isVisible }
        needsDisplay = true
    }
    private func cardRect(_ i: Int) -> CGRect { frames[i] }
    private func clipRect(_ i: Int) -> CGRect { let r = cardRect(i); return CGRect(x: r.midX - 12, y: r.minY - 22, width: 24, height: 36) }
    private func pinRect(_ i: Int) -> CGRect {
        let card = cardRect(i)
        return CGRect(x: card.maxX - 65, y: card.maxY - 29, width: 59, height: 25)
    }
    private var undoRect: CGRect { CGRect(x: bounds.width - 158, y: 10, width: 142, height: 30) }
    private(set) var menuOpen = false
    func isInteractive(_ point: CGPoint) -> Bool {
        !expanded || (undoDeletion != nil && undoRect.contains(point)) || point.y < 96 ||
        items.indices.contains { cardRect($0).contains(point) || clipRect($0).contains(point) }
    }
    private func setScrollOffset(_ value: CGFloat) {
        scrollOffset = min(max(0, value), maxOffset)
        reflow()
        pokeCounter()
    }
    private func pokeCounter() {
        let visible = items.enumerated().filter { frames[$0.offset].maxX > 0 && frames[$0.offset].minX < bounds.width }.map(\.offset)
        if let first = visible.first, let last = visible.last {
            counterText = first == last ? "\(first + 1) / \(items.count)" : "\(first + 1)–\(last + 1) / \(items.count)"
        } else {
            counterText = items.isEmpty ? "暂无记录" : "0 / \(items.count)"
        }
        counterAlpha = 1
        counterTimer?.invalidate()
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            if elapsed < 0.9 { return }
            self.counterAlpha = max(0, 1 - CGFloat((elapsed - 0.9) / 0.25))
            self.needsDisplay = true
            if self.counterAlpha <= 0 { timer.invalidate(); self.counterTimer = nil }
        }
        counterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        needsDisplay = true
    }
    /// 光标扫过绳面的摆动物理：接近即让位，离开后弹回，另有极轻微的悬挂晃动。
    func advanceSway(at point: CGPoint, now: TimeInterval) {
        guard !dragging, !items.isEmpty else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (i, item) in items.enumerated() {
            let frame = frames[i]
            if frame.minX > bounds.width + 260 || frame.maxX < -260 { continue }
            let dx = frame.midX - point.x
            let inf = max(0, 1 - abs(dx) / 240)
            let target = reduceMotion ? 0 : (dx >= 0 ? 1 : -1) * inf * inf * 5.5
            let current = wind[item.id] ?? 0
            let next = current + (target - current) * (reduceMotion ? 1 : 0.2)
            if abs(next) > 3, abs(current) <= 3 { InteractionHaptics.perform() }
            wind[item.id] = next
        }
        needsDisplay = true
    }
    private func swayAngle(for item: ClipboardItem, now: TimeInterval) -> CGFloat {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let ambient = reduceMotion ? 0 : CGFloat(sin(now * 0.9 + (swayPhase[item.id] ?? 0)) * 0.5)
        return (wind[item.id] ?? 0) + (tilt[item.id] ?? 0) + ambient
    }
    @objc private func showUsage() { Toast.shared.showImportant("卡片：单击粘贴，拖出使用，夹子移除。空白绳面按住拨动可滑动；右键有更多操作；Esc 或点外部收起。新截图或复制内容会让绳子自动垂下。") }
    @objc private func openSettingsFromMenu() { controller?.setExpanded(false, view: self); SettingsController.shared.show() }
    @objc private func openHistoryFromMenu() { HistoryPanelController.shared.show(fromHotkey: true) }
    @objc private func collapseFromMenu() { controller?.setExpanded(false, view: self) }
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
        guard expanded else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(revealAlpha)
        let now = ProcessInfo.processInfo.systemUptime
        let ropeStart = CGFloat(16) - scrollOffset
        let ropeEnd = contentWidth - 16 - scrollOffset
        let rope = NSBezierPath(); rope.move(to: CGPoint(x: ropeStart, y: 44))
        rope.curve(to: CGPoint(x: ropeEnd, y: 44), controlPoint1: CGPoint(x: ropeStart + (ropeEnd - ropeStart) * 0.35, y: 60), controlPoint2: CGPoint(x: ropeStart + (ropeEnd - ropeStart) * 0.65, y: 60))
        rope.lineWidth = 2.4
        NSColor(calibratedRed: 0.59, green: 0.55, blue: 0.45, alpha: 1).setStroke(); rope.stroke()
        let thread = rope.copy() as! NSBezierPath
        thread.lineWidth = 0.9; thread.setLineDash([2, 3], count: 2, phase: 0)
        NSColor(calibratedRed: 0.88, green: 0.84, blue: 0.74, alpha: 1).setStroke(); thread.stroke()
        for x in [ropeStart, ropeEnd] {
            green.setFill(); NSBezierPath(ovalIn: CGRect(x: x - 2, y: 42, width: 4, height: 4)).fill()
        }
        for (i, item) in items.enumerated() {
            let rect = cardRect(i)
            if rect.maxX < -60 || rect.minX > bounds.width + 60 { continue }
            NSGraphicsContext.saveGraphicsState()
            let angle = swayAngle(for: item, now: now)
            let anchor = CGPoint(x: rect.midX, y: rect.minY + 8)
            let transform = NSAffineTransform()
            transform.translateX(by: anchor.x, yBy: anchor.y)
            transform.rotate(byDegrees: angle)
            transform.translateX(by: -anchor.x, yBy: -anchor.y)
            transform.concat()
            let shadow = NSShadow(); shadow.shadowBlurRadius = 8; shadow.shadowOffset = NSSize(width: 0, height: -3); shadow.shadowColor = NSColor.black.withAlphaComponent(0.17); shadow.set()
            NSColor(calibratedRed: 0.99, green: 0.985, blue: 0.97, alpha: 1).setFill(); NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            transform.concat()
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
            let clip = clipRect(i).insetBy(dx: 6, dy: 0)
            drawPhotoClip(in: clip, dim: shade[item.id] ?? 0)
            if hoverClipID == item.id {
                let badge = CGRect(x: clip.maxX + 5, y: clip.minY + 3, width: 45, height: 24)
                NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
                NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
                label("移除", in: badge.insetBy(dx: 8, dy: 5), size: 11, color: .systemRed)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if items.isEmpty { label("截图、复制文字或拖入文件，就会挂到这里", in: CGRect(x: 28, y: 70, width: bounds.width - 56, height: 40), size: 15, color: .secondaryLabelColor) }
        if receivingFiles {
            green.withAlphaComponent(0.10).setFill(); bounds.fill()
            label("松手挂入文件", in: CGRect(x: bounds.midX - 90, y: bounds.height - 78, width: 180, height: 28), size: 15, color: green, bold: true)
        }
        if counterAlpha > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(counterAlpha)
            let text = counterText as NSString
            let size = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)])
            let rect = CGRect(x: bounds.midX - (size.width + 24) / 2, y: 12, width: size.width + 24, height: 22)
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
            label(counterText, in: CGRect(x: rect.minX + 12, y: rect.minY + 4, width: rect.width - 24, height: 15), size: 11, color: .secondaryLabelColor)
            NSGraphicsContext.restoreGraphicsState()
        }
        if undoDeletion != nil {
            let rect = undoRect
            NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            label("已移除", in: CGRect(x: rect.minX + 14, y: rect.minY + 7, width: 52, height: 17), size: 11, color: .secondaryLabelColor)
            label("撤销", in: CGRect(x: rect.minX + 78, y: rect.minY + 6, width: 46, height: 18), size: 12, color: green, bold: true)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil); beganDrag = false; pressed = nil
        pressed = items.enumerated().first(where: { cardRect($0.offset).contains(downPoint) && !clipRect($0.offset).contains(downPoint) && !($0.element.kind == .image && pinRect($0.offset).contains(downPoint)) })?.element
        if pressed == nil { panStart = downPoint; panOffset = scrollOffset }
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; panStart = nil }
        guard !beganDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) < 6 else { return }
        if undoDeletion != nil, undoRect.contains(point) {
            let undo = undoDeletion; undoDeletion = nil; undoTimer?.invalidate(); undoTimer = nil
            undo?(); needsDisplay = true
            return
        }
        for (i, item) in items.enumerated() {
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
    override func rightMouseDown(with event: NSEvent) {
        guard expanded, !dragging else { return super.rightMouseDown(with: event) }
        menuOpen = true
        defer { menuOpen = false }
        let menu = NSMenu()
        let history = NSMenuItem(title: "打开主面板", action: #selector(openHistoryFromMenu), keyEquivalent: "")
        history.target = self; menu.addItem(history)
        let collapse = NSMenuItem(title: "收起晾衣架", action: #selector(collapseFromMenu), keyEquivalent: "")
        collapse.target = self; menu.addItem(collapse)
        menu.addItem(.separator())
        let usage = NSMenuItem(title: "操作提示", action: #selector(showUsage), keyEquivalent: "")
        usage.target = self; menu.addItem(usage)
        let settings = NSMenuItem(title: "打开设置…", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        settings.target = self; menu.addItem(settings)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let panStart {
            if hypot(p.x - panStart.x, p.y - panStart.y) >= 3 { beganDrag = true }
            if beganDrag { setScrollOffset(panOffset - (p.x - panStart.x)) }
            return
        }
        guard !beganDrag, let item = pressed else { return }
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
        guard expanded, !dragging else { return }
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        guard abs(delta) > 0.3, Date().timeIntervalSince(lastScroll) > 0.016 else { return }
        lastScroll = Date()
        setScrollOffset(scrollOffset + delta * 2.2)
    }
}
