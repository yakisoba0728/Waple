import Foundation

/// scene.json 효과 항목의 패스별 사용자 데이터(effect.json passes[] 와 인덱스 정렬).
public struct SceneEffectPass: Equatable {
    public var constants: [String: [Float]] = [:]
    /// 상수에 걸린 프로퍼티 스크립트(키 → JS 소스) — 렌더러가 per-frame 평가(컬러 사이클 등).
    public var constantScripts: [String: String] = [:]
    /// 상수 스크립트의 저장 `scriptproperties`(사용자 오버라이드) — 키 → JSON 문자열. 레이어/텍스트
    /// 스크립트와 동일 규약: 엔진 로드 시 주입해 소스 `createScriptProperties().addX({value})` 기본값 대체.
    public var constantScriptProps: [String: String] = [:]
    public var textureNames: [String?] = []
    public var combos: [String: Int] = [:]
    public init() {}
}

public struct SceneEffect: Equatable {
    public let name: String
    /// 원본 effect.json 경로(예: "effects/workshop/<wsid>/<Name>/effect.json"). GLSL 셰이더 해석에 필요 —
    /// 짧은 name 만으론 워크샵 wsid 경로가 유실된다. 스톡은 "effects/<name>/effect.json".
    public let file: String
    public let constants: [String: [Float]]
    /// object effect `textures[]` 슬롯 전체. slot0 은 보통 null(=framebuffer),
    /// 이후 슬롯이 마스크/노멀맵 등 보조 텍스처. 각 원소는 이름 또는 null.
    public let textureNames: [String?]
    /// passes[0].combos (예: AUDIOPROCESSING, BLENDMODE, PULSEALPHA, PULSECOLOR). 셰이더 변형 선택.
    public let combos: [String: Int]
    /// AUDIOPROCESSING 콤보(0=off,1=L,2=R,3=L+R). 오디오-반응 효과 식별.
    public var audioMode: Int { combos["AUDIOPROCESSING"] ?? 0 }
    /// 전체 패스 사용자 데이터(멀티패스 효과용; [0]은 기존 constants/textureNames/combos 와 동일).
    public var passList: [SceneEffectPass] = []

    public init(name: String, constants: [String: [Float]], textureNames: [String?], combos: [String: Int] = [:], file: String = "") {
        self.name = name; self.constants = constants; self.textureNames = textureNames; self.combos = combos; self.file = file
    }
}

public struct SceneLayer: Equatable {
    public let textureEntryName: String
    public var name: String = ""
    /// scene.json objects[] 의 id(부모 트랜스폼 룩업용 — 퍼펫 레이어 parent 체인 합성에 사용).
    public var id: Int = 0
    /// origin/scale/angleZ 는 원래 로컬(부모 상대)값. 퍼펫 레이어는 parse 말미에 부모 체인을 합성한
    /// 월드(프로젝션 픽셀) 트랜스폼으로 덮어쓴다(정적 부모 한정) — 그래서 var.
    public var origin: Vec2
    /// origin 의 3성분째(월드 z) — 2D 씬에선 무시(origin 은 씬 픽셀 xy). 3D 씬 빌보드가 월드 위치로 사용.
    public var originZ: Float = 0
    /// 부모 오브젝트 id(3D 씬 빌보드의 트랜스폼 계층 — 태양계 이미지는 대부분 그룹 노드에 붙는다). nil=루트.
    public var parent: Int? = nil
    public let size: Vec2
    public var scale: Vec2
    public var angleZ: Float
    public let alpha: Float
    public let color: Vec3
    public let brightness: Float
    public let parallaxDepth: Vec2
    public let effects: [SceneEffect]
    /// scene.json objects[] 내 인덱스 — WE 는 오브젝트 순서대로 그린다(파티클과 인터리브).
    public var order: Int = 0
    /// 컴포지션 레이어(_rt_FullFrameBuffer): 이 레이어의 소스는 "그 시점까지 합성된 프레임버퍼".
    /// textureEntryName 은 "" 이고 렌더러가 스냅샷을 src 로 바인드한다(설계 2026-07-02 컴포지션).
    public var isFrameBuffer: Bool = false
    /// 프로퍼티 애니메이션(키: origin/scale/alpha/angles/color). base 는 위 정적 필드.
    public var animations: [String: PropertyAnimation] = [:]
    /// 퍼펫 모델(.mdl) 경로 — model json 의 "puppet" 키(SP6 슬라이스 1). nil = 일반 쿼드.
    public var puppet: String? = nil
    /// 퍼펫 animationlayers(다층 캐스케이드 블렌드). 2+ 레이어면 렌더러가 포즈 합성, 0/1 이면 기존 단일 경로.
    public var animationLayers: [AnimationLayer] = []
    /// 프로퍼티 스크립트(color/alpha/visible — 키 → JS 소스). per-frame 평가(실물: 미디어 썸네일 컬러
    /// 전환, 주야 컨트롤러). visible 스크립트가 있는 레이어는 파스에서 드롭하지 않는다.
    public var propertyScripts: [String: String] = [:]
    /// 프로퍼티 스크립트의 저장된 `scriptproperties`(사용자 오버라이드) — 키 → JSON 문자열. WE 는 이 값을
    /// 스크립트의 scriptProperties 객체에 주입(소스 `addColor({value:new Vec3(1,1,1)})` 기본값 대체).
    /// 미주입 시 Background color 스크립트가 흰색 fallback 을 반환해 전화면 백화(3300031038). {user,value}
    /// 바인딩은 파스 시점에 정적 value 로 해석(resolveUserBindings 규약).
    public var propertyScriptProps: [String: String] = [:]
    /// 머티리얼 블렌드 모드("normal"|"additive"|"alphatocoverage"…). 3D 씬 빌보드가 파이프라인 선택에 사용
    /// (플레어/글로우 = additive). 2D는 additive만 전용 고정기능 파이프라인으로 소비하고 나머지는 premult-over 유지.
    public var blendMode: String = "normal"
    /// 3D 씬 빌보드용 머티리얼 depth 플래그. 2D 경로는 무시.
    public var depthTest: Bool = true
    public var depthWrite: Bool = true
    /// 오브젝트 colorBlendMode(common_blending.h ApplyBlending enum 0-32; 0=normal).
    /// != 0 이면 렌더러가 acc 스냅샷 대비 블렌드 합성(컴포지션 스냅샷 패턴). 코퍼스 121레이어/30씬.
    public var colorBlendMode: Int = 0
    /// visible 의 정적 value(초기 표시). visible 스크립트가 있을 때만 false 로도 남는다 —
    /// 스크립트 없는 정적 false 는 파스에서 레이어 자체가 드롭된다.
    public var initialVisible: Bool = true
    /// 이미지 정렬(9점 앵커, WE IImageLayer.alignment): center(기본)/top/bottom/left/right/
    /// topleft/topright/bottomleft/bottomright. origin 이 사각형의 어느 앵커점인지 결정 — 렌더러
    /// quadVertices/litRect 가 앵커 기준으로 코너 산출. center 는 origin=중심(기존 동작, 무회귀).
    public var alignment: String = "center"
    /// 머티리얼 패스에 SPRITESHEET 콤보가 있으면 true → 이 이미지 레이어는 .tex TEXS 프레임을 시간축
    /// 재생(gif). 렌더러가 이 게이트로만 프레임 전진(콤보 없는 genericimage2/4 는 정지 = 무회귀).
    /// 콤보 키는 대/소문자 혼재(실씬 "SPRITESHEET", 엔진 예제 "spritesheet") — 대소문자 무시 매치.
    public var spritesheet: Bool = false
    /// 머티리얼 패스에 LIGHTING 콤보(!=0)가 있으면 true → 이 레이어는 씬 라이트에 반응(포워드 라이팅).
    /// 2D 씬 + 라이트 존재 시에만 소비(SceneDocument.forwardLit2D). LIGHTING:0/부재는 기존 unlit 경로(무회귀).
    public var lighting: Bool = false
    /// genericimage4 scalar PBR constants from passes[0].constantshadervalues.
    public var roughness: Float = 0.7
    public var metallic: Float = 0
    public var specularTint: Vec3 = Vec3(x: 1, y: 1, z: 1)
}

/// 씬 내 파티클 시스템 인스턴스. def(파티클 정의) + 씬 배치(origin/scale, 씬 픽셀 좌표).
public struct SceneParticle: Equatable {
    public let def: ParticleSystemDef
    public let origin: Vec2
    public let scale: Vec2
    /// scene.json objects[] 내 인덱스(레이어와 공유하는 z-순서).
    public var order: Int = 0
    /// 3D 씬 배치(camera3D 마운트 경로 전용 — 2D 정사영 경로는 origin/scale Vec2 그대로 사용).
    /// 파티클 오브젝트의 3D 트랜스폼(전 성분)·부모 노드 id·정적 가시성. 2D 씬에선 기본값(미사용).
    public var origin3D: Vec3 = Vec3(x: 0, y: 0, z: 0)
    public var scale3D: Vec3 = Vec3(x: 1, y: 1, z: 1)
    public var angles3D: Vec3 = Vec3(x: 0, y: 0, z: 0)
    public var parent: Int? = nil
    public var visible: Bool = true
}

/// 텍스트 오브젝트(시계/날짜/곡정보 등). text 는 평문 또는 JS 프로퍼티 스크립트(script)로 계산.
public struct SceneTextLayer: Equatable {
    public var name: String = ""
    public let text: String              // 평문(스크립트면 "")
    public let script: String?           // {"script": ...} — update(value) 가 텍스트 반환
    /// 텍스트 스크립트의 저장 `scriptproperties`(사용자 오버라이드) — JSON 문자열. 레이어 프로퍼티
    /// 스크립트(propertyScriptProps)와 동일 규약: 미주입 시 소스 기본값 폴백(예 시계 24h/초 표시가
    /// 저작자 저장값 대신 스크립트 기본으로 되돌아감). script 부재 시 nil(무회귀).
    public var scriptProps: String? = nil
    public let font: String              // "systemfont_arial" | "fonts/....otf" (pkg/base-assets)
    public let pointSize: Float          // 씬 픽셀 단위 글자 크기
    public let color: Vec3
    public let alpha: Float
    public let horizontalAlign: String   // left|center|right (origin 앵커 기준)
    public let verticalAlign: String     // top|center|bottom
    public let origin: Vec2
    public let scale: Vec2               // 오브젝트 "size" 필드 = 배수(실측 "2 2")
    public var order: Int = 0
}

/// 3D 씬 카메라(2D 의 orthogonalprojection 대체). look-at 파라미터 + 원근 fov.
/// WE 규약: eye→center 방향으로 보고, up 은 카메라 상방. fov 는 세로 화각(도), near/far 는 클립면.
public struct SceneCamera3D: Equatable {
    public let eye: Vec3       // 카메라 위치(월드)
    public let center: Vec3    // 바라보는 지점(월드)
    public let up: Vec3        // 상방 벡터
    public let fov: Float      // 세로 화각(도)
    public let nearZ: Float
    public let farZ: Float
    public init(eye: Vec3, center: Vec3, up: Vec3, fov: Float, nearZ: Float, farZ: Float) {
        self.eye = eye; self.center = center; self.up = up
        self.fov = fov; self.nearZ = nearZ; self.farZ = farZ
    }
}

/// 3D 모델의 활성 애니메이션 선택(animationlayers 의 숫자 blend≥0.5 & visible 인 베이스 레이어).
/// name = 레이어 이름("Idle" 등, 렌더러가 모델 애니 이름에 서브스트링 매칭), rate = 재생 배속.
public struct AnimationSelection: Equatable {
    public let name: String
    public let rate: Float
    public init(name: String, rate: Float) { self.name = name; self.rate = rate }
}

/// animationlayers 의 개별 레이어(다층 캐스케이드 블렌드용 — 실측 확정 2026-07):
/// - name: 모델 애니 클립에 서브스트링 매칭할 레이어 이름(레이어 name ≈ 클립 name).
/// - additive: false = 절대 포즈(캐스케이드 lerp), true = 델타 가산(bind/이전 포즈 위에 클립 델타).
/// - blend: 블렌드 가중치(대개 1.0, 분수/키프레임 존재 — 키프레임은 초기값). 0..1 클램프 안 함.
/// - rate: 재생 배속(대개 1.0).
/// - visible: 레이어 활성(키프레임 가능 — 정적 초기값만 반영).
public struct AnimationLayer: Equatable {
    public let name: String
    public let additive: Bool
    public let blend: Float
    public let rate: Float
    public let visible: Bool
    /// blend/visible 바인딩의 프로퍼티 스크립트(키 → JS 소스) — 실물 animationEvent 훅의 주 서식지
    /// (3737268876 젤다 blend 핸들러 19개, 3351179520/3396722575 visible 핸들러). 렌더러가 엔진 생성.
    public var scripts: [String: String] = [:]
    /// blend/visible 바인딩의 이벤트 마커 타임라인(options.events 보유분만 — 젤다 "surprise" 등).
    /// 값 구동(blend 키프레임 적용)은 미구현 — 마커 발화 클록으로만 사용(정적 blend 무회귀).
    public var eventTimelines: [PropertyAnimation] = []
    public init(name: String, additive: Bool, blend: Float, rate: Float, visible: Bool) {
        self.name = name; self.additive = additive; self.blend = blend
        self.rate = rate; self.visible = visible
    }
}

/// 3D 메시 오브젝트. 2D 레이어(image→json→puppet 인다이렉션)와 달리 `model` 키가 pkg 의
/// `.mdl` 을 **직접** 참조한다. origin/angles/scale 은 모두 3성분(월드 좌표/오일러 라디안/축별 배율).
public struct SceneObject3D: Equatable {
    public let id: Int
    public let name: String
    public let model: String       // "models/.../X.mdl" — pkg 내 .mdl 직접 참조(2D image 우회)
    public let origin: Vec3        // 월드 위치
    public let angles: Vec3        // 오일러 X,Y,Z (라디안)
    public let scale: Vec3         // 축별 배율
    public let castShadow: Bool
    public let parent: Int?        // 부모 오브젝트 id(트랜스폼 계층) — 렌더러가 월드행렬 합성. nil=루트
    public let effects: [SceneEffect]
    /// scene.json objects[] 내 인덱스 — 그리기/계층 순서 참조.
    public var order: Int = 0
    /// 프로퍼티 스크립트(origin/angles/scale/visible — 키 → JS 소스). 렌더러가 per-frame 평가해 로컬
    /// 변환/가시성을 갱신(태양계 planet 은 부모 그룹 origin 스크립트가 궤도를 그린다). 정적 value 는
    /// 위 필드에 이미 언랩됨 — 스크립트는 재평가용.
    public var propertyScripts: [String: String] = [:]
    /// 활성 애니메이션(animationlayers 파스). nil = 정지(바인드 포즈). 렌더러가 이름 매칭 후 GPU 스키닝.
    public var animation: AnimationSelection? = nil
    /// animationlayers 전 레이어(스크립트·이벤트 타임라인 — 실물 젤다 blend 의 animationEvent 훅 서식지).
    /// 포즈 선택은 종전 `animation`(최고 blend 단일) 그대로 — 이 목록은 이벤트 발화·엔진 생성 전용(무회귀).
    public var animationLayers: [AnimationLayer] = []
    /// 프로퍼티 바인딩(origin/angles/scale/alpha/color)의 이벤트 마커 타임라인(options.events 보유분만).
    /// 값 구동은 미구현(3D 변환은 스크립트 경로) — 마커 발화 클록 전용(실물 젤다 walk_end/blink/change).
    public var eventTimelines: [PropertyAnimation] = []
    public init(id: Int, name: String, model: String, origin: Vec3, angles: Vec3, scale: Vec3,
                castShadow: Bool, parent: Int?, effects: [SceneEffect], order: Int = 0) {
        self.id = id; self.name = name; self.model = model
        self.origin = origin; self.angles = angles; self.scale = scale
        self.castShadow = castShadow; self.parent = parent; self.effects = effects; self.order = order
    }
}

/// 3D 트랜스폼-온리 노드(콘텐츠 키(image/model/particle/text/light) 없는 그룹 오브젝트).
/// 실물 3D 씬의 `parent` 계층은 대부분 이런 빈 그룹을 경유한다(젤다 "Rupee Root"/"Link",
/// 태양계 행성 피벗) — 렌더러가 월드행렬 합성과 서브트리 가시성 판정에 사용한다.
public struct SceneNode3D: Equatable {
    public let id: Int
    public let origin: Vec3
    public let angles: Vec3    // 오일러 라디안(SceneObject3D 와 동일 규약)
    public let scale: Vec3
    public let parent: Int?
    /// 정적 가시성(스크립트 바인딩은 초기 value). false 그룹의 서브트리는 렌더 제외
    /// (실물 3737268876: link_adult(false)/link_child(true) 교대 캐릭터).
    public let visible: Bool
    /// 프로퍼티 스크립트(origin/angles/scale/visible). 그룹 노드도 스크립트를 가진다 — 태양계 컨트롤러
    /// (Main: visible 스크립트로 shared 궤도 파라미터 세팅), 월드 스케일/화면 회전 노드(scale/angles 스크립트)가 모두 그룹.
    public var propertyScripts: [String: String] = [:]
    public init(id: Int, origin: Vec3, angles: Vec3, scale: Vec3, parent: Int?, visible: Bool) {
        self.id = id; self.origin = origin; self.angles = angles
        self.scale = scale; self.parent = parent; self.visible = visible
    }
}

/// 3D 라이트 오브젝트. type: "lpoint"(점) | "ldirectional"(방향) | "lspot"(스팟).
/// general.lightconfig 가 활성 라이트 종류/개수를 요약(point/directional/…shadow 카운트).
public struct SceneLight3D: Equatable {
    public let id: Int
    public let name: String
    public let type: String
    public let origin: Vec3
    public let angles: Vec3
    public let color: Vec3
    public let radius: Float
    public let intensity: Float
    public let exponent: Float
    /// lspot 콘 전각(도). WE 에디터 "Inner/Outer cone". lpoint/ldirectional 은 미사용(0).
    public let innerCone: Float
    public let outerCone: Float
    public let castShadow: Bool
    public let parent: Int?
    public var order: Int = 0
    public init(id: Int, name: String, type: String, origin: Vec3, angles: Vec3, color: Vec3,
                radius: Float, intensity: Float, exponent: Float,
                innerCone: Float = 0, outerCone: Float = 0,
                castShadow: Bool, parent: Int?, order: Int = 0) {
        self.id = id; self.name = name; self.type = type
        self.origin = origin; self.angles = angles; self.color = color
        self.radius = radius; self.intensity = intensity; self.exponent = exponent
        self.innerCone = innerCone; self.outerCone = outerCone
        self.castShadow = castShadow; self.parent = parent; self.order = order
    }
}

public extension SceneLight3D {
    /// WE 라이트 셰이더 유니폼 팩(generic.vert / genericimage2.frag 규약 — 실측 확정 2026-07):
    /// - `g_LightsPosition[4]`(vec3): 라이트 월드 위치(origin). 4 미만은 0 패딩.
    /// - `g_LightsColorPremultiplied[3]`(vec4): 4개 라이트의 (color×intensity)를 3×vec4 로 팩 —
    ///   라이트 0..2 는 `[i].rgb`, 라이트 3 은 `[0..2].w` 3채널에 분산(`[0].w,[1].w,[2].w = L3.r,g,b`).
    ///   ("Premultiplied" = color × intensity; 별도 intensity/radius 유니폼 없음.)
    /// - `ambient`: `general.ambientcolor`.
    ///
    /// > ⚠️ **이 legacy `PackedUniforms`의 현재 런타임 소비처는 없음.** 2D 포워드 라이팅은 별도
    /// > `ForwardUniforms`를 `QuadShaders.f_lit`에 공급한다. 라이트를 참조하는 원본 머티리얼 셰이더
    /// > (generic*/genericimage2)는 로드·번역되지 않으며, 번역되는 이펙트 셰이더는 코퍼스 전체 0건이
    /// > 이 legacy 팩을 참조한다. 이 함수는 향후 해당 규약 소비처 도입을 위해 **확정 규약**을 유닛으로
    /// > 고정해 두는 것이 목적(SP 리포트 참조).
    struct PackedUniforms: Equatable {
        public var positions: [SIMD3<Float>]           // g_LightsPosition[4]
        public var colorsPremultiplied: [SIMD4<Float>] // g_LightsColorPremultiplied[3]
        public var ambient: SIMD3<Float>               // g_LightAmbientColor
    }

    /// 라이트 배열 → 셰이더 유니폼 팩. 4개 초과 시 앞 4개(WE 는 오브젝트별 relevance 4개 선택 —
    /// 현행은 씬 순서 근사; 정확한 선택은 소비처와 함께 도입).
    static func packUniforms(_ lights: [SceneLight3D], ambient: Vec3 = Vec3(x: 0, y: 0, z: 0)) -> PackedUniforms {
        var positions = [SIMD3<Float>](repeating: .zero, count: 4)
        var premult = [SIMD3<Float>](repeating: .zero, count: 4)  // color×intensity, L0..L3
        for (i, l) in lights.prefix(4).enumerated() {
            positions[i] = SIMD3(l.origin.x, l.origin.y, l.origin.z)
            premult[i] = SIMD3(l.color.x, l.color.y, l.color.z) * l.intensity
        }
        let colors = [
            SIMD4(premult[0].x, premult[0].y, premult[0].z, premult[3].x),  // [0].rgb=L0, .w=L3.r
            SIMD4(premult[1].x, premult[1].y, premult[1].z, premult[3].y),  // [1].rgb=L1, .w=L3.g
            SIMD4(premult[2].x, premult[2].y, premult[2].z, premult[3].z),  // [2].rgb=L2, .w=L3.b
        ]
        return PackedUniforms(positions: positions, colorsPremultiplied: colors,
                              ambient: SIMD3(ambient.x, ambient.y, ambient.z))
    }

    /// 포워드 라이팅(2D)용 유니폼 — **실물 셰이더 규약** `common_fragment.h::ComputeLight` /
    /// `generic.vert` 소비 형태에 맞춘 별도 팩. 위 `packUniforms` 는 radius 없는 규약 스냅샷(소비처
    /// 없음)이라 감쇠에 못 쓴다 — 이 팩이 실 소비처(QuadShaders f_lit).
    /// - `positions[i]`: 라이트 월드 위치(프로젝션 픽셀), `.w`=유한광 감쇠 exponent.
    /// - `colorRadius[i]`: `rgb = color × intensity`, `w = radius`(선형 감쇠 반경).
    ///   ⚠️ **`color × intensity` 는 직전 라운드 추정 규약** — 셰이더 소스에 C++ 유니폼 피드가 없고
    ///   코퍼스 번역 이펙트 0건이 이 유니폼을 참조해 미확정. 블로아웃(고강도 씬)의 최대 레버(보고 참조).
    /// - `ambientTerm`: flat ambient (genericimage4).
    struct ForwardUniforms: Equatable {
        public var positions: [SIMD4<Float>]   // xyz=world, w=finite-light exponent
        public var colorRadius: [SIMD4<Float>] // rgb=color×intensity, w=radius
        public var ambientTerm: SIMD3<Float>
        public var count: Int
        public init(positions: [SIMD4<Float>], colorRadius: [SIMD4<Float>],
                    ambientTerm: SIMD3<Float>, count: Int) {
            self.positions = positions; self.colorRadius = colorRadius
            self.ambientTerm = ambientTerm; self.count = count
        }
    }

    /// 라이트 배열 → 포워드 유니폼. 4개 초과 시 앞 4개(현행 근사 — WE 오브젝트별 relevance 선택은 미구현).
    static func forwardUniforms(_ lights: [SceneLight3D], ambient: Vec3, skylight _: Vec3) -> ForwardUniforms {
        var pos = [SIMD4<Float>](repeating: .zero, count: 4)
        var cr = [SIMD4<Float>](repeating: .zero, count: 4)
        let used = lights.prefix(4)
        for (i, l) in used.enumerated() {
            pos[i] = SIMD4(l.origin.x, l.origin.y, l.origin.z, l.exponent)
            cr[i] = SIMD4(l.color.x * l.intensity, l.color.y * l.intensity, l.color.z * l.intensity, l.radius)
        }
        let amb = SIMD3(ambient.x, ambient.y, ambient.z)
        return ForwardUniforms(positions: pos, colorRadius: cr, ambientTerm: amb, count: used.count)
    }

}

/// 씬 sound 오브젝트(scene.json objects[] 중 "sound" 키 보유). 실측(코퍼스 460종 / 382오브젝트, 2026-07-09):
/// - playbackmode ∈ {loop 215, single 158, random 9}
/// - volume 은 숫자 또는 {user,value}/{script,value} 바인딩 — parse 에서 float() 가 언랩
/// - sound 배열은 대개 1개(349/382), 다중(33개, 2~18)은 전부 상이한 곡의 플레이리스트(순차/셔플 재생,
///   동시 아님 — 재생 의미는 SceneAudioPlayer 참조)
/// - startsilent(true 224 / false 157): true = 씬 시작 시 자동재생 안 함(WE 트리거/SceneScript 기동 대기;
///   single·parent 보유에 집중). mintime/maxtime(비-loop 재트리거 간격 추정)은 파스만 하고 미반영.
public struct SceneSound: Equatable {
    public let id: Int
    /// scene.json objects[] 의 "name"(트리거 스크립트의 `thisScene.getLayer(name).play()` 대상 — 실측: 사운드
    /// 오브젝트도 레이어처럼 name 으로 주소지정, 이름 없으면 파일 basename 근사). 빈 문자열이면 트리거 불가(자동재생 전용).
    public let name: String
    /// pkg 상대 경로 배열(예: "sounds/x.mp3"). 다중이면 플레이리스트(한 번에 한 곡).
    public let sounds: [String]
    /// 오서 볼륨 0…1. 재생 시 VideoSettings 배경별 설정과 곱해 최종 음량이 된다.
    public let volume: Float
    public let playbackMode: String    // "loop" | "single" | "random"
    public var loop: Bool { playbackMode == "loop" }
    /// true = 씬 시작 시 자동재생 안 함(트리거/스크립트 기동 대기). Waple 은 트리거 미지원 → 재생기가 스킵.
    public let startSilent: Bool
    /// 비-loop 재트리거 간격(초) 추정 — 파스만, 스케줄링 미구현.
    public let minTime: Float
    public let maxTime: Float
    public init(id: Int, name: String = "", sounds: [String], volume: Float, playbackMode: String,
                startSilent: Bool, minTime: Float, maxTime: Float) {
        self.id = id; self.name = name; self.sounds = sounds; self.volume = volume; self.playbackMode = playbackMode
        self.startSilent = startSilent; self.minTime = minTime; self.maxTime = maxTime
    }
}

public struct SceneDocument: Equatable {
    public let projectionWidth: Int
    public let projectionHeight: Int
    public let clearColor: Vec3
    public let parallaxEnabled: Bool
    public let parallaxAmount: Float
    public let parallaxMouseInfluence: Float
    /// WE `cameraparallaxdelay` — 카메라 시차 지연 시상수(초). 렌더러가 프레임 dt 기반 지수 스무딩에 사용.
    /// 0 = 즉시 반영(스무딩 없음). 실측 기본 0.1, 범위 0.03..2.0(전 코퍼스 >0).
    public let parallaxDelay: Float
    public let layers: [SceneLayer]
    public let particles: [SceneParticle]
    public var texts: [SceneTextLayer] = []
    /// 3D 씬 카메라 — orthogonalprojection 부재(null) + camera{eye,center,up} + fov 존재 시 세팅. 2D=nil.
    public var camera3D: SceneCamera3D? = nil
    /// 카메라 프로퍼티 스크립트(키: eye/center/up/fov → JS 소스). 렌더러가 per-frame 재평가(카메라 애니).
    /// 실물 젤다 fov 는 {"script":…,"value":50}; Sonic eye/center 는 정적 문자열(무스크립트). base 값은 camera3D.
    public var cameraScripts: [String: String] = [:]
    /// 3D 메시 오브젝트(`.mdl` 직접 참조). 2D 씬에서는 빈 배열.
    public var objects3D: [SceneObject3D] = []
    /// 3D 라이트 오브젝트.
    public var lights3D: [SceneLight3D] = []
    /// 트랜스폼-온리 그룹 노드(parent 계층 합성용). 비가시(false) 노드도 기록 — 서브트리 판정에 필요.
    public var nodes3D: [SceneNode3D] = []
    /// 씬 sound 오브젝트. 2D/3D 무관 전역 재생(트랜스폼/공간화는 미반영). 렌더러(SceneAudioPlayer)가 재생.
    public var sounds: [SceneSound] = []
    /// `general.ambientcolor` — 포워드 라이팅의 앰비언트 바닥(라이트 미도달 영역이 전흑되지 않게).
    public var ambientColor: Vec3 = Vec3(x: 0, y: 0, z: 0)
    /// `general.skylightcolor` — 부재 시 ambientcolor 로 폴백. 2D genericimage4 포워드 경로는
    /// flat ambient 만 소비하므로 이 값은 사용하지 않는다.
    public var skylightColor: Vec3 = Vec3(x: 0, y: 0, z: 0)

    /// `general.hdr` — HDR 씬 플래그. true 면 렌더러가 float(rgba16Float) 누적 버퍼 + 톤맵 패스로
    /// >1.0 합을 [0,1] 로 압축한다(종전 bgra8 하드클램프 = 밝은 영역 순백 "백화" 방지).
    /// WE combine_srgb/hdr_upsample 경로 대응(lane-04 §1.2). 부재 시 false = 종전 LDR 경로(무회귀).
    public var hdr: Bool = false
    /// `general.bloom` — fixed two-stage LDR bloom request. Renderer activation additionally requires `!general.hdr`.
    public var bloom: Bool = false
    /// WE fixed two-stage LDR bloom parameters. Strength/threshold remain authored finite values without clamps.
    public var bloomStrength: Float = 2
    public var bloomThreshold: Float = 0.65
    public var bloomTint: Vec3 = Vec3(x: 1, y: 1, z: 1)
    public var bloomHDRStrength: Float = 0
    public var bloomHDRThreshold: Float = 0

    /// 2D 포워드 라이팅 활성 조건: 2D 오르토 씬(camera3D==nil) + 라이트 존재. 3D(원근) 씬은 메시
    /// 라이팅 경로 담당(현행 미구현 — 보고). 개별 레이어는 `SceneLayer.lighting`(LIGHTING 콤보)로 추가 게이트.
    public var forwardLit2D: Bool { camera3D == nil && !lights3D.isEmpty }
}

public enum SceneDocumentError: Error, Equatable { case noScene }

public enum SharedAssetProbeResult {
    case data(Data)
    case missing
    case rejected
}

extension SceneDocument {
    /// - assets: 공유(base-assets) 리졸버 — pkg 에 없는 모델/머티리얼 JSON(models/util/solidlayer.json 등)의
    ///   폴백. WapleCore 는 순수하므로 파일 IO 는 호출자가 클로저로 주입한다(렌더러: BaseAssetsSettings 디렉터리).
    /// - userProps: 유저 속성 오버라이드(키 → 값). scene.json 의 `{"user": "키", "value": 기본}` 바인딩을
    ///   파스 전에 트리 전체에서 일괄 해석한다(visible/alpha/color/effect 상수 등 모든 바인딩 지점 공통).
    public static func parse(
        package: ScenePackage,
        assets: ((String) -> Data?)? = nil,
        sharedAssetProbe: ((String) -> SharedAssetProbeResult)? = nil,
        onMissingRequiredAsset: (() -> Void)? = nil,
        userProps: [String: Any] = [:]
    ) throws -> SceneDocument {
        guard let sceneData = package.data(for: "scene.json") ?? package.data(for: "gifscene.json"),
              var scene = (try? JSONSerialization.jsonObject(with: sceneData)) as? [String: Any] else {
            throw SceneDocumentError.noScene
        }
        if !userProps.isEmpty {
            scene = (resolveUserBindings(scene, userProps: userProps, depth: 0) as? [String: Any]) ?? scene
        }
        let general = scene["general"] as? [String: Any] ?? [:]
        let proj = general["orthogonalprojection"] as? [String: Any] ?? [:]
        let pw = intVal(proj["width"]) ?? 1920
        let ph = intVal(proj["height"]) ?? 1080
        let clear = vec3(general["clearcolor"]) ?? Vec3(x: 0, y: 0, z: 0)
        let ambientColor = vec3(general["ambientcolor"]) ?? Vec3(x: 0, y: 0, z: 0)
        let skylightColor = vec3(general["skylightcolor"]) ?? ambientColor
        // HDR/블룸 플래그 — 종전 조용히 폐기(lane-04 §2.1). {"user":…,"value":Bool} 바인딩은 unwrap 이 처리.
        let hdr = (unwrap(general["hdr"]) as? Bool) ?? false
        let bloom = (unwrap(general["bloom"]) as? Bool) ?? false
        // {"user":…,"value":Bool} 바인딩 형태(실물 21씬)는 unwrap 이 value 를 꺼낸다(평문 Bool 은 그대로).
        let parallaxEnabled = (unwrap(general["cameraparallax"]) as? Bool) ?? false
        let parallaxAmount = float(general["cameraparallaxamount"]) ?? 1
        let parallaxMouseInfluence = float(general["cameraparallaxmouseinfluence"]) ?? 1
        // 부재 시 0(즉시) — 무회귀. 실물은 전부 필드 보유(기본 0.1).
        let parallaxDelay = max(0, float(general["cameraparallaxdelay"]) ?? 0)

        // 3D 카메라(orthogonalprojection 이 딕셔너리가 아닌 3D 씬 + camera{eye,center,up}+fov 존재 시). 2D=nil.
        let (camera3D, cameraScripts) = parseCamera(scene: scene, general: general)

        var layers: [SceneLayer] = []
        var particles: [SceneParticle] = []
        var texts: [SceneTextLayer] = []
        var objects3D: [SceneObject3D] = []
        var lights3D: [SceneLight3D] = []
        var nodes3D: [SceneNode3D] = []
        var sounds: [SceneSound] = []
        let resolvedAssets: ((String) -> Data?)?
        if let sharedAssetProbe {
            resolvedAssets = { name in
                guard case .data(let data) = sharedAssetProbe(name) else { return nil }
                return data
            }
        } else {
            resolvedAssets = assets
        }
        let imageLayerCompositeIDs = referencedImageLayerCompositeIDs(in: package)
        for (order, any) in (scene["objects"] as? [Any] ?? []).enumerated() {
            guard let obj = any as? [String: Any] else { continue }
            // 사운드 오브젝트("sound" 키): 트랜스폼/계층 무시(전역 재생), 실측 필드만 파스.
            // 콘텐츠 키(image/model/…)가 없어 아래 그룹-노드 분기로 새면 nodes3D 로 오분류되므로 먼저 처리.
            if obj["sound"] is [Any] {
                if let s = parseSound(obj) { sounds.append(s) }
                continue
            }
            // `visible` 은 평문 불리언 | 바인딩 객체 {"value":Bool, "script":JS} 두 형태. 스크립트가 있는
            // 이미지 레이어는 정적 false 여도 유지(런타임 토글 + 컨트롤러 top-level 사이드이펙트 —
            // 실물 3394601417 'bt') — 그 외 오브젝트는 정적 false 시 기존대로 드롭.
            var initialVisible = true
            var visibleScript: String? = nil
            var visibleScriptProps: String? = nil
            if let b = obj["visible"] as? Bool { initialVisible = b }
            else if let vis = obj["visible"] as? [String: Any] {
                if let v = vis["value"] as? Bool { initialVisible = v }
                visibleScript = vis["script"] as? String
                if visibleScript != nil { visibleScriptProps = Self.scriptPropsJSON(vis["scriptproperties"]) }
            }
            // 트랜스폼-온리 그룹(콘텐츠 키 없음 + id 보유): 계층 노드로 기록(비가시도 포함 — 서브트리
            // 가시성 판정에 필요)하고 다음으로. 종전에는 조용히 버려져 parent 참조가 끊겼다.
            if let node = parseNode(obj, initialVisible: initialVisible, visibleScript: visibleScript) {
                nodes3D.append(node)
                continue
            }
            let objectID = intVal(obj["id"]) ?? 0
            if !initialVisible && visibleScript == nil && !imageLayerCompositeIDs.contains(objectID) {
                // V06: 정적 비가시 콘텐츠 오브젝트도 id 가 있으면 트랜스폼을 비가시 노드로 보존 —
                // 가시 자식의 parent 체인 합성(2D composeParentTransforms localT·3D nodeMap)이 끊기지
                // 않게 한다. 렌더 대상(layers/objects3D/…)에는 계속 미포함(무회귀).
                if intVal(obj["id"]) != nil {
                    nodes3D.append(SceneNode3D(
                        id: objectID,
                        origin: vec3(obj["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
                        angles: vec3(obj["angles"]) ?? Vec3(x: 0, y: 0, z: 0),
                        scale: vec3(obj["scale"]) ?? Vec3(x: 1, y: 1, z: 1),
                        parent: intVal(obj["parent"]),
                        visible: false))
                }
                continue
            }
            // 콘텐츠 키 접근은 contentValue 로 NSNull 정규화(존재 판정과 동일 규약).
            if let imagePath = contentValue(obj["image"]) as? String {
                if let layer = parseLayer(obj, imagePath: imagePath, order: order, pw: pw, ph: ph,
                                          package: package, assets: resolvedAssets,
                                          sharedAssetProbe: sharedAssetProbe,
                                          missingRequiredAsset: onMissingRequiredAsset,
                                          userProps: userProps,
                                          visibleScript: visibleScript, visibleScriptProps: visibleScriptProps,
                                          initialVisible: initialVisible) {
                    layers.append(layer)
                }
            } else if let particlePath = contentValue(obj["particle"]) as? String {
                if var p = parseParticle(particlePath, obj: obj, package: package,
                                         initialVisible: initialVisible) {
                    p.order = order
                    particles.append(p)
                }
            } else if contentValue(obj["text"]) != nil {
                texts.append(parseText(obj, order: order))
            } else if let modelPath = contentValue(obj["model"]) as? String {
                objects3D.append(parseModel(obj, modelPath: modelPath, order: order, visibleScript: visibleScript))
            } else if let lightType = contentValue(obj["light"]) as? String {
                lights3D.append(parseLight(obj, lightType: lightType, order: order))
            }
        }
        // 레이어 parent 체인 합성(부모의 origin/scale/angle 을 이어붙여 로컬→월드 픽셀로 굽는다).
        composeParentTransforms(
            layers: &layers,
            nodes3D: nodes3D,
            camera3D: camera3D,
            package: package,
            assets: resolvedAssets)
        var out = SceneDocument(projectionWidth: pw, projectionHeight: ph, clearColor: clear,
                                parallaxEnabled: parallaxEnabled, parallaxAmount: parallaxAmount,
                                parallaxMouseInfluence: parallaxMouseInfluence, parallaxDelay: parallaxDelay,
                                layers: layers, particles: particles,
                                texts: texts, camera3D: camera3D, objects3D: objects3D, lights3D: lights3D,
                                nodes3D: nodes3D)
        out.cameraScripts = cameraScripts
        out.sounds = sounds
        out.ambientColor = ambientColor
        out.skylightColor = skylightColor
        out.hdr = hdr
        out.bloom = bloom
        // LDR uses the WE defaults; float/vec3 retain numeric-string and {value} unwrapping without clamps.
        out.bloomStrength = float(general["bloomstrength"]) ?? 2
        out.bloomThreshold = float(general["bloomthreshold"]) ?? 0.65
        out.bloomTint = vec3(general["bloomtint"]) ?? Vec3(x: 1, y: 1, z: 1)
        out.bloomHDRStrength = float(general["bloomhdrstrength"]) ?? 0
        out.bloomHDRThreshold = float(general["bloomhdrthreshold"]) ?? 0
        return out
    }

    /// Runtime composite materials reference hidden image layers by `_rt_imageLayerComposite_<id>_a`.
    /// Those source layers are usually `visible:false`, but their texture is still needed by 3D materials.
    private static func referencedImageLayerCompositeIDs(in package: ScenePackage) -> Set<Int> {
        var out: Set<Int> = []
        let pattern = #"_rt_imageLayerComposite_(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        for entry in package.entries where entry.name.hasSuffix(".json") {
            guard let data = package.data(for: entry.name),
                  let text = String(data: data, encoding: .utf8),
                  text.contains("_rt_imageLayerComposite_") else { continue }
            let ns = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: ns) where match.numberOfRanges > 1 {
                guard let range = Range(match.range(at: 1), in: text),
                      let id = Int(text[range]) else { continue }
                out.insert(id)
            }
        }
        return out
    }

    /// 이미지 레이어("image": .tex 엔트리 | solid | framebuffer). resolveLayerTexture 실패 시 nil(레이어 없음).
    /// 애니(PropertyAnimation)·프로퍼티 스크립트·퍼펫·블렌드·부모/id/originZ 를 obj 에서 채운다.
    private static func parseLayer(_ obj: [String: Any], imagePath: String, order: Int, pw: Int, ph: Int,
                                   package: ScenePackage, assets: ((String) -> Data?)?,
                                   sharedAssetProbe: ((String) -> SharedAssetProbeResult)?,
                                   missingRequiredAsset: (() -> Void)?,
                                   userProps: [String: Any],
                                   visibleScript: String?, visibleScriptProps: String? = nil,
                                   initialVisible: Bool) -> SceneLayer? {
        guard let resolved = resolveLayerTexture(
            imagePath: imagePath,
            package: package,
            assets: assets,
            sharedAssetProbe: sharedAssetProbe,
            missingRequiredAsset: missingRequiredAsset,
            userProps: userProps
        ) else {
            return nil  // 사유별 로그는 resolveLayerTexture 내부에서.
        }
        let angles = floats(obj["angles"])
        var origin = vec2(obj["origin"]) ?? Vec2(x: 0, y: 0)
        var size = vec2(obj["size"]) ?? Vec2(x: Float(pw), y: Float(ph))
        var scale = vec2(obj["scale"]) ?? Vec2(x: 1, y: 1)
        let entryName: String
        var isFB = false
        switch resolved {
        case .entry(let name): entryName = name
        case .solid: entryName = ""
        case .frameBuffer(let fullscreen):
            entryName = ""; isFB = true
            if fullscreen {  // fullscreen 모델은 오브젝트 size 와 무관하게 프로젝션 전체.
                origin = Vec2(x: Float(pw) / 2, y: Float(ph) / 2)
                size = Vec2(x: Float(pw), y: Float(ph))
                scale = Vec2(x: 1, y: 1)
            }
        }
        var anims: [String: PropertyAnimation] = [:]
        var propScripts: [String: String] = [:]
        var propScriptProps: [String: String] = [:]
        for key in ["origin", "scale", "alpha", "angles", "color"] {
            if let bind = obj[key] as? [String: Any], let a = PropertyAnimation.parse(bind) {
                anims[key] = a
            }
            if let bind = obj[key] as? [String: Any], let sc = bind["script"] as? String {
                propScripts[key] = sc  // 정적 value 는 기존 언랩이 처리 — 스크립트는 per-frame 재평가
                if let j = Self.scriptPropsJSON(bind["scriptproperties"]) { propScriptProps[key] = j }
            }
        }
        if let vs = visibleScript { propScripts["visible"] = vs }
        if let j = visibleScriptProps { propScriptProps["visible"] = j }
        // 퍼펫 모델: model json 의 "puppet" 키(스키닝 메시 — 렌더러가 .mdl 로드).
        // 겸사겸사 머티리얼 blending 을 캡처(3D 빌보드 additive 파이프라인 선택 — 플레어/글로우).
        var puppetPath: String? = nil
        var blendMode = "normal"
        var depthTest = true
        var depthWrite = true
        var spritesheetCombo = false
        var lightingCombo = false
        var roughness: Float = 0.7
        var metallic: Float = 0
        var specularTint = Vec3(x: 1, y: 1, z: 1)
        if let md = package.data(for: imagePath) ?? assets?(imagePath),
           let mj = (try? JSONSerialization.jsonObject(with: md)) as? [String: Any] {
            puppetPath = mj["puppet"] as? String
            if let matPath = mj["material"] as? String,
               let matD = package.data(for: matPath) ?? assets?(matPath),
               let matJ = (try? JSONSerialization.jsonObject(with: matD)) as? [String: Any],
               let p0 = (matJ["passes"] as? [Any])?.first as? [String: Any] {
                if let bl = p0["blending"] as? String { blendMode = bl }
                depthTest = (p0["depthtest"] as? String) != "disabled"
                depthWrite = (p0["depthwrite"] as? String) != "disabled"
                // SPRITESHEET 콤보(대/소문자 무시, 값 !=0) → 이 레이어는 .tex TEXS 프레임 시간축 재생.
                // LIGHTING 콤보(!=0) → 포워드 라이팅 대상(씬 라이트에 반응). 둘 다 대소문자 무시 매치.
                if let combos = p0["combos"] as? [String: Any] {
                    spritesheetCombo = combos.contains { $0.key.lowercased() == "spritesheet" && (intVal($0.value) ?? 0) != 0 }
                    lightingCombo = combos.contains { $0.key.lowercased() == "lighting" && (intVal($0.value) ?? 0) != 0 }
                }
                if let constants = p0["constantshadervalues"] as? [String: Any] {
                    roughness = float(constants["roughness"]) ?? roughness
                    metallic = float(constants["metallic"]) ?? metallic
                    specularTint = vec3(constants["speculartint"]) ?? specularTint
                }
            }
        }
        var layer = SceneLayer(
            textureEntryName: entryName,
            origin: origin,
            size: size,
            scale: scale,
            angleZ: angles.count >= 3 ? angles[2] : 0,
            alpha: float(obj["alpha"]) ?? 1,
            color: vec3(obj["color"]) ?? Vec3(x: 1, y: 1, z: 1),
            brightness: float(obj["brightness"]) ?? 1,
            parallaxDepth: vec2(obj["parallaxDepth"]) ?? Vec2(x: 1, y: 1),
            effects: parseEffects(obj["effects"]),
            order: order,
            isFrameBuffer: isFB,
            animations: anims
        )
        layer.name = (obj["name"] as? String) ?? ""
        layer.puppet = puppetPath
        if puppetPath != nil { layer.animationLayers = parseAllAnimationLayers(obj["animationlayers"]) }
        layer.propertyScripts = propScripts
        layer.propertyScriptProps = propScriptProps
        layer.initialVisible = initialVisible
        layer.blendMode = blendMode
        layer.depthTest = depthTest
        layer.depthWrite = depthWrite
        layer.spritesheet = spritesheetCombo
        layer.lighting = lightingCombo
        layer.roughness = roughness
        layer.metallic = metallic
        layer.specularTint = specularTint
        layer.colorBlendMode = intVal(obj["colorBlendMode"]) ?? 0
        // 3D 씬 빌보드용: origin 의 z 성분(월드)과 부모 계층 보존(2D 경로는 origin.xy 만 사용 — 무영향).
        let originFull = floats(obj["origin"])
        layer.originZ = originFull.count >= 3 ? originFull[2] : 0
        layer.parent = intVal(obj["parent"])
        layer.id = intVal(obj["id"]) ?? 0
        layer.alignment = (obj["alignment"] as? String) ?? "center"
        return layer
    }

    /// 3D 카메라 + 프로퍼티 스크립트. orthogonalprojection 이 딕셔너리가 아니고(3D 씬은 null)
    /// camera{eye,center,up} + general.fov 가 있을 때만 카메라 반환(2D=nil). fov 는 float() 언랩 —
    /// 실물(젤다)은 {"script":…,"value":50} 스크립트 프로퍼티. eye/center/up 은 scene.camera, fov 는 general.
    private static func parseCamera(scene: [String: Any], general: [String: Any]) -> (camera: SceneCamera3D?, scripts: [String: String]) {
        guard !(general["orthogonalprojection"] is [String: Any]),
              let camDict = scene["camera"] as? [String: Any],
              let eye = vec3(camDict["eye"]), let center = vec3(camDict["center"]),
              let up = vec3(camDict["up"]), let fov = float(general["fov"]) else { return (nil, [:]) }
        let camera = SceneCamera3D(eye: eye, center: center, up: up, fov: fov,
                                   nearZ: float(general["nearz"]) ?? 0.01,
                                   farZ: float(general["farz"]) ?? 10000)
        var scripts: [String: String] = [:]
        // 카메라 프로퍼티 스크립트 캡처(per-frame 재평가용).
        for (key, src) in [("eye", camDict["eye"]), ("center", camDict["center"]), ("up", camDict["up"])] {
            if let d = src as? [String: Any], let sc = d["script"] as? String { scripts[key] = sc }
        }
        if let d = general["fov"] as? [String: Any], let sc = d["script"] as? String { scripts["fov"] = sc }
        return (camera, scripts)
    }

    /// 사운드 오브젝트("sound" 배열) → SceneSound. 빈 경로면 nil(호출부는 sound 키 존재 시 항상 continue).
    private static func parseSound(_ obj: [String: Any]) -> SceneSound? {
        let paths = (obj["sound"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard !paths.isEmpty else { return nil }
        // multi(플레이리스트)/startsilent(트리거 대기)는 의미 확정·재생기 반영(2026-07-09) — "unhandled" 로그 제거.
        return SceneSound(
            id: intVal(obj["id"]) ?? 0,
            name: (obj["name"] as? String) ?? "",
            sounds: paths,
            volume: float(obj["volume"]) ?? 1,   // float() 가 숫자/{value} 바인딩 공통 언랩
            playbackMode: (obj["playbackmode"] as? String) ?? "single",
            startSilent: (obj["startsilent"] as? Bool) ?? false,
            minTime: float(obj["mintime"]) ?? 0,
            maxTime: float(obj["maxtime"]) ?? 0)
    }

    /// 트랜스폼-온리 그룹 노드: 콘텐츠 키 없음 + id 보유 시 SceneNode3D(비가시도 포함 — 서브트리 판정에 필요).
    /// 콘텐츠 키가 있거나 id 없으면 nil(호출부가 레이어/컨텐츠 분기로 진행).
    private static func parseNode(_ obj: [String: Any], initialVisible: Bool, visibleScript: String?) -> SceneNode3D? {
        guard !["image", "model", "particle", "text", "light"].contains(where: { contentValue(obj[$0]) != nil }),
              let nodeID = intVal(obj["id"]) else { return nil }
        var node = SceneNode3D(
            id: nodeID,
            origin: vec3(obj["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
            angles: vec3(obj["angles"]) ?? Vec3(x: 0, y: 0, z: 0),
            scale: vec3(obj["scale"]) ?? Vec3(x: 1, y: 1, z: 1),
            parent: intVal(obj["parent"]),
            visible: initialVisible)
        var ps = transformScripts(obj)
        if let vs = visibleScript { ps["visible"] = vs }
        node.propertyScripts = ps
        return node
    }

    /// 텍스트 레이어("text": 평문 문자열 | {"value": 초기값, "script": JS} 바인딩 — 둘 다 보유 가능).
    /// script 는 update(current) 로 갱신되므로 value 는 초기 표시값으로도 쓰인다(실물 29씬/136오브젝트).
    private static func parseText(_ obj: [String: Any], order: Int) -> SceneTextLayer {
        var plain = ""
        var script: String? = nil
        var scriptProps: String? = nil
        if let s = obj["text"] as? String { plain = s }
        else if let d = obj["text"] as? [String: Any] {
            script = d["script"] as? String
            plain = (d["value"] as? String) ?? ""
            // 레이어 프로퍼티 스크립트(line 500)와 동일 게이트: 스크립트가 있을 때만 오버라이드 보존.
            if script != nil { scriptProps = Self.scriptPropsJSON(d["scriptproperties"]) }
        }
        return SceneTextLayer(
            name: (obj["name"] as? String) ?? "",
            text: plain, script: script, scriptProps: scriptProps,
            font: (obj["font"] as? String) ?? "systemfont_arial",
            pointSize: float(obj["pointsize"]) ?? 16,
            color: vec3(obj["color"]) ?? Vec3(x: 1, y: 1, z: 1),
            alpha: float(obj["alpha"]) ?? 1,
            horizontalAlign: (obj["horizontalalign"] as? String) ?? "center",
            verticalAlign: (obj["verticalalign"] as? String) ?? "center",
            origin: vec2(obj["origin"]) ?? Vec2(x: 0, y: 0),
            scale: vec2(obj["scale"]) ?? Vec2(x: 1, y: 1),  // 배율은 scale 필드 — size 는 레이아웃 박스(오독 시 거대 글리프)
            order: order)
    }

    /// 3D 메시 오브젝트("model": `.mdl` 직접 참조 — 2D image→json→puppet 인다이렉션 우회). angles 는 라디안.
    private static func parseModel(_ obj: [String: Any], modelPath: String, order: Int, visibleScript: String?) -> SceneObject3D {
        var o = SceneObject3D(
            id: intVal(obj["id"]) ?? 0,
            name: (obj["name"] as? String) ?? "",
            model: modelPath,
            origin: vec3(obj["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
            angles: vec3(obj["angles"]) ?? Vec3(x: 0, y: 0, z: 0),
            scale: vec3(obj["scale"]) ?? Vec3(x: 1, y: 1, z: 1),
            castShadow: (obj["castshadow"] as? Bool) ?? false,
            parent: intVal(obj["parent"]),
            effects: parseEffects(obj["effects"]),
            order: order)
        var ps = transformScripts(obj)
        if let vs = visibleScript { ps["visible"] = vs }
        o.propertyScripts = ps
        o.animation = parseAnimationLayers(obj["animationlayers"])
        o.animationLayers = parseAllAnimationLayers(obj["animationlayers"])
        for key in ["origin", "angles", "scale", "alpha", "color"] {
            if let bind = obj[key] as? [String: Any], let a = PropertyAnimation.parse(bind), !a.events.isEmpty {
                o.eventTimelines.append(a)
            }
        }
        return o
    }

    /// 3D 라이트 오브젝트("light": 타입 문자열 + 위치/색/반경/강도 등).
    private static func parseLight(_ obj: [String: Any], lightType: String, order: Int) -> SceneLight3D {
        SceneLight3D(
            id: intVal(obj["id"]) ?? 0,
            name: (obj["name"] as? String) ?? "",
            type: lightType,
            origin: vec3(obj["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
            angles: vec3(obj["angles"]) ?? Vec3(x: 0, y: 0, z: 0),
            color: vec3(obj["color"]) ?? Vec3(x: 1, y: 1, z: 1),
            radius: float(obj["radius"]) ?? 0,
            intensity: float(obj["intensity"]) ?? 1,
            exponent: float(obj["exponent"]) ?? 1,
            innerCone: float(obj["innercone"]) ?? 0,
            outerCone: float(obj["outercone"]) ?? 0,
            castShadow: (obj["castshadow"] as? Bool) ?? false,
            parent: intVal(obj["parent"]),
            order: order)
    }

    /// 레이어 parent 체인 합성: 부모(트랜스폼 그룹 노드/레이어)의 origin/scale/angle 을 이어붙여
    /// 로컬(부모 상대)좌표를 월드(프로젝션 픽셀)로 굽는다 — 예: Hollow Knight 3598808038 의 knight/sword 는
    /// 부모 "PUPPET"(origin 1920,1080/scale 0.72)에 붙고, 3577990983 의 '背景'(origin 부재)은
    /// 그룹 노드(1920,1080)에 붙는다(미합성 시 (0,0) → 흑화면). 부모는 정적 가정.
    /// 퍼펫 파스 실패(폴백 쿼드) 레이어만 종전 위치 유지(luma 가드). **2D 한정**: 3D 씬(camera3D)의
    /// 이미지 레이어는 빌보드 — 렌더러(encodeBillboard)가 부모 월드행렬을 매 프레임 합성(파스-시 합성은 이중 적용 → 제외).
    private static func composeParentTransforms(layers: inout [SceneLayer], nodes3D: [SceneNode3D],
                                                camera3D: SceneCamera3D?, package: ScenePackage,
                                                assets: ((String) -> Data?)?) {
        func puppetLoads(_ path: String) -> Bool {
            guard let d = package.data(for: path) ?? assets?(path) else { return false }
            return PuppetModel.parse(d) != nil || Model3D.parse(d) != nil
        }
        let composeTargets = camera3D != nil ? [] : layers.indices.filter {
            guard layers[$0].parent != nil else { return false }
            if let pp = layers[$0].puppet { return puppetLoads(pp) }
            return true
        }
        guard !composeTargets.isEmpty else { return }
        var localT: [Int: (origin: Vec2, scale: Vec2, angle: Float)] = [:]
        var parentOf: [Int: Int] = [:]
        for l in layers where l.id != 0 {
            localT[l.id] = (l.origin, l.scale, l.angleZ)
            if let p = l.parent { parentOf[l.id] = p }
        }
        for n in nodes3D {
            localT[n.id] = (Vec2(x: n.origin.x, y: n.origin.y), Vec2(x: n.scale.x, y: n.scale.y), n.angles.z)
            if let p = n.parent { parentOf[n.id] = p }
        }
        // angle 은 도(°) 단위(레이어 규약; puppetVertices 가 렌더 시 라디안 변환) — 부모 오프셋 회전은
        // 라디안으로 계산하되 합성 각은 도로 유지한다.
        func world(_ id: Int, _ depth: Int) -> (origin: Vec2, scale: Vec2, angle: Float)? {
            guard depth < 32, let t = localT[id] else { return nil }
            guard let pid = parentOf[id], let pw = world(pid, depth + 1) else { return t }
            let r = pw.angle * .pi / 180
            let ca = cosf(r), sa = sinf(r)
            let sx = pw.scale.x * t.origin.x, sy = pw.scale.y * t.origin.y
            return (origin: Vec2(x: pw.origin.x + sx * ca - sy * sa, y: pw.origin.y + sx * sa + sy * ca),
                    scale: Vec2(x: pw.scale.x * t.scale.x, y: pw.scale.y * t.scale.y),
                    angle: pw.angle + t.angle)
        }
        for i in composeTargets {
            guard let wt = world(layers[i].id, 0) else { continue }
            layers[i].origin = wt.origin
            layers[i].scale = wt.scale
            layers[i].angleZ = wt.angle
        }
    }

    /// animationlayers → 활성 베이스 애니(숫자 blend≥0.5 & visible 중 blend 최대). 나머지(딕셔너리 blend =
    /// 스크립트/이벤트 제어, 시작≈0)는 무시 → 트리거 전 정지. 실물 젤다: "Idle"(blend 1.0)만 상시 재생.
    private static func parseAnimationLayers(_ raw: Any?) -> AnimationSelection? {
        guard let layers = raw as? [Any] else { return nil }
        var best: (name: String, rate: Float, blend: Float)? = nil
        for case let layer as [String: Any] in layers {
            // 바인딩 객체 {"value":false,...} 언랩 — parseAllAnimationLayers 와 동일 해석(숨긴 클립 오선택 방지)
            let visible = (layer["visible"] as? Bool)
                ?? ((layer["visible"] as? [String: Any])?["value"] as? Bool) ?? true
            guard visible else { continue }
            let blend = float(layer["blend"])  // 딕셔너리 blend(스크립트/애니 커브) = 이벤트 트리거 → 제외
            guard let bl = blend, bl >= 0.5 else { continue }
            if best == nil || bl > best!.blend {
                best = ((layer["name"] as? String) ?? "", float(layer["rate"]) ?? 1, bl)
            }
        }
        return best.map { AnimationSelection(name: $0.name, rate: $0.rate) }
    }

    /// animationlayers → 전 레이어(다층 블렌드용, 순서 보존). visible/blend 는 정적 초기값
    /// (키프레임은 float()/value 언랩 후 초기값만 — 런타임 키프레임 토글은 미반영).
    private static func parseAllAnimationLayers(_ raw: Any?) -> [AnimationLayer] {
        guard let layers = raw as? [Any] else { return [] }
        return layers.compactMap { any in
            guard let l = any as? [String: Any] else { return nil }
            let visible = (l["visible"] as? Bool)
                ?? ((l["visible"] as? [String: Any])?["value"] as? Bool) ?? true
            var al = AnimationLayer(name: (l["name"] as? String) ?? "",
                                    additive: (l["additive"] as? Bool) ?? false,
                                    blend: float(l["blend"]) ?? 1,
                                    rate: float(l["rate"]) ?? 1,
                                    visible: visible)
            // blend/visible 바인딩의 스크립트·이벤트 타임라인(실물: 젤다 blend 의 animationEvent 훅 +
            // options.events 마커, 3396722575 visible 의 훅). 값 구동은 종전대로 정적 초기값만.
            for key in ["blend", "visible"] {
                guard let bind = l[key] as? [String: Any] else { continue }
                if let sc = bind["script"] as? String { al.scripts[key] = sc }
                if let a = PropertyAnimation.parse(bind), !a.events.isEmpty { al.eventTimelines.append(a) }
            }
            return al
        }
    }

    /// 레이어 소스 해석 결과.
    private enum LayerTexture {
        case entry(String)                    // 일반 텍스처 엔트리
        case solid                            // 무텍스처 머티리얼(flat) → 솔리드 필
        case frameBuffer(fullscreen: Bool)    // _rt_FullFrameBuffer → 컴포지션 레이어
    }

    /// image(model) → material → texture name → "materials/<name>.tex". nil = 해석 실패(드롭+로그).
    private static func resolveLayerTexture(
        imagePath: String,
        package: ScenePackage,
        assets: ((String) -> Data?)? = nil,
        sharedAssetProbe: ((String) -> SharedAssetProbeResult)? = nil,
        missingRequiredAsset: (() -> Void)? = nil,
        userProps: [String: Any] = [:]
    ) -> LayerTexture? {
        func requiredData(_ name: String) -> Data? {
            if let data = package.data(for: name) {
                return data
            }
            guard WallpaperPathSecurity.normalizedRelativePath(name) != nil else {
                return nil
            }
            if let sharedAssetProbe {
                switch sharedAssetProbe(name) {
                case .data(let data):
                    return data
                case .missing:
                    missingRequiredAsset?()
                case .rejected:
                    break
                }
                return nil
            }
            if let data = assets?(name) {
                return data
            }
            missingRequiredAsset?()
            return nil
        }

        guard let modelData = requiredData(imagePath),
              let model = (try? JSONSerialization.jsonObject(with: modelData)) as? [String: Any],
              let materialPath = model["material"] as? String,
              let materialData = requiredData(materialPath),
              let material = (try? JSONSerialization.jsonObject(with: materialData)) as? [String: Any],
              let passes = material["passes"] as? [Any],
              let pass0 = passes.first as? [String: Any] else {
            WapleLog.warn("[Waple] image layer texture resolve failed: \(imagePath)")
            return nil
        }
        // 텍스처 배열은 빈 슬롯을 null 로 표기할 수 있으므로(예: [null, "real.tex"]),
        // 첫 항목이 아니라 첫 non-null·non-empty 문자열을 사용한다.
        var textures = pass0["textures"] as? [Any] ?? []
        if let userTextures = pass0["usertextures"] as? [Any] {
            for (slot, rawUserKey) in userTextures.enumerated() {
                guard let userKey = rawUserKey as? String,
                      let override = userProps[userKey] as? String,
                      !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                while textures.count <= slot { textures.append(NSNull()) }
                textures[slot] = override
            }
        }
        guard let name = textures.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) else {
            // 무텍스처 머티리얼(예: util/solidlayer 의 shader "flat") → 솔리드 필.
            return .solid
        }
        if name.hasPrefix("_rt_") {
            // 프레임버퍼 참조(fullscreen/compose/project layer) → 컴포지션 레이어.
            let fullscreen = (model["fullscreen"] as? Bool) ?? (model["autosize"] as? Bool) ?? false
            return .frameBuffer(fullscreen: fullscreen)
        }
        if name.hasPrefix("/") {
            return .entry(name)
        }
        let candidates = name.hasSuffix(".tex") ? [name] : ["materials/\(name).tex", name]
        for candidate in candidates {
            if package.data(for: candidate) != nil || assets?(candidate) != nil {
                return .entry(candidate)
            }
        }
        return .entry(candidates[0])
    }

    /// scene object 의 `particle` 경로 → particles/X.json + material → SceneParticle.
    /// origin/scale 은 씬 픽셀 좌표(첫 2성분). 로드/파싱 실패 → nil + 로그.
    /// children[] 링크는 재귀 리졸브(순환/깊이 4 가드) — 자식도 자체 material 포함 완전한 def.
    private static func parseParticle(_ path: String, obj: [String: Any], package: ScenePackage,
                                      initialVisible: Bool) -> SceneParticle? {
        // instanceoverride(인스턴스 모디파이어): 프리셋 def 에 배수/CP 대체를 적용해 인스턴스별 다양화
        // (실측 127씬/866건). 종전 통째 드롭 — 재사용 프리셋 전 인스턴스가 동일 기본값으로 렌더됐다.
        let override = particleInstanceOverride(obj["instanceoverride"])
        guard let def = parseParticleDef(path, package: package, visited: [path],
                                         instanceOverride: override) else {
            WapleLog.warn("[Waple] SP4 particle load failed: \(path)")
            return nil
        }
        var p = SceneParticle(def: def,
                              origin: vec2(obj["origin"]) ?? Vec2(x: 0, y: 0),
                              scale: vec2(obj["scale"]) ?? Vec2(x: 1, y: 1))
        // 3D 마운트용 전-성분 트랜스폼/부모/가시성(2D 경로는 위 Vec2 만 사용 — 무영향).
        p.origin3D = vec3(obj["origin"]) ?? Vec3(x: 0, y: 0, z: 0)
        p.scale3D = vec3(obj["scale"]) ?? Vec3(x: 1, y: 1, z: 1)
        p.angles3D = vec3(obj["angles"]) ?? Vec3(x: 0, y: 0, z: 0)
        p.parent = intVal(obj["parent"])
        p.visible = initialVisible
        return p
    }

    /// instanceOverride 는 루트 def 에만 적용(자식 children 재귀에는 비전파 — 보수 규약).
    private static func parseParticleDef(_ path: String, package: ScenePackage,
                                         visited: Set<String>,
                                         instanceOverride: ParticleInstanceOverride? = nil) -> ParticleSystemDef? {
        guard let pData = package.data(for: path),
              let pjson = (try? JSONSerialization.jsonObject(with: pData)) as? [String: Any] else {
            return nil
        }
        var material: ParticleMaterial? = nil
        if let matPath = pjson["material"] as? String, let mData = package.data(for: matPath),
           let mjson = (try? JSONSerialization.jsonObject(with: mData)) as? [String: Any] {
            material = ParticleMaterial.parse(mjson)
        }
        return ParticleSystemDef.parse(pjson, material: material, instanceOverride: instanceOverride) { childPath in
            guard !visited.contains(childPath), visited.count < 4 else {
                WapleLog.warn("[Waple] particle child cycle/depth cap, dropped: \(childPath)")
                return nil
            }
            return parseParticleDef(childPath, package: package, visited: visited.union([childPath]))
        }
    }

    /// scene object "instanceoverride" 블록 → 타입드 오버라이드. 실측 값 형태(코퍼스 127씬/866건):
    /// 숫자 | {user,value}/{animation,value} 바인딩(float()/vec3() 언랩) | "r g b" 문자열(colorn/
    /// controlpointN). 색 배수는 colorn(0..1) × brightness(스칼라) × color(0..255 → /255) 합성.
    /// id 는 인스턴스 식별자(미적용), controlpointangleN 은 실코퍼스 전건 0 — 스킵. 유효 필드 없으면 nil.
    private static func particleInstanceOverride(_ raw: Any?) -> ParticleInstanceOverride? {
        guard let io = raw as? [String: Any], !io.isEmpty else { return nil }
        var ov = ParticleInstanceOverride()
        ov.count = float(io["count"])
        ov.rate = float(io["rate"])
        ov.size = float(io["size"])
        ov.alpha = float(io["alpha"])
        ov.speed = float(io["speed"])
        ov.lifetime = float(io["lifetime"])
        var colorMul: Vec3? = nil
        if let c = vec3(io["colorn"]) { colorMul = c }
        if let b = float(io["brightness"]) {
            let m = colorMul ?? Vec3(x: 1, y: 1, z: 1)
            colorMul = Vec3(x: m.x * b, y: m.y * b, z: m.z * b)
        }
        if let c = vec3(io["color"]) {  // 0..255 표기(실측 1건) — 정규화 후 합성
            let m = colorMul ?? Vec3(x: 1, y: 1, z: 1)
            colorMul = Vec3(x: m.x * c.x / 255, y: m.y * c.y / 255, z: m.z * c.z / 255)
        }
        ov.colorMultiplier = colorMul
        for i in 0..<8 {
            if let v = vec3(io["controlpoint\(i)"]) { ov.controlPoints[i] = v }
        }
        return ov.isEmpty ? nil : ov
    }

    /// 프로퍼티 스크립트의 저장 `scriptproperties`(사용자 오버라이드)를 JSON 문자열로 직렬화. {user,value}
    /// 바인딩은 정적 value 로 해석(스크립트는 정적 값을 기대 — resolveUserBindings 규약). 빈 값/직렬화
    /// 불가면 nil(= 소스 기본값 유지, 무회귀).
    private static func scriptPropsJSON(_ raw: Any?) -> String? {
        guard let dict = raw as? [String: Any], !dict.isEmpty else { return nil }
        var resolved: [String: Any] = [:]
        for (k, v) in dict {
            if let bind = v as? [String: Any], let inner = bind["value"] { resolved[k] = inner }
            else { resolved[k] = v }
        }
        guard JSONSerialization.isValidJSONObject(resolved),
              let data = try? JSONSerialization.data(withJSONObject: resolved),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private static func parseEffects(_ raw: Any?) -> [SceneEffect] {
        guard let arr = raw as? [Any] else { return [] }
        var out: [SceneEffect] = []
        for case let e as [String: Any] in arr {
            // WE: visible=false 효과는 미적용(사용자 토글 OFF 포함 — {user,value} 는 resolveUserBindings 가
            // 이미 정적 value 로 해석). 종전 무시 → 꺼진 post-process(예 3489263099 halftone)가 적용돼 전화면 흑화.
            if let visible = unwrap(e["visible"]) as? Bool, !visible { continue }
            let file = (e["file"] as? String) ?? ""
            // "effects/<name>/effect.json" → name
            let parts = file.split(separator: "/")
            let name = parts.count >= 2 ? String(parts[parts.count - 2]) : file
            // 전체 패스 사용자 데이터 파스(멀티패스 effect.json passes[] 와 인덱스 정렬).
            var passList: [SceneEffectPass] = []
            for case let passDict as [String: Any] in (e["passes"] as? [Any] ?? []) {
                var p = SceneEffectPass()
                if let cb = passDict["combos"] as? [String: Any] {
                    for (k, v) in cb {
                        if let i = intVal(v) { p.combos[k] = i }
                    }
                }
                if let cs = passDict["constantshadervalues"] as? [String: Any] {
                    for (k, v) in cs {
                        // 스크립트 캡처는 value 언랩보다 먼저 — 스칼라 {value,script} 는 아래 float(v) 의
                        // {value} 언랩이 dict 를 삼켜 스크립트가 통째로 유실되던 결함(실물 54씬:
                        // alpha/multiply/audioamount 류. 벡터 "r g b" 만 dict 브랜치에 도달해 생존하던 비대칭).
                        if let dict = v as? [String: Any], let sc = dict["script"] as? String {
                            p.constantScripts[k] = sc
                            // 스크립트가 있을 때만 저장 오버라이드 보존(레이어/텍스트 경로와 동일 규약).
                            if let sp = Self.scriptPropsJSON(dict["scriptproperties"]) { p.constantScriptProps[k] = sp }
                        }
                        if let f = float(v) { p.constants[k] = [f] }
                        else if let s = v as? String {
                            let f = floatList(s)
                            if !f.isEmpty { p.constants[k] = f }
                        }
                        else if let dict = v as? [String: Any] {
                            // 바인딩 객체 {script/user/value} 의 정적 value 언랩(스칼라 value 는 위 float(v)
                            // 가 언랩 — 여기는 "r g b" 벡터 value 만 도달).
                            if let f = float(dict["value"]) { p.constants[k] = [f] }
                            else if let sv = dict["value"] as? String {
                                let f = floatList(sv)
                                if !f.isEmpty { p.constants[k] = f }
                            }
                        }
                    }
                }
                // textures 배열 전체를 슬롯 순서로 캡처. JSON null → nil, 문자열 → 이름.
                if let texs = passDict["textures"] as? [Any] {
                    p.textureNames = texs.map { $0 as? String }
                }
                passList.append(p)
            }
            let p0 = passList.first ?? SceneEffectPass()
            var eff = SceneEffect(name: name, constants: p0.constants, textureNames: p0.textureNames,
                                  combos: p0.combos, file: file)
            eff.passList = passList
            out.append(eff)
        }
        return out
    }

    /// `{"user": …, ...}` 바인딩의 value 를 유저 오버라이드로 치환(재귀, 깊이 제한). 두 문법:
    ///   (a) bare-string `{"user":"키"}` (bool) → userProps[키] 로 value 교체.
    ///   (b) nested `{"user":{"condition":"<옵션값>","name":"<콤보키>"}}` (combo) → value =
    ///       (현재 콤보값 == 옵션값). TEXB0004 TexImage.VariantCondition 과 동형 그래머(동등비교).
    /// 둘 다 userProps 에 키가 있을 때만 갱신 — 없으면(미변경) 저작 스냅샷 유지(동일 계약, 무회귀).
    private static func resolveUserBindings(_ node: Any, userProps: [String: Any], depth: Int) -> Any {
        guard depth < 32 else { return node }
        if var dict = node as? [String: Any] {
            if let user = dict["user"] as? String, let override = userProps[user] {
                dict["value"] = override
            } else if let user = dict["user"] as? [String: Any],
                      let name = user["name"] as? String,
                      let condition = comboLiteral(user["condition"]),
                      let current = comboLiteral(userProps[name]) {
                dict["value"] = (current == condition)
            }
            for (k, v) in dict { dict[k] = resolveUserBindings(v, userProps: userProps, depth: depth + 1) }
            return dict
        }
        if let arr = node as? [Any] {
            return arr.map { resolveUserBindings($0, userProps: userProps, depth: depth + 1) }
        }
        return node
    }

    /// combo 바인딩 조건/현재값 → 문자열 정규화: 문자열이 정본(옵션 value 는 "0".."19"/"12h"/"动态"
    /// 등), 숫자 관용(NSNumber→문자열, bool 제외). 불리언/부재/기타는 nil → 평가 불가로 fail-closed
    /// (저작 스냅샷 유지). 이 fail-closed 가드가 non-combo·미상 키에 Bool 오기록을 막는다.
    private static func comboLiteral(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }

    /// 3D 오브젝트/그룹의 변환 프로퍼티 스크립트 추출(origin/angles/scale — 키 → JS 소스).
    /// visible 은 호출부에서 별도 처리(평문 불리언 | 바인딩 객체 두 형태). 정적 value 는 이미 언랩됨.
    private static func transformScripts(_ obj: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for key in ["origin", "angles", "scale"] {
            if let bind = obj[key] as? [String: Any], let sc = bind["script"] as? String { out[key] = sc }
        }
        return out
    }

    /// NSNull → nil 정규화(콘텐츠 키 존재 판정·접근 공통) — 실물 21오브젝트가 image/model 에 JSON null 을
    /// 쓴다. NSNull 을 "있음"으로 오판하면 그룹-노드 분기도 콘텐츠 분기도 못 타 계층에서 통째로 유실된다.
    private static func contentValue(_ v: Any?) -> Any? { v is NSNull ? nil : v }

    /// 바인딩 객체 {"animation":..., "value": X} → X(정적 값), 아니면 원값.
    /// 실물 씬은 origin/alpha 등 대부분의 프로퍼티에 이 형태를 쓴다(애니메이션 재생은 후속 기능).
    /// (공용 JSONNumerics 위임 — 씬 규약: {value} 언랩 경유 + 문자열 숫자 관용)
    private static func unwrap(_ v: Any?) -> Any? { unwrapValue(v) }
    private static func floats(_ v: Any?) -> [Float] {
        floatList((unwrap(v) as? String) ?? "")
    }
    private static func float(_ v: Any?) -> Float? {
        lenientFloat(unwrap(v))   // 문자열 숫자 관용(문자열 id 씬과 동급 방어)
    }
    private static func intVal(_ v: Any?) -> Int? {
        lenientInt(unwrap(v))   // 실물 3577990983: id/parent 가 "35" 문자열 타입
    }
    private static func vec2(_ v: Any?) -> Vec2? {
        let f = floats(v); return f.count >= 2 ? Vec2(x: f[0], y: f[1]) : nil
    }
    private static func vec3(_ v: Any?) -> Vec3? {
        let f = floats(v); return f.count >= 3 ? Vec3(x: f[0], y: f[1], z: f[2]) : nil
    }
}
