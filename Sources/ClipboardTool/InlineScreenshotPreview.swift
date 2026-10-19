import AppKit

/// Synthetic scene only: no desktop capture, clipboard, history or preferences.
enum InlineScreenshotPreview {
    static func makeScene() -> NSImage {
        let image = NSImage(size:CGSize(width:1100,height:720))
        image.lockFocus()
        NSColor(calibratedRed:0.09,green:0.14,blue:0.19,alpha:1).setFill()
        NSBezierPath(rect:CGRect(x:0,y:0,width:1100,height:720)).fill()
        NSColor.white.setFill();NSBezierPath(roundedRect:CGRect(x:70,y:80,width:960,height:560),xRadius:14,yRadius:14).fill()
        let header:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:28,weight:.bold),.foregroundColor:NSColor.black]
        ("项目设置" as NSString).draw(at:CGPoint(x:110,y:565),withAttributes:header)
        let normal:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.darkGray]
        for (i,title) in ["搜索与筛选", "默认工作空间", "保存与同步"].enumerated() {
            let y=CGFloat(465-i*130)
            NSColor(calibratedWhite:0.95,alpha:1).setFill();NSBezierPath(roundedRect:CGRect(x:105,y:y-40,width:870,height:100),xRadius:8,yRadius:8).fill()
            (title as NSString).draw(at:CGPoint(x:130,y:y),withAttributes:normal)
            NSColor.systemGreen.setFill();NSBezierPath(roundedRect:CGRect(x:810,y:y-6,width:130,height:32),xRadius:5,yRadius:5).fill()
        }
        image.unlockFocus();return image
    }
    static func configure(_ canvas:InlineScreenshotCanvas) {
        canvas.document.setSelection(CGRect(x:90,y:110,width:900,height:510))
        for (i,text) in ["这里需要增加搜索入口", "点击后保留当前筛选", "保存失败时提供重试"].enumerated() {
            let id=canvas.document.appendNote(at:CGPoint(x:450,y:490-CGFloat(i)*130),numbered:true,fontSize:18,color:1)
            canvas.document.updateNote(id:id,text:text)
        }
        canvas.document.state.marks.append(.magnifier(InlineMagnifier(rect: CGRect(x:130,y:265,width:160,height:160), color:1)))
        canvas.refresh()
    }
    static func render(to path:String) throws {
        let image=makeScene(), rect=CGRect(origin:.zero,size:image.size)
        let canvas=InlineScreenshotCanvas(image:image,union:rect,windows:[])
        let window=NSWindow(contentRect:rect,styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView=canvas
        configure(canvas)
        canvas.layoutSubtreeIfNeeded()
        guard let bitmap=canvas.bitmapImageRepForCachingDisplay(in:rect) else {throw CocoaError(.fileWriteUnknown)}
        canvas.cacheDisplay(in:rect,to:bitmap)
        guard let data=bitmap.representation(using:.png,properties:[:]) else {throw CocoaError(.fileWriteUnknown)}
        try data.write(to:URL(fileURLWithPath:path))
        if let result=InlineScreenshotRenderer.render(image:image,state:canvas.document.state),let png=result.pngData() {
            try png.write(to:URL(fileURLWithPath:path.replacingOccurrences(of:".png",with:"-export.png")))
        }
    }
}
