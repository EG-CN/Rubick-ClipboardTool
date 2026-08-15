import AppKit
import SwiftUI
import CoreImage

// MARK: - 截图标注编辑器（v2.0，功能清单 12.1）
// 7 工具 + 颜色/线宽 + 撤销重做 + 全部快捷键可配置（AnnotateKeyConfig）

struct Annotation: Identifiable, Equatable {
    enum Tool: String, CaseIterable {
        case rect, ellipse, arrow, pen, text, mosaic, highlight

        var symbol: String {
            switch self {
            case .rect: return "rectangle"
            case .ellipse: return "oval"
            case .arrow: return "arrow.up.right"
            case .pen: return "scribble"
            case .text: return "textformat"
            case .mosaic: return "square.grid.3x3"
            case .highlight: return "highlighter"
            }
        }
        var label: String {
            switch self {
            case .rect: return "矩形"
            case .ellipse: return "椭圆"
            case .arrow: return "箭头"
            case .pen: return "画笔"
            case .text: return "文字"
            case .mosaic: return "马赛克"
            case .highlight: return "高亮"
            }
        }
    }

    let id = UUID()
    var tool: Tool
    var rect: CGRect = .zero          // 归一化到图片（原点左上）
    var points: [CGPoint] = []        // 画笔路径（归一化）
    var text: String = ""
    var colorIndex: Int = 0
    var lineWidth: CGFloat = 4        // 创建时的显示点宽
    var fontSize: CGFloat = 16        // 文字工具字号（显示点）
    var displaySize: CGSize = .zero   // 创建时图片显示尺寸（用于展平缩放）
}

// MARK: - 编辑器共享状态（供视图绑定 + 控制器快捷键驱动）

final class AnnotateModel: ObservableObject {
    @Published var tool: Annotation.Tool = .rect
    @Published var colorIndex = 0
    @Published var lineWidth: CGFloat = 4
    @Published var annotations: [Annotation] = []
    @Published var redoStack: [Annotation] = []
    @Published var textEditing: (id: UUID, position: CGPoint)?
    @Published var textDraft = ""
    @Published var imageRect: CGRect = .zero

    func commit(_ a: Annotation) {
        annotations.append(a)
        redoStack.removeAll()
    }

    func undo() {
        textEditing = nil
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
    }

    func redo() {
        textEditing = nil
        guard let last = redoStack.popLast() else { return }
        annotations.append(last)
    }

    func commitText() {
        let text = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let editing = textEditing else { return }
        textEditing = nil
        guard !text.isEmpty else { return }
        var a = Annotation(tool: .text)
        a.rect = CGRect(origin: editing.position, size: .zero)
        a.text = text
        a.colorIndex = colorIndex
        a.lineWidth = lineWidth
        a.fontSize = 16
        a.displaySize = imageRect.size
        commit(a)
    }
}

final class AnnotationController {
    static let shared = AnnotationController()

    private var window: NSWindow?
    private var keyMonitor: Any?
    private var completion: ((NSImage) -> Void)?
    private var model: AnnotateModel?
    private var currentImage: NSImage?

    static let palette: [NSColor] = [
        NSColor(red: 0.18, green: 0.80, blue: 0.44, alpha: 1),   // 祖母绿
        NSColor(red: 1.00, green: 0.36, blue: 0.36, alpha: 1),   // 红
        NSColor(red: 1.00, green: 0.82, blue: 0.29, alpha: 1),   // 黄
        NSColor.white                                             // 白
    ]

    private init() {}

    func show(image: NSImage, completion: @escaping (NSImage) -> Void) {
        self.completion = completion
        self.currentImage = image
        let m = AnnotateModel()
        model = m
        let view = AnnotateEditorView(
            image: image,
            model: m,
            onConfirm: { [weak self] annotated in self?.finish(annotated) },
            onCancel: { [weak self] in self?.cancel() }
        )
        if window == nil {
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            let w = NSWindow(contentRect: screen.frame,
                             styleMask: [.borderless],
                             backing: .buffered, defer: false)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.contentView = NSHostingView(rootView: view)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor(model: m)
    }

    private func installKeyMonitor(model: AnnotateModel) {
        if let mk = keyMonitor { NSEvent.removeMonitor(mk) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.isVisible == true else { return event }
            // 文本框输入中：放行（Esc 取消输入）
            if let fr = NSApp.keyWindow?.firstResponder, fr is NSTextView {
                if event.keyCode == 53 {
                    model.textEditing = nil
                    return nil
                }
                return event
            }
            let ak = AnnotateKeyConfig.shared
            if ak.matches(.confirm, event: event) { self.confirm(); return nil }
            if ak.matches(.cancel, event: event) { self.cancel(); return nil }
            if ak.matches(.undo, event: event) { model.undo(); return nil }
            if ak.matches(.redo, event: event) { model.redo(); return nil }
            let toolMap: [(AnnotateKeyConfig.Action, Annotation.Tool)] = [
                (.toolRect, .rect), (.toolEllipse, .ellipse), (.toolArrow, .arrow),
                (.toolPen, .pen), (.toolText, .text), (.toolMosaic, .mosaic),
                (.toolHighlight, .highlight)
            ]
            for (action, tool) in toolMap where ak.matches(action, event: event) {
                model.tool = tool
                return nil
            }
            return event
        }
    }

    private func confirm() {
        guard let m = model, let img = currentImage else { return }
        m.textEditing = nil
        let out = Self.flatten(image: img, annotations: m.annotations) ?? img
        finish(out)
    }

    private func finish(_ image: NSImage) {
        teardown()
        completion?(image)
        completion = nil
    }

    private func cancel() {
        teardown()
        completion = nil
    }

    private func teardown() {
        window?.orderOut(nil)
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        model = nil
        currentImage = nil
    }

    // MARK: 展平（标注烘焙进图片）

    static func flatten(image: NSImage, annotations: [Annotation]) -> NSImage? {
        let size = image.size
        let pw = max(Int(size.width), 1)
        let ph = max(Int(size.height), 1)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        let baseCG = image.cgImage()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for a in annotations {
            draw(a, imageSize: size, baseCG: baseCG, ctx: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: size)
        out.addRepresentation(rep)
        return out
    }

    private static func draw(_ a: Annotation, imageSize: CGSize, baseCG: CGImage?, ctx: CGContext) {
        let scale = imageSize.width / max(a.displaySize.width, 1)
        let lw = max(a.lineWidth * scale, 1)
        let color = palette[a.colorIndex]
        let r = CGRect(x: a.rect.minX * imageSize.width,
                       y: (1 - a.rect.maxY) * imageSize.height,
                       width: a.rect.width * imageSize.width,
                       height: a.rect.height * imageSize.height)
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(lw)

        switch a.tool {
        case .rect:
            ctx.stroke(r.insetBy(dx: lw / 2, dy: lw / 2))
        case .ellipse:
            ctx.strokeEllipse(in: r.insetBy(dx: lw / 2, dy: lw / 2))
        case .arrow:
            drawArrow(r, ctx: ctx)
        case .pen:
            guard a.points.count > 1 else { break }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: a.points[0].x * imageSize.width,
                                  y: (1 - a.points[0].y) * imageSize.height))
            for p in a.points.dropFirst() {
                path.addLine(to: CGPoint(x: p.x * imageSize.width,
                                         y: (1 - p.y) * imageSize.height))
            }
            ctx.addPath(path)
            ctx.strokePath()
        case .text:
            let font = NSFont.systemFont(ofSize: max(a.fontSize * scale, 10), weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            (a.text as NSString).draw(at: CGPoint(x: r.minX, y: r.minY), withAttributes: attrs)
        case .mosaic:
            drawMosaic(r, imageSize: imageSize, baseCG: baseCG)
        case .highlight:
            ctx.fill(r)
        }
    }

    private static func drawArrow(_ r: CGRect, ctx: CGContext) {
        let start = CGPoint(x: r.minX, y: r.minY)
        let end = CGPoint(x: r.maxX, y: r.maxY)
        ctx.move(to: start)
        ctx.addLine(to: end)
        ctx.strokePath()
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLen = max(r.width * 0.22, 10)
        for da in [CGFloat.pi * 5 / 6, -CGFloat.pi * 5 / 6] {
            let hp = CGPoint(x: end.x + cos(angle + da) * headLen,
                             y: end.y + sin(angle + da) * headLen)
            ctx.move(to: end)
            ctx.addLine(to: hp)
        }
        ctx.strokePath()
    }

    private static func drawMosaic(_ r: CGRect, imageSize: CGSize, baseCG: CGImage?) {
        guard let baseCG = baseCG else {
            NSColor.gray.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: r).fill()
            return
        }
        let scalePx = CGFloat(baseCG.width) / imageSize.width
        let cropPx = CGRect(x: r.minX * scalePx,
                            y: (imageSize.height - r.maxY) * scalePx,
                            width: r.width * scalePx,
                            height: r.height * scalePx)
        let ci = CIImage(cgImage: baseCG).cropped(to: cropPx)
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: 16])
        if let cg = CIContext().createCGImage(ci, from: ci.extent) {
            NSImage(cgImage: cg, size: r.size).draw(in: r)
        }
    }
}

// MARK: - 编辑器视图

struct AnnotateEditorView: View {
    let image: NSImage
    @ObservedObject var model: AnnotateModel
    let onConfirm: (NSImage) -> Void
    let onCancel: () -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var penPath: [CGPoint] = []   // 画笔实时轨迹（归一化）

    @ObservedObject private var keys = AnnotateKeyConfig.shared

    private func keyDisplay(_ action: AnnotateKeyConfig.Action) -> String {
        keys.keys[action]?.display ?? "?"
    }

    var body: some View {
        GeometryReader { geo in
            let imageRect = fitRect(in: geo.size)
            ZStack {
                RubickTheme.darkBackground.opacity(0.82)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)

                Canvas { ctx, _ in
                    for a in model.annotations { drawPreview(&ctx, a, imageRect: imageRect) }
                    if model.tool == .pen && penPath.count > 1 {
                        var a = Annotation(tool: .pen)
                        a.points = penPath
                        a.colorIndex = model.colorIndex
                        a.lineWidth = model.lineWidth
                        a.displaySize = imageRect.size
                        drawPreview(&ctx, a, imageRect: imageRect)
                    } else if let p = inProgress(imageRect: imageRect) {
                        drawPreview(&ctx, p, imageRect: imageRect)
                    }
                }
                .frame(width: imageRect.width, height: imageRect.height)
                .position(x: imageRect.midX, y: imageRect.midY)
                .allowsHitTesting(false)

                if let editing = model.textEditing {
                    TextField("输入文字…", text: $model.textDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(AnnotationController.palette[model.colorIndex]))
                        .padding(6)
                        .frame(width: 220)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.55)))
                        .position(x: min(imageRect.maxX - 110, imageRect.minX + editing.position.x * imageRect.width + 110),
                                  y: min(imageRect.maxY, imageRect.minY + editing.position.y * imageRect.height))
                        .onSubmit { model.commitText() }
                }

                VStack {
                    Spacer()
                    toolbar
                }
                .padding(.bottom, 26)

                Text("\(keyDisplay(.toolRect))–\(keyDisplay(.toolHighlight)) 工具 · \(keyDisplay(.undo)) 撤销 · \(keyDisplay(.redo)) 重做 · \(keyDisplay(.confirm)) 确认 · \(keyDisplay(.cancel)) 取消")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.5)))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 92)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        model.textEditing = nil
                        let p = clamp(v.startLocation, to: imageRect)
                        dragStart = dragStart ?? p
                        dragCurrent = clamp(v.location, to: imageRect)
                        if model.tool == .pen {
                            let n = normalize(clamp(v.location, to: imageRect), in: imageRect)
                            if let last = penPath.last {
                                if hypot(n.x - last.x, n.y - last.y) > 0.002 { penPath.append(n) }
                            } else {
                                penPath = [n]
                            }
                        }
                    }
                    .onEnded { v in
                        dragCurrent = clamp(v.location, to: imageRect)
                        defer { dragStart = nil; dragCurrent = nil; penPath = [] }
                        guard let start = dragStart else { return }
                        let end = dragCurrent ?? start
                        let normStart = normalize(start, in: imageRect)
                        let normEnd = normalize(end, in: imageRect)
                        if model.tool == .text {
                            if hypot(start.x - end.x, start.y - end.y) < 6 {
                                model.textDraft = ""
                                model.textEditing = (UUID(), normStart)
                            }
                            return
                        }
                        if model.tool == .pen {
                            var pts = penPath
                            if pts.count < 2 {
                                pts = [normStart, normEnd]
                            }
                            guard pts.count >= 2 else { return }
                            var a = Annotation(tool: .pen)
                            a.points = pts
                            let xs = pts.map { $0.x }
                            let ys = pts.map { $0.y }
                            a.rect = CGRect(x: xs.min()!, y: ys.min()!,
                                            width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                            a.colorIndex = model.colorIndex
                            a.lineWidth = model.lineWidth
                            a.displaySize = imageRect.size
                            model.commit(a)
                            return
                        }
                        let w = abs(normEnd.x - normStart.x)
                        let h = abs(normEnd.y - normStart.y)
                        guard w > 0.004 || h > 0.004 else { return }
                        var a = Annotation(tool: model.tool)
                        a.rect = CGRect(x: min(normStart.x, normEnd.x), y: min(normStart.y, normEnd.y),
                                        width: w, height: h)
                        a.colorIndex = model.colorIndex
                        a.lineWidth = model.lineWidth
                        a.fontSize = model.lineWidth * 4
                        a.displaySize = imageRect.size
                        model.commit(a)
                    }
            )
            .onChange(of: imageRect) { newValue in
                model.imageRect = newValue
            }
        }
        .onAppear { NSCursor.crosshair.set() }
        .onDisappear { NSCursor.arrow.set() }
    }

    private func fitRect(in container: CGSize) -> CGRect {
        let padH: CGFloat = 60
        let padTop: CGFloat = 40
        let padBottom: CGFloat = 150
        let avail = CGSize(width: max(container.width - padH * 2, 100),
                           height: max(container.height - padTop - padBottom, 100))
        guard image.size.width > 0, image.size.height > 0 else {
            return CGRect(origin: CGPoint(x: padH, y: padTop), size: avail)
        }
        let s = min(avail.width / image.size.width, avail.height / image.size.height)
        let size = CGSize(width: image.size.width * s, height: image.size.height * s)
        return CGRect(x: (container.width - size.width) / 2,
                      y: padTop + (avail.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func normalize(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: (p.x - rect.minX) / max(rect.width, 1),
                y: (p.y - rect.minY) / max(rect.height, 1))
    }

    private func clamp(_ p: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, rect.minX), rect.maxX),
                y: min(max(p.y, rect.minY), rect.maxY))
    }

    private func inProgress(imageRect: CGRect) -> Annotation? {
        guard let start = dragStart else { return nil }
        let end = dragCurrent ?? start
        let n1 = normalize(start, in: imageRect)
        let n2 = normalize(end, in: imageRect)
        var a = Annotation(tool: model.tool)
        a.rect = CGRect(x: min(n1.x, n2.x), y: min(n1.y, n2.y),
                        width: abs(n2.x - n1.x), height: abs(n2.y - n1.y))
        a.colorIndex = model.colorIndex
        a.lineWidth = model.lineWidth
        a.fontSize = model.lineWidth * 4
        a.displaySize = imageRect.size
        return a
    }

    private func drawPreview(_ ctx: inout GraphicsContext, _ a: Annotation, imageRect: CGRect) {
        let r = CGRect(x: a.rect.minX * imageRect.width,
                       y: a.rect.minY * imageRect.height,
                       width: a.rect.width * imageRect.width,
                       height: a.rect.height * imageRect.height)
        let color = Color(AnnotationController.palette[a.colorIndex])
        switch a.tool {
        case .rect:
            ctx.stroke(Path(r), with: .color(color), lineWidth: a.lineWidth)
        case .ellipse:
            ctx.stroke(Path(ellipseIn: r), with: .color(color), lineWidth: a.lineWidth)
        case .arrow:
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            ctx.stroke(p, with: .color(color), lineWidth: a.lineWidth)
        case .pen:
            var p = Path()
            let pts = a.points
            if let first = pts.first {
                p.move(to: CGPoint(x: first.x * imageRect.width,
                                   y: first.y * imageRect.height))
                for pt in pts.dropFirst() {
                    p.addLine(to: CGPoint(x: pt.x * imageRect.width,
                                          y: pt.y * imageRect.height))
                }
            }
            ctx.stroke(p, with: .color(color),
                       style: StrokeStyle(lineWidth: a.lineWidth, lineCap: .round, lineJoin: .round))
        case .text:
            ctx.draw(Text(a.text).font(.system(size: a.fontSize, weight: .semibold)).foregroundStyle(color),
                     at: CGPoint(x: r.minX, y: r.minY), anchor: .bottomLeading)
        case .mosaic:
            ctx.fill(Path(r), with: .color(.gray.opacity(0.45)))
        case .highlight:
            ctx.fill(Path(r), with: .color(color.opacity(0.3)))
        }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            ForEach(Annotation.Tool.allCases, id: \.self) { t in
                toolButton(t)
            }
            Divider().frame(height: 22).opacity(0.5)
            ForEach(0..<AnnotationController.palette.count, id: \.self) { i in
                colorDot(i)
            }
            Divider().frame(height: 22).opacity(0.5)
            Picker("", selection: $model.lineWidth) {
                Text("细").tag(CGFloat(2))
                Text("中").tag(CGFloat(4))
                Text("粗").tag(CGFloat(6))
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            Divider().frame(height: 22).opacity(0.5)
            toolbarAction("arrow.uturn.backward", help: "撤销 \(keyDisplay(.undo))", enabled: !model.annotations.isEmpty) {
                model.undo()
            }
            toolbarAction("arrow.uturn.forward", help: "重做 \(keyDisplay(.redo))", enabled: !model.redoStack.isEmpty) {
                model.redo()
            }
            Spacer()
            Button {
                model.textEditing = nil
                onConfirm(AnnotationController.flatten(image: image, annotations: model.annotations) ?? image)
            } label: {
                Label("确认", systemImage: "checkmark")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(RubickTheme.emerald)
            Button {
                onCancel()
            } label: {
                Label("取消", systemImage: "xmark")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RubickTheme.emerald.opacity(0.35), lineWidth: 0.8))
        .shadow(color: RubickTheme.emerald.opacity(0.2), radius: 10)
        .padding(.horizontal, 20)
    }

    private func toolButton(_ t: Annotation.Tool) -> some View {
        Button {
            model.tool = t
        } label: {
            Image(systemName: t.symbol)
                .font(.system(size: 15))
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 7).fill(model.tool == t
                                                                   ? RubickTheme.emerald.opacity(0.22)
                                                                   : .white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                    model.tool == t ? RubickTheme.emerald : .white.opacity(0.12), lineWidth: 1))
                .foregroundStyle(model.tool == t ? RubickTheme.emeraldBright : .white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .help(t.label + "（\(keyForTool(t) ?? "")）")
    }

    private func keyForTool(_ t: Annotation.Tool) -> String? {
        let map: [Annotation.Tool: AnnotateKeyConfig.Action] = [
            .rect: .toolRect, .ellipse: .toolEllipse, .arrow: .toolArrow,
            .pen: .toolPen, .text: .toolText, .mosaic: .toolMosaic, .highlight: .toolHighlight
        ]
        guard let a = map[t] else { return nil }
        return keys.keys[a]?.display
    }

    private func colorDot(_ i: Int) -> some View {
        Button {
            model.colorIndex = i
        } label: {
            Circle()
                .fill(Color(AnnotationController.palette[i]))
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(model.colorIndex == i ? .white : .clear, lineWidth: 1.5))
                .shadow(color: model.colorIndex == i ? Color(AnnotationController.palette[i]).opacity(0.8) : .clear, radius: 3)
        }
        .buttonStyle(.plain)
    }

    private func toolbarAction(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .foregroundStyle(enabled ? .white.opacity(0.85) : .white.opacity(0.3))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}
