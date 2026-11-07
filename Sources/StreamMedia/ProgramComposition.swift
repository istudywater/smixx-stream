import Foundation
import CoreGraphics
import CoreText
import StreamCore

/// The immutable student-facing composition. Future annotation paths belong here,
/// not on an independent UI-only overlay, so export and recording stay identical.
public struct ProgramComposition: @unchecked Sendable {
    public var image: CGImage?
    public var scaling: Scaling
    public var zoom: Double
    public var slate: String?
    public var pan = InkPoint(0, 0)
    public var strokes: [InkStroke] = []
    public init(image: CGImage?, scaling: Scaling = .fit, zoom: Double = 1, slate: String? = nil) {
        self.image = image; self.scaling = scaling; self.zoom = zoom; self.slate = slate
    }
    public func draw(in context: CGContext, width: Int, height: Int) {
        let canvas = CGRect(x: 0,y: 0,width: width,height: height)
        context.saveGState(); defer { context.restoreGState() }
        context.setFillColor(CGColor(gray: 0,alpha: 1)); context.fill(canvas)
        context.clip(to: canvas)
        if let image, slate == nil {
            let rect = contentRect(width: Double(width), height: Double(height))
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            context.clip(to: rect)
            for stroke in strokes where !stroke.points.isEmpty {
                context.saveGState()
                context.setAlpha(stroke.opacity)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                context.setStrokeColor(CGColor(red: stroke.red, green: stroke.green, blue: stroke.blue, alpha: 1))
                context.setFillColor(CGColor(red: stroke.red, green: stroke.green, blue: stroke.blue, alpha: 1))
                let lineWidth = max(0.5, stroke.width * rect.width)
                context.setLineWidth(lineWidth); context.setLineCap(.round); context.setLineJoin(.round)
                let points = stroke.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
                if points.count == 1 {
                    context.fillEllipse(in: CGRect(x: points[0].x-lineWidth/2,y: points[0].y-lineWidth/2,width: lineWidth,height: lineWidth))
                } else {
                    context.beginPath(); context.addLines(between: points); context.strokePath()
                }
                context.endTransparencyLayer(); context.restoreGState()
            }
        } else {
            let text = slate ?? "Ready for the lesson"
            let font = CTFontCreateWithName("Helvetica" as CFString,CGFloat(width)/38,nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1,alpha: 1)]))
            let bounds = CTLineGetBoundsWithOptions(line,[])
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: (CGFloat(width)-bounds.width)/2,y: (CGFloat(height)-bounds.height)/2)
            CTLineDraw(line,context)
        }
    }
    public func contentRect(width: Double, height: Double) -> CGRect {
        guard let image else { return .zero }
        let base = Routing.videoRect(width: Double(image.width), height: Double(image.height), canvasWidth: width, canvasHeight: height, scaling: scaling)
        let z = zoom.isFinite ? max(1, min(4, zoom)) : 1
        let w = base.width * z, h = base.height * z
        let dx = max(-max(0,(w-width)/2),min(max(0,(w-width)/2),pan.x * width))
        let dy = max(-max(0,(h-height)/2),min(max(0,(h-height)/2),pan.y * height))
        return CGRect(x: (width-w)/2+dx,y: (height-h)/2+dy,width: w,height: h)
    }
    public func sourcePoint(_ point: InkPoint) -> InkPoint? {
        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        let rect = contentRect(width: 1920,height: 1080)
        let x = point.x * 1920, y = point.y * 1080
        guard rect.width > 0, rect.height > 0, rect.contains(CGPoint(x: x,y: y)) else { return nil }
        return InkPoint((x-rect.minX)/rect.width,(y-rect.minY)/rect.height)
    }
    public func render(width: Int = 1920,height: Int = 1080) -> CGImage? {
        guard let context = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(in: context,width: width,height: height)
        return context.makeImage()
    }
}
