import Testing
import AppKit
@testable import ClipboardTool

private final class ScreenshotLayoutTestPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@Suite(.serialized)
@MainActor
struct InlineScreenshotTests {
    private func document() -> InlineScreenshotDocument {
        let d = InlineScreenshotDocument(size: CGSize(width: 600, height: 400))
        d.setSelection(CGRect(x: 20, y: 20, width: 560, height: 360))
        return d
    }
    @Test(arguments: [
        CGRect(x:-200,y:0,width:200,height:150),
        CGRect(x:0,y:100,width:200,height:150),
        CGRect(x:100,y:-80,width:200,height:150)
    ])
    func screenViewportKeepsSceneCoordinates(external: CGRect) throws {
        let laptop=CGRect(x:0,y:0,width:100,height:100)
        let scene=laptop.union(external)
        for screen in [laptop,external] {
            let viewport=InlineScreenshotViewport(screenFrame:screen,sceneFrame:scene)
            // A point on either screen must land at exactly the same global point
            // after the full scene is clipped into that screen's own native window.
            let scenePoint=CGPoint(x:screen.midX-scene.minX,y:screen.midY-scene.minY)
            let local=CGPoint(x:scenePoint.x+viewport.canvasFrame.minX,y:scenePoint.y+viewport.canvasFrame.minY)
            #expect(local == CGPoint(x:screen.width/2,y:screen.height/2))
            #expect(viewport.visibleSceneRect.size == screen.size)
        }
    }
    @Test func leftExternalDisplayShowsItsOwnPixelsAtMixedScale() throws {
        func solid(_ color:NSColor,width:Int,height:Int) throws -> CGImage {
            let rep=try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
            color.setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:width,height:height)).fill()
            NSGraphicsContext.restoreGraphicsState();return try #require(rep.cgImage)
        }
        let laptop=CGRect(x:0,y:0,width:100,height:100), external=CGRect(x:-200,y:0,width:200,height:150)
        let scene=laptop.union(external)
        let shots=[ScreenShot(frame:laptop,image:try solid(.blue,width:200,height:200)),ScreenShot(frame:external,image:try solid(.red,width:200,height:150))]
        let image=try #require(ImageCompose.composite(shots,union:scene))
        for (frame,red) in [(external,true),(laptop,false)] {
            let viewport=InlineScreenshotViewport(screenFrame:frame,sceneFrame:scene)
            let output=try #require(InlineScreenshotRenderer.render(image:image,state:InlineSnapshot(selection:viewport.visibleSceneRect)))
            let data=try #require(output.tiffRepresentation)
            let bitmap=try #require(NSBitmapImageRep(data:data))
            let color=try #require(bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/2)?.usingColorSpace(.deviceRGB))
            #expect(red ? color.redComponent > 0.9 : color.blueComponent > 0.9)
            #expect(output.size == frame.size)
        }
    }
    @Test(arguments: [false, true])
    func textExportUsesSelectedRedWithoutWhiteBackground(numbered: Bool) throws {
        let rep=try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:300,pixelsHigh:200,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
        NSColor.blue.setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:300,height:200)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image=NSImage(size:CGSize(width:300,height:200));image.addRepresentation(rep)
        let d=InlineScreenshotDocument(size:image.size);d.setSelection(CGRect(origin:.zero,size:image.size))
        let id=d.appendNote(at:CGPoint(x:40,y:100),numbered:numbered,fontSize:18,color:1)
        d.updateNote(id:id,text:"Test")
        guard case .note(let n)=d.state.marks[0] else {Issue.record("missing note");return}
        let body=InlineScreenshotRenderer.layout(n,selection:d.state.selection!).body
        let output=try #require(InlineScreenshotRenderer.render(image:image,state:d.state))
        let data=try #require(output.tiffRepresentation), bitmap=try #require(NSBitmapImageRep(data:data))
        // Padding inside the text hit region must still show the original blue pixels.
        let c=try #require(bitmap.colorAt(x:Int(body.minX+1),y:Int(200-body.midY))?.usingColorSpace(.deviceRGB))
        #expect(c.blueComponent > 0.9);#expect(c.redComponent < 0.1)
        var redGlyphPixels = 0
        var whiteBackgroundPixels = 0
        for y in Int(200-body.maxY)..<Int(200-body.minY) {
            for x in Int(body.minX)..<Int(body.maxX) {
                let pixel=try #require(bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB))
                if pixel.redComponent > 0.7 && pixel.redComponent > pixel.blueComponent + 0.15 && pixel.greenComponent < 0.7 { redGlyphPixels += 1 }
                if pixel.redComponent > 0.9 && pixel.greenComponent > 0.9 && pixel.blueComponent > 0.9 { whiteBackgroundPixels += 1 }
            }
        }
        #expect(redGlyphPixels > 0)
        #expect(whiteBackgroundPixels == 0)
    }
    @Test func nativeViewClippingKeepsEachDisplayOnItsOwnScreen() throws {
        _ = NSApplication.shared
        func solid(_ color:NSColor,width:Int,height:Int) throws -> CGImage {
            let rep=try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
            color.setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:width,height:height)).fill()
            NSGraphicsContext.restoreGraphicsState();return try #require(rep.cgImage)
        }
        let laptop=CGRect(x:0,y:0,width:300,height:240)
        let external=CGRect(x:-500,y:0,width:500,height:360)
        let scene=laptop.union(external)
        let image=try #require(ImageCompose.composite([
            ScreenShot(frame:laptop,image:try solid(.blue,width:600,height:480)),
            ScreenShot(frame:external,image:try solid(.red,width:500,height:360))
        ],union:scene))
        let document=InlineScreenshotDocument(size:scene.size)
        document.setSelection(CGRect(origin:.zero,size:scene.size))
        for (screen,red) in [(external,true),(laptop,false)] {
            let root=NSView(frame:CGRect(origin:.zero,size:screen.size))
            let canvas=InlineScreenshotCanvas(image:image,union:scene,windows:[],document:document)
            canvas.frame=InlineScreenshotViewport(screenFrame:screen,sceneFrame:scene).canvasFrame
            root.addSubview(canvas)
            let bitmap=try #require(root.bitmapImageRepForCachingDisplay(in:root.bounds))
            root.cacheDisplay(in:root.bounds,to:bitmap)
            let pixel=try #require(bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/2)?.usingColorSpace(.deviceRGB))
            #expect(red ? pixel.redComponent > 0.9 : pixel.blueComponent > 0.9)
            #expect(red ? pixel.blueComponent < 0.1 : pixel.redComponent < 0.1)
        }
    }
    @Test func hiddenPanelsPreserveActualVerticalMixedScaleDisplayLayout() throws {
        _ = NSApplication.shared
        func solid(_ color:NSColor,width:Int,height:Int) throws -> CGImage {
            let rep=try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
            color.setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:width,height:height)).fill()
            NSGraphicsContext.restoreGraphicsState();return try #require(rep.cgImage)
        }
        let laptop=CGRect(x:0,y:0,width:1470,height:956)
        let external=CGRect(x:-213,y:956,width:1920,height:1080)
        let scene=laptop.union(external)
        let image=try #require(ImageCompose.composite([
            ScreenShot(frame:laptop,image:try solid(.blue,width:2940,height:1912)),
            ScreenShot(frame:external,image:try solid(.red,width:1920,height:1080))
        ],union:scene))
        let document=InlineScreenshotDocument(size:scene.size)
        document.setSelection(CGRect(origin:.zero,size:scene.size))
        for (screen,red) in [(external,true),(laptop,false)] {
            let viewport=InlineScreenshotViewport(screenFrame:screen,sceneFrame:scene)
            let panel=ScreenshotLayoutTestPanel(contentRect:screen,styleMask:[.borderless],backing:.buffered,defer:false)
            panel.isReleasedWhenClosed=false
            defer { panel.close() }
            let root=NSView(frame:CGRect(origin:.zero,size:screen.size))
            let canvas=InlineScreenshotCanvas(image:image,union:scene,windows:[],document:document)
            canvas.frame=viewport.canvasFrame
            root.addSubview(canvas)
            let initialFrame=canvas.frame
            panel.contentView=root
            #expect(canvas.frame == initialFrame)
            #expect(root.frame.size == screen.size)
            panel.setFrame(screen,display:false)
            root.layoutSubtreeIfNeeded()
            #expect(!panel.isVisible)
            #expect(panel.frame == screen)
            #expect(root.bounds == CGRect(origin:.zero,size:screen.size))
            #expect(canvas.frame == viewport.canvasFrame)
            #expect(canvas.bounds == CGRect(origin:.zero,size:scene.size))
            #expect(canvas.visibleRect == viewport.visibleSceneRect)
            if red { #expect(canvas.frame.minY == -956) }
            let bitmap=try #require(root.bitmapImageRepForCachingDisplay(in:root.bounds))
            root.cacheDisplay(in:root.bounds,to:bitmap)
            let pixel=try #require(bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/2)?.usingColorSpace(.deviceRGB))
            #expect(red ? pixel.redComponent > 0.9 : pixel.blueComponent > 0.9)
            #expect(red ? pixel.blueComponent < 0.1 : pixel.redComponent < 0.1)
        }
    }
    @Test func numberingDeletionAndUndoKeepIdentity() {
        let d = document()
        let first = d.appendNote(at: CGPoint(x: 60,y: 80), numbered: true,fontSize:16,color:0)
        _ = d.appendNote(at: CGPoint(x: 60,y:160), numbered:true,fontSize:16,color:0)
        d.remove(id:first)
        #expect(d.state.nextNumber == 3)
        d.undo()
        #expect(d.state.marks.count == 2)
        d.undo()
        #expect(d.state.nextNumber == 2)
        d.redo()
        #expect(d.state.nextNumber == 3)
    }
    @Test func textAndMovementUndoAsWholeObjects() {
        let d = document()
        let id = d.appendNote(at: CGPoint(x:60,y:80),numbered:true,fontSize:16,color:0)
        d.updateNote(id:id,text:"需要保留筛选\n第二行")
        let before = d.state
        d.moveMark(id:id,from:before,delta:CGPoint(x:30,y:20))
        d.checkpoint(before)
        d.undo()
        #expect(d.state == before)
        d.undo()
        if case .note(let n) = d.state.marks[0] { #expect(n.text.isEmpty); #expect(n.number == 1) }
    }
    @Test func cancelledCreationCannotBeRedone() {
        let d = document(), before = document().state
        _ = d.appendNote(at:CGPoint(x:60,y:80),numbered:true,fontSize:16,color:0)
        d.rollbackCreation(to:before)
        d.redo()
        #expect(d.state == before)
        #expect(d.state.nextNumber == 1)
    }
    @Test func cropDoesNotRepositionBodyOrBringOutsideNoteBack() {
        let d = document()
        let id = d.appendNote(at:CGPoint(x:200,y:220),numbered:true,fontSize:16,color:0)
        d.updateNote(id:id,text:"原位置说明")
        guard case .note(let note)=d.state.marks[0] else { Issue.record("missing note");return }
        let old = InlineScreenshotRenderer.layout(note,selection:d.state.selection!).body
        d.setSelection(CGRect(x:220,y:20,width:300,height:300))
        let next = InlineScreenshotRenderer.layout(note,selection:d.state.selection!).body
        #expect(old == next)
        #expect(!d.state.selection!.contains(note.anchor))
    }
    @Test func cropChangesDoNotStretchOrMoveNotes() {
        let d = document()
        _ = d.appendNote(at:CGPoint(x:70,y:80),numbered:true,fontSize:16,color:0)
        let original = d.state.marks
        d.setSelection(CGRect(x:30,y:40,width:300,height:200))
        #expect(d.state.marks == original)
        d.undo()
        #expect(d.state.selection == CGRect(x:20,y:20,width:560,height:360))
    }
    @Test func bodyWrapsInsideCropAndEmptyNoteHasOnlyCircle() {
        let s = CGRect(x:20,y:20,width:300,height:200)
        let n = InlineNote(id:UUID(),number:12,anchor:CGPoint(x:290,y:180),text:"说明正文，需要换行，保持在选区内。",fontSize:16,color:0)
        let layout = InlineScreenshotRenderer.layout(n,selection:s)
        #expect(s.contains(layout.bounds))
        var empty = n; empty.text = ""
        let blank = InlineScreenshotRenderer.layout(empty,selection:s)
        #expect(blank.body.isEmpty)
        #expect(!blank.circle.isEmpty)
    }
    @Test func exportPreservesRetinaPixelsAndCropContent() throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:400,pixelsHigh:200,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        rep.size = CGSize(width:200,height:100)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
        NSColor.blue.setFill(); NSBezierPath(rect:CGRect(x:0,y:0,width:400,height:200)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size:rep.size); image.addRepresentation(rep)
        let state = InlineSnapshot(selection:CGRect(x:20,y:10,width:60,height:40))
        let output = try #require(InlineScreenshotRenderer.render(image:image,state:state))
        let cg = try #require(output.cgImage())
        #expect(cg.width == 120); #expect(cg.height == 80)
        #expect(output.size == CGSize(width:60,height:40))
    }
    @Test func notePreviewAndOutputUseIdenticalLayout() throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:600,pixelsHigh:400,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let image = NSImage(size:CGSize(width:600,height:400)); image.addRepresentation(rep)
        let d = document()
        let id = d.appendNote(at:CGPoint(x:80,y:220),numbered:true,fontSize:16,color:0)
        d.updateNote(id:id,text:"第一条说明\n第二行")
        let output = try #require(InlineScreenshotRenderer.render(image:image,state:d.state))
        #expect(output.cgImage()?.width == 560)
        #expect(output.cgImage()?.height == 360)
        let tiff = try #require(output.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data:tiff))
        let circleEdge = try #require(bitmap.colorAt(x:51,y:160)?.usingColorSpace(.deviceRGB))
        #expect(circleEdge.greenComponent > 0.6)
        #expect(circleEdge.redComponent < 0.4)
        if case .note(let n) = d.state.marks[0] { #expect(n.number == 1); #expect(n.text == "第一条说明\n第二行") }
    }
}
