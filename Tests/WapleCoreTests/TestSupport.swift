import Foundation
@testable import WapleCore

// WapleCoreTests 공용 인코딩 스캐폴 — 파일마다 중복되던 LE i32/f32 로컬 인코더 통합(2026-07-19 테스트 위생 정리).
// 규약: 이 바이트가 곧 파서 테스트의 입력 — 기존 로컬 사본과 바이트 동일해야 한다.

/// LE u32 4바이트. truncatingIfNeeded — i32(-1)(TEXB imageFormat v3) 표현에 쓰인다.
func i32(_ v: Int) -> [UInt8] {
    let u = UInt32(truncatingIfNeeded: v)
    return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
}

/// 청크를 순서대로 이어붙인다. 긴 `+` 체인(6~10항)은 항마다 오버로드 후보가 곱해져 타입체커가
/// 지수 폭발한다 — 구형 툴체인(CI 러너 Xcode 16.2 / Swift 6.0.3)에선 "unable to type-check this
/// expression in reasonable time" 컴파일 에러로 CI 를 세우고, 최신 툴체인에서도 식마다 수백 ms 를
/// 태운다. 인자 타입이 [UInt8] 로 고정되는 가변인자 헬퍼는 항 수에 선형이다.
func bytes(_ chunks: [UInt8]...) -> [UInt8] { chunks.flatMap { $0 } }

/// NUL 종단 태그 바이트("TEXV0005" + 0x00) — 컨테이너 시그니처/블록 헤더 규약.
func tag(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }

/// LE f32 4바이트(비트패턴 그대로).
func f32(_ v: Float) -> [UInt8] {
    let u = v.bitPattern
    return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
}

// MARK: - 공용 팩토리 (2026-07-31 중복 제거 패스)

/// 문자열 파일 쌍으로 인메모리 ScenePackage 를 합성한다 — 11개 테스트 파일에 동일 사본이 있었다.
func pkg(_ files: [(String, String)]) throws -> ScenePackage {
    try ScenePackage.parse(ScenePackageTests.makePkg(files.map { ($0.0, Data($0.1.utf8)) }))
}

/// JSON 문자열을 [String: Any] 로 역직렬화 — 파티클 계열 6개 테스트 파일에 동일 사본이 있었다.
func json(_ s: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: s.data(using: .utf8)!) as! [String: Any]
}
// MARK: - 동봉 WEAssets 루트 (2026-08-25 통합)

/// 동봉 `WEAssets` 루트. **이 파일의 위치**에서 리포 루트로 거슬러 올라간다.
///
/// **[2026-08-25] 종전엔 작업 디렉터리(cwd)에서 8단계 상향 탐색했다.** 그 사본이 9곳에 흩어져
/// 있었고 전부 같은 함정을 공유했다 — 실패하면 `nil` 을 돌려주고 호출부가 `XCTSkip` 으로
/// 사라진다. `cd /tmp && swift test --package-path <repo>` 나 Xcode 실행처럼 cwd 가 리포 밖인
/// 실행에서는 동봉 자산 오라클 8건이 통째로 조용히 빠지고, 그 상태로 초록이 뜬다.
///
/// **WEAssets 2,940 파일은 리포에 커밋돼 있다.** 즉 "못 찾음" 은 환경 조건이 아니라 버그다.
/// 소스 파일 위치는 cwd 와 달리 실행 방식에 흔들리지 않는다 — `LocalizationCoverageTests` 와
/// `TexSpriteSheetBlendTests` 가 이미 쓰던 규약이고, 여기서 그쪽으로 통일한다.
///
/// `WAPLE_WE_ASSETS` 오버라이드는 유지한다(리눅스 하네스가 넣는다). 오버라이드가 가리키는
/// 트리에 특정 파일이 없어서 나는 스킵은 정상이다 — 여기서 막는 것은 **루트 자체를 못 찾는**
/// 경우다. `testBundledWEAssetsRootIsAlwaysFindable` 이 그 자리를 실패로 낸다.
func bundledWEAssetsRoot() -> URL? {
    let fm = FileManager.default
    if let p = ProcessInfo.processInfo.environment["WAPLE_WE_ASSETS"], !p.isEmpty,
       fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
    let repoRoot = URL(fileURLWithPath: #filePath)   // Tests/<Target>/TestSupport.swift
        .deletingLastPathComponent()                  // Tests/<Target>
        .deletingLastPathComponent()                  // Tests
        .deletingLastPathComponent()                  // repo root
    let cand = repoRoot.appendingPathComponent("Sources/WapleRender/Resources/WEAssets")
    return fm.fileExists(atPath: cand.path) ? cand : nil
}
