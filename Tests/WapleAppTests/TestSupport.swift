import Foundation
@testable import Waple
import WapleLibrary

// MARK: - URL 쿼리 파라미터 추출 (순수 함수)

/// URL 의 쿼리스트링에서 이름으로 단일 값 추출. Workshop API 테스트용.
func queryValue(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == name }?.value
}

// MARK: - MainActor Task yield (순수 비동기 헬퍼)

/// VM 콜백이 Task { @MainActor } 로 한 번 홉하므로 메인 액터 큐를 비워 적용을 기다린다.
@MainActor func pump() async {
    for _ in 0..<3 { await Task.yield() }
}

// MARK: - 필터링 결과 ID 추출 (순수 함수)

/// 검색 없이 criteria 만 적용한 결과의 id 배열. V06/V07 감사 회귀 테스트용.
func applyIds(_ entries: [LibraryEntry], _ c: LibraryFilterCriteria) -> [String] {
    LibraryFiltering.apply(entries, search: "", criteria: c, sort: .recentFirst,
                           isFavorite: { _ in false }).map(\.id)
}

// MARK: - URLRecorder (스레드-안전 URL 수집 목 객체)

/// 네트워크 요청 URL 을 직렬화하여 기록. transport 주입 테스트에서 호출 순서 검증용.
final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    func record(_ u: URL) { lock.lock(); stored.append(u); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return stored }
}
