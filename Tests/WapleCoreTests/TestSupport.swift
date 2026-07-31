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