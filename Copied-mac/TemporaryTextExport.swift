import AppKit
import Darwin
import Foundation

enum TemporaryTextExport {
    private static let filenamePrefix = "Copied-TextExport-"
    private static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    private static let queue = DispatchQueue(
        label: "com.copied.text-export",
        qos: .userInitiated
    )

    static func prepare(text: String, completion: @escaping (URL?) -> Void) {
        queue.async {
            let url = write(text: text)
            DispatchQueue.main.async { completion(url) }
        }
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func cleanupExpiredFiles(now: Date = Date()) {
        queue.async {
            let directory = FileManager.default.temporaryDirectory
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for file in files where owns(file) {
                guard let values = try? file.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .isRegularFileKey,
                ]), values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) > maximumAge else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func write(text: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filenamePrefix)\(UUID().uuidString).txt")
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return nil }

        var succeeded = true
        var buffer: [UInt8] = []
        buffer.reserveCapacity(64 * 1_024)
        for byte in text.utf8 {
            buffer.append(byte)
            if buffer.count == buffer.capacity {
                succeeded = writeAll(buffer, to: descriptor)
                buffer.removeAll(keepingCapacity: true)
                if !succeeded { break }
            }
        }
        if succeeded, !buffer.isEmpty {
            succeeded = writeAll(buffer, to: descriptor)
        }
        if Darwin.close(descriptor) != 0 { succeeded = false }
        guard succeeded else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var offset = 0
            while offset < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if result == 0 { return false }
                offset += result
            }
            return true
        }
    }

    private static func owns(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix(filenamePrefix), name.hasSuffix(".txt") else { return false }
        let uuidStart = name.index(name.startIndex, offsetBy: filenamePrefix.count)
        let uuidEnd = name.index(name.endIndex, offsetBy: -4)
        return UUID(uuidString: String(name[uuidStart..<uuidEnd])) != nil
    }
}
