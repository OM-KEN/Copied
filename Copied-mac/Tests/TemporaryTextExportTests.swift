import Foundation

private enum Failure: Error { case failed(String) }

@main
enum TemporaryTextExportTests {
    static func main() throws {
        let fullText = String(repeating: "👨‍👩‍👧‍👦 clipboard line\n", count: 20_000)
        guard let url = TemporaryTextExport.write(text: fullText) else {
            throw Failure.failed("streaming export failed")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let written = try String(contentsOf: url, encoding: .utf8)
        try expect(written == fullText, "streaming export changed full text")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o600, "export permissions are not 0600")
        try expect(url.lastPathComponent.hasPrefix("Copied-TextExport-"), "ownership prefix missing")

        var preparedURL: URL?
        var preparationFinished = false
        TemporaryTextExport.prepare(text: "prepared export") { result in
            preparedURL = result
            preparationFinished = true
        }
        let deadline = Date().addingTimeInterval(3)
        while !preparationFinished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard let preparedURL else {
            throw Failure.failed("background export preparation did not return a URL")
        }
        let preparedText = try String(contentsOf: preparedURL, encoding: .utf8)
        try expect(preparedText == "prepared export", "prepared export changed text")
        TemporaryTextExport.remove(preparedURL)
        try expect(!FileManager.default.fileExists(atPath: preparedURL.path),
                   "stale/failed export cleanup did not remove the file")
        print("TemporaryTextExportTests: PASS")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.failed(message) }
    }
}
