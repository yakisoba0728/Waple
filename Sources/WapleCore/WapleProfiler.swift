import Foundation

/// 계측 전용 프로파일러(하네스 `WapleCompat --profile`). 기본 비활성 →
/// 제품 경로는 `enabled` 원자 로드 1회 + 직접 body 호출이므로 무영향(측정 시에만 누적).
///
/// ponytail: 단일 스레드 마운트 경로 전제(락 없음). 프로파일드 마운트/캡처는 호출 스레드에서
/// 순차 실행되며, 백그라운드 모니터(시차/오디오)는 이 누적기를 건드리지 않는다. 동시 파스
/// (DeepScan.concurrentPerform)는 enabled=false 라 진입하지 않는다 — 병렬화하려면 락 필요.
///
/// [2026-08-19] 엄격 동시성: 아래 static 들은 전부 `nonisolated(unsafe)` 로 표기한다. **직렬화 근거는
/// 위 ponytail 문단이고 새 근거가 아니다** — 하네스(`WapleCompat --profile`)가 enabled 를 켜고,
/// 그 프로세스에서 마운트/캡처를 한 스레드로 순차 실행한 뒤 읽는다. 대안 둘을 실제로 검토하고 버렸다:
///  · `@MainActor`: 소비자가 CLI(ProfilePipeline)와 렌더 내부(TexDecoder/GLSLTranslator/SceneRenderer)
///    인데 이들은 메인 액터가 아니다 — 격리하면 계측 호출 전부가 액터 홉을 요구해 계측 대상의
///    타이밍 자체를 바꾼다(측정 도구가 측정값을 오염시킨다).
///  · 락: 제품 경로는 `enabled` 원자 로드 1회로 끝나는 게 설계 전제인데, 락을 넣으면 그 전제가 깨지고
///    (매 time/recordTex 호출마다 락) 계측 비용이 계측값에 섞인다. 병렬 프로파일이 필요해지면
///    그때 락을 넣고 이 주석을 갱신할 것 — 지금은 병렬 진입 경로가 없다는 것이 위 문단의 확인 사항이다.
public enum WapleProfiler {
    nonisolated(unsafe) public static var enabled = false

    /// 리프 페이즈 누적 시간(초). 키: pkgRead/pkgParse/docParse/deviceInit/texDecode/
    /// glslTranslate/shaderCompile/pipelineCreate. 하네스가 총 마운트 시간에서 이 합을 빼 "other" 산출.
    nonisolated(unsafe) public private(set) static var phases: [String: Double] = [:]
    nonisolated(unsafe) public private(set) static var counters: [String: Int64] = [:]

    /// 텍스처 디코드 레코드: (포맷, 디코드 출력 바이트, 디스크 압축 바이트, 초).
    public struct TexRec { public let format: String; public let outBytes: Int; public let inBytes: Int; public let seconds: Double }
    nonisolated(unsafe) public private(set) static var texRecs: [TexRec] = []

    /// makeLibrary 에 투입된 MSL 소스의 안정 해시(프로세스 간 비교 가능). 재컴파일 비율 산출용.
    nonisolated(unsafe) public private(set) static var shaderHashes: [UInt64] = []

    /// 파티클 시뮬 스텝: (생존 파티클 수, 초). 정상상태 ms/프레임 + 피크 수 산출.
    nonisolated(unsafe) public private(set) static var particleSteps: [(count: Int, seconds: Double)] = []

    /// 마운트 직후 MTLDevice.currentAllocatedSize(마운트가 enabled 시 기록).
    nonisolated(unsafe) public static var deviceAllocatedBytes: Int = 0

    public static func reset() {
        phases = [:]; counters = [:]; texRecs = []; shaderHashes = []
        particleSteps = []; deviceAllocatedBytes = 0
    }

    // MARK: 페이즈 타이밍

    @inline(__always)
    public static func time<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { phases[phase, default: 0] += CFAbsoluteTimeGetCurrent() - t0 }
        return try body()
    }

    /// makeLibrary 래퍼: shaderCompile 누적 + 소스 해시 기록(재컴파일 비율).
    @inline(__always)
    public static func compile<T>(_ source: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let t0 = CFAbsoluteTimeGetCurrent()
        let out = try body()
        phases["shaderCompile", default: 0] += CFAbsoluteTimeGetCurrent() - t0
        shaderHashes.append(stableHash(source))
        return out
    }

    /// makeRenderPipelineState 래퍼: pipelineCreate 누적.
    @inline(__always)
    public static func pipe<T>(_ body: () throws -> T) rethrows -> T {
        try time("pipelineCreate", body)
    }

    // MARK: 리프 레코드

    public static func recordTex(format: String, outBytes: Int, inBytes: Int, seconds: Double) {
        guard enabled else { return }
        phases["texDecode", default: 0] += seconds
        texRecs.append(TexRec(format: format, outBytes: outBytes, inBytes: inBytes, seconds: seconds))
    }

    public static func recordTranslate(seconds: Double) {
        guard enabled else { return }
        phases["glslTranslate", default: 0] += seconds
        counters["translateCount", default: 0] += 1
    }

    public static func recordParticleStep(count: Int, seconds: Double) {
        guard enabled else { return }
        particleSteps.append((count, seconds))
    }

    /// 프로세스 간 안정적인 FNV-1a 64bit(String.hashValue 는 실행마다 시드가 달라 재현 불가).
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
