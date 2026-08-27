import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// `general.supportsaudioprocessing` 의 **의도적 미사용**을 지키는 오라클(2026-08-27).
///
/// ## 무엇을 지키는가
///
/// `WallpaperProject.supportsAudioProcessing` 는 파싱되지만 프로덕션 소비처가 **0** 이다.
/// 그것은 미완이 아니라 결정이고, 근거와 뒤집을 조건은
/// `ProjectJSONParser.parseSupportsAudioProcessing` 의 「처분 [2026-08-27]」 문단에 있다.
/// 요지만: WE 의 게이트는 `SupportsAudioProcessing() && audioprocessing.value` 두 항인데
/// Waple 에는 둘째 항(엔진 합성 유저 프로퍼티)이 없고, 선언을 상위 게이트로 얹었을 때
/// 조용해질 벽지 수를 잴 씬 × 선언 교차표가 이 리포에 없으며, **헤드리스 골든은 오디오 기동을
/// 통째로 꺼도 픽셀 diff 가 0** 이라 그 회귀를 구조적으로 못 본다.
///
/// 마지막 항목이 이 파일이 존재하는 이유다. 결정을 코드에 적어 두기만 하면, 누가 "TODO 처럼
/// 보이는 문단" 을 읽고 배선하는 순간 **어떤 게이트도 빨개지지 않는다.** 그래서 결정 자체를
/// 실행 가능한 단언으로 내린다: **선언 값이 무엇이든 `SceneRenderer.hasAudio` 승격은 같다.**
///
/// 배선하는 사람은 이 테스트를 먼저 깨게 되고, 그러면 위 문단을 읽고 뒤집을 조건 셋을
/// 충족했는지 판단한 뒤 **의도적으로** 이 파일을 갱신하게 된다.
final class AudioProcessingDeclarationTests: XCTestCase {

    /// `hasAudio` 승격을 **확실하게** 일으키는 씬. 승격 기전은 `SceneRenderer.scriptWantsAudio`
    /// (SceneRenderer.swift:284) 의 **소스 문자열 스캔**이고, 그 검사는 엔진 생성보다 먼저
    /// 실행된다(:251) — 즉 스크립트가 실제로 돌든 말든 참조만 보이면 승격한다. 이펙트/이미터
    /// 경로에 기대지 않는 것은 의도적이다: 여기서 재는 것은 "선언과 무관함" 이지 "어느 승격원이
    /// 도는가" 가 아니므로, 승격이 확실한 기전 하나만 쓴다.
    private static let js = "'use strict';\\nexport function update(){ return new Vec3(1,1,1); }\\nexport function unusedAudioProbe(){ return engine.audio; }\\n"

    private static let model = #"{"width":100,"height":100,"material":"materials/m.json"}"#
    private static let material = #"{"passes":[{"textures":["pic"]}]}"#

    private static var scene: String {
        """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"50 50 0","size":"10 10",
           "color":{"value":"1 1 1","script":"\(js)"}}]}
        """
    }

    /// `project.json` 원문을 골라 넣고 **파서를 거쳐** 프로젝트를 만든다 — 파싱 쪽 절반
    /// (`general.supportsaudioprocessing` 판독)과 소비 쪽 절반(`hasAudio`)을 한 경로에서 잰다.
    private func mount(tag: String, projectJSON: String) throws -> (SceneRenderer, WallpaperProject) {
        let pkg = encodePkg([
            ("scene.json", Data(Self.scene.utf8)),
            ("models/x.json", Data(Self.model.utf8)),
            ("materials/m.json", Data(Self.material.utf8)),
            ("materials/pic.tex", solidTex(255, 255, 255)),
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_audiodecl_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pkg.write(to: dir.appendingPathComponent("scene.pkg"))
        let project = try ProjectJSONParser.parse(data: Data(projectJSON.utf8), folderURL: dir)
        let r = SceneRenderer()
        r.capturePointerUV = SIMD2<Float>(0.5, 0.5)   // 라이브 모니터 미기동(캡처 하네스 규약)
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        return (r, project)
    }

    private static func projectJSON(general: String) -> String {
        #"{"type":"scene","file":"scene.pkg","title":"t"\#(general)}"#
    }

    /// **선언 true** — 파서는 읽고, 렌더러는 무시한다(승격은 씬 내용에서 온다).
    func testDeclaredTrueDoesNotChangeAudioPromotion() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal 없음") }
        let (r, p) = try mount(tag: "declared",
                               projectJSON: Self.projectJSON(general: #","general":{"supportsaudioprocessing":true}"#))
        defer { r.teardown() }
        XCTAssertTrue(p.supportsAudioProcessing, "파서가 선언을 읽어야(이 축의 파싱은 계속 유지한다)")
        XCTAssertTrue(r.hasAudio, "씬 내용(스크립트 오디오 참조)이 hasAudio 를 승격해야 — 이 픽스처의 전제")
    }

    /// **선언 부재** — 그래도 승격은 그대로다. 이것이 WE 와의 **의도적 divergence** 다:
    /// 원본이라면 `CProject::SupportsAudioProcessing`(0x14010d100)이 false 라 벽지 런타임 플래그
    /// bit3 이 0 으로 고정되고(0x140114d21) 밴드 버퍼가 0 으로 밀린다(0x140115403).
    /// Waple 은 그 선언을 게이트로 쓰지 않는다 — 근거는 파일 머리말·파서 「처분」 문단.
    func testUndeclaredWallpaperStillGetsAudio() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal 없음") }
        let (r, p) = try mount(tag: "absent", projectJSON: Self.projectJSON(general: ""))
        defer { r.teardown() }
        XCTAssertFalse(p.supportsAudioProcessing, "키 부재는 false(WE 기본값)")
        XCTAssertTrue(r.hasAudio, Self.divergenceMessage)
    }

    /// **선언 명시 false** — 부재와 같아야 한다(선언을 읽지 않으므로 구분 자체가 없다).
    func testExplicitFalseDeclarationStillGetsAudio() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal 없음") }
        let (r, p) = try mount(tag: "false",
                               projectJSON: Self.projectJSON(general: #","general":{"supportsaudioprocessing":false}"#))
        defer { r.teardown() }
        XCTAssertFalse(p.supportsAudioProcessing)
        XCTAssertTrue(r.hasAudio, Self.divergenceMessage)
    }

    private static let divergenceMessage = """
        `supportsAudioProcessing` 가 오디오 기동의 게이트가 됐다.

        그게 의도라면 이 테스트를 갱신하기 전에 `ProjectJSONParser.parseSupportsAudioProcessing`
        의 「처분 [2026-08-27]」 문단에 적힌 **뒤집을 조건 셋**을 확인할 것:
          ① `audioprocessing` 유저 프로퍼티 합성 주입 + 설정 UI(WE 게이트의 둘째 항)
          ② 실물 코퍼스에서 씬 × 선언 교차표 — 조용해질 벽지가 몇 개인지 알 것
          ③ 실기에서 오디오 반응 벽지로 전/후 육안 대조
        (③ 이 필요한 이유: 헤드리스 골든은 오디오 기동을 통째로 꺼도 픽셀 diff 가 0 이다 —
         `CaptureAudioDeterminismTests` 참조. 이 회귀를 볼 수 있는 게이트가 이 파일뿐이다.)
        """
}
