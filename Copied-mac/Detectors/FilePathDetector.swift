import Foundation

/// 文件路径检测器 — 检测 ~ 或 / 开头且文件系统中存在的路径。
struct FilePathDetector: ContentDetectorProtocol {
    let kind = ContentKind.filePath
    let priority = 200

    func detect(in text: String) -> ContentDetection? {
        guard text.hasPrefix("/") || text.hasPrefix("~") else { return nil }

        let expanded = (text as NSString).expandingTildeInPath

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            return nil
        }

        return ContentDetection(kind: .filePath, value: expanded)
    }
}
