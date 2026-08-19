import Foundation

struct BaseAssetsWarningGate {
    /// **이미 현지화된 문자열.** 싱크(StatusBanner)는 `Label(msg, systemImage:)` 의 StringProtocol
    /// 오버로드라 번역하지 않는다 — 생산 지점인 여기서 완성해서 넘긴다(AppDelegate.notify 호출부와 같은 규약).
    ///
    /// F840: 종전에는 생 한국어 `static let` 이라 영어 시스템에서 이 배너만 한국어로 떴고,
    /// 커버리지 오라클의 패턴(NSLocalizedString / 표시 API)에도 걸리지 않아 아무도 몰랐다
    /// (StatusBanner.swift 의 주석이 "BaseAssetsWarningGate 만 미착수"로 남겨 둔 자리다).
    /// `let` 이 아니라 계산 프로퍼티인 이유는 번역 조회를 접근 시점에 하기 위해서다.
    static var message: String {
        NSLocalizedString("공유 기본 에셋을 찾지 못해 일부 씬 요소가 표시되지 않습니다 — 설정 > 에셋·도구에서 폴더를 지정하세요.",
                          comment: "공유 기본 에셋 부재 경고 배너")
    }

    private var warnedFingerprints: Set<String> = []

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
        guard !warnedFingerprints.contains(currentFingerprint),
              renderers.compactMap(missingRequiredSharedAssets).contains(true) else {
            return
        }
        if present(Self.message) {
            warnedFingerprints.insert(currentFingerprint)
        }
    }
}
