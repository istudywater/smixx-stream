import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

public enum HandoutExporter {
    private static func line(_ text: String, size: CGFloat, color: CGColor = CGColor(gray: 1,alpha: 1), bold: Bool = false) -> CTLine {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString,size,nil)
        return CTLineCreateWithAttributedString(NSAttributedString(string: text,attributes: [.init(kCTFontAttributeName as String): font,.init(kCTForegroundColorAttributeName as String): color]))
    }
    public static func render(_ composition: ProgramComposition, citation: SourceCitation) throws -> CGImage {
        guard !citation.filename.isEmpty, citation.filename == (citation.filename as NSString).lastPathComponent,
              let location = citation.location, composition.image != nil, composition.slate == nil else {
            throw RecordingError.message("A visible PDF page or frozen video frame with valid source attribution is required.")
        }
        // Widen very long filenames without shrinking below 24 px or truncating identity.
        let filenameLine = line(citation.filename,size: 24)
        let textWidth = CTLineGetTypographicBounds(filenameLine,nil,nil,nil)
        let width = max(1920,Int(ceil(textWidth + 460)))
        guard width <= 8192 else { throw RecordingError.message("The source filename is too long for a readable handout. Rename a copy of the source and reconnect it.") }
        let pictureHeight = Int((Double(width)*9/16).rounded()), footer = 100
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,width: width,height: pictureHeight+footer,bitsPerComponent: 8,bytesPerRow: 0,space: colorSpace,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RecordingError.message("Cannot allocate the PNG export.") }
        context.setFillColor(CGColor(srgbRed: 0.047,green: 0.063,blue: 0.125,alpha: 1))
        context.fill(CGRect(x: 0,y: 0,width: width,height: pictureHeight+footer))
        context.saveGState(); context.translateBy(x: 0,y: CGFloat(footer))
        composition.draw(in: context,width: width,height: pictureHeight); context.restoreGState()
        // Vector reconstruction of the supplied five-bar horizontal brand lockup.
        let violet = CGColor(srgbRed: 0.608,green: 0.302,blue: 0.890,alpha: 1)
        context.setFillColor(violet)
        for (i,h) in [18.0,32,46,32,18].enumerated() {
            let rect = CGRect(x: 24+Double(i)*11,y: (100-h)/2,width: 7,height: h)
            context.addPath(CGPath(roundedRect: rect,cornerWidth: 3.5,cornerHeight: 3.5,transform: nil)); context.fillPath()
        }
        context.textMatrix = .identity
        let smixx = line("Smixx",size: 29,bold: true)
        context.textPosition = CGPoint(x: 90,y: 39); CTLineDraw(smixx,context)
        context.textPosition = CGPoint(x: 98+CTLineGetTypographicBounds(smixx,nil,nil,nil),y: 39)
        CTLineDraw(line("Stream",size: 29,color: violet,bold: true),context)
        for (textLine,y) in [(filenameLine,CGFloat(58)),(line(location,size: 24),CGFloat(26))] {
            context.textPosition = CGPoint(x: CGFloat(width)-24-CTLineGetTypographicBounds(textLine,nil,nil,nil),y: y)
            CTLineDraw(textLine,context)
        }
        guard let image = context.makeImage() else { throw RecordingError.message("Cannot create the PNG image.") }
        return image
    }
    public static func write(_ image: CGImage, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw RecordingError.message("Choose a new filename; existing PNGs are not overwritten.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else { throw RecordingError.message("Cannot create PNG encoder.") }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw RecordingError.message("PNG encoding failed.") }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try (data as Data).write(to: temporary,options: .atomic)
        try FileManager.default.moveItem(at: temporary,to: url)
    }
}
