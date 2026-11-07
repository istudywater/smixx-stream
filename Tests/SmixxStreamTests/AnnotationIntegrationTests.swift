import Foundation
import AppKit
import PDFKit
import Testing
import StreamMedia
@testable import SmixxStream

@MainActor struct AnnotationIntegrationTests {
    @Test func rotatedCroppedPDFRetainsCitationAndPageGeometryAtHighResolution() throws {
        let data = NSMutableData()
        var box = CGRect(x:0,y:0,width:600,height:800)
        let consumer = try #require(CGDataConsumer(data:data))
        let context = try #require(CGContext(consumer:consumer,mediaBox:&box,nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1))
        context.fill(CGRect(x:100,y:200,width:400,height:300))
        context.endPDFPage(); context.closePDF()
        let document = try #require(PDFDocument(data:data as Data))
        let page = try #require(document.page(at:0))
        page.setBounds(CGRect(x:100,y:200,width:400,height:300),for:.cropBox)
        page.rotation = 90
        let session = VideoSourceSession(); session.document = document; session.sourceID = "version-A"
        session.scopeURL = URL(fileURLWithPath:"/fixtures/Score.pdf")
        var result: CapturedFrame?
        session.frame = { result = $0 }
        session.renderPDF(page:0,zoom:1)
        let first = try #require(result)
        #expect(first.citation == SourceCitation(filename:"Score.pdf",page:1,pages:1))
        #expect(first.contextID == "version-A-page-0")
        #expect(abs(Double(first.image.width)/Double(first.image.height)-0.75)<0.01)
        session.renderPDF(page:0,zoom:3)
        let large = try #require(result)
        #expect(large.image.width >= first.image.width*2)
        #expect(large.contextID == first.contextID)
        #expect(large.citation == first.citation)
    }
    @Test func snapshotArchiveRoundtripPreservesImageCitationAndUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let archive = AnnotationArchive(directory:directory)
        let image = try #require(ProgramComposition(image:nil,slate:"Saved frame").render(width:320,height:180))
        let id = UUID().uuidString
        let frame = CapturedFrame(image:image,hostTime:123,sourceID:"source-version-A",contextID:id,citation:SourceCitation(filename:"Lesson.mp4",seconds:14.125))
        var history = InkHistory()
        history.replace([InkStroke(points:[InkPoint(0.5,0.5)],red:1,green:0,blue:0,opacity:1,width:0.01)])
        try archive.save(histories:[id:history],snapshots:[id:frame])
        let (saved,frames) = try archive.load()
        #expect(saved.histories[id]?.strokes == history.strokes)
        #expect(saved.histories[id]?.undoStack.count == 1)
        #expect(frames[id]?.citation?.location == "00:00:14.125")
        #expect(frames[id]?.image.width == 320)
        let corrupt = Data("unreadable previous archive".utf8)
        try corrupt.write(to:archive.index)
        #expect(throws:(any Error).self) { try archive.load() }
        #expect(try Data(contentsOf:archive.index) == corrupt)
    }
}
