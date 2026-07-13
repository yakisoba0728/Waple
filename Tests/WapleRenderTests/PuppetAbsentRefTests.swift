import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

/// H3 회귀: 퍼펫 ref(model json "puppet" 키)가 **pkg 에 부재**할 때의 처리.
/// 실측(capture.log 78회): WE 기본 모델 `models/1x1.json` 이 `"puppet":"models/1x1_puppet.mdl"`
/// 를 참조하나 해당 .mdl 이 pkg 에 미베이크(코퍼스 2955378002: 그런 레이어 50개). 종전 buildLayers 는
/// 이를 로깅 assetData 로 로드 시도 → "asset missing" + "puppet mdl load failed" 스팸.
/// WE 규약(changelog: "Only load puppet ref if file exists on global file system")은 부재를 조용히 건너뛴다.
/// 저장된 실물 퍼펫은 파싱 정상(코퍼스 226개 전수 parse nil=0) — 파서 결함 아님.
final class PuppetAbsentRefTests: XCTestCase {
    /// 유효 MDLV0023(비스키닝 3정점) — PuppetModel.parse 가 Model3D 경유로 로드(실측 레이아웃).
    private func validPuppetMDLV0023() -> Data {
        var d = Data("MDLV0023".utf8)
        d.append(0)
        func u(_ v: UInt32) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func f(_ v: Float) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        u(0x0000000f); u(1); u(1)                       // formatFlag, const(1), meshCount=1
        d.append(Data("materials/p.json".utf8)); d.append(0)  // material cstring
        u(0)                                            // 미상 u32(0)
        f(-1); f(0); f(0); f(1); f(2); f(0)             // aabb min/max
        u(0x0000000f)                                   // vertex format(비스키닝)
        u(UInt32(3 * 48))                               // 정점 블롭(3 × stride48)
        for (px, py): (Float, Float) in [(-1, 0), (1, 0), (0, 2)] {
            f(px); f(py); f(0); f(0); f(0); f(1); f(1); f(0); f(0); f(-1); f(0); f(0)  // pos3 nrm3 tan4 uv2
        }
        u(UInt32(3 * 2))                                // 인덱스 블롭
        for i: UInt16 in [0, 1, 2] { var x = i; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        return d
    }

    func testAbsentPuppetRefIsSilent_presentUnparseableStillLogs_validLoads() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/absent.json","origin":"32 32 0","size":"8 8"},
           {"id":2,"image":"models/garbage.json","origin":"32 32 0","size":"8 8"},
           {"id":3,"image":"models/valid.json","origin":"32 32 0","size":"8 8"}
         ]}
        """
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("materials/m.json", Data(#"{"passes":[{}]}"#.utf8)),   // 무텍스처 → solid 레이어(.tex 불요, 퍼펫 경로 도달)
            ("models/absent.json",  Data(#"{"material":"materials/m.json","puppet":"models/absent_puppet.mdl"}"#.utf8)),
            ("models/garbage.json", Data(#"{"material":"materials/m.json","puppet":"models/garbage_puppet.mdl"}"#.utf8)),
            ("models/valid.json",   Data(#"{"material":"materials/m.json","puppet":"models/valid_puppet.mdl"}"#.utf8)),
            // absent_puppet.mdl 은 일부러 미저장 — 실측 1x1_puppet.mdl 댕글링 ref 재현
            ("models/garbage_puppet.mdl", Data("NOPEBYTES".utf8)),  // 존재하나 파싱 불가
            ("models/valid_puppet.mdl", validPuppetMDLV0023()),
        ]
        let package = ScenePackage.assemble(files)
        let doc = try SceneDocument.parse(package: package)
        let renderer = SceneRenderer()
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)

        let (layers, log) = captureStderr {
            renderer.buildLayers(doc: doc, package: package, device: device)
        }

        // 퍼펫 유무와 무관하게 세 이미지 레이어 모두 쿼드로 남아야(부재는 스킵이 아니라 정적 쿼드)
        XCTAssertEqual(layers.count, 3, "이미지 레이어는 퍼펫 부재여도 드롭되면 안 됨")
        // 저장된 유효 MDLV0023 퍼펫만 로드(present-path 무회귀 가드)
        XCTAssertEqual(layers.filter { $0.puppet != nil }.count, 1, "유효 퍼펫 1개만 로드돼야")

        // === 근본원인 red→green: 부재 ref 는 실패로 로그되면 안 됨(WE: 존재 시만 로드) ===
        XCTAssertFalse(log.contains("puppet mdl load failed (static quad fallback): models/absent_puppet.mdl"),
                       "부재 퍼펫 ref 를 로드 실패로 로깅하면 안 됨(수정 전 실패 지점)")
        XCTAssertFalse(log.contains("asset missing (pkg+shared): models/absent_puppet.mdl"),
                       "부재 퍼펫은 quietAssetData 경유라 asset-missing 로그도 없어야")
        // === 과침묵 방지: 존재하나 파싱 불가한 퍼펫은 여전히 결함으로 로그(실진단 보존) ===
        XCTAssertTrue(log.contains("puppet mdl load failed (static quad fallback): models/garbage_puppet.mdl"),
                      "존재+파싱실패 퍼펫은 여전히 로그로 남아야")
    }

    /// stderr 캡처(NSLog → stderr; GT 하네스도 동일 가정). XCTest 직렬 실행 전제, 출력 소량(무-deadlock).
    private func captureStderr<T>(_ body: () -> T) -> (T, String) {
        let pipe = Pipe()
        fflush(stderr)
        let saved = dup(2)
        dup2(pipe.fileHandleForWriting.fileDescriptor, 2)
        let result = body()
        fflush(stderr)
        dup2(saved, 2); close(saved)
        pipe.fileHandleForWriting.closeFile()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        return (result, String(decoding: out, as: UTF8.self))
    }
}
