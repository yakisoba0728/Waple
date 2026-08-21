import XCTest
@testable import WapleCore

/// 동봉 WE 자산의 `.tex` **전건**을 Waple 파서로 돌려 회귀를 잡는다.
///
/// 왜 전건이냐
/// -----------
/// `.tex` 컨테이너는 **조건부 필드**가 셋이나 있다(헤더 texDepth, 헤더 previewColor, mip 레코드 depth).
/// 조건이 안 걸린 표본만 보면 셋 다 안 보이고, 실제로 그래서 `materials/lut/*.tex` 28개가 오래
/// 컨테이너 파스 실패 상태로 있었다(PNG 시그니처 스캔 폴백이 픽셀만 우연히 맞혀서 조용했다).
/// 합성 픽스처는 우리가 아는 것만 담으므로 이 자리는 **실물 전수**여야 의미가 있다.
///
/// 판정 기준은 "nil 이 아니다" 가 아니라 **컨테이너를 실제로 읽었는가**다 — mip 이 없거나
/// payload 가 `.unknown` 이면 실패로 본다.
final class TexBundledCorpusTests: XCTestCase {
    /// 동봉 자산 루트(`WAPLE_WE_ASSETS` → 상위 탐색). AssetJSONLenientTests 와 같은 규약.
    private func assetsRoot() throws -> URL {
        guard let root = AssetJSONLenientTests.bundledAssetsRoot() else {
            throw XCTSkip("WAPLE_WE_ASSETS 미지정 — 동봉 자산 트리를 못 찾았다")
        }
        return root
    }

    private func texFiles() throws -> [(rel: String, data: Data)] {
        let root = try assetsRoot()
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("자산 트리를 못 훑었다"); return []
        }
        var out: [(String, Data)] = []
        for case let url as URL in en where url.pathExtension == "tex" {
            guard let d = try? Data(contentsOf: url) else { XCTFail("읽기 실패 \(url.path)"); continue }
            out.append((String(url.path.dropFirst(root.path.count + 1)), d))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// 전건 파스 + 포맷 분포. 실측(2026-08-21, 동봉 311건): 실패 0 · `.unknown` 0 ·
    /// format {0: 191, 9: 60, 8: 51, 4: 9} · payload {lz4RGBA 156, r8 60, rg88 51, embeddedImage 35, bc3 9}.
    /// 자산이 늘어도 안 깨지도록 **하한**으로 고정하고, 실패는 0 을 못박는다.
    func testAllBundledTexParse() throws {
        let files = try texFiles()
        XCTAssertGreaterThanOrEqual(files.count, 311, "동봉 .tex 가 줄었다 — 경로/자산 확인")
        var failed: [String] = []
        var unknown: [String] = []
        var noMip: [String] = []
        var formats: [Int: Int] = [:]
        for (rel, data) in files {
            guard let t = TexImage.parse(data) else { failed.append(rel); continue }
            formats[t.format, default: 0] += 1
            if t.payload == .unknown { unknown.append(rel) }
            // 동봉 전건은 TEXB 컨테이너를 갖는다(참조 파스 결과 311/311). mip 이 없다는 건
            // 컨테이너를 못 읽고 시그니처 스캔으로 흘렀다는 뜻이라 회귀다.
            if t.mip == nil { noMip.append(rel) }
            XCTAssertGreaterThan(t.width, 0, rel)
            XCTAssertGreaterThan(t.height, 0, rel)
            XCTAssertEqual(t.imageCount, 1, "동봉 자산은 전건 단일 image \(rel)")
        }
        XCTAssertEqual(failed, [], "파스 실패")
        XCTAssertEqual(unknown, [], "포맷 미매핑(.unknown)")
        XCTAssertEqual(noMip, [], "TEXB 컨테이너 파스 실패 — 시그니처 스캔 폴백으로 흘렀다")
        XCTAssertEqual(Set(formats.keys), [0, 4, 8, 9], "동봉 포맷 집합이 바뀌었다: \(formats)")
    }

    /// 헤더 flags 에서 **실제로 켜지는 비트 집합**을 못박는다. Waple 의 flags 주석표(`TexImage.flags`)가
    /// 딛고 선 근거가 이 도수라서, 자산이 바뀌어 새 비트가 들어오면 그 표부터 다시 봐야 한다.
    /// 실측(2026-08-21, **동봉 311건** = 설치본 `assets/` 311건과 바이트 동일):
    ///   0x2 ×218 · 0x80000 ×82 · 0x4 ×52 · 0x40 ×28 · 0x1 ×2 — 그 외 비트는 0건.
    /// 특히 **0x8 은 파일 입력이 아니다**(로더가 세운다) — 0건이어야 리더가 무시해도 되는 근거가 산다.
    /// (범위 밖 참고: 설치본 `projects/defaultprojects/` 129건에는 여기 없는 **0x10(sRGB)** 이 10건 있다.
    ///  런타임 비소비 레거시 비트라 파스에는 영향이 없다 — docs/re/tex-format.md §3 참조.)
    func testBundledFlagBitsAreTheDocumentedSet() throws {
        var bitCount: [Int: Int] = [:]
        for (_, data) in try texFiles() {
            guard let t = TexImage.parse(data) else { continue }
            for i in 0..<32 where t.flags & (1 << i) != 0 { bitCount[1 << i, default: 0] += 1 }
        }
        XCTAssertEqual(Set(bitCount.keys), [0x1, 0x2, 0x4, 0x40, 0x80000],
                       "동봉 flags 비트 집합이 바뀌었다: \(bitCount.mapValues { $0 })")
        XCTAssertNil(bitCount[0x8], "0x8 은 파일 입력이 아니다 — 파일에서 켜져 나오면 모델이 틀린 것")
        XCTAssertEqual(bitCount[0x40], 28, "slice3d 자산(LUT) 수")
        XCTAssertEqual(bitCount[0x4], 52, "스프라이트시트 수")
        XCTAssertEqual(bitCount[0x80000], 82, "alphachannelpriority 수")
    }

    /// mip 페이로드 범위가 **파일 안**이고 서로 겹치지 않으며, 압축 크기가 0 보다 큰지.
    /// 레이아웃을 잘못 읽으면 거의 항상 여기서 먼저 무너진다(다음 레벨 시작이 뒤로 밀린다).
    func testMipChainRangesAreSaneAndOrdered() throws {
        for (rel, data) in try texFiles() {
            guard let t = TexImage.parse(data) else { continue }
            var prevEnd = 0
            for (i, m) in t.mipChain.enumerated() {
                XCTAssertGreaterThanOrEqual(m.payloadRange.lowerBound, prevEnd, "\(rel) level \(i) 역행")
                XCTAssertLessThanOrEqual(m.payloadRange.upperBound, data.count, "\(rel) level \(i) 파일 밖")
                XCTAssertGreaterThan(m.payloadRange.count, 0, "\(rel) level \(i) 빈 페이로드")
                // 레벨 L 의 image dims = imgW/imgH 를 1/2^L 축소(최소 1).
                XCTAssertEqual(m.imageWidth, max(1, t.width >> i), "\(rel) level \(i) imageWidth")
                XCTAssertEqual(m.imageHeight, max(1, t.height >> i), "\(rel) level \(i) imageHeight")
                prevEnd = m.payloadRange.upperBound
            }
        }
    }

    /// slice3d(flags 0x40) — 헤더 texDepth + **mip 레코드 depth** 두 조건부 필드가 동시에 걸리는
    /// 유일한 실물 군이다. 동봉 `materials/lut/*.tex` 28개가 32×32×32 LUT.
    /// 이 배선이 빠지면 28개가 전건 컨테이너 파스 실패로 되돌아간다.
    func testVolumeLUTTexturesCarryDepth() throws {
        let luts = try texFiles().filter { $0.rel.hasPrefix("materials/lut/") }
        XCTAssertEqual(luts.count, 28, "LUT 자산 수가 바뀌었다")
        for (rel, data) in luts {
            let t = try XCTUnwrap(TexImage.parse(data), rel)
            XCTAssertTrue(t.isVolume, "\(rel) flags 0x40")
            XCTAssertEqual(t.depth, 32, "\(rel) 헤더 texDepth")
            XCTAssertEqual(t.mip?.depth, 32, "\(rel) mip 레코드 depth")
            XCTAssertEqual(t.payload, .embeddedImage, "\(rel) imageFormat=13(PNG) 컨테이너")
            XCTAssertEqual(t.imageCount, 1, rel)
            XCTAssertEqual(t.mip?.lz4, false, "\(rel) LUT PNG 은 비압축 저장")
            // 헤더는 imgW = texW × depth 규약(1024 = 32×32).
            XCTAssertEqual(t.width, 1024, rel)
            XCTAssertEqual(t.height, 32, rel)
            XCTAssertNotEqual(t.previewColor, 0, "\(rel) previewColor 를 읽지 못했다")
        }
    }

    /// 스프라이트시트: flags bit2(IsGif) 와 TEXS 프레임의 존재가 정확히 같은 집합인지.
    /// 실측 동봉 52건(TEXS0003 44 + TEXS0002 8).
    func testSpriteSheetFlagMatchesFrames() throws {
        var gifFlagged = 0, framed = 0, v2 = 0, v3 = 0
        for (rel, data) in try texFiles() {
            guard let t = TexImage.parse(data) else { continue }
            if t.isGif { gifFlagged += 1 }
            if !t.frames.isEmpty { framed += 1 }
            XCTAssertEqual(t.isGif, !t.frames.isEmpty, "\(rel) IsGif 와 TEXS 존재가 어긋났다")
            switch t.framesVersion {
            case 2: v2 += 1
            case 3: v3 += 1
            default: XCTAssertTrue(t.frames.isEmpty, "\(rel) 미지 TEXS 버전 \(t.framesVersion)")
            }
            guard !t.frames.isEmpty else { continue }
            // v3 은 파일에서, v2 이하는 헤더 imgW/imgH 가 기본값(엔진 0x14015e268).
            XCTAssertGreaterThan(t.gifWidth, 0, rel)
            XCTAssertGreaterThan(t.gifHeight, 0, rel)
            if t.framesVersion < 3 {
                XCTAssertEqual(t.gifWidth, t.width, "\(rel) v2 gifWidth 기본값")
                XCTAssertEqual(t.gifHeight, t.height, "\(rel) v2 gifHeight 기본값")
            }
        }
        XCTAssertEqual(gifFlagged, framed)
        XCTAssertGreaterThanOrEqual(v3, 44, "TEXS0003 시트가 줄었다")
        XCTAssertGreaterThanOrEqual(v2, 8, "TEXS0002 시트가 줄었다")
    }

    /// TEXS0002 8건(debris1·fire1~3·lightning1~2·snow·smoke3)은 frametime 이 **전 프레임 0** 이다.
    /// 종전 `max(1e-4, time)` 클램프면 총 재생길이가 n×0.1ms 라 0.05 초 간격 샘플이 전부 같은
    /// 프레임(또는 무의미한 값)으로 접혔다. 폴백이 걸리면 0.016s/프레임으로 정상 진행해야 한다.
    func testZeroFrameTimeSheetsAdvanceWithFallback() throws {
        var checked = 0
        for (rel, data) in try texFiles() {
            guard let t = TexImage.parse(data), t.frames.count > 1,
                  t.frames.allSatisfy({ $0.time == 0 }) else { continue }
            checked += 1
            let n = t.frames.count
            // 프레임 k 의 중앙 시각을 찍으면 정확히 k 가 나와야 한다(균일 폴백이므로).
            for k in Set([0, 1, min(2, n - 1), n - 1]).sorted() {
                let mid = (Float(k) + 0.5) * TexImage.fallbackFrameTime
                XCTAssertEqual(TexImage.spriteFrameIndex(frames: t.frames, time: mid), k,
                               "\(rel) 프레임 \(k) 폴백 진행 실패")
            }
            // 한 바퀴 뒤(모듈로 랩)도 0 으로 돌아와야 한다.
            let cycle = Float(n) * TexImage.fallbackFrameTime
            XCTAssertEqual(TexImage.spriteFrameIndex(frames: t.frames, time: cycle + 0.5 * TexImage.fallbackFrameTime), 0, rel)
        }
        XCTAssertGreaterThanOrEqual(checked, 8, "frametime==0 시트가 줄었다 — 폴백 경로가 안 밟혔다")
    }

    /// TEXS0003(frametime 실측값) 은 **종전 식 그대로** 여야 한다 — 폴백이 정상 시트를 건드리면 안 된다.
    /// 짝 `.tex-json` 의 `spritesheetsequences[0].duration / frames` 와 프레임 시간이 일치하는 것으로 고정.
    func testStoredFrameTimesAreUnchanged() throws {
        var checked = 0
        for (rel, data) in try texFiles() {
            guard let t = TexImage.parse(data), t.framesVersion >= 3, t.frames.count > 1 else { continue }
            let ft = t.frames[0].time
            guard ft > 0 else { continue }
            checked += 1
            // 균일 시트라 프레임 k 중앙 = (k+0.5)*ft.
            for k in [0, 1, t.frames.count - 1] {
                XCTAssertEqual(TexImage.spriteFrameIndex(frames: t.frames, time: (Float(k) + 0.5) * ft), k, "\(rel) \(k)")
            }
            XCTAssertNotEqual(ft, TexImage.fallbackFrameTime, "\(rel) 폴백값과 우연히 같으면 판정력이 없다")
        }
        XCTAssertGreaterThanOrEqual(checked, 40, "TEXS0003 시트 표본이 줄었다")
    }

    // MARK: - 2026-08-21 추가: 컨테이너 프레이밍을 **파일 끝으로** 검증한다

    /// **파스가 파일 끝에 정확히 착지하는가.** 조건부 필드(texDepth·previewColor·mip depth)나
    /// 버전별 필드(isLZ4/dec·imageFormat·variantCount)를 하나라도 잘못 세면 mip 테이블이 밀리는데,
    /// 밀린 채로도 개별 필드 검사는 통과할 수 있다(값이 그럴듯하면). 착지는 못 속인다.
    ///
    /// 규약: 마지막 mip 페이로드 끝 == (TEXS 없으면) 파일 끝, (있으면) 거기서 `"TEXS000"` 이 시작.
    /// 실측(2026-08-21, 동봉 311 + 설치 `projects/` 129 = 440건 전수): 착지 실패 **0건**,
    /// TEXS 보유 61건 전부 TEXB 끝에서 시작(61/61), TEXS 없는 379건에 `"TEXS000"` 우연 출현 **0건**.
    /// 마지막 항목이 곧 `parseFrames` 의 역방향 스캔이 이 코퍼스에서 오탐하지 않는다는 근거다.
    func testContainerParseLandsExactlyOnEOF() throws {
        var checkedTail = 0, checkedSheet = 0
        for (rel, data) in try texFiles() {
            let t = try XCTUnwrap(TexImage.parse(data), rel)
            // 동봉 전건이 단일 image + 전 레벨 파스 성공이라 체인이 곧 TEXB 본문이다.
            let chain = t.mipChain.isEmpty ? (t.mip.map { [$0] } ?? []) : t.mipChain
            let end = try XCTUnwrap(chain.last?.payloadRange.upperBound, "\(rel) mip 체인 없음")
            let bytes = [UInt8](data)
            if t.frames.isEmpty {
                XCTAssertEqual(end, data.count, "\(rel) TEXB 끝이 파일 끝과 다르다 — 프레이밍 오독")
                // 역방향 스캔 오탐 후보가 아예 없어야 한다.
                XCTAssertNil(Self.firstIndex(of: Array("TEXS000".utf8), in: bytes),
                             "\(rel) TEXS 섹션이 없는데 시그니처 바이트가 있다 — 오탐 위험")
                checkedTail += 1
            } else {
                guard end >= 0, end + 7 <= bytes.count else {
                    XCTFail("\(rel) TEXB 끝(\(end))이 파일(\(bytes.count)) 밖이다"); continue
                }
                XCTAssertEqual(Array(bytes[end..<(end + 7)]), Array("TEXS000".utf8),
                               "\(rel) TEXS 가 TEXB 바로 뒤에서 시작하지 않는다")
                checkedSheet += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checkedTail, 259, "TEXS 없는 동봉 표본이 줄었다")
        XCTAssertGreaterThanOrEqual(checkedSheet, 52, "TEXS 보유 동봉 표본이 줄었다")
    }

    /// **`decompressedSize` 가 포맷 바이트 모델과 정확히 일치하는가.** `TexImage.mipByteSize` 가
    /// 딛고 선 `format → bpp` 대응(0=4B/px · 4·6=16B/블록 · 7=8B/블록 · 8=2B/px · 9=1B/px)이
    /// 어긋나면 조건 변형 mip 의 LZ4 해제 크기가 틀리고, DXT/raw 분기도 같이 틀린다. 실제로
    /// **fmt9 를 fmt4(DXT5)에 묶어 마스크가 전백이 된 회귀가 있었다** — 그 종류를 여기서 잡는다.
    ///
    /// 파일이 `dec` 를 직접 싣는 레벨(TEXB0002+)까지 포함해 전 레벨을 본다. 실측(2026-08-21):
    /// 440건 2,139 레벨 전부 일치(불일치 0), LZ4 해제 실패 0.
    func testEveryRawMipDecompressedSizeMatchesFormatModel() throws {
        var levels = 0
        for (rel, data) in try texFiles() {
            let t = try XCTUnwrap(TexImage.parse(data), rel)
            // 인코딩 페이로드(PNG/JPEG/GIF/MP4)는 픽셀 모델이 없다 — 대상 아님.
            switch t.payload {
            case .lz4RGBA, .bc3, .bc2, .bc1, .rg88, .r8: break
            default: continue
            }
            let chain = t.mipChain.isEmpty ? (t.mip.map { [$0] } ?? []) : t.mipChain
            for (i, m) in chain.enumerated() {
                let expected = Self.expectedMipBytes(format: t.format, w: m.decodeWidth, h: m.decodeHeight) * m.depth
                XCTAssertEqual(m.decompressedSize, expected,
                               "\(rel) level \(i): fmt \(t.format) \(m.decodeWidth)×\(m.decodeHeight)×\(m.depth)")
                levels += 1
            }
        }
        XCTAssertGreaterThanOrEqual(levels, 1397, "raw mip 레벨 표본이 줄었다")
    }

    /// **프레임이 아틀라스 밖으로 나가는 실물이 있다 — 그 집합을 못박는다.**
    /// WE 패커의 float 반올림 때문에 마지막 열이 통째로 빠지고 밀린 프레임이 바닥을 넘는다
    /// (`TexFrame` 주석의 실측 참조). 이 도수를 고정해 두는 이유 둘:
    ///   · 파서가 지오메트리 필드 순서를 잘못 읽으면 이 집합이 **조용히 달라진다**(다른 검사는
    ///     좌표를 안 본다). 여기가 그 그물이다.
    ///   · 소비처(`SceneRendererFrameEncoder.spriteSubrect`)가 자르기/감기 중 무엇을 하든,
    ///     **입력이 실제로 범위를 넘는다**는 사실은 여기에 근거로 남아야 한다.
    /// 실측(2026-08-21, 동봉 311건): 시트 52건 중 **13건 · 프레임 62개**가 `y + h > 아틀라스 높이`.
    /// x 축으로 넘는 프레임은 **0개**다(패커는 열을 건너뛸 뿐 가로로 넘기지 않는다).
    func testSomeSheetsHaveFramesOutsideTheAtlas() throws {
        var offenders: [String: Int] = [:]
        var xOver = 0, sheets = 0
        for (rel, data) in try texFiles() {
            guard let t = TexImage.parse(data), !t.frames.isEmpty, let mip = t.mip else { continue }
            sheets += 1
            let aw = Float(mip.decodeWidth), ah = Float(mip.decodeHeight)
            for f in t.frames {
                if f.atlasY + f.atlasHeight > ah + 1 { offenders[rel, default: 0] += 1 }
                if f.atlasX + f.atlasWidth > aw + 1 { xOver += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(sheets, 52, "동봉 시트 표본이 줄었다")
        XCTAssertEqual(xOver, 0, "가로로 넘는 프레임이 생겼다 — 지오메트리 필드 순서를 의심할 것")
        XCTAssertEqual(offenders.count, 13, "세로로 넘는 시트 수가 바뀌었다: \(offenders.keys.sorted())")
        XCTAssertEqual(offenders.values.reduce(0, +), 62, "넘는 프레임 총수가 바뀌었다: \(offenders)")
        // 이름까지 고정 — 새 자산이 들어와도 "같은 13건" 인지 사람이 본다.
        let expected = ["bubble1", "jellyfish1", "leaves1", "leaves10", "leaves2", "leaves3", "leaves4",
                        "leaves5", "leaves6", "leaves7", "leaves8", "leaves9", "rosepetals"]
        let stems = offenders.keys.map { rel -> String in
            let leaf = rel.split(separator: "/").last.map(String.init) ?? rel
            return leaf.hasSuffix(".tex") ? String(leaf.dropLast(4)) : leaf
        }.sorted()
        XCTAssertEqual(stems, expected)
    }

    /// `TexImage.mipByteSize` 와 **같은 식을 테스트에 다시 적는다** — 프로덕션 함수를 그대로 부르면
    /// 그 함수가 틀렸을 때 테스트도 같이 틀린다(동어반복). 여기 값은 WE 포맷 enum 정의에서 온다.
    private static func expectedMipBytes(format: Int, w: Int, h: Int) -> Int {
        switch format {
        case 4, 6: return ((w + 3) / 4) * ((h + 3) / 4) * 16   // BC3 / BC2
        case 7:    return ((w + 3) / 4) * ((h + 3) / 4) * 8    // BC1
        case 8:    return w * h * 2                            // RG88
        case 9:    return w * h                                // R8
        default:   return w * h * 4                            // RGBA8888
        }
    }

    /// 무할당 선형 탐색(첫바이트 선비교). `Array(hay[i..<j]) == needle` 은 위치마다 배열을
    /// 새로 만들어 수 MB 자산에서 테스트가 사실상 멈춘다 — 여기서 그 형태를 쓰지 않는 이유다.
    private static func firstIndex(of needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        let first = needle[0]
        let upper = hay.count - needle.count
        var i = 0
        while i <= upper {
            if hay[i] == first {
                var match = true
                var j = 1
                while j < needle.count {
                    if hay[i + j] != needle[j] { match = false; break }
                    j += 1
                }
                if match { return i }
            }
            i += 1
        }
        return nil
    }
}

/// 조건부 필드 3종을 **합성 픽스처**로 고정한다 — 실물엔 조합이 다 없어서 경계가 안 밟힌다.
final class TexConditionalHeaderFieldTests: XCTestCase {
    /// flags 0x40 이면 헤더에 i32 texDepth 가, **mip 레코드에도** i32 depth 가 붙는다.
    /// 둘 중 하나만 반영하면 mip 테이블 전체가 4바이트씩 밀려 파스가 무너진다.
    func testSlice3DAddsDepthToHeaderAndMipRecord() {
        let px: [UInt8] = Array(repeating: 0x7F, count: 2 * 2 * 3 * 4)   // 2×2×3 RGBA
        var b = bytes(tag("TEXV0005"), tag("TEXI0001"))
        b += bytes(i32(0), i32(0x42), i32(2), i32(2), i32(6), i32(2))     // fmt0, flags=clampuvs|slice3d
        b += bytes(i32(3), i32(0x11223344))                               // texDepth=3, previewColor
        b += bytes(tag("TEXB0004"), i32(1), i32(-1), i32(0), i32(1))      // imageCount, imageFormat, variantCount, mipCount
        b += bytes(i32(2), i32(2), i32(3), i32(0), i32(px.count), i32(px.count), px)  // w,h,depth,isLZ4,dec,comp
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.depth, 3)
        XCTAssertEqual(t?.previewColor, 0x11223344)
        XCTAssertTrue(t?.isVolume ?? false)
        XCTAssertEqual(t?.mip?.depth, 3)
        XCTAssertEqual(t?.mip?.decodeWidth, 2)
        XCTAssertEqual(t?.mip?.decodeHeight, 2)
        XCTAssertEqual(t?.mip?.decompressedSize, px.count)
        XCTAssertEqual(t?.payload, .lz4RGBA)
        XCTAssertEqual(t?.mip?.payloadRange.count, px.count)
    }

    /// flags 에 0x40 이 없으면 depth 필드는 **없다**(헤더·mip 둘 다). 기본값 1.
    func testNoSlice3DMeansNoDepthField() {
        let px: [UInt8] = Array(repeating: 0x20, count: 2 * 2 * 4)
        var b = bytes(tag("TEXV0005"), tag("TEXI0001"))
        b += bytes(i32(0), i32(2), i32(2), i32(2), i32(2), i32(2))
        b += bytes(tag("TEXB0004"), i32(1), i32(-1), i32(0), i32(1))
        b += bytes(i32(2), i32(2), i32(0), i32(px.count), i32(px.count), px)
        let t = TexImage.parse(Data(b))
        XCTAssertEqual(t?.depth, 1)
        XCTAssertEqual(t?.mip?.depth, 1)
        XCTAssertFalse(t?.isVolume ?? true)
        XCTAssertEqual(t?.mip?.decompressedSize, px.count)
    }

    /// isLZ4 필드는 엔진이 **bit0 만** 본다(0x14015d484 `and al, 1`). 상위 비트가 켜져도 판정 불변.
    func testIsLZ4UsesOnlyBitZero() {
        let px: [UInt8] = Array(repeating: 0x20, count: 16)
        func make(_ flagWord: Int) -> TexImage? {
            var b = bytes(tag("TEXV0005"), tag("TEXI0001"))
            b += bytes(i32(0), i32(0), i32(2), i32(2), i32(2), i32(2))
            b += bytes(tag("TEXB0004"), i32(1), i32(-1), i32(0), i32(1))
            b += bytes(i32(2), i32(2), i32(flagWord), i32(16), i32(px.count), px)
            return TexImage.parse(Data(b))
        }
        XCTAssertEqual(make(0)?.mip?.lz4, false)
        XCTAssertEqual(make(1)?.mip?.lz4, true)
        XCTAssertEqual(make(0x101)?.mip?.lz4, true, "bit0 켜짐")
        XCTAssertEqual(make(0x100)?.mip?.lz4, false, "bit0 꺼짐 — 상위 비트는 무시")
    }

    /// TEXS 는 v3 부터만 gifWidth/gifHeight 를 싣는다. v2 는 헤더 imgW/imgH 가 기본값(0x14015e268).
    func testTexsGifDimsDefaultForV2() {
        func sheet(_ version: Int, gif: [UInt8]) -> TexImage? {
            var b = bytes(tag("TEXV0005"), tag("TEXI0001"))
            b += bytes(i32(0), i32(4), i32(8), i32(8), i32(8), i32(8))      // IsGif
            b += bytes(tag("TEXB0004"), i32(1), i32(-1), i32(0), i32(1))
            let px: [UInt8] = Array(repeating: 0x40, count: 8 * 8 * 4)
            b += bytes(i32(8), i32(8), i32(0), i32(px.count), i32(px.count), px)
            b += tag("TEXS000\(version)")
            b += i32(2)
            b += gif
            for k in 0..<2 {
                b += bytes(i32(0), f32(0.25), f32(Float(k) * 4), f32(0), f32(4), f32(0), f32(0), f32(4))
            }
            return TexImage.parse(Data(b))
        }
        let v3 = sheet(3, gif: bytes(i32(5), i32(6)))
        XCTAssertEqual(v3?.framesVersion, 3)
        XCTAssertEqual(v3?.gifWidth, 5); XCTAssertEqual(v3?.gifHeight, 6)
        XCTAssertEqual(v3?.frames.count, 2)
        let v2 = sheet(2, gif: [])
        XCTAssertEqual(v2?.framesVersion, 2)
        XCTAssertEqual(v2?.gifWidth, 8); XCTAssertEqual(v2?.gifHeight, 8)
        XCTAssertEqual(v2?.frames.count, 2)
    }

    /// frametime 이 전부 0 이면 폴백(0.016s/프레임), 하나라도 있으면 파일 값 — 경계 고정.
    func testSpriteFrameIndexFallbackBoundary() {
        func fr(_ t: Float, _ i: Int) -> TexImage.TexFrame {
            TexImage.TexFrame(imageId: 0, time: t, x: Float(i) * 4, y: 0, width: 4, height: 4)
        }
        let zero = (0..<4).map { fr(0, $0) }
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: zero, time: 0.008), 0)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: zero, time: 0.024), 1)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: zero, time: 0.056), 3)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: zero, time: 0.072), 0, "한 바퀴 랩")
        // 하나라도 값이 있으면 폴백 금지 — 나머지 0 은 종전대로 1e-4 클램프.
        var mixed = (0..<4).map { fr(0, $0) }
        mixed[0] = fr(1.0, 0)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: mixed, time: 0.5), 0)
        XCTAssertEqual(TexImage.spriteFrameIndex(frames: mixed, time: 1.0 + 1e-5), 1)
    }
}
