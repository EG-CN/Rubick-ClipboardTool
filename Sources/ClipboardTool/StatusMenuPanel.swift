import AppKit

// MARK: - 状态栏自绘下拉菜单（照效果图④：深色玻璃 + 双语分组 + 高亮胶囊 + 开关）

struct StatusMenuEntry {
    enum Style { case normal, featured, destructive, toggle }
    let title: String
    let symbol: String?
    let shortcut: String?
    let style: Style
    var isOn: Bool = true
    var subtitle: String? = nil
    let action: (() -> Void)?
}

struct StatusMenuSection {
    let zh: String
    let en: String
    let trailing: String?
    var entries: [StatusMenuEntry]
}

/// 状态栏自绘菜单浮层：非激活面板、深色玻璃质感、行悬停高亮、点击执行并关闭。
final class StatusMenuPanelController: NSObject {
    static let shared = StatusMenuPanelController()
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private(set) var isVisible = false
    var sections: [StatusMenuSection] = []
    var footer: (left: String, right: String)?

    private override init() {}

    func toggle(anchor: NSView) {
        if isVisible { close() } else { show(anchor: anchor) }
    }

    func show(anchor: NSView) {
        close()
        let view = StatusMenuView(sections: sections, footer: footer) { [weak self] in self?.close() }
        let size = view.fitSize()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = view
        panel.isReleasedWhenClosed = false
        panel.setFrame(StatusMenuPanelController.frame(for: size, anchor: anchor), display: true)

        self.panel = panel
        panel.orderFrontRegardless()
        isVisible = true

        // Esc 关闭（面板可成为 key，本地监听即可）
        let esc = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }
            return event
        }
        // 点击面板外关闭
        let outside = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.close()
        }
        monitors = [esc, outside]
    }

    func close() {
        guard isVisible else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        isVisible = false
    }

    private static func frame(for size: CGSize, anchor: NSView) -> CGRect {
        let w = size.width, h = size.height
        guard let window = anchor.window, let screen = window.screen ?? NSScreen.main else {
            return CGRect(origin: .zero, size: size)
        }
        let boundsInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorGlobal = window.convertToScreen(boundsInWindow)
        var x = anchorGlobal.midX - w / 2
        let screenFrame = screen.visibleFrame
        x = min(max(x, screenFrame.minX + 8), screenFrame.maxX - w - 8)
        let y = anchorGlobal.minY - h - 8
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - 自绘菜单视图

final class StatusMenuView: NSView {
    private var sections: [StatusMenuSection]
    private let footer: (left: String, right: String)?
    private var onClose: () -> Void

    private struct Row {
        enum Kind { case header, entry, footer }
        let kind: Kind
        let sectionIndex: Int?
        let entryIndex: Int?
        var height: CGFloat
    }
    private var rows: [Row] = []
    private var hovered: (section: Int, entry: Int)?
    private var tracking: NSTrackingArea?
    private var panelFrame: CGRect { convert(bounds, to: nil) }

    init(sections: [StatusMenuSection], footer: (left: String, right: String)?, onClose: @escaping () -> Void) {
        self.sections = sections
        self.footer = footer
        self.onClose = onClose
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 100))
        rebuildRows()
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func rebuildRows() {
        rows.removeAll()
        var h: CGFloat = 14
        for (si, section) in sections.enumerated() {
            rows.append(Row(kind: .header, sectionIndex: si, entryIndex: nil, height: 30))
            h += 30
            for (ei, entry) in section.entries.enumerated() {
                let eh: CGFloat = entry.style == .toggle ? 46 : 36
                rows.append(Row(kind: .entry, sectionIndex: si, entryIndex: ei, height: eh))
                h += eh
            }
            h += 6
        }
        if footer != nil { rows.append(Row(kind: .footer, sectionIndex: nil, entryIndex: nil, height: 30)); h += 30 }
        h += 10
        frame.size.height = h
    }

    func fitSize() -> NSSize {
        rebuildRows()
        return NSSize(width: 340, height: frame.height)
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // ── 悬停 ──
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hovered = rowAt(p)
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hovered = nil; needsDisplay = true
    }

    private func rowAt(_ p: CGPoint) -> (section: Int, entry: Int)? {
        var y: CGFloat = 0
        for row in rows {
            if p.y >= y, p.y < y + row.height, row.kind == .entry,
               let si = row.sectionIndex, let ei = row.entryIndex {
                return (si, ei)
            }
            y += row.height
        }
        return nil
    }

    // ── 点击 ──
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let target = rowAt(p), let si = rowAt(p)?.section, let ei = rowAt(p)?.entry else { return }
        let entry = sections[si].entries[ei]
        switch entry.style {
        case .toggle:
            sections[si].entries[ei].isOn.toggle()
            let on = sections[si].entries[ei].isOn
            UserDefaults.standard.set(on, forKey: "clothesline.autoRetract")
            needsDisplay = true
            InteractionHaptics.perform(.levelChange)
        default:
            InteractionHaptics.perform(.generic)
            onClose()
            entry.action?()
        }
    }

    // ── 绘制 ──
    override func draw(_ dirtyRect: NSRect) {
        // 深色玻璃底
        NSColor(calibratedRed: 0.04, green: 0.045, blue: 0.055, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        NSColor.white.withAlphaComponent(0.1).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        border.lineWidth = 1; border.stroke()

        var y: CGFloat = 14
        for row in rows {
            switch row.kind {
            case .header:
                if let si = row.sectionIndex {
                    let section = sections[si]
                    // 翡翠点
                    NSColor(calibratedRed: 0.31, green: 0.87, blue: 0.64, alpha: 1).setFill()
                    NSBezierPath(ovalIn: CGRect(x: 18, y: y + 10, width: 6, height: 6)).fill()
                    // 中文 + 英文
                    let zh = section.zh as NSString
                    zh.draw(at: CGPoint(x: 30, y: y + 6), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                        .foregroundColor: NSColor(calibratedWhite: 0.9, alpha: 1)
                    ])
                    let zhW = zh.size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
                    (". " + section.en as NSString).draw(at: CGPoint(x: 34 + zhW, y: y + 8), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                        .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1)
                    ])
                    if let trailing = section.trailing {
                        let t = trailing as NSString
                        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor(calibratedRed: 0.31, green: 0.87, blue: 0.64, alpha: 0.85)]
                        t.draw(at: CGPoint(x: bounds.width - 20 - t.size(withAttributes: attrs).width, y: y + 8), withAttributes: attrs)
                    }
                }
            case .entry:
                if let si = row.sectionIndex, let ei = row.entryIndex {
                    let entry = sections[si].entries[ei]
                    let isHovered = hovered?.section == si && hovered?.entry == ei
                    let rowRect = CGRect(x: 10, y: y + 2, width: bounds.width - 20, height: row.height - 4)
                    // 背景
                    switch entry.style {
                    case .featured:
                        NSColor(calibratedRed: 0.063, green: 0.725, blue: 0.506, alpha: isHovered ? 0.32 : 0.22).setFill()
                        NSBezierPath(roundedRect: rowRect, xRadius: 9, yRadius: 9).fill()
                        NSColor(calibratedRed: 0.31, green: 0.87, blue: 0.64, alpha: 0.5).setStroke()
                        NSBezierPath(roundedRect: rowRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9).stroke()
                    case .destructive:
                        if isHovered {
                            NSColor(srgbRed: 0.94, green: 0.27, blue: 0.27, alpha: 0.12).setFill()
                            NSBezierPath(roundedRect: rowRect, xRadius: 9, yRadius: 9).fill()
                        }
                    default:
                        if isHovered {
                            NSColor.white.withAlphaComponent(0.07).setFill()
                            NSBezierPath(roundedRect: rowRect, xRadius: 9, yRadius: 9).fill()
                        }
                    }
                    // 图标
                    if let symbol = entry.symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: entry.title) {
                        let tint: NSColor
                        switch entry.style {
                        case .featured: tint = NSColor(calibratedRed: 0.31, green: 0.87, blue: 0.64, alpha: 1)
                        case .destructive: tint = NSColor(srgbRed: 1, green: 0.55, blue: 0.5, alpha: 1)
                        default: tint = NSColor.white.withAlphaComponent(0.65)
                        }
                        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
                        let sized = img.withSymbolConfiguration(config) ?? img
                        let size = sized.size
                        let ratio = min(16 / size.width, 16 / size.height)
                        let w = size.width * ratio, h = size.height * ratio
                        let tinted = NSImage(size: sized.size, flipped: false) { rect in
                            sized.draw(in: rect)
                            tint.set()
                            rect.fill(using: .sourceAtop)
                            return true
                        }
                        tinted.draw(in: CGRect(x: 18, y: y + row.height / 2 - h / 2, width: w, height: h))
                    }
                    // 标题
                    let titleColor: NSColor
                    switch entry.style {
                    case .featured: titleColor = NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.78, alpha: 1)
                    case .destructive: titleColor = NSColor(srgbRed: 1, green: 0.55, blue: 0.5, alpha: 1)
                    default: titleColor = NSColor(calibratedWhite: 0.9, alpha: 1)
                    }
                    (entry.title as NSString).draw(at: CGPoint(x: 44, y: y + row.height / 2 - 8), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
                        .foregroundColor: titleColor
                    ])
                    if let subtitle = entry.subtitle {
                        (subtitle as NSString).draw(at: CGPoint(x: 44, y: y + row.height / 2 + 6), withAttributes: [
                            .font: NSFont.systemFont(ofSize: 10.5),
                            .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1)
                        ])
                    }
                    // 快捷键（右对齐 mono）
                    if let shortcut = entry.shortcut, entry.style != .toggle {
                        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.4)]
                        let size = (shortcut as NSString).size(withAttributes: attrs)
                        (shortcut as NSString).draw(at: CGPoint(x: bounds.width - 24 - size.width, y: y + row.height / 2 - size.height / 2), withAttributes: attrs)
                    }
                    // 开关（toggle 行）
                    if entry.style == .toggle {
                        let on = entry.isOn
                        let track = CGRect(x: bounds.width - 54, y: y + row.height / 2 - 10, width: 36, height: 20)
                        let trackPath = NSBezierPath(roundedRect: track, xRadius: 10, yRadius: 10)
                        (on ? NSColor(calibratedRed: 0.063, green: 0.725, blue: 0.506, alpha: 1) : NSColor.white.withAlphaComponent(0.15)).setFill()
                        trackPath.fill()
                        let knobX = on ? track.maxX - 22 : track.minX + 2
                        NSColor.white.setFill()
                        NSBezierPath(ovalIn: CGRect(x: knobX, y: track.minY + 2, width: 16, height: 16)).fill()
                    }
                }
            case .footer:
                if let footer {
                    NSColor(calibratedWhite: 1, alpha: 0.06).setStroke()
                    let line = NSBezierPath(); line.move(to: CGPoint(x: 14, y: y + 2)); line.line(to: CGPoint(x: bounds.width - 14, y: y + 2)); line.lineWidth = 0.5; line.stroke()
                    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor(calibratedRed: 0.31, green: 0.87, blue: 0.64, alpha: 0.9)]
                    (footer.left as NSString).draw(at: CGPoint(x: 18, y: y + 12), withAttributes: attrs)
                    let r = footer.right as NSString
                    r.draw(at: CGPoint(x: bounds.width - 18 - r.size(withAttributes: attrs).width, y: y + 12), withAttributes: attrs)
                }
            }
            y += row.height
        }
    }
}
