import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import StreamMedia

struct AnnotationTests {
    func whitePage() -> CGImage {
        let c = CGContext(data: nil,width: 600,height: 800,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(gray: 1,alpha: 1)); c.fill(CGRect(x: 0,y: 0,width: 600,height: 800)); return c.makeImage()!
    }
    func stroke() -> InkStroke { InkStroke(points: [InkPoint(0.2,0.5),InkPoint(0.8,0.5)],red: 1,green: 0,blue: 0,opacity: 1,width: 0.02) }
    @Test func inkTracksSourceAcrossZoomPanAndResolution() throws {
        var c = ProgramComposition(image: whitePage()); c.strokes = [stroke()]
        let initial = c.contentRect(width: 1920,height: 1080)
        #expect(abs(initial.width-810) < 0.01)
        #expect(c.sourcePoint(InkPoint(0,0.5)) == nil) // letterbox is not paper
        #expect(c.sourcePoint(InkPoint(0.5,0.5)) == InkPoint(0.5,0.5))
        c.zoom = 3; c.pan = InkPoint(0.1,-0.2)
        let rect = c.contentRect(width: 1920,height: 1080)
        let p = try #require(c.sourcePoint(InkPoint(rect.midX/1920,rect.midY/1080)))
        #expect(abs(p.x-0.5)<0.0001 && abs(p.y-0.5)<0.0001)
        let half = c.contentRect(width: 960,height: 540)
        #expect(abs(half.minX*2-rect.minX)<0.001)
        #expect(abs(half.height*2-rect.height)<0.001)
        c.pan = InkPoint(999,-999)
        let bounded = c.contentRect(width: 1920,height: 1080)
        #expect(bounded.minX <= 0 && bounded.maxY >= 1080)
    }
    @Test func pageHistoriesUndoRedoClearAndRoundtrip() throws {
        var pages = ["documentA-page0":InkHistory(),"documentA-page1":InkHistory()]
        pages["documentA-page0"]!.replace([stroke()]); pages["documentA-page0"]!.replace([])
        pages["documentA-page0"]!.undo()
        #expect(pages["documentA-page0"]!.strokes.count == 1)
        #expect(pages["documentA-page1"]!.strokes.isEmpty)
        pages["documentA-page0"]!.redo(); #expect(pages["documentA-page0"]!.strokes.isEmpty)
        let decoded = try JSONDecoder().decode([String:InkHistory].self,from: JSONEncoder().encode(pages))
        #expect(decoded["documentA-page0"]!.undoStack.count == 2)
        #expect(decoded["documentB-page0"] == nil)
    }
    @Test func citationUsesPageCountsAndExactRoundedSourceTime() {
        #expect(SourceCitation(filename:"Score.pdf",page:3,pages:12).location == "page 3 of 12")
        #expect(SourceCitation(filename:"Video.mp4",seconds:59.9996).location == "00:01:00.000")
        #expect(SourceCitation(filename:"Video.mp4",seconds:3661.125).location == "01:01:01.125")
        #expect(SourceCitation(filename:"Bad.pdf",page:0,pages:12).location == nil)
        #expect(SourceCitation(filename:"Bad.mp4",seconds: .nan).location == nil)
    }
    @Test func brandedPNGIsOpaquePreservesPictureAndRefusesOverwrite() throws {
        var c = ProgramComposition(image:whitePage()); c.strokes = [stroke()]
        let image = try HandoutExporter.render(c,citation:SourceCitation(filename:"Étude 音楽.pdf",page:3,pages:12))
        #expect(image.width == 1920 && image.height == 1180)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url = folder.appendingPathComponent("handout.png")
        try HandoutExporter.write(image,to:url)
        let original = try Data(contentsOf:url)
        #expect(throws:(any Error).self) { try HandoutExporter.write(image,to:url) }
        #expect(try Data(contentsOf:url) == original)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL,nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source,0,nil))
        #expect(decoded.width == 1920 && decoded.height == 1180)
        #expect(decoded.colorSpace?.name == CGColorSpace.sRGB)
        let long = try HandoutExporter.render(c,citation:SourceCitation(filename:String(repeating:"長",count:160)+".pdf",page:1,pages:1))
        #expect(long.width > 1920)
        #expect(throws:(any Error).self) { try HandoutExporter.render(c,citation:SourceCitation(filename:"/private/Score.pdf",page:1,pages:1)) }
    }
}
