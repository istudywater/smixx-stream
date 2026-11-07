import Foundation
import StreamMedia
import ImageIO

struct SavedSnapshot: Codable {
    var id: String
    var sourceID: String
    var citation: SourceCitation
}
struct SavedAnnotations: Codable {
    var version = 1
    var histories: [String: InkHistory]
    var snapshots: [SavedSnapshot]
}
/// Own app data only; source PDFs and movies are never modified.
struct AnnotationArchive {
    let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0].appendingPathComponent("SmixxStream/Annotations")) { self.directory = directory }
    var index: URL { directory.appendingPathComponent("index.json") }
    func load() throws -> (SavedAnnotations, [String: CapturedFrame]) {
        guard FileManager.default.fileExists(atPath: index.path) else { return (SavedAnnotations(histories: [:],snapshots: []),[:]) }
        let saved = try JSONDecoder().decode(SavedAnnotations.self,from: Data(contentsOf: index))
        guard saved.version == 1 else { throw SourceError.message("Unsupported annotation archive version; existing data was preserved.") }
        var frames: [String: CapturedFrame] = [:]
        for item in saved.snapshots {
            guard UUID(uuidString: item.id) != nil else { throw SourceError.message("Invalid snapshot identity; annotation archive preserved.") }
            let url = directory.appendingPathComponent(item.id+".png")
            guard let source = CGImageSourceCreateWithURL(url as CFURL,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw SourceError.message("A saved annotation snapshot is missing or unreadable; archive preserved.") }
            frames[item.id] = CapturedFrame(image: image,hostTime: 0,sourceID: item.sourceID,contextID: item.id,citation: item.citation)
        }
        return (saved,frames)
    }
    func save(histories: [String: InkHistory], snapshots: [String: CapturedFrame]) throws {
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        var records: [SavedSnapshot] = []
        for (id,frame) in snapshots {
            guard let citation = frame.citation, UUID(uuidString: id) != nil else { continue }
            let url = directory.appendingPathComponent(id+".png")
            if !FileManager.default.fileExists(atPath: url.path) { try HandoutExporter.write(frame.image,to: url) }
            records.append(SavedSnapshot(id: id,sourceID: frame.sourceID,citation: citation))
        }
        let data = try JSONEncoder().encode(SavedAnnotations(histories: histories,snapshots: records))
        try data.write(to: index,options: .atomic)
    }
}
