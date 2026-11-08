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
    /// 挂绳面板：绳铺满可见区横向（左右各留 8pt），贴屏幕上缘；高度随卡片缩小收窄。
    /// 收起分支（96×26）仅为 ClotheslinePreview 兼容保留，运行时不再有常驻入口。
    static func frame(screen: CGRect, visible: CGRect, expanded: Bool, cutout: CGRect? = nil) -> CGRect {
        // 绳宽百分比可在设置里调（30~95%）
        let maxSpan = UserDefaults.standard.object(forKey: "clothesline.maxWidth") as? Double ?? 60
        let width = expanded ? max(560, visible.width * maxSpan / 100) : 96
        let height = expanded ? min(320, visible.height - 8) : 26
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
            let height = min(150, max(72, 120 / sqrt(ratio)))
            let width = min(210, max(80, height * ratio))
            return CGSize(width: width + 18, height: height + 50)
        }
        let value = String((text ?? "").prefix(600))
        let width: CGFloat = value.count < 35 ? 132 : (value.count < 120 ? 168 : 200)
        let measured = (value as NSString).boundingRect(with: CGSize(width: width - 20, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 13)])
        return CGSize(width: width, height: min(160, max(64, ceil(measured.height) + 32)) + 50)
    }
    /// 连续挂绳：内容总宽（卡片 + 间距 + 两端留白）。
    static func railWidth(widths: [CGFloat], gap: CGFloat = 18, margin: CGFloat = 20) -> CGFloat {
        guard !widths.isEmpty else { return 0 }
        return margin + widths.reduce(0, +) + gap * CGFloat(widths.count - 1) + margin
    }
    /// 卡片沿绳排布：x 随滚动偏移平移，y 跟随悬链下垂弧度（弧度按全宽绳算，绳铺满屏幕横向）。
    static func railFrames(sizes: [CGSize], offset: CGFloat, boundsWidth: CGFloat, gap: CGFloat = 18, margin: CGFloat = 20) -> [CGRect] {
        let content = railWidth(widths: sizes.map(\.width), gap: gap, margin: margin)
        let maxOffset = max(0, content - boundsWidth)
        let clamped = min(max(0, offset), maxOffset)
        var frames: [CGRect] = []
        var x = margin
        for size in sizes {
            let railX = x + size.width / 2
            // 绳铺满全宽：视口内按位置取弧度，滚出视口的卡片夹紧到绳末端，不会翻到绳上方。
            let t = boundsWidth > 1 ? min(max(railX / boundsWidth, 0), 1) : 0.5
            let top = 52 + 44 * t * (1 - t)
            frames.append(CGRect(x: x - clamped, y: top, width: size.width, height: size.height))
            x += size.width + gap
        }
        return frames
    }
    /// 接取区位置：覆盖刘海本体及其下方缓冲（无刘海屏为顶部居中窄条）。
    /// 用户瞄准"刘海"甩文件即可命中；宽度略大于刘海，左右稍偏也接得住。
    static func catcherFrame(screen: CGRect, visible: CGRect, cutout: CGRect?) -> CGRect {
        let width: CGFloat = 560
        let safeTop = screen.maxY - visible.maxY
        let height: CGFloat = cutout != nil ? safeTop + 96 : 96
        let center = cutout?.midX ?? screen.midX
        let x = min(max(center - width / 2, visible.minX), visible.maxX - width)
        return CGRect(x: x, y: screen.maxY - height, width: width, height: height)
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

/// 隐形拖拽接取区：常驻刘海带，平时对点击穿透（hitTest 返回 nil）；
/// 检测到拖拽会话时变为实体并可接收文件，同时画出虚线引导框指引用户投放。
final class ClotheslineDragCatcher: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ClotheslineDragCatcherView: NSView {
    weak var controller: ClotheslineController?
    var isRopeVisible: (() -> Bool)?
    /// 拖拽会话进行中（由控制器的全局鼠标监听翻转）；此静态标记必须走主线程。
    static var dragSessionActive = false
    private var pulseTimer: Timer?
    private var dashPhase: CGFloat = 0
    deinit { pulseTimer?.invalidate() }

    /// 引导框呼吸动画：仅拖拽会话进行时运转，会话结束自动停表
    private func ensurePulse() {
        guard pulseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.receptive {
                self.dashPhase += 0.7
                self.needsDisplay = true
            } else {
                timer.invalidate(); self.pulseTimer = nil
            }
        }
        pulseTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        (Self.dragSessionActive && !(isRopeVisible?() ?? false)) ? self : nil
    }
    override func draw(_ dirtyRect: NSRect) {
        guard Self.dragSessionActive, !(isRopeVisible?() ?? false) else { return }
        ensurePulse()
        let pill = bounds.insetBy(dx: 10, dy: 6)
        let path = NSBezierPath(roundedRect: pill, xRadius: 13, yRadius: 13)
        NSColor(calibratedWhite: 0.05, alpha: 0.88).setFill(); path.fill()
        // 呼吸辉光：外圈柔光随相位起伏
        let breathe = 0.5 + 0.5 * sin(dashPhase * 0.18)
        NSColor(calibratedRed: 0.31, green: 0.87, blue: 0.64, alpha: 0.08 + 0.10 * CGFloat(breathe)).setStroke()
        let glow = NSBezierPath(roundedRect: pill.insetBy(dx: -2.5, dy: -2.5), xRadius: 15, yRadius: 15)
        glow.lineWidth = 5; glow.stroke()
        // 蚂蚁线：虚线相位行进
        let dash = NSBezierPath(roundedRect: pill.insetBy(dx: 1.5, dy: 1.5), xRadius: 12, yRadius: 12)
        NSColor(calibratedRed: 0.31, green: 0.87, blue: 0.64, alpha: 0.9).setStroke()
        dash.lineWidth = 1.2; dash.setLineDash([4, 3], count: 2, phase: dashPhase); dash.stroke()
        let text = "松手把文件挂到绳上" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                                         .foregroundColor: NSColor(calibratedRed: 0.45, green: 0.93, blue: 0.71, alpha: 1)]
        let size = text.size(withAttributes: attributes)
        let textY = pill.midY - size.height / 2 + 4
        text.draw(at: CGPoint(x: pill.midX - size.width / 2, y: textY), withAttributes: attributes)
        // 文案上方下落箭头，亮度随呼吸
        let arrow = NSBezierPath()
        let ax = pill.midX, ay = textY - 14
        arrow.move(to: CGPoint(x: ax - 5, y: ay + 4))
        arrow.line(to: CGPoint(x: ax, y: ay + 8))
        arrow.line(to: CGPoint(x: ax + 5, y: ay + 4))
        arrow.lineWidth = 1.6; arrow.lineCapStyle = .round
        NSColor(calibratedRed: 0.45, green: 0.93, blue: 0.71, alpha: 0.7 + 0.3 * CGFloat(breathe)).setStroke()
        arrow.stroke()
    }
    private var receptive: Bool { Self.dragSessionActive && !(isRopeVisible?() ?? false) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard receptive, !(sender.draggingSource is ClotheslineView), !FileTransfer.files(from: sender.draggingPasteboard).isEmpty else { return [] }
        // 拖拽中只亮引导框，不弹绳：松手后绳子才带着新文件出现
        needsDisplay = true
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { receptive ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = FileTransfer.files(from: sender.draggingPasteboard)
        // 不再检查 receptive：mouseUp 解除武装可能先于 drop 到达（竞态会导致投放被拒），
        // 有文件就收——引导框的显隐只影响视觉。
        guard !urls.isEmpty else { return false }
        Self.dragSessionActive = false
        needsDisplay = true
        controller?.stageFilesAtMouse(urls)
        return true
    }
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
    private var catchers: [(screen: NSScreen, panel: ClotheslineDragCatcher, view: ClotheslineDragCatcherView)] = []
    private init() {}

    func start() {
        guard timer == nil else { return }
        observers.append(NotificationCenter.default.addObserver(forName: .clipboardHistoryChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.entries.forEach { $0.view.reload() }
            // 触发策略（用户实测定稿）：复制/截图不自动弹绳，由用户 ⌘⇧Z 或菜单手动调出；
            // 唯一自动触发 = 拖文件到刘海投放区。
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshStyle() })
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in self?.handleDismissal(event) }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp], handler: { [weak self] event in self?.noteDragSession(event.type == .leftMouseDragged) }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            self?.handleDismissal(event); return event
        }) { eventMonitors.append(monitor) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.008
        refreshStyle()
    }
    var layoutDiagnostics: [[String: Any]] {
        entries.map { entry in
            let catcher = catchers.first { $0.screen === entry.screen }
            return ["display": (entry.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0,
                    "hasCutout": ClotheslineLayout.cutout(on: entry.screen) != nil,
                    "screenFrame": NSStringFromRect(entry.screen.frame),
                    "entryFrame": NSStringFromRect(entry.panel.frame),
                    "catcherFrame": catcher.map { NSStringFromRect($0.panel.frame) } ?? "",
                    "catcherOnScreen": catcher?.panel.isVisible ?? false,
                    "expanded": entry.view.expanded]
        }
    }
    func refreshStyle() {
        let migrated = entries.map { ($0.screen, $0.view.exportPresentationState()) }
        entries.forEach { $0.panel.orderOut(nil) }; entries.removeAll()
        catchers.forEach { $0.panel.orderOut(nil) }; catchers.removeAll()
        guard ClipboardPresentation.current == .clothesline else { return }
        for screen in NSScreen.screens {
            let frame = ClotheslineLayout.frame(screen: screen.frame, visible: screen.visibleFrame, expanded: false)
            let panel = ClotheslinePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.level = .floating; panel.hidesOnDeactivate = false; panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = ClotheslineView(frame: CGRect(origin: .zero, size: frame.size))
            view.controller = self
            // 热插拔显示器/改分辨率时迁移垂绳与钉图状态，不让绳子凭空消失。
            if let old = migrated.first(where: { $0.0 === screen })?.1 { view.importPresentationState(old) }
            panel.contentView = view
            panel.isReleasedWhenClosed = false
            entries.append((screen, panel, view))
            if view.expanded { panel.orderFrontRegardless() }
            // 隐形接取区：常驻在刘海正下方，无刘海屏为顶部居中，点击穿透。
            let catcherFrame = ClotheslineLayout.catcherFrame(screen: screen.frame, visible: screen.visibleFrame, cutout: ClotheslineLayout.cutout(on: screen))
            let catcherPanel = ClotheslineDragCatcher(contentRect: catcherFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            catcherPanel.isOpaque = false; catcherPanel.backgroundColor = .clear; catcherPanel.hasShadow = false
            catcherPanel.level = .floating; catcherPanel.hidesOnDeactivate = false
            catcherPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let catcherView = ClotheslineDragCatcherView(frame: CGRect(origin: .zero, size: catcherFrame.size))
            catcherView.controller = self
            catcherView.isRopeVisible = { [weak view] in view?.expanded ?? false }
            catcherView.registerForDraggedTypes([.fileURL])
            catcherPanel.contentView = catcherView
            catcherPanel.isReleasedWhenClosed = false
            catchers.append((screen, catcherPanel, catcherView))
            catcherPanel.orderFrontRegardless()
        }
    }
    /// 拖拽会话开始/结束时翻转接取区的实体态，并让引导框同步显隐。
    /// 配合拖拽剪贴板检查，只有文件拖拽才点亮，窗口移动/文字拖拽不干扰。
    private var lastDragChangeCount = 0
    /// 拖拽会话布防：仅当拖拽剪贴板出现"新的 fileURL 会话"才武装接取区。
    /// 拖拽剪贴板会残留上一次的内容——没有 changeCount 门闩时，移动窗口的
    /// 鼠标拖动也会被误判为新文件拖拽（用户实测"移动应用就触发"的真凶）。
    func noteDragSession(_ began: Bool) {
        guard ClipboardPresentation.current == .clothesline, !suspended else { return }
        let dragPB = NSPasteboard(name: NSPasteboard.Name("Apple CFPasteboard drag"))
        if began {
            guard dragPB.changeCount != lastDragChangeCount,
                  dragPB.types?.contains(.fileURL) == true else { return }
            lastDragChangeCount = dragPB.changeCount
            ClotheslineDragCatcherView.dragSessionActive = true
            catchers.forEach { $0.view.needsDisplay = true }
        } else {
            guard ClotheslineDragCatcherView.dragSessionActive else { return }
            ClotheslineDragCatcherView.dragSessionActive = false
            catchers.forEach { $0.view.needsDisplay = true }
        }
    }
    /// 接取区兜底接收：光标停在接取区内松手时，走与绳面拖入一致的挂入路径。
    func stageFilesAtMouse(_ urls: [URL]) {
        let entry = entries.first { $0.screen.frame.contains(NSEvent.mouseLocation) } ?? entries.first
        guard let entry else { return }
        entry.view.receiveExternalFiles(urls)
    }
    func suspendForCapture() {
        suspended = true
        entries.forEach { $0.panel.orderOut(nil) }
    }
    func resumeAfterCapture() {
        suspended = false
        guard ClipboardPresentation.current == .clothesline, !hidden else { return }
        entries.forEach { if $0.view.expanded, $0.view.interaction.isOpen { $0.panel.orderFrontRegardless() } }
        FileTrace.log("resumeAfterCapture: 恢复 \(entries.filter { $0.view.expanded }.count) 个屏的绳")
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
    func presentAtMouse(reason: String) {
        FileTrace.log("presentAtMouse reason=\(reason)")
        if entries.isEmpty { refreshStyle() }
        guard ClipboardPresentation.current == .clothesline, !suspended else {
            FileTrace.log("present blocked: form/\(suspended ? "suspended" : "ok")")
            return
        }
        let entry = entries.first { $0.screen.frame.contains(NSEvent.mouseLocation) } ?? entries.first
        guard let entry, !entry.view.dragging, !entry.view.receivingFiles else { return }
        hidden = false
        setExpanded(true, view: entry.view, feedback: true)
    }

    /// 菜单「显示晾衣架」：强制切到随手夹形态并垂绳
    func presentFromMenu() {
        UserDefaults.standard.set("clothesline", forKey: "panel.form")
        ClipboardPresentation.apply()
        hidden = false
        presentAtMouse(reason: "menu")
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
        let wasExpanded = view.expanded
        if feedback && wasExpanded != expanded { InteractionHaptics.perform(expanded ? .alignment : .levelChange) }
        view.expanded = expanded
        let frame = ClotheslineLayout.frame(screen: entry.screen.frame, visible: entry.screen.visibleFrame, expanded: expanded)
        // 只在真实过渡时播垂下/收绳动画；绳已垂下时补挂新内容不得整面闪断。
        if expanded != wasExpanded {
            view.reveal(expanded, frame: frame)   // 动画内负责 setFrame / orderFront / orderOut
        } else if expanded {
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
    /// 收绳动画进行中（面板仍需绘制，draw 不能因 expanded=false 直接返回）
    private var isRetracting = false
    private var hoverTimer: Timer?
    private var shade: [String: CGFloat] = [:]
    private var outlineAlpha: [String: CGFloat] = [:]
    private var wind: [String: CGFloat] = [:]
    private var tilt: [String: CGFloat] = [:]
    private var swayPhase: [String: Double] = [:]
    private var counterText = ""
    private var counterAlpha: CGFloat = 0
    private var counterTimer: Timer?
    private var swayFrame = 0

    deinit { hoverTimer?.invalidate(); undoTimer?.invalidate(); revealTimer?.invalidate(); counterTimer?.invalidate() }

    func completeTaking(accepted: Bool) {
        receiptCount = 0
        interaction.finishTaking(accepted: accepted, at: ProcessInfo.processInfo.systemUptime)
        needsDisplay = true
    }
    /// 绳子垂下/收起：整窗从屏幕上缘滑入（轻回弹，像绳落到位置后坠一下）或上滑淡出，
    /// 替代旧的整面淡入淡出。动画内负责 setFrame / orderFront / orderOut。
    func reveal(_ expanded: Bool, frame: CGRect) {
        revealTimer?.invalidate(); revealTimer = nil
        guard let panel = window as? NSPanel else {
            isRetracting = false; revealAlpha = 1
            if expanded { window?.setFrame(frame, display: true); window?.orderFrontRegardless() }
            else { window?.orderOut(nil) }
            needsDisplay = true
            return
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            isRetracting = false; revealAlpha = 1
            if expanded { panel.setFrame(frame, display: true); panel.orderFrontRegardless() }
            else { panel.orderOut(nil) }
            needsDisplay = true
            return
        }
        let raised = CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: frame.height)
        if expanded {
            isRetracting = false; revealAlpha = 1
            panel.setFrame(raised, display: false)
            panel.orderFrontRegardless()
            let began = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let t = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.45)
                let k = Self.easeOutBack(t)
                panel.setFrame(CGRect(x: frame.minX, y: raised.minY + (frame.minY - raised.minY) * CGFloat(k),
                                      width: frame.width, height: frame.height), display: false)
                if t >= 1 { timer.invalidate(); self.revealTimer = nil }
                self.needsDisplay = true
            }
            revealTimer = timer; RunLoop.main.add(timer, forMode: .common)
        } else {
            isRetracting = true
            let from = panel.frame
            let began = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let t = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.26)
                let k = t * t
                panel.setFrame(CGRect(x: from.minX, y: from.minY + (raised.minY - from.minY) * CGFloat(k),
                                      width: from.width, height: from.height), display: false)
                self.revealAlpha = max(0, 1 - t * 1.5)
                self.needsDisplay = true
                if t >= 1 {
                    timer.invalidate(); self.revealTimer = nil
                    self.isRetracting = false; self.revealAlpha = 1
                    panel.orderOut(nil)
                }
            }
            revealTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        needsDisplay = true
    }
    /// easeOutBack（c1=0.9，峰值约 3% 过冲：绳坠到位后轻弹回）
    private static func easeOutBack(_ t: Double) -> Double {
        let c1 = 0.9, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
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
        else if (26...64).contains(point.y) { hint = "按住拨绳滑动 · 右键更多操作 · Esc 收起" }
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
    /// 换屏/重建 entries 时迁移垂绳与钉图状态，绳子不能凭空消失。
    struct PresentationState { var expanded: Bool; var pins: [String: NSPanel]; var scrollOffset: CGFloat }
    func exportPresentationState() -> PresentationState {
        PresentationState(expanded: expanded, pins: pins, scrollOffset: scrollOffset)
    }
    func importPresentationState(_ state: PresentationState) {
        expanded = state.expanded
        pins = state.pins
        scrollOffset = state.scrollOffset
        reflow()
    }
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
            if item.kind == .file { return CGSize(width: 150, height: 160) }
            return ClotheslineLayout.cardSize(image: image, text: item.text)
        }
        let known = Set(items.map(\.id))
        wind = wind.filter { known.contains($0.key) }
        for item in items where !tilt.keys.contains(item.id) {
            let h = abs(item.id.hashValue)
            let amp = UserDefaults.standard.object(forKey: "clothesline.tilt") as? Double ?? 3
            tilt[item.id] = CGFloat(h % 60) / 10 * (amp / 3)
            swayPhase[item.id] = Double(h % 628) / 100
        }
        tilt = tilt.filter { known.contains($0.key) }
        swayPhase = swayPhase.filter { known.contains($0.key) }
        // 取空自动收绳（可在设置关闭）：历史清空时绳子立刻收走。
        if items.isEmpty, expanded, !dragging,
           UserDefaults.standard.object(forKey: "clothesline.autoRetract") as? Bool ?? true {
            interaction.showManually(false)
            controller?.setExpanded(false, view: self, manual: false)
        }
        reflow()
        pins = pins.filter { $0.value.isVisible }
        needsDisplay = true
    }
    private func cardRect(_ i: Int) -> CGRect { frames[i] }
    private func clipRect(_ i: Int) -> CGRect { let r = cardRect(i); return CGRect(x: r.midX - 16, y: r.minY - 24, width: 32, height: 40) }
    private func pinRect(_ i: Int) -> CGRect {
        let card = cardRect(i)
        return CGRect(x: card.maxX - 65, y: card.maxY - 29, width: 59, height: 25)
    }
    private var undoRect: CGRect { CGRect(x: bounds.width - 158, y: 10, width: 142, height: 30) }
    private(set) var menuOpen = false
    func isInteractive(_ point: CGPoint) -> Bool {
        // 全宽绳面下命中区收窄：绳线一带（y 26–64）可拨绳，其余只有卡片/夹子近旁可点，
        // 避免顶部横条吞掉下层窗口标题栏的点击。
        !expanded || (undoDeletion != nil && undoRect.contains(point)) ||
        (point.y >= 26 && point.y <= 64) ||
        items.indices.contains { cardRect($0).insetBy(dx: -24, dy: -24).contains(point) || clipRect($0).contains(point) }
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
    /// 光标落在卡片上时该卡摆正，保证绘制与轴对齐命中矩形一致。
    func advanceSway(at point: CGPoint, now: TimeInterval) {
        guard !dragging, !items.isEmpty else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var changed = false
        for (i, item) in items.enumerated() {
            let frame = frames[i]
            if frame.minX > bounds.width + 260 || frame.maxX < -260 { continue }
            if reduceMotion {
                if wind[item.id] != 0 { wind[item.id] = 0; changed = true }
                continue
            }
            let dx = frame.midX - point.x
            let inf = max(0, 1 - abs(dx) / 240)
            let hover = frame.contains(point) || clipRect(i).contains(point)
            let target = hover ? 0 : (dx >= 0 ? 1 : -1) * inf * inf * 5.5
            let current = wind[item.id] ?? 0
            let next = current + (target - current) * 0.2
            if abs(next) > 3, abs(current) <= 3 { InteractionHaptics.perform() }
            if abs(next - current) > 0.015 { changed = true }
            wind[item.id] = next
        }
        // 常态下环境微晃每帧都不同；只在有摆动变化或每 4 帧刷新一次，降功耗。
        swayFrame += 1
        needsDisplay = changed || (!reduceMotion && swayFrame % 4 == 0)
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
    private enum ClipVariant { case chrome, brass }
    /// 金属弹簧夹：铬丝环 + 渐变夹身，铬/黄铜两变体按卡片身份确定性分配。
    private func drawMetalClip(in rect: CGRect, variant: ClipVariant, dim: CGFloat = 0) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / 32, yBy: rect.height / 40)
        transform.concat()
        let metal: [NSColor]
        if variant == .chrome {
            metal = [NSColor(calibratedWhite: 0.96 * (1 - dim) + 0.04, alpha: 1),
                     NSColor(calibratedWhite: 0.74 * (1 - dim), alpha: 1),
                     NSColor(calibratedWhite: 0.44 * (1 - dim), alpha: 1)]
        } else {
            metal = [NSColor(calibratedRed: 0.93 * (1 - dim) + 0.04, green: 0.80 * (1 - dim) + 0.04, blue: 0.42 * (1 - dim), alpha: 1),
                     NSColor(calibratedRed: 0.72 * (1 - dim), green: 0.55 * (1 - dim), blue: 0.17 * (1 - dim), alpha: 1),
                     NSColor(calibratedRed: 0.40 * (1 - dim), green: 0.29 * (1 - dim), blue: 0.08 * (1 - dim), alpha: 1)]
        }
        let loop = NSBezierPath(roundedRect: CGRect(x: 5, y: 24, width: 22, height: 14), xRadius: 10, yRadius: 7)
        NSColor(calibratedWhite: 0.2 * (1 - dim) + 0.08, alpha: 1).setStroke()
        loop.lineWidth = 2.2; loop.stroke()
        NSGradient(colors: metal.reversed())?.draw(in: loop, angle: -90)
        loop.stroke()
        let body = NSBezierPath(roundedRect: CGRect(x: 2, y: 9, width: 28, height: 16), xRadius: 3, yRadius: 3)
        NSGradient(colors: metal)?.draw(in: body, angle: 90)
        NSColor.black.withAlphaComponent(0.45).setStroke(); body.lineWidth = 0.7; body.stroke()
        // 金属高光斜划
        NSColor.white.withAlphaComponent(0.35 * (1 - dim)).setFill()
        NSBezierPath(roundedRect: CGRect(x: 5, y: 21.5, width: 15, height: 2.0), xRadius: 1, yRadius: 1).fill()
        NSColor.black.withAlphaComponent(0.35 * (1 - dim)).setStroke()
        let seam = NSBezierPath(); seam.move(to: CGPoint(x: 8, y: 17)); seam.line(to: CGPoint(x: 24, y: 17)); seam.lineWidth = 1
        seam.stroke()
        NSColor.black.withAlphaComponent(0.3 * (1 - dim)).setFill()
        NSBezierPath(roundedRect: CGRect(x: 6, y: 5, width: 20, height: 4), xRadius: 2, yRadius: 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    private func clipVariant(for id: String) -> ClipVariant { abs(id.hashValue) % 2 == 0 ? .chrome : .brass }
    private static let captionTimeFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"; return formatter
    }()
    private static func captionTime(_ date: Date?) -> String {
        guard let date else { return "" }
        return captionTimeFormatter.string(from: date)
    }

    /// 麻绳质感：沿绳弧采样，三股纤维带捻转波动（相位互差 2π/3），叠斜向捻痕与落影。
    private func drawHempRope(fromX: CGFloat, toX: CGFloat) {
        let p0 = CGPoint(x: fromX, y: 44)
        let p1 = CGPoint(x: fromX + (toX - fromX) * 0.35, y: 60)
        let p2 = CGPoint(x: fromX + (toX - fromX) * 0.65, y: 60)
        let p3 = CGPoint(x: toX, y: 44)
        let count = max(24, Int((toX - fromX) / 4))
        var pts: [CGPoint] = [], tans: [CGPoint] = []
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count), mt = 1 - t
            let x = mt * mt * mt * p0.x + 3 * mt * mt * t * p1.x + 3 * mt * t * t * p2.x + t * t * t * p3.x
            let y = mt * mt * mt * p0.y + 3 * mt * mt * t * p1.y + 3 * mt * t * t * p2.y + t * t * t * p3.y
            let dx = 3 * mt * mt * (p1.x - p0.x) + 6 * mt * t * (p2.x - p1.x) + 3 * t * t * (p3.x - p2.x)
            let dy = 3 * mt * mt * (p1.y - p0.y) + 6 * mt * t * (p2.y - p1.y) + 3 * t * t * (p3.y - p2.y)
            pts.append(CGPoint(x: x, y: y)); tans.append(CGPoint(x: dx, y: dy))
        }
        func normal(_ i: Int) -> CGPoint {
            let d = tans[i], len = max(hypot(d.x, d.y), 0.001)
            return CGPoint(x: -d.y / len, y: d.x / len)
        }
        let shadow = NSBezierPath()
        for (i, p) in pts.enumerated() { i == 0 ? shadow.move(to: p) : shadow.line(to: p) }
        shadow.lineWidth = 5.2
        NSColor.black.withAlphaComponent(0.14).setStroke(); shadow.stroke()
        let hempDark = NSColor(calibratedRed: 0.38, green: 0.30, blue: 0.18, alpha: 1)
        let hemp = NSColor(calibratedRed: 0.56, green: 0.48, blue: 0.34, alpha: 1)
        let hempLight = NSColor(calibratedRed: 0.79, green: 0.71, blue: 0.55, alpha: 1)
        for (k, strand) in [(offset: CGFloat(-1.15), color: hempDark),
                            (offset: CGFloat(0), color: hemp),
                            (offset: CGFloat(1.15), color: hempLight)].enumerated() {
            let path = NSBezierPath()
            let phase = Double(k) * 2.0 * Double.pi / 3.0
            for (i, p) in pts.enumerated() {
                let n = normal(i)
                let twist = sin(Double(i) * 1.5 + phase) * 0.85
                let q = CGPoint(x: p.x + n.x * (strand.offset + CGFloat(twist)),
                                y: p.y + n.y * (strand.offset + CGFloat(twist)))
                i == 0 ? path.move(to: q) : path.line(to: q)
            }
            path.lineWidth = 1.7; strand.color.setStroke(); path.stroke()
        }
        // 斜向捻痕：短刻线沿法向横跨绳身，倾角交替，读出「拧过的绳」
        let tick = NSBezierPath()
        var i = 4
        while i < pts.count - 4 {
            let n = normal(i), d = tans[i], len = max(hypot(d.x, d.y), 0.001)
            let t = CGPoint(x: d.x / len, y: d.y / len)
            let lean: CGFloat = (i / 6) % 2 == 0 ? 1 : -1
            tick.move(to: CGPoint(x: pts[i].x - n.x * 2.0 + t.x * 1.3 * lean, y: pts[i].y - n.y * 2.0 + t.y * 1.3 * lean))
            tick.line(to: CGPoint(x: pts[i].x + n.x * 2.0 - t.x * 1.3 * lean, y: pts[i].y + n.y * 2.0 - t.y * 1.3 * lean))
            i += 6
        }
        tick.lineWidth = 0.8
        NSColor(calibratedRed: 0.30, green: 0.23, blue: 0.13, alpha: 0.5).setStroke(); tick.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard expanded || isRetracting else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(revealAlpha)
        let now = ProcessInfo.processInfo.systemUptime
        // 绳铺满面板全宽（左右各留 10pt），卡片沿绳滚动。
        let ropeStart: CGFloat = 10
        let ropeEnd = bounds.width - 10
        drawHempRope(fromX: ropeStart, toX: ropeEnd)
        for x in [ropeStart, ropeEnd] {
            let peg = NSBezierPath(ovalIn: CGRect(x: x - 5, y: 39, width: 10, height: 10))
            NSGradient(colors: [NSColor(calibratedRed: 0.88, green: 0.74, blue: 0.34, alpha: 1),
                                NSColor(calibratedRed: 0.42, green: 0.31, blue: 0.08, alpha: 1)])?.draw(in: peg, angle: -70)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: CGRect(x: x - 1.6, y: 42.4, width: 3.2, height: 3.2)).fill()
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
            let shadow = NSShadow(); shadow.shadowBlurRadius = 10; shadow.shadowOffset = NSSize(width: 0, height: -4); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28); shadow.set()
            // 相纸：纵向受光渐变替代平涂，外缘细描边 + 内嵌细线模拟纸厚
            let paper = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
            NSGradient(colors: [NSColor(calibratedWhite: 0.988, alpha: 1),
                                NSColor(calibratedRed: 0.958, green: 0.948, blue: 0.928, alpha: 1)])?.draw(in: paper, angle: 90)
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            transform.concat()
            NSColor(calibratedRed: 0.918, green: 0.898, blue: 0.867, alpha: 1).setStroke(); paper.lineWidth = 0.6; paper.stroke()
            let innerEdge = NSBezierPath(roundedRect: rect.insetBy(dx: 1.4, dy: 1.4), xRadius: 1.8, yRadius: 1.8)
            NSColor.black.withAlphaComponent(0.05).setStroke(); innerEdge.lineWidth = 1; innerEdge.stroke()
            let content = CGRect(x: rect.minX + 10, y: rect.minY + 10, width: rect.width - 20, height: rect.height - 54)
            NSGradient(colors: [NSColor(calibratedWhite: 0.948, alpha: 1), NSColor(calibratedWhite: 0.926, alpha: 1)])?.draw(in: content, angle: 90)
            // 内容区上缘压一条内阴影线：照片嵌进相纸的凹槽感
            NSColor.black.withAlphaComponent(0.06).setFill()
            CGRect(x: content.minX, y: content.minY, width: content.width, height: 1).fill()
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
            // 拍立得图注：标题 + 元信息 + 状态点，占卡片底部 34pt。
            let captionTop = rect.maxY - 34
            NSColor.black.withAlphaComponent(0.07).setStroke()
            let capSep = NSBezierPath(); capSep.move(to: CGPoint(x: rect.minX + 8, y: captionTop - 1))
            capSep.line(to: CGPoint(x: rect.maxX - 8, y: captionTop - 1)); capSep.lineWidth = 0.8; capSep.stroke()
            var captionTitle: String
            var captionMeta: String
            var metaColor = NSColor(calibratedWhite: 0.49, alpha: 1)
            switch item.kind {
            case .image:
                captionTitle = "图片"
                if let w = item.metaWidth, let h = item.metaHeight { captionMeta = "\(w) × \(h)" } else { captionMeta = Self.captionTime(item.timestamp) }
            case .file:
                let exists = item.filePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                captionTitle = FileTransfer.filename(item)
                captionMeta = exists ? "可拖出 · ⌘多选" : "源文件已移动或删除"
                if !exists { metaColor = .systemRed }
            case .text:
                captionTitle = "文字"
                captionMeta = Self.captionTime(item.timestamp)
            }
            label(captionTitle, in: CGRect(x: rect.minX + 8, y: captionTop + 1, width: rect.width - 44, height: 15), size: 11.5, color: NSColor(calibratedWhite: 0.16, alpha: 1), bold: true)
            label(captionMeta, in: CGRect(x: rect.minX + 8, y: captionTop + 16, width: rect.width - 44, height: 13), size: 9.5, color: metaColor)
            green.setFill(); NSBezierPath(ovalIn: CGRect(x: rect.maxX - 17, y: captionTop + 8, width: 7, height: 7)).fill()
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
            drawMetalClip(in: clipRect(i), variant: clipVariant(for: item.id), dim: shade[item.id] ?? 0)
            if hoverClipID == item.id {
                let badge = CGRect(x: clipRect(i).maxX + 5, y: clipRect(i).minY + 3, width: 45, height: 24)
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
        receiveExternalFiles(urls)
        return true
    }
    /// 屏幕上缘接取条转发的挂入路径，与绳面拖入完全一致。
    func receiveExternalFiles(_ urls: [URL]) {
        InteractionHaptics.perform(.levelChange)
        let count = store.addFiles(urls.map(\.path), sourceApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        guard count > 0 else { return }
        receiptCount = count
        interaction.received(at: ProcessInfo.processInfo.systemUptime)
        controller?.setExpanded(true, view: self, manual: false)
        reload()
        Toast.shared.show("已暂存 \(count) 个文件")
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
