import Foundation

struct EntityDetectorWarmUpResult: Equatable {
    let matchedURL: Bool
    let matchedPhoneNumber: Bool
    let matchedDate: Bool
}

enum EntityDetectorWarmUp {
    static let urlCandidate = "https://example.com/copied-warm-up"
    static let phoneNumberCandidate = "+86 138 0013 8000"
    static let dateCandidate = "2040年1月2日"

    @discardableResult
    static func perform() -> EntityDetectorWarmUpResult {
        EntityDetectorWarmUpResult(
            matchedURL: URLDetector().detect(in: urlCandidate)?.kind == .url,
            matchedPhoneNumber: PhoneNumberDetector().detect(in: phoneNumberCandidate)?.kind
                == .phoneNumber,
            matchedDate: DateTimeDetector().detect(in: dateCandidate)?.kind == .dateTime
        )
    }
}
