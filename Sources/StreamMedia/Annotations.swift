import Foundation
import CoreGraphics

public enum AnnotationTool: String, Codable, CaseIterable { case hand, pen, highlighter, eraser }
public struct InkPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}
public struct InkStroke: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var points: [InkPoint]
    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double
    /// Width relative to the oriented source width, independent of raster resolution.
    public var width: Double
    public init(points: [InkPoint], red: Double, green: Double, blue: Double, opacity: Double, width: Double) {
        self.points = points; self.red = red; self.green = green; self.blue = blue; self.opacity = opacity; self.width = width
    }
}
public struct InkHistory: Codable, Sendable {
    public var strokes: [InkStroke] = []
    public var undoStack: [[InkStroke]] = []
    public var redoStack: [[InkStroke]] = []
    public init() {}
    public mutating func replace(_ value: [InkStroke]) {
        guard value != strokes else { return }
        undoStack.append(strokes); if undoStack.count > 50 { undoStack.removeFirst() }
        strokes = value; redoStack = []
    }
    public mutating func undo() { guard let value = undoStack.popLast() else { return }; redoStack.append(strokes); strokes = value }
    public mutating func redo() { guard let value = redoStack.popLast() else { return }; undoStack.append(strokes); strokes = value }
}
public struct SourceCitation: Codable, Sendable, Equatable {
    public var filename: String
    public var page: Int?
    public var pages: Int?
    public var seconds: Double?
    public init(filename: String, page: Int? = nil, pages: Int? = nil, seconds: Double? = nil) {
        self.filename = filename; self.page = page; self.pages = pages; self.seconds = seconds
    }
    public var location: String? {
        if let page, let pages, page >= 1, page <= pages { return "page \(page) of \(pages)" }
        if let seconds, seconds.isFinite, seconds >= 0, seconds < 1e12 {
            let ms = Int64((seconds * 1000).rounded())
            return String(format: "%02lld:%02lld:%02lld.%03lld", ms/3_600_000,(ms/60_000)%60,(ms/1000)%60,ms%1000)
        }
        return nil
    }
}
