import XCTest
import simd
@testable import WapleCore

/// TEXS 스프라이트시트 프레임 파스(실물 "particles 256x1280".tex 로 리버스한 레이아웃) +
/// mapsequence 이니셜라이저(CP 각도/구간 → 시퀀스) + 시퀀스→시트 폴드(sheetFrameIndex).
final class TexFramesAndMapSequenceTests: XCTestCase {

    /// 실측 레이아웃 그대로 합성: TEXV0005 헤더(42B) + raw RGBA 페이로드 + TEXS0003 섹션.
    private func makeTexWithFrames() -> Data {
        var b = [UInt8]()
        b.append(contentsOf: Array("TEXV0005".utf8)); b.append(0)          // 0..8
        b.append(contentsOf: Array("TEXI0001".utf8)); b.append(0)          // 9..17
        b += i32(0)      // format 0 (raw RGBA)                                18
        b += i32(0)      //                                                    22
        b += i32(2) + i32(1)   // texW, texH                                   26, 30
        b += i32(2) + i32(1)   // imgW, imgH                                   34, 38
        b.append(contentsOf: [255, 0, 0, 255,  0, 255, 0, 255])            // 2x1 RGBA
        b.append(contentsOf: Array("TEXS0003".utf8)); b.append(0)
        b += i32(2)          // frameCount
        b += i32(256) + i32(256)   // gifW, gifH (v3)
        // frame0: id0, t0.2, x0, y0, w256, unk, unk, h256
        b += i32(0) + f32(0.2) + f32(0) + f32(0) + f32(256) + f32(0) + f32(0) + f32(256)
        // frame1: x=256
        b += i32(0) + f32(0.2) + f32(256) + f32(0) + f32(256) + f32(0) + f32(0) + f32(256)
        return Data(b)
    }

    func testTexFramesParse() {
        guard let tex = TexImage.parse(makeTexWithFrames()) else { return XCTFail("parse nil") }
        XCTAssertEqual(tex.frames.count, 2)
        XCTAssertEqual(tex.frames[0].time, 0.2, accuracy: 1e-5)
        XCTAssertEqual(tex.frames[0].x, 0); XCTAssertEqual(tex.frames[0].width, 256)
        XCTAssertEqual(tex.frames[1].x, 256); XCTAssertEqual(tex.frames[1].height, 256)
    }

    /// 회전 프레임(RePKG): Width=0, HeightX 가 (부호 있는) 유효 폭. 종전 w>0 가드였다면 프레임 목록
    /// 전체가 [] 로 버려졌다 — 이제 유효 크기 기준으로 살아남고 atlas*/rotationQuarters 가 도출된다.
    private func makeTexWithRotatedFrame() -> Data {
        var b = [UInt8]()
        b.append(contentsOf: Array("TEXV0005".utf8)); b.append(0)
        b.append(contentsOf: Array("TEXI0001".utf8)); b.append(0)
        b += i32(0) + i32(0) + i32(2) + i32(1) + i32(2) + i32(1)
        b.append(contentsOf: [255, 0, 0, 255,  0, 255, 0, 255])
        b.append(contentsOf: Array("TEXS0003".utf8)); b.append(0)
        b += i32(1)                 // frameCount
        b += i32(256) + i32(256)    // gifW, gifH
        // id0, t0.2, x256, y0, Width0, WidthY0, HeightX(-256), Height128 → 90/270° 회전
        b += i32(0) + f32(0.2) + f32(256) + f32(0) + f32(0) + f32(0) + f32(-256) + f32(128)
        return Data(b)
    }

    func testRotatedFrameNotDropped() {
        guard let tex = TexImage.parse(makeTexWithRotatedFrame()) else { return XCTFail("parse nil") }
        XCTAssertEqual(tex.frames.count, 1, "회전 프레임이 드롭되지 않음")
        let fr = tex.frames[0]
        XCTAssertEqual(fr.width, 0)           // raw Width==0
        XCTAssertEqual(fr.heightX, -256)      // raw HeightX(부호)
        XCTAssertEqual(fr.atlasWidth, 256)    // |HeightX|
        XCTAssertEqual(fr.atlasHeight, 128)   // |Height|
        XCTAssertEqual(fr.atlasX, 0)          // min(256, 256+(-256))
        XCTAssertEqual(fr.atlasY, 0)
        XCTAssertEqual(fr.rotationQuarters, 3)  // signedW<0, signedH>0 → (-,+)
    }

    /// 비회전 프레임은 rotationQuarters==0, atlas*==raw — 기존 UV 경로와 동일(무회귀 보증).
    func testNonRotatedFrameIdentityMapping() {
        guard let tex = TexImage.parse(makeTexWithFrames()) else { return XCTFail("parse nil") }
        let fr = tex.frames[0]
        XCTAssertEqual(fr.rotationQuarters, 0)
        XCTAssertEqual(fr.atlasX, fr.x); XCTAssertEqual(fr.atlasY, fr.y)
        XCTAssertEqual(fr.atlasWidth, fr.width); XCTAssertEqual(fr.atlasHeight, fr.height)
    }

    /// 양 축 모두 0(퇴화)이면 프레임 목록 전체 드롭(안전망 유지).
    func testDegenerateZeroFrameDropped() {
        var b = [UInt8]()
        b.append(contentsOf: Array("TEXV0005".utf8)); b.append(0)
        b.append(contentsOf: Array("TEXI0001".utf8)); b.append(0)
        b += i32(0) + i32(0) + i32(2) + i32(1) + i32(2) + i32(1)
        b.append(contentsOf: [255, 0, 0, 255,  0, 255, 0, 255])
        b.append(contentsOf: Array("TEXS0003".utf8)); b.append(0)
        b += i32(1) + i32(256) + i32(256)
        b += i32(0) + f32(0.2) + f32(0) + f32(0) + f32(0) + f32(0) + f32(0) + f32(0)  // Width=Height=HeightX=WidthY=0
        if let tex = TexImage.parse(Data(b)) { XCTAssertEqual(tex.frames, []) }
    }

    func testTexWithoutFramesHasEmptyFrames() {
        var d = makeTexWithFrames()
        d = d.prefix(50)   // TEXS 섹션 절단
        if let tex = TexImage.parse(d) { XCTAssertTrue(tex.frames.isEmpty) }
    }

    /// TEXS0001(v1): 지오메트리가 i32 정수형(RePKG 실측 — frametime 만 f32, gifW/H 없음).
    /// v3 와 달리 x/y/w/h 를 정수 바이트로 넣는다.
    private func makeTexWithFramesV1() -> Data {
        var b = [UInt8]()
        b.append(contentsOf: Array("TEXV0005".utf8)); b.append(0)
        b.append(contentsOf: Array("TEXI0001".utf8)); b.append(0)
        b += i32(0) + i32(0)    // format 0(raw RGBA), unk
        b += i32(2) + i32(1)    // texW, texH
        b += i32(2) + i32(1)    // imgW, imgH
        b.append(contentsOf: [255, 0, 0, 255,  0, 255, 0, 255])   // 2x1 RGBA
        b.append(contentsOf: Array("TEXS0001".utf8)); b.append(0)
        b += i32(2)             // frameCount (v1: gifW/H 없음)
        // v1 프레임 32B: i32 id | f32 frametime | i32 x | i32 y | i32 w | i32 widthY | i32 heightX | i32 h
        b += i32(0) + f32(0.2) + i32(0)   + i32(0) + i32(256) + i32(0) + i32(0) + i32(256)
        b += i32(0) + f32(0.2) + i32(256) + i32(0) + i32(256) + i32(0) + i32(0) + i32(256)
        return Data(b)
    }

    func testTexFramesParseV1_integerGeometry() {
        guard let tex = TexImage.parse(makeTexWithFramesV1()) else { return XCTFail("parse nil") }
        XCTAssertEqual(tex.frames.count, 2)
        XCTAssertEqual(tex.frames[0].time, 0.2, accuracy: 1e-5)  // frametime 은 v1 도 f32
        // 정수 지오메트리를 f32 로 오독하면 x=256 이 ≈0(denormal)이 되어 실패 — i32 경로 실측.
        XCTAssertEqual(tex.frames[0].x, 0); XCTAssertEqual(tex.frames[0].width, 256)
        XCTAssertEqual(tex.frames[1].x, 256); XCTAssertEqual(tex.frames[1].height, 256)
    }

    /// 이미지 레이어 스프라이트 재생: 씬 시간 → 프레임 인덱스(가변 frametime 누적 + 루프 랩).
    /// 파티클 sheetFrameIndex(시퀀스→시트 폴드)와 별개 — 이쪽은 시간축 재생 클럭(정본 TexFrame.time).
    func testSpriteFrameIndex_constantFrametimeLoops() {
        let f = { (t: Float) in TexImage.TexFrame(imageId: 0, time: t, x: 0, y: 0, width: 1, height: 1) }
        let frames = [f(0.2), f(0.2), f(0.2)]   // total 0.6
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.0), 0)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.1), 0)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.25), 1)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.5), 2)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.65), 0, "wrap: 0.65 mod 0.6 = 0.05")
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 1.25), 0, "wrap: 1.25 mod 0.6 = 0.05")
    }

    func testSpriteFrameIndex_variableFrametime() {
        let f = { (t: Float) in TexImage.TexFrame(imageId: 0, time: t, x: 0, y: 0, width: 1, height: 1) }
        let frames = [f(0.1), f(0.3), f(0.1)]   // 경계 0.1 / 0.4 / 0.5 (total 0.5)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.05), 0)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.1), 1, "긴 중간 프레임 진입")
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.39), 1)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.4), 2)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: frames, time: 0.55), 0, "wrap → 0.05 → frame0")
    }

    func testSpriteFrameIndex_edgeCases() {
        let f = { (t: Float) in TexImage.TexFrame(imageId: 0, time: t, x: 0, y: 0, width: 1, height: 1) }
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: [], time: 1.0), 0, "무프레임 → 0")
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: [f(0.2)], time: 5.0), 0, "1프레임 정지 → 항상 0")
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: [f(0.2), f(0.2)], time: -0.1), 1, "음수: -0.1 mod 0.4 = 0.3 → frame1")
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: [f(0.2), f(0.2)], time: .infinity), 0, "비유한 → 0")
    }

    func testSheetFrameIndex_mirrorPingpong() {
        // fc=5, mirror: 주기 8 — 0,1,2,3,4,3,2,1,0,1…
        let expect = [0, 1, 2, 3, 4, 3, 2, 1, 0, 1]
        for (s, e) in expect.enumerated() {
            XCTAssertEqual(sheetFrameIndex(sequence: Float(s), frameCount: 5, mirror: true), e, "s=\(s)")
        }
        // loop: 단순 순환
        XCTAssertEqual(sheetFrameIndex(sequence: 7, frameCount: 5, mirror: false), 2)
        XCTAssertEqual(sheetFrameIndex(sequence: -3, frameCount: 5, mirror: true), 0)  // 방어
        XCTAssertEqual(sheetFrameIndex(sequence: 3, frameCount: 0, mirror: true), 0)
    }

    private func defWith(initializer: Initializer, origin: Vec3,
                         cps: [(Int, Vec3)] = []) -> ParticleSystemDef {
        var def = ParticleSystemDef(
            emitters: [.box(origin: origin, distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: 10, max: 10), initializer],
            operators: [],
            renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
        for (id, off) in cps { def.controlPoints[id] = off }
        return def
    }

    func testMapSequenceBetween_projectsOntoSegment() {
        // CP0(0,0) → CP1(100,0), 스폰 (50,0) → t=0.5, count 4 → frame 2.
        let def = defWith(initializer: .mapSequence(count: 4, mirror: false, between: true),
                          origin: Vec3(x: 50, y: 0, z: 0),
                          cps: [(0, Vec3(x: 0, y: 0, z: 0)), (1, Vec3(x: 100, y: 0, z: 0))])
        var sim = ParticleSimulator(def: def, seed: 41)
        let p = sim.step(0.01)
        XCTAssertEqual(p[0].frame, 2.0, accuracy: 0.01)
    }

    func testMapSequenceBetween_clampsOutsideSegment() {
        let def = defWith(initializer: .mapSequence(count: 4, mirror: false, between: true),
                          origin: Vec3(x: -50, y: 0, z: 0),
                          cps: [(0, Vec3(x: 0, y: 0, z: 0)), (1, Vec3(x: 100, y: 0, z: 0))])
        var sim = ParticleSimulator(def: def, seed: 42)
        XCTAssertEqual(sim.step(0.01)[0].frame, 0, accuracy: 0.01)
    }

    func testMapSequenceAround_angleToSequence() {
        // CP0=(0,0). 스폰 (10,0): atan2(0,10)=0 → t=0.5 → count 8 → frame 4.
        let def = defWith(initializer: .mapSequence(count: 8, mirror: true, between: false),
                          origin: Vec3(x: 10, y: 0, z: 0))
        var sim = ParticleSimulator(def: def, seed: 43)
        XCTAssertEqual(sim.step(0.01)[0].frame, 4.0, accuracy: 0.01)
    }

    func testParse_mapSequenceRealKeys_andControlPoints() {
        let json: [String: Any] = [
            "controlpoint": [["id": 0, "offset": "0 0 0"], ["id": 1, "offset": "512 512 0", "flags": 2]],
            "emitter": [["name": "sphererandom", "rate": 100]],
            "initializer": [
                ["name": "mapsequencebetweencontrolpoints", "count": 10, "limitbehavior": "mirror"],
                ["name": "mapsequencearoundcontrolpoint", "count": 10, "limitbehavior": "mirror"],
            ],
            "renderer": [["name": "sprite"]],
        ]
        let def = ParticleSystemDef.parse(json, material: nil)
        XCTAssertEqual(def.controlPoints[1], Vec3(x: 512, y: 512, z: 0))
        XCTAssertEqual(def.initializers.count, 2)
        XCTAssertTrue(def.initializers.contains {
            if case .mapSequence(10, true, true) = $0 { return true }; return false
        })
        XCTAssertTrue(def.initializers.contains {
            if case .mapSequence(10, true, false) = $0 { return true }; return false
        })
    }
}
