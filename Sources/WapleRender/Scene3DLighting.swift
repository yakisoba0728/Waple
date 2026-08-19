import Foundation
import simd
import WapleCore

/// `generic4`의 상수형 metallic/roughness 머티리얼 값.
/// PBR mask/normal map은 별도 후속 범위이며 여기서는 네이티브 기본값을 보존한다.
///
/// ⚠️ **WE 는 메시 머티리얼 레인이 둘이고 상수 규약이 서로 다르다.**
/// - PBR 레인(`generic3`/`generic4`, `common_pbr*.h` → `ComputePBRLightShadow*`):
///   키 `roughness`/`metallic`, 기본 0.7/0. 스페큘러는 GGX 이고 `specular * specularTint` 로
///   diffuse 와 **같은 식** 안에서 합산된다(common_pbr_2.h:313/362). 우리 스톡 셰이더가 이식한 레인.
/// - 레거시 레인(`generic`/`generic2`, `common_fragment.h:68` → `ComputeLightSpecular`):
///   키 `Metal`/`Rough`/`Light`, **셋 다 기본 0**(generic2.frag:6-9). 스페큘러는 GGX 가 아니라
///   Blinn 로브 `pow(dot(normalize(V+L),N), specularPower) * specularStrength * lightAttn * color` 를
///   `specularResult` 에 따로 누적해(common_fragment.h:74) 마지막에
///   `albedo.rgb = albedo.rgb * light + specularResult` 로 가산한다(generic2.frag:60-69)
///   — **알베도와 곱해지지 않는다.**
///   ⚠️ 여기서 `g_Light`(상수 `Light`)는 **스페큘러 게이트가 아니다** — `ComputeLightSpecular` 가
///   `halfLambert` 인자로 받아 `lightDot = mix(lightDot, halfLambertLight, halfLambert)`(common_fragment.h:78)
///   로 **diffuse 만** 성형한다. `specularResult +=` 는 무조건 실행된다. 스페큘러를 사실상 끄는 것은
///   `Rough`/`Metal` 기본 0 이 만드는 지수 404 로브 쪽이다(아래 parse 주석).
/// 두 레인의 상수 이름과 기본값은 하나도 겹치지 않는다.
struct Scene3DMaterialValues: Equatable {
    var roughness: Float = 0.7
    var metallic: Float = 0
    var specularTint = SIMD3<Float>(1, 1, 1)
    /// RIMLIGHTING 콤보 유니폼(g_RimAmount/g_RimExponent) — generic4.frag 기본값과 동일(F274).
    /// 콤보 자체(rimLighting/shadingGradient on-off)는 combos 딕셔너리 소관이라 loadMesh3DMaterial 에서
    /// 별도 파싱(unlit 과 동일 패턴) — 여기는 constantshadervalues 수치만 다룬다.
    var rimAmount: Float = 2.0
    var rimExponent: Float = 4.0
    /// M6(⑥): REFLECTION 콤보 g_Reflectivity(generic4.frag:66 — material key "reflectivity", 기본 1).
    var reflectivity: Float = 1.0

    /// WE `g_Brightness` — `#if HDR` 안에서 **최종색에 곱하는** 배율(기본 1, 범위 [0,10]).
    /// 소비 위치가 알베도가 아니라 라이팅·반사를 **다 더한 뒤**, 포그 **직전**이다
    /// (generic2.frag:79-81, generic4.frag:166-172). LIGHTING 콤보와 무관하게 발화한다 —
    /// unlit 머티리얼도 곱해야 한다(코퍼스 실물: 3470948192 `uc/材质` generic2 + LIGHTING:0 + 0.5).
    /// HDR 게이트는 머티리얼이 아니라 **엔진이 주입하는 콤보**라(정본: spec/engine/material-brightness.json
    /// `shaders.materialBrightness.hdrGateInjection` — 코퍼스 전수에서 HDR 콤보 저작 0건) 여기서는
    /// 저작값만 보존하고 씬 HDR 여부는 encode3D 가 곱한다.
    var brightness: Float = 1

    /// 레거시 레인 머티리얼 셰이더(`common_fragment.h::ComputeLightSpecular`). 이름이 비슷한
    /// `generic3` 은 **PBR 레인**이다(generic3.frag:22 `#include "common_pbr.h"`, 상수 키
    /// `roughness`/`metallic` 기본 0.7/0) — 여기 넣으면 안 된다.
    /// 2D 레이어 전용 `genericimage*`/`genericparticle` 도 메시 머티리얼이 아니라 대상 밖이다.
    static let legacyLaneShaders: Set<String> = ["generic", "generic2"]

    /// `g_Brightness` 를 노출하는 머티리얼 키(소문자 정규화 후). nil = **그 셰이더엔 유니폼이 없다**.
    /// 같은 유니폼인데 레인마다 철자가 갈리는 것이 이 값의 함정이다:
    /// - `generic2` → `Brigtness`. **WE 자신의 오타**다(generic2.frag:7 선언 주석 원문). 철자를
    ///   교정해 읽으면 저작값을 영영 못 만난다 — 코퍼스에서도 이 셰이더에만 이 철자가 붙는다.
    /// - PBR 레인(`generic3`/`generic4`/`chroma4`/`fur4`/`foliage4`) → `brightness`(소문자,
    ///   generic4.frag:37 label `ui_editor_properties_hdr_brightness`). 선언 기본값·범위·소비 위치는
    ///   generic2 와 동일하다. 미지/무명 셰이더도 스톡 셰이딩이 PBR 레인이라 여기로 묶는다.
    /// - `generic` → 없음. 같은 레거시 레인이지만 generic.frag 에는 g_Brightness 선언 자체가 없어
    ///   (uniform 전수 대조: Metal/Rough/Light/Color/Alpha 뿐) 키를 읽는 것 자체가 오독이다.
    ///   레인 구분(legacyLaneShaders)과 키 유무가 일치하지 않으므로 별도 판정을 둔다.
    /// 2D 레이어 레인(`genericimage` 키 `Bright`, `genericimage2` 키 `Brightness`)은 대상 밖이다 —
    /// 그쪽은 `#if HDR` 게이트가 없고 소비 위치도 알베도 직후라 규약이 다른 별개 유니폼이다.
    static func brightnessKey(shader: String?) -> String? {
        switch shader {
        case "generic": return nil
        case "generic2": return "brigtness"
        default: return "brightness"
        }
    }

    /// `passes[0].constantshadervalues` → 머티리얼 값. `shader` 는 같은 pass 의 셰이더 이름으로,
    /// 어떤 상수 규약(키·기본값)을 적용할지 고른다. nil/미지 셰이더는 PBR 레인(종전 동작).
    static func parse(_ constants: [String: Any]?, shader: String? = nil) -> Self {
        var result = Self()
        let legacy = shader.map(legacyLaneShaders.contains) ?? false
        if legacy {
            // generic2.frag:6-7 선언 기본값 — `Rough`/`Metal` 둘 다 0(generic4 의 0.7/0 이 아니다).
            result.roughness = 0
            result.metallic = 0
            // ★ 이 커밋의 실제 수정. 스톡 셰이더의 스페큘러는 PBR 레인의 GGX 항이라 레거시 레인에는
            // 존재하지 않는 것이다. 그대로 두면 `specular * specularTint` 가 **알베도와 무관하게**
            // 라이트 세기에 비례해 그려져(3470948192 워프 터널: 알베도를 util/black 으로 바꿔도 평균
            // 휘도 150.23 → 149.92 로 안 어두워지고, intensity 를 9.84→1.0 으로 낮추면 30.91 로 떨어짐)
            // WE 대비 휘도비 11.99 의 블로우아웃이 된다.
            // WE 의 이 레인 스페큘러는 지수 `(1.01-Rough)*mix(400,250,Metal)`, 세기
            // `(0.5+Metal*0.5)*(1-Rough*0.9)` 의 Blinn 로브다(common_fragment.h:51-58,74). 코퍼스의
            // 레거시 머티리얼은 `Rough`/`Metal` 을 저작하지 않거나 0 으로 저작하므로 전건이 지수 404 —
            // 사실상 델타 함수라 평균 휘도 기여가 0 이다. 로브 자체를 이식하지 않는 이상(그러려면 diffuse
            // 항도 같이 갈아야 한다: `albedo*(saturate(NL)+rim)*lightAttn²`, /π 없음) GGX 로브를
            // 대신 그리는 것보다 끄는 쪽이 WE 에 가깝다.
            // 온전한 해법은 GLSLTranslator 의 VIn 에 a_Normal 을 붙여 generic2 를 진짜로 번역하는 것이고
            // (그러면 이 경로 자체를 안 탄다) 별도 작업 단위다.
            result.specularTint = .zero
        }
        guard let constants else { return result }
        // case-only 중복 키(예: "Alpha"+"alpha")는 원본 키 정렬 후 첫 키를 채택해 결정적으로 병합한다.
        // (uniquingKeysWith 클로저는 값만 받으므로 정렬 없이는 dict 순회 비결정성이 런마다 결과를 가른다.)
        let values = Dictionary(
            constants.sorted { $0.key < $1.key }.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first })
        if let roughness = numbers(values[legacy ? "rough" : "roughness"])?.first { result.roughness = roughness }
        if let metallic = numbers(values[legacy ? "metal" : "metallic"])?.first { result.metallic = metallic }
        // `speculartint` 는 PBR 레인 전용 상수다 — 레거시 레인은 위에서 정한 0 을 저작으로 뒤집지 않는다.
        if !legacy, let tint = numbers(values["speculartint"]), tint.count >= 3 {
            result.specularTint = SIMD3(tint[0], tint[1], tint[2])
        }
        if let rimAmount = numbers(values["rimamount"])?.first { result.rimAmount = rimAmount }
        if let rimExponent = numbers(values["rimexponent"])?.first { result.rimExponent = rimExponent }
        if let reflectivity = numbers(values["reflectivity"])?.first { result.reflectivity = reflectivity }
        if let key = brightnessKey(shader: shader), let brightness = numbers(values[key])?.first {
            result.brightness = brightness
        }
        return result
    }

    private static func numbers(_ value: Any?) -> [Float]? {
        switch value {
        case let value as Float:
            return [value]
        case let value as Double:
            return [Float(value)]
        case let value as Int:
            return [Float(value)]
        case let value as NSNumber:
            return [value.floatValue]
        case let value as String:
            let parsed = value.split(whereSeparator: { $0.isWhitespace }).compactMap { Float($0) }
            return parsed.isEmpty ? nil : parsed
        case let value as [Any]:
            let parsed = value.compactMap { numbers($0)?.first }
            return parsed.isEmpty ? nil : parsed
        case let value as [String: Any]:
            return numbers(value["value"])
        default:
            return nil
        }
    }
}

/// 3D 라이트 종류. rawValue 는 MSL `LightU.shadow.z` 타입 플래그와 동일 규약(0/1/2/4).
/// tube=4: WE 정본 라이트 4종(point/spot/tube/directional — A2-pbr-lighting.md §4.4) 중 마지막 갭.
/// 3 을 건너뛰는 것은 기존 0/1/2 비교 경계(kind<0.5/<1.5/<2.5)를 비트동일로 보존하기 위함이다.
enum Scene3DLightKind: Float, Equatable {
    case point = 0, directional = 1, spot = 2, tube = 4
    init?(type: String) {
        // G-A4-04: 접두 `l` 없는 레거시 표기도 받는다. WE 2.8.42 설치본 실측: 씬의 `"light"` 값이
        // `"lpoint"` **3건**, `"point"` **3건**으로 반반이다(`arsenal` 오브젝트 2개, `demon_core` 1개가
        // 후자). 그 씬들은 `version` 키가 아예 없는 최구 포맷이고, `arsenal` 은 `ambientcolor` 가
        // 완전 검정이라 두 point 라이트를 버리면 WE 가 배포하는 대표 배경이 사실상 새까맣게 렌더된다.
        // 종전 `default: return nil` 은 그 3건을 조용히 드롭했다.
        // 미지 타입은 계속 nil 이다 — 2D 레인의 "미지 → point" 관용(forwardLightKind)은 여기 들이지
        // 않는다(오타를 라이트로 승격시키는 쪽이 더 위험하다).
        switch type.lowercased() {
        case "lpoint", "point": self = .point
        case "ldirectional", "directional": self = .directional
        case "lspot", "spot": self = .spot
        case "ltube", "tube": self = .tube
        default: return nil
        }
    }
}

struct Scene3DResolvedLight: Equatable {
    var position: SIMD3<Float>
    var exponent: Float
    var colorRadius: SIMD4<Float>
    var castsShadow: Bool
    var kind: Scene3DLightKind = .point
    /// 월드 forward(+Z blue축 = 광자 진행 방향). directional/spot 만 유효. point 는 미사용.
    var forward: SIMD3<Float> = SIMD3(0, 0, 1)
    /// spot 콘 코사인(축 기준). point/directional 미사용(기본 0 → 셰이더가 kind 로 분기).
    var coneInnerCos: Float = 0
    var coneOuterCos: Float = 0
    /// F780(S-47): `cascadedistance0-2`(친 치수 상승 far 경계). 소비는 directional + castShadow 한정
    /// (DirectionalShadowMath.validCascades) — WE 에디터는 라이트 종 무관 기록이라 point/spot 도 파스는 보존.
    var cascadeDistances: SIMD3<Float>? = nil
    /// tube 세그먼트 단점 B(월드 — WE g_LTube_OriginB). tube 외 kind 는 nil(셰이더가 kind 로 분기).
    /// 부모-로컬 `originb` 를 부모 체인 행렬로 월드화한 값(resolveLights — origin 과 동일 공간 규약).
    var originB: SIMD3<Float>? = nil
}

/// MSL `FrameU`와 필드/정렬이 같은 per-frame 3D 라이팅 상수(8×float4).
struct Scene3DFrameUniform {
    var cameraEye: SIMD4<Float>
    var ambient: SIMD4<Float>
    var skylight: SIMD4<Float>
    /// x=활성 라이트 수, y/z=shadow atlas texel 크기, w=receiver depth bias.
    var meta: SIMD4<Float>
    /// F662: scene fog 유니폼(common_fog.h g_FogDistanceColor/g_FogDistanceParams 대응). w=활성 플래그.
    var fogDistanceColor = SIMD4<Float>(0, 0, 0, 0)
    /// x=start, y=end-start, z=startDensity, w=endDensity-startDensity.
    var fogDistanceParams = SIMD4<Float>(0, 1, 0, 0)
    var fogHeightColor = SIMD4<Float>(0, 0, 0, 0)
    var fogHeightParams = SIMD4<Float>(0, 1, 0, 0)
}

/// MSL `LightU`와 필드/정렬이 같은 라이트 1개 상수(5×float4).
struct Scene3DLightUniform {
    var positionExponent: SIMD4<Float>
    var colorRadius: SIMD4<Float>
    /// x=shadow array slice(-1이면 비활성), y=shadow VP 시작 인덱스, z=kind(0/1/2/4), w=spot 콘 inner cos.
    var shadow: SIMD4<Float>
    /// xyz=월드 forward(+Z blue축), w=spot 콘 outer cos. directional/spot 전용.
    /// tube(kind 4)는 xyz=세그먼트 단점 B(WE g_LTube_OriginB — cone/forward 미사용 슬롯 재활용), w=0.
    var axis: SIMD4<Float>
    /// F780: directional CSM far 경계 xyz + w=캐스케이드 수(3=CSM, 0=단일 오소/기타).
    /// spot cone 필드와 달리 directional 이 아니면 항상 .zero.
    var cascades: SIMD4<Float> = .zero
}

enum Scene3DLighting {
    // F660: 4 → 8 상향. WE 는 종류별 배열(lightconfig: 젤다 point:5+directional:1=6슬롯)로 전량 렌더하는데
    // first-4 캡이 3737268876 의 5번째 lpoint(Navi Light)와 ldirectional(태양, castshadow:true)을 드롭했다.
    // 코퍼스 최대 6(젤다) — 8 은 상한 여유 포함. 셰이더 루프 상한(Mesh3DShaders mf_main)도 동일하게 올린다.
    static let maximumLights = 8

    /// lpoint / ldirectional / lspot / ltube 를 월드 공간으로 해석한다. 입력 순서를 보존하고(first-N 정책),
    /// 부모가 있으면 그 부모의 현재 월드행렬/가시성을 적용한다.
    ///
    /// 방향 규약(2026-07 확정): scene.json `angles`(라디안) → Scene3DMath 모델행렬(T·Rz·Ry·Rx·S,
    /// 오브젝트와 동일 규약)의 **blue축(+Z, col2)** 이 라이트 forward. 근거: WE 스크립트 API
    /// (`lib.sceneScript.d.ts`) `Mat4.forward() = Blue axis`, `right=Red(+X)`, `up=Green(+Y)`,
    /// `compose = T*R*S`. directional 은 무감쇠(radiance=color×intensity), L=-forward.
    /// spot 섀도우는 스코프 밖(코퍼스 spot 전원 castshadow:false) → castShadow 는 point/directional 만 존중.
    /// ltube: origin=단점A/originb=단점B(부모-로컬 동일 공간), 무섀도우(WE 정본 — A2-pbr-lighting.md §4.4).
    static func resolveLights(_ lights: [SceneLight3D],
                              nodes: [Int: Scene3DMath.Node]) -> [Scene3DResolvedLight] {
        var result: [Scene3DResolvedLight] = []
        result.reserveCapacity(maximumLights)

        for light in lights where result.count < maximumLights {
            guard let kind = Scene3DLightKind(type: light.type),
                  light.intensity.isFinite,
                  light.exponent.isFinite,
                  light.origin.x.isFinite, light.origin.y.isFinite, light.origin.z.isFinite,
                  light.angles.x.isFinite, light.angles.y.isFinite, light.angles.z.isFinite,
                  light.color.x.isFinite, light.color.y.isFinite, light.color.z.isFinite else { continue }
            // point/spot 은 유한 감쇠 반경 필요. directional 은 무감쇠라 반경 무관.
            if kind != .directional {
                guard light.radius.isFinite, light.radius > PointShadowMath.minimumRadius else { continue }
            }

            // 라이트 자체 회전 포함 로컬행렬(scale=1: 위치·방향에 스케일 오염 방지) → 부모 체인 합성.
            // col3=위치, col2=forward. point 위치는 회전 무관(T·R·S 의 col3 = origin)이라 무회귀.
            let localMatrix = Scene3DMath.modelMatrix(
                origin: SIMD3(light.origin.x, light.origin.y, light.origin.z),
                angles: SIMD3(light.angles.x, light.angles.y, light.angles.z),
                scale: SIMD3(1, 1, 1))
            // 부모 행렬을 분리 보관 — tube 단점 B(originb)는 origin 과 같은 부모-로컬 공간 점이라
            // 라이트 자체 회전(R)이 아니라 부모 체인만으로 월드화한다(WE g_LTube_OriginA/B 는
            // 동일 공간의 두 단점 — generic3.frag:110 PointSegmentDelta 소비). 무parent = 항등(비트동일).
            let parentMatrix: simd_float4x4
            if let parent = light.parent {
                guard let transform = Scene3DMath.worldMatrix(id: parent, nodes: nodes),
                      transform.visible else { continue }
                parentMatrix = transform.matrix
            } else {
                parentMatrix = matrix_identity_float4x4
            }
            let worldMatrix = parentMatrix * localMatrix
            let position = SIMD3(worldMatrix.columns.3.x, worldMatrix.columns.3.y, worldMatrix.columns.3.z)
            let forward = normalizedOr(
                SIMD3(worldMatrix.columns.2.x, worldMatrix.columns.2.y, worldMatrix.columns.2.z),
                SIMD3(0, 0, 1))
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite,
                  forward.x.isFinite, forward.y.isFinite, forward.z.isFinite else { continue }

            var resolved = Scene3DResolvedLight(
                position: position,
                exponent: light.exponent,
                colorRadius: SIMD4(
                    light.color.x * light.intensity,
                    light.color.y * light.intensity,
                    light.color.z * light.intensity,
                    light.radius),
                // F661: spot 섀도우만 스코프 밖(코퍼스 spot 전원 castshadow:false). directional 은
                // 단일 오소 맵 최소 근사 지원(DirectionalShadowMath) — castshadow:true 3씬.
                // tube 도 섀도우 없음이 정본(WE PerformLighting_V1: tube 는 shadowFactor=1.0 고정 —
                // A2-pbr-lighting.md §4.4/§4.5 "Tube (섀도우 없음)").
                castsShadow: kind != .spot && kind != .tube && light.castShadow,
                kind: kind,
                forward: forward)
            if kind == .spot {
                let cone = spotConeCosines(inner: light.innerCone, outer: light.outerCone)
                resolved.coneInnerCos = cone.inner
                resolved.coneOuterCos = cone.outer
            }
            if kind == .tube {
                // originb 미저작은 A==B 퇴화 — WE PointSegmentDelta(common_pbr.h:13-14)가 v==0 이면
                // A-pos 반환이라 point 와 수치 동치(드롭하지 않는다).
                let b = light.originB ?? light.origin
                let wb = parentMatrix * SIMD4(b.x, b.y, b.z, 1)
                guard wb.x.isFinite, wb.y.isFinite, wb.z.isFinite else { continue }
                resolved.originB = SIMD3(wb.x, wb.y, wb.z)
            }
            // F780: cascadeDistances 는 종 무관 보존(유효성·소비 게이트는 packLights/뎁스 패스).
            if let cd = light.cascadeDistances {
                resolved.cascadeDistances = SIMD3(cd.x, cd.y, cd.z)
            }
            result.append(resolved)
        }
        return result
    }

    /// spot innercone/outercone(전각, 도) → 축 기준 half-angle 코사인.
    /// half-angle 규약(cone/2) 채택: WE 에디터 라벨은 단위 미명시라 표준 전각 해석.
    // ponytail: half vs full 미확정(코퍼스 spot 은 전부 지오메트리 범위 밖이라 육안 보정 불가).
    //           full-angle 이면 `* 0.5` 를 제거. 지오메트리 도달 spot 실물 확보 시 3477054430 로 보정.
    static func spotConeCosines(inner: Float, outer: Float) -> (inner: Float, outer: Float) {
        guard outer.isFinite, outer > 0 else { return (1, -1) }  // 콘 데이터 없음 → 반구 그라디언트(셰이더 (cosAngle+1)/2 → 축상 1·수직 0.5·후방 0). 전방향 통과 아님.
        let toHalfRadians = Float.pi / 180 * 0.5
        let cosOuter = cos(max(0, outer) * toHalfRadians)
        let cosInnerRaw = inner.isFinite && inner > 0 ? cos(inner * toHalfRadians) : 1
        // inner 는 outer 보다 좁아야(코사인 큼) 스무드스텝이 0→1 로 증가.
        return (max(cosInnerRaw, cosOuter + 1e-4), cosOuter)
    }

    /// 영벡터/비유한 방어 정규화(셰이더 normalizedOr 과 동일 시맨틱).
    private static func normalizedOr(_ value: SIMD3<Float>, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(value)
        return lengthSquared > 1e-12 && lengthSquared.isFinite ? value / sqrt(lengthSquared) : fallback
    }

    /// 활성 라이트 순서를 유지하면서 shadow caster에만 조밀한 array slice를 부여한다.
    static func packLights(_ lights: [Scene3DResolvedLight]) -> [Scene3DLightUniform] {
        var packed = [Scene3DLightUniform](repeating: Scene3DLightUniform(
            positionExponent: .zero,
            colorRadius: .zero,
            shadow: SIMD4(-1, -1, 0, 0),
            axis: SIMD4(0, 0, 1, 0)), count: maximumLights)
        var nextShadowSlice: Float = 0
        for (index, light) in lights.prefix(maximumLights).enumerated() {
            let slice = light.castsShadow ? nextShadowSlice : -1
            if light.castsShadow { nextShadowSlice += 1 }
            // F780: directional + 캐스터 + 유효 상승 3경계만 CSM 소비. 무효/부재면 w=0(단일 오소 폴터).
            var csm = SIMD4<Float>.zero
            if light.kind == .directional && light.castsShadow,
               let d = DirectionalShadowMath.validCascades(light.cascadeDistances) {
                csm = SIMD4(d.x, d.y, d.z, 3)
            }
            packed[index] = Scene3DLightUniform(
                positionExponent: SIMD4(light.position.x, light.position.y, light.position.z, light.exponent),
                colorRadius: light.colorRadius,
                shadow: SIMD4(slice, slice >= 0 ? slice * 6 : -1, light.kind.rawValue, light.coneInnerCos),
                // tube: axis.xyz = 단점 B(월드). resolveLights 가 originb 부재 시 A==B 로 채우므로 ?? 는 방어.
                axis: light.kind == .tube
                    ? SIMD4((light.originB ?? light.position).x, (light.originB ?? light.position).y,
                            (light.originB ?? light.position).z, 0)
                    : SIMD4(light.forward.x, light.forward.y, light.forward.z, light.coneOuterCos),
                cascades: csm)
        }
        return packed
    }

    static func shadowSliceCount(_ packed: [Scene3DLightUniform]) -> Int {
        packed.reduce(into: 0) { count, light in
            if light.shadow.x >= 0 { count = max(count, Int(light.shadow.x) + 1) }
        }
    }

    /// shadow slice/VP 만 끈다(x/y). kind/cone(z/w)·axis 는 보존해야 directional/spot 셰이딩이 유지된다.
    static func disableShadow(at index: Int, in lights: inout [Scene3DLightUniform]) {
        guard lights.indices.contains(index) else { return }
        lights[index].shadow.x = -1
        lights[index].shadow.y = -1
    }
}

/// point shadow cube의 네이티브 dominant-axis face 순서와 2×3 셀 배치.
enum PointShadowMath {
    /// 이 이하 반경은 안정적인 depth 범위를 만들 수 없는 퇴화 광원으로 취급한다.
    static let minimumRadius: Float = 1e-4
    static let faceResolution = 512
    static let atlasColumns = 2
    static let atlasRows = 3
    static let viewportCompensation: Float = 0.49

    static func faceIndex(_ delta: SIMD3<Float>) -> Int {
        let absolute = simd_abs(delta)
        if absolute.x >= absolute.y && absolute.x >= absolute.z {
            return delta.x >= 0 ? 0 : 1
        }
        if absolute.y >= absolute.x && absolute.y >= absolute.z {
            return delta.y >= 0 ? 2 : 3
        }
        return delta.z >= 0 ? 4 : 5
    }

    static func atlasCell(_ face: Int) -> SIMD2<Int> {
        switch face {
        case 0: return SIMD2(0, 0)
        case 1: return SIMD2(1, 0)
        case 2: return SIMD2(0, 1)
        case 3: return SIMD2(1, 1)
        case 4: return SIMD2(0, 2)
        default: return SIMD2(1, 2)
        }
    }

    static func faceViewProjections(position: SIMD3<Float>, radius: Float) -> [simd_float4x4] {
        guard let near = nearPlane(radius: radius) else { return [] }
        let directions: [SIMD3<Float>] = [
            SIMD3(1, 0, 0), SIMD3(-1, 0, 0),
            SIMD3(0, 1, 0), SIMD3(0, -1, 0),
            SIMD3(0, 0, 1), SIMD3(0, 0, -1),
        ]
        let up: [SIMD3<Float>] = [
            SIMD3(0, -1, 0), SIMD3(0, -1, 0),
            SIMD3(0, 0, 1), SIMD3(0, 0, -1),
            SIMD3(0, -1, 0), SIMD3(0, -1, 0),
        ]
        let projection = Scene3DMath.perspective(fovYDegrees: 90, aspect: 1, nearZ: near, farZ: radius)
        return zip(directions, up).map { direction, upVector in
            projection * Scene3DMath.lookAt(eye: position, center: position + direction, up: upVector)
        }
    }

    static func nearPlane(radius: Float) -> Float? {
        guard radius.isFinite, radius > minimumRadius else { return nil }
        // [Waple stability policy] native CPU near 값은 미확정. 반경에 비례시키되 항상 far보다 작게 둔다.
        let preferred = max(minimumRadius, min(0.05, radius * 0.01))
        return min(preferred, radius * 0.5)
    }
}

/// F661(S-47): directional 섀도우 — F780 이후 2단계: 라이트에 유효한 `cascadedistance0-2`(F750 파스)가
/// 있으면 CSM 3-스플릿(엄격 상승 far 경계, 실측 ldirectional 3씬), 없으면 종전 단일 오소 근사 폴터.
/// 단일 오소: 라이트 forward 축으로 씬 전체 메시 월드 AABB(캐스터+리시버)를 타이트 피팅한 ortho VP 1장을
/// 아틀라스 한 슬라이스 전체에 기록. CSM: 깊이(라이트뷰 z)는 씬 AABB 전체를 유지하되 xy 범위는
/// 카메라 프러스텀 슬라이스([near, d0], [d0, d1], [d1, d2])에 타이트 피팅 — 캐스케이드 i 는 point 와 같은
/// 2×3 셀 배치의 셀 i 에 기록(VP 슬롯 slice*6+i, maximumLights*6 패턴 유지).
/// WE 의 캐스케이드 피팅 정밀 수학은 미확정 — 여기서는 "cascadedistance = 카메라 기준 far 경계"(C-shaders
/// 문서 확정 의미)만 소비하는 표준 CSM 으로 근사하고, 경계가 유효하지 않으면 추측 대신 단일 오소로 폴터.
/// **근사 유지 항목(동적 캡처 대기)**: 셰이더 측 선택은 WE mix 체인(투영 박스 포함 검사 — Mesh3DShaders
/// directionalShadowVisibility)으로 정합했으나, VP 피팅 자체(슬라이스 hull 타이트핏 + 씬 AABB 깊이 확장
/// + 5% 패드)는 WE 내부 수식 미확정 근사다. 실씬 동적 캡처로 WE 아틀라스와 대조 가능해지면 재보정한다.
enum DirectionalShadowMath {
    /// CSM 소비 가능한 경계인가: 전 성분 유한·양·친 치수 상승. 부분 저작/역전/0 은 WE 의미 미확정이라 부적격.
    static func validCascades(_ distances: SIMD3<Float>?) -> SIMD3<Float>? {
        guard let d = distances,
              d.x.isFinite, d.y.isFinite, d.z.isFinite,
              d.x > 0, d.y > d.x, d.z > d.y else { return nil }
        return d
    }

    /// 캐스케이드 프러스텀 슬라이스 산출 입력(encode3D 의 per-frame 카메라 해석값과 동일 출처).
    struct ShadowCamera {
        var eye: SIMD3<Float>
        /// 정규화된 시선 forward(center-eye). right/up 은 lookAt 과 동일 규약의 직교축.
        var forward: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var tanHalfFovY: Float
        var aspect: Float
        var nearZ: Float
    }

    /// 월드 AABB(minB/maxB)를 라이트 뷰 공간으로 옮겨 타이트하게 덮는 ortho VP(Metal z 0..1) 반환.
    /// 입력이 비유한/퇴화(min>max)면 nil — 호출부는 해당 라이트 섀도우를 끈다(기존 묻섀도우 폴터 유지).
    static func viewProjection(forward: SIMD3<Float>,
                               minBound: SIMD3<Float>, maxBound: SIMD3<Float>) -> simd_float4x4? {
        guard forward.x.isFinite, forward.y.isFinite, forward.z.isFinite,
              minBound.x.isFinite, minBound.y.isFinite, minBound.z.isFinite,
              maxBound.x.isFinite, maxBound.y.isFinite, maxBound.z.isFinite,
              minBound.x <= maxBound.x, minBound.y <= maxBound.y, minBound.z <= maxBound.z,
              simd_length_squared(forward) > 1e-12 else { return nil }
        let f = simd_normalize(forward)
        // 라이트 뷰: eye=원점, center=forward(RH, 전방 -Z). up 은 침침과 동일 기준축 폴터(F533).
        let view = Scene3DMath.lookAt(eye: .zero, center: f, up: SIMD3<Float>(0, 1, 0))
        // 월드 AABB 8코너 → 라이트 뷰 공간 min/max.
        var lo = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for cx in [minBound.x, maxBound.x] {
            for cy in [minBound.y, maxBound.y] {
                for cz in [minBound.z, maxBound.z] {
                    let p = view * SIMD4<Float>(cx, cy, cz, 1)
                    lo = simd_min(lo, SIMD3(p.x, p.y, p.z))
                    hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
                }
            }
        }
        return ortho(view: view, lo: lo, hi: hi)
    }

    /// F780: CSM 3-스플릿 VP(캐스케이드 0..2 순). 슬라이스 i 의 xy 는 카메라 프러스텀 구간
    /// [near, d0]/[d0, d1]/[d1, d2] 8코너에, 깊이(z)는 씬 AABB 전체와의 합집합(프러스텀 밖 캐스터 포함)에
    /// 피팅한다. 경계 무효(validCascades 부적격)·비유한 입력·퇴화 카메라면 nil → 호출부는 단일 오소 폴터.
    static func cascadeViewProjections(forward: SIMD3<Float>,
                                       camera: ShadowCamera,
                                       distances: SIMD3<Float>,
                                       minBound: SIMD3<Float>, maxBound: SIMD3<Float>) -> [simd_float4x4]? {
        guard let d = validCascades(distances),
              forward.x.isFinite, forward.y.isFinite, forward.z.isFinite,
              simd_length_squared(forward) > 1e-12,
              camera.eye.x.isFinite, camera.eye.y.isFinite, camera.eye.z.isFinite,
              camera.forward.x.isFinite, camera.forward.y.isFinite, camera.forward.z.isFinite,
              simd_length_squared(camera.forward) > 1e-12,
              camera.right.x.isFinite, camera.right.y.isFinite, camera.right.z.isFinite,
              camera.up.x.isFinite, camera.up.y.isFinite, camera.up.z.isFinite,
              camera.tanHalfFovY.isFinite, camera.tanHalfFovY > 0,
              camera.aspect.isFinite, camera.aspect > 0,
              camera.nearZ.isFinite, camera.nearZ >= 0,
              minBound.x.isFinite, minBound.y.isFinite, minBound.z.isFinite,
              maxBound.x.isFinite, maxBound.y.isFinite, maxBound.z.isFinite,
              minBound.x <= maxBound.x, minBound.y <= maxBound.y, minBound.z <= maxBound.z else { return nil }
        let f = simd_normalize(forward)
        let view = Scene3DMath.lookAt(eye: .zero, center: f, up: SIMD3<Float>(0, 1, 0))
        // 깊이(z) 범위는 씬 AABB(캐스터+리시버) 기준 — 프러스텀 밖 캐스터의 그림자도 맵에 들어와야 한다.
        var sceneLo = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var sceneHi = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for cx in [minBound.x, maxBound.x] {
            for cy in [minBound.y, maxBound.y] {
                for cz in [minBound.z, maxBound.z] {
                    let p = view * SIMD4<Float>(cx, cy, cz, 1)
                    sceneLo = simd_min(sceneLo, SIMD3(p.x, p.y, p.z))
                    sceneHi = simd_max(sceneHi, SIMD3(p.x, p.y, p.z))
                }
            }
        }
        // 프러스텀 슬라이스 양단 4코너씩 → 라이트 뷰.
        func sliceCorners(_ dist: Float) -> [SIMD3<Float>] {
            let hh = camera.tanHalfFovY * dist
            let hw = hh * camera.aspect
            let c = camera.eye + camera.forward * dist
            return [c + camera.right * hw + camera.up * hh,
                    c - camera.right * hw + camera.up * hh,
                    c + camera.right * hw - camera.up * hh,
                    c - camera.right * hw - camera.up * hh]
        }
        var result: [simd_float4x4] = []
        result.reserveCapacity(3)
        var dNear = max(camera.nearZ, Float(1e-3))
        for boundary in [d.x, d.y, d.z] {
            // 카메라 near 가 첫 경계를 넘는 퇴화(빈 슬라이스)만 방어 — 정상 시나리오에선 dNear 가 작다.
            let dn = min(dNear, boundary * 0.5)
            var lo = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
            for corner in sliceCorners(dn) + sliceCorners(boundary) {
                let p = view * SIMD4<Float>(corner.x, corner.y, corner.z, 1)
                lo = simd_min(lo, SIMD3(p.x, p.y, p.z))
                hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
            }
            // 깊이만 씬 전체로 확장(xy 는 슬라이스 타이트핏 유지 — 캐스케이드 해상도 이득의 핵심).
            lo.z = sceneLo.z
            hi.z = sceneHi.z
            result.append(ortho(view: view, lo: lo, hi: hi))
            dNear = boundary
        }
        return result
    }

    /// 라이트 뷰 공간 min/max → Metal NDC(x/y -1..1, z 0..1) 직교 VP. 가장자리 5% 여백 + 최소 두께.
    private static func ortho(view: simd_float4x4, lo rawLo: SIMD3<Float>,
                              hi rawHi: SIMD3<Float>) -> simd_float4x4 {
        // 가장자리 여백 5%(스키닝 애니의 바인드포즈 AABB 이탈 흡수) + 최소 두께(퇴화 상자 방지).
        let pad = simd_max((rawHi - rawLo) * 0.05, SIMD3<Float>(repeating: 1e-3))
        let lo = rawLo - pad
        let hi = rawHi + pad
        // RH 뷰: 가시 범위는 -Z. near = -hi.z(가장 가까움), far = -lo.z(가장 멂). pad 로 near<far 보장.
        let l = lo.x, r = hi.x, b = lo.y, t = hi.y
        let zn = -hi.z, zf = -lo.z
        // Metal NDC(x/y -1..1, z 0..1) 직교 투영. z: view z=-zn → 0, z=-zf → 1.
        let proj = simd_float4x4(columns: (
            SIMD4<Float>(2 / (r - l), 0, 0, 0),
            SIMD4<Float>(0, 2 / (t - b), 0, 0),
            SIMD4<Float>(0, 0, 1 / (zn - zf), 0),
            SIMD4<Float>((l + r) / (l - r), (b + t) / (b - t), zn / (zn - zf), 1)))
        return proj * view
    }
}

/// F662(S-45): scene-level fog(general.fogdistance*/fogheight*) + 머티리얼 FOG 콤보.
/// WE generic4.frag 는 common_fog.h `#if FOG_HEIGHT || FOG_DIST` 로 ApplyFog — 씬에 fog 필드가 있으면
/// FOG 콤보 기본값(1) 머티리얼 전부 참여. SceneDocument 가 general fog 를 미파스라(타 소유 파일)
/// 렌더러가 패키지 scene.json 을 직접 읽어 이 구조로 파스한다(SceneRenderer3D.build3D).
/// 파라미터 매핑(WE common_fog.h 정합): params=(start, end-start, startDensity, endDensity-startDensity)
///  — factor = z + w·saturate((d - x)/y)² 로 ApplyFog 식과 동일.
struct Scene3DFog: Equatable {
    var distanceEnabled = false
    var distanceColor = SIMD3<Float>(0, 0, 0)
    var distanceParams = SIMD4<Float>(0, 1, 0, 0)
    var heightEnabled = false
    var heightColor = SIMD3<Float>(0, 0, 0)
    var heightParams = SIMD4<Float>(0, 1, 0, 0)
    var enabled: Bool { distanceEnabled || heightEnabled }

    /// scene.json general 딕셔너리 → fog 설정. {user/script/animation, value} 바인딩은 초기값 언랩
    /// (SceneDocument unwrap/float/vec3 와 동일 의미론 — 사용자 오버라이드 미반영은 기존 파스와 동일 한계).
    static func parse(general: [String: Any]) -> Scene3DFog {
        var fog = Scene3DFog()
        if boolValue(general["fogdistance"]) {
            fog.distanceEnabled = true
            fog.distanceColor = vec3Value(general["fogdistancecolor"]) ?? SIMD3(0, 0, 0)
            fog.distanceParams = params(start: floatValue(general["fogdistancestart"]),
                                        end: floatValue(general["fogdistanceend"]),
                                        startDensity: floatValue(general["fogdistancestartdensity"]),
                                        endDensity: floatValue(general["fogdistanceenddensity"]))
        }
        if boolValue(general["fogheight"]) {
            fog.heightEnabled = true
            fog.heightColor = vec3Value(general["fogheightcolor"]) ?? SIMD3(0, 0, 0)
            fog.heightParams = params(start: floatValue(general["fogheightstart"]),
                                      end: floatValue(general["fogheightend"]),
                                      startDensity: floatValue(general["fogheightstartdensity"]),
                                      endDensity: floatValue(general["fogheightenddensity"]))
        }
        return fog
    }

    /// (start, end-start, startDensity, Δdensity). end==start 퇴화는 0 나눗셈 방지로 최소폭 보장.
    private static func params(start: Float?, end: Float?, startDensity: Float?, endDensity: Float?) -> SIMD4<Float> {
        let s = start ?? 0
        let e = end ?? 1
        let sd = startDensity ?? 0
        let ed = endDensity ?? 1
        var span = e - s
        if span.magnitude < 1e-4 { span = span < 0 ? -1e-4 : 1e-4 }
        return SIMD4(s, span, sd, ed - sd)
    }

    private static func unwrap(_ value: Any?) -> Any? {
        if let dict = value as? [String: Any], dict["value"] != nil { return dict["value"] }
        return value
    }

    private static func boolValue(_ value: Any?) -> Bool {
        switch unwrap(value) {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        default: return false
        }
    }

    private static func floatValue(_ value: Any?) -> Float? {
        switch unwrap(value) {
        case let f as Float: return f.isFinite ? f : nil
        case let d as Double: return d.isFinite ? Float(d) : nil
        case let i as Int: return Float(i)
        case let n as NSNumber: return n.floatValue
        case let s as String: return Float(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func vec3Value(_ value: Any?) -> SIMD3<Float>? {
        switch unwrap(value) {
        case let s as String:
            let parts = s.split(whereSeparator: { $0.isWhitespace }).compactMap { Float($0) }
            return parts.count >= 3 ? SIMD3(parts[0], parts[1], parts[2]) : nil
        case let a as [Any]:
            let parts = a.compactMap { floatValue($0) }
            return parts.count >= 3 ? SIMD3(parts[0], parts[1], parts[2]) : nil
        default: return nil
        }
    }
}
