import AppKit
import Foundation

enum LitheIntegrationContract {
    static let applicationBundleIdentifier = "com.lithe.app"
    static let generatedFilesPasteboardType = NSPasteboard.PasteboardType(
        "com.lithe.generated-files"
    )
    static let requestIDPasteboardType = NSPasteboard.PasteboardType(
        "com.lithe.request-id"
    )
}

struct LitheClipboardMetadata: Equatable {
    let isGeneratedByLithe: Bool
    let requestID: UUID?

    init(pasteboard: NSPasteboard) {
        let types = pasteboard.types ?? []
        isGeneratedByLithe = types.contains(
            LitheIntegrationContract.generatedFilesPasteboardType
        )

        let rawRequestID = pasteboard.string(
            forType: LitheIntegrationContract.requestIDPasteboardType
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        requestID = rawRequestID.flatMap(UUID.init(uuidString:))
    }
}

struct LitheInvocation: Equatable {
    let applicationURL: URL
    let fileURLs: [URL]
}

struct LitheApplicationClient {
    let locateApplication: () -> URL?
    let openFiles: (LitheInvocation) -> Void

    static func makeOpenConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        return configuration
    }

    static let live = LitheApplicationClient(
        locateApplication: {
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: LitheIntegrationContract.applicationBundleIdentifier
            )
        },
        openFiles: { invocation in
            NSWorkspace.shared.open(
                invocation.fileURLs,
                withApplicationAt: invocation.applicationURL,
                configuration: makeOpenConfiguration()
            ) { _, error in
                if let error {
                    NSLog("Copied: unable to open selected images in Lithe (error=%@)", error.localizedDescription)
                }
            }
        }
    )
}

enum LitheCompressionEligibility {
    private static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png"]

    static func invocation(
        for fileURLs: [URL]?,
        isGeneratedByLithe: Bool,
        client: LitheApplicationClient
    ) -> LitheInvocation? {
        guard !isGeneratedByLithe,
              let fileURLs,
              !fileURLs.isEmpty,
              fileURLs.allSatisfy(isSupportedRegularImage),
              let applicationURL = client.locateApplication() else {
            return nil
        }

        return LitheInvocation(
            applicationURL: applicationURL,
            fileURLs: fileURLs
        )
    }

    private static func isSupportedRegularImage(_ url: URL) -> Bool {
        guard url.isFileURL,
              supportedExtensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .isDirectoryKey,
                  .isSymbolicLinkKey,
                  .isAliasFileKey,
              ]) else {
            return false
        }

        return values.isRegularFile == true
            && values.isDirectory != true
            && values.isSymbolicLink != true
            && values.isAliasFile != true
    }
}
