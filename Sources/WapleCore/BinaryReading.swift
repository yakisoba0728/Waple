import Foundation

// WapleCore 바이너리 파서 공용 리더(경계검사 포함 자유함수). WE 에셋은 전부 리틀엔디안 —
// Model3D / PuppetModel / TexImage 가 공유(종전 파일별 3~4벌 중복 리더 통합).

/// 리틀엔디안 u32. [at, at+4) 가 버퍼 밖(또는 at<0)이면 nil.
func readU32LE(_ bytes: [UInt8], at: Int) -> UInt32? {
    guard at >= 0, at + 4 <= bytes.count else { return nil }
    return UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
}

/// 리틀엔디안 u16. [at, at+2) 가 버퍼 밖(또는 at<0)이면 nil. C③: MDLA0006 클립 트레일러 id 필드용.
func readU16LE(_ bytes: [UInt8], at: Int) -> UInt16? {
    guard at >= 0, at + 2 <= bytes.count else { return nil }
    return UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
}

/// NUL 종료 문자열을 **UTF-8** 로 디코드. next = NUL 다음 오프셋. NUL 없이 버퍼 끝에 닿으면 nil.
/// UTF-8 고정 이유: 실물 머티리얼 경로가 CJK("materials/models/太空球/…")를 포함 — 바이트별
/// UnicodeScalar(Latin-1) 해석은 mojibake 가 되어 太空球 pkg 엔트리 조회가 실패한다.
func readCString(_ bytes: [UInt8], at: Int) -> (value: String, next: Int)? {
    guard at >= 0 else { return nil }
    var e = at
    while e < bytes.count, bytes[e] != 0 { e += 1 }
    guard e < bytes.count else { return nil }
    return (String(decoding: bytes[at..<e], as: UTF8.self), e + 1)
}
