import Foundation

// MARK: - 截图吸附纯逻辑（v2.0：窗口检测 + 选框边缘吸附）
// 功能清单 12.6.2 / 12.6.3；纯函数便于单元测试

enum SnapLogic {
    /// 选区与窗口四边的最小距离（用于寻找最佳吸附目标）
    static func edgeDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(abs(a.minX - b.minX), abs(a.maxX - b.maxX),
            abs(a.minY - b.minY), abs(a.maxY - b.maxY))
    }

    /// 选区各边吸附到阈值内最近的窗口边；返回（吸附后选区, 命中的窗口）
    static func snappedRect(_ rect: CGRect, windows: [CGRect], threshold: CGFloat) -> (rect: CGRect, window: CGRect?) {
        var best: CGRect?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for w in windows {
            let d = edgeDistance(rect, w)
            if d < bestDistance {
                bestDistance = d
                best = w
            }
        }
        guard let win = best, bestDistance <= threshold else { return (rect, nil) }
        var r = rect
        if abs(r.minX - win.minX) <= threshold { r.origin.x = win.minX }
        if abs(r.maxX - win.maxX) <= threshold { r.origin.x = win.maxX - r.width }
        if abs(r.minY - win.minY) <= threshold { r.origin.y = win.minY }
        if abs(r.maxY - win.maxY) <= threshold { r.origin.y = win.maxY - r.height }
        return (r, win)
    }

    /// 光标悬停的窗口（窗口检测吸附，单击直截整窗）
    static func window(under point: CGPoint, windows: [CGRect]) -> CGRect? {
        windows.first { $0.contains(point) }
    }

    /// 选区是否与窗口几乎重合（单击判定容差）
    static func nearlyEquals(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance &&
        abs(a.minY - b.minY) <= tolerance &&
        abs(a.maxX - b.maxX) <= tolerance &&
        abs(a.maxY - b.maxY) <= tolerance
    }

    /// 视图坐标（左上原点）→ AppKit 全局坐标（左下原点）；windowOrigin 为窗口左下角，viewHeight 为视图高度
    static func appKitRect(fromViewRect r: CGRect, viewHeight: CGFloat, windowOrigin: CGPoint) -> CGRect {
        CGRect(x: r.minX + windowOrigin.x,
               y: windowOrigin.y + viewHeight - r.maxY,
               width: r.width, height: r.height)
    }

    /// AppKit 全局坐标（左下原点）→ 视图坐标（左上原点）
    static func viewRect(fromAppKitRect r: CGRect, viewHeight: CGFloat, windowOrigin: CGPoint) -> CGRect {
        CGRect(x: r.minX - windowOrigin.x,
               y: windowOrigin.y + viewHeight - r.maxY,
               width: r.width, height: r.height)
    }
}
