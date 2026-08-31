import Foundation
import simd

/// 커서 히트테스트의 **순수 기하** — WE `wallpaper64.exe` 실측을 그대로 옮긴 것.
///
/// 실물 경로(2026-08-21 재확인, imagebase `0x140000000`):
/// `sub_140189e10`(커서 이벤트 디스패처, 프레임당 1회) → 오브젝트별 `sub_14019dbb0`(쿼드 구성)
/// → `sub_14019d5a0`(광선 × 평행사변형 교차, Möller–Trumbore 변형).
///
/// `sub_14019dbb0` 이 만드는 것(`0x14019dc85`–`0x14019dee9`):
/// ```
/// M      = obj->vtbl[0x80]()            ; 오브젝트 4×4(row-vector 규약)
/// if (obj->vtbl[0xa8](&E)) M = M · E    ; 선택적 추가 변환(있으면 곱한다)
/// t      = M.row3.xyz                   ; 중심(평행이동)
/// if (parallaxOffset) t += parallaxOffset   ; 0x14019dd79 — **쿼드 중심**에 더한다(광선이 아니다)
/// sz     = obj[0x2f0]                   ; (width, height)
/// X      = M.row0 * sz.x                ; 폭 벡터(회전·스케일 포함)
/// Y      = M.row1 * sz.y                ; 높이 벡터
/// c0 = t − 0.5·X − 0.5·Y                ; 0x140493000 = (-0.5)×4
/// c1 = t + 0.5·X − 0.5·Y                ; 0x140492dd0 = (+0.5)×4
/// c2 = t − 0.5·X + 0.5·Y
/// hit = sub_14019d5a0(rayOrigin, rayDir, c0, c1, c2, &uv, &tHit) && tHit >= 0
/// out = (uv.x · sz.x, (1 − uv.y) · sz.y, 0)     ; 0x14019df2f–0x14019df5f — 로컬 픽셀, y 뒤집힘
/// ```
/// **코너가 3개뿐이다.** `sub_14019d5a0` 은 `e1 = c1 − c0`(= X) · `e2 = c2 − c0`(= Y) 로 만든
/// **평행사변형**을 검사한다 — `u`·`v` 를 각각 `[0, det]` 와 비교할 뿐 `u + v ≤ det`(삼각형) 검사가
/// 없다(`0x14019d6fa`·`0x14019d761`). 따라서 판정은 "회전된 사각형 안"이다.
/// 퇴화(`|det| ≤ FLT_EPSILON`)면 `uv = (0,0)`, `t = −1`, false 를 돌려준다(`0x14019d891`).
///
/// 정사영(2D) 씬에서 광선이 z 축과 나란하면 이 3D 검사는 아래 2D 크래머 공식과 **대수적으로 동일**하다
/// (유도는 `docs/re/pointer-interaction.md` §4.3).
///
/// 여기 담지 **않은** 것: 알파 임계(실물도 없다 — 텍스처를 한 번도 샘플링하지 않는다),
/// `config.fullscreen` 지름길(`obj[0x304]` bit1 → 항상 히트), 퍼펫(kind 5)의 뼈 히트박스.
public enum PointerHit {
    /// `sub_14019d5a0` 의 퇴화 판정 상수 — `0x1404925e0` = `FLT_EPSILON`(양)·`0x1404929a4`(음).
    public static let determinantEpsilon: Float = 1.1920929e-7

    /// 씬 픽셀 공간의 회전된 쿼드. `axisX`/`axisY` 는 **반너비가 아니라 변 벡터 전체**다
    /// (실물 `X = M.row0 · size.x` 와 같은 규약 — `contains` 가 ±0.5 를 자기가 붙인다).
    public struct Quad: Equatable {
        public var center: SIMD2<Float>
        public var axisX: SIMD2<Float>
        public var axisY: SIMD2<Float>

        public init(center: SIMD2<Float>, axisX: SIMD2<Float>, axisY: SIMD2<Float>) {
            self.center = center
            self.axisX = axisX
            self.axisY = axisY
        }

        /// 2D 레이어 쿼드. `center` 는 **정렬 보정이 끝난 유효 중심**을 넘겨라
        /// (`SceneRenderer.alignedCenter` 의 결과 — WE 는 그 보정을 오브젝트 4×4 안에 갖고 있다).
        /// 축 규약은 `SceneRendererFrameEncoder.quadVertices` 의 `corner(lx,ly)` 와 동일하다:
        /// `corner = center + (lx·cos − ly·sin, lx·sin + ly·cos)`.
        /// **부호를 절대 지우지 마라** — 음수 `scale` 은 축을 뒤집고, 평행사변형 검사는 `det < 0`
        /// 분기(`0x14019d779`)로 그걸 그대로 받아들인다(실물과 동일).
        public static func layer(center: SIMD2<Float>, size: SIMD2<Float>,
                                 scale: SIMD2<Float>, angleZ: Float) -> Quad {
            let ca = cos(angleZ), sa = sin(angleZ)
            let w = size.x * scale.x, h = size.y * scale.y
            return Quad(center: center,
                        axisX: SIMD2(w * ca, w * sa),
                        axisY: SIMD2(-h * sa, h * ca))
        }

        public func translated(by d: SIMD2<Float>) -> Quad {
            Quad(center: center + d, axisX: axisX, axisY: axisY)
        }

        /// `c0`(−X−Y) · `c1`(+X−Y) · `c2`(−X+Y) · `c3`(+X+Y) 순. 실물은 `c0..c2` 만 만든다.
        public var corners: [SIMD2<Float>] {
            let hx = axisX * 0.5, hy = axisY * 0.5
            return [center - hx - hy, center + hx - hy, center - hx + hy, center + hx + hy]
        }
    }

    /// 원근 투영과 near/far 클립이 끝난 볼록 다각형(씬 픽셀, 순환 꼭짓점 순서).
    /// x/y 회전이 있는 image/text 평면은 투영 뒤 사다리꼴이고, 클립 면을 가로지르면 3–6각형이
    /// 될 수 있어 평행사변형 `Quad`로는 표현할 수 없다. 렌더러가 triangle fan의 외곽 순서를 보존해 넣는다.
    public struct ConvexPolygon: Equatable {
        public var vertices: [SIMD2<Float>]

        public init(vertices: [SIMD2<Float>]) { self.vertices = vertices }

        /// 볼록 다각형 꼭짓점 평균. 항상 내부(또는 경계)에 있으므로 테스트/진단 클릭 좌표로 안전하다.
        public var center: SIMD2<Float> {
            guard !vertices.isEmpty else { return .zero }
            return vertices.reduce(.zero, +) / Float(vertices.count)
        }

        public func translated(by d: SIMD2<Float>) -> ConvexPolygon {
            ConvexPolygon(vertices: vertices.map { $0 + d })
        }
    }

    /// 쿼드 로컬 UV(`c0` 기준, `axisX` 방향 `u`, `axisY` 방향 `v`). 경계 밖이거나 퇴화면 `nil`.
    /// 실물 `sub_14019d5a0` 의 `u = (T·(D×e2))/det` · `v = ((T×e1)·D)/det` 를 광선이 평면 법선과
    /// 나란한 2D 경우로 축약한 것(크래머). 경계는 **포함**이다 — 실물이 `jbe`/`jae` 로 등호를 살린다.
    public static func localUV(_ quad: Quad, _ point: SIMD2<Float>) -> SIMD2<Float>? {
        let x = quad.axisX, y = quad.axisY
        let det = x.x * y.y - x.y * y.x
        guard abs(det) > determinantEpsilon else { return nil }
        let t = point - (quad.center - x * 0.5 - y * 0.5)   // T = P − c0
        let u = (t.x * y.y - t.y * y.x) / det
        let v = (x.x * t.y - x.y * t.x) / det
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        return SIMD2(u, v)
    }

    /// 회전을 존중하는 히트 판정. 종전 `SceneRenderer.layerHitRect` 의 축정렬 AABB 를 대체한다.
    public static func contains(_ quad: Quad, _ point: SIMD2<Float>) -> Bool {
        localUV(quad, point) != nil
    }

    /// 순환 순서의 볼록 다각형 포함 판정. 시계/반시계 방향을 모두 허용하고 경계를 포함한다.
    /// 면적 0, 비유한 좌표, 3점 미만은 히트 불가다.
    public static func contains(_ polygon: ConvexPolygon, _ point: SIMD2<Float>) -> Bool {
        let v = polygon.vertices
        guard v.count >= 3, point.x.isFinite, point.y.isFinite,
              v.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        var twiceArea: Float = 0
        for i in v.indices {
            let a = v[i], b = v[(i + 1) % v.count]
            twiceArea += a.x * b.y - a.y * b.x
        }
        guard twiceArea.isFinite, abs(twiceArea) > determinantEpsilon else { return false }

        var winding: Float = 0
        for i in v.indices {
            let a = v[i], b = v[(i + 1) % v.count]
            let edge = b - a, rel = point - a
            let cross = edge.x * rel.y - edge.y * rel.x
            let tolerance = determinantEpsilon * max(1, simd_length(edge))
            if abs(cross) <= tolerance { continue }
            if winding == 0 { winding = cross }
            else if (winding > 0) != (cross > 0) { return false }
        }
        return true
    }

    /// 실물이 `CursorEvent.localPosition` 으로 싣는 값 — `(u·size.x, (1−v)·size.y)`
    /// (`0x14019df36`–`0x14019df5f`). y 가 뒤집혀 있다(로컬 좌상단 원점).
    /// `size` 는 **스케일 이전**의 저작 크기다(실물 `obj[0x2f0]`).
    public static func localPixels(_ quad: Quad, _ point: SIMD2<Float>,
                                   size: SIMD2<Float>) -> SIMD2<Float>? {
        guard let uv = localUV(quad, point) else { return nil }
        return SIMD2(uv.x * size.x, (1 - uv.y) * size.y)
    }

    // ── 텍스트 오브젝트 히트 상자 (BD, 2026-08-21) ────────────────────────────
    /// 실물 텍스트 오브젝트의 히트 상자 크기 = `size` 멤버 `+0x2f0`.
    ///
    /// **텍스트도 이미지와 같은 상자 함수를 탄다.** 히트 순회는 타입 가상함수 `[vtbl+0x60]` 을 부르고
    /// (`0x14018a041`) 그 결과 **1(이미지)과 4(텍스트)를 같은 레지스터로 모아**(`0x14018a044` `cmp eax,1`
    /// → `0x14018a04b` `cmp eax,4` → `0x14018a050` `mov rdx,r15`) 위 `sub_14019dbb0` 하나에 넘긴다
    /// (`0x14018a242`). 텍스트 vtable 은 `0x140491950`(생성자 `0x140256af7` `lea rax,[rip+0x23ae52]` →
    /// `0x140256b05` `mov [rdi],rax`)이고 그 슬롯 `+0x60` 이 `0x1400fde90` = `mov eax,4; ret` 이다
    /// (셋 다 2026-08-21 재실측 — 남의 주석을 베끼지 않았다).
    ///
    /// 그 `+0x2f0` 을 쓰는 것은 텍스트 vtable 슬롯 `+0x110` = `0x140258900` 이다(레이아웃 직후
    /// `0x1402575db` 이 호출). 함수 전체가 이 식이다:
    /// ```
    /// 0x140258927  xmm1 = [layout+0x98] − [layout+0x90]      ; 잉크박스 maxX−minX
    /// 0x14025892f  xmm2 = [layout+0x9c] − [layout+0x94]      ; 잉크박스 maxY−minY
    /// 0x140258949  (레이아웃 객체 없음) xmm1 = xmm2 = 2.0
    /// 0x140258954  if ([this+0x320] > 0 || [this+0x304] & 0x10 || [this+0x594] & 2)
    /// 0x140258986      xmm4 = min(padding.x, 512.0) ; xmm3 = min(padding.y, 512.0)   ; +0x4e8/+0x4ec
    /// 0x14025896f  else xmm4 = xmm3 = 0
    /// 0x1402589a9  xmm4 += xmm4 ; xmm3 += xmm3               ; 양쪽에 붙으므로 2배
    /// 0x1402589b9  [this+0x2f0] = xmm1 + xmm4 ; [this+0x2f4] = xmm2 + xmm3
    /// ```
    /// Waple 의 `inkBox` 등가물은 `TextRasterizer.Raster.width`/`height`(= `GPUText.rasterWidth`/
    /// `rasterHeight`)다. 그 값은 이미 축당 `+2 px`(래스터 캔버스 여백)을 품고 있으므로
    /// `docs/re/text-layer.md` §11.1 의 "안전판 ② 축당 +2 px" 는 **이미 충족돼 있다** — 여기서 더
    /// 더하지 않는다(이중 가산 방지).
    ///
    /// **실물과 의도적으로 다른 한 곳**: 실물은 `minss` 상한만 있어 음수 `padding` 이 상자를 **줄인다**.
    /// 여기서는 `[0, 512]` 로 양끝을 자른다 — 좁히는 쪽으로 틀리면 그 텍스트에 붙은 스크립트가 커서
    /// 이벤트를 통째로 못 받기 때문이다. 음수 `padding` 의 도달은 설치본 5/5 · 리포 동봉 3/3 이 전건
    /// `0` 이고 워크샵 정본(`spec/corpus/scene-schema.json`) `padding` range 가 `[0, 300]` 이라 **0건**.
    public static func textHitSize(inkBox: SIMD2<Float>, padding: SIMD2<Float>,
                                   paddingActive: Bool) -> SIMD2<Float> {
        guard paddingActive else { return inkBox }
        let px = min(max(padding.x, 0), textPaddingClamp)
        let py = min(max(padding.y, 0), textPaddingClamp)
        return SIMD2(inkBox.x + 2 * px, inkBox.y + 2 * py)
    }

    /// `0x140258986` 의 `movss xmm0, [rip+0x239fa6]` (= `0x140492934` f32 512.0).
    public static let textPaddingClamp: Float = 512

    /// 위 세 게이트 중 **Waple 이 값을 갖고 있는 것들**의 논리합. 셋 다 참이면 패딩 항이 산다.
    ///
    /// | 실물 게이트 | 뜻 | Waple 인자 |
    /// |---|---|---|
    /// | `[this+0x320] > 0` | 이펙트 **패스** 수 > 0 (이펙트 빌더 `0x1401e6f50` 이 `0x1401e6fef` 에서 0 으로 깔고 패스 집계가 누적) | `hasEffects` |
    /// | `[this+0x594] & 2` | `opaquebackground`(bit1) | `opaqueBackground` |
    /// | `[this+0x304] & 0x10` | 오프스크린 합성 필요 — `0x1401e6fa2` `or dword [rsi+0x304],0x10` | `colorBlendMode` (아래) |
    ///
    /// 셋째 게이트의 조건은 세 갈래 논리합이다(`0x1401e6f74`–`0x1401e6fa0`):
    /// `colorBlendMode`(`+0x32c`)가 **0 도 31 도 아님** · `+0x304 & 0x100` · 씬 렌더 설정
    /// `[[this+0xc8]+0x118] & 0x1800000`. 그 `or` 는 이펙트 배열을 읽기 **전**(`0x1401e6ffa` 의
    /// `lea rdx,"effects"` 앞)에 실행되므로 **이펙트 유무와 독립**이다 — 그래서 `hasEffects` 로 대신
    /// 덮을 수 없고 여기서 `colorBlendMode` 를 따로 본다.
    ///
    /// **남는 사각(정직하게)**: `+0x304 & 0x100` = `ledsource`(BD 2026-08-21 확정 — 등록 이름
    /// `0x1401eede6` "ledsource" · `[desc+0x34]=0x304` `0x1401eee1a` · 태그 6 `0x1401eee30`, 주입기
    /// `0x14019c850` 의 `bts ecx,8`/`btr edx,8`, 게터 `0x14019ca60` 의 `shr edx,8; and dl,1`)와
    /// 씬 설정 비트 둘은 Waple 이 텍스트에서 파스하지 않는다. 도달은 워크샵 텍스트 1,597 중
    /// `ledsource` **6건**(5씬) · 설치본 5 중 0 · 리포 동봉 3 중 0.
    ///
    /// **`hasEffects` 는 일부러 넓다**: 실물 게이트는 이펙트 *패스 수*인데 우리는 배열 비어있음만 본다.
    /// 패스가 0 으로 접히는 이펙트 배열에서 우리 상자가 실물보다 커진다 — 넓어지는 방향이라
    /// "스크립트가 이벤트를 못 받는" 실패는 만들지 않는다.
    public static func textPaddingActive(hasEffects: Bool, opaqueBackground: Bool,
                                         colorBlendMode: Int) -> Bool {
        hasEffects || opaqueBackground || (colorBlendMode != 0 && colorBlendMode != 31)
    }

    /// 커서 훅 **배달 범위** — 실물 배달 루프 `0x14018a709`–`0x14018a723`(커서 훅 5종 전건 동형)의
    /// 첫 관문을 순수 값으로 옮긴 것. 커서 훅은 **브로드캐스트가 아니다**:
    ///
    /// ```
    /// if (inst[0x48] != hitObject && inst[8] != 0) continue;   // 소유 오브젝트 일치 또는 무바인딩
    /// if (!(inst[0x40] & (1 << hookIdx)))          continue;   // 훅 보유 비트마스크
    /// if (inst[0x44] != 2)                         continue;   // 인스턴스 상태 = 초기화 완료
    /// ```
    ///
    /// 둘째·셋째 관문은 Waple 에 이미 있다(`TextScriptEngine.hookNames` / "엔진이 생성됐다").
    /// 남는 첫 관문이 이 타입이다. 그 앞단(어떤 오브젝트가 히트인가)은 히트 순회 쪽 관문 —
    /// `solid`(플래그워드 `+0x120` bit13, ctor 기본 **true**, `0x14018a00b` `mov r8d,0x2000` →
    /// `0x14018a02d`)가 첫 게이트다.
    public enum DeliveryScope: Equatable {
        /// 오브젝트에 바인딩되지 않은 스크립트 — 실물 `inst[8] == 0`. 어느 오브젝트가 맞았든 받는다.
        case unbound
        /// 소유 오브젝트의 히트 쿼드(씬 픽셀 · 시차 보정까지 끝난 것).
        case object(Quad)
        /// 원근 투영/클립까지 끝난 소유 오브젝트의 화면 볼록 다각형.
        case projected(ConvexPolygon)
        /// 소유 오브젝트가 히트 순회에 **아예 들어가지 않는다** — `solid` 가 꺼져 있다.
        case unhittable
        /// **Waple 한정 폴백**: 소유 오브젝트는 있는데 히트 기하가 미확정이다. 실물 텍스트 오브젝트의
        /// 크기는 래스터된 픽셀 크기인데(`docs/re/scene-script-api.md` §9.1 (b) 의 `size` [미해결])
        /// 우리는 그 값을 모른다. **추측한 상자로 막기보다 종전 브로드캐스트를 유지한다** —
        /// 틀린 방향으로 좁히면 스크립트가 통째로 죽고, 넓은 채로 두면 종전과 같다.
        ///
        /// **해소(2026-08-21, BD)** — 위 문단의 "우리는 그 값을 모른다" 는 이제 틀렸다. 규약은
        /// `textHitSize(inkBox:padding:paddingActive:)` 로 확정했고(`+0x2f0` 산출 `0x140258900`),
        /// `SceneRenderer.buildPointerTargets` 의 텍스트 분기가 `GPUText.rasterWidth`/`rasterHeight`
        /// 로 실제 쿼드를 만든다. **이 케이스는 사라지지 않는다** — 아직도 세 자리에서 쓴다:
        /// ① 래스터가 없는 텍스트(빈 문자열 = 드로우 스킵 → 상자를 만들 근거가 없다),
        /// ② 3D 씬(2D `buildTexts` 미실행이라 `textLayers` 가 비어 있다),
        /// ③ 디스크립터 인덱스가 문서 범위 밖(방어).
        case geometryUnknown
    }

    /// 이 대상이 포인터 `point` 에 대해 커서 훅을 받는가. `point == nil`(창 밖)이면 실물은 히트
    /// 오브젝트가 없어 루프 자체가 돌지 않으므로 `.object` 는 거짓이다.
    /// `.unbound`/`.geometryUnknown` 은 히트와 무관하게 참(각각 실물 예외와 우리 폴백).
    public static func delivers(_ scope: DeliveryScope, to point: SIMD2<Float>?) -> Bool {
        switch scope {
        case .unbound, .geometryUnknown: return true
        case .unhittable: return false
        case .object(let quad): return point.map { contains(quad, $0) } ?? false
        case .projected(let polygon): return point.map { contains(polygon, $0) } ?? false
        }
    }
}

/// `cursorClick` 타이밍 — 실물은 **뗄 때** 발화하고, **누를 때 잡아 둔 오브젝트에서 떼었을 때만**이다.
///
/// - 누름(`dl != 0`): `0x14018a78b`–`0x14018a7a0` 이 히트 오브젝트를 `scene+0x2c0` 해시맵에 넣는다
///   (`0x14018a79b` `mov [rsp+0x50], r15` 로 오브젝트 포인터를 넘긴다).
/// - 뗌(`0x14018a787` `test dl,dl` → `je 0x14018a7aa`): 같은 맵을 `find` 하고
///   **end 면 스킵**한다(`0x14018a7aa`–`0x14018a7b2`. 버킷 탐색 `0x14018a1d2`–`0x14018a20c` 의
///   `cmove rbx, r9` 가 미발견 시 end 를 대입하는 짝이다). 통과해야 `cursorClick` 배달 루프
///   (`0x14018a833` `mov r9d, 0xb` = 훅 인덱스 11)로 들어간다.
///
/// 종전 Waple 은 **누를 때** `cursorDown` 과 함께 쐈다(W-9). 키는 실물이 오브젝트 포인터,
/// 여기서는 배달 대상 인덱스다 — 같은 동치관계라 판정이 같다.
public struct PointerClickLatch: Equatable {
    private var held: Set<Int>

    public init(held: Set<Int> = []) { self.held = held }

    /// 지금 "누른 채 잡고 있는" 대상들(진단·테스트용).
    public var heldTargets: Set<Int> { held }

    /// 누름 — 이번에 히트한 대상을 잡는다(실물 맵 삽입). 직전 눌림은 덮어쓴다.
    public mutating func press(_ hit: [Int]) { held = Set(hit) }

    /// 뗌 — 지금 히트한 대상 중 **누를 때도 잡고 있던** 것만 클릭이다. 호출 후 맵은 비운다.
    /// 순서는 입력 순서를 유지한다(z-순서 역순 순회 결과를 그대로 쓰기 위함).
    public mutating func release(_ hit: [Int]) -> [Int] {
        let clicked = hit.filter { held.contains($0) }
        held.removeAll()
        return clicked
    }

    /// 눌림 무효화(창 밖에서 뗌 · 마운트 해제). 실물도 맵을 비운다(`0x14018a468`).
    public mutating func cancel() { held.removeAll() }
}

/// `g_PointerState`(유니폼 id 106) 합성용 버튼 상태 — 실물 renderState `+0xa4` 의 **비트 2개**.
///
/// - bit0 = 좌버튼 눌림 **유지**. 샘플러 `0x14010dab0` 이 세우고 지운다.
/// - bit1 = "이 눌림은 이미 한 프레임 소비했다". 렌더러 프레임 **꼬리**가 갱신한다 —
///   `0x140181623`–`0x14018162d` `if (s & 1) s |= 2; else s &= ~2;` → 저장 `0x14018169e`.
///
/// 유니폼 핸들러 `0x1400d9e2c`–`0x1400d9e8b`:
/// `x = y = (s & 1) ? 1 : 0` · `z = ((s & 1) && !(s & 2)) ? 1 : 0` · `w = 0`.
/// 즉 **`.z` 는 누른 첫 프레임에만 1** 인 클릭 임펄스다(유지 아님).
/// 동봉 셰이더 4파일이 전부 `.z` **만** 읽는다(`cursorripple_apply_force.frag:83` 이 `× 5.0`,
/// `fluidsimulation_vorticity.frag:198` 이 게인 1 — 각 preview 사본 포함).
public struct PointerButtonState: Equatable {
    /// renderState `+0xa4` bit0.
    public private(set) var isDown: Bool
    /// renderState `+0xa4` bit1.
    public private(set) var isConsumed: Bool

    public init(isDown: Bool = false, isConsumed: Bool = false) {
        self.isDown = isDown
        self.isConsumed = isConsumed
    }

    /// `g_PointerState.z` — 누른 첫 프레임만 1.0.
    public var clickImpulse: Float { (isDown && !isConsumed) ? 1 : 0 }

    /// `g_PointerState.x`/`.y` — 누르고 있는 동안 1.0(동봉 셰이더 소비 0건, 기록용).
    public var heldValue: Float { isDown ? 1 : 0 }

    /// 버튼 상태 주입(샘플러 `0x14010dab0` 대응). **bit1 은 건드리지 않는다** — 실물에서 bit1 을
    /// 쓰는 곳은 프레임 꼬리 하나뿐이다(`0x14018169e`).
    ///
    /// 한계(실물과 동형이라 그대로 둔다): 한 프레임 사이에 뗌→눌림이 몰리면 임펄스가 나가지 않는다.
    /// 실물은 프레임당 1회 `GetKeyState` 폴링(`0x1401115b1`)이라 애초에 그 전이를 보지 못한다.
    public mutating func setDown(_ down: Bool) { isDown = down }

    /// 프레임 꼬리(`0x140181623`). 이 호출 이후로 `.z` 는 0 이 된다.
    public mutating func endFrame() { isConsumed = isDown }
}
