import Foundation

struct BaseAssetsWarningGate {
    static let message = "공유 기본 에셋을 찾지 못해 일부 씬 요소가 표시되지 않습니다 — 설정 > 에셋·도구에서 폴더를 지정하세요."

    private var fingerprint: String?
    private var didPresent = false

    init() {}

    mutating func presentIfNeeded<R>(
        after swap: Result<[R], Error>,
        fingerprint currentFingerprint: String,
        missingRequiredSharedAssets: (R) -> Bool?,
        present: (String) -> Bool
    ) {
        guard case .success(let renderers) = swap else {
            return
        }
        if fingerprint != currentFingerprint {
            fingerprint = currentFingerprint
            didPresent = false
        }
        guard !didPresent,
              renderers.compactMap(missingRequiredSharedAssets).contains(true) else {
            return
        }
        if present(Self.message) {
            didPresent = true
        }
    }
}
