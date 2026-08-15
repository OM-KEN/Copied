import AppKit
import Foundation

enum ApplicationRelaunchError: LocalizedError {
    case missingRunningApplication

    var errorDescription: String? {
        switch self {
        case .missingRunningApplication:
            String(localized: "系统没有返回新的 Copied 实例。")
        }
    }
}

@MainActor
final class ApplicationRelauncher {
    typealias LaunchCompletion = (Result<Void, Error>) -> Void
    typealias LaunchNewInstance = (@escaping LaunchCompletion) -> Void

    static let shared = ApplicationRelauncher(
        launchNewInstance: { completion in
            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL,
                configuration: makeOpenConfiguration()
            ) { runningApplication, error in
                if let error {
                    completion(.failure(error))
                } else if runningApplication != nil {
                    completion(.success(()))
                } else {
                    completion(.failure(ApplicationRelaunchError.missingRunningApplication))
                }
            }
        },
        terminateCurrent: {
            NSApp.terminate(nil)
        }
    )

    static func makeOpenConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.addsToRecentItems = false
        return configuration
    }

    private let launchNewInstance: LaunchNewInstance
    private let terminateCurrent: () -> Void
    private var pendingRequestID: UUID?
    private var hasRequestedTermination = false

    init(
        launchNewInstance: @escaping LaunchNewInstance,
        terminateCurrent: @escaping () -> Void
    ) {
        self.launchNewInstance = launchNewInstance
        self.terminateCurrent = terminateCurrent
    }

    func relaunch(onFailure: @escaping (Error) -> Void) {
        guard pendingRequestID == nil, !hasRequestedTermination else { return }

        let requestID = UUID()
        pendingRequestID = requestID
        launchNewInstance { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.pendingRequestID == requestID else { return }
                self.pendingRequestID = nil
                switch result {
                case .success:
                    self.hasRequestedTermination = true
                    self.terminateCurrent()
                case let .failure(error):
                    onFailure(error)
                }
            }
        }
    }
}
