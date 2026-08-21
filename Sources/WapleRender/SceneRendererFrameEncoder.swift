import AppKit
import MetalKit
import simd
import WapleCore

// SceneRenderer 프레임 인코더(갓클래스 3분할 ②, 2026-07-04 — 코드 이동 + private→internal 만, 로직 무변경):
// per-frame 인코딩 경로 — drawPlan 공용 루프(encodeDrawPlan), 레이어/텍스트/파티클 인코딩,
// 효과 체인 실행(applyEffect/buildDisplayTextures), 컴포지션(_rt_) 처리, 오프스크린 풀,
// px→NDC 지오메트리 헬퍼, PNG readback. 리소스 빌드는 SceneRendererResources.swift 참조.
/// per-frame 갱신 정점의 재사용 버퍼(3-슬롯 링). 매 프레임 makeBuffer 신규 할당(30fps × 레이어/
/// 파티클 수) 대신 기존 버퍼에 memcpy 하고 **크기 부족 시에만 재할당**. 슬롯 로테이션은 in-flight
/// GPU 프레임(MTKView drawable 최대 3장)이 아직 읽고 있는 버퍼를 CPU 가 덮어쓰는 경합을 회피한다
/// (setVertexBytes 와 달리 setVertexBuffer 는 GPU 실행 시점에 내용을 읽는다).
final class DynamicVertexBuffer {
    private var slots: [MTLBuffer?] = [nil, nil, nil]
    private var cursor = 0
    /// data 를 다음 슬롯 버퍼에 적재해 반환(부족 시에만 재할당). 빈 배열 → nil.
    func load<T>(_ data: [T], device: MTLDevice) -> MTLBuffer? {
        let length = MemoryLayout<T>.stride * data.count
        guard length > 0 else { return nil }
        cursor = (cursor + 1) % slots.count
        if let b = slots[cursor], b.length >= length {
            data.withUnsafeBytes { _ = memcpy(b.contents(), $0.baseAddress!, length) }
            return b
        }
        let b = data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: length) }
        slots[cursor] = b
        return b
    }
}

extension SceneRenderer {
    /// EngineU 버퍼: mvp(항등) + timeAndPad(time,pointer,dt) + pointerLastAndPad + texRes[8](슬롯별 실제 dims)
    /// + texWrap[8](F162/F163: 슬롯별 1=clamp/0=repeat, pass.texWrap 그대로 — 빌드 시 고정이라 런타임 재계산 불요)
    /// + texFilter[8](감사 V07: 슬롯별 1=nearest/0=linear, pass.texFilter 그대로 — TexImage.noInterpolation)
    /// + layerTint[4](H1: 레이어 color×brightness/alpha — 이펙트는 (1,1,1,1) 기본값) + X-⑤ targetRes[4]
    /// (g_TexelSize/g_TexelSizeHalf 전용 — 이펙트 체인 경로는 출력(dst) 해상도 고정값, 전 패스 불변).
    /// 레이아웃은 GLSLTranslator.assemble 의 EngineU 구조체 방출과 동기 필수.
    /// targetRes 는 의도적으로 기본값 없음(교차배치 리뷰 must_fix) — 신규 호출부는 자기 렌더 타깃
    /// 해상도를 명시 전달할 것(예: 3D 커스텀 메시 경로라면 소스 texRes.first 근사). 기본값 (1,1,1,1)
    /// 을 되살리면 그 호출부만 g_TexelSize=1.0 으로 조용히 깨진다 — 컴파일 에러가 나면 값을 채울 것,
    /// 파라미터를 다시 옵셔널로 되돌리지 말 것.
    func engineUniform(time: Float, texRes: [SIMD4<Float>], texWrap: [Float] = [], texFilter: [Float] = [],
                       layerTint: SIMD4<Float> = SIMD4(1, 1, 1, 1),
                       targetRes: SIMD4<Float>,
                       mvp: simd_float4x4? = nil) -> [Float] {
        var e = [Float](repeating: 0, count: 16 + 8 + 32 + 8 + 8 + 4 + 4)
        let m = mvp ?? simd_float4x4(1)
        e[0] = m.columns.0.x; e[1] = m.columns.0.y; e[2] = m.columns.0.z; e[3] = m.columns.0.w
        e[4] = m.columns.1.x; e[5] = m.columns.1.y; e[6] = m.columns.1.z; e[7] = m.columns.1.w
        e[8] = m.columns.2.x; e[9] = m.columns.2.y; e[10] = m.columns.2.z; e[11] = m.columns.2.w
        e[12] = m.columns.3.x; e[13] = m.columns.3.y; e[14] = m.columns.3.z; e[15] = m.columns.3.w
        e[16] = time; e[17] = pointerUV.x; e[18] = pointerUV.y  // timeAndPad = (time, pointerX, pointerY, dt)
        e[19] = frameDT                                          // g_Frametime
        e[20] = pointerUVLast.x; e[21] = pointerUVLast.y         // g_PointerPositionLast
        e[22] = pointerDown ? 1 : 0                              // g_PointerState.z (클릭 힘) — pad 슬롯 재사용
        for n in 0..<8 {
            let r = n < texRes.count ? texRes[n] : SIMD4<Float>(1, 1, 1, 1)
            let o = 24 + n * 4
            e[o] = r.x; e[o + 1] = r.y; e[o + 2] = r.z; e[o + 3] = r.w
        }
        for n in 0..<8 where n < texWrap.count { e[56 + n] = texWrap[n] }
        for n in 0..<8 where n < texFilter.count { e[64 + n] = texFilter[n] }  // 감사 V07: texWrap 직후
        e[72] = layerTint.x; e[73] = layerTint.y; e[74] = layerTint.z; e[75] = layerTint.w
        e[76] = targetRes.x; e[77] = targetRes.y; e[78] = targetRes.z; e[79] = targetRes.w  // X-⑤
        return e
    }

    func runtimeTexRes(for pass: TranslatedPass, src: MTLTexture, fboTex: [MTLTexture]) -> [SIMD4<Float>] {
        var texRes = pass.texRes
        func set(_ slot: Int, _ tex: MTLTexture) {
            guard slot >= 0, slot < 8 else { return }
            let w = Float(max(1, tex.width)), h = Float(max(1, tex.height))
            texRes[slot] = SIMD4(w, h, w, h)
        }
        for (slot, source) in pass.binds {
            if source == -1 { set(slot, src) }
            else if source >= 0, source < fboTex.count { set(slot, fboTex[source]) }
        }
        for (slot, tex) in pass.aux { set(slot, tex) }
        return texRes
    }

    /// 파티클 스냅샷 → 인터리브드 버텍스(정점당 8 float: ndc.xy, uv, rgba).
    /// sprite = 빌보드 쿼드. rope/ropeTrail = 위치 히스토리 폴리라인을 두께 있는 리본(삼각 스트립).
    /// spriteTrail = F790: 속도 방향 신장 쿼드(히스토리 리본 아님 — WE 공식 문서).
    func particleVertices(_ snapshot: [Particle], _ sys: GPUParticleSystem) -> [Float] {
        var verts: [Float] = []
        verts.reserveCapacity(snapshot.count * (sys.isTrail ? 200 : 48))
        func toNDC(_ x: Float, _ y: Float) -> (Float, Float) { let p = sceneToNDC(x, y); return (p.x, p.y) }
        func appendQuad(_ p: Particle, stretch: Float = 1, angleOverride: Float? = nil) {
            let wx = sys.origin.x + sys.scale.x * p.pos.x
            // W1-yaxis: 파티클 sim 로컬은 y-up(눈/비 하강=음의 y). 씬 픽셀도 이제 y-up 이라 부호
            // 일치(종전엔 씬을 y-down 으로 오구현해 `−` 로 상쇄) — 위치·속도(아래 wvy) 동일 부호.
            let wy = sys.origin.y + sys.scale.y * p.pos.y
            // 오브젝트 scale 은 **위치·이미터 기하에만** 곱한다. 스프라이트 크기에는 안 곱한다.
            //
            // 근거 ①(WE 평문 셰이더, 1차): `common_particles.h:54-58` 의 ComputeParticlePosition 은
            // 쿼드를 `positionAndSize.w`(=size) 로만 전개하고, 그 공간에 `g_ModelViewProjectionMatrix`
            // 를 곱한다(genericparticle.vert:88-89). 즉 엔진은 오브젝트 변환을 **위치에 미리 구워**
            // 업로드하고 M 에는 스케일이 없다 — 크기는 배율을 안 탄다.
            // 근거 ②(WE 실기 A/B): 3465215190 obj 2432(scale 3.145)를 네 변종으로 재패킹해 대조하면
            // 위치×s·크기×1 이 정렬후 corr **0.987**(노이즈 바닥 0.997 = 구별불가)로 최고다.
            // 종전(위치×s·크기×s)은 0.812, 크기에만 곱하면 0.598 로 최악. 3299228616 Fireflies 는
            // WE 광점 등가 지름 13~53px 인데 종전 코드가 88~240px 을 냈다(4~8배).
            // 반례로 보이던 둘은 반례가 아니다 — `fairy_glow_large`(scale 50)는 부모가 0.01 이라
            // 월드 0.5 이고 3D 경로이며, `樱花`(scale 20)는 이미터가 캔버스 밖으로 나가 아무것도
            // 안 그린다(중화 캡처 차분 0픽셀).
            // ⚠️ 3D 경로(SceneRenderer3D.swift:2102 colScale)는 **미측정이다.** 같이 고치지 마라.
            let sizePx = p.size
            // 스프라이트시트(TEXS): mapsequence 는 스폰 확정 시퀀스, 아니면 age/frametime gif 애니.
            // UV = 프레임 서브렉트의 4코너(TL,TR,BR,BL). 회전 프레임이면 코너 배정을 rotationQuarters 만큼
            // 회전(비회전 q=0 은 종전과 byte-identical — 코퍼스 무회귀).
            var uv: [(Float, Float)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
            var ratio = sys.texRatio
            if !sys.frames.isEmpty {
                let fc = sys.frames.count
                let idx: Int
                if p.frame >= 0 {
                    idx = sheetFrameIndex(sequence: p.frame, frameCount: fc, mirror: sys.mapSeqMirror)
                } else {
                    // F740(S-22): def.animationmode=sequence/sequencemultiplier 소비(그 외 frametime 폴터).
                    idx = Self.particleSheetFrameIndex(age: p.age, lifetime: p.lifetime,
                                                       frameTime: sys.frames[0].time, frameCount: fc,
                                                       mode: sys.def.animationMode,
                                                       seqMul: sys.def.sequenceMultiplier)
                }
                let fr = sys.frames[max(0, min(fc - 1, idx))]
                let tw = Float(max(1, sys.texture.width)), th = Float(max(1, sys.texture.height))
                let u0 = fr.atlasX / tw, v0 = fr.atlasY / th
                let u1 = min(1, (fr.atlasX + fr.atlasWidth) / tw), v1 = min(1, (fr.atlasY + fr.atlasHeight) / th)
                let corners = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
                let q = fr.rotationQuarters
                uv = (0..<4).map { corners[($0 + q) % 4] }
                // 똑바로 세운 스프라이트 종횡비(90/270°는 축 스왑).
                let upW = q % 2 == 0 ? fr.atlasWidth : fr.atlasHeight
                let upH = q % 2 == 0 ? fr.atlasHeight : fr.atlasWidth
                ratio = upH / max(1, upW)
            }
            let hw = sizePx * 0.5 * stretch, hh = sizePx * ratio * 0.5  // F790: stretch = local X 신장
            // 3축 회전(WE `common_particles.h` ComputeParticleTangents) 후 화면에 **정사영**한다.
            //
            // 2D 경로에는 z 좌표가 없어 out-of-plane 회전을 못 담는다고 보기 쉽지만, 화면
            // 기저(right=(1,0,0), up=(0,1,0))에 대해 접선을 구하고 **xy 성분만 취하면** 그게
            // 정사영이다 — x·y 회전은 접선의 화면 성분을 단축시켜 "기울어 납작해짐" 으로
            // 나타난다(z 성분은 직교 투영이라 버린다). 원근 단축까지는 아니지만 저작 의도의
            // 주된 효과인 foreshortening 이 살아난다.
            //
            // angleOverride(속도 정렬 등)가 있으면 종전대로 그 각만 쓴다 — 그 경로는 롤을
            // 외부에서 정하는 규약이라 3축을 얹으면 이중 적용이 된다.
            let ca: Float, sa: Float, upX: Float, upY: Float
            if let ang = angleOverride {
                ca = cos(ang); sa = sin(ang); upX = -sa; upY = ca
            } else {
                let t = SceneRenderer.particleTangents(rotation: p.rotation,
                                                       right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0))
                ca = t.right.x; sa = t.right.y     // right 의 화면 성분
                upX = t.up.x;   upY = t.up.y       // up 의 화면 성분
            }
            func ndc(_ lx: Float, _ ly: Float) -> (Float, Float) {
                return toNDC(wx + lx * ca + ly * upX, wy + lx * sa + ly * upY)
            }
            // W1-yaxis: quadVertices 와 동형 — uv(0,0) 이 화면 위쪽에 오도록 로컬 hh 코너 재페어링
            // (스프라이트시트 프레임처럼 비대칭 콘텐츠가 있는 파티클의 상하반전 방지).
            let tl = ndc(-hw, hh), tr = ndc(hw, hh), br = ndc(hw, -hh), bl = ndc(-hw, -hh)
            let r = p.color.x, g = p.color.y, b = p.color.z, al = p.alpha
            func v(_ pt: (Float, Float), _ u: (Float, Float)) {
                verts.append(contentsOf: [pt.0, pt.1, u.0, u.1, r, g, b, al])
            }
            v(tl, uv[0]); v(tr, uv[1]); v(br, uv[2])
            v(tl, uv[0]); v(br, uv[2]); v(bl, uv[3])
        }
        // F790: WE spritetrail — 쿼드 장축(local X = u 축)을 속도 방향에 두고 size×신장 배로
        // 그린다(히스토리 리본 아님). 신장 = speed×length 를 [minlength, maxlength] 클램프(공식
        // 문서 — RendererKind.spriteTrailStretch). 정지/미세 속도는 방향 부정 → 무신장 폴터.
        func appendSpriteTrailQuad(_ p: Particle) {
            let speed = sqrtf(p.vel.x * p.vel.x + p.vel.y * p.vel.y)  // 씬 로컬(Y-up) — 신장 산정
            guard speed > 0.5 else { appendQuad(p); return }  // ponytail: 방향 부정 임계 0.5px/s
            // W1-yaxis: 씬 픽셀도 y-up 이라 위치(wy)와 동일 부호(종전 월드 y-down 상쇄용 `−` 제거).
            let wvx = sys.scale.x * p.vel.x, wvy = sys.scale.y * p.vel.y
            appendQuad(p, stretch: sys.def.renderer.spriteTrailStretch(speed: speed),
                       angleOverride: atan2(wvy, wvx))
        }
        for p in snapshot {
            if case .spriteTrail = sys.def.renderer {
                appendSpriteTrailQuad(p)
            } else if sys.isTrail {
                // 리본이 붕괴(정지 rope 등)면 false → 쿼드 폴백. inout verts 를 클로저와 동시
                // 접근하지 않도록 순차 호출(Swift 배타적 접근 위반 방지).
                if !appendRibbon(p, sys, into: &verts) { appendQuad(p) }
            } else {
                appendQuad(p)
            }
        }
        return verts
    }

    /// 파티클 위치 히스토리(oldest→newest) → 두께 있는 리본. 폭 = size_px, 텍스처 u 는 길이 방향,
    /// v 는 가로. 알파는 tail(oldest)=0 → head(newest)=full 로 코멧 페이드. 세그먼트 접선의 수직으로
    /// ±half-width 오프셋해 삼각 스트립을 만든다.
    /// 붕괴(정지 rope, mouse-follow 헤드리스) 시 false 반환 → 호출자가 쿼드 폴백(NaN/블랭크 방지).
    func appendRibbon(_ p: Particle, _ sys: GPUParticleSystem, into verts: inout [Float]) -> Bool {
        func toNDC(_ x: Float, _ y: Float) -> (Float, Float) { let p = sceneToNDC(x, y); return (p.x, p.y) }
        let h = p.history
        // 월드 px 로 변환.
        var pts: [(Float, Float)] = []
        pts.reserveCapacity(h.count)
        // W1-yaxis: appendQuad 의 wy 와 동일 부호(씬 픽셀 y-up).
        for q in h { pts.append((sys.origin.x + sys.scale.x * q.x, sys.origin.y + sys.scale.y * q.y)) }
        // 유효 스팬 판정: bbox 대각선이 1px 미만이면 붕괴 → 쿼드.
        guard pts.count >= 2 else { return false }
        var minX = pts[0].0, maxX = pts[0].0, minY = pts[0].1, maxY = pts[0].1
        for pt in pts { minX = min(minX, pt.0); maxX = max(maxX, pt.0); minY = min(minY, pt.1); maxY = max(maxY, pt.1) }
        if (maxX - minX) + (maxY - minY) < 1 { return false }

        let n = pts.count
        // **반폭 = size 그대로다.** WE `genericropeparticle.geom:79-80` 이
        // `trailRightStart = normalize(cross(eye, CP)) * sizeStart` 로 중심에서 ±size 만큼
        // 벌린다 — 즉 저작 size 는 리본의 **반폭**이고 전체폭은 2×size 다.
        // 종전엔 쿼드 공식(`(uv.x-0.5)*size`, 전체폭=size)을 그대로 재사용해 `size*0.5` 였고,
        // 그래서 모든 리본이 **정확히 절반 폭**으로 그려졌다. 쿼드 쪽(appendQuad)은 맞다 —
        // 두 렌더러가 같은 CPU size 를 받지만 해석 규약이 다르다.
        let hw = max(0.5, p.size)  // 리본 반폭(px) — scale 미적용(위 appendQuad 근거와 동일)
        let r = p.color.x, g = p.color.y, b = p.color.z
        // 접선(중앙차분, 끝은 편차). 0-길이는 직전 유효 접선 계승(NaN 방지 — normalizeSafe 미러).
        var lastT: (Float, Float) = (1, 0)
        func tangent(_ i: Int) -> (Float, Float) {
            let a = pts[max(0, i - 1)], c = pts[min(n - 1, i + 1)]
            let dx = c.0 - a.0, dy = c.1 - a.1
            let len = sqrtf(dx * dx + dy * dy)
            if len > 1e-4 { lastT = (dx / len, dy / len) }
            return lastT
        }
        // 각 히스토리 포인트의 좌/우 엣지 정점(ndc, u, alpha).
        var edges: [(a: (Float, Float), bEdge: (Float, Float), u: Float, alpha: Float)] = []
        edges.reserveCapacity(n)
        for i in 0..<n {
            let t = tangent(i)
            let nx = -t.1 * hw, ny = t.0 * hw            // 수직 오프셋(px)
            let A = toNDC(pts[i].0 + nx, pts[i].1 + ny)
            let B = toNDC(pts[i].0 - nx, pts[i].1 - ny)
            let u = Float(i) / Float(n - 1)
            // **위치 기반 페이드를 얹지 않는다.** WE 의 코멧 페이드(꼬리→머리 그라디언트)는
            // `TRAILSCROLLALPHA`/`TRAILFADEALPHA` 콤보 뒤에 있고, 기본 `TRAILRENDERER` 경로는
            // 각 히스토리 포인트 자신의 색·알파(`v_Color`)를 그대로 쓴다
            // (`genericropeparticle.geom` — 콤보 밖에서 alpha 를 u 로 곱하는 코드가 없다).
            // 종전엔 `p.alpha * u` 로 항상 페이드를 강제해, 저작이 균일 알파를 의도한 리본도
            // 꼬리가 투명해졌다. 콤보 지원은 별개 작업이라 여기서는 강제만 걷는다.
            edges.append((A, B, u, p.alpha))
        }
        func push(_ pt: (Float, Float), _ u: Float, _ vv: Float, _ al: Float) {
            verts.append(contentsOf: [pt.0, pt.1, u, vv, r, g, b, al])
        }
        // 스프라이트시트: 선택 프레임 렉트로 u(가로)/v(길이) 재매핑(discharge rope 등 —
        // 미적용 시 시트 전 프레임이 리본에 통째로 늘어난다).
        // 축 이름은 WE 규약 기준이다 — fu*=폭 방향, fv*=길이 방향(아래 삼각 조립 주석 참조).
        var fu0: Float = 0, fu1: Float = 1, fv0: Float = 0, fv1: Float = 1
        if !sys.frames.isEmpty {
            let fc = sys.frames.count
            let idx = p.frame >= 0
                ? sheetFrameIndex(sequence: p.frame, frameCount: fc, mirror: sys.mapSeqMirror)
                : Self.particleSheetFrameIndex(age: p.age, lifetime: p.lifetime,
                                               frameTime: sys.frames[0].time, frameCount: fc,
                                               mode: sys.def.animationMode,
                                               seqMul: sys.def.sequenceMultiplier)  // F740(S-22): 쿼드 경로와 동일 폴터
            let fr = sys.frames[max(0, min(fc - 1, idx))]
            let tw = Float(max(1, sys.texture.width)), th = Float(max(1, sys.texture.height))
            // 서브렉트는 atlas*(회전 프레임의 실제 extent). ponytail: 리본은 rotationQuarters 미반영 —
            // spritetrail/rope 가 회전 아틀라스를 쓰는 실물이 코퍼스에 없어 보류(발견 시 코너 회전 이식).
            fu0 = fr.atlasX / tw; fu1 = min(1, (fr.atlasX + fr.atlasWidth) / tw)
            fv0 = fr.atlasY / th; fv1 = min(1, (fr.atlasY + fr.atlasHeight) / th)
        }
        for i in 0..<(n - 1) {
            let e0 = edges[i], e1 = edges[i + 1]
            // 쿼드 (A0,B0,B1,A1) → 삼각 2개.
            //
            // **u 가 가로(폭), v 가 길이다** — WE `genericropeparticle.geom:110·123·146·159` 가
            // `v_TexCoord.xy = vec2(0 또는 1, uvMin..uvMax)` 로 낸다. 즉 x 성분이 좌우 엣지
            // (0/1)이고 y 성분이 리본을 따라 흐른다. 종전엔 정확히 전치돼 있어서(u=길이,
            // v=가로) 리본 텍스처가 90° 돌아간 채 늘어났다.
            func V(_ t: Float) -> Float { fv0 + (fv1 - fv0) * t }
            push(e0.a, fu0, V(e0.u), e0.alpha); push(e0.bEdge, fu1, V(e0.u), e0.alpha); push(e1.bEdge, fu1, V(e1.u), e1.alpha)
            push(e0.a, fu0, V(e0.u), e0.alpha); push(e1.bEdge, fu1, V(e1.u), e1.alpha); push(e1.a, fu0, V(e1.u), e1.alpha)
        }
        return true
    }

    /// 프레임 시작: 풀 체크아웃 리셋 + **직전 프레임에 사용되지 않은 항목 evict**(크기키/초과분).
    /// 화면 리사이즈/캡처 크기 변경 후 이전 크기의 오프스크린이 무기한 잔존하는 누수 방지.
    /// 사용 중 크기(레이어/FBO/화면)는 매 프레임 체크아웃되므로 유지되고, 배열 prefix 트림이라
    /// 반환 순서도 보존 — 프레임 간 지속 FBO(motionblur copy 누적)의 재사용 텍스처가 바뀌지 않는다.
    func beginFramePool() {
        for (key, arr) in texturePool {
            let used = poolCheckout[key] ?? 0
            if used == 0 { texturePool.removeValue(forKey: key) }
            else if used < arr.count { texturePool[key] = Array(arr.prefix(used)) }
        }
        poolCheckout.removeAll(keepingCapacity: true)
    }

    /// S5-2: `unique:true` FBO(프레임 간 지속 텍스처)의 **렌더러 전역** 상한.
    ///
    /// 왜 상한이 필요한가: 지속 텍스처는 이펙트 인스턴스마다 따로 잡히는데 아무도 세지 않았다.
    /// **이미 존재하는 클램프만으로** 계산한 한 인스턴스의 최악은 32 GiB 다 —
    /// fbo 개수 상한 64(`EffectManifest.swift` `maxFBOs`) × 치수 클램프 8192²(같은 파일
    /// `clampedFixed`) × 이 렌더러가 만들 수 있는 최대 8 B/px = 64 × 512 MiB. 이펙트 인스턴스
    /// 개수에는 상한이 없으므로 씬 전체로는 그 배수다(코퍼스 실측 평균 39.6 인스턴스/씬).
    ///
    /// 1 GiB 인 근거(동봉 자산 실측): `unique` fbo 를 선언하는 스톡 이펙트는 46종 중 **2종뿐**이고
    /// (motionblur 1개 · fluidsimulation 8개), 5K HDR(5120×2880) 기준 인스턴스당 각각
    /// 112.5 MiB · 57.25 MiB, 4K LDR 이면 31.6 MiB · 16.8 MiB 다. 동봉 프리뷰 씬은 이펙트
    /// 인스턴스가 1개라 최악이 112.5 MiB — **9배 여유**이므로 동봉 코퍼스는 이 분기에 닿지 않는다.
    static let uniqueFBOByteBudget = 1 << 30   // 1 GiB

    /// S5-2: 텍스처 1장의 바이트 수. `makeOffscreenFormatted` 는 `mipmapped: false` 라 레벨 0 뿐이다.
    /// 표에 없는 포맷은 **8**(이 렌더러의 `metalFormat` 이 만들 수 있는 최대 픽셀 크기)로 친다 —
    /// 모르는 쪽을 과소평가하면 예산이 뚫리므로 항상 비싼 쪽으로 센다.
    static func uniqueFBOBytes(width: Int, height: Int, format: MTLPixelFormat) -> Int {
        let bytesPerPixel: Int
        switch format {
        case .r8Unorm:                                  bytesPerPixel = 1
        case .rg8Unorm, .r16Float:                      bytesPerPixel = 2
        case .rgba8Unorm, .rg16Float, .rgb10a2Unorm:    bytesPerPixel = 4
        case .rgba16Float, .rgba16Unorm, .rgba16Snorm:  bytesPerPixel = 8
        default:                                        bytesPerPixel = 8
        }
        return max(1, width) * max(1, height) * bytesPerPixel
    }

    static func uniqueFBOBytes(_ texture: MTLTexture) -> Int {
        uniqueFBOBytes(width: texture.width, height: texture.height, format: texture.pixelFormat)
    }

    /// X-⑧: `format` 은 bgra/HDR 승격 규칙을 **우회하는 명시 포맷**이다(effect.json `fbos[].format`).
    /// nil 이면 종전 동작 그대로 — bgra 플래그와 hdrActive 로 결정한다. 풀 키에 포맷을 넣어야
    /// r16f 요청이 이전에 만들어 둔 rgba8 텍스처를 받아가지 않는다.
    func pooledOffscreen(_ w: Int, _ h: Int, _ device: MTLDevice, bgra: Bool = false,
                         format: MTLPixelFormat? = nil) -> MTLTexture? {
        // A2 HDR: bgra 요청(acc·합성 스냅샷)은 HDR 씬에서 float(rgba16Float)로 승격 — runFrameBufferLayer/
        // runBlendModeLayer 본문 무수정으로 스냅샷이 float acc 와 동일 포맷(blit copy 정합)이 되게 한다.
        let hdrBGRA = bgra && hdrActive
        let key: String
        if let f = format {
            key = "f\(f.rawValue)_\(max(w,1))x\(max(h,1))"
        } else {
            key = "\(hdrBGRA ? "h" : (bgra ? "b" : ""))\(max(w,1))x\(max(h,1))"
        }
        let idx = poolCheckout[key, default: 0]
        if idx < (texturePool[key]?.count ?? 0) {
            poolCheckout[key] = idx + 1
            return texturePool[key]![idx]
        }
        let made: MTLTexture?
        if let f = format {
            made = makeOffscreenFormatted(w, h, device, format: f)
        } else {
            made = hdrBGRA ? makeOffscreenHDR(w, h, device)
                           : (bgra ? makeOffscreenBGRA(w, h, device) : makeOffscreen(w, h, device))
        }
        guard let t = made else { return nil }
        texturePool[key, default: []].append(t)
        poolCheckout[key] = idx + 1
        return t
    }

    /// 컴포지션(_rt_) 레이어 실행: 현재 encoder 를 닫고, acc 스냅샷(blit — 진행 중 타깃은 샘플 불가)에
    /// 레이어의 효과 체인을 적용한 뒤, 새 encoder(.load)로 레이어 지오메트리에 결과를 그린다.
    /// 반환된 encoder 로 나머지 drawPlan 을 계속한다. 실패 시 기존 흐름 유지 위해 새 encoder 만 연다.
    /// P⑤: colorBlendMode 도 함께 저작된 레이어(코퍼스 13씬: _rt_ + colorBlendMode 동시 보유)는 종전
    /// encodeDrawPlan 매치 순서(isFrameBuffer 가 colorBlendMode 보다 먼저 매치)때문에 f_compose 로만
    /// 그려져 저작 블렌드 모드가 통째로 무시됐다(주석 명시 우선순위 lit>colorBlendMode>framebuffer 위반).
    /// 매치 순서 자체를 바꾸면 colorBlendMode 경로(runBlendModeLayer)가 buildDisplayTextures 의 원본
    /// 텍스처(효과 체인 스킵 — isFrameBuffer 는 사전계산 불가, :1485)를 쓰게 돼 이펙트 체인 결과를
    /// 통째로 잃는다. 대신 이 함수 안에서 colorBlendMode 를 함께 반영: 효과 체인 실행 전 acc 스냅샷을
    /// blendSnapshot 으로 보존해 encodeLayer 에 넘기면(:1113 의 f_blend 분기가 :1119 compose 분기보다
    /// 우선) 이펙트 체인 결과(srcTex)는 그대로 유지한 채 저작 블렌드 모드가 적용된다.
    func runFrameBufferLayer(_ layer: GPULayer, acc: MTLTexture, cb: MTLCommandBuffer,
                                     ending enc: MTLRenderCommandEncoder, device: MTLDevice, time: Float,
                                     camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) -> MTLRenderCommandEncoder? {
        enc.endEncoding()
        var srcTex: MTLTexture? = nil
        var backdrop: MTLTexture? = nil
        if let snap = pooledOffscreen(acc.width, acc.height, device, bgra: true) {
            // B2-effects④: copyBackground(WE 컴포지션 레이어 "배경 복사") false 면 이 레이어 이펙트
            // 체인의 *입력*(snap = chain src)은 acc(기존 누적 화면)를 블릿하지 않고 투명으로 시작한다 —
            // 실물 확인(3629379075 "可调整组合层" blur, copybackground:false): Waple 이 이 플래그를 무시하고
            // 항상 acc 를 블릿·블러해 전체 화면이 풀프레임 워시로 덮였다. Waple 은 WE 와 달리 compose
            // 레이어별 자식 RT 가 없어 "자식 RT 대신 무(無)" 로 근사한다 — 이 근사는 입력을 재료로만
            // 쓰는 필터형 체인(블러 등)엔 타당하지만, 입력과 무관하게 색을 새로 "쓰는" 생성형 체인
            // (오디오바 등)에도 콘텐츠 손실이 없다는 보장은 아니다(코퍼스 블라스트 반경·근거는
            // BACKLOG.md B2-effects④ 항목 참고 — 자식 RT 부재를 정면돌파하지 않는 한 구조적 한계).
            //
            // `_rt_FullFrameBuffer` aux 슬롯(godrays/shine 의 COPYBG 콤보, F-X4)은 chain src 와 별개
            // 요청이다 — WE 실물 의미는 "이 시점까지의 씬 컬러" 이지 "이 레이어가 배경을 복사했는가"
            // 가 아니므로, copyBackground 값과 무관하게 항상 실제 acc 스냅샷을 바인드해야 한다(fullFrame).
            // 종전엔 이 둘을 같은 텍스처(snap)로 합쳐 써 copyBackground:false 컴포지션 레이어의
            // godrays/shine 이 aux 슬롯까지 투명해지는 회귀 위험이 있었다 — 별도 블릿으로 분리.
            var fullFrame: MTLTexture = snap
            if layer.copyBackground {
                guard let blit = cb.makeBlitCommandEncoder() else { return nil }
                blit.copy(from: acc, to: snap)
                blit.endEncoding()
            } else {
                // 풀 고갈(드문 경우)이면 fullFrame 은 snap(투명) 유지 — aux 슬롯만 무크래시 폴백,
                // chain src(투명 클리어)는 항상 그대로 진행.
                if let auxSnap = pooledOffscreen(acc.width, acc.height, device, bgra: true) {
                    guard let auxBlit = cb.makeBlitCommandEncoder() else { return nil }
                    auxBlit.copy(from: acc, to: auxSnap)
                    auxBlit.endEncoding()
                    fullFrame = auxSnap
                }
                let clearRPD = MTLRenderPassDescriptor()
                clearRPD.colorAttachments[0].texture = snap
                clearRPD.colorAttachments[0].loadAction = .clear
                clearRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                clearRPD.colorAttachments[0].storeAction = .store
                guard let clearEnc = cb.makeRenderCommandEncoder(descriptor: clearRPD) else { return nil }
                clearEnc.endEncoding()
            }
            backdrop = snap
            var current: MTLTexture = snap
            for eff in layer.effects {
                guard effectVisible(eff, time: time) else { continue }  // X-⑥: 꺼진 이펙트만 건너뜀
                guard let next = pooledOffscreen(acc.width, acc.height, device) else { break }
                // F532: 인코드 실패 시 미기록 next 대신 마지막 유효 텍스처 유지.
                guard applyEffect(eff, src: current, dst: next, time: time, cb: cb, fullFrameSnapshot: fullFrame) else { break }
                current = next
            }
            srcTex = current
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = acc
        rpd.colorAttachments[0].loadAction = .load
        guard let next = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        if let srcTex {
            // NOTE: acc 는 premultiplied 누적이라 스냅샷도 premult — straight 규약과의 미세 오차는
            // 불투명 배경(일반 씬)에선 없음(설계 §4). fit/fill 시 aspectScale 이중 적용 에지도 §3 참고.
            // time/device 전달 — 누락 시 기본값(0/nil)으로 _rt_ 레이어의 애니·프로퍼티 스크립트 동결.
            // P⑤: 효과 체인이 0패스(srcTex===backdrop)면 블렌드 소스=타깃 자기샘플이 되므로 blendSnapshot
            // 생략(무회귀 f_compose 폴백) — 효과 체인이 실제로 다른 텍스처를 만들었을 때만 블렌드 적용.
            let blendSnapshot: MTLTexture? = (layer.colorBlendMode != 0 && srcTex !== backdrop) ? backdrop : nil
            encodeLayer(layer, texture: srcTex, into: next, camOffset: &camOffset, aspectScale: &aspectScale,
                        time: time, device: device, blendSnapshot: blendSnapshot)
        }
        return next
    }

    /// P⑦: colorBlendMode 레이어 전용 acc 스냅샷 — pooledOffscreen(프레임 내 단조 체크아웃, :239-253)을
    /// 쓰면 블렌드 레이어 수(N)만큼 드로어블 크기 텍스처가 동시 상주한다(코퍼스 2955378002 실측 366개,
    /// 4K 기준 ≈12GB). 커맨드 버퍼 내 인코더는 제출 순서대로 실행되므로, 레이어 직전에 acc 를 다시
    /// blit 하는 이 패턴에서는 스냅샷 1장을 순차 재사용해도 매 레이어가 항상 "그 시점까지의" acc 를
    /// 그대로 샘플한다(내용은 종전과 비트동일 — 텍스처 아이덴티티만 바뀜). 크기/포맷(acc 와 동형,
    /// P① hdrActive 에 따라 동적)이 바뀌면만 재할당.
    func blendModeSnapshotSlot(_ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let fmt: MTLPixelFormat = hdrActive ? .rgba16Float : .bgra8Unorm
        if let t = blendModeSnapshotTexture, t.width == w, t.height == h, t.pixelFormat == fmt {
            return t
        }
        let t = hdrActive ? makeOffscreenHDR(w, h, device) : makeOffscreenBGRA(w, h, device)
        blendModeSnapshotTexture = t
        return t
    }

    /// colorBlendMode 레이어: acc 스냅샷(dst) 확보 → f_blend 로 레이어 쿼드 드로우 → 새 인코더 반환.
    /// runFrameBufferLayer 와 같은 인코더 분할 패턴(효과 체인은 displayTextures 에서 이미 처리 — 미실행).
    func runBlendModeLayer(_ layer: GPULayer, texture: MTLTexture, acc: MTLTexture, cb: MTLCommandBuffer,
                           ending enc: MTLRenderCommandEncoder, device: MTLDevice, time: Float,
                           camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) -> MTLRenderCommandEncoder? {
        enc.endEncoding()
        var snapshot: MTLTexture? = nil
        if let snap = blendModeSnapshotSlot(acc.width, acc.height, device),
           let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: acc, to: snap)
            blit.endEncoding()
            snapshot = snap
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = acc
        rpd.colorAttachments[0].loadAction = .load
        guard let next = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        encodeLayer(layer, texture: texture, into: next, camOffset: &camOffset, aspectScale: &aspectScale,
                    time: time, device: device, blendSnapshot: snapshot)
        return next
    }

    /// C⑥: colorBlendMode 텍스트 — runBlendModeLayer 와 동일 인코더 분할 패턴(이미지 레이어 경로 재사용).
    /// acc 스냅샷(dst) 확보 → f_blend 로 텍스트 쿼드 드로우 → 새 인코더 반환.
    func runBlendModeText(_ t: GPUText, texture: MTLTexture?, acc: MTLTexture, cb: MTLCommandBuffer,
                          ending enc: MTLRenderCommandEncoder, device: MTLDevice, time: Float,
                          camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) -> MTLRenderCommandEncoder? {
        enc.endEncoding()
        var snapshot: MTLTexture? = nil
        if let snap = pooledOffscreen(acc.width, acc.height, device, bgra: true),
           let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: acc, to: snap)
            blit.endEncoding()
            snapshot = snap
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = acc
        rpd.colorAttachments[0].loadAction = .load
        guard let next = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        encodeText(t, into: next, camOffset: &camOffset, aspectScale: &aspectScale,
                  time: time, device: device, displayTexture: texture, blendSnapshot: snapshot)
        return next
    }

    /// H4: REFRACT 이미지 레이어 드로우(인코더 분할): 현재 enc 를 닫고 acc(씬 컬러)를 스냅샷(blit — 진행 중
    /// 타깃은 샘플 불가, runFrameBufferLayer/runBlendModeLayer 와 동일 패턴)한 뒤, .load 로 재개한 인코더에
    /// f_refract 로 레이어를 그린다(노멀 오프셋으로 스냅샷 재샘플·곱). 스냅샷/파이프라인 확보 실패 시
    /// identity 레이어 폴터(무크래시). 재개 실패만 nil(호출자는 추가 인코딩 없이 commit).
    func runRefractLayer(_ layer: GPULayer, texture: MTLTexture, acc: MTLTexture, cb: MTLCommandBuffer,
                         ending enc: MTLRenderCommandEncoder, device: MTLDevice, time: Float,
                         camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) -> MTLRenderCommandEncoder? {
        enc.endEncoding()
        var snapshot: MTLTexture? = nil
        if let snap = pooledOffscreen(acc.width, acc.height, device, bgra: true),
           let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: acc, to: snap)
            blit.endEncoding()
            snapshot = snap
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = acc
        rpd.colorAttachments[0].loadAction = .load
        guard let next = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        if let snap = snapshot, let pipe = refractLayerPipeline {
            encodeRefractLayer(layer, texture: texture, framebuffer: snap, pipe: pipe, into: next,
                               device: device, camOffset: &camOffset, aspectScale: &aspectScale)
        } else {
            encodeLayer(layer, texture: texture, into: next, camOffset: &camOffset, aspectScale: &aspectScale,
                        time: time, device: device)  // identity 폴터
        }
        return next
    }

    /// REFRACT 레이어 1개 드로우. encodeLayer 와 동형이나 노멀맵(1)·씬 스냅샷(2)·refract 유니폼을 바인딩하고
    /// f_refract 파이프라인 사용. 정점은 layer.vertexBuffer(quadVertices 4-float) — 노멀은 알베도와 같은 uv 로 샘플.
    func encodeRefractLayer(_ layer: GPULayer, texture: MTLTexture, framebuffer: MTLTexture,
                            pipe: MTLRenderPipelineState, into enc: MTLRenderCommandEncoder,
                            device: MTLDevice, camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) {
        guard let normal = layer.refract.normalTexture else { return }
        enc.setRenderPipelineState(pipe)
        enc.setVertexBuffer(layer.vertexBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        var depth = layer.parallaxDepth
        enc.setVertexBytes(&depth, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        enc.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        var shake = frameShakeOffset
        enc.setVertexBytes(&shake, length: MemoryLayout<SIMD2<Float>>.stride, index: 4)
        enc.setFragmentTexture(texture, index: 0)         // 알베도(g_Texture0)
        enc.setFragmentTexture(normal, index: 1)          // 노멀맵(g_Texture1)
        enc.setFragmentTexture(framebuffer, index: 2)     // 씬 컬러 스냅샷
        var tint = layer.tint
        var params = SIMD4<Float>(layer.refract.amount, layer.refract.normalRG88 ? 1 : 0, 0, 0)
        enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// W1-yaxis: 씬 픽셀 좌표(좌하단 원점, y-up — WE 전 씬 규약, RenderDoc 골든 3397690043 실측
    /// 확정) → NDC(-1..1, y-up). px→NDC 변환의 단일 정의 — 파티클/리본/쿼드/퍼펫/텍스트 경로가 공유
    /// (동일식 5중 중복 제거, 2026-07-04). 종전엔 y-down(`1 − y/H·2`)으로 오구현 — 부호만 반전하면
    /// 위치는 고치지만 각 호출부의 로컬 지오메트리(quadVertices 코너 uv 페어링, alignedCenter
    /// top/bottom, ortho 모델 y-basis 등)가 "콘텐츠 상하반전"을 새로 유발하므로 해당 파생 지점은
    /// 각자 별도 보정(이 함수 자체는 이 한 줄만 변경 — 회전은 자동 정합, 켤레 켤레 상쇄).
    @inline(__always)
    static func pxToNDC(_ x: Float, _ y: Float, projW: Float, projH: Float) -> SIMD2<Float> {
        SIMD2(x / projW * 2 - 1, y / projH * 2 - 1)
    }

    /// pxToNDC 의 인스턴스 프로젝션 크기(projW/projH) 버전.
    @inline(__always)
    func sceneToNDC(_ x: Float, _ y: Float) -> SIMD2<Float> {
        Self.pxToNDC(x, y, projW: projW, projH: projH)
    }

    /// alignment(9점 앵커) → origin 을 앵커점으로 삼는 유효 중심. WE IImageLayer.alignment:
    ///   left/right → 앵커가 좌/우변(사각형은 반대쪽으로 뻗음), top/bottom → 상/하변, center=중심.
    /// effectiveCenter = origin − rotate(alignX,alignY) 이므로 기존 코너식(rotate(local)+center)·
    /// litRect 셰이더 재구성(center 가정)이 수식 변경 없이 그대로 앵커 정렬을 재현한다(회전 선형성).
    /// W1-yaxis: y-up 씬픽셀(위=y큼): top=+hh·bottom=−hh(종전 y-down 부호의 반대) · left=−hw·right=+hw
    /// (x 는 y-flip 과 무관해 불변). center/미지정=이동 0(무회귀).
    @inline(__always)
    static func alignedCenter(origin: Vec2, alignment: String, hw: Float, hh: Float, ca: Float, sa: Float) -> Vec2 {
        let ax: Float = alignment.contains("left") ? -hw : (alignment.contains("right") ? hw : 0)
        let ay: Float = alignment.contains("top") ? hh : (alignment.contains("bottom") ? -hh : 0)
        if ax == 0 && ay == 0 { return origin }  // center/미지정: 중심 그대로(무회귀)
        return Vec2(x: origin.x - (ax * ca - ay * sa), y: origin.y - (ax * sa + ay * ca))
    }

    /// 씬 픽셀 좌표(좌하단 원점, W1-yaxis: y-up 확정) → NDC.
    static func quadVertices(layer: SceneLayer, projW: Float, projH: Float) -> [SIMD4<Float>] {
        quadVertices(origin: layer.origin, size: layer.size, scale: layer.scale, angleZ: layer.angleZ,
                     alignment: layer.alignment, projW: projW, projH: projH,
                     perspective: layer.perspective, perspectiveFov: 95)
    }

    /// 명시 파라미터 변형 — 프로퍼티 애니메이션의 per-frame 재계산용.
    static func quadVertices(origin: Vec2, size: Vec2, scale: Vec2, angleZ: Float, alignment: String,
                              projW: Float, projH: Float, perspective: Bool = false,
                              perspectiveFov: Float = 95) -> [SIMD4<Float>] {
        let hw = size.x * scale.x * 0.5
        let hh = size.y * scale.y * 0.5
        let a = angleZ   // A1: scene.json angles 는 이미 라디안(코퍼스 전부 ≤π 확정) — 종전 *.pi/180 은 라디안을 도로 오인해 회전 57× 축소
        let ca = cos(a), sa = sin(a)
        let c = Self.alignedCenter(origin: origin, alignment: alignment, hw: hw, hh: hh, ca: ca, sa: sa)
        func corner(_ lx: Float, _ ly: Float) -> SIMD2<Float> {
            let rx = lx * ca - ly * sa, ry = lx * sa + ly * ca
            return SIMD2<Float>(c.x + rx, c.y + ry)
        }
        func ndc(_ p: SIMD2<Float>) -> SIMD2<Float> { Self.pxToNDC(p.x, p.y, projW: projW, projH: projH) }
        // W1-yaxis: pxToNDC 가 이제 y-up(큰 scene-y → 화면 위)이므로, uv(0,0)=텍스처 상단이 화면
        // 위쪽에 오려면 로컬 ly=+hh(큰 y) 코너를 "tl/tr" 로 써야 한다(종전 −hh 는 이제 시각적 하단).
        // hw/x 축은 y-flip 과 무관해 그대로 — 코너 4점의 SET 은 불변(재라벨링만, 회전/와인딩 무영향).
        let tl = ndc(corner(-hw, hh)), tr = ndc(corner(hw, hh))
        let br = ndc(corner(hw, -hh)), bl = ndc(corner(-hw, -hh))
        // M4: perspective=true 레이어 원근 투영 근사 — FOV 기반 상단 축소(코퍼스 x/y angles=0 이라
        // 정사영과 출력 동일, 후속 진짜 원근 구현 시 제거).
        if perspective {
            let fovScale = tan(perspectiveFov * 0.5 * Float.pi / 180)
            func persp(_ p: SIMD2<Float>, _ isTop: Bool) -> SIMD2<Float> {
                let factor: Float = isTop ? 1.0 / (1.0 + fovScale * 0.1) : 1.0
                return SIMD2(p.x * factor, p.y)
            }
            let ptl = persp(tl, true), ptr = persp(tr, true)
            return [
                SIMD4<Float>(ptl.x, ptl.y, 0, 0), SIMD4<Float>(ptr.x, ptr.y, 1, 0), SIMD4<Float>(br.x, br.y, 1, 1),
                SIMD4<Float>(ptl.x, ptl.y, 0, 0), SIMD4<Float>(br.x, br.y, 1, 1), SIMD4<Float>(bl.x, bl.y, 0, 1),
            ]
        }
        // uv: TL(0,0) TR(1,0) BR(1,1) BL(0,1)
        return [
            SIMD4<Float>(tl.x, tl.y, 0, 0), SIMD4<Float>(tr.x, tr.y, 1, 0), SIMD4<Float>(br.x, br.y, 1, 1),
            SIMD4<Float>(tl.x, tl.y, 0, 0), SIMD4<Float>(br.x, br.y, 1, 1), SIMD4<Float>(bl.x, bl.y, 0, 1),
        ]
    }

    /// H1: 커스텀 셰이더 레이어의 로컬 쿼드(-1…1) → NDC 변환 행렬.
    /// quadVertices + v_main 의 기존 동작을 행렬로 재현.
    func layerTransformMatrix(origin: Vec2, size: Vec2, scale: Vec2, angleZ: Float, alignment: String,
                              parallaxDepth: Vec2, camOffset: SIMD2<Float>, shakeOffset: SIMD2<Float>,
                              aspectScale: SIMD2<Float>) -> simd_float4x4 {
        let hw = size.x * scale.x * 0.5
        let hh = size.y * scale.y * 0.5
        let ca = cos(angleZ), sa = sin(angleZ)
        let aligned = Self.alignedCenter(origin: origin, alignment: alignment, hw: hw, hh: hh, ca: ca, sa: sa)
        // model: translate(aligned) * rotateZ(angleZ) * scale(hw, hh)
        // W1-yaxis: customLayerQuadInterleaved 는 local(-1,-1)→uv(0,0)=TL 로 고정(SceneRenderer.swift:889).
        // quadVertices 와 동일하게 uv(0,0) 이 화면 위쪽에 오려면 local y-basis(columns.1) 를 반전해야
        // local ly=-1 가 +hh(위) 로 매핑된다(quadVertices 의 hh 재페어링과 동형 보정).
        // 주의: quadVertices 는 코너 재라벨링(점 집합 불변)이라 삼각형 와인딩이 안 바뀌지만, 이 행렬
        // 경로는 columns.1 반전으로 행렬식 부호가 뒤집혀 와인딩이 역전된다 — 이 파이프라인을 그리는
        // 인코더는 setCullMode 를 호출하지 않아(grep 확인) Metal 기본값 .none 이라 무해(컬링 자체가
        // 없음). 향후 이 경로에 컬링을 도입하면 이 반전을 함께 재검토해야 한다.
        var model = simd_float4x4(1)
        model.columns.0 = SIMD4(ca * hw, sa * hw, 0, 0)
        model.columns.1 = SIMD4(sa * hh, -ca * hh, 0, 0)
        model.columns.2 = SIMD4(0, 0, 1, 0)
        model.columns.3 = SIMD4(aligned.x, aligned.y, 0, 1)
        // ortho: pixel → NDC(W1-yaxis: y-up, sceneToNDC/pxToNDC 와 동일 부호로 갱신)
        var ortho = simd_float4x4(1)
        ortho.columns.0 = SIMD4(2 / projW, 0, 0, 0)
        ortho.columns.1 = SIMD4(0, 2 / projH, 0, 0)
        ortho.columns.2 = SIMD4(0, 0, 1, 0)
        ortho.columns.3 = SIMD4(-1, -1, 0, 1)
        // camera/shake translation
        let camX = camOffset.x * parallaxDepth.x + shakeOffset.x
        let camY = camOffset.y * parallaxDepth.y + shakeOffset.y
        var cam = simd_float4x4(1)
        cam.columns.3 = SIMD4(camX, camY, 0, 1)
        // aspect scale
        var aspect = simd_float4x4(1)
        aspect.columns.0 = SIMD4(aspectScale.x, 0, 0, 0)
        aspect.columns.1 = SIMD4(0, aspectScale.y, 0, 0)
        return aspect * cam * ortho * model
    }

    /// 텍스트 horizontalAlign/verticalAlign(left|center|right / top|center|bottom) → SceneLayer.alignment
    /// 9점 앵커 문자열(F218/F219). 두 규약은 의미가 동일함이 확인됨: rasterize() 의 x0/y0 앵커 계산
    /// (left→origin=좌변, right→origin=좌변-w, top→origin=상변, bottom→origin=상변-h)이 quadVertices/
    /// alignedCenter 의 "left"→ax=-hw(origin=좌변)/"right"→ax=+hw(origin=우변에서 2× 폭만큼 안쪽) 규약과
    /// 정확히 일치 — 그래서 텍스트 지오메트리도 quadVertices 를 그대로 재사용할 수 있다(신규 회전 수식 불요).
    static func textAlignmentString(h: String, v: String) -> String {
        var s = ""
        if v == "top" { s += "top" } else if v == "bottom" { s += "bottom" }
        if h == "left" { s += "left" } else if h == "right" { s += "right" }
        return s.isEmpty ? "center" : s
    }

    /// 포워드 라이팅용 레이어 월드 사각형 — f_lit 이 uv→월드 재구성에 쓰는 (ox,oy,hw,hh)+(cosA,sinA,z,0).
    /// hw/hh/angle 규약은 quadVertices 와 동일(정합 필수). z = 레이어 originZ(2D 라이트 감쇠의 z 성분).
    static func litRect(origin: Vec2, size: Vec2, scale: Vec2, angleZ: Float, alignment: String, originZ: Float) -> (SIMD4<Float>, SIMD4<Float>) {
        let hw = size.x * scale.x * 0.5
        let hh = size.y * scale.y * 0.5
        let a = angleZ   // A1: scene.json angles 는 이미 라디안(코퍼스 전부 ≤π 확정) — 종전 *.pi/180 은 라디안을 도로 오인해 회전 57× 축소
        let ca = cos(a), sa = sin(a)
        let c = Self.alignedCenter(origin: origin, alignment: alignment, hw: hw, hh: hh, ca: ca, sa: sa)
        // W1-yaxis: f_lit(QuadShaders.swift, 불변)의 `ly = (uv.y*2-1)*rect[0].w` 역산이 quadVertices 의
        // 새 uv/코너 페어링(uv.y=0 → ly=+hh)과 맞으려면 −hh 를 패킹해야 한다(셰이더 소스 자체는 불변).
        // rect[0].w 의 소비자는 f_lit 의 이 한 줄뿐(grep 확인, QuadShaders.swift) — 크기(양수)로 읽는
        // 별도 소비자가 없어 부호반전 패킹이 무해함을 재확인.
        return (SIMD4(c.x, c.y, hw, -hh), SIMD4(ca, sa, originZ, 0))
    }

    /// 퍼펫 스킨 정점 → NDC 삼각형 리스트(quadVertices 와 동일 규약, W1-yaxis: 씬 픽셀 y-up).
    /// 메시 좌표는 레이어 로컬 픽셀(원점 중심)·**y-up**(실측: 2809885105 프리뷰 대비 반전 확인) —
    /// 씬도 이제 y-up 이라 모델 y-up 과 규약이 일치, 부호 반전 없이 그대로 origin/scale/angleZ 적용
    /// (W1-yaxis: §5 의 "제거 시 정상 3씬 파괴" 근거는 구 y-down pxToNDC 하에서 측정된 것이라
    /// 전역 y-flip 과 함께 무효 — 4종 게이트(3463520581 + §5 3씬) 전수 실측으로 제거가 맞음을
    /// 확인 후 착수. attachmentSceneDelta 의 Y-켤레도 동시에 제거(짝 관계, 아래 참조).
    /// 기록 정정(병합 게이트 지적): 이 게이트의 "flipped == before 일치" 캡처 비교는 **퍼펫
    /// 정립성(상하 방향)만** before 와 일치한다는 뜻이다 — before 자체가 구 y-down pxToNDC 산출물이라
    /// 위젯/레이어 절대 위치 등 프레임 전체 레이아웃은 이 웨이브(전역 pxToNDC y-up 반전)로 인해
    /// before 대비 달라졌다(예: 2809885105 의 시계 위젯 우상단→우하단 이동). "무회귀"로 오독 금지.
    static func puppetVertices(model: PuppetModel, positions: [SIMD3<Float>],
                               origin: Vec2, scale: Vec2, angleZ: Float,
                               projW: Float, projH: Float) -> [SIMD4<Float>] {
        let a = angleZ   // A1: scene.json angles 는 이미 라디안(코퍼스 전부 ≤π 확정) — 종전 *.pi/180 은 라디안을 도로 오인해 회전 57× 축소
        let ca = cos(a), sa = sin(a)
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(model.indices.count)
        for idx in model.indices {
            let i = Int(idx)
            guard i < positions.count else { continue }
            let p = positions[i]
            let lx = p.x * scale.x, ly = p.y * scale.y
            let sx = origin.x + lx * ca - ly * sa
            let sy = origin.y + lx * sa + ly * ca
            let ndc = pxToNDC(sx, sy, projW: projW, projH: projH)
            out.append(SIMD4<Float>(ndc.x, ndc.y, model.vertices[i].uv.x, model.vertices[i].uv.y))
        }
        return out
    }

    /// attachment 씬공간 델타 D = P∘A∘P⁻¹ — 베이크된 자식 월드에 곱하면
    /// childWorld(t) = P∘A(t)∘childLocal (P=부모 월드 T(o)·R(a)·S(s); A=부착점 프레임 4x4).
    /// W1-yaxis: 씬도 이제 y-up 이라 모델 y-up 과 일치 — 구 Y-켤레(Y=diag(1,−1))가 항등이 되어
    /// 제거(puppetVertices 의 부호 제거와 짝 — 한쪽만 바꾸면 부착물이 퍼펫 몸체에서 분리된다).
    /// 반환 (m,t): p′ = m·p + t. 부모 스케일 퇴화(≈0) → nil.
    static func attachmentSceneDelta(frame A: simd_float4x4,
                                     parentOrigin po: SIMD2<Float>, parentScale ps: SIMD2<Float>,
                                     parentAngle pa: Float) -> (m: simd_float2x2, t: SIMD2<Float>)? {
        guard abs(ps.x) > 1e-6, abs(ps.y) > 1e-6 else { return nil }
        let FL = simd_float2x2(SIMD2(A.columns.0.x, A.columns.0.y),
                               SIMD2(A.columns.1.x, A.columns.1.y))
        let Ft = SIMD2(A.columns.3.x, A.columns.3.y)
        let ca = cos(pa), sa = sin(pa)
        let PL = simd_float2x2(SIMD2(ca * ps.x, sa * ps.x), SIMD2(-sa * ps.y, ca * ps.y))
        let m = PL * FL * PL.inverse
        let t = PL * Ft + po - m * po
        return (m, t)
    }

    /// F742(S-19): SceneLayer.dependencies(F696) 명시 선행 의존 보정. 의존 타깃 레이어가 그리기 순서상
    /// 의존자보다 뒤(depLater — 실물 3113287126 idx2→idx4, 3151551777 idx74→idx76)면 의존자 직전으로 이동한다.
    /// _rt_imageLayerComposite 바인드(F720)가 "타깃이 그려진 뒤"의 프레임을 샘플하는 RTT/순서 계약을 보장.
    /// 이미 선행인 엣지(코퍼스 39건 중 37)는 무건드림(무회귀). 타깃 해석은 image 레이어 id 한정 —
    /// text 오브젝트는 id 미파스(F693 스코프)라 건드릴 수 없다(보고).
    static func applyingDependencies(_ plan: [DrawItem], layers: [SceneLayer]) -> [DrawItem] {
        var plan = plan
        let idToIdx = Dictionary(layers.enumerated().compactMap {
            $0.element.id != 0 ? ($0.element.id, $0.offset) : nil
        }, uniquingKeysWith: { a, _ in a })
        for (i, l) in layers.enumerated() where !l.dependencies.isEmpty {
            for depId in l.dependencies {
                guard let tIdx = idToIdx[depId],
                      let depPos = plan.firstIndex(where: { $0.kind == .layer && $0.idx == i }),
                      let tPos = plan.firstIndex(where: { $0.kind == .layer && $0.idx == tIdx }),
                      tPos > depPos else { continue }
                let item = plan.remove(at: tPos)
                // 이동 후 의존자 위치를 다시 찾아 그 직전에 삽입(타깃 1개만 옮기는 최소 보정).
                if let at = plan.firstIndex(where: { $0.kind == .layer && $0.idx == i }) {
                    plan.insert(item, at: at)
                }
            }
        }
        return plan
    }

    /// drawPlan 씬-순서 인터리브 인코딩(라이브 draw / 헤드리스 captureFrames 공용 단일 루프).
    /// 컴포지션(_rt_) 레이어는 인코더 교체(runFrameBufferLayer)가 일어나며, 재개 실패 시 nil 반환 —
    /// 이 시점엔 직전 인코더가 이미 endEncoding 된 상태이므로 호출자는 **추가 인코딩 없이**
    /// cb.commit() 으로만 정리해야 한다. 성공 시 열린 최종 인코더 반환(호출자가 endEncoding).
    /// 회귀 노트(2026-07-04): 과거 captureFrames 쪽 복제 루프는 이 실패를 switch-`break` 로만 탈출해
    /// 이미 종료된 인코더에 나머지 아이템을 계속 인코딩했다(Metal 크래시 후보). draw 쪽은 return 으로
    /// 고쳐져 있었는데 복제 루프가 발산한 것 — 루프 단일화로 구조적으로 제거(별도 목킹 불가로 RED
    /// 재현 테스트 대신 본 서술로 회귀 방지 근거를 남긴다).
    func encodeDrawPlan(startingWith enc: MTLRenderCommandEncoder, acc: MTLTexture,
                                cb: MTLCommandBuffer, device: MTLDevice, time: Float,
                                displayTextures: [MTLTexture],
                                textTextures: [MTLTexture?] = [],   // F741(S-13): 텍스트 이펙트 적용 표시 텍스처(옵션)
                                particleSnapshot: (Int) -> [Particle],
                                // 파티클 visible 을 호출자가 **이미** 평가했을 때의 조회 클로저(캡처 경로 —
                                // 방출 게이트를 웜업 스텝 전에 확정해야 해서 먼저 평가한다). nil = 여기서 평가
                                // (라이브 draw — 종전 경로 그대로). 스크립트 프레임당 1회 평가 계약 유지용.
                                particleVisible: ((Int) -> Bool)? = nil,
                                camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) -> MTLRenderCommandEncoder? {
        var enc = enc
        var i = 0
        while i < drawPlan.count {
            let item = drawPlan[i]
            if item.kind == .mesh3D {
                // F721: 연속 mesh3D 런을 한 메시 패스로 묶어 뎁스 공유(메시 상호 은폐 정합) —
                // 오브젝트별 분할이면 런 사이에 뎁스가 클리어되어 겹친 메시가 잘못 합성된다.
                var run = [item.idx]
                var j = i + 1
                while j < drawPlan.count, drawPlan[j].kind == .mesh3D { run.append(drawPlan[j].idx); j += 1 }
                guard let next = runOrtho3DMeshes(run, acc: acc, cb: cb, ending: enc, device: device,
                                                  time: time, aspectScale: &aspectScale) else { return nil }
                enc = next
                i = j
                continue
            }
            // E1(④): 2D 파티클 visible(정적+스크립트) 게이트 — 레이어/텍스트와 동일 규약으로 스크립트를
            // 먼저 평가(shared 사이드이펙트 보존)한 뒤 거짓이면 draw 스킵. 종전엔 이 검사가 전무해
            // 저작자가 숨긴 파티클 시스템이 항상 렌더됐다.
            if item.kind == .particle,
               !(particleVisible?(item.idx) ?? particleScriptVisible(item.idx, time: time)) {
                i += 1
                continue
            }
            switch item.kind {
            case .mesh3D:
                break  // 위 런 수집에서 처리(도달 불가)
            case .particle where particleSystems[item.idx].refract
                              && !particleSystems[item.idx].isRopeTrail
                              && particleSystems[item.idx].normalTexture != nil
                              && (particleSystems[item.idx].blendAdditive
                                  ? refractParticlePipelineAdditive : refractParticlePipeline) != nil:
                // REFRACT 스프라이트(+ C4-(iii): spriteTrail 신장 쿼드도 sprite 와 동형이라 포함): 여기까지의
                // acc(씬 컬러)를 스냅샷 떠 노멀 오프셋 재샘플(인코더 분할). rope/ropeTrail(히스토리 리본) refract
                // 는 스코프 밖 → 아래 일반 .particle 로 identity 렌더(ponytail).
                guard let next = runRefractParticle(particleSystems[item.idx], snapshot: particleSnapshot(item.idx),
                                                    acc: acc, cb: cb, ending: enc, device: device,
                                                    camOffset: &camOffset, aspectScale: &aspectScale) else { return nil }
                enc = next
            case .particle:
                encodeParticle(particleSystems[item.idx], snapshot: particleSnapshot(item.idx), into: enc,
                               device: device, camOffset: &camOffset, aspectScale: &aspectScale)
            case .text where textLayers[item.idx].def.colorBlendMode != 0:
                // C⑥: colorBlendMode 텍스트 — 이미지 레이어와 동일 인코더 분할(acc 스냅샷 dst 블렌드).
                guard let next = runBlendModeText(
                    textLayers[item.idx], texture: item.idx < textTextures.count ? textTextures[item.idx] : nil,
                    acc: acc, cb: cb, ending: enc, device: device, time: time,
                    camOffset: &camOffset, aspectScale: &aspectScale) else { return nil }
                enc = next
            case .text:
                encodeText(textLayers[item.idx], into: enc, camOffset: &camOffset, aspectScale: &aspectScale,
                          time: time, device: device,
                          displayTexture: item.idx < textTextures.count ? textTextures[item.idx] : nil)
            case .layer where layers[item.idx].isFrameBuffer:
                guard let next = runFrameBufferLayer(layers[item.idx], acc: acc, cb: cb, ending: enc,
                                                     device: device, time: time,
                                                     camOffset: &camOffset, aspectScale: &aspectScale) else { return nil }
                enc = next
            case .layer where layers[item.idx].colorBlendMode != 0:
                // colorBlendMode: 그 시점까지의 acc 스냅샷을 dst 로 셰이더 블렌드(컴포지션과 동일한
                // 인코더 분할 패턴 — 진행 중 타깃은 샘플 불가). 효과는 displayTextures 에 이미 적용됨.
                guard let next = runBlendModeLayer(layers[item.idx], texture: displayTextures[item.idx],
                                                   acc: acc, cb: cb, ending: enc, device: device, time: time,
                                                   camOffset: &camOffset, aspectScale: &aspectScale) else { return nil }
                enc = next
            case .layer where layers[item.idx].refract.enabled
                              && layers[item.idx].refract.normalTexture != nil
                              && refractLayerPipeline != nil:
                // H4: REFRACT 이미지 레이어: 여기까지의 acc(씬 컬러)를 스냅샷 떠 노멀 오프셋 재샘플(인코더 분할).
                guard let next = runRefractLayer(layers[item.idx], texture: displayTextures[item.idx],
                                                 acc: acc, cb: cb, ending: enc, device: device, time: time,
                                                 camOffset: &camOffset, aspectScale: &aspectScale) else { return nil }
                enc = next
            case .layer:
                encodeLayer(layers[item.idx], texture: displayTextures[item.idx], into: enc,
                            camOffset: &camOffset, aspectScale: &aspectScale, time: time, device: device)
            }
            i += 1
        }
        return enc
    }

    /// F721(S-12): ortho(2D) 씬에 인터리브된 3D 메시 런. acc 를 load 하는 별도 패스(뎁스 부착)로
    /// 메시를 그린 뒤 2D 인코더를 재개한다(runFrameBufferLayer 와 같은 인코더 분할 패턴).
    /// 투영: 2D v_main 과 같은 픽셀→NDC 직교 매핑(W1-yaxis: x_ndc=(2x/W−1)·aspectScale.x,
    /// y_ndc=(2y/H−1)·aspectScale.y — pxToNDC 와 동일 y-up 부호) + z 는 ±F 대칭 클립(z 클수록
    /// 앞 — 오브젝트 z 양수가 화면 앞). 씬 픽셀 좌표계를 2D 레이어와 공유하므로 같은 화면 위치에
    /// 놓인다(실물 3354366708: 그룹 origin (1920,1080) = 화면 중앙).
    /// 프런트 와인딩(W1-yaxis): sy 부호가 y-down→y-up 으로 바뀌며 이 직교행렬의 det 부호도 뒤집혀
    /// perspective 경로(encode3D=CCW)와 이제 같은 부호가 된다 — CW→CCW 로 동반 전환(종전엔 sy 의
    /// 구 부호 때문에 반대라 CW 였음). 섀도우는 미지원(ortho 검증 부재, 스코프 밖) — 라이트는
    /// resolveLights/packLights 를 3D 경로와 동일하게 해석(ortho 씬 라이트는 같은 씬 픽셀 공간).
    func runOrtho3DMeshes(_ meshIndices: [Int], acc: MTLTexture, cb: MTLCommandBuffer,
                          ending enc: MTLRenderCommandEncoder, device: MTLDevice, time: Float,
                          aspectScale: inout SIMD2<Float>) -> MTLRenderCommandEncoder? {
        enc.endEncoding()
        // 2D 인코더 재개 헬퍼(메시 스킵 폴터 — 색만 load, 뎁스 없음).
        func resume2D() -> MTLRenderCommandEncoder? {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = acc
            rpd.colorAttachments[0].loadAction = .load
            return cb.makeRenderCommandEncoder(descriptor: rpd)
        }
        guard let over = meshPipelineOver,
              let depthTex = pooledDepth(acc.width, acc.height, device) else {
            NSLog("%@", "[Waple] ortho 3D: mesh pipeline/depth unavailable — meshes skipped")
            return resume2D()
        }
        // H4: refract 메시가 런에 있으면 인코더 분할 전 패스의 뎁스를 .store(분할 재개 시 .load 정합 —
        // encode3D 의 needsDepthStore 게이트와 동일 이유). M6(⑥): reflect 메시도 동일 이유로 포함
        // (코퍼스 실측: REFLECTION 콤보 7씬 중 3씬이 orthogonalprojection 실값 보유 — ortho 경로 필수).
        let anyRefract = meshIndices.contains { meshRenderables[$0].meshes.contains { $0.refract && $0.refractNormal != nil } }
        let anyReflect = meshIndices.contains { meshRenderables[$0].meshes.contains { $0.reflection } }
        let needsStore = anyRefract || anyReflect
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = acc
        rpd.colorAttachments[0].loadAction = .load
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = needsStore ? .store : .dontCare
        guard var menc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        // 직교 투영: z_ndc = 0.5 − z/(2F). F 는 WE ortho 기본 farz 와 같은 대칭 클립(오브젝트 z ≈ ±수백).
        // W1-yaxis: sy/평행이동 y 를 pxToNDC 와 동일 부호(y-up)로 반전.
        let F: Float = 10000
        let sx = 2 / max(1, projW) * aspectScale.x
        let sy = 2 / max(1, projH) * aspectScale.y
        var proj = simd_float4x4(columns: (
            SIMD4<Float>(sx, 0, 0, 0),
            SIMD4<Float>(0, sy, 0, 0),
            SIMD4<Float>(0, 0, -1 / (2 * F), 0),
            SIMD4<Float>(-1, -1, 0.5, 1)))
        // camerashake/camera-origin 팬: 2D 레이어와 같은 화면 병진(clipTranslation — encode3D 와 동일 기법).
        if frameShakeOffset != .zero { proj = Scene3DMath.clipTranslation(frameShakeOffset) * proj }
        // W1-yaxis: sy 부호 반전으로 det 부호가 perspective 경로와 같아져 CCW 로 동반 전환.
        menc.setFrontFacing(.counterClockwise)
        // 월드행렬 입력(노드 계층) + 라이팅 바인드(섀도우 없음 — identity 행렬/nil 텍스처).
        var nmap: [Int: Scene3DMath.Node] = [:]
        nmap.reserveCapacity(nodes3D.count)
        for n in nodes3D {
            nmap[n.id] = Scene3DMath.Node(origin: n.origin, angles: n.angles, scale: n.scale,
                                          parent: n.parent, visible: n.visible)
        }
        let resolvedLights = Scene3DLighting.resolveLights(scene3DLights, nodes: nmap)
        var frameUniform = Scene3DFrameUniform(
            cameraEye: SIMD4(projW / 2, projH / 2, F, 1),   // ortho 관측자 근사(스페큘러 방향용)
            ambient: SIMD4(scene3DAmbient.x, scene3DAmbient.y, scene3DAmbient.z, 0),
            skylight: SIMD4(scene3DSkylight.x, scene3DSkylight.y, scene3DSkylight.z, 0),
            meta: SIMD4(Float(resolvedLights.count), 0, 0, 0))
        let lightUniforms = Scene3DLighting.packLights(resolvedLights)
        // 길이는 셰이더의 인덱스 공간과 **같아야 한다**: pointShadowVisibility 가 shadowVP[slice*6 + i]
        // 를 읽고 slice < Scene3DLighting.maximumLights(8) 이라 최대 인덱스가 47 이다
        // (encodePointShadows:1271 도 같은 식으로 maximumLights*6 개를 만든다). 종전 24 는 그 절반이라
        // 잠재 out-of-bounds 였고, 지금까지 안 터진 이유는 meta.y == 0 조기 반환뿐이었다.
        let noShadow = [simd_float4x4](repeating: matrix_identity_float4x4,
                                       count: Scene3DLighting.maximumLights * 6)
        bindScene3DLighting(frame: &frameUniform, lights: lightUniforms,
                            shadowMatrices: noShadow, shadowTexture: nil, into: menc)
        let skinBuffers = prepare3DSkinBuffers(time: time, device: device)
        for idx in meshIndices {
            let mr = meshRenderables[idx]
            guard let w = Scene3DMath.worldMatrix(id: mr.id, nodes: nmap), w.visible else { continue }
            var u = MeshUniform(
                mvp: proj * w.matrix,
                model: w.matrix,
                normalMatrix: Scene3DMath.normalMatrix4x4(w.matrix),
                tint: SIMD4(1, 1, 1, 1),
                material: SIMD4(0.7, 0, 0, 1),
                specularTint: SIMD4(1, 1, 1, 0),
                rim: SIMD4(2, 4, 0, 0))
            let boneBuf = skinBuffers[idx]
            for mesh in mr.meshes {
                // 스키닝 메시는 스킨 파이프라인+본 버퍼 필수(없으면 스킵 — encode3D 와 동일 규약).
                if mesh.skinned && boneBuf == nil { continue }
                u.tint = mesh.tint
                u.material = SIMD4(mesh.roughness, mesh.metallic, mesh.alphaCutoff, mesh.unlit ? 0 : 1)
                u.specularTint = SIMD4(mesh.specularTint.x, mesh.specularTint.y, mesh.specularTint.z, 0)
                // F274: RIMLIGHTING/SHADINGGRADIENT 콤보 유니폼 + 게이트 플래그.
                u.rim = SIMD4(mesh.rimAmount, mesh.rimExponent, mesh.rimLighting ? 1 : 0, mesh.shadingGradient ? 1 : 0)
                // WE `#if HDR albedo.rgb *= g_Brightness` — encode3D 와 동일 규약(게이트 근거는 그쪽 주석).
                // 이 경로는 자체 MeshUniform 을 만들므로 새 슬롯을 여기서도 실어야 한다.
                u.extra = SIMD4(sceneIsHDR ? mesh.brightness : 1, 0, 0, 0)
                let useSkin = mesh.skinned && boneBuf != nil
                // H4: REFRACT 메시(정적·비커스텀 한정): 여기까지의 acc(하위 order 2D 레이어+선행 메시 누적)를
                // 스냅샷 떠 노멀 오프셋 재샘플·곱(인코더 분할 — encode3D 의 H4 분기와 동형). 스냅샷 실패 시
                // 아래 일반 경로 폴터(무크래시).
                if mesh.refract, let refractNormal = mesh.refractNormal, !useSkin, mesh.customShader == nil,
                   let refractPipe = mesh.additive ? (meshPipelineRefractAdditive ?? meshPipelineRefract)
                                                 : meshPipelineRefract {
                    menc.endEncoding()
                    var snap: MTLTexture? = nil
                    if let s = pooledOffscreen(acc.width, acc.height, device, bgra: true),
                       let blit = cb.makeBlitCommandEncoder() {
                        blit.copy(from: acc, to: s); blit.endEncoding(); snap = s
                    }
                    let nextRPD = MTLRenderPassDescriptor()
                    nextRPD.colorAttachments[0].texture = acc
                    nextRPD.colorAttachments[0].loadAction = .load
                    nextRPD.depthAttachment.texture = depthTex
                    nextRPD.depthAttachment.loadAction = .load
                    nextRPD.depthAttachment.storeAction = needsStore ? .store : .dontCare
                    guard let nextMenc = cb.makeRenderCommandEncoder(descriptor: nextRPD) else { return nil }
                    menc = nextMenc
                    menc.setFrontFacing(.counterClockwise)
                    bindScene3DLighting(frame: &frameUniform, lights: lightUniforms,
                                        shadowMatrices: noShadow, shadowTexture: nil, into: menc)
                    if let snap {
                        menc.setRenderPipelineState(refractPipe)
                        if let ds = meshDepthState(test: mesh.depthTest, write: mesh.depthWrite, device: device) {
                            menc.setDepthStencilState(ds)
                        }
                        menc.setCullMode(mesh.cullBack ? .back : .none)
                        menc.setVertexBuffer(mesh.vbuf, offset: 0, index: 0)
                        menc.setVertexBytes(&u, length: MemoryLayout<MeshUniform>.stride, index: 1)
                        menc.setFragmentBytes(&u, length: MemoryLayout<MeshUniform>.stride, index: 1)
                        menc.setFragmentTexture(mesh.texture, index: 0)
                        menc.setFragmentTexture(mesh.gradientTexture ?? mesh.texture, index: 2)
                        menc.setFragmentTexture(refractNormal, index: 3)   // 노멀맵(g_Texture1)
                        menc.setFragmentTexture(snap, index: 4)            // 씬 컬러 스냅샷(_rt_FullFrameBuffer)
                        var rp = SIMD4<Float>(mesh.refractAmount, mesh.refractRG88 ? 1 : 0, 0, 0)
                        menc.setFragmentBytes(&rp, length: MemoryLayout<SIMD4<Float>>.stride, index: 5)
                        menc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                                   indexType: .uint32, indexBuffer: mesh.ibuf, indexBufferOffset: 0)
                        continue
                    }
                    // 스냅샷 확보 실패 — 재개한 menc 에서 일반 파이프라인으로 identity 폴터.
                } else if mesh.reflection, !useSkin, mesh.customShader == nil,
                          let reflectPipe = mesh.additive ? (meshPipelineReflectAdditive ?? meshPipelineReflect)
                                                          : meshPipelineReflect {
                    // M6(⑥): REFLECTION 메시(ortho 하이브리드) — encode3D 의 REFLECTION 분기와 동형.
                    // 카메라 뷰가 없는 ortho 경로는 이 함수의 `proj`(직교 투영) 를 encode3D 의 viewProj
                    // 자리에 그대로 대입(둘 다 "world→clip, 모델 미포함" 인 동일 역할).
                    menc.endEncoding()
                    var snap: MTLTexture? = nil
                    // encode3D 반사 분기와 동일 정정(2026-08-19): 반사 스냅샷은 **밉체인**이 있어야 한다 —
                    // mf_reflect 가 roughness 로 LOD 를 고르기 때문(Mesh3DShaders:815). 종전 이 경로는
                    // 밉 없는 pooledOffscreen 이라 reflectLod 가 항상 0(블러 대신 알갱이)이었다.
                    // refract 분기(위)는 level() 을 쓰지 않으므로 밉 없는 풀 그대로가 맞다.
                    if let s = reflectionSnapshot(acc.width, acc.height, device, hdr: hdrActive),
                       let blit = cb.makeBlitCommandEncoder() {
                        // 레벨 명시 copy — acc 는 밉 1개, s 는 mipmapped 라 전체 리소스 copy 오버로드의
                        // mipmapLevelCount 일치 요구를 위반한다(Metal 검증 실패).
                        blit.copy(from: acc, sourceSlice: 0, sourceLevel: 0,
                                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                                  sourceSize: MTLSize(width: acc.width, height: acc.height, depth: 1),
                                  to: s, destinationSlice: 0, destinationLevel: 0,
                                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                        blit.generateMipmaps(for: s)
                        blit.endEncoding(); snap = s
                    }
                    let nextRPD = MTLRenderPassDescriptor()
                    nextRPD.colorAttachments[0].texture = acc
                    nextRPD.colorAttachments[0].loadAction = .load
                    nextRPD.depthAttachment.texture = depthTex
                    nextRPD.depthAttachment.loadAction = .load
                    nextRPD.depthAttachment.storeAction = needsStore ? .store : .dontCare
                    guard let nextMenc = cb.makeRenderCommandEncoder(descriptor: nextRPD) else { return nil }
                    menc = nextMenc
                    menc.setFrontFacing(.counterClockwise)
                    bindScene3DLighting(frame: &frameUniform, lights: lightUniforms,
                                        shadowMatrices: noShadow, shadowTexture: nil, into: menc)
                    if let snap {
                        menc.setRenderPipelineState(reflectPipe)
                        if let ds = meshDepthState(test: mesh.depthTest, write: mesh.depthWrite, device: device) {
                            menc.setDepthStencilState(ds)
                        }
                        menc.setCullMode(mesh.cullBack ? .back : .none)
                        menc.setVertexBuffer(mesh.vbuf, offset: 0, index: 0)
                        menc.setVertexBytes(&u, length: MemoryLayout<MeshUniform>.stride, index: 1)
                        menc.setFragmentBytes(&u, length: MemoryLayout<MeshUniform>.stride, index: 1)
                        menc.setFragmentTexture(mesh.texture, index: 0)
                        menc.setFragmentTexture(mesh.gradientTexture ?? mesh.texture, index: 2)
                        menc.setFragmentTexture(snap, index: 4)
                        var rp = SIMD4<Float>(mesh.reflectivity, Float(acc.width) / Float(max(1, acc.height)), 0, 0)
                        menc.setFragmentBytes(&rp, length: MemoryLayout<SIMD4<Float>>.stride, index: 5)
                        var vp = proj
                        menc.setFragmentBytes(&vp, length: MemoryLayout<simd_float4x4>.stride, index: 6)
                        menc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                                   indexType: .uint32, indexBuffer: mesh.ibuf, indexBufferOffset: 0)
                        continue
                    }
                    // 스냅샷 확보 실패 — 재개한 menc 에서 일반 파이프라인으로 identity 폴터.
                }
                let pipe: MTLRenderPipelineState
                if useSkin {
                    let skinPipe = mesh.additive ? (meshPipelineSkinAdditive ?? meshPipelineSkin) : meshPipelineSkin
                    guard let p = skinPipe else { continue }
                    pipe = p
                } else {
                    pipe = mesh.additive ? (meshPipelineAdditive ?? over) : over
                }
                menc.setRenderPipelineState(pipe)
                if let ds = meshDepthState(test: mesh.depthTest, write: mesh.depthWrite, device: device) {
                    menc.setDepthStencilState(ds)
                }
                menc.setCullMode(mesh.cullBack ? .back : .none)
                menc.setVertexBuffer(mesh.vbuf, offset: 0, index: 0)
                menc.setVertexBytes(&u, length: MemoryLayout<MeshUniform>.stride, index: 1)
                if useSkin, let boneBuf { menc.setVertexBuffer(boneBuf, offset: 0, index: 2) }
                menc.setFragmentBytes(&u, length: MemoryLayout<MeshUniform>.stride, index: 1)
                menc.setFragmentTexture(mesh.texture, index: 0)
                // gradientTex 는 mf_main 선언 인자 — 미사용(u.rim.w==0) 시에도 자기 텍스처로 채워 바인딩 부재 방지.
                menc.setFragmentTexture(mesh.gradientTexture ?? mesh.texture, index: 2)
                menc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                           indexType: .uint32, indexBuffer: mesh.ibuf, indexBufferOffset: 0)
            }
        }
        menc.endEncoding()
        return resume2D()
    }

    /// F723(S-30): 스크립트의 `thisLayer.*` 직접 대입을 렌더러로 되읽는 채널(read-back).
    /// 종전엔 update() 반환값만 유효해서, 훅/사이드이펙트에서의 직접 대입(표준 WE 이디엄 — 커서/미디어 훅의
    /// thisLayer.visible 토글, isDragging 드래그 컨트롤러의 origin 대입 등 280회/23씬)이 렌더에 미반영이었다.
    /// 씬 공유 JSContext 의 thisScene.layers[] 오브젝트는 __wapleLayerForScript 가 thisLayer 로 바인드한
    /// 그 라이브 오브젝트이므로, 여기서 읽으면 스크립트가 쓴 최신 값이 보인다.
    /// 적용 우선순위(기존 채널 무회귀): update 보유 propScript 키·키프레임 애니 키·attachment/puppet 변환은
    /// 기존 평가값을 유지하고, 그 외 키만 read-back 으로 덮는다(update 반환값이 같은 프로퍼티의 WE 최종
    /// 쓰기 순서와 일치 — update 본문 대입 후 호스트가 반환값을 적용하므로 반환값이 이긴다).
    struct ScriptLayerReadBack {
        var visible: Bool? = nil
        var alpha: Float? = nil
        var origin: SIMD3<Float>? = nil
        var scale: SIMD3<Float>? = nil
        var angles: SIMD3<Float>? = nil
    }

    /// name 레이어의 JS 측 현재 상태를 읽어 온다(씬 공유 컨텍스트가 없으면 nil — 단독 컨텍스트 엔진의
    /// thisLayer 는 씬 레지스트리에 없어 read-back 대상이 아니다). 레이어 식별은 이름이 아니라
    /// **thisScene.layers 인덱스**(sceneScriptLayers 와 동일 순서: 이미지 레이어 후 텍스트) —
    /// 이름 조회(getLayer)는 중복명 첫 매치/묘명 layers[0] 폴터(S-34 오바인딩)라, 그 경로로 읽으면
    /// 묘명 레이어가 전혀 다른 layers[0] 의 트랜스폼으로 오염된다(실측 3394601417 거대 텍스트 사고).
    /// F743(S-34)로 엔진 thisLayer 는 디스크립터 인덱스 직결이라 대입과 read-back 이 항상 같은 객체를
    /// 가리킨다(종전 이름 기반 한계 — 중복명/묘명 미반영 — 는 해소).
    func readBackScriptLayerState(index: Int) -> ScriptLayerReadBack? {
        guard let ctx = sceneScript?.context, index >= 0 else { return nil }
        // NaN/비수치 방어: num() 이 null 로 떨어뜨리면 아래 NSNumber 캐스트가 실패해 해당 키만 미적용.
        guard let v = ctx.evaluateScript("""
        (function(i){
            var l = (thisScene.layers && i >= 0 && i < thisScene.layers.length) ? thisScene.layers[i] : null;
            if (!l) { return null; }
            function num(x){ return (typeof x === 'number' && isFinite(x)) ? x : null; }
            function v3(v){ return v ? [num(v.x), num(v.y), num(v.z)] : null; }
            return JSON.stringify({ visible: !!l.visible, alpha: num(l.alpha),
                origin: v3(l.origin), scale: v3(l.scale), angles: v3(l.angles) });
        })(\(index))
        """), v.isString, let data = v.toString().data(using: .utf8),
              let dict = AssetJSON.dictionary(data) else { return nil }
        var rb = ScriptLayerReadBack()
        rb.visible = dict["visible"] as? Bool
        rb.alpha = (dict["alpha"] as? NSNumber)?.floatValue
        func vec(_ key: String) -> SIMD3<Float>? {
            guard let a = dict[key] as? [Any], a.count >= 3,
                  let x = (a[0] as? NSNumber)?.floatValue,
                  let y = (a[1] as? NSNumber)?.floatValue,
                  let z = (a[2] as? NSNumber)?.floatValue else { return nil }
            return SIMD3(x, y, z)
        }
        rb.origin = vec("origin"); rb.scale = vec("scale")
        // 단위 경계(3/3): JS 의 angles 는 **도**, ScriptLayerReadBack 은 렌더러 내부 표현인
        // **라디안**(근거는 TextScriptEngine.evaluateAnglesVec 주석). origin/scale 은 무단위라
        // vec() 그대로, angles 만 여기서 되돌린다 — 그래서 아래 소비부(encodeLayer/encodeText 의
        // rb.angles 적용)와 liveLayerStates 기록부는 손댈 필요가 없다.
        // 부작용 하나: 라디안→도→라디안 왕복이 ~1 ulp 어긋나 `a.z != angle` 가드가 스크립트 보유
        // 레이어에서 매 프레임 참이 된다(quadDirty 재계산 1회 추가). 결정적이고 시각적으로
        // 무의미하며, 근거 없는 허용오차를 넣는 것보다 낫다고 판단해 그대로 둔다.
        rb.angles = vec("angles").map { $0 * Float(Double.pi / 180.0) }
        return rb
    }

    /// F743(S-35): 프레임 말 라이브 레이어 상태 → JS thisScene.layers 제자리 갱신(F710 경로).
    /// encodeLayer/encodeText 가 기록한 값으로 기준 디스크립터를 덮어써 밀어 넣는다 — 다음 프레임의
    /// getLayer()/thisLayer 독해가 스크립트/애니로 움직인 현재값을 본다(종전 t=0 정적 스냅샷 결함).
    /// 기록 없음(정적 씬)/컨텍스트 없음이면 no-op(무회귀).
    func pushLiveSceneLayers() {
        guard let ctx = sceneScript, !sceneScriptBaseDescriptors.isEmpty, !liveLayerStates.isEmpty else { return }
        var desc = sceneScriptBaseDescriptors
        for (idx, rb) in liveLayerStates where idx >= 0 && idx < desc.count {
            if let v = rb.visible { desc[idx].visible = v }
            if let a = rb.alpha { desc[idx].alpha = a }
            if let o = rb.origin { desc[idx].origin = o }
            if let sc = rb.scale { desc[idx].scale = sc }
            if let an = rb.angles { desc[idx].angles = an }
        }
        ctx.updateSceneLayers(desc)
        liveLayerStates.removeAll(keepingCapacity: true)
    }

    /// 이미지 레이어 1개 드로우(메인 컴포지트 파이프라인). time/device 는 프로퍼티 애니메이션·스크립트
    /// 평가용(def 있는 레이어만 per-frame 재계산 — origin/scale/angles → 쿼드, alpha/color → tint;
    /// 프로퍼티 스크립트(F331)도 동일 두 그룹으로 나뉘어 반영: origin/scale/angles 는 이 함수 앞부분
    /// (애니와 합류해 quadDirty 단일 재계산), color/alpha/visible 은 아래 별도 루프).
    func encodeLayer(_ layer: GPULayer, texture: MTLTexture, into enc: MTLRenderCommandEncoder,
                             camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>,
                             time: Float = 0, device: MTLDevice? = nil,
                             blendSnapshot: MTLTexture? = nil) {
        guard let pipeline else { return }
        var tint = layer.tint
        var vbuf = layer.vertexBuffer
        var litRect0 = layer.litRect.0, litRect1 = layer.litRect.1  // 애니 레이어는 아래서 재계산
        // H1/C②: 커스텀 셰이더·퍼펫 스킨 메시 배치 공용 유효 변환(애니/스크립트/attachment 반영 후).
        var effectiveTransform: (origin: Vec2, scale: Vec2, angle: Float)? = nil
        // F723: thisLayer 직접 대입 read-back(구조·우선순위는 함수 주석 참조). 스크립트 없는 레이어는
        // JS 평가 비용 0(propScripts/animLayerScripts 가 비어 있으면 nil).
        let scriptUpdateKeys = Set(layer.propScripts.filter { $0.engine.hasUpdate }.map { $0.key })
        let scriptRB: ScriptLayerReadBack? = {
            guard layer.def != nil, !layer.propScripts.isEmpty || !layer.animLayerScripts.isEmpty else { return nil }
            return readBackScriptLayerState(index: layer.uid)   // uid = doc.layers 인덱스 = JS layers 인덱스
        }()
        if let def = layer.def, let device {
            func animValue(_ key: String, _ comp: Int, _ base: Float) -> Float {
                def.animations[key]?.value(component: comp, atTime: time, base: base) ?? base
            }
            var origin = Vec2(x: animValue("origin", 0, def.origin.x), y: animValue("origin", 1, def.origin.y))
            var scale = Vec2(x: animValue("scale", 0, def.scale.x), y: animValue("scale", 1, def.scale.y))
            var angle = animValue("angles", 2, def.angleZ)
            var quadDirty = def.animations["origin"] != nil || def.animations["scale"] != nil || def.animations["angles"] != nil
            // attachment(이름 본-슬롯 부착): 부모 퍼펫 부착점 프레임 A(t) → 씬 델타 D = P∘(Y·A·Y)∘P⁻¹ 를
            // 베이크된 월드 변환에 합성. childWorld(t) = P∘A(t)∘childLocal 이 되어 정적 배치(부착점 상대)와
            // 본 애니 추종을 한 식으로 해소. 부착점 부재/퇴화 스케일 → 무부착(기존 위치 유지 — 무회귀).
            if let att = layer.attach {
                let eff = att.parentLayers.enumerated().filter { $0.element.visible && $0.element.blend > 0 }
                // 부모 퍼펫 렌더와 동일 디스패치: 2+ 레이어 = 캐스케이드, 그 외 = 클립 0(attachmentFrame 폴백).
                let resolved: [(anim: Int, additive: Bool, weight: Float, rate: Float)] = eff.count >= 2
                    ? eff.map { (PuppetPose.clipIndex(model: att.model, name: $0.element.name, fallback: $0.offset,
                                                      clipId: $0.element.clipId),
                                 $0.element.additive, $0.element.blend, $0.element.rate) }
                    : []
                if let A = PuppetPose.attachmentFrame(model: att.model, name: att.name, layers: resolved, time: time),
                   let d = Self.attachmentSceneDelta(frame: A, parentOrigin: att.parentOrigin,
                                                     parentScale: att.parentScale, parentAngle: att.parentAngle) {
                    let o2 = d.m * SIMD2(origin.x, origin.y) + d.t
                    origin = Vec2(x: o2.x, y: o2.y)
                    angle += atan2(d.m.columns.0.y, d.m.columns.0.x)
                    // ponytail: 델타 선형부는 각+축배율로 분해(전단 폐기) — 2D 퍼펫 본은 z회전·평행이동 위주.
                    scale = Vec2(x: scale.x * simd_length(d.m.columns.0), y: scale.y * simd_length(d.m.columns.1))
                    quadDirty = true
                }
            }
            // 프로퍼티 스크립트(origin/scale/angles, F331): update(현재값) → 쿼드 지오메트리 갱신(오디오반응
            // 스케일·클릭 angles·호버 origin — 3D 빌보드 경로(SceneRenderer3D.Billboard3D.evaluateScripts)와
            // 동일 marshalling 규약: origin/scale 은 Vec3(z 더미 성분 포함), angles 는 Vec3 의 z 성분만 사용.
            // 애니메이션/attachment 가 이미 채운 origin/scale/angle 을 "현재값"으로 스크립트에 공급 —
            // 한 레이어에서 서로 다른 키가 애니와 스크립트로 나뉘어도(예: scale 키프레임 + origin 스크립트)
            // 둘 다 보존된다(스크립트 전용 바인딩은 PropertyAnimation.parse 가 nil 이라 키 단위로는 배타적).
            for sc in layer.propScripts where sc.key == "origin" || sc.key == "scale" || sc.key == "angles" {
                sc.engine.setRuntime(Double(time))
                switch sc.key {
                case "origin":
                    if let v = sc.engine.evaluateVec(current: [origin.x, origin.y, def.originZ]), v.count >= 2 {
                        origin = Vec2(x: v[0], y: v[1]); quadDirty = true
                    }
                case "scale":
                    if let v = sc.engine.evaluateVec(current: [scale.x, scale.y, 1]), v.count >= 2 {
                        scale = Vec2(x: v[0], y: v[1]); quadDirty = true
                    }
                default:  // "angles"
                    // 단위 경계(1/3): 도↔라디안(evaluateAnglesVec). 0 은 두 단위에서 같다.
                    if let v = sc.engine.evaluateAnglesVec(currentRadians: [0, 0, angle]), v.count >= 3 {
                        angle = v[2]; quadDirty = true
                    }
                }
            }
            // F723: thisLayer 직접 대입 read-back(변환). update 보유 키·키프레임 애니 키는 기존 평가값 우선,
            // attachment/puppet 은 별도 변환 채널(본 델타/스킨)이라 건드리지 않는다(무회귀).
            if let rb = scriptRB, layer.attach == nil, layer.puppet == nil {
                if let o = rb.origin, !scriptUpdateKeys.contains("origin"), def.animations["origin"] == nil,
                   (o.x != origin.x || o.y != origin.y) {
                    origin = Vec2(x: o.x, y: o.y); quadDirty = true
                }
                if let s = rb.scale, !scriptUpdateKeys.contains("scale"), def.animations["scale"] == nil,
                   (s.x != scale.x || s.y != scale.y) {
                    scale = Vec2(x: s.x, y: s.y); quadDirty = true
                }
                if let a = rb.angles, !scriptUpdateKeys.contains("angles"), def.animations["angles"] == nil,
                   a.z != angle {
                    angle = a.z; quadDirty = true
                }
            }
            if quadDirty {
                let verts = Self.quadVertices(origin: origin, size: def.size, scale: scale, angleZ: angle,
                                         alignment: def.alignment, projW: projW, projH: projH,
                                         perspective: def.perspective, perspectiveFov: 95)
                if let b = layer.scratchQuad.load(verts, device: device) {
                    vbuf = b
                }
                // 라이트 레이어: 애니 지오메트리에 맞춰 월드 사각형도 재계산(f_lit 정합).
                if layer.isLit {
                    let r = Self.litRect(origin: origin, size: def.size, scale: scale, angleZ: angle, alignment: def.alignment, originZ: def.originZ)
                    litRect0 = r.0; litRect1 = r.1
                }
            }
            // H1/C②: 유효 변환(애니/스크립트/attachment 반영 후)을 항상 보존 — 커스텀 셰이더 파이프라인
            // 행렬 산출뿐 아니라 퍼펫 스킨 메시 배치(:1056)도 이 값을 쓴다. 애니/스크립트/attachment가
            // 전무하면 origin/scale/angle == def 정적값이라 비트동일(무회귀).
            effectiveTransform = (origin, scale, angle)
            // F743(S-35): 라이브 디스크립터 채널 — 이번 프레임 최종 변환 기록(알파/가시성은 아래서 병기).
            liveLayerStates[layer.uid] = ScriptLayerReadBack(
                visible: nil, alpha: nil,
                origin: SIMD3(origin.x, origin.y, def.originZ),
                scale: SIMD3(scale.x, scale.y, 1),
                angles: SIMD3(0, 0, angle))
            if def.animations["alpha"] != nil || def.animations["color"] != nil {
                let a = animValue("alpha", 0, def.alpha)
                let c = Vec3(x: animValue("color", 0, def.color.x), y: animValue("color", 1, def.color.y), z: animValue("color", 2, def.color.z))
                tint = SIMD4(c.x * def.brightness, c.y * def.brightness, c.z * def.brightness, a)
            }
        }
        // 프로퍼티 스크립트: update(현재값) → visible/color/alpha 갱신(미디어 컬러 전환 등 — 이벤트
        // 없으면 스크립트 초기 상태값이 정답: 실물 ColorTinter 는 Vec3(0,0,0) 시작 = 다크).
        // 모든 스크립트를 먼저 평가(shared 사이드이펙트 보존)한 뒤 visible 이 거짓이면 draw 스킵.
        for sc in layer.propScripts {
            sc.engine.setRuntime(Double(time))
            if sc.key == "color", let v = sc.engine.evaluateVec(current: [tint.x, tint.y, tint.z]), v.count >= 3 {
                let b = layer.def?.brightness ?? 1
                tint = SIMD4(v[0] * b, v[1] * b, v[2] * b, tint.w)
            } else if sc.key == "alpha", let v = sc.engine.evaluateVec(current: [tint.w]), let a = v.first {
                tint.w = a
            } else if sc.key == "visible" {
                let cur = scriptVisible[layer.uid] ?? layer.initialVisible
                scriptVisible[layer.uid] = sc.engine.evaluateBool(current: cur) ?? cur
            }
        }
        // F723: thisLayer 직접 대입 read-back(alpha/visible). update 보유 키는 위 루프의 반환값이 우선.
        // 훅/사이드이펙트 대입(커서·미디어 훅의 thisLayer.visible/alpha)이 여기서 렌더에 반영된다.
        if let rb = scriptRB {
            if let a = rb.alpha, !scriptUpdateKeys.contains("alpha"), layer.def?.animations["alpha"] == nil {
                tint.w = a
            }
            if let v = rb.visible, !scriptUpdateKeys.contains("visible") {
                scriptVisible[layer.uid] = v
            }
        }
        // F743(S-35): 알파/가시성 최종값 병기(변환은 위 애니 블록에서 기록 — def 없는 레이어는
        // 스크립트/애니도 없어 기록 불요, 기준 디스크립터의 정적값이 곧 정답).
        liveLayerStates[layer.uid]?.alpha = tint.w
        liveLayerStates[layer.uid]?.visible = scriptVisible[layer.uid] ?? layer.initialVisible
        // animationlayers 스크립트: per-frame 재평가 → 유효 visible/rate/blend 를 로컬 사본에 반영
        // (캐스케이드 블렌드 소비자 전용 — 정적 파스값 def.animationLayers 는 불변, current 인자로 재공급).
        // propScripts 와 동일하게 draw 스킵보다 먼저 평가(shared 사이드이펙트 보존). 예외/무update → 정적값 유지.
        var effLayers = layer.def?.animationLayers ?? []
        for sc in layer.animLayerScripts where sc.layerIndex < effLayers.count {
            sc.engine.setRuntime(Double(time))
            switch sc.key {
            case "visible":
                let cur = effLayers[sc.layerIndex].visible
                effLayers[sc.layerIndex].visible = sc.engine.evaluateBool(current: cur) ?? cur
            case "rate":
                if let r = sc.engine.evaluateVec(current: [effLayers[sc.layerIndex].rate])?.first {
                    effLayers[sc.layerIndex].rate = r
                }
            case "blend":   // 이미지 레이어 코퍼스 실측 0건 — 동일 스위치라 무비용 커버(3D 쪽 실물만 존재)
                if let b = sc.engine.evaluateVec(current: [effLayers[sc.layerIndex].blend])?.first {
                    effLayers[sc.layerIndex].blend = b
                }
            default: break
            }
        }
        // visible 스크립트 평가값(또는 정적 초기값)이 거짓 → draw 스킵(레이어는 유지 — 런타임 토글 가능).
        if !(scriptVisible[layer.uid] ?? layer.initialVisible) { return }
        // 영구 비가시 조상 상속(SceneLayer.hiddenByAncestor)은 스크립트 반환값보다 우선한다 — 조상이
        // 정적 false + 스크립트 없음이라 이 마운트 동안 절대 켜지지 않기 때문이다. 위 스크립트 평가를
        // **먼저** 끝낸 뒤 여기서 스킵하므로 컨트롤러 스크립트의 shared 사이드이펙트는 그대로 돈다.
        if layer.hiddenByAncestor { return }
        var vertexCount = 6
        // 퍼펫: per-frame CPU 스키닝 → 메시 삼각형 리스트로 쿼드 대체.
        if let pm = layer.puppet, let def = layer.def, let device {
            // 다층 animationlayers → 캐스케이드 블렌드(2+ 활성 레이어). 0/1 = 기존 단일 경로(무회귀).
            // effLayers = 정적 파스값 + per-frame 스크립트 평가값(위 animLayerScripts 루프).
            let eff = effLayers.enumerated().filter { $0.element.visible && $0.element.blend > 0 }
            let mats: [simd_float4x4]
            if eff.count >= 2 {
                let resolved = eff.map { (pos, L) in
                    (anim: PuppetPose.clipIndex(model: pm, name: L.name, fallback: pos, clipId: L.clipId),
                     additive: L.additive, weight: L.blend, rate: L.rate)
                }
                // C④: rate 가 스크립트로 매프레임 재평가되는 레이어(오디오 반응 등)만 dt 위상적분 —
                // 정적 rate 레이어는 기존 time×rate 순간위상 그대로(비트동일). rate 스크립트 부재 씬은
                // overrideFrames 전원 nil → PuppetPose 내부 기존 계산과 100% 동일.
                var overrideFrames: [Float?] = [Float?](repeating: nil, count: resolved.count)
                var phase = puppetCascadePhase[layer.uid] ?? []
                if phase.count != resolved.count { phase = [Float](repeating: .nan, count: resolved.count) }
                let dt = puppetCascadeLastTime[layer.uid].map { max(0, time - $0) } ?? 0
                var phaseTouched = false
                for (i, e) in eff.enumerated() {
                    guard layer.animLayerScripts.contains(where: { $0.key == "rate" && $0.layerIndex == e.offset })
                    else { continue }
                    let prev: Float? = phase[i].isNaN ? nil : phase[i]
                    let r = PuppetPose.integratedCascadeFrame(model: pm, anim: resolved[i].anim,
                                                              rate: resolved[i].rate, time: time, dt: dt,
                                                              previousPhase: prev)
                    phase[i] = r.phase
                    overrideFrames[i] = r.frame
                    phaseTouched = true
                }
                if phaseTouched {
                    puppetCascadePhase[layer.uid] = phase
                    puppetCascadeLastTime[layer.uid] = time
                }
                mats = PuppetPose.blendedSkinMatrices(model: pm, layers: resolved, time: time,
                                                      overrideFrames: overrideFrames)
            } else if let (_, L) = eff.first {
                // C③: 활성 레이어가 1개면 종전엔 무조건 클립 0(하드코딩)이었다 — id/이름 매칭 없이.
                // clipIndex 와 동일 규약(id 최우선 → 이름 서브스트링 → fallback)으로 통일하되, fallback
                // 을 0 으로 둬 id/이름 모두 미매칭이면 종전과 100% 동일한 클립 0 을 유지(무회귀).
                let ci = PuppetPose.clipIndex(model: pm, name: L.name, fallback: 0, clipId: L.clipId)
                mats = PuppetPose.skinMatrices(model: pm, animation: ci, time: time)
            } else {
                mats = PuppetPose.skinMatrices(model: pm, animation: 0, time: time)
            }
            let pos = PuppetPose.skinnedPositions(model: pm, matrices: mats)
            // C②: 스킨 메시 배치는 이 함수가 앞서 계산한 유효 변환(애니/스크립트/attachment 반영,
            // effectiveTransform)을 써야 한다 — attachment 자식 퍼펫(머리카락 등)의 부착 델타뿐 아니라
            // 부모 퍼펫 자신의 origin/scale/angles 키프레임·프로퍼티 스크립트도 여기 포함된다. 이전에는
            // attachedTransform(attachment 전용) ?? def 정적값으로 떨어져, attachment 없는 퍼펫의 애니/
            // 스크립트 변환이 계산만 되고 버려졌다(6씬 398오브젝트 실측 — 감사 C② wf3#20). 애니/스크립트/
            // attachment가 전무하면 effectiveTransform == def 정적값이라 비트동일(무회귀).
            let (po, psRaw, pa) = effectiveTransform ?? (origin: def.origin, scale: def.scale, angle: def.angleZ)
            // H1(W0a): 스크립트 산출 scale 이 양 축 모두 0(완전 퇴화)이면 def 정적 scale 로 폴백 — 스크립트가
            // 미할당 변수를 산술에 섞어 NaN 을 만들면(예 WEMath.mix(a,b,undefined)) Vec2/Vec3 shim 생성자의
            // `x || 0` 관용이 이를 조용히 (0,0) 으로 흡수해 evaluateVec 의 NaN/Inf 가드를 통과해버린다
            // (실물 3622495963: 워크샵 공유 호버-스케일 스크립트가 applyUserProperties 초기화 경합으로
            // speed 미할당 → 9레이어 치비 스프라이트가 스킨 메시 자체는 로드됐는데 화면에서 통째로 소멸).
            // 정상 애니메이션이 스케일을 지나가는 경우는 순간적(0 근방을 스칠 뿐)이라, 캡처 시점에 정확히
            // 양 축 모두 0으로 고정 관측되는 경우는 사실상 결함 신호로 간주해도 안전(원점/각도는 유효 변환 유지).
            let ps = (psRaw.x == 0 && psRaw.y == 0) ? def.scale : psRaw
            let verts = SceneRenderer.puppetVertices(model: pm, positions: pos,
                                                     origin: po, scale: ps, angleZ: pa,
                                                     projW: projW, projH: projH)
            if !verts.isEmpty, let b = layer.scratchSkin.load(verts, device: device) {
                vbuf = b
                vertexCount = verts.count
            }
        }
        var depth = layer.parallaxDepth
        // H1: 커스텀 머티리얼 셰이더 경로 — QuadShaders 대체.
        if let custom = layer.customShader, let def = layer.def {
            let t = effectiveTransform ?? (origin: def.origin, scale: def.scale, angle: def.angleZ)
            // 번역 셰이더의 mul(v, eng.mvp) 는 M·v 로 방출된다(GLSLTranslator translateBody ①의
            // ((b)*(a)) 셰임 — HLSL 행벡터 규약과 등가). layerTransformMatrix 도 M·v 규약이라
            // **전치 없이** 그대로 바인딩한다. 종전에는 번역기가 v·M 로 방출하던 시기(d45c259)의
            // 보정으로 여기에 .transpose 가 붙어 있었고, 셰임을 되돌리면서 함께 걷어냈다.
            // 무회전·축정렬 스케일만 있는 레이어는 D=Dᵀ 이라 전치 여부가 무관하다 — 회전 레이어에서만 발현.
            let m = layerTransformMatrix(origin: t.origin, size: def.size, scale: t.scale,
                                         angleZ: t.angle, alignment: def.alignment,
                                         parallaxDepth: Vec2(x: layer.parallaxDepth.x, y: layer.parallaxDepth.y),
                                         camOffset: camOffset, shakeOffset: frameShakeOffset,
                                         aspectScale: aspectScale)
            enc.setRenderPipelineState(custom.pipeline)
            // F1(flip①): effectQuadInterleaved(ev_main 전용, local(-1,-1)→uv(0,1))는 여기서 재사용하면
            // layerTransformMatrix 의 y-flip ortho 와 겹쳐 텍스처가 상하 반전된다 — 전용 버퍼로 분리
            // (customLayerQuadInterleaved: local(-1,-1)→uv(0,0), 표준 quadVertices 규약과 동일).
            enc.setVertexBuffer(customLayerQuadInterleaved, offset: 0, index: 4)
            var mat = custom.material
            for sc in custom.scripts {
                sc.engine.setRuntime(Double(time))
                let cur = mat[sc.slot]
                if let v = sc.engine.evaluateVec(current: [cur.x, cur.y, cur.z]) {
                    if v.count >= 3 { mat[sc.slot] = SIMD4(v[0], v[1], v[2], cur.w) }
                    else if v.count == 1 { mat[sc.slot] = SIMD4(v[0], cur.y, cur.z, cur.w) }
                }
            }
            if !mat.isEmpty {
                mat.withUnsafeBytes {
                    enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
                    enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
                }
            }
            // X-⑤ 스코프 밖: 이 경로는 tex0(custom.texRes.first, 레이어 자산 텍스처 해상도)를 그대로
            // targetRes 에 실어 무회귀만 유지한다. 이펙트 체인 경로(위 g_TexelSize 정본)와 규약이
            // 이원화된 상태이며, tex0=타깃이라는 근거는 확인되지 않았다(레이어 자산 해상도와 합성
            // RT 해상도가 실제로 다른 경우가 흔함) — 알려진 미검증 괴리로 남겨둔 것이지 옳다고
            // 확인된 근사가 아니다. 값을 바꾸는 것은 이번 배치 스코프 밖(무회귀 우선), 필요 시 라이브
            // A/B 로 별도 재검증.
            let eng = engineUniform(time: time, texRes: custom.texRes, texWrap: custom.texWrap,
                                    texFilter: custom.texFilter, layerTint: tint,
                                    targetRes: custom.texRes.first ?? SIMD4(1, 1, 1, 1), mvp: m)
            eng.withUnsafeBytes {
                enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
            }
            enc.setFragmentTexture(texture, index: 0)
            for (slot, tex) in custom.aux { enc.setFragmentTexture(tex, index: slot) }
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            return
        }
        // 파이프라인 선택: lit > colorBlendMode > framebuffer compose > material additive >
        // DIRECTDRAW premultiplied 출력 > 기본 over.
        // additive는 특수 경로가 아닌 일반 f_main 레이어에만 적용한다.
        // 감사 V07: 무효과 NoInterpolation 레이어는 nearest 변형 우선(미빌드 시 대응 선형 폴터 — 무회귀).
        // 효과 보유 레이어의 표시 텍스처는 체인 출력(FBO)이라 선형 유지가 WE 정합(손-포팅 fbNearest 의
        // V06 근거와 동일 — nearest 는 베이스 텍스처 직결 샘플에만).
        let near = layer.noInterp && layer.effects.isEmpty
        if layer.isLit, let litPipeline {
            enc.setRenderPipelineState(near ? litNearestPipeline ?? litPipeline : litPipeline)
        } else if let blendSnapshot, let blendPipeline, layer.colorBlendMode != 0 {
            // colorBlendMode: 스냅샷 dst 대비 셰이더 블렌드(f_blend). 스냅샷 없으면 일반 합성 폴백.
            enc.setRenderPipelineState(near ? blendNearestPipeline ?? blendPipeline : blendPipeline)
            enc.setFragmentTexture(blendSnapshot, index: 1)
            var mode = Int32(clamping: layer.colorBlendMode)  // F530-sweep: 범위 밖은 트랩이 아니라 포화(파스에서 이미 0 정규화, 여기는 이중 방어)
            enc.setFragmentBytes(&mode, length: MemoryLayout<Int32>.stride, index: 1)
        } else if layer.isFrameBuffer, let composePipeline {
            // 컴포지션(_rt_FullFrameBuffer): texture=프레임버퍼 스냅샷을 화면좌표로 샘플(f_compose).
            // 부분 쿼드도 뒤 화면을 1:1 통과 → stretch 회색 덩어리 제거(E1). 나머지 바인딩은 f_main 동일.
            enc.setRenderPipelineState(near ? composeNearestPipeline ?? composePipeline : composePipeline)
        } else if layer.blendAdditive,
                  !layer.isLit,
                  layer.colorBlendMode == 0,
                  !layer.isFrameBuffer,
                  let layerAdditivePipeline {
            enc.setRenderPipelineState(near ? layerAdditiveNearestPipeline ?? layerAdditivePipeline : layerAdditivePipeline)
        } else if premultipliedDisplayLayers.contains(layer.uid), let layerPremultipliedPipeline {
            // DIRECTDRAW 이펙트 체인 출력: 블렌드 상태는 기본 over 와 같고 프래그먼트만 premultiply 생략.
            // near 는 여기서 항상 false 다(near 는 effects.isEmpty 를 요구 — 이 분기는 체인 보유 레이어).
            enc.setRenderPipelineState(layerPremultipliedPipeline)
        } else {
            enc.setRenderPipelineState(near ? pipelineNearest ?? pipeline : pipeline)
        }
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.setVertexBytes(&depth, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        enc.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        var shake = frameShakeOffset  // camerashake 전역 지터(v_main buffer 4, 깊이 무관). 비활성=0 → +0 비트동일.
        enc.setVertexBytes(&shake, length: MemoryLayout<SIMD2<Float>>.stride, index: 4)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        // f_lit 유니폼: rect + 라이트 위치·exponent/색·반경 + 앰비언트 + 레이어 PBR 재질. 라이트 레이어만.
        if layer.isLit, litPipeline != nil {
            let rect = [litRect0, litRect1]
            rect.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            lightPositions.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
            lightColorRadius.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 3) }
            var amb = lightAmbient
            enc.setFragmentBytes(&amb, length: MemoryLayout<SIMD4<Float>>.stride, index: 4)
            var material = layer.pbrMaterial
            // material.constantshadervalue.scripted — PBR scalar per-frame evaluation.
            for (key, engine) in layer.materialScripts {
                engine.setRuntime(Double(time))
                switch key {
                case "roughness":
                    if let v = engine.evaluateVec(current: [material.scalars.x])?.first {
                        material.scalars.x = v
                    }
                case "metallic":
                    if let v = engine.evaluateVec(current: [material.scalars.y])?.first {
                        material.scalars.y = v
                    }
                case "speculartint":
                    if let v = engine.evaluateVec(current: [material.specularTint.x,
                                                             material.specularTint.y,
                                                             material.specularTint.z]), v.count >= 3 {
                        material.specularTint = SIMD4(v[0], v[1], v[2], 0)
                    }
                default: break
                }
            }
            enc.setFragmentBytes(&material, length: MemoryLayout<PBRMaterialUniforms>.stride, index: 5)
            // F800(S-9): kind/axis/cone — 후방 확장(기존 0-5 슬롯 규약 불변).
            lightAxisCone.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 6) }
            lightKindCone.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 7) }
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }

    /// 스크립트 텍스트 매 프레임 재평가. 변경 시에만 재래스터(시계류는 초 1회만 바뀌어 비용 동일).
    /// F724: 종전 초당 1회 게이트(sec != lastTextRefreshSecond)는 스크롤/마키·서브초 애니 스크립트를
    /// 1Hz 로 끊었다 — WE 의 update 는 매 프레임 발화(d.ts:58). 게이트 제거, 재래스터는 문자열 비교로 억제.
    func refreshScriptedTexts(device: MTLDevice, time: Float) {
        guard hasScriptedText else { return }
        for i in textLayers.indices {
            guard let e = textLayers[i].engine else { continue }
            e.setRuntime(Double(time))
            let newText = e.evaluate(current: textLayers[i].lastText) ?? ""
            if newText != textLayers[i].lastText {
                textLayers[i].lastText = newText
                rasterize(&textLayers[i], device: device)
            }
        }
    }

    /// 텍스트 1개 드로우(메인 컴포지트 파이프라인, parallaxDepth=1). time/device 는 프로퍼티 스크립트
    /// 평가용(F218/F219) — 콘텐츠 텍스트(engine/lastText, refreshScriptedTexts 가 매 프레임 재평가·변경 시 재래스터)와
    /// 별개 채널: origin/scale/alpha/color/angles/visible 은 재래스터 없이 이 함수가 인코드 시점
    /// 트랜스폼/알파/가시성만 갱신한다(3D 빌보드 Billboard3D.evaluateScripts 와 동형 단일 루프 —
    /// 텍스트는 키프레임 애니메이션이 없어 GPULayer 처럼 애니 블록과 합류시킬 필요가 없다).
    func encodeText(_ t: GPUText, into enc: MTLRenderCommandEncoder,
                            camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>,
                            time: Float = 0, device: MTLDevice? = nil,
                            displayTexture: MTLTexture? = nil,   // F741(S-13): 이펙트 적용 텍스처(없으면 원본)
                            blendSnapshot: MTLTexture? = nil) {  // C⑥: colorBlendMode dst 스냅샷(이미지 레이어와 동형)
        guard let pipeline, let tex = displayTexture ?? t.texture else { return }
        var tint = t.tint
        var vbuf = t.vertexBuffer
        var origin = t.def.origin, scale = t.def.scale
        // W3-⑤(b): 정적 angleZ(3146703458 등, ~178°) — rasterize() 가 굽는 초기 vbuf 는 무회전이라
        // quadDirty 를 강제해야 아래 quadVertices 재계산이 실제로 회전을 반영한다(스크립트 없는 텍스트도).
        var angle: Float = t.def.angleZ
        var quadDirty = t.def.angleZ != 0
        // 모든 스크립트를 먼저 평가(shared 사이드이펙트 보존)한 뒤 visible 이 거짓이면 draw 스킵
        // (GPULayer.propScripts 루프와 동일 순서 원칙).
        for sc in t.propScripts {
            sc.engine.setRuntime(Double(time))
            switch sc.key {
            case "origin":
                if let v = sc.engine.evaluateVec(current: [origin.x, origin.y, 0]), v.count >= 2 {
                    origin = Vec2(x: v[0], y: v[1]); quadDirty = true
                }
            case "scale":
                if let v = sc.engine.evaluateVec(current: [scale.x, scale.y, 1]), v.count >= 2 {
                    scale = Vec2(x: v[0], y: v[1]); quadDirty = true
                }
            case "angles":
                // 단위 경계(1/3): 도↔라디안(evaluateAnglesVec) — 이미지 레이어(:1114 루프)와 동형.
                if let v = sc.engine.evaluateAnglesVec(currentRadians: [0, 0, angle]), v.count >= 3 {
                    angle = v[2]; quadDirty = true
                }
            case "color":
                if let v = sc.engine.evaluateVec(current: [tint.x, tint.y, tint.z]), v.count >= 3 {
                    tint = SIMD4(v[0], v[1], v[2], tint.w)
                }
            case "alpha":
                if let v = sc.engine.evaluateVec(current: [tint.w]), let a = v.first {
                    tint.w = a
                }
            case "visible":
                let cur = scriptTextVisible[t.uid] ?? t.initialVisible
                scriptTextVisible[t.uid] = sc.engine.evaluateBool(current: cur) ?? cur
            default: break
            }
        }
        // F723: thisLayer 직접 대입 read-back(텍스트 — GPULayer 와 동형). update 보유 키는 위 루프의
        // 반환값이 우선(무회귀). 텍스트는 키프레임 애니가 없어 변환 read-back 도 그대로 적용.
        // JS layers 인덱스 = 이미지 레이어 수 + 텍스트 uid(sceneScriptLayers 의 이미지→텍스트 순서).
        if !t.propScripts.isEmpty, let rb = readBackScriptLayerState(index: sceneScriptImageLayerCount + t.uid) {
            let updateKeys = Set(t.propScripts.filter { $0.engine.hasUpdate }.map { $0.key })
            if let o = rb.origin, !updateKeys.contains("origin"), (o.x != origin.x || o.y != origin.y) {
                origin = Vec2(x: o.x, y: o.y); quadDirty = true
            }
            if let s = rb.scale, !updateKeys.contains("scale"), (s.x != scale.x || s.y != scale.y) {
                scale = Vec2(x: s.x, y: s.y); quadDirty = true
            }
            if let a = rb.angles, !updateKeys.contains("angles"), a.z != angle {
                angle = a.z; quadDirty = true
            }
            if let al = rb.alpha, !updateKeys.contains("alpha") { tint.w = al }
            if let v = rb.visible, !updateKeys.contains("visible") { scriptTextVisible[t.uid] = v }
        }
        // origin/scale/angles 스크립트가 있을 때만 재계산(정적 텍스트는 rasterize() 가 구운 vbuf 그대로
        // — device 없는 호출자는 지오메트리 갱신을 건너뛰되 tint/visible 은 이미 반영된 채 그린다).
        if quadDirty, let device {
            let align = Self.textAlignmentString(h: t.def.horizontalAlign, v: t.def.verticalAlign)
            let verts = Self.quadVertices(origin: origin, size: Vec2(x: t.rasterWidth, y: t.rasterHeight),
                                          scale: scale, angleZ: angle, alignment: align, projW: projW, projH: projH)
            if let b = t.scratchQuad.load(verts, device: device) { vbuf = b }
        }
        // F743(S-35): 텍스트 라이브 디스크립터(GPULayer 와 동형 — JS 인덱스 = 이미지 레이어 수 + uid).
        liveLayerStates[sceneScriptImageLayerCount + t.uid] = ScriptLayerReadBack(
            visible: scriptTextVisible[t.uid] ?? t.initialVisible, alpha: tint.w,
            origin: SIMD3(origin.x, origin.y, 0), scale: SIMD3(scale.x, scale.y, 1),
            angles: SIMD3(0, 0, angle))
        // visible 스크립트 평가값(또는 정적 초기값)이 거짓 → draw 스킵(GPULayer 와 동일 규약).
        if !(scriptTextVisible[t.uid] ?? t.initialVisible) { return }
        if t.hiddenByAncestor { return }   // 조상 상속 하드 게이트(encodeLayer 와 동일 규약)
        guard let vbuf else { return }
        var depth = SIMD2<Float>(1, 1)
        // C⑥: colorBlendMode — 이미지 레이어(encodeLayer)와 동일 f_blend 경로 재사용. 스냅샷 없으면
        // (인코더 미분할 호출자 등) 일반 premult-over 폴백(무회귀).
        if let blendSnapshot, let blendPipeline, t.def.colorBlendMode != 0 {
            enc.setRenderPipelineState(blendPipeline)
            enc.setVertexBuffer(vbuf, offset: 0, index: 0)
            enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            enc.setVertexBytes(&depth, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            enc.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
            var shake = frameShakeOffset
            enc.setVertexBytes(&shake, length: MemoryLayout<SIMD2<Float>>.stride, index: 4)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.setFragmentTexture(blendSnapshot, index: 1)
            var mode = Int32(clamping: t.def.colorBlendMode)  // F530-sweep: 이미지 레이어(:1450)와 동형
            enc.setFragmentBytes(&mode, length: MemoryLayout<Int32>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            return
        }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.setVertexBytes(&depth, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        enc.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        var shake = frameShakeOffset  // camerashake 전역 지터(v_main buffer 4). 텍스트도 전역 병진에 동참.
        enc.setVertexBytes(&shake, length: MemoryLayout<SIMD2<Float>>.stride, index: 4)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// E1(④): 2D 파티클 visible 프로퍼티 스크립트 재평가(레이어 encodeLayer/텍스트 encodeText 의 "visible"
    /// 케이스와 동일 규약 — 이전 평가값을 current 로 전달, 스크립트 없으면 정적 초기값). 반환값이 draw 게이트.
    func particleScriptVisible(_ idx: Int, time: Float) -> Bool {
        guard idx < particleSystems.count, let engine = particleSystems[idx].visibleEngine else {
            guard idx < particleSystems.count else { return true }
            return particleSystems[idx].initialVisible && !particleSystems[idx].hiddenByAncestor
        }
        engine.setRuntime(Double(time))
        let cur = scriptParticleVisible[idx] ?? particleSystems[idx].initialVisible
        let v = engine.evaluateBool(current: cur) ?? cur
        scriptParticleVisible[idx] = v
        // WE IParticleSystem.play/pause/stop — 같은 스크립트가 visible 반환과 **별개로** 방출을 켜고
        // 끈다(실물 3690417937 bubbleclick: `return value` 로 visible 은 늘 true 인 채 클릭 여부로
        // play/pause 만 토글한다). 스텝 직전에 sim 으로 옮겨진다 — 호출부 참조.
        if let playing = engine.layerPlaying { scriptParticleEmissionPaused[idx] = !playing }
        // 조상 상속 하드 게이트(encodeLayer 와 동일 규약) — 스크립트 평가와 play/pause 반영을 모두
        // 끝낸 뒤에 가린다(방출 상태·사이드이펙트는 보존, 드로우만 스킵).
        return v && !particleSystems[idx].hiddenByAncestor
    }

    /// 파티클 시스템 1개의 스냅샷을 빌보드 쿼드로 드로우(additive/translucent).
    func encodeParticle(_ sys: GPUParticleSystem, snapshot: [Particle], into enc: MTLRenderCommandEncoder,
                                device: MTLDevice, camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) {
        // 감사 V07: 알베도 NoInterpolation 은 nearest 변형 우선(미빌드 시 대응 선형 폴터 — 무회귀).
        let linearPipe = sys.blendAdditive ? additivePipeline : translucentPipeline
        let nearPipe = sys.noInterp ? (sys.blendAdditive ? additiveNearestPipeline : translucentNearestPipeline) : nil
        guard !snapshot.isEmpty,
              let pipe = nearPipe ?? linearPipe else { return }
        let verts = particleVertices(snapshot, sys)
        // 트레일은 파티클당 정점 수가 가변(붕괴 시 0) — 빈 버텍스면 드로우 스킵.
        let vertexCount = verts.count / 8
        guard vertexCount > 0, let vbuf = sys.scratch.load(verts, device: device) else { return }
        enc.setRenderPipelineState(pipe)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        var depth = sys.parallaxDepth  // F200: 마우스 시차 가중치(pv_main buffer 2). 기본(1,1)/camOffset=0 은 비트동일.
        enc.setVertexBytes(&depth, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        enc.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        var shake = frameShakeOffset  // camerashake 전역 지터(pv_main buffer 4). 파티클도 함께 흔들림. 비활성=0.
        enc.setVertexBytes(&shake, length: MemoryLayout<SIMD2<Float>>.stride, index: 4)
        enc.setFragmentTexture(sys.texture, index: 0)
        var overbright = sys.overbright  // C4-(ii): pf_main buffer 0(기본 1 — 비트동일).
        enc.setFragmentBytes(&overbright, length: MemoryLayout<Float>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }

    /// REFRACT 스프라이트 드로우(인코더 분할): 현재 enc 를 닫고 acc(씬 컬러)를 스냅샷(blit — 진행 중 타깃은
    /// 샘플 불가, runFrameBufferLayer 와 동일 패턴)한 뒤, .load 로 재개한 인코더에 pf_refract 로 파티클을
    /// 그린다(노멀 오프셋으로 스냅샷 재샘플·곱). 스냅샷/파이프라인 확보 실패 시 identity 파티클 폴백(무크래시).
    /// 반환 인코더로 나머지 drawPlan 지속. 재개 실패만 nil(호출자는 추가 인코딩 없이 commit).
    func runRefractParticle(_ sys: GPUParticleSystem, snapshot: [Particle], acc: MTLTexture, cb: MTLCommandBuffer,
                            ending enc: MTLRenderCommandEncoder, device: MTLDevice,
                            camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) -> MTLRenderCommandEncoder? {
        enc.endEncoding()
        var snap: MTLTexture? = nil
        if let s = pooledOffscreen(acc.width, acc.height, device, bgra: true), let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: acc, to: s); blit.endEncoding(); snap = s
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = acc
        rpd.colorAttachments[0].loadAction = .load
        guard let next = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        // C4-(iii): 머티리얼 블렌드(additive/translucent)에 맞는 REFRACT 파이프라인 변형 선택.
        let refractPipe = sys.blendAdditive ? refractParticlePipelineAdditive : refractParticlePipeline
        if let snap, let pipe = refractPipe {
            encodeRefractParticle(sys, snapshot: snapshot, framebuffer: snap, pipe: pipe, into: next,
                                  device: device, camOffset: &camOffset, aspectScale: &aspectScale)
        } else {
            encodeParticle(sys, snapshot: snapshot, into: next, device: device,
                           camOffset: &camOffset, aspectScale: &aspectScale)  // identity 폴백
        }
        return next
    }

    /// REFRACT 파티클 1개 드로우. encodeParticle 과 동형이나 노멀맵(1)·씬 스냅샷(2)·refract 유니폼을 바인딩하고
    /// pf_refract 파이프라인 사용. 정점(프레임 UV 포함)은 particleVertices 공유 — 노멀은 알베도와 같은 uv 로 샘플.
    func encodeRefractParticle(_ sys: GPUParticleSystem, snapshot: [Particle], framebuffer: MTLTexture,
                               pipe: MTLRenderPipelineState, into enc: MTLRenderCommandEncoder,
                               device: MTLDevice, camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) {
        guard !snapshot.isEmpty, let normal = sys.normalTexture else { return }
        let verts = particleVertices(snapshot, sys)
        let vertexCount = verts.count / 8
        guard vertexCount > 0, let vbuf = sys.scratch.load(verts, device: device) else { return }
        enc.setRenderPipelineState(pipe)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        var depth = sys.parallaxDepth  // F200: 마우스 시차 가중치(pv_main buffer 2). 기본(1,1)/camOffset=0 은 비트동일.
        enc.setVertexBytes(&depth, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        enc.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        var shake = frameShakeOffset  // camerashake 전역 지터(pv_main buffer 4). refract 파티클도 함께 흔들림.
        enc.setVertexBytes(&shake, length: MemoryLayout<SIMD2<Float>>.stride, index: 4)
        enc.setFragmentTexture(sys.texture, index: 0)     // 알베도(g_Texture0)
        enc.setFragmentTexture(normal, index: 1)          // 노멀맵(g_Texture1)
        enc.setFragmentTexture(framebuffer, index: 2)     // 씬 컬러 스냅샷(g_Texture3 = _rt_FullFrameBuffer)
        // C4-(ii): z 슬롯(종전 예약 0) = overbright(기본 1 — 비트동일).
        var params = SIMD4<Float>(sys.refractAmount, sys.normalRG88 ? 1 : 0, sys.overbright, 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }

    /// F740(S-22): 스프라이트 프레임 폴터(p.frame 미지정)의 def.animationmode 소비. sequence = 수명에
    /// 걸쳐 시트를 순차 재생(×sequencemultiplier 회 반복 — rosepetals ×3/ash ×12 실물 배속이 종전엔
    /// frametime 1배 고정이라 1/N 속도로 느려졌다). nil/randomframe 은 종전 frametime gif 폴터(무회귀)
    /// — randomframe 은 시뮬이 스폰 시 p.frame 을 확정(F622)해 애초에 이 경로에 오지 않는다.
    static func particleSheetFrameIndex(age: Float, lifetime: Float, frameTime ft: Float, frameCount fc: Int,
                                        mode: ParticleAnimationMode?, seqMul: Float) -> Int {
        guard fc > 1 else { return 0 }
        if mode == .sequence, lifetime > 1e-4 {
            let m = seqMul.isFinite ? max(0, seqMul) : 1
            guard m > 0 else { return 0 }
            let v = age / lifetime * Float(fc) * m
            // F530-sweep: 유한성만으로는 부족하다 — `sequencemultiplier: 1e19` 처럼 **유한하지만
            // Int 범위를 넘는** 값에서 `Int(v)` 는 클램프가 아니라 트랩이었다(매 프레임 경로).
            // safeFloatToInt(:1766)는 반올림 규약이라 여기 쓸 수 없다(프레임 인덱스는 절사).
            guard let iv = safeInt(Double(v)) else { return 0 }
            return iv % fc
        }
        // 같은 트랩이 frametime 폴터에도 있었다(age 가 비유한이거나 거대하면 사망).
        guard let iv = safeInt(Double(age / max(0.016, ft))) else { return 0 }
        return iv % fc
    }

    /// F530(F-2/F-70): 유한하지만 Int 범위를 넘는 float 의 Int() 변환은 클램프 전에 트랩 — 비신뢰
    /// 패키지(거대 TEXS 프레임/scene.json size) 크래시 방지. ParticleSystem.sheetFrameIndex(:50) 의
    /// Int.max 가드와 동형. 반환은 항상 ≥ floor(비유한/음수 → floor).
    static func safeFloatToInt(_ v: Float, floor: Int) -> Int {
        guard v.isFinite else { return floor }
        let r = v.rounded()
        if r <= 0 { return floor }
        return r >= Float(Int.max) ? Int.max : max(floor, Int(r))
    }

    /// 스프라이트 프레임의 아틀라스 절대 서브렉트(정수 픽셀, 엄격 클램프). 잘못된 TEXS 렉트도 경계 내로
    /// 자른다(추출 validation 크래시 방지). 종전 blit 과 동일 규약 — nearest 추출이 이 정수 렉트를
    /// 텍셀 단위로 재현하도록 rounded→clamp 를 그대로 유지(비-BC bit-identical 근거).
    static func spriteSubrect(atlasW aw: Int, atlasH ah: Int, frame fr: TexImage.TexFrame) -> (x: Int, y: Int, w: Int, h: Int) {
        // F530: Int() 직접 변환 금지 — safeFloatToInt 경유(거대 좌표/크기는 Int.max 까지만 허용).
        let sx = max(0, min(aw - 1, safeFloatToInt(fr.atlasX, floor: 0)))
        let sy = max(0, min(ah - 1, safeFloatToInt(fr.atlasY, floor: 0)))
        let fw = max(1, min(aw - sx, safeFloatToInt(fr.atlasWidth, floor: 1)))
        let fh = max(1, min(ah - sy, safeFloatToInt(fr.atlasHeight, floor: 1)))
        return (sx, sy, fw, fh)
    }

    /// 스프라이트시트 레이어(SPRITESHEET 콤보 + TEXS 다중 프레임)의 **현재 프레임**을 프레임 크기
    /// 텍스처로 추출한다(패스스루 샘플 드로우). 씬 시간 → 프레임 인덱스 → 아틀라스 서브렉트(멀티페이지는
    /// frame.y 에 페이지 오프셋 반영됨)를 프레임크기 dst 로 1:1 복사. 이 텍스처가 하류(효과 체인 src, 또는
    /// 무효과 시 displayTexture)가 되어 효과·컴포지트 쿼드는 시트를 모른 채 프레임 1장만 다룬다 —
    /// 효과+스프라이트가 자연히 맞물린다(코퍼스 37씬 중 17씬이 효과+스프라이트라 이 프레임-추출 구조 유지 필수).
    /// **종전 blit.copy 대체**: blit 은 BC 아틀라스를 CPU rgba8 로 강제했으나(BC→rgba8 blit 무효 → keepFullAtlas
    /// 폴백), f_spriteframe 샘플은 BC 를 GPU 에서 디코드하므로 아틀라스가 네이티브 BC 로 상주할 수 있다(메모리 절감).
    /// dst 가 정확히 프레임크기(fw×fh)라 **nearest** 샘플이 dst 픽셀중심 → 아틀라스 텍셀로 1:1 낙하 →
    /// blit 과 텍셀 동일(비-BC bit-identical). f_spriteframe 은 tint/premultiply 없음 — straight-alpha 규약(§3) 보존.
    /// ponytail: 회전 미지원(코퍼스 회전 프레임 0건) + 프레임 dims 균일 가정(코퍼스 균일).
    func spriteFrameTexture(_ layer: GPULayer, time: Float, device: MTLDevice, cb: MTLCommandBuffer) -> MTLTexture {
        let atlas = layer.texture
        let aw = atlas.width, ah = atlas.height
        let fr = layer.frames[TexImage.spriteFrameIndex(frames: layer.frames, time: time)]
        let (sx, sy, fw, fh) = Self.spriteSubrect(atlasW: aw, atlasH: ah, frame: fr)
        // 파이프라인/버퍼 부재(빌드 실패) 시 원본 아틀라스 폴백(무크래시 — advisor).
        guard let pipe = spriteFramePipeline, let vbuf = effectVertexBuffer,
              let dst = pooledOffscreen(fw, fh, device) else { return atlas }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .dontCare   // 전 픽셀 덮어씀(클리어 불필요)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return atlas }
        enc.setRenderPipelineState(pipe)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setFragmentTexture(atlas, index: 0)
        // 정규화 서브렉트 (u0, v0, du, dv) — f_spriteframe 이 uv=rect.xy+in.uv*rect.zw 로 샘플.
        var rect = SIMD4<Float>(Float(sx) / Float(aw), Float(sy) / Float(ah),
                                Float(fw) / Float(aw), Float(fh) / Float(ah))
        enc.setFragmentBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        return dst
    }

    /// F741(S-13): 텍스트 이펙트 체인 — 래스터 텍스처를 src 로 레이어와 동일한 applyEffect 체인을
    /// 적용(buildDisplayTextures 와 같은 풀/F532 실패 규약). 이펙트 없는 텍스트는 nil → encodeText 가
    /// 원본 래스터를 그대로 사용(무회귀). 인코더 생성 전(cb 에 패스 추가 가능한 시점)에 호출할 것.
    func buildTextDisplayTextures(device: MTLDevice, time: Float, cb: MTLCommandBuffer) -> [MTLTexture?] {
        textLayers.map { t in
            guard let src = t.texture, !t.effects.isEmpty else { return nil }
            var current: MTLTexture = src
            for eff in t.effects {
                guard effectVisible(eff, time: time) else { continue }  // X-⑥: 꺼진 이펙트만 건너뜀
                guard let next = pooledOffscreen(src.width, src.height, device),
                      applyEffect(eff, src: current, dst: next, time: time, cb: cb) else { break }
                current = next
            }
            return current
        }
    }

    /// 효과가 있는 레이어는 원본 텍스처를 첫 src 로 삼아 효과 패스 체인을 적용한 결과 텍스처를, 없으면 원본을 반환.
    /// 스프라이트시트 레이어는 원본 대신 **현재 프레임 텍스처**를 base 로 삼는다(효과 유무 공통 — 프레임
    /// 선택이 효과 체인 앞에 오므로 효과+스프라이트가 정상). 라이브 draw 와 헤드리스 captureFrames 가 공유.
    func buildDisplayTextures(device: MTLDevice, time: Float, cb: MTLCommandBuffer) -> [MTLTexture] {
        beginFramePool()  // 프레임 시작: 모든 풀 텍스처를 재사용 가능 상태로 + 미사용 크기 evict
        // DIRECTDRAW 체인 출력 플래그는 매 프레임 재계산한다(이펙트 visible 스크립트가 프레임마다
        // 마지막 실행 패스를 바꿀 수 있으므로 stale 유지 금지).
        premultipliedDisplayLayers.removeAll(keepingCapacity: true)
        var out: [MTLTexture] = []
        for layer in layers {
            // 비디오 레이어: 프레임별 비디오 텍스처를 base 로(라이브=AVPlayerItemVideoOutput,
            // 헤드리스=AVAssetImageGenerator@scene-time). 디코드 실패면 layer.texture(1×1 clear
            // placeholder) → 비디오만 투명, 형제 레이어는 그대로 합성. 효과가 있으면 아래 체인이 이어 적용.
            // 스프라이트: 현재 프레임 추출(무프레임 레이어는 원본 그대로 — 무회귀).
            let base: MTLTexture
            if let video = layer.video {
                if video.isLive {
                    base = video.liveTexture(device: device) ?? layer.texture
                } else if video.liveStartFailed {
                    // 감사 V06: startLive 실패 레이어 — 정적 폴 백(t=0, 1회 디코드 고정). 종전엔 isLive=false
                    // 만으로 아래 헤드리스 경로를 타 라이브 draw(메인 스레드)가 매 프레임 copyCGImage 동기
                    // 디코드(+ 최초 duration 세마포어 블로킹)를 했다.
                    base = video.staticFallbackTexture(device: device) ?? layer.texture
                } else {
                    base = video.headlessTexture(at: time, device: device) ?? layer.texture
                }
            } else if layer.mediaArtwork != .none {
                // F722: $mediaThumbnail/$mediaPreviousThumbnail — 라이브 아트워크가 base(효과 체인 입력 동일).
                // 미수신(nil) 시 정적 placeholder 폴터(WE 의 썸네일-없음 상태와 동형 — 깜빡임 없음).
                base = (layer.mediaArtwork == .previous ? mediaPreviousArtworkTexture : mediaArtworkTexture)
                    ?? layer.texture
            } else if layer.frames.isEmpty {
                base = layer.texture
            } else {
                base = spriteFrameTexture(layer, time: time, device: device, cb: cb)
            }
            // 컴포지션 레이어의 효과는 사전 계산 불가(src = 그 시점 프레임버퍼 스냅샷) — draw 루프에서 처리.
            if layer.effects.isEmpty || layer.isFrameBuffer { out.append(base); continue }
            // 베이스 복사 불필요: base 를 직접 첫 src 로 사용(아래 루프는 항상 새 dst 로 출력).
            var current = base
            // 실제로 마지막까지 실행된 이펙트의 규약만 남긴다 — 비가시(continue)·인코드 실패(break)로
            // 건너뛴 이펙트는 결과 텍스처를 만들지 않았으므로 합성 규약도 바꾸지 않는다.
            var premultiplied = false
            for eff in layer.effects {
                guard effectVisible(eff, time: time) else { continue }  // X-⑥: 꺼진 이펙트만 건너뜀
                guard let next = pooledOffscreen(layer.texWidth, layer.texHeight, device) else { break }
                // F532: 인코드 실패 시 미기록 next 를 표시 결과로 채택하지 않음(:877 가드와 정합).
                guard applyEffect(eff, src: current, dst: next, time: time, cb: cb) else { break }
                current = next
                premultiplied = eff.outputPremultiplied
            }
            if premultiplied { premultipliedDisplayLayers.insert(layer.uid) }
            out.append(current)
        }
        return out
    }

    /// X-⑥: 이펙트 visible 스크립트 per-frame 재평가 — visibleGate 없으면(대다수) 무비용 true.
    /// 호출부는 false 시 이 이펙트만 건너뛰고(continue, break 아님) 체인의 나머지·현재 텍스처를 보존한다
    /// (레이어/텍스트 propertyScripts["visible"] 과 달리 이펙트 하나가 꺼진다고 레이어 전체가 안 꺼짐).
    func effectVisible(_ eff: EffectGPU, time: Float) -> Bool {
        guard let gate = eff.visibleGate else { return true }
        gate.engine.setRuntime(Double(time))
        gate.current = gate.engine.evaluateBool(current: gate.current) ?? gate.current
        return gate.current
    }

    /// 효과 1개를 src→dst 로 인코드. 반환값 = dst 기록 완료 여부(F532 — 조기 반환 시 dst 미기록을
    /// 호출부가 알 수 있게; 실패 시 호출부는 마지막 유효 텍스처를 유지하도록 break).
    /// fullFrameSnapshot(F-X4): `_rt_FullFrameBuffer` aux 슬롯(godrays/shine COPYBG)에 바인딩할 씬 컬러
    /// 스냅샷 — 이미 acc 스냅샷을 확보한 호출부(runFrameBufferLayer 등)만 넘긴다. nil(기본값)이면 빌드
    /// 시점 흰색 1×1 폴백 그대로(무회귀 — 기존 호출부는 수정 불필요).
    @discardableResult
    func applyEffect(_ eff: EffectGPU, src: MTLTexture, dst: MTLTexture, time: Float, cb: MTLCommandBuffer,
                     fullFrameSnapshot: MTLTexture? = nil) -> Bool {
        switch eff.bind {
        case .handPort(let params, let aux, let audio):
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = dst
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return false }
            enc.setRenderPipelineState(eff.pipeline)
            enc.setVertexBuffer(effectVertexBuffer, offset: 0, index: 0)
            enc.setFragmentTexture(src, index: 0)  // g_Texture0 = framebuffer
            for (i, t) in aux.enumerated() { enc.setFragmentTexture(t, index: i + 1) }  // aux slot i → texture(i+1)
            let buf = [time] + params
            buf.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            // 오디오 응답(현재 스펙트럼 + 효과 오디오 파라미터) → buffer(1). pulse 등 오디오 효과가 소비.
            var audioResp: Float = 0
            if let a = audio {
                audioResp = AudioResponse.compute(left: currentSpectrum.left, right: currentSpectrum.right,
                                                  mode: a.mode, freqMin: a.freqMin, freqMax: a.freqMax,
                                                  bounds: a.bounds, power: a.power, multiply: a.multiply)
            }
            enc.setFragmentBytes(&audioResp, length: MemoryLayout<Float>.stride, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()

        case .translated(var passes, let fboSpecs, let uniqueStore):
            guard let device else { return false }  // mount 이후 항상 존재 — 강제 언랩 제거(teardown 경합 안전)
            // 디버그: WAPLE_MP_TRUNC=n → 앞 n개 패스만 실행(마지막은 dst 로 강제) — 패스별 이분용.
            // env 는 캐시 스냅샷 경유(매 프레임·패스마다 사전 재구성 회피 — SceneRenderer.environmentSnapshot 주석).
            if let t = Self.environmentValue("WAPLE_MP_TRUNC"), let n = Int(t), n > 0, n < passes.count {
                passes = Array(passes.prefix(n))
                let last = passes.removeLast()
                passes.append(TranslatedPass(pipeline: last.pipeline, material: last.material, aux: last.aux,
                                             binds: last.binds, target: nil, usesAudio: last.usesAudio,
                                             texRes: last.texRes, texWrap: last.texWrap, texFilter: last.texFilter,
                                             scripts: last.scripts, fullFrameSlots: last.fullFrameSlots,
                                             swapPair: last.swapPair, mediaArtworkSlots: last.mediaArtworkSlots,
                                             animations: last.animations))
            }
            // 멀티패스: 이름 있는 FBO(다운스케일 또는 X-① 절대 크기)를 풀에서 할당하고, 각 패스를
            // target(fbo|dst)에 순차 실행.
            let baseW = max(1, dst.width), baseH = max(1, dst.height)
            // X-⑤: g_TexelSize/g_TexelSizeHalf = 이펙트 출력(dst) 1텍셀, 체인 전 패스 불변 — 채택된
            // 정본이며 "실측으로 확정"은 아니다(근거 판별력 한계는 GLSLTranslator.assemble 의
            // EngineU/g_TexelSize 주석 참조). 다운스케일 fbo 를 타깃/소스로 쓰는 패스에서도 종전 tex0
            // 근사(4× 과대 오프셋)가 아니라 이 값을 쓴다 — bokeh_blur 12씬 블러 폭은 라이브 A/B
            // 판독 대기(BACKLOG.md 시각 충실도 표).
            let targetRes = SIMD4<Float>(Float(baseW), Float(baseH), Float(baseW), Float(baseH))
            // X-⑧(G-A5-05/G-B2-03): `unique` FBO 는 풀이 아니라 이펙트 전용 저장소에서 온다.
            // dst 크기가 바뀌면 전부 재생성하고 clear 예약도 되살린다.
            // 종전엔 dst 크기가 바뀌면 **전부** 파기했다. 그건 두 가지로 틀렸다:
            //   · `fit:`/`width`/`height` 로 절대 크기를 쓰는 fbo 는 dst 와 무관하다. 유체 시뮬의
            //     속도·압력장이 전부 `fit:256` 인데, 창을 1픽셀만 리사이즈해도 상태가 통째로 날아갔다.
            //     원본은 unique RT 키에 차원 접미사가 없어 리사이즈로 드롭되지 않는다.
            //   · 보유 텍스처의 규격을 한 번도 대조하지 않아서, 한 번 어긋나면 baseW/baseH 가
            //     안 바뀌는 한 영원히 교정되지 않았다.
            // 인덱스별로 (폭, 높이, 포맷)을 대조해 어긋난 것만 버린다.
            if uniqueStore.textures.count != fboSpecs.count {
                // 장부에서 먼저 뺀다 — 아래 대입이 보유분을 통째로 버리기 때문이다.
                for case let t? in uniqueStore.textures { uniqueFBOBytesInUse -= SceneRenderer.uniqueFBOBytes(t) }
                uniqueStore.textures = [MTLTexture?](repeating: nil, count: fboSpecs.count)
                uniqueStore.pendingClear = []
            }
            var fboTex: [MTLTexture] = []
            for (i, spec) in fboSpecs.enumerated() {
                let w = spec.fixedWidth ?? max(1, baseW / spec.scale)
                let h = spec.fixedHeight ?? max(1, baseH / spec.scale)
                if spec.unique {
                    var held = uniqueStore.textures[i]
                    if let t = held, t.width != w || t.height != h || t.pixelFormat != spec.pixelFormat {
                        // 버리는 즉시 장부에서 빼고 슬롯도 비운다 — 아래 재할당이 실패해 return 해도
                        // "장부 = 살아 있는 보유분의 합" 이 유지되게(그리고 새 것을 만들기 전에
                        // 옛 것을 놓아 최대 점유가 겹치지 않게).
                        uniqueFBOBytesInUse -= SceneRenderer.uniqueFBOBytes(t)
                        uniqueStore.textures[i] = nil
                        held = nil          // 규격이 어긋난 보유분은 버리고 다시 만든다
                    }
                    if let t = held {
                        fboTex.append(t)
                    } else {
                        let want = SceneRenderer.uniqueFBOBytes(width: w, height: h, format: spec.pixelFormat)
                        guard uniqueFBOBytesInUse + want <= SceneRenderer.uniqueFBOByteBudget else {
                            // S5-2 **소프트 페일**: 예산을 넘으면 이펙트를 죽이지도(return false) 않고
                            // 크래시하지도 않는다. 같은 크기·같은 포맷을 공유 풀에서 받고, 잃는 것은
                            // **프레임 간 지속**뿐이다(누적/시뮬 상태가 매 프레임 초기화된다).
                            //
                            // `fboSpecs[i].unique` 는 여전히 true 라 아래 타깃 로드액션이 `.load` 다.
                            // 지속이 아니게 된 이상 미정의 내용을 읽으면 안 되므로 **매 프레임**
                            // pendingClear 에 넣어 결정적으로 비운다(pendingClear 는 클리어 루프
                            // 직후 removeAll 되므로 매 프레임 다시 넣는 것이 곧 매 프레임 클리어다).
                            // 저장소에는 넣지 않는다 → swap 의 동치 검사(nil 과 불일치)도 자동으로
                            // 어긋나 교환이 일어나지 않는다(핑퐁 없이 그리기만 한다).
                            guard let t = pooledOffscreen(w, h, device, format: spec.pixelFormat) else { return false }
                            if !uniqueStore.budgetWarned {
                                uniqueStore.budgetWarned = true
                                WapleLog.warn("[Waple] unique FBO 예산 초과 — 공유 풀로 폴백(프레임 간 지속 없음): "
                                    + "\(w)x\(h) fmt=\(spec.pixelFormat.rawValue) "
                                    + "요청 \(want / 1_048_576) MiB · 사용 중 \(uniqueFBOBytesInUse / 1_048_576) MiB "
                                    + "/ 예산 \(SceneRenderer.uniqueFBOByteBudget / 1_048_576) MiB")
                            }
                            uniqueStore.pendingClear.insert(i)
                            fboTex.append(t)
                            continue
                        }
                        guard let t = makeOffscreenFormatted(w, h, device, format: spec.pixelFormat) else { return false }
                        uniqueFBOBytesInUse += want
                        uniqueStore.textures[i] = t
                        // 새로 만든 텍스처의 내용은 미정의다. `clear` 가 선언돼 있으면 그 색으로,
                        // 없으면 투명 검정으로 **1회** 비운다 — 매 프레임이 아니다(누적이 이 버퍼들의
                        // 존재 이유이고, 매 프레임 비우면 시뮬레이션 상태가 매번 사라진다).
                        uniqueStore.pendingClear.insert(i)
                        fboTex.append(t)
                    }
                } else {
                    guard let t = pooledOffscreen(w, h, device, format: spec.pixelFormat) else { return false }
                    fboTex.append(t)
                }
            }
            // 생성 1회 초기화 — 드로우 없는 클리어 전용 렌더 패스.
            for i in uniqueStore.pendingClear.sorted() where i < fboTex.count {
                let c = fboSpecs[i].clearColor ?? SIMD4<Float>(0, 0, 0, 0)
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = fboTex[i]
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].storeAction = .store
                rpd.colorAttachments[0].clearColor = MTLClearColor(red: Double(c.x), green: Double(c.y),
                                                                   blue: Double(c.z), alpha: Double(c.w))
                guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return false }
                enc.endEncoding()
            }
            uniqueStore.pendingClear.removeAll()
            for pass in passes {
                // X-②: command:"swap" — 무비용 포인터 교환(draw 없음). 인덱스 유효성만 재확인(빌드 시
                // fboIndex 로 이미 확정됐지만 fboTex.count 는 fboSpecs.count 와 항상 같아 안전).
                if let sp = pass.swapPair, sp.source < fboTex.count, sp.target < fboTex.count {
                    // **규격이 다르면 교환하지 않는다.** 패스 파이프라인의 컬러 어태치먼트 포맷은
                    // 빌드 시점에 `fboFormats[<매니페스트 인덱스>]` 로 고정되는데, swap 은 그 인덱스가
                    // 담는 텍스처를 바꾼다. 포맷이나 크기가 다른 둘을 맞바꾸면 **다음 프레임에**
                    // 파이프라인-어태치먼트 불일치로 Metal 이 거부한다(검증 끄면 미정의).
                    // 이펙트 전체를 죽이는 대신 이 교환만 버린다.
                    guard sp.source < fboSpecs.count, sp.target < fboSpecs.count,
                          fboSpecs[sp.source].pixelFormat == fboSpecs[sp.target].pixelFormat,
                          fboSpecs[sp.source].scale == fboSpecs[sp.target].scale,
                          fboSpecs[sp.source].fixedWidth == fboSpecs[sp.target].fixedWidth,
                          fboSpecs[sp.source].fixedHeight == fboSpecs[sp.target].fixedHeight else {
                        WapleLog.warn("[Waple] swap 대상의 규격이 달라 건너뛴다(포맷/크기 불일치)")
                        continue
                    }
                    fboTex.swapAt(sp.source, sp.target)
                    // X-⑧: 양쪽이 `unique` 면 **저장소에서도** 맞바꾼다 — 그래야 핑퐁이 프레임을 넘는다.
                    // 종전엔 프레임 로컬 배열만 바꿔서, 다음 프레임에 원래 배치로 되돌아갔다(= 유체
                    // 시뮬이 직전 프레임 자기 출력을 못 읽는다). 한쪽만 unique 인 혼합 교환은
                    // 프레임 안에서만 유효하게 두고 저장소는 건드리지 않는다 — 풀 텍스처를 지속
                    // 슬롯에 넣으면 다음 프레임에 남이 그 텍스처를 체크아웃해 간다.
                    // 저장소 교환은 **플래그가 아니라 동일성**으로 가드한다. 앞선 혼합 교환
                    // (한쪽만 unique)으로 `fboTex[i]` 가 이미 저장소 텍스처가 아닐 수 있는데,
                    // 그때도 플래그만 보고 교환하면 저장소 위상만 한 칸 전진해 핑퐁 패리티가
                    // 프레임마다 어긋난다.
                    if sp.source < uniqueStore.textures.count, sp.target < uniqueStore.textures.count,
                       fboTex[sp.target] === uniqueStore.textures[sp.source],
                       fboTex[sp.source] === uniqueStore.textures[sp.target] {
                        uniqueStore.textures.swapAt(sp.source, sp.target)
                    }
                    continue
                }
                let target = pass.target.map { fboTex[$0] } ?? dst
                // X-⑧: **unique 타깃은 `.load` 다.** 원본은 획득 경로에서 1회만 클리어하고 프레임
                // 렌더 경로는 플래그를 읽지도 않는다. 동봉 이펙트 셰이더에 `discard` 가 0건이라
                // 전 픽셀을 덮어써서 지금은 `.clear` 여도 결과가 같지만, `discard` 를 쓰는 워크샵
                // 이펙트가 누적 버퍼를 타깃으로 잡는 순간 그 영역이 직전 상태 유지가 아니라
                // 투명 검정으로 지워진다. 저작이 지정한 clear RGBA 도 생성 프레임 이후 다시는
                // 안 보이게 된다. 풀 타깃과 dst 는 남의 내용을 물고 오므로 `.clear` 를 유지한다.
                let targetIsUnique = pass.target.map { $0 < fboSpecs.count && fboSpecs[$0].unique } ?? false
                // D4/F6: **풀 타깃의 클리어 색도 저작이 선언한 `clear` RGBA 다.** 종전엔 투명 검정
                // 고정이라, 파서가 읽어 둔 `FBOSpec.clearColor` 가 non-unique 경로에서는 단 한 번도
                // 쓰이지 않았다 — 유일한 소비처인 `uniqueStore.pendingClear` 에 `spec.unique` 분기에서만
                // 인덱스가 들어가기 때문이다(바로 위 할당 루프). 풀 텍스처는 프레임마다 남(다른 이펙트·
                // 다른 프레임)의 내용을 물고 오므로, 이 `.clear` 가 원본의 "획득 시 1회 클리어" 자리를
                // 대신한다(풀 타깃은 매 프레임 재획득이라 둘이 일치한다).
                //
                // 무회귀 근거: `clear` 미선언이면 (0,0,0,0) 이라 종전과 비트 동일이고, 타깃 없는 패스
                // (효과 출력=dst)도 선언이 있을 수 없어 (0,0,0,0) 이다. unique 타깃은 `.load` 라 이 색을
                // 애초에 읽지 않는다(위 "생성 1회" 규약 불변). 동봉 자산의 `clear` 보유 fbo 선언 12건은
                // 전건 unique 라(EffectFBOFormatTests 가 고정) 실측 동작 변화 0 — non-unique fbo 에
                // `clear` 를 선언한 워크샵 이펙트에서만 달라진다.
                var targetClear = SIMD4<Float>(0, 0, 0, 0)
                if let ti = pass.target, ti < fboSpecs.count, let c = fboSpecs[ti].clearColor { targetClear = c }
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = target
                rpd.colorAttachments[0].loadAction = targetIsUnique ? .load : .clear
                rpd.colorAttachments[0].clearColor = MTLClearColor(red: Double(targetClear.x),
                                                                   green: Double(targetClear.y),
                                                                   blue: Double(targetClear.z),
                                                                   alpha: Double(targetClear.w))
                guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return false }
                enc.setRenderPipelineState(pass.pipeline)
                // 변환본 규약: 인터리브드 쿼드 buffer(4), p buffer(0)·EngineU buffer(1) 는 vert+frag 양쪽.
                enc.setVertexBuffer(effectQuadInterleaved, offset: 0, index: 4)
                if !pass.material.isEmpty {
                    var mat = pass.material
                    // 상수 프로퍼티 스크립트: update(현재값) → 슬롯 갱신(컬러 사이클 등 시간 함수).
                    for sc in pass.scripts {
                        sc.engine.setRuntime(Double(time))
                        let cur = mat[sc.slot]
                        if let v = sc.engine.evaluateVec(current: [cur.x, cur.y, cur.z]) {
                            if v.count >= 3 { mat[sc.slot] = SIMD4(v[0], v[1], v[2], cur.w) }
                            else if v.count == 1 { mat[sc.slot] = SIMD4(v[0], cur.y, cur.z, cur.w) }
                        }
                    }
                    // X-⑦: constantshadervalues 의 {animation:{...}} 키프레임 — 레이어 origin/scale/alpha
                    // 애니와 동일 평가기(PropertyAnimation.value)로 슬롯별 성분을 갱신. base = 현재(정적)값,
                    // relative 애니는 그 base 에 가산. 컴포넌트 수는 tracks.count(선언된 c0..c2 만).
                    for a in pass.animations {
                        let cur = mat[a.slot]
                        let base: [Float] = [cur.x, cur.y, cur.z, cur.w]
                        var v = cur
                        for comp in 0..<min(a.anim.tracks.count, 4) {
                            v[comp] = a.anim.value(component: comp, atTime: time, base: base[comp])
                        }
                        mat[a.slot] = v
                    }
                    mat.withUnsafeBytes {
                        enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
                        enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
                    }
                }
                let eng = engineUniform(time: time, texRes: runtimeTexRes(for: pass, src: src, fboTex: fboTex),
                                        texWrap: pass.texWrap, texFilter: pass.texFilter, targetRes: targetRes)
                eng.withUnsafeBytes {
                    enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                    enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
                }
                for (slot, source) in pass.binds {
                    enc.setFragmentTexture(source == -1 ? src : fboTex[source], index: slot)
                }
                for (slot, tex) in pass.aux { enc.setFragmentTexture(tex, index: slot) }
                // F-X4: `_rt_FullFrameBuffer` 슬롯 — 위 aux 루프가 이미 흰색 1×1 로 채웠으므로, 실제
                // 씬 스냅샷이 있으면 여기서 덮어써 배경을 바인드(godrays/shine COPYBG). 없으면 무회귀.
                if let snap = fullFrameSnapshot {
                    for slot in pass.fullFrameSlots where slot < 128 { enc.setFragmentTexture(snap, index: slot) }
                }
                // X-③: usertextures 시스템 키($mediaThumbnail/$mediaPreviousThumbnail) 슬롯 — 위 aux 루프가
                // 이미 흰색 1×1 로 채웠으므로, 라이브 아트워크가 있으면 여기서 덮어쓴다(레이어 base 의 F722
                // 배선과 동일 소스: self.mediaArtworkTexture/mediaPreviousArtworkTexture). 미수신(nil)이면 무회귀.
                for (slot, previous) in pass.mediaArtworkSlots where slot < 128 {
                    if let tex = previous ? mediaPreviousArtworkTexture : mediaArtworkTexture {
                        enc.setFragmentTexture(tex, index: slot)
                    }
                }
                if pass.usesAudio {  // 스펙트럼 버퍼(16:2/3, 32:5/6, 64:7/8).
                    func bind(_ arr: [Float], _ idx: Int) {
                        arr.withUnsafeBytes {
                            enc.setVertexBytes($0.baseAddress!, length: $0.count, index: idx)
                            enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: idx)
                        }
                    }
                    bind(currentSpectrum.left, 2); bind(currentSpectrum.right, 3)
                    bind(left32, 5); bind(right32, 6)
                    bind(left64, 7); bind(right64, 8)
                }
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.endEncoding()
            }
        }
        return true
    }

    /// bgra8 타겟 readback(BGRA→RGBA 스왑) → PNG 저장. 성공 여부 반환.
    func writeFramePNG(_ target: MTLTexture, width: Int, height: Int, to url: URL) -> Bool {
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        raw.withUnsafeMutableBytes { ptr in
            target.getBytes(ptr.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        for j in stride(from: 0, to: raw.count, by: 4) { raw.swapAt(j, j + 2) }
        guard let png = OffscreenCapture.png(rgba: raw, width: width, height: height) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
