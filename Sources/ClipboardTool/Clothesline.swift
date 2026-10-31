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
        case .clothesline: HistoryPanelController.shared.close(); ShellDockController.shared.hide(); ClotheslineController.shared.toggle()
        }
    }
}

struct ClotheslineLayout {
    static func frame(screen: CGRect, visible: CGRect, expanded: Bool) -> CGRect {
        let width: CGFloat = expanded ? min(980, max(120, visible.width - 32)) : 72
        let height: CGFloat = expanded ? min(224, visible.height) : 34
        return CGRect(x: visible.maxX - width - 16, y: min(visible.maxY, screen.maxY) - height - 3, width: width, height: height)
    }
    static func items(_ items: [ClipboardItem]) -> [ClipboardItem] { items.filter { $0.kind == .text || $0.kind == .image } }
    static func capacity(width: CGFloat) -> Int { max(1, Int((width - 32) / 158)) }
    static func pageStart(_ start: Int, count: Int, capacity: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, start), ((count - 1) / capacity) * capacity)
    }
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
    private init() {}

    func start() {
        guard timer == nil else { return }
        observers.append(NotificationCenter.default.addObserver(forName: .clipboardHistoryChanged, object: nil, queue: .main) { [weak self] _ in
            self?.entries.forEach { $0.view.reload() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshStyle() })
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.03
        refreshStyle()
    }
    func refreshStyle() {
        entries.forEach { $0.panel.orderOut(nil) }; entries.removeAll()
        guard ClipboardPresentation.current == .clothesline else { return }
        hidden = false
        for screen in NSScreen.screens {
            let frame = ClotheslineLayout.frame(screen: screen.frame, visible: screen.visibleFrame, expanded: false)
            let panel = ClotheslinePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = ClotheslineView(frame: CGRect(origin: .zero, size: frame.size))
            view.controller = self; panel.contentView = view
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
    func toggle() {
        if entries.isEmpty { refreshStyle() }
        hidden = false
        guard !suspended else { return }
        let entry = entries.first { $0.screen.frame.contains(NSEvent.mouseLocation) } ?? entries.first
        guard let entry else { return }
        entry.panel.orderFrontRegardless()
        setExpanded(!entry.view.expanded, view: entry.view)
        entry.view.hoverBlocked = !entry.view.expanded
    }
    func hide() {
        hidden = true; entries.forEach { $0.panel.orderOut(nil) }
    }
    func setExpanded(_ expanded: Bool, view: ClotheslineView) {
        guard let entry = entries.first(where: { $0.view === view }), !view.dragging else { return }
        view.expanded = expanded
        let frame = ClotheslineLayout.frame(screen: entry.screen.frame, visible: entry.screen.visibleFrame, expanded: expanded)
        entry.panel.setFrame(frame, display: true)
        entry.panel.ignoresMouseEvents = false
        view.frame = CGRect(origin: .zero, size: frame.size); view.needsDisplay = true
    }
    private func tick() {
        guard !suspended, !hidden, ClipboardPresentation.current == .clothesline else { return }
        let now = Date()
        for entry in entries {
            let inside = entry.panel.frame.contains(NSEvent.mouseLocation)
            let view = entry.view
            if view.dragging { continue }
            if inside {
                view.leftAt = nil
                if view.enteredAt == nil { view.enteredAt = now }
                // The corner tab opens explicitly on click, avoiding accidental expansion.
            } else {
                view.enteredAt = nil; view.hoverBlocked = false
                if view.leftAt == nil { view.leftAt = now }
                if view.expanded, now.timeIntervalSince(view.leftAt!) > 0.7 { setExpanded(false, view: view) }
            }
            // Empty space between hanging cards must not block clicks into the underlying app.
            let local = view.convert(entry.panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            entry.panel.ignoresMouseEvents = view.expanded && !view.isInteractive(local)
        }
    }
    func use(_ item: ClipboardItem, from view: ClotheslineView, copyOnly: Bool = false) {
        let target = NSWorkspace.shared.frontmostApplication
        let focused = Self.editableFocus(in: target)
        switch item.kind {
        case .text: writeTextToPasteboard(item.text ?? "")
        case .image:
            guard let image = HistoryStore.shared.imageFor(item) else { Toast.shared.showImportant("图片已失效"); return }
            writeImageToPasteboard(image)
        case .file: return
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
            if let view, !(UserDefaults.standard.bool(forKey: "keepPanelOpen")) {
                self?.setExpanded(false, view: view); view.hoverBlocked = true
            }
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
    var hoverBlocked = false
    var enteredAt: Date?, leftAt: Date?
    private var items: [ClipboardItem] = []
    private var start = 0
    private var lastScroll = Date.distantPast
    private let store: HistoryStore
    private var pressed: ClipboardItem?
    private var downPoint = CGPoint.zero
    private var beganDrag = false
    private var pins: [String: NSPanel] = [:]
    private let green = NSColor(calibratedRed: 0.14, green: 0.52, blue: 0.36, alpha: 1)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(frame: NSRect, store: HistoryStore = .shared) { self.store = store; super.init(frame: frame); reload() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var capacity: Int { ClotheslineLayout.capacity(width: bounds.width) }
    func reload() {
        guard !dragging else { return }
        let updated = ClotheslineLayout.items(store.items)
        if updated.first?.id != items.first?.id { start = 0 }
        items = updated
        start = ClotheslineLayout.pageStart(start, count: items.count, capacity: capacity)
        pins = pins.filter { $0.value.isVisible }
        needsDisplay = true
    }
    private var shown: [ClipboardItem] { Array(items.dropFirst(start).prefix(capacity)) }
    private func cardRect(_ i: Int) -> CGRect { CGRect(x: 16 + CGFloat(i) * 158, y: 26 + (i % 2 == 0 ? 0 : 4), width: 144, height: 150) }
    private func clipRect(_ i: Int) -> CGRect { let r = cardRect(i); return CGRect(x: r.midX - 12, y: 10, width: 24, height: 36) }
    private var footerY: CGFloat { max(180, bounds.height - 33) }
    private var toggleRect: CGRect { CGRect(x: bounds.width - 104, y: expanded ? footerY : 1, width: 100, height: 30) }
    private var allRect: CGRect { CGRect(x: 16, y: footerY, width: 94, height: 30) }
    private var hideRect: CGRect { CGRect(x: bounds.width - 165, y: footerY, width: 56, height: 30) }
    func isInteractive(_ point: CGPoint) -> Bool {
        !expanded || toggleRect.contains(point) || allRect.contains(point) || hideRect.contains(point) ||
        point.y < 24 || shown.indices.contains { cardRect($0).contains(point) || clipRect($0).contains(point) }
    }
    private func label(_ text: String, in rect: CGRect, size: CGFloat = 12, color: NSColor = .labelColor, bold: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .medium : .regular), .foregroundColor: color, .paragraphStyle: paragraph])
    }
    private func pill(_ text: String, _ rect: CGRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.88).setFill(); NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        label(text, in: rect.insetBy(dx: 9, dy: 7), color: green)
    }
    override func draw(_ dirtyRect: NSRect) {
        if !expanded {
            let tab = bounds.insetBy(dx: 1, dy: 1)
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: tab, xRadius: 12, yRadius: 12).fill()
            green.setFill()
            NSBezierPath(roundedRect: CGRect(x: 12, y: 6, width: 10, height: 22), xRadius: 3, yRadius: 3).fill()
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let seam = NSBezierPath(); seam.move(to: CGPoint(x: 17, y: 9)); seam.line(to: CGPoint(x: 17, y: 24)); seam.stroke()
            label(items.count > 99 ? "99+" : "\(items.count)", in: CGRect(x: 30, y: 10, width: 37, height: 19), color: green, bold: true)
            return
        }
        let rope = NSBezierPath(); rope.move(to: CGPoint(x: 6, y: 10)); rope.curve(to: CGPoint(x: bounds.width - 6, y: 10), controlPoint1: CGPoint(x: bounds.width * 0.35, y: 26), controlPoint2: CGPoint(x: bounds.width * 0.65, y: 26)); rope.lineWidth = 1.5
        green.withAlphaComponent(0.8).setStroke(); rope.stroke()
        for (i, item) in shown.enumerated() {
            let rect = cardRect(i)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowBlurRadius = 8; shadow.shadowOffset = NSSize(width: 0, height: -3); shadow.shadowColor = NSColor.black.withAlphaComponent(0.17); shadow.set()
            NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill(); NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            NSGraphicsContext.restoreGraphicsState()
            let content = CGRect(x: rect.minX + 8, y: rect.minY + 15, width: rect.width - 16, height: 105)
            if item.kind == .image, let image = store.thumbnail(for: item, maxPixel: 320) {
                let scale = min(content.width / max(image.size.width, 1), content.height / max(image.size.height, 1))
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: content.midX - size.width / 2, y: content.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else if item.kind == .text {
                label("Aa  文字", in: CGRect(x: content.minX, y: content.minY, width: content.width, height: 18), color: green, bold: true)
                label(String((item.text ?? "").prefix(180)), in: CGRect(x: content.minX, y: content.minY + 23, width: content.width, height: 80), size: 13)
            }
            label(item.kind == .image ? "图片 · 点按粘贴" : "文字 · 点按粘贴", in: CGRect(x: rect.minX + 8, y: rect.maxY - 22, width: rect.width - 16, height: 18), size: 11, color: .secondaryLabelColor)
            let clip = clipRect(i).insetBy(dx: 7, dy: 3)
            green.setFill(); NSBezierPath(roundedRect: clip, xRadius: 3, yRadius: 3).fill()
            NSColor.white.withAlphaComponent(0.5).setStroke(); let seam = NSBezierPath(); seam.move(to: CGPoint(x: clip.midX, y: clip.minY + 4)); seam.line(to: CGPoint(x: clip.midX, y: clip.maxY - 4)); seam.stroke()
        }
        if items.isEmpty { label("截图或复制文字，就会挂到这里", in: CGRect(x: 28, y: 70, width: bounds.width - 56, height: 40), size: 15, color: .secondaryLabelColor) }
        pill("全部记录", allRect); pill("隐藏", hideRect); pill("收起  ⌃", toggleRect)
        if bounds.width > 620 {
            pill("\(items.isEmpty ? 0 : start + 1)–\(min(start + capacity, items.count)) / \(items.count)  ·  滚轮翻页  ·  拖入使用", CGRect(x: 123, y: footerY, width: 278, height: 30))
        }
    }
    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil); beganDrag = false; pressed = nil
        if expanded { pressed = shown.enumerated().first(where: { cardRect($0.offset).contains(downPoint) && !clipRect($0.offset).contains(downPoint) })?.element }
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard !beganDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) < 6 else { return }
        if !expanded || toggleRect.contains(point) {
            controller?.setExpanded(!expanded, view: self); hoverBlocked = !expanded; return
        }
        if hideRect.contains(point) { controller?.hide(); Toast.shared.show("衣架已隐藏 · ⌘⇧V 可展开"); return }
        if allRect.contains(point) { controller?.setExpanded(false, view: self); HistoryPanelController.shared.show(fromHotkey: true); return }
        for (i, item) in shown.enumerated() where clipRect(i).contains(point) && item.kind == .image {
            if let pin = pins.removeValue(forKey: item.id), pin.isVisible { PinController.shared.close(pin) }
            else if let image = store.imageFor(item) { pins[item.id] = PinController.shared.pin(image: image); Toast.shared.show("已钉图 · 再点夹子收回") }
            return
        }
        if let pressed { controller?.use(pressed, from: self, copyOnly: event.modifierFlags.contains(.option)) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard !beganDrag, let item = pressed else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - downPoint.x, p.y - downPoint.y) >= 6 else { return }
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
        beganDrag = true; dragging = true
        beginDraggingSession(with: [drag], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false; pressed = nil; reload(); leftAt = Date()
    }
    override func scrollWheel(with event: NSEvent) {
        guard Date().timeIntervalSince(lastScroll) > 0.18 else { return }
        lastScroll = Date()
        guard expanded, !dragging, abs(event.scrollingDeltaY) > 1 || abs(event.scrollingDeltaX) > 1 else { return }
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        start = ClotheslineLayout.pageStart(start + (delta < 0 ? capacity : -capacity), count: items.count, capacity: capacity)
        needsDisplay = true
    }
}
