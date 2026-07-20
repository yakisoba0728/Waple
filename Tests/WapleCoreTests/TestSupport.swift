import Foundation

// WapleCoreTests 공용 인코딩 스캐폴 — 파일마다 중복되던 LE i32/f32 로컬 인코더 통합(2026-07-19 테스트 위생 정리).
// 규약: 이 바이트가 곧 파서 테스트의 입력 — 기존 로컬 사본과 바이트 동일해야 한다.

/// LE u32 4바이트. truncatingIfNeeded — i32(-1)(TEXB imageFormat v3) 표현에 쓰인다.
func i32(_ v: Int) -> [UInt8] {
    let u = UInt32(truncatingIfNeeded: v)
    return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
}

/// LE f32 4바이트(비트패턴 그대로).
func f32(_ v: Float) -> [UInt8] {
    let u = v.bitPattern
    return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
}
