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
    /// EngineU 버퍼: mvp(항등) + timeAndPad(time,0,0,0) + texRes[8](슬롯별 실제 dims).
    func engineUniform(time: Float, texRes: [SIMD4<Float>]) -> [Float] {
        var e = [Float](repeating: 0, count: 16 + 4 + 32)
        e[0] = 1; e[5] = 1; e[10] = 1; e[15] = 1   // identity mvp
        e[16] = time; e[17] = pointerUV.x; e[18] = pointerUV.y  // timeAndPad = (time, pointerX, pointerY, 0)
        for n in 0..<8 {
            let r = n < texRes.count ? texRes[n] : SIMD4<Float>(1, 1, 1, 1)
            let o = 20 + n * 4
            e[o] = r.x; e[o + 1] = r.y; e[o + 2] = r.z; e[o + 3] = r.w
        }
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
    /// sprite = 빌보드 쿼드. trail = 위치 히스토리 폴리라인을 두께 있는 리본(삼각 스트립)으로.
    func particleVertices(_ snapshot: [Particle], _ sys: GPUParticleSystem) -> [Float] {
        var verts: [Float] = []
        verts.reserveCapacity(snapshot.count * (sys.isTrail ? 200 : 48))
        func toNDC(_ x: Float, _ y: Float) -> (Float, Float) { let p = sceneToNDC(x, y); return (p.x, p.y) }
        func appendQuad(_ p: Particle) {
            let wx = sys.origin.x + sys.scale.x * p.pos.x
            let wy = sys.origin.y - sys.scale.y * p.pos.y
            let sizePx = p.size * sys.scale.x
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
                    let ft = max(0.016, sys.frames[0].time)
                    idx = Int(p.age / ft) % fc
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
            let hw = sizePx * 0.5, hh = sizePx * ratio * 0.5
            let ca = cos(p.rotation.z), sa = sin(p.rotation.z)
            func ndc(_ lx: Float, _ ly: Float) -> (Float, Float) {
                return toNDC(wx + lx * ca - ly * sa, wy + lx * sa + ly * ca)
            }
            let tl = ndc(-hw, -hh), tr = ndc(hw, -hh), br = ndc(hw, hh), bl = ndc(-hw, hh)
            let r = p.color.x, g = p.color.y, b = p.color.z, al = p.alpha
            func v(_ pt: (Float, Float), _ u: (Float, Float)) {
                verts.append(contentsOf: [pt.0, pt.1, u.0, u.1, r, g, b, al])
            }
            v(tl, uv[0]); v(tr, uv[1]); v(br, uv[2])
            v(tl, uv[0]); v(br, uv[2]); v(bl, uv[3])
        }
        for p in snapshot {
            if sys.isTrail {
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
        for q in h { pts.append((sys.origin.x + sys.scale.x * q.x, sys.origin.y - sys.scale.y * q.y)) }
        // 유효 스팬 판정: bbox 대각선이 1px 미만이면 붕괴 → 쿼드.
        guard pts.count >= 2 else { return false }
        var minX = pts[0].0, maxX = pts[0].0, minY = pts[0].1, maxY = pts[0].1
        for pt in pts { minX = min(minX, pt.0); maxX = max(maxX, pt.0); minY = min(minY, pt.1); maxY = max(maxY, pt.1) }
        if (maxX - minX) + (maxY - minY) < 1 { return false }

        let n = pts.count
        let hw = max(0.5, p.size * sys.scale.x * 0.5)  // 리본 반폭(px)
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
            edges.append((A, B, u, p.alpha * u))          // tail(u=0)=투명 → head=불투명
        }
        func push(_ pt: (Float, Float), _ u: Float, _ vv: Float, _ al: Float) {
            verts.append(contentsOf: [pt.0, pt.1, u, vv, r, g, b, al])
        }
        // 스프라이트시트: 선택 프레임 렉트로 u(길이)/v(가로) 재매핑(discharge rope 등 —
        // 미적용 시 시트 전 프레임이 리본에 통째로 늘어난다).
        var fu0: Float = 0, fu1: Float = 1, fv0: Float = 0, fv1: Float = 1
        if !sys.frames.isEmpty {
            let fc = sys.frames.count
            let idx = p.frame >= 0
                ? sheetFrameIndex(sequence: p.frame, frameCount: fc, mirror: sys.mapSeqMirror)
                : Int(p.age / max(0.016, sys.frames[0].time)) % fc
            let fr = sys.frames[max(0, min(fc - 1, idx))]
            let tw = Float(max(1, sys.texture.width)), th = Float(max(1, sys.texture.height))
            // 서브렉트는 atlas*(회전 프레임의 실제 extent). ponytail: 리본은 rotationQuarters 미반영 —
            // spritetrail/rope 가 회전 아틀라스를 쓰는 실물이 코퍼스에 없어 보류(발견 시 코너 회전 이식).
            fu0 = fr.atlasX / tw; fu1 = min(1, (fr.atlasX + fr.atlasWidth) / tw)
            fv0 = fr.atlasY / th; fv1 = min(1, (fr.atlasY + fr.atlasHeight) / th)
        }
        for i in 0..<(n - 1) {
            let e0 = edges[i], e1 = edges[i + 1]
            // 쿼드 (A0,B0,B1,A1) → 삼각 2개. u 는 길이, v 는 가로(0/1).
            func U(_ u: Float) -> Float { fu0 + (fu1 - fu0) * u }
            push(e0.a, U(e0.u), fv0, e0.alpha); push(e0.bEdge, U(e0.u), fv1, e0.alpha); push(e1.bEdge, U(e1.u), fv1, e1.alpha)
            push(e0.a, U(e0.u), fv0, e0.alpha); push(e1.bEdge, U(e1.u), fv1, e1.alpha); push(e1.a, U(e1.u), fv0, e1.alpha)
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

    func pooledOffscreen(_ w: Int, _ h: Int, _ device: MTLDevice, bgra: Bool = false) -> MTLTexture? {
        let key = "\(bgra ? "b" : "")\(max(w,1))x\(max(h,1))"
        let idx = poolCheckout[key, default: 0]
        if idx < (texturePool[key]?.count ?? 0) {
            poolCheckout[key] = idx + 1
            return texturePool[key]![idx]
        }
        guard let t = bgra ? makeOffscreenBGRA(w, h, device) : makeOffscreen(w, h, device) else { return nil }
        texturePool[key, default: []].append(t)
        poolCheckout[key] = idx + 1
        return t
    }

    /// 컴포지션(_rt_) 레이어 실행: 현재 encoder 를 닫고, acc 스냅샷(blit — 진행 중 타깃은 샘플 불가)에
    /// 레이어의 효과 체인을 적용한 뒤, 새 encoder(.load)로 레이어 지오메트리에 결과를 그린다.
    /// 반환된 encoder 로 나머지 drawPlan 을 계속한다. 실패 시 기존 흐름 유지 위해 새 encoder 만 연다.
    func runFrameBufferLayer(_ layer: GPULayer, acc: MTLTexture, cb: MTLCommandBuffer,
                                     ending enc: MTLRenderCommandEncoder, device: MTLDevice, time: Float,
                                     camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) -> MTLRenderCommandEncoder? {
        enc.endEncoding()
        var srcTex: MTLTexture? = nil
        if let snap = pooledOffscreen(acc.width, acc.height, device, bgra: true),
           let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: acc, to: snap)
            blit.endEncoding()
            var current: MTLTexture = snap
            for eff in layer.effects {
                guard let next = pooledOffscreen(acc.width, acc.height, device) else { break }
                applyEffect(eff, src: current, dst: next, time: time, cb: cb)
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
            encodeLayer(layer, texture: srcTex, into: next, camOffset: &camOffset, aspectScale: &aspectScale)
        }
        return next
    }

    /// colorBlendMode 레이어: acc 스냅샷(dst) 확보 → f_blend 로 레이어 쿼드 드로우 → 새 인코더 반환.
    /// runFrameBufferLayer 와 같은 인코더 분할 패턴(효과 체인은 displayTextures 에서 이미 처리 — 미실행).
    func runBlendModeLayer(_ layer: GPULayer, texture: MTLTexture, acc: MTLTexture, cb: MTLCommandBuffer,
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
        encodeLayer(layer, texture: texture, into: next, camOffset: &camOffset, aspectScale: &aspectScale,
                    time: time, device: device, blendSnapshot: snapshot)
        return next
    }

    /// 씬 픽셀 좌표(좌상단 원점, y-down) → NDC(-1..1, y-up). px→NDC 변환의 단일 정의 —
    /// 파티클/리본/쿼드/퍼펫/텍스트 경로가 공유(동일식 5중 중복 제거, 2026-07-04).
    @inline(__always)
    static func pxToNDC(_ x: Float, _ y: Float, projW: Float, projH: Float) -> SIMD2<Float> {
        SIMD2(x / projW * 2 - 1, 1 - y / projH * 2)
    }

    /// pxToNDC 의 인스턴스 프로젝션 크기(projW/projH) 버전.
    @inline(__always)
    func sceneToNDC(_ x: Float, _ y: Float) -> SIMD2<Float> {
        Self.pxToNDC(x, y, projW: projW, projH: projH)
    }

    /// 씬 픽셀 좌표(좌상단 원점, Y-down 가정) → NDC. Y-flip은 Task 7에서 실측 보정.
    func quadVertices(layer: SceneLayer, projW: Float, projH: Float) -> [SIMD4<Float>] {
        quadVertices(origin: layer.origin, size: layer.size, scale: layer.scale, angleZ: layer.angleZ,
                     projW: projW, projH: projH)
    }

    /// 명시 파라미터 변형 — 프로퍼티 애니메이션의 per-frame 재계산용.
    func quadVertices(origin: Vec2, size: Vec2, scale: Vec2, angleZ: Float,
                              projW: Float, projH: Float) -> [SIMD4<Float>] {
        let hw = size.x * scale.x * 0.5
        let hh = size.y * scale.y * 0.5
        let a = angleZ * .pi / 180
        let ca = cos(a), sa = sin(a)
        func corner(_ lx: Float, _ ly: Float) -> SIMD2<Float> {
            let rx = lx * ca - ly * sa, ry = lx * sa + ly * ca
            return SIMD2<Float>(origin.x + rx, origin.y + ry)
        }
        func ndc(_ p: SIMD2<Float>) -> SIMD2<Float> { Self.pxToNDC(p.x, p.y, projW: projW, projH: projH) }
        let tl = ndc(corner(-hw, -hh)), tr = ndc(corner(hw, -hh))
        let br = ndc(corner(hw, hh)), bl = ndc(corner(-hw, hh))
        // uv: TL(0,0) TR(1,0) BR(1,1) BL(0,1)
        return [
            SIMD4<Float>(tl.x, tl.y, 0, 0), SIMD4<Float>(tr.x, tr.y, 1, 0), SIMD4<Float>(br.x, br.y, 1, 1),
            SIMD4<Float>(tl.x, tl.y, 0, 0), SIMD4<Float>(br.x, br.y, 1, 1), SIMD4<Float>(bl.x, bl.y, 0, 1),
        ]
    }

    /// 퍼펫 스킨 정점 → NDC 삼각형 리스트(quadVertices 와 동일 규약: 씬 픽셀 y-down, uv 그대로).
    /// 메시 좌표는 레이어 로컬 픽셀(원점 중심)·**y-up**(실측: 2809885105 프리뷰 대비 반전 확인) —
    /// y 부호 반전 후 origin/scale/angleZ 적용, NDC 변환.
    static func puppetVertices(model: PuppetModel, positions: [SIMD3<Float>],
                               origin: Vec2, scale: Vec2, angleZ: Float,
                               projW: Float, projH: Float) -> [SIMD4<Float>] {
        let a = angleZ * .pi / 180
        let ca = cos(a), sa = sin(a)
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(model.indices.count)
        for idx in model.indices {
            let i = Int(idx)
            guard i < positions.count else { continue }
            let p = positions[i]
            let lx = p.x * scale.x, ly = -p.y * scale.y
            let sx = origin.x + lx * ca - ly * sa
            let sy = origin.y + lx * sa + ly * ca
            let ndc = pxToNDC(sx, sy, projW: projW, projH: projH)
            out.append(SIMD4<Float>(ndc.x, ndc.y, model.vertices[i].uv.x, model.vertices[i].uv.y))
        }
        return out
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
                                particleSnapshot: (Int) -> [Particle],
                                camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) -> MTLRenderCommandEncoder? {
        var enc = enc
        for item in drawPlan {
            switch item.kind {
            case .particle:
                encodeParticle(particleSystems[item.idx], snapshot: particleSnapshot(item.idx), into: enc,
                               device: device, camOffset: &camOffset, aspectScale: &aspectScale)
            case .text:
                encodeText(textLayers[item.idx], into: enc, camOffset: &camOffset, aspectScale: &aspectScale)
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
            case .layer:
                encodeLayer(layers[item.idx], texture: displayTextures[item.idx], into: enc,
                            camOffset: &camOffset, aspectScale: &aspectScale, time: time, device: device)
            }
        }
        return enc
    }

    /// 이미지 레이어 1개 드로우(메인 컴포지트 파이프라인). time/device 는 프로퍼티 애니메이션 평가용
    /// (def 있는 레이어만 per-frame 재계산 — origin/scale/angles → 쿼드, alpha/color → tint).
    func encodeLayer(_ layer: GPULayer, texture: MTLTexture, into enc: MTLRenderCommandEncoder,
                             camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>,
                             time: Float = 0, device: MTLDevice? = nil,
                             blendSnapshot: MTLTexture? = nil) {
        guard let pipeline else { return }
        var tint = layer.tint
        var vbuf = layer.vertexBuffer
        if let def = layer.def, let device {
            func animValue(_ key: String, _ comp: Int, _ base: Float) -> Float {
                def.animations[key]?.value(component: comp, atTime: time, base: base) ?? base
            }
            let origin = Vec2(x: animValue("origin", 0, def.origin.x), y: animValue("origin", 1, def.origin.y))
            let scale = Vec2(x: animValue("scale", 0, def.scale.x), y: animValue("scale", 1, def.scale.y))
            let angle = animValue("angles", 2, def.angleZ)
            if def.animations["origin"] != nil || def.animations["scale"] != nil || def.animations["angles"] != nil {
                let verts = quadVertices(origin: origin, size: def.size, scale: scale, angleZ: angle,
                                         projW: projW, projH: projH)
                if let b = layer.scratchQuad.load(verts, device: device) {
                    vbuf = b
                }
            }
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
        // visible 스크립트 평가값(또는 정적 초기값)이 거짓 → draw 스킵(레이어는 유지 — 런타임 토글 가능).
        if !(scriptVisible[layer.uid] ?? layer.initialVisible) { return }
        var vertexCount = 6
        // 퍼펫: per-frame CPU 스키닝 → 메시 삼각형 리스트로 쿼드 대체.
        if let pm = layer.puppet, let def = layer.def, let device {
            let mats = PuppetPose.skinMatrices(model: pm, animation: 0, time: time)
            let pos = PuppetPose.skinnedPositions(model: pm, matrices: mats)
            let verts = SceneRenderer.puppetVertices(model: pm, positions: pos,
                                                     origin: def.origin, scale: def.scale, angleZ: def.angleZ,
                                                     projW: projW, projH: projH)
            if !verts.isEmpty, let b = layer.scratchSkin.load(verts, device: device) {
                vbuf = b
                vertexCount = verts.count
            }
        }
        var depth = layer.parallaxDepth
        // colorBlendMode: 스냅샷 dst 대비 셰이더 블렌드(f_blend). 스냅샷 없으면 일반 합성 폴백.
        if let blendSnapshot, let blendPipeline, layer.colorBlendMode != 0 {
            enc.setRenderPipelineState(blendPipeline)
            enc.setFragmentTexture(blendSnapshot, index: 1)
            var mode = Int32(layer.colorBlendMode)
            enc.setFragmentBytes(&mode, length: MemoryLayout<Int32>.stride, index: 1)
        } else {
            enc.setRenderPipelineState(pipeline)
        }
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.setVertexBytes(&depth, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        enc.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }

    /// 스크립트 텍스트 초당 재평가(시계 등). 변경 시에만 재래스터.
    func refreshScriptedTexts(device: MTLDevice, time: Float) {
        guard hasScriptedText else { return }
        let sec = Int(CFAbsoluteTimeGetCurrent())
        guard sec != lastTextRefreshSecond else { return }
        lastTextRefreshSecond = sec
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

    /// 텍스트 1개 드로우(메인 컴포지트 파이프라인, parallaxDepth=1).
    func encodeText(_ t: GPUText, into enc: MTLRenderCommandEncoder,
                            camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) {
        guard let pipeline, let tex = t.texture, let vbuf = t.vertexBuffer else { return }
        var tint = t.tint
        var depth = SIMD2<Float>(1, 1)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.setVertexBytes(&depth, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        enc.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// 파티클 시스템 1개의 스냅샷을 빌보드 쿼드로 드로우(additive/translucent).
    func encodeParticle(_ sys: GPUParticleSystem, snapshot: [Particle], into enc: MTLRenderCommandEncoder,
                                device: MTLDevice, camOffset: inout SIMD2<Float>, aspectScale: inout SIMD2<Float>) {
        guard !snapshot.isEmpty,
              let pipe = sys.blendAdditive ? additivePipeline : translucentPipeline else { return }
        let verts = particleVertices(snapshot, sys)
        // 트레일은 파티클당 정점 수가 가변(붕괴 시 0) — 빈 버텍스면 드로우 스킵.
        let vertexCount = verts.count / 8
        guard vertexCount > 0, let vbuf = sys.scratch.load(verts, device: device) else { return }
        enc.setRenderPipelineState(pipe)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.setVertexBytes(&aspectScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        enc.setFragmentTexture(sys.texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }

    /// 효과가 있는 레이어는 원본 텍스처를 첫 src 로 삼아 효과 패스 체인을 적용한 결과 텍스처를, 없으면 원본을 반환.
    /// 라이브 draw 와 헤드리스 captureFrames 가 공유.
    func buildDisplayTextures(device: MTLDevice, queue: MTLCommandQueue, time: Float, cb: MTLCommandBuffer) -> [MTLTexture] {
        beginFramePool()  // 프레임 시작: 모든 풀 텍스처를 재사용 가능 상태로 + 미사용 크기 evict
        var out: [MTLTexture] = []
        for layer in layers {
            // 컴포지션 레이어의 효과는 사전 계산 불가(src = 그 시점 프레임버퍼 스냅샷) — draw 루프에서 처리.
            if layer.effects.isEmpty || layer.isFrameBuffer { out.append(layer.texture); continue }
            // 베이스 복사 불필요: 원본 텍스처를 직접 첫 src 로 사용(아래 루프는 항상 새 dst 로 출력).
            var current = layer.texture
            for eff in layer.effects {
                guard let next = pooledOffscreen(layer.texWidth, layer.texHeight, device) else { break }
                applyEffect(eff, src: current, dst: next, time: time, cb: cb)
                current = next
            }
            out.append(current)
        }
        return out
    }

    func applyEffect(_ eff: EffectGPU, src: MTLTexture, dst: MTLTexture, time: Float, cb: MTLCommandBuffer) {
        switch eff.bind {
        case .handPort(let params, let aux, let audio):
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = dst
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
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

        case .translated(var passes, let fboScales):
            guard let device else { return }  // mount 이후 항상 존재 — 강제 언랩 제거(teardown 경합 안전)
            // 디버그: WAPLE_MP_TRUNC=n → 앞 n개 패스만 실행(마지막은 dst 로 강제) — 패스별 이분용.
            if let t = ProcessInfo.processInfo.environment["WAPLE_MP_TRUNC"], let n = Int(t), n > 0, n < passes.count {
                passes = Array(passes.prefix(n))
                let last = passes.removeLast()
                passes.append(TranslatedPass(pipeline: last.pipeline, material: last.material, aux: last.aux,
                                             binds: last.binds, target: nil, usesAudio: last.usesAudio,
                                             texRes: last.texRes, scripts: last.scripts))
            }
            // 멀티패스: 이름 있는 FBO(다운스케일)를 풀에서 할당하고, 각 패스를 target(fbo|dst)에 순차 실행.
            let baseW = max(1, dst.width), baseH = max(1, dst.height)
            var fboTex: [MTLTexture] = []
            for s in fboScales {
                guard let t = pooledOffscreen(max(1, baseW / s), max(1, baseH / s), device) else { return }
                fboTex.append(t)
            }
            for pass in passes {
                let target = pass.target.map { fboTex[$0] } ?? dst
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = target
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
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
                    mat.withUnsafeBytes {
                        enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
                        enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
                    }
                }
                let eng = engineUniform(time: time, texRes: runtimeTexRes(for: pass, src: src, fboTex: fboTex))
                eng.withUnsafeBytes {
                    enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                    enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
                }
                for (slot, source) in pass.binds {
                    enc.setFragmentTexture(source == -1 ? src : fboTex[source], index: slot)
                }
                for (slot, tex) in pass.aux { enc.setFragmentTexture(tex, index: slot) }
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
