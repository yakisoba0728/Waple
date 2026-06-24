# Waple Scene SP3a (Effect Framework + BC3 + waterwaves) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** WE 효과(포스트프로세스 패스)를 씬 객체에 적용한다 — 객체 베이스를 오프스크린 텍스처로 렌더 후 효과 프래그먼트 셰이더(framebuffer+mask+uniforms)로 처리·합성. BC3/LZ4/DXT5 마스크 디코드 + g_Time 애니메이션 + waterwaves 손-포팅. 타깃: `2111201226`.

**Architecture:** 순수 디코드/파싱(`TexImage.bc3`, `DXT5Decoder`, `SceneLayer.effects`)은 TDD. `TexDecoder`가 BC3 경로(LZ4 해제→DXT5)를 추가. `SceneRenderer`가 오프스크린 렌더타깃 + 효과 패스 + g_Time 애니메이션(가림 시 정지)을 수행, `EffectShaders` 레지스트리에서 손-포팅 MSL을 로드.

**Tech Stack:** Swift 5.9, Metal/MetalKit, Accelerate/Compression(LZ4), XCTest. 새 의존성 없음.

## Global Constraints

- 기존 SPM 패키지에 추가. **새 타깃·서드파티 의존성 없음.** tools 5.9, macOS 13+.
- BC3 `.tex`(format==9): TEXB000{3,4} mip 헤더에서 `decompressedSize`(= `((w+3)/4)*((h+3)/4)*16`)를 int 스트림에서 찾고 그 다음 int=`compressedSize`, 이후 LZ4 payload. → `COMPRESSION_LZ4_RAW`(dst=decompressedSize)로 해제 → DXT5 디코드 → RGBA8888.
- 효과 부착: `object.effects = [{file, passes:[{constantshadervalues:{...}, textures:[fb, mask]}]}]`. effectName = file 경로의 effects/<name>/ 세그먼트. SP3a 지원: `waterwaves`만(미지원 스킵).
- 효과 있는 씬만 연속 드로우(`isPaused=false`, 30fps), g_Time 누적, **가려지면 일시정지**. 효과 없는 씬은 기존 온디맨드.
- 미지원 효과/디코드 실패 → 효과 스킵(베이스만), 무크래시.

**전제:** main에서 시작(SP2 병합), `swift build`/`swift test` 그린. 타깃 씬 `/Users/yakisoba/Downloads/packages/2111201226`.

---

### Task 1: `TexImage` BC3 mip 파싱

**Files:**
- Modify: `Sources/WapleCore/TexImage.swift`
- Modify: `Tests/WapleCoreTests/TexImageTests.swift`

**Interfaces:**
- Produces: `TexImage.bc3: BC3Mip?` where `struct BC3Mip: Equatable { let width:Int; let height:Int; let decompressedSize:Int; let payloadRange: Range<Int> }`

- [ ] **Step 1: 실패 테스트 추가**

`Tests/WapleCoreTests/TexImageTests.swift` 에 메서드 추가(클래스 내부). 헬퍼 `makeTex`는 기존 것 재사용하되, BC3는 TEXB 컨테이너가 필요하므로 전용 빌더를 추가:
```swift
    /// format=9 BC3 .tex: TEX 헤더 + "TEXB0003" + mipCount + 7 ints(decompressedSize 포함) + payload.
    private func makeBC3Tex(w: Int, h: Int, payload: [UInt8]) -> Data {
        func i32(_ v: Int) -> [UInt8] { let u = UInt32(truncatingIfNeeded: v); return [UInt8(u & 0xff), UInt8((u>>8)&0xff), UInt8((u>>16)&0xff), UInt8((u>>24)&0xff)] }
        let dxt5 = ((w + 3) / 4) * ((h + 3) / 4) * 16
        var b: [UInt8] = []
        b += Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(9) + i32(0) + i32(w) + i32(h) + i32(w) + i32(h)   // format=9, dims
        b += Array("TEXB0003".utf8) + [0]
        b += i32(1)                       // mipCount
        b += i32(-1) + i32(1) + i32(w) + i32(h) + i32(1)  // leading ints
        b += i32(dxt5) + i32(payload.count)               // decompressedSize, compressedSize
        b += payload
        return Data(b)
    }

    func testParsesBC3Mip() {
        let payload: [UInt8] = Array(0..<40)
        let t = TexImage.parse(makeBC3Tex(w: 8, h: 8, payload: payload))
        XCTAssertEqual(t?.payload, .bc3)
        let mip = t?.bc3
        XCTAssertEqual(mip?.width, 8); XCTAssertEqual(mip?.height, 8)
        XCTAssertEqual(mip?.decompressedSize, 64)             // (8/4)*(8/4)*16 = 64
        XCTAssertEqual(mip?.payloadRange.count, payload.count)
    }
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter TexImageTests/testParsesBC3Mip`
Expected: 컴파일 에러 (`bc3`/`BC3Mip` 없음).

- [ ] **Step 3: 구현**

`Sources/WapleCore/TexImage.swift` 의 `TexImage` 구조체에 추가(프로퍼티 + 중첩 타입):
```swift
    public struct BC3Mip: Equatable {
        public let width: Int
        public let height: Int
        public let decompressedSize: Int
        public let payloadRange: Range<Int>
    }
```
`parse(_:)` 의 `let (kind, start) = detect(...)` 다음, `return` 전에:
```swift
        var bc3: BC3Mip? = nil
        if kind == .bc3 {
            bc3 = parseBC3(b, imgW: width, imgH: height)
        }
```
그리고 `TexImage` 의 `payload`/`payloadRange` 저장 프로퍼티 옆에 `public let bc3: BC3Mip?` 추가하고, 생성자 호출에 `bc3: bc3` 추가. (기존 `return TexImage(width:..., payloadRange: start..<b.count)` 을 `bc3` 포함하도록 변경.) 비-BC3는 `bc3=nil`.
`detect` 아래에 헬퍼 추가:
```swift
    private static func parseBC3(_ b: [UInt8], imgW: Int, imgH: Int) -> BC3Mip? {
        guard let ti = indexOf(b, Array("TEXB".utf8)) else { return nil }
        func i32(_ o: Int) -> Int? {
            guard o + 4 <= b.count else { return nil }
            return Int(UInt32(b[o]) | UInt32(b[o+1])<<8 | UInt32(b[o+2])<<16 | UInt32(b[o+3])<<24)
        }
        let expected = ((imgW + 3) / 4) * ((imgH + 3) / 4) * 16
        var p = ti + 9 + 4   // skip "TEXB000N\0" + mipCount
        for _ in 0..<12 {     // scan ints for decompressedSize == expected
            guard let v = i32(p) else { return nil }
            if v == expected {
                guard let comp = i32(p + 4) else { return nil }
                let start = p + 8
                guard start + comp <= b.count, comp >= 0 else { return nil }
                return BC3Mip(width: imgW, height: imgH, decompressedSize: expected, payloadRange: start..<start + comp)
            }
            p += 4
        }
        return nil
    }
    private static func indexOf(_ b: [UInt8], _ sig: [UInt8]) -> Int? {
        guard b.count >= sig.count else { return nil }
        var i = 0
        while i <= b.count - sig.count { if Array(b[i..<i+sig.count]) == sig { return i }; i += 1 }
        return nil
    }
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter TexImageTests`
Expected: PASS (기존 + 신규). 비-BC3 테스트는 `bc3 == nil`로 영향 없음.

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleCore/TexImage.swift Tests/WapleCoreTests/TexImageTests.swift
git commit -m "feat: parse BC3 mip (decompressed/compressed/payload) from .tex"
```

---

### Task 2: `DXT5Decoder` (BC3 블록 → RGBA, 순수)

**Files:**
- Create: `Sources/WapleRender/DXT5Decoder.swift`
- Test: `Tests/WapleRenderTests/DXT5DecoderTests.swift`

**Interfaces:**
- Produces: `enum DXT5Decoder { static func decode(_ blocks: Data, width: Int, height: Int) -> Data? }` (RGBA8888, width*height*4)

- [ ] **Step 1: 실패 테스트 작성**

`Tests/WapleRenderTests/DXT5DecoderTests.swift`:
```swift
import XCTest
@testable import WapleRender

final class DXT5DecoderTests: XCTestCase {
    /// 4x4 단색 블록: alpha=255, color0=color1=white → 전부 흰색 불투명.
    func testDecodesSolidWhiteBlock() {
        var block = [UInt8](repeating: 0, count: 16)
        block[0] = 255; block[1] = 255            // alpha endpoints a0=a1=255 → 모든 알파 255
        // alpha indices(6B)=0 → index0 → a0=255
        block[8] = 0xFF; block[9] = 0xFF          // color0 = 565 white
        block[10] = 0xFF; block[11] = 0xFF        // color1 = 565 white
        // color indices(4B)=0 → color0
        let out = DXT5Decoder.decode(Data(block), width: 4, height: 4)
        XCTAssertEqual(out?.count, 4 * 4 * 4)
        let px = [UInt8](out!)
        XCTAssertEqual(px[0], 255); XCTAssertEqual(px[1], 255); XCTAssertEqual(px[2], 255); XCTAssertEqual(px[3], 255)
    }

    func testWrongSizeReturnsNil() {
        XCTAssertNil(DXT5Decoder.decode(Data([0, 1, 2]), width: 4, height: 4))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter DXT5DecoderTests`
Expected: 컴파일 에러 ("cannot find 'DXT5Decoder'").

- [ ] **Step 3: 구현**

`Sources/WapleRender/DXT5Decoder.swift`:
```swift
import Foundation

public enum DXT5Decoder {
    /// DXT5(BC3) 블록 → RGBA8888. blocks 크기는 ((w+3)/4)*((h+3)/4)*16 이어야 함.
    public static func decode(_ blocks: Data, width: Int, height: Int) -> Data? {
        let bx = (width + 3) / 4, by = (height + 3) / 4
        guard blocks.count >= bx * by * 16, width > 0, height > 0 else { return nil }
        let src = [UInt8](blocks)
        var out = [UInt8](repeating: 0, count: width * height * 4)

        func u16(_ o: Int) -> Int { Int(src[o]) | (Int(src[o + 1]) << 8) }
        func color565(_ c: Int) -> (Int, Int, Int) {
            let r = (c >> 11) & 0x1f, g = (c >> 5) & 0x3f, b = c & 0x1f
            return (r * 255 / 31, g * 255 / 63, b * 255 / 31)
        }

        for byi in 0..<by {
            for bxi in 0..<bx {
                let o = (byi * bx + bxi) * 16
                // --- alpha (BC4) ---
                let a0 = Int(src[o]), a1 = Int(src[o + 1])
                var alpha = [Int](repeating: 0, count: 8)
                alpha[0] = a0; alpha[1] = a1
                if a0 > a1 {
                    for i in 1...6 { alpha[i + 1] = ((7 - i) * a0 + i * a1) / 7 }
                } else {
                    for i in 1...4 { alpha[i + 1] = ((5 - i) * a0 + i * a1) / 5 }
                    alpha[6] = 0; alpha[7] = 255
                }
                var abits: UInt64 = 0
                for i in 0..<6 { abits |= UInt64(src[o + 2 + i]) << (8 * i) }
                // --- color (BC1, DXT5 always 4-color) ---
                let c0 = u16(o + 8), c1 = u16(o + 10)
                let (r0, g0, b0) = color565(c0), (r1, g1, b1) = color565(c1)
                func lerp(_ x: Int, _ y: Int, _ t: Int) -> Int { (x * (3 - t) + y * t) / 3 }
                let palette: [(Int, Int, Int)] = [
                    (r0, g0, b0), (r1, g1, b1),
                    (lerp(r0, r1, 1), lerp(g0, g1, 1), lerp(b0, b1, 1)),
                    (lerp(r0, r1, 2), lerp(g0, g1, 2), lerp(b0, b1, 2)),
                ]
                let cbits = UInt32(src[o + 12]) | (UInt32(src[o + 13]) << 8) | (UInt32(src[o + 14]) << 16) | (UInt32(src[o + 15]) << 24)
                for py in 0..<4 {
                    for px in 0..<4 {
                        let x = bxi * 4 + px, y = byi * 4 + py
                        if x >= width || y >= height { continue }
                        let idx = py * 4 + px
                        let ai = Int((abits >> UInt64(3 * idx)) & 0x7)
                        let ci = Int((cbits >> UInt32(2 * idx)) & 0x3)
                        let (r, g, b) = palette[ci]
                        let d = (y * width + x) * 4
                        out[d] = UInt8(r); out[d + 1] = UInt8(g); out[d + 2] = UInt8(b); out[d + 3] = UInt8(alpha[ai])
                    }
                }
            }
        }
        return Data(out)
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter DXT5DecoderTests`
Expected: PASS (2 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleRender/DXT5Decoder.swift Tests/WapleRenderTests/DXT5DecoderTests.swift
git commit -m "feat: DXT5 (BC3) block decoder to RGBA"
```

---

### Task 3: `TexDecoder` BC3 경로 (LZ4 해제 + DXT5)

**Files:**
- Modify: `Sources/WapleRender/TexDecoder.swift`
- Test: `Tests/WapleRenderTests/TexDecoderTests.swift`

**Interfaces:**
- Consumes: `TexImage.bc3`, `DXT5Decoder.decode`
- Produces: `TexDecoder.rgba` 의 `.bc3` 경로가 RGBA 반환

- [ ] **Step 1: 실패 테스트 추가**

`Tests/WapleRenderTests/TexDecoderTests.swift` 에 추가(import Compression 필요):
```swift
    func testDecodesBC3ViaLZ4RoundTrip() throws {
        // 4x4 단색 흰 DXT5 블록(16B)을 LZ4_RAW로 압축해 BC3 .tex 합성 → 디코드.
        var block = [UInt8](repeating: 0, count: 16)
        block[0] = 255; block[1] = 255; block[8] = 0xFF; block[9] = 0xFF; block[10] = 0xFF; block[11] = 0xFF
        let raw = Data(block)
        var comp = [UInt8](repeating: 0, count: 256)
        let n = raw.withUnsafeBytes { srcp in
            comp.withUnsafeMutableBytes { dstp in
                compression_encode_buffer(dstp.bindMemory(to: UInt8.self).baseAddress!, 256,
                                          srcp.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        XCTAssertGreaterThan(n, 0)
        func i32(_ v: Int) -> [UInt8] { let u = UInt32(truncatingIfNeeded: v); return [UInt8(u & 0xff), UInt8((u>>8)&0xff), UInt8((u>>16)&0xff), UInt8((u>>24)&0xff)] }
        var b: [UInt8] = Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(9) + i32(0) + i32(4) + i32(4) + i32(4) + i32(4)
        b += Array("TEXB0003".utf8) + [0] + i32(1) + i32(-1) + i32(1) + i32(4) + i32(4) + i32(1) + i32(16) + i32(n)
        b += Array(comp[0..<n])
        let data = Data(b)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.payload, .bc3)
        let out = try XCTUnwrap(TexDecoder.rgba(from: tex, data: data))
        XCTAssertEqual(out.width, 4); XCTAssertEqual(out.height, 4)
        XCTAssertEqual([UInt8](out.pixels)[0], 255)  // white
    }
```
파일 상단 import 에 `import Compression` 추가.

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter TexDecoderTests/testDecodesBC3ViaLZ4RoundTrip`
Expected: FAIL (`.bc3` 경로가 nil 반환).

- [ ] **Step 3: 구현**

`Sources/WapleRender/TexDecoder.swift` 상단에 `import Compression` 추가. `rgba(from:data:)` 의 `case .bc3, .video, .unknown: return nil` 을 다음으로 교체:
```swift
        case .bc3:
            guard let mip = tex.bc3 else { return nil }
            let comp = data.subdata(in: mip.payloadRange)
            var dst = [UInt8](repeating: 0, count: mip.decompressedSize)
            let got = comp.withUnsafeBytes { srcp in
                dst.withUnsafeMutableBytes { dstp in
                    compression_decode_buffer(dstp.bindMemory(to: UInt8.self).baseAddress!, mip.decompressedSize,
                                              srcp.bindMemory(to: UInt8.self).baseAddress!, comp.count, nil, COMPRESSION_LZ4_RAW)
                }
            }
            guard got == mip.decompressedSize,
                  let rgba = DXT5Decoder.decode(Data(dst), width: mip.width, height: mip.height) else { return nil }
            return (rgba, mip.width, mip.height)
        case .video, .unknown:
            return nil
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter TexDecoderTests`
Expected: PASS.

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleRender/TexDecoder.swift Tests/WapleRenderTests/TexDecoderTests.swift
git commit -m "feat: TexDecoder BC3 path (LZ4 raw decompress + DXT5)"
```

---

### Task 4: `SceneLayer.effects` 파싱

**Files:**
- Modify: `Sources/WapleCore/SceneDocument.swift`
- Modify: `Tests/WapleCoreTests/SceneDocumentTests.swift`

**Interfaces:**
- Produces:
  - `struct SceneEffect: Equatable { let name: String; let constants: [String: Float]; let maskTextureName: String? }`
  - `SceneLayer.effects: [SceneEffect]`

- [ ] **Step 1: 실패 테스트 추가**

`Tests/WapleCoreTests/SceneDocumentTests.swift` 에 메서드 추가:
```swift
    func testParsesObjectEffects() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true},
                     "effects":[{"file":"effects/waterwaves/effect.json",
                       "passes":[{"constantshadervalues":{"speed":3.97,"scale":34.66},
                                  "textures":[null,"masks/wmask"]}]}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let eff = try XCTUnwrap(try SceneDocument.parse(package: p).layers.first?.effects.first)
        XCTAssertEqual(eff.name, "waterwaves")
        XCTAssertEqual(eff.constants["speed"], 3.97)
        XCTAssertEqual(eff.constants["scale"], 34.66)
        XCTAssertEqual(eff.maskTextureName, "masks/wmask")
    }

    func testLayerWithoutEffectsHasEmptyArray() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        XCTAssertEqual(try SceneDocument.parse(package: p).layers.first?.effects.count, 0)
    }
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter SceneDocumentTests`
Expected: 컴파일 에러 (`SceneEffect`/`effects` 없음).

- [ ] **Step 3: 구현**

`Sources/WapleCore/SceneDocument.swift`:

(a) `SceneLayer` 위에 `SceneEffect` 추가, `SceneLayer` 에 `effects` 필드 추가:
```swift
public struct SceneEffect: Equatable {
    public let name: String
    public let constants: [String: Float]
    public let maskTextureName: String?
}
```
`SceneLayer` 의 `parallaxDepth` 다음에 `public let effects: [SceneEffect]` 추가.

(b) `parse` 의 layer append 에서, `parallaxDepth:` 다음 인자에 추가:
```swift
                parallaxDepth: vec2(obj["parallaxDepth"] as? String) ?? Vec2(x: 1, y: 1),
                effects: parseEffects(obj["effects"])
```

(c) 헬퍼 추가(다른 private static 옆):
```swift
    private static func parseEffects(_ raw: Any?) -> [SceneEffect] {
        guard let arr = raw as? [Any] else { return [] }
        var out: [SceneEffect] = []
        for case let e as [String: Any] in arr {
            let file = (e["file"] as? String) ?? ""
            // "effects/<name>/effect.json" → name
            let parts = file.split(separator: "/")
            let name = parts.count >= 2 ? String(parts[parts.count - 2]) : file
            var constants: [String: Float] = [:]
            var mask: String? = nil
            if let passes = e["passes"] as? [Any], let pass0 = passes.first as? [String: Any] {
                if let cs = pass0["constantshadervalues"] as? [String: Any] {
                    for (k, v) in cs { if let f = float(v) { constants[k] = f } }
                }
                if let texs = pass0["textures"] as? [Any], texs.count >= 2, let m = texs[1] as? String { mask = m }
            }
            out.append(SceneEffect(name: name, constants: constants, maskTextureName: mask))
        }
        return out
    }
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter SceneDocumentTests`
Expected: PASS (기존 + 신규 2개).

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleCore/SceneDocument.swift Tests/WapleCoreTests/SceneDocumentTests.swift
git commit -m "feat: parse per-object effects (name, constants, mask)"
```

---

### Task 5: `EffectShaders` (waterwaves MSL 레지스트리)

빌드 전용.

**Files:**
- Create: `Sources/WapleRender/EffectShaders.swift`

**Interfaces:**
- Produces: `enum EffectShaders { static func source(for name: String) -> String? }` — waterwaves의 vert+frag MSL 포함(없으면 nil)

- [ ] **Step 1: 작성**

`Sources/WapleRender/EffectShaders.swift`:
```swift
enum EffectShaders {
    /// 효과 이름 → MSL(vert: ev_main, frag: ef_main). framebuffer=texture0, mask=texture1.
    /// uniforms(buffer0): {float2 direction; float time; float speed; float scale; float strength; float perspective;}
    static func source(for name: String) -> String? {
        switch name {
        case "waterwaves": return waterwaves
        default: return nil
        }
    }

    private static let waterwaves = """
    #include <metal_stdlib>
    using namespace metal;
    struct EUniforms { float2 direction; float time; float speed; float scale; float strength; float perspective; };
    struct EOut { float4 pos [[position]]; float2 uv; };
    vertex EOut ev_main(uint vid [[vertex_id]], const device float2* verts [[buffer(0)]]) {
        // 풀스크린 트라이앵글 스트립 4점: (-1,-1)(1,-1)(-1,1)(1,1), uv=(0,1)(1,1)(0,0)(1,0)
        float2 p = verts[vid];
        EOut o; o.pos = float4(p, 0.0, 1.0); o.uv = float2((p.x + 1) * 0.5, 1.0 - (p.y + 1) * 0.5); return o;
    }
    fragment float4 ef_main(EOut in [[stage_in]],
                            texture2d<float> fb [[texture(0)]],
                            texture2d<float> mask [[texture(1)]],
                            constant EUniforms& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 dir = u.direction;
        float maskV = mask.sample(s, in.uv).r;
        float2 tc = in.uv;
        float pos = abs(dot(tc - 0.5, dir));
        float distance = u.time * u.speed + dot(tc, dir) * (u.scale + u.perspective * pos);
        float2 offset = float2(dir.y, -dir.x);
        float strength = u.strength * u.strength + u.perspective * pos;
        tc += sin(distance) * offset * strength * maskV;
        return fb.sample(s, tc);
    }
    """
}
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build`
Expected: 성공.

- [ ] **Step 3: 커밋**

```bash
git add Sources/WapleRender/EffectShaders.swift
git commit -m "feat: EffectShaders registry with hand-ported waterwaves MSL"
```

---

### Task 6: `SceneRenderer` 오프스크린 효과 패스 + g_Time 애니메이션

빌드 전용. 시각 검증은 Task 7.

**Files:**
- Modify: `Sources/WapleRender/SceneRenderer.swift`

**Interfaces:**
- Consumes: `SceneLayer.effects`, `SceneEffect`, `EffectShaders`, `TexImage`/`TexDecoder`(BC3 마스크), `DXT5Decoder`

- [ ] **Step 1: GPULayer에 효과 정보 추가**

`Sources/WapleRender/SceneRenderer.swift` 의 `GPULayer` 를 다음으로 교체:
```swift
    private struct EffectGPU { let pipeline: MTLRenderPipelineState; let mask: MTLTexture; let constants: [String: Float] }
    private struct GPULayer { let texture: MTLTexture; let vertexBuffer: MTLBuffer; let tint: SIMD4<Float>; let parallaxDepth: SIMD2<Float>; let effects: [EffectGPU]; let texWidth: Int; let texHeight: Int }
```

- [ ] **Step 2: 애니메이션/시간 프로퍼티 추가**

`private let maxShift: Float = 0.1` 다음에 추가:
```swift
    private var startTime = CFAbsoluteTimeGetCurrent()
    private var hasEffects = false
    private var effectVertexBuffer: MTLBuffer?
    private var fullscreenQuad: [SIMD2<Float>] = [SIMD2(-1,-1), SIMD2(1,-1), SIMD2(-1,1), SIMD2(1,1)]
```

- [ ] **Step 3: buildLayers에서 효과 파이프라인·마스크 구성**

`buildLayers` 를 다음으로 교체:
```swift
    private func buildLayers(doc: SceneDocument, package: ScenePackage, device: MTLDevice) -> [GPULayer] {
        let w = Float(doc.projectionWidth), h = Float(doc.projectionHeight)
        var out: [GPULayer] = []
        for layer in doc.layers {
            guard let texData = package.data(for: layer.textureEntryName),
                  let tex = TexImage.parse(texData),
                  let decoded = TexDecoder.rgba(from: tex, data: texData),
                  let mtl = makeTexture(decoded.pixels, decoded.width, decoded.height, device) else { continue }
            let verts = quadVertices(layer: layer, projW: w, projH: h)
            guard let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<SIMD4<Float>>.stride * verts.count) else { continue }
            let tint = SIMD4<Float>(layer.color.x * layer.brightness, layer.color.y * layer.brightness,
                                    layer.color.z * layer.brightness, layer.alpha)
            var effects: [EffectGPU] = []
            for eff in layer.effects {
                guard let src = EffectShaders.source(for: eff.name),
                      let mask = effectMask(eff.maskTextureName, package: package, device: device),
                      let pipe = effectPipeline(source: src, device: device) else { continue }
                effects.append(EffectGPU(pipeline: pipe, mask: mask, constants: eff.constants))
            }
            if !effects.isEmpty { hasEffects = true }
            out.append(GPULayer(texture: mtl, vertexBuffer: vbuf, tint: tint,
                                parallaxDepth: SIMD2<Float>(layer.parallaxDepth.x, layer.parallaxDepth.y),
                                effects: effects, texWidth: decoded.width, texHeight: decoded.height))
        }
        return out
    }

    private func effectMask(_ name: String?, package: ScenePackage, device: MTLDevice) -> MTLTexture? {
        // 마스크 없거나 디코드 실패 → 흰색 1x1(=효과 전체 적용).
        if let name {
            let cand = name.hasSuffix(".tex") ? name : "materials/\(name).tex"
            if let d = package.data(for: cand) ?? package.data(for: name),
               let tex = TexImage.parse(d), let dec = TexDecoder.rgba(from: tex, data: d),
               let m = makeTexture(dec.pixels, dec.width, dec.height, device) { return m }
        }
        return makeTexture(Data([255, 255, 255, 255]), 1, 1, device)
    }

    private func effectPipeline(source: String, device: MTLDevice) -> MTLRenderPipelineState? {
        guard let lib = try? device.makeLibrary(source: source, options: nil) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "ev_main")
        pd.fragmentFunction = lib.makeFunction(name: "ef_main")
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: pd)
    }

    private func makeOffscreen(_ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: max(w,1), height: max(h,1), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: d)
    }
```

- [ ] **Step 4: mount에서 효과 vertex 버퍼 + 애니메이션 모드**

`mount` 의 `view.needsDisplay = true`(패럴랙스 블록 앞) 직전에 효과 quad 버퍼와 모드 설정. 패럴랙스 블록 다음에 추가:
```swift
        effectVertexBuffer = device.makeBuffer(bytes: fullscreenQuad, length: MemoryLayout<SIMD2<Float>>.stride * fullscreenQuad.count)
        if hasEffects {
            view.isPaused = false
            view.enableSetNeedsDisplay = false
            view.preferredFramesPerSecond = 30
            startTime = CFAbsoluteTimeGetCurrent()
        }
```

- [ ] **Step 5: draw에서 효과 패스 적용**

`draw(in:)` 전체를 다음으로 교체:
```swift
    public func draw(in view: MTKView) {
        guard let device, let queue, let pipeline,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        // 가림 시 애니메이션 정지(배터리).
        if hasEffects, view.window?.occlusionState.contains(.visible) == false { return }
        let time = Float(CFAbsoluteTimeGetCurrent() - startTime)

        // 효과 있는 레이어는 오프스크린 베이스→효과 패스 후 결과 텍스처로 교체.
        var displayTextures: [MTLTexture] = []
        for layer in layers {
            if layer.effects.isEmpty { displayTextures.append(layer.texture); continue }
            guard var current = makeOffscreen(layer.texWidth, layer.texHeight, device),
                  let evb = effectVertexBuffer else { displayTextures.append(layer.texture); continue }
            blit(layer.texture, to: current, device: device, queue: queue)  // 베이스 복사
            for eff in layer.effects {
                guard let next = makeOffscreen(layer.texWidth, layer.texHeight, device) else { break }
                applyEffect(eff, src: current, dst: next, evb: evb, time: time, cb: cb)
                current = next
            }
            displayTextures.append(current)
        }

        var camOffset = cameraOffset
        rpd.colorAttachments[0].clearColor = clearColor
        rpd.colorAttachments[0].loadAction = .clear
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        for (i, layer) in layers.enumerated() {
            var tint = layer.tint
            var depth = layer.parallaxDepth
            enc.setVertexBuffer(layer.vertexBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            enc.setVertexBytes(&depth, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            enc.setFragmentTexture(displayTextures[i], index: 0)
            enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    private func blit(_ src: MTLTexture, to dst: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) {
        guard let cb = queue.makeCommandBuffer(), let b = cb.makeBlitCommandEncoder() else { return }
        let w = min(src.width, dst.width), h = min(src.height, dst.height)
        b.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
               sourceSize: MTLSize(width: w, height: h, depth: 1),
               to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    }

    private func applyEffect(_ eff: EffectGPU, src: MTLTexture, dst: MTLTexture, evb: MTLBuffer, time: Float, cb: MTLCommandBuffer) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(eff.pipeline)
        enc.setVertexBuffer(evb, offset: 0, index: 0)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentTexture(eff.mask, index: 1)
        var u = effectUniforms(eff.constants, time: time)
        enc.setFragmentBytes(&u, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
```

- [ ] **Step 6: EffectUniforms + teardown**

`SceneRenderer` 내부(파일 상단 import 다음 또는 클래스 위)에 추가:
```swift
private struct EffectUniforms { var direction: SIMD2<Float>; var time: Float; var speed: Float; var scale: Float; var strength: Float; var perspective: Float }
```
`effectUniforms` 헬퍼 추가(클래스 내):
```swift
    private func effectUniforms(_ c: [String: Float], time: Float) -> EffectUniforms {
        let dirDeg = c["direction"] ?? 0
        let a = dirDeg * .pi / 180
        return EffectUniforms(direction: SIMD2<Float>(cos(a), sin(a)), time: time,
                              speed: c["speed"] ?? 5, scale: c["scale"] ?? 200,
                              strength: c["strength"] ?? 0.1, perspective: c["perspective"] ?? 0)
    }
```
`teardown()` 에 변화 없음(기존 정리로 충분; 애니메이션은 뷰 제거로 멈춤).

- [ ] **Step 7: 빌드 확인**

Run: `swift build`
Expected: 성공.

- [ ] **Step 8: 커밋**

```bash
git add Sources/WapleRender/SceneRenderer.swift
git commit -m "feat: offscreen effect passes with g_Time animation and occlusion pause"
```

---

### Task 7: 시각 게이트 (waterwaves 엔드투엔드 — 자율/수동)

자동 테스트 불가. **수동/자율.** 효과 렌더·애니메이션·디코드 정확도 실측.

**Files:** 없음(검증). 어긋나면 좌표/스케일/LZ4 조정.

- [ ] **Step 1: 임시 적용**

`Sources/Waple/AppDelegate.swift` 끝에 임시(커밋 금지):
```swift
        apply(folderURL: URL(fileURLWithPath: "/Users/yakisoba/Downloads/packages/2111201226", isDirectory: true))
```

- [ ] **Step 2: 실행·관찰**

Run: `swift build && swift run Waple` (데스크탑 보이게)
관찰:
- `2111201226`의 WallpaperEngine 레이어에 **물결 왜곡이 애니메이션**(시간에 따라 흐름)되는가?
- 마스크 영역에서만 왜곡(마스크=BC3 디코드 정상)인가?
- 데스크탑 가리면 애니메이션 정지(가림 일시정지)인가?
- 효과 없는 레이어(Clock 등)는 정상 합성인가?

- [ ] **Step 3: 어긋남 보정**

- 효과가 안 보임/검은 화면: 오프스크린 패스의 framebuffer uv Y축(`ev_main`의 uv 식)·블렌딩 확인.
- 마스크가 깨짐(잡색): LZ4 변형 의심 → `COMPRESSION_LZ4_RAW` 대신 `COMPRESSION_LZ4` 시도, 또는 DXT5 알파/컬러 인덱스 확인.
- 왜곡 과/소: `scale`/`strength`/g_Time 단위 매칭(WE는 g_Time=초). speed/scale은 constantshadervalues 그대로.
보정은 해당 파일만 수정 후 커밋.

- [ ] **Step 4: 임시 제거 + 검증**

```bash
git checkout -- Sources/Waple/AppDelegate.swift
grep -rn "TEMP" Sources/ || echo clean
swift build && swift test 2>&1 | grep -E "Test Suite '.*xctest' (passed|failed)"
```

---

## Self-Review (작성자 체크리스트 결과)

**1. 스펙 커버리지**
- BC3 mip 파싱(§3.1) → Task 1 ✅
- DXT5 디코드(§3.1) → Task 2 ✅
- LZ4 해제 + BC3 경로(§3.1) → Task 3 ✅
- 효과 파싱(§2) → Task 4 ✅
- waterwaves 손-포팅(§2) → Task 5 ✅
- 오프스크린 효과 패스 + g_Time + 가림 정지(§3.2,§3.3) → Task 6 ✅
- 시각 게이트(LZ4/좌표/느낌/가림)(§7) → Task 7 ✅
- 미지원/실패 강등(§6) → Task 6(effects 비면 skip, 마스크 실패→흰색, EffectShaders nil→skip) ✅
- TDD(§8) → Task 1–4 ✅; 수동 게이트 → Task 7 ✅

**2. 플레이스홀더 스캔:** 없음. Metal/디코드/튜닝은 구체 코드·절차. ✅

**3. 타입 일관성:** `TexImage.bc3:BC3Mip`(width/height/decompressedSize/payloadRange), `DXT5Decoder.decode(_:width:height:)`,
`TexDecoder.rgba` BC3 경로, `SceneEffect`(name/constants/maskTextureName)·`SceneLayer.effects`,
`EffectShaders.source(for:)`(ev_main/ef_main, EUniforms), `SceneRenderer` EffectGPU/EffectUniforms/effectUniforms/applyEffect/blit/makeOffscreen — 일치. ✅

**범위 밖(스펙 §9):** blur/tint/scroll/opacity/shake(SP3b), 씬-와이드/bloom, 다중 패스 심화, 파티클(SP4)/오디오(SP5).
