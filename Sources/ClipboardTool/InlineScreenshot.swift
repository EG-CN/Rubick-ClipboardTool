import AppKit
import UniformTypeIdentifiers

// All geometry stays in the frozen scene, in AppKit points (bottom-left origin).
// Changing the crop never transforms existing marks.
struct InlineNote: Equatable {
    let id: UUID
    var number: Int?
    var anchor: CGPoint
    var text: String
    var fontSize: CGFloat
    var color: Int
    var bodyTopLeft: CGPoint? = nil
    var textWidth: CGFloat? = nil
}

enum InlineMark: Equatable {
    case drawing(Annotation)
    case note(InlineNote)
    case magnifier(InlineMagnifier)
    var id: UUID {
        switch self { case .drawing(let a): return a.id; case .note(let n): return n.id; case .magnifier(let m): return m.id }
    }
}

struct InlineSnapshot: Equatable {
    var selection: CGRect?
    var marks: [InlineMark] = []
    var nextNumber = 1
}

final class InlineScreenshotDocument {
    let size: CGSize
    var state = InlineSnapshot()
    private(set) var undoStack: [InlineSnapshot] = []
    private(set) var redoStack: [InlineSnapshot] = []
    init(size: CGSize) { self.size = size }

    func checkpoint(_ before: InlineSnapshot) {
        guard before != state else { return }
        undoStack.append(before)
        redoStack.removeAll()
    }
    func rollbackCreation(to before: InlineSnapshot) {
        if undoStack.last == before { undoStack.removeLast() }
        state = before
        redoStack.removeAll()
    }
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state); state = previous
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state); state = next
    }
    func setSelection(_ rect: CGRect) {
        let old = state
        let clipped = rect.standardized.intersection(CGRect(origin: .zero, size: size))
        state.selection = clipped.width >= 4 && clipped.height >= 4 ? clipped : nil
        checkpoint(old)
    }
    func appendNote(at anchor: CGPoint, numbered: Bool, fontSize: CGFloat, color: Int, layoutRegion: CGRect? = nil) -> UUID {
        let old = state
        var note = InlineNote(id: UUID(), number: numbered ? state.nextNumber : nil,
                              anchor: anchor, text: "", fontSize: fontSize, color: color)
        if let selection = layoutRegion ?? state.selection {
            note.textWidth = min(300, max(40, selection.width - (numbered ? 45 : 8)))
            let layout = InlineScreenshotRenderer.layout(note, selection: selection, editing: true)
            note.bodyTopLeft = CGPoint(x: layout.body.minX, y: layout.body.maxY)
        }
        if numbered { state.nextNumber += 1 }
        state.marks.append(.note(note)); checkpoint(old)
        return note.id
    }
    func updateNote(id: UUID, text: String) {
        guard let i = state.marks.firstIndex(where: { $0.id == id }), case .note(var note) = state.marks[i] else { return }
        let old = state; note.text = text; state.marks[i] = .note(note); checkpoint(old)
    }
    func remove(id: UUID) {
        let old = state; state.marks.removeAll { $0.id == id }; checkpoint(old)
    }
    func appendDrawing(_ annotation: Annotation) {
        let old = state; state.marks.append(.drawing(annotation)); checkpoint(old)
    }
    func moveMark(id: UUID, from before: InlineSnapshot, delta: CGPoint) {
        guard let index = before.marks.firstIndex(where: { $0.id == id }) else { return }
        switch before.marks[index] {
        case .magnifier(var lens):
            lens.rect = lens.rect.offsetBy(dx: delta.x, dy: delta.y)
            state.marks[index] = .magnifier(lens)
        case .note(var n):
            n.anchor.x += delta.x; n.anchor.y += delta.y
            if var origin = n.bodyTopLeft { origin.x += delta.x; origin.y += delta.y; n.bodyTopLeft = origin }
            state.marks[index] = .note(n)
        case .drawing(var a):
            let dx = delta.x / size.width, dy = -delta.y / size.height
            a.rect.origin.x += dx; a.rect.origin.y += dy
            a.points = a.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            a.startPoint.x += dx; a.startPoint.y += dy
            a.endPoint.x += dx; a.endPoint.y += dy
            state.marks[index] = .drawing(a)
        }
    }
}

enum InlineScreenshotRenderer {
    struct NoteLayout {
        let circle: CGRect
        let body: CGRect
        var bounds: CGRect { circle.isEmpty ? body : (body.isEmpty ? circle : circle.union(body)) }
    }
    static func attributes(_ note: InlineNote) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        return [.font: NSFont.systemFont(ofSize: note.fontSize, weight: .medium),
                .foregroundColor: AnnotationController.palette[note.color],
                .paragraphStyle: paragraph]
    }
    static func layout(_ note: InlineNote, selection: CGRect, editing: Bool = false) -> NoteLayout {
        let radius: CGFloat = note.number == nil ? 0 : 12
        let circle = radius == 0 ? CGRect.zero : CGRect(x: note.anchor.x - radius, y: note.anchor.y - radius, width: radius * 2, height: radius * 2)
        let room = max(32, selection.width - (radius > 0 ? 38 : 8))
        let width = note.textWidth ?? min(230, room)
        let measured = (note.text as NSString).boundingRect(with: CGSize(width: width - 12, height: 10000),
                                                            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes(note)).size
        let bodyWidth = min(width, max(editing ? 60 : 24, ceil(measured.width) + 12))
        let bodyHeight = max(ceil(note.fontSize * 1.35) + 8, ceil(measured.height) + 12)
        var x = note.anchor.x + radius + (radius > 0 ? 7 : 0)
        if x + bodyWidth > selection.maxX - 3 { x = note.anchor.x - radius - 7 - bodyWidth }
        x = min(max(x, selection.minX + 3), max(selection.minX + 3, selection.maxX - bodyWidth - 3))
        let y = min(max(note.anchor.y + 12 - bodyHeight, selection.minY + 3), max(selection.minY + 3, selection.maxY - bodyHeight - 3))
        if let origin = note.bodyTopLeft {
            return NoteLayout(circle: circle, body: note.text.isEmpty && !editing ? .zero : CGRect(x: origin.x, y: origin.y - bodyHeight, width: bodyWidth, height: bodyHeight))
        }
        return NoteLayout(circle: circle, body: note.text.isEmpty && !editing ? .zero : CGRect(x: x, y: y, width: bodyWidth, height: bodyHeight))
    }
    static func draw(_ note: InlineNote, selection: CGRect, hidingBody: Bool = false) {
        let layout = layout(note, selection: selection)
        let color = AnnotationController.palette[note.color == 4 ? 0 : note.color]
        if let number = note.number {
            color.setFill(); NSBezierPath(ovalIn: layout.circle).fill()
            NSColor.white.setStroke(); let border = NSBezierPath(ovalIn: layout.circle); border.lineWidth = 1; border.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: (note.color == 2 || note.color == 3) ? NSColor.black : NSColor.white]
            let text = String(number) as NSString, size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: layout.circle.midX - size.width / 2, y: layout.circle.midY - size.height / 2), withAttributes: attrs)
        }
        if !hidingBody && !layout.body.isEmpty {
            (note.text as NSString).draw(with: layout.body.insetBy(dx: 6, dy: 6), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes(note))
        }
    }
    static func drawMarks(_ marks: [InlineMark], image: NSImage, selection: CGRect, editingID: UUID? = nil) {
        guard !marks.isEmpty else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let cg = image.cgImage()
        context.saveGState(); context.clip(to: selection)
        for mark in marks {
            context.saveGState()
            switch mark {
            case .magnifier(let lens):
                // Magnification must preserve redactions, including masks added later.
                let overlays = marks.filter { if case .magnifier = $0 { return false }; return true }
                lens.draw(image: image, selection: selection, overlays: overlays)
            case .drawing(let annotation): AnnotationController.draw(annotation, imageSize: image.size, baseCG: cg, ctx: context)
            case .note(let note):
                if selection.contains(note.anchor) { draw(note, selection: selection, hidingBody: note.id == editingID) }
            }
            context.restoreGState()
        }
        context.restoreGState()
    }
    static func render(image: NSImage, state: InlineSnapshot) -> NSImage? {
        guard let selection = state.selection, selection.width >= 4, selection.height >= 4 else { return nil }
        // Align to source pixels rather than integral logical points.
        let scale = CGFloat(image.cgImage()?.width ?? Int(image.size.width)) / max(image.size.width, 1)
        let px = selection.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        let crop = px.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height), bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = crop.size
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        drawMarks(state.marks, image: image, selection: selection)
        let out = NSImage(size: crop.size); out.addRepresentation(rep); return out
    }
}

private final class InlineScreenshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

struct InlineScreenshotViewport: Equatable {
    let screenFrame: CGRect
    let sceneFrame: CGRect
    var canvasFrame: CGRect {
        CGRect(x: sceneFrame.minX - screenFrame.minX, y: sceneFrame.minY - screenFrame.minY,
               width: sceneFrame.width, height: sceneFrame.height)
    }
    var visibleSceneRect: CGRect { screenFrame.offsetBy(dx: -sceneFrame.minX, dy: -sceneFrame.minY) }
}

final class InlineScreenshotController {
    static let shared = InlineScreenshotController()
    private var windows: [NSPanel] = []
    private var canvases: [InlineScreenshotCanvas] = []
    private var previousApp: NSRunningApplication?
    private var activeCanvas: InlineScreenshotCanvas?
    private var layoutProbePending = CommandLine.arguments.contains("--diagnose-screenshot-layout")
    var isVisible: Bool { windows.contains { $0.isVisible } }

    func show(image: NSImage, union: CGRect, windows windowRects: [CGRect]) {
        close(restoreFocus: false)
        previousApp = NSWorkspace.shared.frontmostApplication
        let document = InlineScreenshotDocument(size: union.size)
        let demo = Bundle.main.bundleIdentifier == "local.rubick.inline-demo"
        let frames = demo ? [union] : NSScreen.screens.map(\.frame).filter { $0.intersects(union) }
        // One native window per physical display. A spanning NSWindow can be repositioned
        // by macOS/Spaces; never stretch the composite into a screen-sized content view.
        for frame in frames {
            let viewport = InlineScreenshotViewport(screenFrame: frame, sceneFrame: union)
            let panel = InlineScreenshotPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.title = "拉比克 · 截图"
            panel.level = demo ? .floating : .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = true; panel.backgroundColor = .black; panel.hasShadow = false; panel.acceptsMouseMovedEvents = true
            let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
            // Keep the frozen scene on a separate backing layer. Dragging only redraws
            // the mask/marks instead of resampling a full mixed-Retina desktop each time.
            let backdrop = NSView(frame: viewport.canvasFrame)
            backdrop.wantsLayer = true
            backdrop.layer?.contents = image.cgImage()
            backdrop.layer?.contentsGravity = .resize
            root.addSubview(backdrop)
            let canvas = InlineScreenshotCanvas(image: image, union: union, windows: windowRects, document: document)
            canvas.drawsFrozenBackground = false
            canvas.frame = viewport.canvasFrame
            root.addSubview(canvas)
            panel.contentView = root
            panel.setFrame(frame, display: false)
            canvas.onCancel = { [weak self] in self?.close(restoreFocus: true) }
            canvas.onOutput = { [weak self, weak canvas] action in self?.activeCanvas = canvas; self?.output(action) }
            canvas.onWillInteract = { [weak self, weak canvas] in
                guard let self, let canvas else { return }
                for peer in self.canvases where peer !== canvas { peer.commitEditing() }
                self.activeCanvas = canvas
                canvas.window?.makeKeyAndOrderFront(nil)
            }
            canvas.onSceneChange = { [weak self, weak canvas] in
                guard let self, let canvas else { return }
                for peer in self.canvases where peer !== canvas { peer.synchronize(from: canvas) }
            }
            self.windows.append(panel); canvases.append(canvas)
        }
        ActivationPolicyKeeper.shared.acquire("inlineScreenshot")
        ScreenshotDiagnostics.windows(self.windows, stage: "beforeOrder")
        for panel in self.windows { panel.orderFrontRegardless() }
        activeCanvas = canvases.first { $0.window?.frame.contains(NSEvent.mouseLocation) == true } ?? canvases.first
        activeCanvas?.window?.makeKeyAndOrderFront(nil)
        activeCanvas?.window?.makeFirstResponder(activeCanvas)
        ScreenshotDiagnostics.windows(self.windows, stage: "afterOrder")
        let sessionDocument = document
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.activeCanvas?.document === sessionDocument else { return }
            ScreenshotDiagnostics.windows(self.windows, stage: "settled")
            if Bundle.main.bundleIdentifier == "local.rubick.screenshot-test",
               self.layoutProbePending {
                self.layoutProbePending = false
                self.close(restoreFocus: true)
            }
        }
    }
    func close(restoreFocus: Bool) {
        for panel in windows { panel.orderOut(nil) }
        windows.removeAll(); canvases.removeAll(); activeCanvas = nil
        ActivationPolicyKeeper.shared.release("inlineScreenshot")
        if restoreFocus, let app = previousApp, !app.isTerminated { NSApp.yieldActivation(to: app); app.activate() }
        previousApp = nil
    }
    private func output(_ action: InlineScreenshotCanvas.Output) {
        guard let canvas = activeCanvas, let panel = canvas.window else { return }
        for peer in canvases { peer.commitEditing() }
        guard canvas.notesFitSelection else { canvas.showMessage("说明超出选区，请移动说明或扩大选区"); return }
        guard let image = InlineScreenshotRenderer.render(image: canvas.image, state: canvas.document.state), let png = image.pngData() else {
            canvas.showMessage("无法生成截图，内容已保留，请重试"); return
        }
        switch action {
        case .copy:
            let pb = NSPasteboard.general
            pb.clearContents()
            guard pb.setData(png, forType: .png) else { canvas.showMessage("复制失败，内容已保留"); return }
            ClipboardMonitor.shared.acknowledgeCurrentWrite()
            HistoryStore.shared.addImageData(png)
        case .save:
            let save = NSSavePanel(); save.allowedContentTypes = [.png]; save.nameFieldStringValue = "拉比克截图.png"
            for window in windows { window.orderOut(nil) }
            let response = save.runModal()
            guard response == .OK, let url = save.url else {
                for window in windows { window.orderFrontRegardless() }; panel.makeKeyAndOrderFront(nil); return
            }
            do { try png.write(to: url, options: .atomic) }
            catch { for window in windows { window.orderFrontRegardless() }; panel.makeKeyAndOrderFront(nil); canvas.showMessage("保存失败：\(error.localizedDescription)"); return }
            HistoryStore.shared.addImageData(png)
        case .pin:
            guard let selection = canvas.document.state.selection else { return }
            PinController.shared.pin(image: image, at: CGPoint(x: canvas.union.minX + selection.minX, y: canvas.union.minY + selection.minY))
            HistoryStore.shared.addImageData(png)
        }
        close(restoreFocus: true)
        Toast.shared.show(action == .copy ? "已复制截图" : (action == .save ? "已保存截图" : "已钉在桌面"))
    }
}

final class InlineTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onEscape: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { super.keyDown(with: event); return }
        if event.keyCode == 53 { onEscape?(); return }
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command) { onCommit?(); return }
        super.keyDown(with: event)
    }
}

final class InlineScreenshotCanvas: NSView, NSTextViewDelegate {
    enum Output { case copy, save, pin }
    enum Tool: Int, CaseIterable {
        case select, rect, ellipse, arrow, pen, text, note, mosaic, highlight, step, magnifier
        var title: String { ["选择", "矩形", "椭圆", "箭头", "画笔", "文字", "编号说明", "马赛克", "高亮", "序号", "局部放大"][rawValue] }
        var drawing: Annotation.Tool? {
            switch self {
            case .rect: return .rect; case .ellipse: return .ellipse; case .arrow: return .arrow
            case .pen: return .pen; case .mosaic: return .mosaic; case .highlight: return .highlight; case .step: return .step
            default: return nil
            }
        }
    }
    let image: NSImage
    let union: CGRect
    let document: InlineScreenshotDocument
    let windowRects: [CGRect]
    var drawsFrozenBackground = true
    private var magnifierPreview: InlineMagnifier?
    private var remoteMagnifier: InlineMagnifier?
    var onCancel: (() -> Void)?
    var onOutput: ((Output) -> Void)?
    var onWillInteract: (() -> Void)?
    var onSceneChange: (() -> Void)?
    private var remoteEditingID: UUID?
    private var tool: Tool = .select
    private var colorIndex = 1
    private var lineWidth: CGFloat = 4
    private var noteFontSize: CGFloat = 18
    private var hoverRect: CGRect?
    private var selectedID: UUID?
    private var editingID: UUID?
    private var editor: InlineTextView?
    private var editingScroll: NSScrollView?
    private var editingBefore: InlineSnapshot?
    private var editingIsNew = false
    private var start: CGPoint?
    private var dragBefore: InlineSnapshot?
    private var handle: Int?
    private var movingID: UUID?
    private var pendingTextEditID: UUID?
    private var textDragHandle: InlineTextDragHandle?
    private var textDragStart: CGPoint?
    private var textDragBefore: InlineSnapshot?
    private var textDragFrame: CGRect?
    private var drawing: Annotation?
    private var remoteDrawing: Annotation?
    private var toolbar = NSVisualEffectView()
    private var toolButtons: [NSButton] = []
    private var undoButton = NSButton()
    private var redoButton = NSButton()
    private var message = "拖拽框选，或单击窗口 · Esc取消"
    override var acceptsFirstResponder: Bool { true }

    init(image: NSImage, union: CGRect, windows: [CGRect], document sharedDocument: InlineScreenshotDocument? = nil) {
        self.image = image; self.union = union; document = sharedDocument ?? InlineScreenshotDocument(size: union.size)
        windowRects = windows.map { $0.offsetBy(dx: -union.minX, dy: -union.minY) }
        super.init(frame: CGRect(origin: .zero, size: union.size))
        setupToolbar()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { tool == .select ? NSCursor.arrow.set() : NSCursor.crosshair.set() }

    private func setupToolbar() {
        toolbar.material = .hudWindow; toolbar.blendingMode = .withinWindow; toolbar.state = .active
        toolbar.wantsLayer = true; toolbar.layer?.cornerRadius = 10; toolbar.layer?.masksToBounds = true
        let first = NSStackView(); first.orientation = .horizontal; first.spacing = 6; first.alignment = .centerY
        for t in Tool.allCases {
            let button = NSButton(title: t.title, target: self, action: #selector(changeTool(_:)))
            button.tag = t.rawValue; button.bezelStyle = .texturedRounded; button.setButtonType(.toggle)
            button.font = .systemFont(ofSize: 13); button.controlSize = .large
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            button.toolTip = t == .note ? "连续编号圆点＋说明；Enter换行，⌘Enter结束输入，点击下一处继续" : (t == .text ? "直接输入文字；Enter换行，⌘Enter结束输入" : t.title)
            if t == .magnifier { button.toolTip = "点击放置2倍放大镜，拖出圆形区域；选中后滚轮调整倍率" }
            toolButtons.append(button); first.addArrangedSubview(button)
        }
        let second = NSStackView(); second.orientation = .horizontal; second.spacing = 8; second.alignment = .centerY
        for (i, color) in AnnotationController.palette.enumerated() {
            let b = NSButton(title: "●", target: self, action: #selector(changeColor(_:))); b.tag = i
            b.attributedTitle = NSAttributedString(string:"●",attributes:[.foregroundColor:color,.font:NSFont.systemFont(ofSize:22)])
            b.contentTintColor = color; b.bezelStyle = .texturedRounded; b.toolTip = ["绿色", "红色", "黄色", "白色", "黑色"][i]
            b.controlSize = .large
            NSLayoutConstraint.activate([b.widthAnchor.constraint(greaterThanOrEqualToConstant: 36), b.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)])
            second.addArrangedSubview(b)
        }
        let fontSizes = NSPopUpButton(); fontSizes.addItems(withTitles:["14号", "18号", "24号", "32号"]); fontSizes.selectItem(at:1)
        fontSizes.target=self; fontSizes.action = #selector(changeFontSize(_:)); fontSizes.toolTip="文字大小"
        fontSizes.font = .systemFont(ofSize: 13); fontSizes.controlSize = .large
        fontSizes.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        second.addArrangedSubview(fontSizes)
        let widths = NSPopUpButton(); widths.addItems(withTitles: ["细", "中", "粗"]); widths.selectItem(at: 1)
        widths.target = self; widths.action = #selector(changeWidth(_:)); widths.toolTip = "线条粗细"
        widths.font = .systemFont(ofSize: 13); widths.controlSize = .large
        widths.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        second.addArrangedSubview(widths)
        let third = NSStackView(); third.orientation = .horizontal; third.spacing = 8; third.alignment = .centerY
        undoButton = makeButton("撤销", action: #selector(undoAction)); third.addArrangedSubview(undoButton)
        redoButton = makeButton("重做", action: #selector(redoAction)); third.addArrangedSubview(redoButton)
        third.addArrangedSubview(makeButton("重选", action: #selector(reselect)))
        third.addArrangedSubview(makeButton("钉图", action: #selector(pinAction)))
        third.addArrangedSubview(makeButton("保存", action: #selector(saveAction)))
        let copy = makeButton("复制 ↵", action: #selector(copyAction)); copy.contentTintColor = .systemGreen; third.addArrangedSubview(copy)
        third.addArrangedSubview(makeButton("关闭", action: #selector(cancelAction)))
        let stack = NSStackView(views: [first, second, third]); stack.orientation = .vertical; stack.spacing = 8; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false; toolbar.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10), stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10), stack.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -10)])
        addSubview(toolbar); toolbar.isHidden = true
    }
    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .texturedRounded; b.font = .systemFont(ofSize: 13); b.controlSize = .large
        NSLayoutConstraint.activate([b.heightAnchor.constraint(greaterThanOrEqualToConstant: 32), b.widthAnchor.constraint(greaterThanOrEqualToConstant: 56)])
        return b
    }
    @objc private func changeTool(_ sender: NSButton) {
        onWillInteract?()
        commitEditing(); tool = Tool(rawValue: sender.tag) ?? .select; selectedID = nil; refresh()
    }
    @objc private func changeColor(_ sender: NSButton) { onWillInteract?(); colorIndex = sender.tag; updateSelectedNoteStyle() }
    @objc private func changeFontSize(_ sender: NSPopUpButton) { onWillInteract?(); noteFontSize=[CGFloat(14),18,24,32][sender.indexOfSelectedItem];updateSelectedNoteStyle() }
    private func updateSelectedNoteStyle() {
        guard let id=editingID ?? selectedID,let index=document.state.marks.firstIndex(where:{$0.id==id}),case .note(var note)=document.state.marks[index] else { refresh();return }
        let before=document.state;note.color=colorIndex;note.fontSize=noteFontSize;document.state.marks[index] = .note(note)
        if let editor {
            editor.unmarkText()
            let attrs=InlineScreenshotRenderer.attributes(note)
            editor.textStorage?.setAttributes(attrs,range:NSRange(location:0,length:(editor.string as NSString).length))
            editor.typingAttributes=attrs;editor.insertionPointColor=AnnotationController.palette[colorIndex]
            textDidChange(Notification(name:NSText.didChangeNotification,object:editor))
        } else { document.checkpoint(before) }
        refresh()
    }
    @objc private func changeWidth(_ sender: NSPopUpButton) { onWillInteract?(); lineWidth = [CGFloat(2), 4, 8][sender.indexOfSelectedItem] }
    @objc private func undoAction() { onWillInteract?(); commitEditing(); document.undo(); selectedID = nil; refresh() }
    @objc private func redoAction() { onWillInteract?(); commitEditing(); document.redo(); selectedID = nil; refresh() }
    @objc private func reselect() {
        onWillInteract?()
        commitEditing(); let old = document.state; document.state.selection = nil; document.checkpoint(old)
        tool = .select; selectedID = nil; refresh()
    }
    @objc private func pinAction() { onOutput?(.pin) }
    @objc private func saveAction() { onOutput?(.save) }
    @objc private func copyAction() { onOutput?(.copy) }
    @objc private func cancelAction() { onCancel?() }
    func showMessage(_ text: String) { message = text; needsDisplay = true }

    private func safeFrame() -> CGRect {
        let p = document.state.selection.map { CGPoint(x: $0.midX + union.minX, y: $0.midY + union.minY) } ?? NSEvent.mouseLocation
        let screen = screenContaining(p) ?? NSScreen.screens.first
        return (screen?.visibleFrame ?? union).offsetBy(dx: -union.minX, dy: -union.minY).intersection(bounds)
    }
    func synchronize(from source: InlineScreenshotCanvas) {
        tool=source.tool; colorIndex=source.colorIndex; lineWidth=source.lineWidth; noteFontSize=source.noteFontSize
        selectedID=source.selectedID; hoverRect=source.hoverRect; remoteEditingID=source.editingID; remoteDrawing=source.drawing
        remoteMagnifier = source.magnifierPreview
        if source.start != nil { toolbar.isHidden = true; needsDisplay = true; return }
        refresh(notify:false)
    }
    func refresh(notify: Bool = true) {
        defer { if notify { onSceneChange?() } }
        needsDisplay = true
        toolButtons.forEach { $0.state = $0.tag == tool.rawValue ? .on : .off }
        undoButton.isEnabled = !document.undoStack.isEmpty; redoButton.isEnabled = !document.redoStack.isEmpty
        guard let s = document.state.selection else { toolbar.isHidden = true; return }
        toolbar.isHidden = false
        let fit = toolbar.fittingSize, safe = safeFrame().insetBy(dx: 8, dy: 8)
        let x = min(max(s.maxX - fit.width, safe.minX), max(safe.minX, safe.maxX - fit.width))
        var y = s.minY - fit.height - 10
        if y < safe.minY { y = s.maxY + 10 }
        y = min(max(y, safe.minY), max(safe.minY, safe.maxY - fit.height))
        toolbar.setFrameOrigin(CGPoint(x: x, y: y)); toolbar.setFrameSize(fit)
        message = (tool == .note || tool == .text) ? "Enter换行 · ⌘Enter结束输入 · 点击下一处继续" : "选择态Enter复制 · ⌘S保存 · Esc逐层返回"
        if tool == .magnifier { message = "点击放置2倍放大镜 · 拖出圆形区域 · 选中后滚轮调整倍率" }
    }
    private func normalized(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / bounds.width, y: 1 - p.y / bounds.height) }
    private func clamped(_ p: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, rect.minX), rect.maxX), y: min(max(p.y, rect.minY), rect.maxY))
    }
    private func handlePoints(_ s: CGRect) -> [CGPoint] {
        [CGPoint(x: s.minX,y:s.minY), CGPoint(x:s.midX,y:s.minY), CGPoint(x:s.maxX,y:s.minY), CGPoint(x:s.maxX,y:s.midY), CGPoint(x:s.maxX,y:s.maxY), CGPoint(x:s.midX,y:s.maxY), CGPoint(x:s.minX,y:s.maxY), CGPoint(x:s.minX,y:s.midY)]
    }
    private func markBounds(_ mark: InlineMark) -> CGRect {
        switch mark {
        case .magnifier(let lens): return lens.rect
        case .note(let note): return InlineScreenshotRenderer.layout(note, selection: document.state.selection ?? bounds).bounds
        case .drawing(let a):
            let r = CGRect(x: a.rect.minX * bounds.width, y: (1 - a.rect.maxY) * bounds.height, width: a.rect.width * bounds.width, height: a.rect.height * bounds.height)
            let hit = a.tool == .step ? max(a.fontSize * 0.75, 10) + 3 : max(a.lineWidth / 2, 8)
            return r.insetBy(dx: -hit, dy: -hit)
        }
    }
    var notesFitSelection: Bool {
        guard let selection = document.state.selection else { return false }
        return document.state.marks.allSatisfy { mark in
            guard case .note(let n) = mark else { return true }
            let layout = InlineScreenshotRenderer.layout(n, selection: selection)
            // Notes wholly outside a changed crop stay recoverable, like drawings.
            return !selection.contains(n.anchor) || selection.contains(layout.bounds)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        if drawsFrozenBackground { image.draw(in: bounds) }
        let shade = NSBezierPath(rect: bounds)
        if let selection = document.state.selection {
            shade.appendRect(selection); shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.48).setFill(); shade.fill()
            var marks = document.state.marks
            if let lens = magnifierPreview ?? remoteMagnifier { marks.append(.magnifier(lens)) }
            if let preview = drawing ?? remoteDrawing { marks.append(.drawing(preview)) }
            InlineScreenshotRenderer.drawMarks(marks, image: image, selection: selection, editingID: editingID ?? remoteEditingID)
            NSColor.systemGreen.setStroke(); let border = NSBezierPath(rect: selection); border.lineWidth = 1; border.stroke()
            if tool == .select {
                for p in handlePoints(selection) { NSColor.white.setFill(); NSBezierPath(ovalIn: CGRect(x: p.x-4,y:p.y-4,width:8,height:8)).fill() }
            }
            let sizeText = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
            sizeText.draw(at: CGPoint(x: selection.minX + 4, y: min(bounds.maxY - 24, selection.maxY + 5)), withAttributes: [.font:NSFont.monospacedDigitSystemFont(ofSize:11,weight:.medium), .foregroundColor:NSColor.white, .backgroundColor:NSColor.black.withAlphaComponent(0.7)])
            if let selectedID, let mark = document.state.marks.first(where: { $0.id == selectedID }) {
                NSColor.systemGreen.setStroke(); NSBezierPath(rect: markBounds(mark).insetBy(dx: -3, dy: -3)).stroke()
            }
        } else {
            NSColor.black.withAlphaComponent(0.48).setFill(); shade.fill()
            if let hoverRect { NSColor.systemGreen.setStroke(); let b = NSBezierPath(rect:hoverRect); b.lineWidth=2; b.stroke() }
        }
        let text = message as NSString
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:12), .foregroundColor:NSColor.white, .backgroundColor:NSColor.black.withAlphaComponent(0.7)]
        let safe = safeFrame(), width = text.size(withAttributes:attrs).width
        let hintX = max(safe.minX+12,safe.midX-width/2)
        var hintY = safe.maxY-28
        if !toolbar.isHidden, toolbar.frame.intersects(CGRect(x: hintX, y: hintY, width: width, height: 22)) {
            hintY = safe.minY+12
        }
        text.draw(at: CGPoint(x: hintX, y: hintY), withAttributes:attrs)
    }
    override func mouseMoved(with event: NSEvent) {
        guard document.state.selection == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let next = windowRects.first { $0.contains(p) }?.intersection(bounds)
        guard next != hoverRect else { return }
        hoverRect = next; needsDisplay = true; onSceneChange?()
    }
    // Screenshot overlays must consume the first click even while the previous
    // application (or another display's overlay) still owns keyboard focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onWillInteract?()
        let wasEditing = editingID != nil
        commitEditing(); window?.makeFirstResponder(self)
        let p = clamped(convert(event.locationInWindow, from: nil), to: bounds)
        start = p; dragBefore = document.state; movingID = nil; handle = nil; pendingTextEditID = nil
        guard let selection = document.state.selection else { return }
        if tool == .select, let i = handlePoints(selection).firstIndex(where: { hypot($0.x-p.x,$0.y-p.y) <= 12 }) { handle = i; return }
        guard selection.contains(p) else { start = nil; return }
        if let mark = document.state.marks.reversed().first(where: {
            let editable: Bool
            switch $0 {
            case .magnifier: editable = tool == .select
            case .note(let n): editable = tool == .select || (tool == .note && n.number != nil) || (tool == .text && n.number == nil)
            case .drawing: editable = tool == .select
            }
            return editable && markBounds($0).contains(p)
        }) {
            selectedID = mark.id
            if case .note(let note) = mark,
               event.clickCount >= 2 || InlineScreenshotRenderer.layout(note,selection:selection).body.contains(p) {
                pendingTextEditID = mark.id; movingID = mark.id
            }
            else { movingID = mark.id }
            refresh(); return
        }
        selectedID = nil
        if wasEditing { start = nil; refresh(); return }
        if tool == .magnifier {
            magnifierPreview = InlineMagnifier(rect: CGRect(origin: p, size: .zero), color: colorIndex)
        } else if tool == .note || tool == .text {
            guard selection.width >= (tool == .note ? 70 : 40), selection.height >= 32 else { showMessage("选区太小，请扩大后添加说明"); start=nil; return }
            let before = document.state
            let inset = tool == .note ? CGFloat(13) : 3
            let viewport = window.map { $0.frame.offsetBy(dx:-union.minX,dy:-union.minY) } ?? bounds
            let region=selection.intersection(viewport)
            guard region.width >= (tool == .note ? 70 : 40), region.height >= 32 else {
                showMessage("当前屏幕内空间不足，请调整选区");start=nil;return
            }
            let anchor = clamped(p, to:region.insetBy(dx:inset,dy:inset))
            let id = document.appendNote(at:anchor,numbered:tool == .note,fontSize:noteFontSize,color:colorIndex,layoutRegion:region)
            beginEditing(id:id,isNew:true,before:before); start=nil
        } else if let t = tool.drawing {
            var a = Annotation(tool:t); a.colorIndex=colorIndex; a.lineWidth=lineWidth; a.fontSize=18; a.displaySize=bounds.size
            a.rect = CGRect(origin:normalized(p),size:.zero); a.startPoint=normalized(p); a.endPoint=normalized(p)
            if t == .pen { a.points=[normalized(p)] }
            if t == .step { a.text = String((document.state.marks.compactMap { if case .drawing(let d)=$0,d.tool == .step {return Int(d.text)};return nil }.max() ?? 0)+1) }
            drawing=a
        }
        refresh()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, let before=dragBefore else { return }
        var p=clamped(convert(event.locationInWindow,from:nil),to:bounds)
        if before.selection == nil {
            let rect=CGRect(x:min(start.x,p.x),y:min(start.y,p.y),width:abs(p.x-start.x),height:abs(p.y-start.y))
            document.state.selection=rect; redrawInteraction(); return
        }
        guard let original=before.selection else{return}
        if let movingID {
            document.moveMark(id:movingID,from:before,delta:CGPoint(x:p.x-start.x,y:p.y-start.y))
        } else if let handle {
            var x=original.minX,y=original.minY,xx=original.maxX,yy=original.maxY
            if [0,6,7].contains(handle){x=min(p.x,xx-4)}; if [2,3,4].contains(handle){xx=max(p.x,x+4)}
            if [0,1,2].contains(handle){y=min(p.y,yy-4)}; if [4,5,6].contains(handle){yy=max(p.y,y+4)}
            document.state.selection=CGRect(x:x,y:y,width:xx-x,height:yy-y)
        } else if tool == .select {
            var r=original.offsetBy(dx:p.x-start.x,dy:p.y-start.y)
            r.origin.x=min(max(r.minX,0),bounds.maxX-r.width);r.origin.y=min(max(r.minY,0),bounds.maxY-r.height)
            document.state.selection=r
        } else if var lens = magnifierPreview, let original = before.selection {
            p = clamped(p, to: original)
            let diameter = min(abs(p.x-start.x), abs(p.y-start.y))
            lens.rect = CGRect(x: p.x >= start.x ? start.x : start.x-diameter,
                               y: p.y >= start.y ? start.y : start.y-diameter,
                               width: diameter, height: diameter)
            magnifierPreview = lens
        } else if var a=drawing {
            p=clamped(p,to:original)
            if event.modifierFlags.contains(.shift) {
                if a.tool == .arrow {p=AnnotationController.snap45(from:start,to:p)}
                if [.rect,.ellipse,.highlight].contains(a.tool) {let d=min(abs(p.x-start.x),abs(p.y-start.y));p=CGPoint(x:start.x+(p.x>=start.x ? d : -d),y:start.y+(p.y>=start.y ? d : -d))}
            }
            let n=normalized(p),s=normalized(start)
            a.rect=CGRect(x:min(n.x,s.x),y:min(n.y,s.y),width:abs(n.x-s.x),height:abs(n.y-s.y));a.endPoint=n
            if a.tool == .pen {
                a.points.append(n)
                let xs=a.points.map(\.x), ys=a.points.map(\.y)
                a.rect=CGRect(x:xs.min() ?? n.x,y:ys.min() ?? n.y,width:(xs.max() ?? n.x)-(xs.min() ?? n.x),height:(ys.max() ?? n.y)-(ys.min() ?? n.y))
            }
            drawing=a
        }
        redrawInteraction()
    }
    private func redrawInteraction() {
        toolbar.isHidden = true
        needsDisplay = true
        onSceneChange?()
    }
    override func mouseUp(with event: NSEvent) {
        defer { start=nil;dragBefore=nil;movingID=nil;handle=nil;drawing=nil;magnifierPreview=nil;pendingTextEditID=nil;refresh() }
        guard let start,let before=dragBefore else{return}
        let p=convert(event.locationInWindow,from:nil)
        if let id = pendingTextEditID, hypot(p.x-start.x,p.y-start.y) < 4 {
            document.state = before
            beginEditing(id: id, isNew: false); return
        }
        if before.selection == nil {
            if hypot(p.x-start.x,p.y-start.y)<4 {
                document.state.selection=windowRects.first{$0.contains(p)}?.intersection(bounds)
            } else if let rect = document.state.selection, CaptureController.shared.snapEnabled, !event.modifierFlags.contains(.option) {
                document.state.selection = SnapLogic.snappedRect(rect, windows: windowRects, threshold: CaptureController.shared.snapThreshold).rect.intersection(bounds)
            }
            if let r=document.state.selection,(r.width<4 || r.height<4){document.state.selection=nil}
            document.checkpoint(before)
        } else if var lens = magnifierPreview, let original = before.selection {
            if lens.rect.width < 24 {
                let diameter = min(160, original.width, original.height)
                lens.rect = CGRect(x: min(max(start.x-diameter/2, original.minX), original.maxX-diameter),
                                   y: min(max(start.y-diameter/2, original.minY), original.maxY-diameter), width: diameter, height: diameter)
            }
            let old = document.state
            document.state.marks.append(.magnifier(lens)); document.checkpoint(old); selectedID = lens.id
        } else if let drawing {
            if drawing.tool == .step || hypot(p.x-start.x,p.y-start.y)>2 {document.appendDrawing(drawing)}
        } else {document.checkpoint(before)}
    }
    private func beginEditing(id:UUID,isNew:Bool,before:InlineSnapshot?=nil) {
        guard let mark=document.state.marks.first(where:{$0.id==id}),case .note(let note)=mark,let s=document.state.selection else{return}
        editingID=id;selectedID=id;editingIsNew=isNew;editingBefore=before ?? document.state
        colorIndex=note.color;noteFontSize=note.fontSize
        let viewport = window.map { $0.frame.offsetBy(dx:-union.minX,dy:-union.minY) } ?? bounds
        let editFrame = InlineScreenshotRenderer.layout(note,selection:s,editing:true).body.intersection(s).intersection(viewport)
        let scroll=NSScrollView(frame:editFrame)
        scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false;scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground=false;scroll.contentView.backgroundColor = .clear
        scroll.wantsLayer=true;scroll.layer?.borderWidth=1;scroll.layer?.borderColor=NSColor.systemGreen.withAlphaComponent(0.65).cgColor
        let view=InlineTextView(frame:CGRect(origin:.zero,size:editFrame.size))
        view.string=note.text;view.font=NSFont.systemFont(ofSize:note.fontSize,weight:.medium)
        view.drawsBackground=false;view.backgroundColor = .clear;view.insertionPointColor=AnnotationController.palette[note.color];view.isRichText=false
        let attrs=InlineScreenshotRenderer.attributes(note)
        view.textStorage?.setAttributes(attrs,range:NSRange(location:0,length:(view.string as NSString).length))
        view.typingAttributes=attrs
        view.textContainerInset=CGSize(width:6,height:6);view.textContainer?.lineFragmentPadding=0
        view.isVerticallyResizable=true;view.isHorizontallyResizable=false
        view.minSize=CGSize(width:0,height:editFrame.height);view.maxSize=CGSize(width:10000,height:100000)
        view.textContainer?.widthTracksTextView=true
        view.autoresizingMask=[.width]
        view.delegate=self
        view.onCommit = {[weak self] in self?.commitEditing()}
        view.onEscape = {[weak self] in
            guard let self else{return};self.cancelOrCommitEditing();self.tool = .select;self.selectedID=nil;self.refresh()
        }
        scroll.documentView=view;editingScroll=scroll;editor=view;addSubview(scroll)
        let grip = InlineTextDragHandle(frame: CGRect(x: editFrame.minX, y: min(editFrame.maxY+2, viewport.maxY-20), width: 30, height: 20))
        grip.toolTip = "拖动文字位置"
        grip.onBegin = { [weak self] point in
            guard let self else { return }
            self.editor?.unmarkText()
            if let index = self.document.state.marks.firstIndex(where: { $0.id == id }), case .note(var note) = self.document.state.marks[index] {
                note.text = self.editor?.string ?? note.text; self.document.state.marks[index] = .note(note)
            }
            self.textDragStart = point; self.textDragBefore = self.document.state; self.textDragFrame = self.editingScroll?.frame
        }
        grip.onDrag = { [weak self] point in
            guard let self, let start = self.textDragStart, let before = self.textDragBefore, let frame = self.textDragFrame else { return }
            let allowed = s.intersection(viewport)
            guard let mark = before.marks.first(where: { $0.id == id }) else { return }
            let box = self.markBounds(mark)
            let delta = CGPoint(x: min(max(point.x-start.x, allowed.minX-box.minX), max(allowed.minX-box.minX, allowed.maxX-box.maxX)),
                                y: min(max(point.y-start.y, allowed.minY-box.minY), max(allowed.minY-box.minY, allowed.maxY-box.maxY)))
            self.document.moveMark(id: id, from: before, delta: delta)
            self.editingScroll?.frame = frame.offsetBy(dx: delta.x, dy: delta.y)
            self.textDragHandle?.frame.origin = CGPoint(x: frame.minX+delta.x, y: min(frame.maxY+delta.y+2, viewport.maxY-20))
            self.needsDisplay = true; self.onSceneChange?()
        }
        textDragHandle = grip; addSubview(grip)
        window?.makeFirstResponder(view);refresh()
    }
    override func scrollWheel(with event: NSEvent) {
        guard let id = selectedID, let index = document.state.marks.firstIndex(where: { $0.id == id }),
              case .magnifier(var lens) = document.state.marks[index], abs(event.scrollingDeltaY) > 0 else {
            super.scrollWheel(with: event); return
        }
        let before = document.state
        lens.zoom = min(max(lens.zoom + (event.scrollingDeltaY > 0 ? 0.25 : -0.25), 1.5), 6)
        document.state.marks[index] = .magnifier(lens); document.checkpoint(before); refresh()
    }
    func textDidChange(_ notification:Notification) {
        guard let id=editingID,let editor,let i=document.state.marks.firstIndex(where:{$0.id==id}),case .note(var n)=document.state.marks[i] else{return}
        n.text=editor.string
        if let s=document.state.selection {
            let viewport = window.map { $0.frame.offsetBy(dx:-union.minX,dy:-union.minY) } ?? bounds
            let r=InlineScreenshotRenderer.layout(n,selection:s,editing:true).body.intersection(s).intersection(viewport)
            editingScroll?.frame=r
            textDragHandle?.frame.origin = CGPoint(x: r.minX, y: min(r.maxY+2, viewport.maxY-20))
            editor.setFrameSize(CGSize(width:r.width,height:max(r.height,editor.frame.height)))
            editor.scrollRangeToVisible(editor.selectedRange())
        }
    }
    func commitEditing() {
        guard let id=editingID,let editor else{return}
        textDragHandle?.removeFromSuperview(); textDragHandle=nil
        editor.unmarkText()
        if editingIsNew, editor.string.isEmpty,
           let mark=document.state.marks.first(where:{$0.id==id}),case .note(let note)=mark,note.number == nil,
           let before=editingBefore {
            editingScroll?.removeFromSuperview();editingScroll=nil;self.editor=nil;editingID=nil
            document.rollbackCreation(to:before);editingBefore=nil;editingIsNew=false
            window?.makeFirstResponder(self);refresh();return
        }
        if let i=document.state.marks.firstIndex(where:{$0.id==id}),case .note(var note)=document.state.marks[i] {
            let before=document.state;note.text=editor.string;document.state.marks[i] = .note(note)
            // Creation already has a checkpoint: consolidate initial typing into that same action.
            if !editingIsNew {document.checkpoint(editingBefore ?? before)}
        }
        editingScroll?.removeFromSuperview();editingScroll=nil;self.editor=nil;editingID=nil;editingBefore=nil;editingIsNew=false
        window?.makeFirstResponder(self);refresh()
    }
    private func cancelOrCommitEditing() {
        textDragHandle?.removeFromSuperview(); textDragHandle=nil
        if editingIsNew,editor?.string.isEmpty == true,let before=editingBefore {
            editingScroll?.removeFromSuperview();editingScroll=nil;editor=nil;editingID=nil
            document.rollbackCreation(to:before);editingBefore=nil;editingIsNew=false;refresh();window?.makeFirstResponder(self)
        }else{commitEditing()}
    }
    override func keyDown(with event:NSEvent) {
        onWillInteract?()
        let keys = AnnotateKeyConfig.shared
        let bindings: [(AnnotateKeyConfig.Action, Tool)] = [(.toolRect,.rect),(.toolEllipse,.ellipse),(.toolArrow,.arrow),(.toolPen,.pen),(.toolText,.text),(.toolMosaic,.mosaic),(.toolHighlight,.highlight),(.toolStep,.step)]
        if let binding = bindings.first(where: { keys.matches($0.0, event:event) }) {
            tool=binding.1;selectedID=nil;refresh();return
        }
        if event.charactersIgnoringModifiers == "9", event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty {
            tool = .note;selectedID=nil;refresh();return
        }
        if keys.matches(.undo,event:event) {undoAction();return}
        if keys.matches(.redo,event:event) {redoAction();return}
        let command=event.modifierFlags.contains(.command)
        if command,event.charactersIgnoringModifiers == "z" {event.modifierFlags.contains(.shift) ? redoAction() : undoAction();return}
        if command,event.charactersIgnoringModifiers == "s" {saveAction();return}
        if command,event.charactersIgnoringModifiers == "c" {copyAction();return}
        if event.keyCode == 53 || keys.matches(.cancel,event:event) {
            if selectedID != nil {selectedID=nil;refresh()}
            else if tool != .select {tool = .select;refresh()}
            else{onCancel?()};return
        }
        if event.keyCode == 51,let selectedID {document.remove(id:selectedID);self.selectedID=nil;refresh();return}
        if (event.keyCode == 36 || event.keyCode == 76 || keys.matches(.confirm,event:event)),tool == .select {onOutput?(.copy);return}
        super.keyDown(with:event)
    }
}
