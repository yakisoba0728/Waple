import XCTest
@testable import WapleCore

/// `spec/engine/media.json` 의 **미디어 재생 정책** 항목을 값으로 잠근다.
///
/// 왜 정본을 테스트가 읽는가. 이 서브시스템(비디오 재생·오디오 볼륨·하드웨어 디코딩 게이트)은
/// Waple 에 아직 대응 코드가 없다 — `VideoRenderer`/`SceneVideoLayer` 는 `WapleRender` 에 있고
/// 리눅스에서 실행되지 않는다. 그래서 여기서 잠글 수 있는 것은 **사실 그 자체**뿐이고,
/// 사실의 정본은 `spec/engine/media.json` 이다.
///
/// 이 테스트가 막는 사고는 둘이다.
///  ① 코퍼스가 있는 머신에서 `scripts/spec/measure_media.py` 를 돌렸을 때 이 문장들이
///     **조용히 되돌아가는 것**(`docs/dev/re-methodology.md` §2 의 함정 19).
///  ② 툼스톤 규약이 깨지는 것 — 해소된 미해결의 키를 지우면 다음 사람이 같은 질문을
///     처음부터 다시 판다.
///
/// 근거 VA 는 `docs/re/media-playback.md` §4.5 · §8.5 에 있다.
final class MediaPlaybackCanonTests: XCTestCase {

    // MARK: 정본 로드

    /// `spec/engine/media.json` 을 찾는다.
    ///
    /// `scripts/dev/linux-core-tests.sh` 는 테스트 소스를 **심링크로** 임시 패키지에 건다 —
    /// `#filePath` 를 그대로 거슬러 오르면 리포 밖으로 나간다. 심링크를 먼저 푼다
    /// (`EffectManifestTests.bundledEffectsRoot` 와 같은 방식).
    private static func canonURL() -> URL? {
        let fm = FileManager.default
        let here = (try? fm.destinationOfSymbolicLink(atPath: #filePath)) ?? #filePath
        var dir = URL(fileURLWithPath: here).deletingLastPathComponent()
        for _ in 0..<8 {
            let cand = dir.appendingPathComponent("spec/engine/media.json")
            if fm.fileExists(atPath: cand.path) { return cand }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private func entries() throws -> [String: (status: String, value: [String: Any])] {
        let url = try XCTUnwrap(Self.canonURL(), "spec/engine/media.json 을 못 찾았다")
        let raw = try Data(contentsOf: url)
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let list = try XCTUnwrap(doc["entries"] as? [[String: Any]])
        var out: [String: (status: String, value: [String: Any])] = [:]
        for e in list {
            guard let id = e["id"] as? String, let status = e["status"] as? String else { continue }
            out[id] = (status, (e["value"] as? [String: Any]) ?? [:])
        }
        return out
    }

    private func text(_ value: [String: Any], _ key: String, file: StaticString = #filePath,
                      line: UInt = #line) throws -> String {
        try XCTUnwrap(value[key] as? String, "키 \(key) 가 없다", file: file, line: line)
    }

    // MARK: 볼륨·뮤트 규약 (0x140102092–0x140102181)

    /// 볼륨은 **즉시 바뀌지 않는다**. 25ms 타이머로 램프하고 오르내림이 비대칭이다.
    /// 이 세 상수(0.03 / 0.02 / 0.01)와 틱 주기가 이 서브시스템의 이식 계약 전부다.
    func testVolumeFadeConstantsArePinned() throws {
        let all = try entries()
        let fade = try XCTUnwrap(all["engine.media.audio.volumeFade"], "볼륨 램프 항목이 사라졌다")
        XCTAssertEqual(fade.status, "확정")

        let out = try text(fade.value, "fadeOutStep")
        XCTAssertTrue(out.contains("target*0.03f + 0.02f"), "fade-out 산식: \(out)")
        XCTAssertTrue(out.contains("0x140492634"), "0.03f 상수 VA")
        XCTAssertTrue(out.contains("0x14049262c"), "0.02f 상수 VA")

        let inn = try text(fade.value, "fadeInStep")
        XCTAssertTrue(inn.contains("target*0.01f + 0.01f"), "fade-in 산식: \(inn)")
        XCTAssertTrue(inn.contains("0x140492620"), "0.01f 상수 VA")

        let timer = try text(fade.value, "timer")
        XCTAssertTrue(timer.contains("SetTimer(hwnd, 0x65, 25, NULL)"), "타이머 id·주기: \(timer)")

        // 파생값 — 램프가 비대칭이라는 것이 결론이므로 수치를 여기서 다시 센다.
        let tick = 0.025
        let target = 1.0
        let outStep = target * 0.03 + 0.02
        let inStep = target * 0.01 + 0.01
        XCTAssertEqual(target / outStep * tick, 0.5, accuracy: 1e-9, "fade-out 500ms")
        XCTAssertEqual(target / inStep * tick, 1.25, accuracy: 1e-9, "fade-in 1250ms")
        XCTAssertEqual(inStep * 2.5, outStep, accuracy: 1e-9, "내려가는 쪽이 정확히 2.5배 빠르다")

        let done = try text(fade.value, "completion")
        XCTAssertTrue(done.contains("일시정지는 램프가 끝난 뒤에 걸린다"),
                      "정지는 소리를 끊는 게 아니라 fade-out 이다: \(done)")
    }

    // MARK: 하드웨어 디코딩 게이트 (0x1401007e3–0x1401007ff)

    /// `videohardwareacceleration` 은 **반전 저장**이고, 소비 지점은 백엔드 vtbl+0x70 이다.
    /// 반전을 잊으면 의미가 뒤집히므로 그 문장을 값으로 잠근다.
    func testHardwareDecodeGateIsInvertedAndLandsOnBackendSlot() throws {
        let all = try entries()
        let backend = try XCTUnwrap(all["engine.media.video.backendVtable"], "백엔드 vtable 항목이 사라졌다")
        XCTAssertEqual(backend.status, "확정")

        let hw = try text(backend.value, "mask0x04")
        XCTAssertTrue(hw.contains("([player+0x17c]>>4)&1"), "저장 위치: \(hw)")
        XCTAssertTrue(hw.contains("vtbl+0x70"), "소비 슬롯: \(hw)")
        XCTAssertTrue(hw.contains("1 이 '가속 끔' 이다"), "반전 규약이 사라졌다: \(hw)")

        // 형제 마스크가 같은 함수에서 다른 슬롯으로 간다 — 슬롯이 밀리면 여기서 깨진다.
        XCTAssertTrue(try text(backend.value, "mask0x08").contains("vtbl+0x68"))
        XCTAssertTrue(try text(backend.value, "mask0x10").contains("vtbl+0x58"))
        XCTAssertTrue(try text(backend.value, "mask0x20").contains("vtbl+0x60"))
        XCTAssertTrue(try text(backend.value, "mask0x02").contains("vtbl+0x30"))
    }

    // MARK: 프레임워크 게이트 (0x140100fed–0x140100ffe)

    /// 플래그 워드의 두 바이트가 서로 **다른 것**을 뜻한다. 하나로 뭉뚱그리면 틀린다.
    func testFrameworkFlagWordBytesHaveDistinctMeanings() throws {
        let all = try entries()
        let gate = try XCTUnwrap(all["engine.media.video.frameworkGate"], "프레임워크 게이트 항목이 사라졌다")
        XCTAssertEqual(gate.status, "확정")

        let low = try text(gate.value, "lowByte")
        XCTAssertTrue(low.contains("Media Foundation 을 요구한다"), low)
        XCTAssertTrue(low.contains("0x140100fed–0x140100ffe"), "소비 지점 VA: \(low)")

        let high = try text(gate.value, "highByte")
        XCTAssertTrue(high.contains("비트21(0x00200000)"), high)
        XCTAssertNotEqual(low, high, "두 바이트가 같은 뜻이면 이 엔트리가 존재할 이유가 없다")

        // 세 값이 표와 일치하는지 — 0x0101 / 0x0001 / 0x0000.
        let word = try text(gate.value, "flagWord")
        for literal in ["0x0101", "0x0001", "0x0000"] {
            XCTAssertTrue(word.contains(literal), "\(literal) 가 없다: \(word)")
        }
    }

    // MARK: mediaextensions64.dll — 함정 11("바이너리 하나 ≠ WE")의 답

    /// 두 export 시그니처가 복원됐다. `미복원` 이라는 낡은 문장이 되살아나면 깨진다.
    func testMediaExtensionsExportSignaturesAreRestored() throws {
        let all = try entries()
        let exports = try XCTUnwrap(all["engine.media.mediaextensions.weExports"])
        let signatures = try XCTUnwrap(exports.value["signatures"] as? [String: Any])

        let create = try XCTUnwrap(signatures["CreateMediaExtensions"] as? String)
        XCTAssertFalse(create.contains("미복원"), "복원해 놓고 문장이 되돌아갔다: \(create)")
        XCTAssertTrue(create.contains("void* CreateMediaExtensions(void)"), create)

        let version = try XCTUnwrap(signatures["WallpaperEngineMedaExtensionVersion"] as? String)
        XCTAssertFalse(version.contains("미복원"))
        XCTAssertTrue(version.contains("함수가 아니라 데이터 export"), version)
        XCTAssertTrue(version.contains("WallpaperEngineMediaExtensions0002"), version)

        let factory = try XCTUnwrap(all["engine.media.mediaextensions.factory"])
        XCTAssertEqual(factory.status, "확정")
        XCTAssertTrue(try text(factory.value, "loadLibrary").contains("LoadLibraryExW"),
                      "LoadLibraryW 로 되돌아갔다")
    }

    // MARK: 툼스톤 규약

    /// 해소된 미해결의 **키를 지우지 않는다**. 지우면 축소 가드가 못 잡고(값만 바뀌므로)
    /// 다음 사람이 같은 질문을 처음부터 판다.
    func testResolvedUnknownKeepsItsTombstone() throws {
        let all = try entries()
        let unknowns = try XCTUnwrap(all["engine.media.unknowns"])
        XCTAssertEqual(unknowns.status, "추정", "미해결 목록은 확정이 될 수 없다 — 사라질 뿐이다")

        let tomb = try text(unknowns.value, "mediaextensions64.dll 의 WE 전용 export 2개 시그니처")
        XCTAssertTrue(tomb.contains("해소 2026-08-21"), "툼스톤이 아니라 옛 문장이다: \(tomb)")

        // 아직 안 닫힌 것들은 그대로 있어야 한다 — 조용히 사라지면 안 된다.
        for key in ["videoloopmode 의 syncclock/synctopo 동작", "frommemory 모드",
                    "webmframework cef/native 의 분기", "GUID 0x14042c380"] {
            XCTAssertNotNil(unknowns.value[key], "미해결 \(key) 가 근거 없이 사라졌다")
        }
    }
}
