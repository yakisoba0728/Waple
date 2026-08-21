import Foundation

/// scene.json 효과 항목의 패스별 사용자 데이터(effect.json passes[] 와 인덱스 정렬).
public struct SceneEffectPass: Equatable {
    public var constants: [String: [Float]] = [:]
    /// 상수에 걸린 프로퍼티 스크립트(키 → JS 소스) — 렌더러가 per-frame 평가(컬러 사이클 등).
    public var constantScripts: [String: String] = [:]
    /// 상수 스크립트의 저장 `scriptproperties`(사용자 오버라이드) — 키 → JSON 문자열. 레이어/텍스트
    /// 스크립트와 동일 규약: 엔진 로드 시 주입해 소스 `createScriptProperties().addX({value})` 기본값 대체.
    public var constantScriptProps: [String: String] = [:]
    /// X-⑦: 상수에 걸린 키프레임 애니메이션({animation:{...}} 바인딩, 55씬/287건) — 렌더러가
    /// per-frame PropertyAnimation.value(component:atTime:base:) 로 평가(레이어 origin/scale/alpha
    /// 애니와 동일 평가기 재사용). 정적 constants[key] 는 애니 없을 때의 기본값 겸 relative 애니의 base.
    public var constantAnimations: [String: PropertyAnimation] = [:]
    public var textureNames: [String?] = []
    /// F697: 패스 `usertextures` 슬롯 — 머티리얼 경로(material/instance)와 동일하게 name 만 정규화
    /// (평문 문자열=유저 프로퍼티 키, {name,type}={"$mediaThumbnail","system"} 류 시스템 키 → name).
    /// 렌더러가 이펙트 텍스처 슬롯 오버라이드/시스템 텍스처 바인드에 사용(소비는 렌더 그룹 경계).
    public var userTextureNames: [String?] = []
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
    /// X-⑪: 이펙트 **인스턴스** 레벨 `combos`(씬의 `objects[].effects[i].combos`).
    /// 위 `combos`(= `passes[0].combos`)와 **다른 것**이다. `conditions` 평가의 좌변이 이쪽이며,
    /// 동봉 씬에는 0건이라 실측상 항상 비어 있다(그래서 조건이 전부 false 로 떨어진다 — 원본 동작).
    public var instanceCombos: [String: Int] = [:]
    /// 전체 패스 사용자 데이터(멀티패스 효과용; [0]은 기존 constants/textureNames/combos 와 동일).
    public var passList: [SceneEffectPass] = []
    /// 초기 가시성(스크립트 있으면 정적 false 도 보존 — 오브젝트 레벨 initialVisible 게이트와 동일 규약).
    public var initialVisible: Bool = true
    /// visible 프로퍼티 스크립트(단일 JS 소스, 상수처럼 키 맵이 아님). X-⑥: SceneRendererResources.
    /// buildEffectChain 이 per-frame 재평가로 소비(레이어/텍스트 propertyScripts["visible"] 과 동형 규약)
    /// — 이 필드가 있으면 initialVisible 이 false 라도 SceneEffect 를 드롭하지 않고 보존만 한다.
    public var visibleScript: String? = nil
    /// X-⑥: visibleScript 의 scriptproperties(레이어/텍스트 visibleScriptProps 와 동일 규약) — 스크립트가
    /// scriptProperties.<name> 참조 시 필요. 미보유 스크립트는 nil 이어도 무해(기본값 폴백).
    public var visibleScriptProps: String? = nil

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
    // **가시성 상속 전용 부모 id(`visibilityParent`)는 2026-08-17 에 `parent` 로 흡수돼 사라졌다.**
    // 그 필드는 이펙트 캐리어 quad 의 풀스크린 승격이 만든 모순 — "지오메트리는 parent 를 버려야
    // 하는데(부모 좌표로 재배치되면 풀스크린이 깨진다) 가시성은 parent 를 알아야 한다" — 을 두 축으로
    // 쪼개서 우회한 것이었고, 그 필드 주석 자체가 "승격을 걷어내면 parent 로 흡수돼야 한다" 고 적어
    // 두었다. WE shape 기본 크기가 확정돼(spec/engine/shape-quad.json) 승격을 걷어냈으므로 모순의
    // 전제가 없어졌다 — 이제 쿼드도 다른 레이어와 똑같이 `parent` 하나로 지오메트리·가시성을 모두 탄다.
    /// 오브젝트 `attachment` — 부모 퍼펫 모델의 **이름 부착점**(.mdl MDAT 슬롯, 본 인덱스 바인딩)에 부착.
    /// 자식의 origin/angles 는 부착점 프레임 상대(실측 3538758087 주발/눈: 부모중심 상대면 허리 위치 —
    /// 부착점 상대만 머리에 정합). 렌더러가 per-frame `boneWorld(t)×attLocal` 씬 델타를 합성. nil=일반 계층.
    public var attachment: String? = nil
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
    /// 머티리얼 패스 `alphawriting`("default"|"enabled" — json-keys.txt:622 A 0x0048a4c0; 코퍼스 실측
    /// 806엔트리 중 enabled 16건). 파스·보존 전용 — 알파 채널 기록 제어 의미로 추정, 렌더 소비 보류.
    /// 기본 "default"(항등 — :1107 depthtest/depthwrite 와 같은 패스 키 군).
    public var alphaWriting: String = "default"
    /// 오브젝트 colorBlendMode(common_blending.h ApplyBlending enum 0-32; 0=normal).
    /// != 0 이면 렌더러가 acc 스냅샷 대비 블렌드 합성(컴포지션 스냅샷 패턴). 코퍼스 121레이어/30씬.
    public var colorBlendMode: Int = 0
    /// visible 의 정적 value(초기 표시). visible 스크립트가 있을 때만 false 로도 남는다 —
    /// 스크립트 없는 정적 false 는 파스에서 레이어 자체가 드롭된다.
    public var initialVisible: Bool = true
    /// **영구 비가시 조상 상속**(applyVisibilityInheritance) — true 면 렌더러가 이 마운트 동안
    /// 무조건 드로우를 건너뛴다. `initialVisible=false` 와 갈라 두는 이유는 소비 규약이 다르기
    /// 때문이다: initialVisible 은 visible 스크립트의 **초기값(seed)** 일 뿐이라
    /// `scriptVisible[uid] = evaluateBool(current:) ?? cur`(SceneRendererFrameEncoder)가 스크립트
    /// 반환값으로 **덮어쓴다** — 자기 visible 스크립트를 가진 자식은 조상이 꺼져 있어도 다시 켜졌다.
    /// 반면 조상 집합은 "정적 false + visible 스크립트 없음" 만 담으므로(같은 함수) 그 조상은 이
    /// 마운트 동안 절대 켜지지 않는다 — 그래서 시드가 아니라 **하드 게이트**가 맞는 수단이다.
    /// 스크립트는 계속 평가한다(shared 사이드이펙트 보존) — 게이트는 평가 **뒤** 드로우 스킵 지점이다.
    /// 유저가 부모 콤보를 켜면 remount=전체 재파스라 이 플래그도 다음 파스에서 풀린다.
    public var hiddenByAncestor: Bool = false
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
    /// material.constantshadervalue.scripted — PBR scalar per-frame evaluation (roughness/metallic/speculartint).
    public var materialScripts: [String: String] = [:]
    public var materialScriptProps: [String: String] = [:]
    /// H1: 커스텀 머티리얼 셰이더(material passes[0].shader). nil = 고정 QuadShaders 경로.
    public var materialShader: String? = nil
    /// H1: 커스텀 머티리얼 콤보(material passes[0].combos).
    public var materialCombos: [String: Int] = [:]
    /// H1: 커스텀 머티리얼 상수(material passes[0].constantshadervalues).
    public var materialConstants: [String: [Float]] = [:]
    /// H1: 커스텀 머티리얼 상수 스크립트.
    public var materialConstantScripts: [String: String] = [:]
    public var materialConstantScriptProps: [String: String] = [:]
    /// H1: 커스텀 머티리얼 텍스처 슬롯(material passes[0].textures).
    public var materialTextureNames: [String?] = []
    /// H2: usershadervalues — 머티리얼 상수 이름 → user property 키 매핑.
    public var materialUserShaderValues: [String: String] = [:]
    /// H4: REFRACT 콤보 + 노멀맵 + refractAmount. 노멀맵 없으면 refract=false.
    public var refract: Bool = false
    public var normalTextureName: String? = nil
    public var refractAmount: Float = 0.05
    /// F692: 오브젝트 `perspective:true` — WE 는 이 레이어를 general.perspectiveoverridefov 의
    /// 원근 침침으로 그린다(정사영 평면화 대신). 파스·보존 전용: 원근 투영 소비는 렌더 경로 책임.
    /// 실측(전수): perspective:true 19씬 전부 x/y angles 0(z-회전만)이라 원근/정사영 출력이
    /// 코퍼스 내에서는 동일 — 렌더 갭 실피해 0 확인 후 파스 보존으로 결정.
    public var perspective: Bool = false
    /// F696: 오브젝트 `dependencies`(명시 렌더 순서/RTT 선행 의존 id 목록 — 타깃은 image/text
    /// 오브젝트). 파스·보존 전용: depLater(타깃이 후순위 — 실물 3113287126 idx2→idx4 등)의
    /// 순서 보장은 렌더러 그리기 순서 책임(보고 경계).
    public var dependencies: [Int] = []
    /// 오브젝트-레벨 전파/렌더 플래그 파스·보존(소비는 렌더러 책임).
    public var disablePropagation: Bool = false
    /// B2-effects④: WE 컴포지션(_rt_) 레이어 "배경 복사". 기본 true — WE 레퍼런스 shim 자체 기본값이
    /// `copybackground | true`(references/.../lanes/L1-project-scene-model.md:230, shim:87, "배경 복사(뒤
    /// 렌더 결과 샘플)")이고, 코퍼스 실측(명시값 255×true vs 56×false)도 이를 뒷받침한다(미명시는 true
    /// 가 통상 케이스). false 는 렌더러가 acc(기존 누적 화면) 블릿을 건너뛰고 투명에서 이펙트 체인을
    /// 시작(runFrameBufferLayer 소비 — 실물 3629379075 "可调整组合层" blur 풀프레임 워시 수정의 근거).
    /// 단 Waple 은 compose 레이어별 자식 RT 가 없어 "자식 RT 대신 무(無)" 로 근사한 것 — 필터형 체인엔
    /// 타당하나 생성형(입력과 무관하게 색을 새로 쓰는) 체인의 콘텐츠 손실까지 보장하는 것은 아니다.
    public var copyBackground: Bool = true
    /// **[2026-08-20] 기본값 정정 false → true.** 렌더러블 생성자가 플래그 dword 를
    /// `[obj+0x304] = 0x8040`(0x1401e69e8) 으로 초기화한다 — bit6 `copybackground` **와**
    /// bit15 `clampuvs` 가 **둘 다** 서는 값이다. 바로 위 `copyBackground = true` 는 그 상수의
    /// bit6 을 이미 반영한 것인데 같은 상수의 bit15 만 안 따라와 있었다.
    /// 비트 극성 확인: 세터 0x14019bf40 이 `btr eax,0xf` / `bts r9d,0xf` 후 입력이 0 이면
    /// `cmove` 로 지운 쪽을 고르고, 게터 0x14019bf80 은 `shr edx,0xf; and dl,1` 이다.
    ///
    /// **오늘의 화면은 바뀌지 않는다** — 이 필드를 읽는 곳이 없다. 샘플러 주소지정을 정하는 것은
    /// `TexImage.clampUVs`(`.tex` 헤더 flags bit1)뿐이고(SceneRendererResources:1182·1191),
    /// 씬 JSON 에서 파스한 이 값은 저장만 되고 소비처가 없다. 그래서 이건 동작 수정이 아니라
    /// **모델 수정**이다 — 나중에 소비를 붙이는 사람이 틀린 기본값을 물려받지 않게 한다.
    ///
    /// 도달: 동봉+설치본 scene.json 355개 중 `clampuvs` 명시 6건이고 **전건 `true`** 다.
    /// 즉 명시 자산조차 기본값과 같아서, 이 기본값이 사실상 전 자산의 실효값이다.
    ///
    /// 미해결: 씬 JSON 의 `clampuvs` 와 `.tex` 헤더의 flags bit1 이 어긋날 때 어느 쪽이
    /// 이기는지는 확인 못 했다 — 소비를 붙일 때 먼저 정해야 한다.
    public var clampUVs: Bool = true
    public var noInterpolation: Bool = false
    public var spacing: Float? = nil
    public var lockTransforms: Bool = false
    public var isSolid: Bool = false
    public var ledSource: Bool = false
    /// `config:{passthrough:true}` 등 compose 레이어 설정(이미지 오브젝트용).
    public var configPassthrough: Bool = false
    public var configAutosize: Bool = false
    public var configIsSolidLayer: Bool = false
    public var configIsProjectLayer: Bool = false
    public var configIsInstanced: Bool = false
    /// F751(S-20): 모델 json 루트 `cropoffset` — 에디터 크롭 베이크(베이크된 텍스처=크롭 영역,
    /// autosize 동반) 시 **크롭 영역 중심 − 원본 이미지 중심**(px, 레이어 로컬). 실측 확정 근거:
    /// 전수 1386 컴포넌트(693파일/49wp — 퍼펫 모델 49파일 포함)가 전부 0.5 배수(정수 픽셀 rect 의
    /// 중심 차이만이 생성 가능한 정량화), "-0.00000"(중심 좌표계 산출의 −0.0) 출현, 임의 소수 0건.
    /// nil = 크롭 아님. 파스·보존 전용.
    /// F801(S-20 후속): 런타임 적용 **기각 확정** — 실물 2827816001 의 크롭 6조각 재조립 분석:
    /// origin == 원본배치중심(1920,1080)+cropoffset 이 4/6 비트정합, 2/6(id 39/35, 비정수 origin)은
    /// ±0.1~1.4px 델타 = 크롭 후 사용자 미세이동. 무적용 시 조각 사각형이 원본 크롭 영역에 정확히
    /// 붙고(id18: [547,2616]), ±어느 부호로든 origin+cropOffset 을 추가 적용하면 |cropOffset| 만큼
    /// 이중 이동해 재조립이 파열(id18: [208.5,2277.5] 또는 [885.5,2954.5]). 즉 WE 에디터가 크롭
    /// 베이크 시 origin 에 이미 합성해 기록 — 쿼드 배치는 cropOffset 을 소비하지 않는다(무회귀).
    public var cropOffset: Vec2? = nil
}

/// 씬 내 파티클 시스템 인스턴스. def(파티클 정의) + 씬 배치(origin/scale, 씬 픽셀 좌표).
public struct SceneParticle: Equatable {
    public let def: ParticleSystemDef
    /// 2D 정사영 경로의 로컬(부모 상대) → 월드(프로젝션 픽셀) 좌표. E1: parent 체인 합성이 파스 말미에
    /// 이 값을 덮어쓴다(레이어와 동일 규약) — 그래서 var.
    public var origin: Vec2
    public var scale: Vec2
    /// scene.json objects[] 내 인덱스(레이어와 공유하는 z-순서).
    public var order: Int = 0
    /// scene.json objects[].id — **다른 오브젝트가 이 파티클을 parent 로 참조할 때의 룩업 키**
    /// (SceneLayer.id:58 / SceneTextLayer.id:236 과 동일 규약). 0 = 미지정.
    /// 종전엔 이 필드 자체가 없어서 파티클이 부모 체인의 "중간 마디"가 될 수 없었다 —
    /// applyVisibilityInheritance 의 parentOf 가 파티클을 담지 못해, 부모가 파티클인 자식은
    /// 조상 탐색이 그 자리에서 끝났다(실물 3299228616: 30오브젝트가 파티클을 거치는 체인).
    public var id: Int = 0
    /// 3D 씬 배치(camera3D 마운트 경로 전용 — 2D 정사영 경로는 origin/scale Vec2 그대로 사용).
    /// 파티클 오브젝트의 3D 트랜스폼(전 성분)·부모 노드 id·정적 가시성. 2D 씬에선 기본값(미사용).
    public var origin3D: Vec3 = Vec3(x: 0, y: 0, z: 0)
    public var scale3D: Vec3 = Vec3(x: 1, y: 1, z: 1)
    public var angles3D: Vec3 = Vec3(x: 0, y: 0, z: 0)
    public var parent: Int? = nil
    public var visible: Bool = true
    /// 영구 비가시 조상 상속 하드 게이트 — SceneLayer.hiddenByAncestor 와 동일 규약(그 주석 참조).
    public var hiddenByAncestor: Bool = false
    /// 마우스 시차(parallax) 가중치 — SceneLayer.parallaxDepth(69행)와 동형(F200). 기본 1(균일 시차,
    /// 파서가 값을 못 읽어도 기존 동작과 동일 — 무회귀). 코퍼스 실측: particle 오브젝트 53개 중 42개(79%) 보유.
    public var parallaxDepth: Vec2 = Vec2(x: 1, y: 1)
    /// visible 프로퍼티 스크립트(JS 소스) — 레이어/노드(SceneLayer.propertyScripts["visible"],
    /// SceneNode3D.propertyScripts["visible"])와 동형 규약(F199). per-frame 재평가로 visible 을
    /// 갱신하는 소비는 렌더러 책임 — 여기선 파스 보존만. nil = 정적 visible(스크립트 없음, 무회귀).
    public var visibleScript: String? = nil
    /// visible 스크립트의 저장 scriptproperties(사용자 오버라이드) — JSON 문자열.
    public var visibleScriptProps: String? = nil
    /// 오브젝트-레벨 전파/렌더 플래그 파스·보존.
    public var disablePropagation: Bool = false
    public var copyBackground: Bool = true
    /// 기본 true — 위 SceneLayer.clampUVs 주석 참조(렌더러블 ctor 0x8040 의 bit15).
    public var clampUVs: Bool = true
    public var noInterpolation: Bool = false
    public var lockTransforms: Bool = false
    public var isSolid: Bool = false
    /// M(⑤): 오브젝트 `attachment`(부모 퍼펫 모델 이름 부착점) — SceneLayer.attachment(62행)와 동일
    /// 원시 문자열 규약. **파스만**: 3D 렌더 소비는 없음(SceneRenderer3D attachment grep 0건, wf8 id 66) —
    /// 2D PuppetAttach 배선(SceneRendererResources.swift:329-341)과는 별개 경로. nil=일반 계층.
    public var attachment: String? = nil
}

/// 텍스트 오브젝트(시계/날짜/곡정보 등). text 는 평문 또는 JS 프로퍼티 스크립트(script)로 계산.
public struct SceneTextLayer: Equatable {
    public var name: String = ""
    /// W3-⑤: scene.json objects[].id — 다른 오브젝트가 이 텍스트를 parent 로 참조할 때 룩업 키
    /// (레이어/노드와 동일 규약). 0 = 미지정(그런 텍스트는 부모 후보에서 제외 — buildParentTransformMap 참조).
    public var id: Int = 0
    /// E1: 부모 오브젝트 id(2D parent 체인 합성 룩업용 — 레이어와 동일 규약). nil=루트.
    /// origin/scale 은 파스 말미에 부모 체인이 합성된 월드(프로젝션 픽셀) 값으로 덮어쓴다(정적 부모 한정).
    public var parent: Int? = nil
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
    /// E1: parent 체인 합성이 파스 말미에 월드(프로젝션 픽셀) 값으로 덮어쓴다(레이어와 동일 규약) — 그래서 var.
    /// (3D 씬은 composeTextParentTransforms 가 미실행 — camera3D!=nil 게이트 — 이라 origin.xy 는 로컬 그대로.)
    public var origin: Vec2
    /// W-①: origin 의 3성분째(월드 z) — SceneLayer.originZ 와 동일 규약. 2D 씬에선 무시, 3D 씬 텍스트
    /// 빌보드가 월드 위치로 사용(build3D). 코퍼스 3D 텍스트 실측: image 레이어와 동일 소수 단위(카메라
    /// eye/center 스케일과 정합, 픽셀 스케일 아님) — "screen overlay" 가 아니라 world placement 가 정본.
    public var originZ: Float = 0
    public var scale: Vec2               // 배율은 "scale" 필드(실측 "2 2") — "size" 는 parseLayer 전용 레이아웃 박스(오독 시 거대 글리프)
    /// W3-⑤: 정적 angleZ(scene.json "angles" 의 z 성분, 라디안 — 레이어 SceneLayer.angleZ 와 동일 규약).
    /// 스크립트 바인딩(propertyScripts["angles"])이 있으면 그 결과가 매 프레임 이 값을 대체(encodeText).
    /// F057: 2D 씬 parent 체인이 있으면 파스 말미에 부모 누적 각이 더해진 월드 각으로 덮어쓴다
    /// (composeTextParentTransforms — origin/scale 과 동일 규약, 그래서 var).
    public var angleZ: Float = 0
    /// "Limit width"(limitwidth) 체크 시 워드랩 폭 maxwidth(래스터 로컬 px — 실물 maxwidth 스크립트가
    /// 화면폭을 scale.x 로 나눠 전달 = 스케일 전 단위, d.ts "Max width in pixels"). nil = 무제한(무회귀).
    public var maxWidth: Float? = nil
    /// "Limit rows"(limitrows) 체크 시 최대 행수 maxrows(실측 기본 1 — 1628/1640). nil = 무제한.
    public var maxRows: Int? = nil
    /// "Overflow ellipsis"(limituseellipsis) — 행 제한 잘림 시 마지막 행에 U+2026.
    public var overflowEllipsis: Bool = false
    /// "Justify text"(blockalign — 에디터 프로퍼티 테이블 실측 라벨) — 워드랩 줄 양쪽 정렬.
    public var justify: Bool = false
    public var order: Int = 0
    /// 초기 가시성(스크립트 있으면 정적 false 도 보존 — 레이어 initialVisible 과 동일 규약). 578행 게이트가
    /// visibleScript!=nil 인 오브젝트를 통과시켜도 이 필드가 없으면 스크립트 평가와 무관하게 항상
    /// 렌더링되던 결함(F219).
    public var initialVisible: Bool = true
    /// 영구 비가시 조상 상속 하드 게이트 — SceneLayer.hiddenByAncestor 와 동일 규약(그 주석 참조).
    public var hiddenByAncestor: Bool = false
    /// 프로퍼티 스크립트(origin/scale/alpha/color/angles/visible — 키 → JS 소스). SceneLayer.propertyScripts
    /// 와 동일 규약(parseLayer:731-739 형): per-frame 재평가는 재래스터가 아니라 인코드 시점 트랜스폼/
    /// 알파/가시성 적용(텍스트 '콘텐츠' 스크립트 위 script/scriptProps 와는 별개 채널).
    public var propertyScripts: [String: String] = [:]
    /// 프로퍼티 스크립트의 저장 scriptproperties(사용자 오버라이드) — 키 → JSON 문자열. 레이어와 동일 규약.
    public var propertyScriptProps: [String: String] = [:]
    /// F693: 텍스트 오브젝트의 `effects[]`(tint/blurprecise/opacity/transform/shift_hue/skew 등 —
    /// 실측 113건/16wp 이상). WE 는 텍스트를 텍스처로 래스터한 뒤 이펙트 체인을 적용한다.
    /// 파스·보존 전용 — 텍스처화된 텍스트에 이펙트를 적용하는 렌더 소비(encodeText 경로)는
    /// 별도 그룹 경계(미적용 시 이펙트가 조용히 소실되는 종전과 동일 동작, 값만 보존).
    public var effects: [SceneEffect] = []
    /// 오브젝트-레벨 전파/렌더 플래그 파스·보존.
    public var disablePropagation: Bool = false
    public var copyBackground: Bool = true
    /// 기본 true — 위 SceneLayer.clampUVs 주석 참조(렌더러블 ctor 0x8040 의 bit15).
    public var clampUVs: Bool = true
    public var noInterpolation: Bool = false
    public var spacing: Float? = nil
    public var lockTransforms: Bool = false
    public var isSolid: Bool = false
    /// 텍스트 오브젝트 `depthtest`(scene-json-schema.md:123 텍스트 키 목록 — SceneLayer.depthTest 의
    /// 머티리얼 패스 키(SceneDocument.swift:1107)와는 별개 오브젝트 레벨). 실측 코퍼스는 문자열
    /// "enabled"(1394건, 불리언 형태도 관용 파스). 기본 true(항등). 파스·보존 전용 — 2D 텍스트 경로는
    /// 페인터 z-순서라 depth 소비 없음(3D 빌보드는 SceneLayer.depthTest 가 담당).
    public var depthTest: Bool = true
    /// C⑥: 오브젝트 colorBlendMode(common_blending.h ApplyBlending enum 0-32; 0=normal) — 이미지
    /// 레이어(SceneLayer.colorBlendMode)와 동일 필드이나 종전 텍스트 경로엔 아예 없었다. 텍스트도
    /// 동일 enum 을 저작하며(실측 코퍼스 9씬/24오브젝트, mode 31 최빈 — 시계/곡명 텍스트 가산 합성).
    public var colorBlendMode: Int = 0
    /// C⑨: 아웃라인/배경 박스 — 파스·보존(실측 코퍼스: outline 1씬/3오브젝트, opaquebackground 5씬/12
    /// 오브젝트 — 후자는 전건 visible=false(README/구분선 에디터 메모)라 실가시 사례 없음). 래스터
    /// 소비는 outline 만 최소 구현(TextRasterizer 참조) — opaquebackground 는 파스만(실가시 0건이라
    /// 렌더 리스크 대비 이득이 낮음, 필요 시 이 필드로 후속 구현 가능).
    public var outline: Bool = false
    public var outlineColor: Vec3 = Vec3(x: 0, y: 0, z: 0)
    public var outlineThickness: Float = 0
    public var opaqueBackground: Bool = false
    public var backgroundColor: Vec3 = Vec3(x: 0, y: 0, z: 0)
    /// F4-polish①: 배경 박스 앵커(에디터 "Anchor" — 실측 코퍼스 anchor:1478/1642, 값 7종
    /// none:1409(대다수 미지정) center:51 left:8 right:6 top:3 topright:1 bottomright:1). "none"이면
    /// 박스가 텍스트 origin 을 그대로 따름(WE 기본). **파스·보존만** — opaqueBackground 와 동형으로
    /// 렌더 소비(배경박스 앵커 오프셋 적용)는 최소구현 정책 밖(실가시 임팩트 낮음, 필요 시 이 필드로 후속).
    public var anchor: String = "none"
    /// F4-polish①: 배경 박스 패딩(에디터 "Padding" — 실측 padding:1642 전건, **혼합 타입**: 단일
    /// 스칼라(정수/실수, 1459건, 예 `32`)와 "x y" 벡터 문자열(168건, 예 `"32.00000 32.00000"`) 둘 다
    /// 저작됨 — 스칼라는 양축 동일값으로 확장. 기본 (0,0) = 무패딩(무회귀). 파스·보존만(anchor 와 동일 정책).
    public var padding: Vec2 = Vec2(x: 0, y: 0)
    /// F4-polish①: 배경 박스 밝기(에디터 "Background Brightness" — 실측 backgroundbrightness:1474/1642,
    /// 관측값 전건 1.0·170건 부재). 기본 1 = 원색 그대로(부재 시 0 이면 검정 박스로 오염되는 잠재
    /// 함정이라 1 로 폴백). 파스·보존만(anchor/padding 과 동일 정책).
    public var backgroundBrightness: Float = 1
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

/// 씬 objects[] 의 camera 의사-오브젝트(에디터 카메라 프리셋: fov/zoom/origin/경로 — 실측 37씬/58
/// 오브젝트, 실효 zoom 애니 9씬·비기본 fov 16). scene.camera(3D 룩앳, parseCamera)와 별개 채널.
/// 종전 parseNode 가 콘텐츠 키 부재로 트랜스폼-노드로 흡수해 fov/zoom 을 통째 드롭했다.
/// path 필드는 스크립트 파일 참조(전 57오브젝트 "scripts/camera_paths_*.json" — 인라인 웨이포인트 부재)라
/// 미소비(YAGNI). 팬은 origin.xy 애니(실측 5씬, zoom single 인트로와 연동)만 실효 — 정적/스크립트 base 는
/// 전수 중립(화면중심)이라 렌더러 데드존/게이트로 흡수(P0-2 파스 → P1 zoom → 이번 origin 팬 잔여).
public struct SceneCameraObject: Equatable {
    public var id: Int = 0
    public var name: String = ""
    public var fov: Float = 50          // 실측 기본 50.0
    public var zoom: Float = 1          // 정적 값({user,value}/{animation,value} 는 value)
    /// zoom 바인딩의 키프레임 타임라인({"animation":…} — 실측 9씬). 렌더러 per-frame 평가용 보존.
    public var zoomAnimation: PropertyAnimation? = nil
    /// origin.xy 바인딩의 키프레임 타임라인({"animation":…} — 실측 5씬, zoom 인트로와 연동된 팬).
    /// zoom 과 동형(PropertyAnimation.parse 재사용). single 끝 클램프로 A/B 캡처 t=6 은 중립 정착.
    public var originAnimation: PropertyAnimation? = nil
    /// origin/zoom 프로퍼티 스크립트(키 → JS 소스 — 실물: 슬라이더 연동 카메라 위치).
    public var scripts: [String: String] = [:]
    public var origin: Vec3 = Vec3(x: 0, y: 0, z: 0)
    /// 오일러 각(라디안 — scene.json 저장 규약, SceneObject3D.angles 와 동일). 종전 파스 누락으로
    /// 카메라 오브젝트의 **방향이 통째로 소실**돼 있었다. 소비는 조사 결과에 달려 있어 보류 —
    /// 파스·보존만 한다(카메라 오브젝트를 3D 카메라로 승격하는 규칙이 미확정. 조사 결론은 아래 parent 주석).
    public var angles: Vec3 = Vec3(x: 0, y: 0, z: 0)
    /// 부모 오브젝트 id. 코퍼스 실측: 다중 카메라 씬(3706286085 8개 / 3737268876 11개)의 카메라는
    /// **전부** parent 를 가지며 그 부모가 스크립트로 구동되는 노드다(소닉 추종 CameraBoneMoveMesh,
    /// 젤다 Cam Link Root/Cam Look At Events). 즉 카메라 포즈가 오브젝트 자체가 아니라 부모 체인에
    /// 있다 — 그래서 "카메라 오브젝트를 그대로 쓰기" 는 이들 씬에서 성립하지 않는다.
    /// 반대로 단일 카메라 7씬(3D 원근)의 카메라는 parent 가 없다. 이 필드는 그 구분에 쓴다.
    public var parent: Int? = nil
    /// `visible` 키를 가지고 있었는가(값 무관). 다중 카메라 씬의 카메라는 이 키가 유저 프로퍼티
    /// (bool/combo) 바인딩이라 활성 여부가 사용자 설정에 달려 있다 — 3737268876 은 `cameratype`
    /// 기본값 "0"(Manual)이라 **11개 중 어느 것도 기본 활성이 아니다**. 무조건 활성인 카메라만
    /// 골라내는 게이트로 쓴다.
    public var hasVisibleBinding: Bool = false
    /// 칩 경로 스크립트 파일 참조 + 큐 모드(기본 random, sequential 1건).
    public var path: String? = nil
    public var queueMode: String = "random"
    /// 오브젝트-레벨 플래그 파스·보존.
    public var disablePropagation: Bool = false
    public var lockTransforms: Bool = false
    public var isSolid: Bool = false
    public init() {}
}

/// 3D 모델의 활성 애니메이션 선택(animationlayers 의 숫자 blend≥0.5 & visible 인 베이스 레이어).
/// name = 레이어 이름("Idle" 등, 렌더러가 모델 애니 이름에 서브스트링 매칭), rate = 재생 배속.
public struct AnimationSelection: Equatable {
    public let name: String
    public let rate: Float
    /// C③: 선택된 레이어의 정수 클립 id(scene.json animationlayers[].animation) — 있으면 이름 휴리스틱
    /// 대신 모델 클립 id 대조로 정확한 클립을 고른다(Model3DPose.resolveAnimation 참조).
    public let clipId: Int?
    public init(name: String, rate: Float, clipId: Int? = nil) {
        self.name = name; self.rate = rate; self.clipId = clipId
    }
}

/// animationlayers 의 개별 레이어(다층 캐스케이드 블렌드용 — 실측 확정 2026-07):
/// - name: 모델 애니 클립에 서브스트링 매칭할 레이어 이름(레이어 name ≈ 클립 name).
/// - additive: false = 절대 포즈(캐스케이드 lerp), true = 델타 가산(bind/이전 포즈 위에 클립 델타).
/// - blend: 블렌드 가중치(대개 1.0, 분수/키프레임 존재 — 키프레임은 초기값). 0..1 클램프 안 함.
/// - rate: 재생 배속(대개 1.0).
/// - visible: 레이어 활성(키프레임 가능 — 파스는 정적 초기값).
/// blend/rate/visible 은 var — 렌더러가 per-frame 스크립트 평가값을 로컬 사본에 덮어쓴다
/// (encodeLayer effLayers; 파스 산출 원본은 불변 유지).
public struct AnimationLayer: Equatable {
    public let name: String
    public let additive: Bool
    public var blend: Float
    public var rate: Float
    public var visible: Bool
    /// C③: 재생 클립의 정수 id(scene.json animationlayers[].animation) — 모델 파일(MDLA0006 트레일러/
    /// baseId, Model3D.Animation.id 경유)의 클립 id와 대조해 정확한 클립을 고른다. 저작 도구가 생성한
    /// 이 레이어의 "표시 이름"(name)은 실제 클립 이름과 무관할 수 있어(실측: 클립명 "动画 1/2/3" 제네릭,
    /// 레이어명 "呼吸/眨眼/转头" 의미부여) 이름 부분일치 휴리스틱이 오선택하는 경우의 정본. nil = 미저작
    /// (이름 휴리스틱 폴백).
    public let clipId: Int?
    /// blend/rate/visible 바인딩의 프로퍼티 스크립트(키 → JS 소스) — 실물 animationEvent 훅의 주 서식지
    /// (3737268876 젤다 blend 핸들러 19개, 3351179520/3396722575 visible 핸들러, 2955378002/3448290956
    /// rate 오디오 배속). 렌더러가 엔진 생성 + per-frame 재평가(2D 퍼펫 캐스케이드 소비자).
    public var scripts: [String: String] = [:]
    /// blend/visible 바인딩의 이벤트 마커 타임라인(options.events 보유분만 — 젤다 "surprise" 등).
    /// 값 구동(blend 키프레임 적용)은 미구현 — 마커 발화 클록으로만 사용(정적 blend 무회귀).
    public var eventTimelines: [PropertyAnimation] = []
    public init(name: String, additive: Bool, blend: Float, rate: Float, visible: Bool, clipId: Int? = nil) {
        self.name = name; self.additive = additive; self.blend = blend
        self.rate = rate; self.visible = visible; self.clipId = clipId
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
    /// F696: 오브젝트 `dependencies`(명시 렌더 선행 의존 id — 실측 model 오브젝트 23건). SceneLayer
    /// 와 동일하게 파스·보존 전용(순서 보장 소비는 렌더러 책임).
    public var dependencies: [Int] = []
    /// M(⑤): 오브젝트 `attachment`(부모 퍼펫 모델 이름 부착점) — SceneLayer.attachment(62행)와 동일
    /// 원시 문자열 규약. **파스만**: 3D 렌더 소비는 없음(SceneRenderer3D attachment grep 0건, wf8 id 66 —
    /// 3D 씬 attachment 보유 model 오브젝트 19건이 부모 루트 변환으로만 배치되는 별개 갭). nil=일반 계층.
    public var attachment: String? = nil
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
    /// M(⑤): 오브젝트 `attachment`(부모 퍼펫 모델 이름 부착점) — SceneLayer.attachment(62행)와 동일
    /// 원시 문자열 규약. **파스만**: 실물 5씬(3629379075·3478434536·3486806915·3737268876·3492627662)의
    /// 콘텐츠 없는 그룹(가면/머리 액세서리 부착)이 이 경로를 거치나, 이 5씬은 camera3D 부재(2D 퍼펫 씬)라
    /// SceneRenderer3D(3D 렌더)를 타지 않는다 — 소비는 2D PuppetAttach 배선(SceneRendererResources.swift:
    /// 329-341)의 몫이며 이 배치는 파스만 착지한다. nil=일반 계층.
    public var attachment: String? = nil
    public init(id: Int, origin: Vec3, angles: Vec3, scale: Vec3, parent: Int?, visible: Bool) {
        self.id = id; self.origin = origin; self.angles = angles
        self.scale = scale; self.parent = parent; self.visible = visible
    }
}

/// 3D 라이트 오브젝트. type: "lpoint"(점) | "ldirectional"(방향) | "lspot"(스팟) | "ltube"(선형).
/// general.lightconfig 가 활성 라이트 종류/개수를 요약(point/directional/…shadow 카운트).
public struct SceneLight3D: Equatable {
    public let id: Int
    public let name: String
    public let type: String
    /// 로컬(부모 상대) 위치. 2D 씬은 파스 말미에 부모 체인을 합성한 월드 좌표로 덮어쓴다
    /// (F691 — composeLightParentTransforms; 레이어 composeParentTransforms 와 동일 규약)라 var.
    /// ltube 는 이 필드가 세그먼트 단점 A(WE g_LTube_OriginA).
    public var origin: Vec3
    /// ltube 세그먼트 단점 B(scene.json `originb` — wallpaper64.exe 스트링/에디터 키 실측, 소문자).
    /// WE 셰이더 g_LTube_OriginB(A2-pbr-lighting.md §4.3). origin 과 같은 부모-로컬 공간이라
    /// 2D 씬은 origin 과 함께 월드로 덮어쓴다(composeLightParentTransforms). nil = 미저작(비-tube 포함).
    public var originB: Vec3? = nil
    public let angles: Vec3
    public let color: Vec3
    public let radius: Float
    public let intensity: Float
    public let exponent: Float
    /// lspot 콘 전각(도). WE 에디터 "Inner/Outer cone". lpoint/ldirectional 은 미사용(0).
    public let innerCone: Float
    public let outerCone: Float
    public let castShadow: Bool
    /// F750(S-47): `cascadedistance0-2` — directional CSM 3-스플릿 far 경계 거리. 실측 11건
    /// (코퍼스 스캔 2026-07: lpoint 7/lspot 1/ldirectional 3 — WE 에디터가 라이트 종 무관하게 기록).
    /// 3키는 항상 동반(부분 저작 0건). nil = 미저작. 파스·보존 전용 — F661 단일 오소 근사가
    /// 캐스케이드로 승격될 때 소비(렌더 미배선).
    public let cascadeDistances: Vec3?
    /// F750(S-47): `castvolumetrics` — 볼류메트릭 라이트 샤프트 캐스트 플래그(실측 2건, 전부 true).
    public let castVolumetrics: Bool
    /// F750(S-47): `volumetricsexponent` — 볼류메트릭 감쇠 지수. 실측 13건(기본 1.0, 비기본 1.7/2.82/3.04).
    public let volumetricsExponent: Float
    /// F750(S-47): `density` — 볼류메트릭 산란 밀도. 실측 13건(기본 2.0, 비기본 0.65..4.12).
    public let density: Float
    public let parent: Int?
    public var order: Int = 0
    /// 프로퍼티 스크립트(color/intensity/radius/origin/angles — 키 → JS 소스). SceneObject3D.propertyScripts/
    /// SceneNode3D.propertyScripts 와 동일 규약(파스 캡처). 실측: intensity 8건(주야 조명 감쇠 컨트롤러),
    /// color 1건(3737268876 젤다). TODO(소비 미배선): per-frame 재평가는 코퍼스 저빈도라 YAGNI 보류 —
    /// 렌더러는 현재 정적 초기값(위 필드)만 소비한다.
    public var propertyScripts: [String: String] = [:]
    public init(id: Int, name: String, type: String, origin: Vec3, angles: Vec3, color: Vec3,
                radius: Float, intensity: Float, exponent: Float,
                innerCone: Float = 0, outerCone: Float = 0,
                castShadow: Bool, parent: Int?, order: Int = 0,
                cascadeDistances: Vec3? = nil, castVolumetrics: Bool = false,
                volumetricsExponent: Float = 1, density: Float = 2, originB: Vec3? = nil) {
        self.id = id; self.name = name; self.type = type
        self.origin = origin; self.originB = originB; self.angles = angles; self.color = color
        self.radius = radius; self.intensity = intensity; self.exponent = exponent
        self.innerCone = innerCone; self.outerCone = outerCone
        self.castShadow = castShadow; self.parent = parent; self.order = order
        self.cascadeDistances = cascadeDistances; self.castVolumetrics = castVolumetrics
        self.volumetricsExponent = volumetricsExponent; self.density = density
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
    /// - F800(S-9): `axisCone`/`kindCone` — 라이트 kind/axis/cone. 3D 경로(Scene3DLighting.swift)의
    ///   확정 규약을 2D 로 가져온 포트: kind 는 Scene3DLightKind rawValue 와 동일(0=point/1=directional/2=spot
    ///   /4=tube, 미지 type 은 point 폴터 — 종전 전원 point 처리와 동일이라 무회귀), axis 는 모델회전(Rz·Ry·Rx)의
    ///   blue축(+Z, col2) = WE 스크립트 API `Mat4.forward()` 규약, cone 은 spot 전각(도)→half-angle
    ///   코사인(Scene3DLighting.spotConeCosines 와 동일 변환). point 는 axis/cone 미사용(셰이더가 kind 로 분기).
    ///   tube(kind 4)는 axisCone.xyz 가 forward 가 아니라 **세그먼트 단점 B**(WE g_LTube_OriginB —
    ///   genericimage3.frag:115/157 PointSegmentDelta 소비, cone 미사용이라 동 슬롯 재활용).
    struct ForwardUniforms: Equatable {
        /// 2D 포워드 라이팅 슬롯 수. **QuadShaders.f_lit 의 루프 상한 · SceneRenderer 의
        /// lightPositions/lightColorRadius/lightAxisCone/lightKindCone 배열 길이와 같은 값이어야 한다.**
        /// F660 이 3D 레인을 8(Scene3DLighting.maximumLights)로 올릴 때 2D 레인만 4 로 남아 있었다 —
        /// 같은 씬에서 5번째 라이트부터 2D 라이팅 레이어에만 안 잡혔다. 8 로 맞춘다.
        public static let slotCount = 8
        public var positions: [SIMD4<Float>]   // xyz=world, w=finite-light exponent
        public var colorRadius: [SIMD4<Float>] // rgb=color×intensity, w=radius
        public var ambientTerm: SIMD3<Float>
        public var count: Int
        public var axisCone: [SIMD4<Float>]    // xyz=월드 forward(blue축) | tube=단점B, w=spot cone outer cos
        public var kindCone: [SIMD4<Float>]    // x=kind(0/1/2/4), y=spot cone inner cos
        public init(positions: [SIMD4<Float>], colorRadius: [SIMD4<Float>],
                    ambientTerm: SIMD3<Float>, count: Int,
                    // 기본값은 **4 그대로** 둔다(구형 호출부 소스/값 호환 — SceneForwardLightKindTests 가
                    // 이 길이를 단언한다). 실제 생산자 forwardUniforms 는 네 배열 모두 slotCount 로 만들고,
                    // 아래 count 클램프가 짧은 배열을 그 길이로 잘라 주므로 범위 밖 인덱싱은 생기지 않는다.
                    axisCone: [SIMD4<Float>] = [SIMD4<Float>](repeating: .zero, count: 4),
                    kindCone: [SIMD4<Float>] = [SIMD4<Float>](repeating: .zero, count: 4)) {
            // 공개 이니셜라이저는 호출자가 만든 배열을 그대로 받는데 종전엔 **아무 검증이 없었다**.
            // ① count 가 배열 길이와 독립이라 소비처(ScenePBRLighting.evaluateLighting 의
            //    `for i in 0..<min(count, …)` → positions[i]/colorRadius[i]/kindCone[i])가
            //    범위 밖을 읽고 트랩한다.
            // ② kindCone[i].x 가 NaN 이면 같은 자리의 `Int(kindCone[i].x + 0.5)` 가 트랩한다
            //    (Swift 의 Int(Float) 는 NaN/무한/범위 밖 입력에서 크래시 — 클램프가 아니다).
            // 그래서 count 를 **네 배열의 실제 길이**로 클램프하고 성분의 비유한 값을 0 으로 눕힌다.
            // 배열 길이 자체는 건드리지 않는다 — 기본값(.zero × 4) 계약과 기존 호출부 보존.
            func finite(_ v: [SIMD4<Float>]) -> [SIMD4<Float>] {
                v.map { s in
                    SIMD4<Float>(s.x.isFinite ? s.x : 0, s.y.isFinite ? s.y : 0,
                                 s.z.isFinite ? s.z : 0, s.w.isFinite ? s.w : 0)
                }
            }
            let capacity = min(min(positions.count, colorRadius.count),
                               min(axisCone.count, kindCone.count))
            self.positions = finite(positions); self.colorRadius = finite(colorRadius)
            self.ambientTerm = SIMD3<Float>(ambientTerm.x.isFinite ? ambientTerm.x : 0,
                                            ambientTerm.y.isFinite ? ambientTerm.y : 0,
                                            ambientTerm.z.isFinite ? ambientTerm.z : 0)
            self.count = max(0, min(count, capacity))
            self.axisCone = finite(axisCone); self.kindCone = finite(kindCone)
        }
    }

    /// F800(S-9): 2D 포워드 라이트 kind — Scene3DLightKind(type:) 와 동일 매핑(WapleRender 소속이라
    /// 직접 참조 불가, rawValue 규약 0/1/2/4 동기 유지). 미지 type 은 point 폴터(무회귀).
    /// ltube(4): WE 정식 tube 경로(genericimage3.frag:112-118/154-160) — 종전 point 오분류 폴터 제거.
    static func forwardLightKind(_ type: String) -> Int {
        switch type.lowercased() {
        case "ldirectional": return 1
        case "lspot": return 2
        case "ltube": return 4
        default: return 0   // lpoint + 미지
        }
    }

    /// F800(S-9): 라이트 월드 forward — Scene3DMath.modelMatrix(WapleRender)의 회전부(Rz·Ry·Rx)와
    /// 동일 수식의 blue축(col2) 포트(WapleCore 라 직접 참조 불가). 회전 열이라 단위 — 비유한 입력만
    /// (0,0,1) 폴터(3D normalizedOr 와 동일 시맨틱). 스케일 미포함(방향 전용).
    static func forwardLightAxis(angles: Vec3) -> SIMD3<Float> {
        let (sx, cx) = (sin(angles.x), cos(angles.x))
        let (sy, cy) = (sin(angles.y), cos(angles.y))
        let (sz, cz) = (sin(angles.z), cos(angles.z))
        let f = SIMD3<Float>(cz * sy * cx + sz * sx, sz * sy * cx - cz * sx, cy * cx)
        guard f.x.isFinite, f.y.isFinite, f.z.isFinite else { return SIMD3(0, 0, 1) }
        return f
    }

    /// F800(S-9): spot innercone/outercone(전각, 도) → half-angle 코사인 — Scene3DLighting
    /// .spotConeCosines(WapleRender)와 동일 변환의 2D 포트(동기 유지 책임).
    // ponytail: half vs full 미확정(3D 경로 주석과 동일) — full-angle 이면 `* 0.5` 제거.
    static func forwardSpotConeCosines(inner: Float, outer: Float) -> (inner: Float, outer: Float) {
        guard outer.isFinite, outer > 0 else { return (1, -1) }  // 콘 데이터 없음 → 반구 그라디언트(3D 동일)
        let toHalfRadians = Float.pi / 180 * 0.5
        let cosOuter = cos(max(0, outer) * toHalfRadians)
        let cosInnerRaw = inner.isFinite && inner > 0 ? cos(inner * toHalfRadians) : 1
        // inner 는 outer 보다 좁아야(코사인 큼) 스무드스텝이 0→1 로 증가.
        return (max(cosInnerRaw, cosOuter + 1e-4), cosOuter)
    }

    /// 라이트 배열 → 포워드 유니폼. slotCount(8) 초과 시 앞 8개(현행 근사 — WE 오브젝트별 relevance
    /// 선택은 미구현). 종전 상한은 4 였다(F660 의 3D 8-라이트 상향이 2D 레인에 도달하지 않았다).
    ///
    /// `skylight` 는 **여전히 미배선**이다(의도적, 이번 라운드 범위 밖). 3D 는 반구 그라디언트로
    /// `mix(skylight, ambient, dot(N, +Y)*0.5+0.5)` 를 쓰지만(Mesh3DShaders), 2D f_lit 의 앰비언트는
    /// genericimage4 규약대로 flat 이고 N 이 항상 +Z 라 반구 항이 상수로 접힌다 — 즉 skylight 를 넣으려면
    /// 수식 자체(그리고 유니폼 슬롯)를 새로 정해야 하고, 그건 전 라이팅 레이어의 픽셀을 바꾸는 변경이라
    /// 근거 없이 할 수 없다. 파라미터는 3D 팩과 호출 형태를 맞추기 위해 유지한다.
    static func forwardUniforms(_ lights: [SceneLight3D], ambient: Vec3, skylight _: Vec3) -> ForwardUniforms {
        let n = ForwardUniforms.slotCount
        var pos = [SIMD4<Float>](repeating: .zero, count: n)
        var cr = [SIMD4<Float>](repeating: .zero, count: n)
        var ac = [SIMD4<Float>](repeating: .zero, count: n)
        var kc = [SIMD4<Float>](repeating: .zero, count: n)
        let used = lights.prefix(n)
        for (i, l) in used.enumerated() {
            pos[i] = SIMD4(l.origin.x, l.origin.y, l.origin.z, l.exponent)
            cr[i] = SIMD4(l.color.x * l.intensity, l.color.y * l.intensity, l.color.z * l.intensity, l.radius)
            // F800(S-9): kind/axis/cone — 3D 확정 규약의 2D 포트(구조체 주석 참조).
            let kind = forwardLightKind(l.type)
            let axis = forwardLightAxis(angles: l.angles)
            var innerCos: Float = 0
            var outerCos: Float = 0
            if kind == 2 {
                let cone = forwardSpotConeCosines(inner: l.innerCone, outer: l.outerCone)
                innerCos = cone.inner; outerCos = cone.outer
            }
            if kind == 4 {
                // tube: axis 슬롯 = 세그먼트 단점 B(월드). originb 미저작은 A==B 퇴화 — WE
                // PointSegmentDelta(common_pbr.h:13-14)가 v==0 이면 A-pos 를 반환해 point 와 동치.
                let b = l.originB ?? l.origin
                ac[i] = SIMD4(b.x, b.y, b.z, 0)
            } else {
                ac[i] = SIMD4(axis.x, axis.y, axis.z, outerCos)
            }
            kc[i] = SIMD4(Float(kind), innerCos, 0, 0)
        }
        let amb = SIMD3(ambient.x, ambient.y, ambient.z)
        return ForwardUniforms(positions: pos, colorRadius: cr, ambientTerm: amb, count: used.count,
                               axisCone: ac, kindCone: kc)
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
    /// volume 프로퍼티 스크립트(update(value) → 새 오서 볼륨). 실측: 12건(예 2911866381 오디오/페이드
    /// 구동 볼륨). SceneAudioPlayer.tick(time:) 이 per-frame 재평가해 재생 중인 Playlist.authorVolume 을 갱신.
    public var volumeScript: String? = nil
    /// volume 스크립트의 저장 scriptproperties(사용자 오버라이드) — 레이어/텍스트와 동일 규약.
    public var volumeScriptProps: String? = nil
    /// `spatialization`/`attenuation`/`mindistance`(json-keys.txt:935 A 0x0048f8d8 / :933 A 0x0048f8b8 /
    /// :928 A 0x0048f868 — 실측 3737268876 등 32오브젝트, attenuation 전건 1.0·mindistance 최빈 1.0).
    /// 파스·보존 전용 — 실제 공간 감쇠 재생은 별도 기능(M6)이라 미소비. 기본값(false/1/1)은 비공간화
    /// 현행 재생과 동치(무회귀).
    public var spatialization: Bool = false
    public var attenuation: Float = 1
    public var minDistance: Float = 1
    public init(id: Int, name: String = "", sounds: [String], volume: Float, playbackMode: String,
                startSilent: Bool, minTime: Float, maxTime: Float) {
        self.id = id; self.name = name; self.sounds = sounds; self.volume = volume; self.playbackMode = playbackMode
        self.startSilent = startSilent; self.minTime = minTime; self.maxTime = maxTime
    }
}

/// 씬 `sprite` 오브젝트(scene.json `objects[]` 중 `"sprite"` 키가 **문자열**인 것).
///
/// **파티클 렌더러의 `sprite` 와는 다른 것이다.** 파티클 쪽 `sprite`/`spritetrail` 은
/// 파티클 JSON 의 `renderer[].name` **값**이고(동봉 코퍼스 실측 192 + 44건), 이쪽은 씬 오브젝트
/// **타입**이다. 같은 팩토리(`0x14018ff60`)가 두 타입에 서로 다른 전용 클래스를 만든다 —
/// 이 타입은 `0x270` 바이트(`mov ecx, 0x270` @ `0x140190304`), 파티클은 `0x960`(@ `0x1401901e9`).
/// WE 로케일이 두 이름을 다 쓰는 것이 혼동의 출처다(`ui_editor_particle_element_renderer_sprite`).
///
/// **정체**: 하드웨어 오클루전 쿼리로 가림 정도를 재서 밝기를 구동하는 태양/렌즈플레어 스프라이트다.
/// ctor `0x140256560–0x140256705` 가 저작 머티리얼과 **별도로** 프로브 머티리얼
/// `materials/util/occlusiontest.json`(문자열 `0x140491658`, 참조 `0x1402566bf`)을 로드하고
/// 오클루전 쿼리를 만든다(`0x1402566ea` — 바이너리 전체에서 쿼리 생성 호출지점은 여기 1곳뿐).
/// 밝기 매핑·1프레임 지연·프로브 크기까지 전문은 `docs/re/sprite-occlusion.md`.
///
/// **도달(2026-08-21 실측)**:
/// - 동봉 자산(`Sources/WapleRender/Resources/WEAssets`, JSON 1,698건) — **0건**.
///   그래서 이 타입은 **파스만 하고 렌더 배선은 하지 않는다**. 리눅스/CI 하네스가 보는
///   `WAPLE_WE_ASSETS` 기본 루트가 곧 이 트리라, 도달 0 은 "회귀 위험 0" 이기도 하다.
/// - 설치본(WE 2.8.42) 전체 JSON 2,143건 — **문자열 저작 1건**
///   (`projects/defaultprojects/ricepod/ricepod.json` `objects[7]` = name `"sun"`, id 9,
///    `"sprite": "materials/sprites/sunsprite.json"`)과 **null 저작 2건**
///   (`projects/defaultprojects/arsenal/scene.json` `objects[1]`/`objects[2]`).
///   null 2건은 `light: "point"` 오브젝트가 `model`/`particle`/`sprite` 를 전부 null 로 갖는
///   에디터 기본 서식이고, 아래 문자열 게이트에 걸려 여기로 오지 않는다(WE 팩토리도 동일).
public struct SceneSprite: Equatable {
    /// `objects[].id`. 베이스 씬 오브젝트 ctor `0x1401ddbb0` 이 `0x1401ddd69` 에서 부르는
    /// `0x1401a38f0` 이 읽는다(키 리터럴 `"id"` @ `0x14048e5bc`, 참조 `0x1401a391b`).
    /// WE 는 여기서 jsoncpp 타입 1..3(int/uint/real)만 받는다(`0x1401a3931–0x1401a393a`).
    /// Waple 의 `intVal` 은 문자열 숫자도 관용한다 — 실물 씬이 id 를 문자열로 싣는 사례가 있어
    /// 다른 오브젝트 타입이 이미 그렇게 하고 있고(intVal 주석), 여기만 다를 이유가 없다.
    public let id: Int
    /// `objects[].name` — 트리거/스크립트 주소지정용(SceneSound.name/SceneLayer.name 과 동일 규약).
    /// 베이스 오브젝트가 이 이름을 MSVC `std::string` 으로 `this+0x1d8` 에 들고 있고(base ctor 가
    /// 빈 문자열로 초기화 — `0x1401ddd3b–0x1401ddd56`, 용량 15 = SSO), 스크립트 프로퍼티 등록표
    /// `0x1401e0530` 이 그 슬롯을 `name` 으로 노출한다(참조 `0x1401e11d0`).
    /// **JSON `"name"` 키를 읽는 명령 자체는 sprite ctor 밖이고 아직 짚지 않았다** — 다른 오브젝트
    /// 타입과 같은 공통 경로라 같은 규약으로 읽는다(실측: ricepod 의 스프라이트가 `"name":"sun"`).
    public let name: String
    /// **`"sprite"` 키의 값 그 자체 = 플레어 머티리얼의 전체 경로**(`"materials/…/x.json"`).
    ///
    /// 팩토리가 `Json::Value::find(json, "sprite")`(`0x1401902de`, 키 리터럴 `0x14048e600`) 후
    /// `cmp byte [rax+8], 4`(`0x1401902fe`) → `jne`(`0x140190302`) 로 **jsoncpp `stringValue`(=4)**
    /// 만 통과시키고, ctor 가 그 문자열을 그대로 머티리얼 매니저(`scene+0x1630`)에 넘긴다:
    /// `json["sprite"]` `0x1402565b9` → 문자열 페이로드 추출 `0x1402565be–0x1402565d4`
    /// (길이 접두 4바이트 스킵 분기 포함) → 로드 `0x1402565df` → `this+0x240` 저장 `0x1402565e4`.
    ///
    /// 머티리얼 **이름**이 아니라 `materials/` 접두와 `.json` 확장자까지 포함한 **경로**다 —
    /// 같은 ctor 가 같은 로더에 넘기는 내장 프로브 경로 `"materials/util/occlusiontest.json"`
    /// (`0x1402566bf` → `0x1402566d4`)와 서식이 같고, 유일한 실측 저작값도 같은 서식이다.
    public let material: String
    /// 베이스 오브젝트 공통 변환. 스크립트 프로퍼티 등록표 `0x1401e0530` 이 세 이름을 등록한다 —
    /// `origin` `0x1401e05d2` / `scale` `0x1401e06a3` / `angles` `0x1401e0759`.
    /// 각도 규약은 다른 3D 오브젝트와 같다(오일러 X,Y,Z).
    public let origin: Vec3
    public let angles: Vec3
    public let scale: Vec3
    /// 부모 오브젝트 id(트랜스폼·가시성 계층). 베이스 vtable `0x1404903b8` 슬롯 `+0x40` =
    /// `0x1401de470` 이 로드 후처리로 `"parent"`(리터럴 `0x14048ed5c`, 참조 `0x1401de4b1`)를 읽어
    /// 링크한다. sprite vtable `0x140491680` 도 이 슬롯을 그대로 상속한다 — 두 표에서 값이 다른
    /// 슬롯은 `+0x00`(소멸자) `+0x48` `+0x50`(렌더 `0x140256780`) `+0x60` 넷뿐이고, 그중 뒤 셋은
    /// 베이스 표가 `_purecall`(`0x1402ba6d0`)을 담고 있는 순수 가상이라 "오버라이드"가 아니라
    /// 파생이 반드시 채워야 하는 자리다. nil = 루트.
    public let parent: Int?
    /// 정적 가시성. 렌더 디스패처가 그리기 직전 vtable `+0x68` = `0x140185010` 을 호출해
    /// 게이트하고(`0x14018adc8`, `0x14018ae72`), 그 구현이 플래그 워드 `this+0x120` 의 bit0 을 보고
    /// 부모 체인 `this+0x180` 으로 재귀한다(`0x140185014–0x140185029`).
    /// sprite 는 `+0x68` 을 오버라이드하지 않으므로 다른 오브젝트와 규약이 같다.
    public let visible: Bool
    /// scene.json `objects[]` 내 인덱스 — 다른 오브젝트와 공유하는 그리기/계층 순서.
    public var order: Int = 0
    /// 마우스 시차 가중치. 베이스 등록표의 `parallaxDepth`(`0x1401e082f`, 리터럴 `0x1404902c8`)
    /// — 이 키만 camelCase 다(SceneLayer/SceneParticle 의 같은 철자와 동형). 부재 시 1(균일).
    /// 실측 저작 1/1(ricepod 의 태양이 `"1.000 1.000"`).
    public var parallaxDepth: Vec2 = Vec2(x: 1, y: 1)
    /// 변환/가시성 프로퍼티 스크립트(origin/angles/scale/visible → JS 소스).
    /// SceneNode3D.propertyScripts 와 동일 규약(파스 캡처 — 소비는 렌더 배선의 몫).
    public var propertyScripts: [String: String] = [:]
    public init(id: Int, name: String, material: String, origin: Vec3, angles: Vec3, scale: Vec3,
                parent: Int?, visible: Bool, order: Int = 0) {
        self.id = id; self.name = name; self.material = material
        self.origin = origin; self.angles = angles; self.scale = scale
        self.parent = parent; self.visible = visible; self.order = order
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
    /// objects[] 의 camera 의사-오브젝트(가시분만 — 정적 비가시는 비활성 카메라로 종전 노드 보존 경로).
    public var cameraObjects: [SceneCameraObject] = []
    /// 3D 메시 오브젝트(`.mdl` 직접 참조). 2D 씬에서는 빈 배열.
    public var objects3D: [SceneObject3D] = []
    /// 3D 라이트 오브젝트.
    public var lights3D: [SceneLight3D] = []
    /// 트랜스폼-온리 그룹 노드(parent 계층 합성용). 비가시(false) 노드도 기록 — 서브트리 판정에 필요.
    public var nodes3D: [SceneNode3D] = []
    /// 씬 sound 오브젝트. 2D/3D 무관 전역 재생(트랜스폼/공간화는 미반영). 렌더러(SceneAudioPlayer)가 재생.
    public var sounds: [SceneSound] = []
    /// 씬 `sprite` 오브젝트(하드웨어 오클루전으로 밝기를 구동하는 태양/렌즈플레어 — SceneSprite 주석).
    /// **파스·보존 전용이고 렌더는 미배선이다.** 동봉 자산 도달이 **0건**이라(설치본 전체에서도
    /// 문자열 저작 1건 — ricepod 의 태양) 배선의 우선순위가 낮다는 판단이고, 그래서 여기 담아만 둔다.
    /// 담아 두는 이유는 parseNode 주석(콘텐츠 키 목록)과 같다 — 인식만 시켜 두면 미구현이 미구현으로
    /// 남고, 트랜스폼-온리 그룹 노드로 조용히 흡수되지 않는다. 배선 지침은 `docs/re/sprite-occlusion.md` §8.3.
    public var sprites: [SceneSprite] = []
    /// `general.ambientcolor` — 포워드 라이팅의 앰비언트 바닥(라이트 미도달 영역이 전흑되지 않게).
    public var ambientColor: Vec3 = Vec3(x: 0, y: 0, z: 0)
    /// `general.skylightcolor` — 3D 반구 앰비언트의 상단 색. 2D genericimage4 포워드 경로는
    /// flat ambient 만 소비하므로 이 값은 사용하지 않는다.
    ///
    /// **[2026-08-21 정정] `ambientcolor` 폴백은 WE 에 없다.** 두 키는 등록도 저장도 독립이고
    /// (`skylightcolor` 등록 `0x14019a26f` → `scene+0x374`, `ambientcolor` 등록 `0x14019a1c6` → `scene+0x368`),
    /// 생성자는 둘 다 0 으로만 깔아 둔다(`0x140186f6f`·`0x140186f76` — r15=0 스토어).
    /// 종전의 `?? ambientColor` 는 `ambientcolor` 만 저작한 씬에서 하늘광을 이중 가산했다.
    /// 동봉 172씬 중 `skylightcolor` 생략은 2건인데(gifscene · videoplayer) 그 둘은 `ambientcolor` 도
    /// 생략하므로 종전 폴백 결과도 (0,0,0) 이었다 — **화면이 달라지는 동봉 씬 0건**.
    public var skylightColor: Vec3 = Vec3(x: 0, y: 0, z: 0)

    /// `general.hdr` — HDR 씬 플래그. true 면 렌더러가 float(rgba16Float) 누적 버퍼 + 톤맵 패스로
    /// >1.0 합을 [0,1] 로 압축한다(종전 bgra8 하드클램프 = 밝은 영역 순백 "백화" 방지).
    /// WE combine_srgb/hdr_upsample 경로 대응(lane-04 §1.2). 부재 시 false = 종전 LDR 경로(무회귀).
    public var hdr: Bool = false
    /// `general.bloom` — fixed two-stage LDR bloom request. Renderer activation additionally requires `!general.hdr`.
    ///
    /// **[2026-08-21] WE 기본값은 `true` 다 — 여기만 의도적으로 다르다.** 씬 생성자가 플래그 워드
    /// `scene+0xe0` 을 `0x26`(= bit1|bit2|bit5)으로 초기화하고(`0x140186d1f`), `bloom` 은 그 bit1 이다
    /// (등록 `0x140199836` — 타입 6=bool · 오프셋 `0xe0`; 게터 썽크 `0x14019b6e0` 이 `shr edx,1 / and dl,1`).
    /// 에디터가 전 씬에 `"bloom": false` 를 명시 저작해서 코퍼스로는 안 드러난다.
    ///
    /// 그런데도 `false` 로 두는 이유는 **실사용 이득이 0이고 비용만 있기 때문**이다 —
    /// 동봉 172씬이 **전건 이 키를 저작**하므로 `true` 로 바꿔도 달라지는 실물 씬은 0건인데,
    /// `sceneWantsLDRBloom = doc.bloom && !doc.hdr`(`SceneRenderer.swift`)를 타고
    /// **키를 생략한 합성 렌더 픽스처 60여 개**의 합성 결과가 한꺼번에 바뀐다.
    /// 실효는 워크샵 씬 전용이므로, 렌더 픽스처를 같이 손볼 수 있는 레인에서 한 커밋으로 뒤집어야 한다
    /// (필요한 변경은 이 줄과 파스의 `?? false` 두 곳뿐 — `docs/re/scene-postprocessing.md` §7 W-4).
    public var bloom: Bool = false
    /// WE fixed two-stage LDR bloom parameters. Strength/threshold remain authored finite values without clamps.
    public var bloomStrength: Float = 2
    public var bloomThreshold: Float = 0.65
    public var bloomTint: Vec3 = Vec3(x: 1, y: 1, z: 1)
    /// WE HDR bloom(soft-knee QuadraticThreshold) 파라미터 — `hdr && bloom` 씬 전용(#22, PS 29931 라이브 확증).
    /// 기본값은 클린룸 확정치(threshold 1.0 · feather 0.1 · scatter 1.619 · iterations 8 — A3 §0).
    ///
    /// **[2026-08-21 정정] strength 기본은 미복원이 아니라 2.0 이다.** 씬 생성자가
    /// `scene+0x3c4` 에 `0x40000000`(=2.0)을 기록한다(`0x1401870c2`; 등록 `0x140199b87` — 타입 4=float).
    /// LDR 짝인 `bloomstrength`(`scene+0x3bc`, `0x1401870ac`)와 **같은 2.0** 이다.
    /// 종전의 0 은 키를 생략한 HDR 씬에서 블룸을 전멸시켰다. 동봉 172씬 중 이 키 생략은 84건이지만
    /// `hdr && bloom` 인 씬은 previewthunderbolt 1건뿐이고 그 씬은 2.0 을 명시 저작한다 —
    /// **화면이 달라지는 동봉 씬 0건**(효과는 키를 생략하는 워크샵 HDR 씬 전용).
    public var bloomHDRStrength: Float = 2
    public var bloomHDRThreshold: Float = 1
    /// knee = threshold × feather (feather 단독 아님 — 윈도우 L1 라이브 cbuffer 확증).
    public var bloomHDRFeather: Float = 0.1
    /// 피라미드 단수(코퍼스 2~8). 단일 레벨 구현은 strength 보상 계수로 소비(실효 = strength ×
    /// iterations — HDRBloomPass.strengthScale 캘리브 근거 참조); 피라미드 승격 시 단수 자체로 소비.
    public var bloomHDRIterations: Int = 8
    /// 업샘플 텐트 계수(레벨당 ×0.25×scatter, additive). 단일 레벨 구현은 미소비 — 피라미드 전용.
    public var bloomHDRScatter: Float = 1.619

    /// `general.camerashake` — 전역 카메라 지터 enable(bool). 코퍼스 활성 13/168씬(그 외는 편집기 기본값을
    /// 동반하되 비활성). 클린룸 확정 수식 부재(문서 결론은 "전역 지터" §16만) → 렌더러가 코퍼스 값분포 기반
    /// 결정적 근사로 적용(SceneRenderer.cameraShakeOffset). 비활성 씬은 렌더 경로가 비켜가 비트동일.
    public var cameraShake: Bool = false
    /// 지터 진폭(무차원 상대값 — 코퍼스 0.04..1.0, 기본 0.5). 렌더러가 NDC 스케일 상수로 환산.
    public var cameraShakeAmplitude: Float = 0.5
    /// 지터 거칠기(고주파 오버톤 혼합비 — 코퍼스 0.0..1.1, 기본 1.0).
    public var cameraShakeRoughness: Float = 1
    /// 지터 속도(시간 진행 스케일 — 코퍼스 0.5..7.0, 기본 3.0).
    public var cameraShakeSpeed: Float = 3

    /// 2D 포워드 라이팅 활성 조건: 2D 오르토 씬(camera3D==nil) + 라이트 존재. 3D(원근) 씬은 메시
    /// 라이팅 경로 담당(현행 미구현 — 보고). 개별 레이어는 `SceneLayer.lighting`(LIGHTING 콤보)로 추가 게이트.
    public var forwardLit2D: Bool { camera3D == nil && !lights3D.isEmpty }

    /// F695: `general.zoom` — 씬 전역 줌(비기본 실측 7씬: 1.006..1.08, {user/script,value} 바인딩은
    /// 정적 value 언랩). 부재 시 1(무회귀). 파스·보존 전용 — 프레이밍 적용 소비는 렌더러 책임.
    public var zoom: Float = 1
    /// F692: `general.perspectiveoverridefov` — perspective:true 레이어(SceneLayer.perspective)의
    /// 원근 투영 FOV(도). 동봉 172씬 저작 77건(95.0 71 · 90.760002 6).
    ///
    /// **[2026-08-21 정정] 미저작은 nil 이 아니라 95.0 이다.** 씬 생성자가 `scene+0x144` 에
    /// `0x42be0000`(=95.0)을 기록하고(`0x140186d67`; 등록 `0x14019aa9d` — 타입 4=float),
    /// `Scene::updateCamera` 가 **정사영 씬일 때 실효 fov 로 이 값을 고른다**
    /// (`0x140189278`: `eax=0x144` · `edx=0x140` · `test r9b,8`(flags bit3=정사영) · `cmove eax,edx`).
    /// 즉 2D 씬의 실효 fov 는 `fov` 가 아니라 이 키다. 종전 `Float?`/nil 은 "미저작" 을 값이 없는 것으로
    /// 표현해 렌더러가 리터럴 95 를 하드코딩하게 만들었고, 그래서 `90.760002` 를 저작한 동봉 6씬의
    /// `perspective:true` 레이어 원근이 WE 와 어긋난다(렌더 소비는 별 레인 — 여기서는 값만 바로잡는다).
    public var perspectiveOverrideFov: Float = 95

    /// `general.clearenabled`(json-keys.txt:667 A 0x0048d558) — false 면 렌더러가 프레임 누적(acc)
    /// 버퍼를 지우지 않는다(잔상 누적 = 엔진 동작 — SceneRenderer.clearEnabled 소비). 부재 시 true
    /// (무회귀). 코퍼스 실측 161/161 전건 true 저작(비활성 실물 사례 없음).
    public var clearEnabled: Bool = true
    /// `general.camerafade`(json-keys.txt:686 A 0x0048d6c8) — 파스만(의미 미확정 — 소비 보류).
    /// 부재 시 true(코퍼스 161/161 전건 true 저작과 동치).
    public var cameraFade: Bool = true
    /// `general.windenabled/windstrength/winddirection` + `gravitystrength/gravitydirection`
    /// (json-keys.txt:696-700) — 파스·보존 전용(소비자 의미론 미확정: 파티클 외력 추정 — 소비 보류).
    /// 코퍼스 실측 109/161씬 보유: direction 은 "x y z" vec3 문자열(2802243144 등 전건 동일 형태 —
    /// corpus_scan/scene-json-schema.md:80-82 의 "float radians" 기술은 실물과 불일치, 실측이 정본).
    /// 기본값 = 코퍼스 전건 모달값(에디터 기본 저작치 — 부재 시 명시 저작과 동치라 무회귀).
    public var windEnabled: Bool = false
    public var windStrength: Float = 1
    public var windDirection: Vec3 = Vec3(x: 0.707, y: 0.707, z: 0)
    public var gravityStrength: Float = 1
    public var gravityDirection: Vec3 = Vec3(x: 0, y: -1, z: 0)

    /// H7: 품질 설정 — low/medium/high/ultra. 픽셀 포맷 분기에 사용. 부재 시 ultra(무회귀).
    ///
    /// **[2026-08-20 정정] 이것은 WE 키가 아니라 Waple 확장이다.** 종전 주석은
    /// "WE 품질 설정(general.quality)" 이라고 적었는데, `wallpaper64.exe` 전수 검색에서
    /// `quality` 를 포함하는 문자열은 **`uiquality` 하나뿐**이고(VA 0x1404747d0, UI 스킨 설정)
    /// UTF-16LE 은 0건이다. 씬의 `general` 에 `quality` 라는 키는 **존재하지 않는다**.
    ///
    /// 자산 실측도 같은 말을 한다 — 동봉+설치본 scene.json 355개의 `general` 이 실제로 쓰는
    /// 키는 39종이고 `quality` 는 그중에 없다(도달 0/355). 그래서 이 값은 **항상 `.ultra`** 이고
    /// low/medium 분기는 한 번도 안 탄다.
    ///
    /// WE 의 실제 품질 노브는 **씬이 아니라 사용자 설정**에 있다(`config.json` 의
    /// `msaa`/`resolution`/`postprocessing`/`shadows`). 씬 단위로 품질을 낮추는 개념 자체가 없다.
    /// 필드를 남겨 두는 이유는 public API 이고 도달 0 이라 무해하기 때문이다 — 다만
    /// **"WE 가 이렇게 한다" 는 근거로 쓰면 안 된다.**
    public enum Quality: String, Equatable {
        case low, medium, high, ultra
    }
    public var quality: Quality = .ultra
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
        userProps: [String: Any] = [:],
        sceneFileName: String? = nil
    ) throws -> SceneDocument {
        // G-E3-02: 씬 문서의 이름은 `project.json` 의 `"file"` 이 정한다 — `scene.json` 은 관례일 뿐
        // 규약이 아니다. WE 2.8.42 설치본 실측: 씬 프로젝트 18개 중 4개가 다른 이름을 쓴다
        // (`audiophile.json` `fantasticcar.json` `ricepod.json` `techno.json`, 그리고 GIF 템플릿의
        // `gifscene.json`). 워크샵 코퍼스는 전건 `scene.json` 이라 이 결함이 지금까지 안 잡혔다.
        // 호출자가 이름을 주지 않으면 종전 관례 순서로 폴백한다(무회귀).
        let sceneCandidates: [String] = [sceneFileName, "scene.json", "gifscene.json"].compactMap { $0 }
        guard let sceneData = sceneCandidates.compactMap({ package.data(for: $0) }).first,
              var scene = AssetJSON.dictionary(sceneData) else {
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
        // 부재 시 (0,0,0) — `ambientcolor` 폴백이 아니다(선언부 주석: 등록/저장/생성자 모두 독립).
        let skylightColor = vec3(general["skylightcolor"]) ?? Vec3(x: 0, y: 0, z: 0)
        // HDR/블룸 플래그 — 종전 조용히 폐기(lane-04 §2.1). {"user":…,"value":Bool} 바인딩은 unwrap 이 처리.
        // `hdr` 은 flags bit10(게터 `0x14019b900`)이라 생성자 `0x26` 에서 clear = false.
        // `bloom` 은 bit1 이라 WE 기본은 **true** 인데 여기만 의도적으로 false 다 — 선언부 주석 참조.
        let hdr = (unwrap(general["hdr"]) as? Bool) ?? false
        let bloom = (unwrap(general["bloom"]) as? Bool) ?? false
        // {"user":…,"value":Bool} 바인딩 형태(실물 21씬)는 unwrap 이 value 를 꺼낸다(평문 Bool 은 그대로).
        // 패럴랙스 3종 기본값은 씬 생성자 실측이다 — amount `scene+0x334`=0.5(`0x140186fa5`),
        // mouseinfluence `scene+0x33c`=0.5(`0x140186fbb`, qword 스토어의 하위 dword),
        // delay `scene+0x338`=0.1(`0x140186fb0`). 종전 1/1/0 은 이동량·마우스 추종을 2배로,
        // 추종을 즉시 스냅으로 만들었다. 동봉 172씬 중 이 셋을 생략하는 4씬(gifs · particleeditor ·
        // particleeditor3dscale · videoplayer)은 `cameraparallax` 도 생략해 비활성이라 **영향 0건**.
        let parallaxEnabled = (unwrap(general["cameraparallax"]) as? Bool) ?? false
        let parallaxAmount = float(general["cameraparallaxamount"]) ?? 0.5
        let parallaxMouseInfluence = float(general["cameraparallaxmouseinfluence"]) ?? 0.5
        let parallaxDelay = max(0, float(general["cameraparallaxdelay"]) ?? 0.1)
        // H7: 품질 설정. **WE 키가 아니라 Waple 확장이다** — 선언부(`SceneDocument.Quality`) 주석 참조.
        // 동봉+설치본 355개 씬 전건 부재라 실질적으로 항상 .ultra 다.
        let quality = Quality(rawValue: (general["quality"] as? String)?.lowercased() ?? "ultra") ?? .ultra

        // 3D 카메라(orthogonalprojection 이 딕셔너리가 아닌 3D 씬 + camera{eye,center,up}+fov 존재 시). 2D=nil.
        let (camera3D, cameraScripts) = parseCamera(scene: scene, general: general)

        var layers: [SceneLayer] = []
        var particles: [SceneParticle] = []
        var texts: [SceneTextLayer] = []
        var objects3D: [SceneObject3D] = []
        var lights3D: [SceneLight3D] = []
        var nodes3D: [SceneNode3D] = []
        var sounds: [SceneSound] = []
        var sprites: [SceneSprite] = []
        var cameraObjects: [SceneCameraObject] = []
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
            // sound 는 배열(플레이리스트) 또는 단수 경로 문자열(scene-json-schema.md:141 "path to audio
            // entry" 단수형 기술) — 종전엔 배열 전용 게이트라 문자열 형태가 조용히 누락됐다(관용 파스).
            if obj["sound"] is [Any] || obj["sound"] is String {
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
                    var invNode = SceneNode3D(
                        id: objectID,
                        origin: vec3(obj["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
                        angles: vec3(obj["angles"]) ?? Vec3(x: 0, y: 0, z: 0),
                        scale: vec3(obj["scale"]) ?? Vec3(x: 1, y: 1, z: 1),
                        parent: intVal(obj["parent"]),
                        visible: false)
                    // 정적 비가시 콘텐츠 노드의 트랜스폼 스크립트(origin/angles/scale) 보존 — 이들이
                    // shared 사이드이펙트로 다른 스크립트를 구동한다(실물 3470948192: 비가시 id=56 origin
                    // 스크립트가 shared.xx 세팅 → text id=181 이 소비 → shared.vvv → Hollow Cylinder 스케일).
                    // 종전엔 트랜스폼만 보존하고 스크립트를 버려 컨트롤러 체인이 끊겼다(소비 지오메트리 NaN).
                    invNode.propertyScripts = transformScripts(obj)
                    nodes3D.append(invNode)
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
                                         assets: resolvedAssets,
                                         initialVisible: initialVisible,
                                         userProps: userProps) {
                    p.order = order
                    particles.append(p)
                }
            } else if let sprite = parseSprite(obj, order: order, initialVisible: initialVisible,
                                               visibleScript: visibleScript) {
                // WE 팩토리의 키 탐색 순서는 model → particle → image → **sprite** → text → light → …
                // (`mov ecx, size` VA: `0x14019013c`/`0x1401901e9`/`0x14019029f`/`0x140190304`/
                //  `0x14019034d`/`0x1401903ba`). 여기 위치가 그 순서다 — image/particle 뒤, text 앞.
                // parseSprite 가 문자열 게이트를 겸하므로(값이 null/숫자면 nil) 아래 분기로 흘러간다.
                sprites.append(sprite)
            } else if contentValue(obj["text"]) != nil {
                texts.append(parseText(obj, order: order, visibleScript: visibleScript,
                                       visibleScriptProps: visibleScriptProps, initialVisible: initialVisible,
                                       userProps: userProps))
            } else if let modelPath = contentValue(obj["model"]) as? String {
                objects3D.append(parseModel(obj, modelPath: modelPath, order: order,
                                            visibleScript: visibleScript, userProps: userProps))
            } else if let lightType = contentValue(obj["light"]) as? String {
                lights3D.append(parseLight(obj, lightType: lightType, order: order))
            } else if contentValue(obj["camera"]) != nil {
                cameraObjects.append(parseCameraObject(obj))
            } else if isEffectQuad(obj) {
                layers.append(effectQuadLayer(obj, order: order, pw: pw, ph: ph,
                                              visibleScript: visibleScript,
                                              visibleScriptProps: visibleScriptProps,
                                              initialVisible: initialVisible,
                                              userProps: userProps))
            }
        }
        // W3-①(C8): 2D 가시성 상속 전파 — 비가시 조상(정적 false 뿐 아니라 user-조건 바인딩이 false 로
        // 해소된 부모도 포함, 3299228616 의 clocklocation 콤보 그룹)의 자식 중 자기 visibleScript 없는
        // 레이어/텍스트/파티클을 initialVisible=false 로 마킹한다(geometry compose 이전— parent 필드는
        // 이후 단계가 건드리지 않아 순서 무관하지만 논리적으로 먼저 둔다).
        applyVisibilityInheritance(layers: &layers, texts: &texts, particles: &particles, nodes3D: nodes3D,
                                   camera3D: camera3D, imageLayerCompositeIDs: imageLayerCompositeIDs)
        // F691: 2D 씬 라이트의 parent 체인 합성(로컬 origin → 월드 픽셀) — 레이어 합성 전에 실행
        // (composeParentTransforms 가 layers 를 월드로 덮어쓰면 부모-레이어 로컬값이 유실된다).
        // 3D 씬은 렌더러(Scene3DLighting.resolveLights)가 월드행렬을 합성하므로 제외(이중 적용 방지).
        composeLightParentTransforms(lights: &lights3D, layers: layers, nodes3D: nodes3D, camera3D: camera3D)
        // E1: 2D 텍스트/파티클 오브젝트의 parent 체인 합성 — 라이트와 동일 이유로 레이어 합성 전에 실행
        // (레이어가 월드로 덮어써지면 부모-레이어 로컬값이 유실된다). 종전에는 SceneTextLayer 에 parent
        // 필드 자체가 없고 SceneParticle.parent 는 3D 마운트 경로 전용이라, 부모 붙은 텍스트/파티클이
        // 저작 로컬 좌표(대개 화면 밖/좌상단) 그대로 렌더됐다(가시 텍스트 177개/62씬).
        composeTextParentTransforms(texts: &texts, layers: layers, nodes3D: nodes3D, camera3D: camera3D)
        composeParticleParentTransforms(particles: &particles, layers: layers, nodes3D: nodes3D, camera3D: camera3D)
        // 레이어 parent 체인 합성(부모의 origin/scale/angle 을 이어붙여 로컬→월드 픽셀로 굽는다). texts 는
        // 위에서 이미 월드로 확정된 뒤라 "부모=텍스트" 인 이미지 자식(W3-⑤, 3701356561 Solide H/V)도 여기서
        // 정상 합성된다.
        composeParentTransforms(
            layers: &layers,
            nodes3D: nodes3D,
            texts: texts,
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
        out.cameraObjects = cameraObjects
        out.sounds = sounds
        out.sprites = sprites
        out.ambientColor = ambientColor
        out.skylightColor = skylightColor
        out.hdr = hdr
        out.bloom = bloom
        applyGeneralSettings(to: &out, general: general, quality: quality)
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
            userProps: userProps,
            instance: obj["instance"] as? [String: Any]
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
        var cropOffset: Vec2? = nil   // F751(S-20): 모델 json cropoffset — 필드 주석 참조
        var blendMode = "normal"
        var depthTest = true
        var depthWrite = true
        var alphaWriting = "default"   // 머티리얼 패스 alphawriting — 파스·보존 전용(필드 주석 참조)
        var spritesheetCombo = false
        var lightingCombo = false
        var roughness: Float = 0.7
        var metallic: Float = 0
        var specularTint = Vec3(x: 1, y: 1, z: 1)
        var materialScripts: [String: String] = [:]
        var materialScriptProps: [String: String] = [:]
        // H1: 커스텀 머티리얼 셰이더/콤보/상수/텍스처 파스 보존.
        var materialShader: String? = nil
        var materialCombos: [String: Int] = [:]
        var materialConstants: [String: [Float]] = [:]
        var materialConstantScripts: [String: String] = [:]
        var materialConstantScriptProps: [String: String] = [:]
        var materialTextureNames: [String?] = []
        // H2: usershadervalues — 머티리얼 상수 이름 → user property 키 매핑.
        var materialUserShaderValues: [String: String] = [:]
        // H4: REFRACT 콤보 + 노멀맵 + refractAmount.
        var refract = false
        var normalTextureName: String? = nil
        var refractAmount: Float = 0.05
        // 모델/머티리얼 JSON 재조회(resolveLayerTexture 가 이미 한 번 읽은 것을 다시 읽는다 —
        // 레이어당 이중 파스지만 구조를 바꾸지 않는다). **소스 집합을 requiredData(:2007) 와 맞춘다**:
        // package → sharedAssetProbe → assets. 종전 이 자리는 `package.data(for:) ?? assets?(…)` 만
        // 봤다. 현재 유일한 호출부(parse)가 assets 에 probe 를 감싼 클로저를 넘기고 있어 실동작은 같았지만
        // (그래서 이 결함은 재현되지 않는다 — 종전 진단을 정정), 두 읽기의 소스 집합이 갈라져 있다는 것
        // 자체가 위험이다: probe 만 주입하고 assets 를 따로 넘기는 호출자가 생기면 텍스처는 해석되는데
        // puppet·cropoffset·blend·depth·머티리얼 콤보/상수/텍스처·refract 만 **로그 없이** 사라진다.
        // 아래 두 실패 경로에 로그를 붙여 그 조용한 유실을 없앤다(resolveLayerTexture 가 이미 성공한
        // 뒤이므로 이 경고는 정상 입력에선 나오지 않는다 — 나오면 진짜 이상 신호다).
        func layerJSONData(_ name: String) -> Data? {
            if let data = package.data(for: name) { return data }
            if let sharedAssetProbe, case .data(let data) = sharedAssetProbe(name) { return data }
            return assets?(name)
        }
        if let md = layerJSONData(imagePath),
           let mj = AssetJSON.dictionary(md) {
            puppetPath = mj["puppet"] as? String
            cropOffset = vec2(mj["cropoffset"])
            if let matPath = mj["material"] as? String {
                if let matD = layerJSONData(matPath),
                   let matJ = AssetJSON.dictionary(matD),
                   let p0 = (matJ["passes"] as? [Any])?.first as? [String: Any] {
                    let matResult: MaterialPassResult = parseMaterialPassProperties(p0, userProps: userProps)
                    blendMode = matResult.blendMode
                    depthTest = matResult.depthTest
                    depthWrite = matResult.depthWrite
                    alphaWriting = matResult.alphaWriting
                    spritesheetCombo = matResult.spritesheetCombo
                    lightingCombo = matResult.lightingCombo
                    roughness = matResult.roughness
                    metallic = matResult.metallic
                    specularTint = matResult.specularTint
                    materialScripts = matResult.materialScripts
                    materialScriptProps = matResult.materialScriptProps
                    materialShader = matResult.materialShader
                    materialCombos = matResult.materialCombos
                    materialConstants = matResult.materialConstants
                    materialConstantScripts = matResult.materialConstantScripts
                    materialConstantScriptProps = matResult.materialConstantScriptProps
                    materialTextureNames = matResult.materialTextureNames
                    materialUserShaderValues = matResult.materialUserShaderValues
                    refract = matResult.refract
                    normalTextureName = matResult.normalTextureName
                    refractAmount = matResult.refractAmount
                } else {
                    WapleLog.warn("[Waple] image layer material properties unavailable: \(matPath) (image=\(imagePath))")
                }
            }
        } else {
            WapleLog.warn("[Waple] image layer model json unavailable for material properties: \(imagePath)")
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
            effects: parseEffects(obj["effects"], userProps: userProps),
            order: order,
            isFrameBuffer: isFB,
            animations: anims
        )
        layer.name = (obj["name"] as? String) ?? ""
        layer.puppet = puppetPath
        layer.cropOffset = cropOffset
        if puppetPath != nil { layer.animationLayers = parseAllAnimationLayers(obj["animationlayers"]) }
        layer.propertyScripts = propScripts
        layer.propertyScriptProps = propScriptProps
        layer.initialVisible = initialVisible
        layer.blendMode = blendMode
        layer.depthTest = depthTest
        layer.depthWrite = depthWrite
        layer.alphaWriting = alphaWriting
        layer.spritesheet = spritesheetCombo
        layer.lighting = lightingCombo
        layer.roughness = roughness
        layer.metallic = metallic
        layer.specularTint = specularTint
        layer.materialScripts = materialScripts
        layer.materialScriptProps = materialScriptProps
        // H1: 커스텀 머티리얼 셰이더/콤보/상수/텍스처 파스 보존.
        layer.materialShader = materialShader
        layer.materialCombos = materialCombos
        layer.materialConstants = materialConstants
        layer.materialConstantScripts = materialConstantScripts
        layer.materialConstantScriptProps = materialConstantScriptProps
        layer.materialTextureNames = materialTextureNames
        // H2: usershadervalues — 머티리얼 상수 이름 → user property 키 매핑.
        layer.materialUserShaderValues = materialUserShaderValues
        // H4: REFRACT 콤보 + 노멀맵 + refractAmount.
        layer.refract = refract
        layer.normalTextureName = normalTextureName
        layer.refractAmount = refractAmount
        layer.colorBlendMode = blendModeVal(obj["colorBlendMode"])
        // 3D 씬 빌보드용: origin 의 z 성분(월드)과 부모 계층 보존(2D 경로는 origin.xy 만 사용 — 무영향).
        let originFull = floats(obj["origin"])
        layer.originZ = originFull.count >= 3 ? originFull[2] : 0
        layer.parent = intVal(obj["parent"])
        layer.attachment = obj["attachment"] as? String   // 이름 본-슬롯 부착(28씬 실측: 평문 문자열)
        layer.id = intVal(obj["id"]) ?? 0
        layer.alignment = (obj["alignment"] as? String) ?? "center"
        // F692/F696: perspective 플래그·명시 렌더 의존 id 목록 파스 보존(소비는 렌더러 책임 — 필드 주석 참조).
        layer.perspective = (unwrap(obj["perspective"]) as? Bool) ?? false
        layer.dependencies = (obj["dependencies"] as? [Any])?.compactMap { intVal($0) } ?? []
        // M7/M5: object-level render flags + config passthrough.
        layer.disablePropagation = (unwrap(obj["disablepropagation"]) as? Bool) ?? false
        layer.copyBackground = (unwrap(obj["copybackground"]) as? Bool) ?? true
        layer.clampUVs = (unwrap(obj["clampuvs"]) as? Bool) ?? true   // WE ctor 0x8040 bit15 — 선언부 주석 참조
        layer.noInterpolation = (unwrap(obj["nointerpolation"]) as? Bool) ?? false
        layer.spacing = float(obj["spacing"])
        layer.lockTransforms = (unwrap(obj["locktransforms"]) as? Bool) ?? false
        layer.isSolid = (unwrap(obj["solid"]) as? Bool) ?? false
        layer.ledSource = (unwrap(obj["ledsource"]) as? Bool) ?? false
        if let config = obj["config"] as? [String: Any] {
            layer.configPassthrough = (unwrap(config["passthrough"]) as? Bool) ?? false
            layer.configAutosize = (unwrap(config["autosize"]) as? Bool) ?? false
            layer.configIsSolidLayer = (unwrap(config["solidlayer"]) as? Bool) ?? false
            layer.configIsProjectLayer = (unwrap(config["projectlayer"]) as? Bool) ?? false
            layer.configIsInstanced = (unwrap(config["instanced"]) as? Bool) ?? false
        }
        return layer
    }

    /// 3D 카메라 + 프로퍼티 스크립트. orthogonalprojection 이 딕셔너리가 아니고(3D 씬은 null)
    /// camera{eye,center,up} + general.fov 가 있을 때만 카메라 반환(2D=nil). fov 는 float() 언랩 —
    /// 실물(젤다)은 {"script":…,"value":50} 스크립트 프로퍼티. eye/center/up 은 scene.camera, fov 는 general.
    private static func parseCamera(scene: [String: Any], general: [String: Any]) -> (camera: SceneCamera3D?, scripts: [String: String]) {
        guard !(general["orthogonalprojection"] is [String: Any]),
              let camDict = scene["camera"] as? [String: Any],
              let eye = vec3(camDict["eye"]), let center = vec3(camDict["center"]),
              let up = vec3(camDict["up"]) else { return (nil, [:]) }
        // G-E3-04: `general.fov` 는 **선택** 키다. 종전엔 이걸 guard 에 넣어 fov 가 없으면 카메라를
        // 통째로 버렸는데, 그러면 `camera3D == nil` + `objects3D` 비어있지 않음 → SceneRenderer 의
        // ortho 하이브리드로 빠져 **픽셀 단위 정사영**이 된다. 모델 월드좌표가 ±5 단위인데 1920px
        // 프러스텀에 넣으므로 씬이 화면 좌하단 서브픽셀로 붕괴한다(= 사용자는 clearcolor 만 본다).
        // 실측(WE 2.8.42 설치본 전수): 3D 씬 8개(arsenal audiophile demon_core dna_fragment
        // fantasticcar neon_sunset ricepod techno)가 **전부** fov 를 생략한다. fov 를 명시하는 4개는
        // 전부 2D 이고 값이 **전건 정확히 50.0** 이다. 즉 WE 에디터 기본값 50 이 정본이며,
        // `SceneCameraObject.fov = 50`(코퍼스 실측)과도 같은 값이다.
        let fov = float(general["fov"]) ?? 50
        // fov/nearz/farz 기본값은 씬 생성자 실측이다 — `scene+0x140`=50.0(`0x140186d5c`),
        // `scene+0x14c`=0.1(`0x140186d7d`), `scene+0x150`=10000.0(`0x140186d88`).
        //
        // **[2026-08-21 정정] nearz 기본은 0.01 이 아니라 0.1 이다**(비트패턴 `0x3dcccccd`).
        // 종전 0.01 은 깊이 버퍼 정밀도를 10배 낭비했다. 이 값이 실제로 쓰이는 건 **3D 원근 씬뿐**이다
        // — 정사영 씬의 z 클립은 `Composite::buildProjection` 이 ±2000 을 직접 싣고 `nearz`/`farz` 를
        // 읽지 않는다(`0x140183df9`·`0x140183e01`). 동봉 172씬 중 3D 는 2건이고 그중 nearz 를 생략하는
        // particleeditor3dscale **1건**이 이 변경의 영향 씬이다(modeleditor 는 0.1 을 명시 저작).
        let camera = SceneCamera3D(eye: eye, center: center, up: up, fov: fov,
                                   nearZ: float(general["nearz"]) ?? 0.1,
                                   farZ: float(general["farz"]) ?? 10000)
        var scripts: [String: String] = [:]
        // 카메라 프로퍼티 스크립트 캡처(per-frame 재평가용).
        for (key, src) in [("eye", camDict["eye"]), ("center", camDict["center"]), ("up", camDict["up"])] {
            if let d = src as? [String: Any], let sc = d["script"] as? String { scripts[key] = sc }
        }
        if let d = general["fov"] as? [String: Any], let sc = d["script"] as? String { scripts["fov"] = sc }
        return (camera, scripts)
    }

    /// 사운드 오브젝트("sound" 배열 또는 단수 경로 문자열) → SceneSound. 빈 경로면 nil(호출부는 sound 키 존재 시 항상 continue).
    private static func parseSound(_ obj: [String: Any]) -> SceneSound? {
        // 단수 문자열("path to audio entry" — scene-json-schema.md:141)은 1개짜리 사운드로 관용 파스.
        let paths = (obj["sound"] as? [Any])?.compactMap { $0 as? String }
            ?? ((obj["sound"] as? String).map { [$0] } ?? [])
        guard !paths.isEmpty else { return nil }
        // multi(플레이리스트)/startsilent(트리거 대기)는 의미 확정·재생기 반영(2026-07-09) — "unhandled" 로그 제거.
        var snd = SceneSound(
            id: intVal(obj["id"]) ?? 0,
            name: (obj["name"] as? String) ?? "",
            sounds: paths,
            volume: float(obj["volume"]) ?? 1,   // float() 가 숫자/{value} 바인딩 공통 언랩
            // F434: volume 과 동일하게 {user,value} 바인딩 언랩 경유 — 평문 캐스트만이면 바인딩
            // 형태가 기본값(single/false = 자동재생)으로 오판된다.
            playbackMode: (unwrap(obj["playbackmode"]) as? String) ?? "single",
            startSilent: (unwrap(obj["startsilent"]) as? Bool) ?? false,
            minTime: float(obj["mintime"]) ?? 0,
            maxTime: float(obj["maxtime"]) ?? 0)
        // 이펙트 상수(:1323)·레이어(:731-739)와 동일 비대칭 수정: float() 의 {value} 언랩이 형제 script 를
        // 삼키므로 스크립트는 별도로 먼저 캡처(정적 volume 은 위에서 이미 언랩됨).
        if let bind = obj["volume"] as? [String: Any], let sc = bind["script"] as? String {
            snd.volumeScript = sc
            if let j = Self.scriptPropsJSON(bind["scriptproperties"]) { snd.volumeScriptProps = j }
        }
        // 공간화 키(json-keys.txt:935/933/928 — 실측 3737268876 등 32오브젝트) — 파스만(필드 주석 참조).
        snd.spatialization = (unwrap(obj["spatialization"]) as? Bool) ?? false
        snd.attenuation = float(obj["attenuation"]) ?? 1
        snd.minDistance = float(obj["mindistance"]) ?? 1
        return snd
    }

    /// `sprite` 씬 오브젝트("sprite" 키가 **문자열**) → SceneSprite. 문자열이 아니면 nil 이고
    /// 호출부는 다음 콘텐츠 키로 진행한다 — WE 팩토리의 타입 게이트
    /// `cmp byte [rax+8], 4`(`0x1401902fe`) → `jne 0x140190332`(`0x140190302`) 와 같은 규약이다
    /// (jsoncpp `stringValue` = 4). 실측에서 이 게이트가 실제로 일하는 자리는 설치본 arsenal 의
    /// `"sprite": null` 2건이고, 거기서 오브젝트는 이 분기를 건너 `light` 로 간다(WE 도 동일).
    ///
    /// **빈 문자열은 거르지 않는다.** WE ctor 도 거르지 않고(`0x1402565c1` 의 null-포인터 분기는
    /// 걸러내기가 아니라 빈 경로를 그대로 로더에 넘기는 경로다) 여기서 거르면 `"sprite": ""` 짜리
    /// 오브젝트가 parseNode(콘텐츠 키로 인정)도 이 분기도 못 타 **통째로 사라진다**.
    /// 그 조용한 드롭을 막는 것이 parseNode 가 애초에 `"sprite"` 를 콘텐츠로 잡아 둔 이유다.
    /// (코퍼스 도달 0건 — 방어적 규약.)
    private static func parseSprite(_ obj: [String: Any], order: Int,
                                    initialVisible: Bool, visibleScript: String?) -> SceneSprite? {
        guard let material = contentValue(obj["sprite"]) as? String else { return nil }
        var sprite = SceneSprite(
            id: intVal(obj["id"]) ?? 0,
            name: (obj["name"] as? String) ?? "",
            material: material,
            origin: vec3(obj["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
            angles: vec3(obj["angles"]) ?? Vec3(x: 0, y: 0, z: 0),
            scale: vec3(obj["scale"]) ?? Vec3(x: 1, y: 1, z: 1),
            parent: intVal(obj["parent"]),
            visible: initialVisible,
            order: order)
        // F200 과 동형(레이어 :1311 · 파티클 :2245) — 미지정 시 1(균일 시차).
        sprite.parallaxDepth = vec2(obj["parallaxDepth"]) ?? Vec2(x: 1, y: 1)
        var ps = transformScripts(obj)
        if let vs = visibleScript { ps["visible"] = vs }
        sprite.propertyScripts = ps
        return sprite
    }

    /// 트랜스폼-온리 그룹 노드: 콘텐츠 키 없음 + id 보유 시 SceneNode3D(비가시도 포함 — 서브트리 판정에 필요).
    /// 콘텐츠 키가 있거나 id 없으면 nil(호출부가 레이어/컨텐츠 분기로 진행).
    /// camera 의사-오브젝트와 이펙트 캐리어 quad(shape+effects)도 콘텐츠로 취급 — 종전에는 여기서
    /// 트랜스폼-노드로 흡수돼 갓레이 41오브젝트(23씬)·카메라 fov/zoom(37씬)이 통째 드롭됐다.
    private static func parseNode(_ obj: [String: Any], initialVisible: Bool, visibleScript: String?) -> SceneNode3D? {
        // G-D2-1: `sprite` 도 **콘텐츠 키**다. WE 오브젝트 팩토리가 `sprite`(문자열)에 0x270 바이트
        // 전용 클래스를 생성하고(`mov ecx, 0x270` `0x140190304` → ctor `0x14019031b`) 그 ctor 가
        // `materials/util/occlusiontest.json` 을 로드한다(= 하드웨어 오클루전으로 가림을 판정하는
        // 태양/렌즈플레어 스프라이트 — `0x1402566bf`). 여기서 제외하지 않으면 트랜스폼-온리 그룹
        // 노드로 **조용히 흡수**돼 "노드는 있는데 아무것도 안 그려진다" 가 된다 — 갓레이 41오브젝트가
        // 같은 방식으로 드롭됐던 것과 동형 사고다.
        // **[2026-08-21 갱신]** 이제 파스 자체가 붙었다(`parseSprite` → `SceneDocument.sprites`).
        // 렌더는 여전히 미배선이다(도달 근거는 SceneSprite 주석) — 이 목록은 그대로 두면 된다.
        // 여기 판정은 `contentValue != nil`(존재)이고 parseSprite 는 `as? String`(타입)이라 서로 다른데,
        // 그건 WE 도 같다 — 팩토리가 `find`(존재, `0x1401902de`)로 분기에 들어와 `cmp …, 4`(타입,
        // `0x1401902fe`)로 다시 거른다. 두 판정이 **실제로 갈리는** 경우는 값이 문자열도 null 도 아닐
        // 때뿐이다: contentValue 는 NSNull 만 정규화하므로 null 은 양쪽 모두에서 "없음"이고
        // (설치본 arsenal 2건이 이 경로로 `light` 분기에 도달한다), 문자열은 양쪽 모두 "있음"이다.
        // 남는 것은 숫자/불리언/배열 같은 값인데 코퍼스 도달 0건이고, 그때 Waple 은 오브젝트를 통째로
        // 버린다(콘텐츠로 잡혀 노드가 못 되고, 어느 분기도 안 맞는다). WE 는 폴백 클래스 0x2c0
        // (`0x1401907e0`)으로 평범한 트랜스폼 오브젝트를 만든다. image/model/particle 도 똑같이 어긋나
        // 있으므로(같은 목록, 같은 규약) sprite 만 따로 맞추지 않는다 — 고칠 거면 목록째 고칠 자리다.
        guard !["image", "model", "particle", "text", "light", "camera", "sprite"].contains(where: { contentValue(obj[$0]) != nil }),
              !isEffectQuad(obj),
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
        node.attachment = obj["attachment"] as? String   // M(⑤): 파스만(SceneNode3D.attachment 주석 참조)
        return node
    }

    /// 이펙트 캐리어 quad: shape 보유 + effects 비어있지 않음(실측 41/41 이 effects 보유 — 전건
    /// lightshafts). effects 없는 shape(코퍼스 0건)는 종전 트랜스폼-노드 경로 유지(무회귀).
    private static func isEffectQuad(_ obj: [String: Any]) -> Bool {
        contentValue(obj["shape"]) != nil && !((obj["effects"] as? [Any])?.isEmpty ?? true)
    }

    /// shape:"quad" 이펙트 캐리어 → 솔리드 풀스크린 이펙트 레이어 승격(갓레이/라이트샤프트 — 육안 차이
    /// 최대급 갭). 렌더러의 기존 솔리드(무텍스처 흰 1×1 + tint)·효과 체인 경로를 그대로 재사용한다.
    /// isFrameBuffer 로 만들면 렌더러가 효과 체인을 스킵(encodeDrawPlan 규약)하므로 반드시 솔리드.
    /// 풀스크린 고정 승격이므로 저작 트랜스폼(origin/scale/angles)·parent 는 버린다 — parent 를 남기면
    /// composeParentTransforms 가 풀스크린 지오메트리를 재배치한다(실측: 쿼드에 붙는 자식 0건, 전건 2D 씬).
    /// **정정(2026-08-17)**: "parent 를 버린다" 가 지오메트리에 대해서는 맞지만 **가시성까지 버린 것은
    /// 결함이었다.** 쿼드는 저작 parent 가 꺼져 있어도 계속 그려졌다 — 실물 3299228616 의 lightshafts
    /// 쿼드 6개가 각각 언어 변형 이미지(LonelyCAT ENG/VIE/RUS/CN/Spa/Fren)에 매달려 있는데 부모 중
    /// visible 로 해소되는 것은 ENG 하나뿐이라, 6중으로 겹친 홍채색 덩어리가 화면 중앙을 덮었다
    /// (mul 전치 수정 `d258b56` 으로 광선이 실제로 켜지기 전까지는 fx≡0 이 이 결함을 가리고 있었다).
    /// 그래서 parent 를 **visibilityParent** 로만 싣는다(지오메트리 합성 4곳은 그대로 미참조).
    /// 코퍼스 도달: 이펙트 캐리어 quad 41개 중 parent 보유 16개, 그중 비가시 조상 아래 5개 / 1씬.
    ///
    /// **정정(2026-08-17, 2차) — 풀스크린 승격 자체를 걷어낸다.** 위 두 문단의 *근거* 는 당시로선
    /// 맞았다: WE 의 shape 쿼드 기본 크기를 몰랐으니 크기를 프로젝션으로 때우는 것 외에 방법이 없었고,
    /// 그 상태에서 parent 만 살리면 "크기는 풀스크린인데 위치는 부모 좌표" 라는 더 나쁜 조합이 됐다.
    /// 뒤집는 것은 *결론* 이다 — 기본 크기가 바이트로 확정됐다(spec/engine/shape-quad.json):
    ///   ① 렌더러블 기반 클래스의 리플렉션 테이블(fn 0x1401ee520)이 프로퍼티 이름 `"size"` 를
    ///      멤버 오프셋 **0x2F0** 에 직접 묶는다(같은 표: color→0x330, alpha→0x33C, brightness→0x340).
    ///   ② shape 클래스의 vfunc+0x40(0x14025fac0)이 그 0x2F0 에 `(float)(int)ortho.height` 를
    ///      movsd 로 **두 성분 다** 쓴다 → 저작 `size` 키가 없을 때의 기본값 = (orthoH, orthoH) 정사각.
    ///   ③ 드로우 준비(fn 0x1401ebf60)가 `size × 0.5` 로 월드행렬 0·1행(x·y 기저)을 스케일한다 →
    ///      쿼드는 origin 중심 **±size/2**. 이미지 레이어도 같은 기반 클래스라(vtable 슬롯
    ///      +0x30/+0x38/+0x58/+0x70/+0x80/+0x88 동일 포인터) 풀스크린 이미지가 size 3840×2160 으로
    ///      정확히 화면을 덮는다는 사실이 로컬 코너 ±1 규약을 되짚어 준다.
    /// 크기를 알게 됐으므로 origin/scale/angles/parent 를 버릴 이유가 사라졌다. 코퍼스 shape 41개 중
    /// `size` 키 보유 0개 — 전건이 이 기본값으로 간다. 최종 크기는 `size × scale`(scale 은 트랜스폼
    /// 노드 쪽 필드라 월드행렬에 먼저 들어가고 그 위에 size/2 가 곱해진다 — ③ 의 순서 그대로다).
    /// `visibilityParent` 는 이 변경으로 `parent` 에 흡수돼 필드째 사라졌다(그 필드 주석의 예고대로).
    /// 이펙트 체인 RT 는 여전히 레이어 크기다(SceneRendererResources: 솔리드는 effW/H = layer.size) —
    /// 즉 비-풀스크린 쿼드도 레이어-로컬 0..1 UV 를 받는다. WE 의 레이어별 RT 규약과 같은 축이다.
    private static func effectQuadLayer(_ obj: [String: Any], order: Int, pw: Int, ph: Int,
                                        visibleScript: String?, visibleScriptProps: String?,
                                        initialVisible: Bool,
                                        userProps: [String: Any] = [:]) -> SceneLayer {
        // WE shape 기본 크기: (orthoHeight, orthoHeight) 정사각 — width 가 아니다(§shape.initWritesOrthoHeightPair
        // 의 sourceIntOffset 0x88 = ctx 의 int 로 자른 ortho.height, 0x84 가 width).
        //
        // **기본값이지 고정값이 아니다.** `size` 는 리플렉션 표가 오프셋 0x2F0 에 이름으로 묶어 둔
        // 저작 가능 프로퍼티다(§shape.sizeIsProperty0x2F0) — vfunc+0x40 이 그 슬롯에 정사각을 써 두는
        // 것은 저작 키가 없을 때의 초기값일 뿐이고, 저작되면 그 값이 이긴다. 처음 이식할 때 초기값만
        // 옮기고 저작 경로를 빼먹어서, `size:"1920 1080"` 을 쓴 DIRECTDRAW 회귀 테스트가 1080 정사각으로
        // 그려져 화면의 56% 만 덮었다(예측 0.5625 vs 실측 0.5647). 이중 곱 회귀처럼 보였지만 기하 문제다.
        // 코퍼스 도달은 0건이다(shape 오브젝트 전수에 size 키 없음) — 그래서 실사용 픽셀은 안 변한다.
        let side = Float(ph)
        let authored = vec2(obj["size"])
        let angles = floats(obj["angles"])
        var layer = SceneLayer(
            textureEntryName: "",
            origin: vec2(obj["origin"]) ?? Vec2(x: 0, y: 0),
            size: authored ?? Vec2(x: side, y: side),
            scale: vec2(obj["scale"]) ?? Vec2(x: 1, y: 1),
            angleZ: angles.count >= 3 ? angles[2] : 0,   // parseLayer 와 동일: 이미 라디안
            alpha: float(obj["alpha"]) ?? 1,
            color: vec3(obj["color"]) ?? Vec3(x: 1, y: 1, z: 1),
            brightness: float(obj["brightness"]) ?? 1,
            parallaxDepth: vec2(obj["parallaxDepth"]) ?? Vec2(x: 1, y: 1),
            effects: parseEffects(obj["effects"], userProps: userProps),
            order: order)
        layer.name = (obj["name"] as? String) ?? ""
        layer.id = intVal(obj["id"]) ?? 0
        layer.parent = intVal(obj["parent"])
        layer.initialVisible = initialVisible
        // 저작 트랜스폼을 살렸으니 그 바인딩도 함께 산다 — 버려 두면 정적 값만 맞고 애니는 멈춘다
        // (parseLayer 의 동일 루프. 이펙트 캐리어는 텍스처가 없으니 material 계열은 해당 없음).
        for key in ["origin", "scale", "alpha", "angles", "color"] {
            guard let bind = obj[key] as? [String: Any], let sc = bind["script"] as? String else { continue }
            layer.propertyScripts[key] = sc
            if let j = Self.scriptPropsJSON(bind["scriptproperties"]) { layer.propertyScriptProps[key] = j }
        }
        if let vs = visibleScript { layer.propertyScripts["visible"] = vs }
        if let vp = visibleScriptProps { layer.propertyScriptProps["visible"] = vp }
        return layer
    }

    /// camera 의사-오브젝트 → SceneCameraObject. fov/zoom 은 float() 언랩({user,value}/{animation,value}),
    /// zoom 키프레임 애니와 origin/zoom 스크립트는 렌더러 소비용으로 별도 보존.
    private static func parseCameraObject(_ obj: [String: Any]) -> SceneCameraObject {
        var cam = SceneCameraObject()
        cam.id = intVal(obj["id"]) ?? 0
        cam.name = (obj["name"] as? String) ?? ""
        cam.fov = float(obj["fov"]) ?? 50
        cam.zoom = float(obj["zoom"]) ?? 1
        cam.origin = vec3(obj["origin"]) ?? Vec3(x: 0, y: 0, z: 0)
        // angles/parent/visible 키 존재는 종전 전무했다 — 카메라 오브젝트의 방향과 계층이 파스에서
        // 통째로 소실돼 있었다는 뜻이다. angles 는 라디안(scene.json 규약 — 스크립트 경계의 도(度)
        // 변환과 무관하다). 필드 주석에 다중 카메라 실측 결론이 있다.
        cam.angles = vec3(obj["angles"]) ?? Vec3(x: 0, y: 0, z: 0)
        cam.parent = intVal(obj["parent"])
        cam.hasVisibleBinding = contentValue(obj["visible"]) != nil
        if let bind = obj["zoom"] as? [String: Any], let a = PropertyAnimation.parse(bind) {
            cam.zoomAnimation = a
        }
        if let bind = obj["origin"] as? [String: Any], let a = PropertyAnimation.parse(bind) {
            cam.originAnimation = a
        }
        // fov 는 바로 위에서 정적 파스(:913)만 하고 스크립트는 origin/zoom 과 달리 누락돼 있었다(실측
        // 9씬 — 슬라이더 연동 줌 애니 정지). 세 키 동일 규약으로 통일.
        for key in ["origin", "zoom", "fov"] {
            if let bind = obj[key] as? [String: Any], let sc = bind["script"] as? String { cam.scripts[key] = sc }
        }
        cam.path = obj["path"] as? String
        cam.queueMode = (obj["queuemode"] as? String) ?? "random"
        cam.disablePropagation = (unwrap(obj["disablepropagation"]) as? Bool) ?? false
        cam.lockTransforms = (unwrap(obj["locktransforms"]) as? Bool) ?? false
        cam.isSolid = (unwrap(obj["solid"]) as? Bool) ?? false
        return cam
    }

    /// 텍스트 레이어("text": 평문 문자열 | {"value": 초기값, "script": JS} 바인딩 — 둘 다 보유 가능).
    /// script 는 update(current) 로 갱신되므로 value 는 초기 표시값으로도 쓰인다(실물 29씬/136오브젝트).
    /// visibleScript/visibleScriptProps/initialVisible 은 호출부(578행 게이트)가 이미 계산한 값을
    /// parseLayer/parseModel/effectQuadLayer 와 동형으로 전달(F219 — 종전엔 이 세 인자 자체가 없었다).
    private static func parseText(_ obj: [String: Any], order: Int,
                                  visibleScript: String?, visibleScriptProps: String? = nil,
                                  initialVisible: Bool,
                                  userProps: [String: Any] = [:]) -> SceneTextLayer {
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
        var t = SceneTextLayer(
            name: (obj["name"] as? String) ?? "",
            parent: intVal(obj["parent"]),
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
        t.id = intVal(obj["id"]) ?? 0
        // W3-⑤(b): 정적 angleZ — 레이어(:1163 인근) 와 동일하게 angles 배열의 z 성분(라디안, 이미 변환됨).
        // 스크립트 바인딩({"script":...})이어도 floats()→unwrap 이 "value" 스냅샷을 돌려주므로 초기값으로 안전.
        let textAngles = floats(obj["angles"])
        t.angleZ = textAngles.count >= 3 ? textAngles[2] : 0
        // W-①: 3D 씬 텍스트 빌보드용 origin.z(월드) — SceneLayer.originZ(:1221 인근)와 동일 파스 규약.
        let originFull = floats(obj["origin"])
        t.originZ = originFull.count >= 3 ? originFull[2] : 0
        // "Limit width/rows" 체크(불리언 리터럴 — 코퍼스 1640건 전수)가 켜진 때만 유효값. maxwidth 는
        // 바인딩 dict({user/script,value} — 실물 32건)가 있어 float() 의 {value} 언랩 경유, 폴백은
        // 에디터 기본(maxwidth 500 — 1468건 / maxrows 1 — 1628건). 부재/미체크 nil = 무제한(무회귀).
        // 체크 플래그도 unwrap 경유 — 코퍼스 전수 평문 Bool 이라 무회귀지만, 값(maxwidth/maxrows)만
        // 바인딩을 읽고 게이트는 못 읽는 비대칭을 없앤다(이 파일의 hdr/bloom/cameraparallax 와 동형).
        if (unwrap(obj["limitwidth"]) as? Bool) == true, case let mw = float(obj["maxwidth"]) ?? 500, mw > 0 { t.maxWidth = mw }
        if (unwrap(obj["limitrows"]) as? Bool) == true, case let mr = intVal(obj["maxrows"]) ?? 1, mr > 0 { t.maxRows = mr }
        t.overflowEllipsis = (obj["limituseellipsis"] as? Bool) ?? false
        t.justify = (obj["blockalign"] as? Bool) ?? false
        // 프로퍼티 스크립트(origin/scale/alpha/color/angles, F218): parseLayer(:731-739)와 동형 캡처 —
        // 렌더러가 재래스터 없이 인코드 시점 트랜스폼/알파 적용(buildTexts/encodeText 참조). visible(F219)
        // 은 위 578행 게이트에서 이미 판정된 값을 그대로 기록.
        t.initialVisible = initialVisible
        var propScripts: [String: String] = [:]
        var propScriptProps: [String: String] = [:]
        for key in ["origin", "scale", "alpha", "angles", "color"] {
            if let bind = obj[key] as? [String: Any], let sc = bind["script"] as? String {
                propScripts[key] = sc
                if let j = Self.scriptPropsJSON(bind["scriptproperties"]) { propScriptProps[key] = j }
            }
        }
        if let vs = visibleScript { propScripts["visible"] = vs }
        if let j = visibleScriptProps { propScriptProps["visible"] = j }
        t.propertyScripts = propScripts
        t.propertyScriptProps = propScriptProps
        // F693: 텍스트 이펙트 체인 파스·보존(레이어/3D 와 동일 parseEffects 경로 — 렌더 적용은 별도 그룹).
        t.effects = parseEffects(obj["effects"], userProps: userProps)
        // M7: object-level render flags.
        t.disablePropagation = (unwrap(obj["disablepropagation"]) as? Bool) ?? false
        t.copyBackground = (unwrap(obj["copybackground"]) as? Bool) ?? true
        t.clampUVs = (unwrap(obj["clampuvs"]) as? Bool) ?? true   // WE ctor 0x8040 bit15 — 선언부 주석 참조
        t.noInterpolation = (unwrap(obj["nointerpolation"]) as? Bool) ?? false
        t.spacing = float(obj["spacing"])
        t.lockTransforms = (unwrap(obj["locktransforms"]) as? Bool) ?? false
        t.isSolid = (unwrap(obj["solid"]) as? Bool) ?? false
        // 텍스트 오브젝트 depthtest(scene-json-schema.md:123) — 실측 문자열 "enabled"(1394건)이 정본,
        // 불리언 형태도 관용. 기본 true(항등). 파스·보존 전용(SceneTextLayer.depthTest 주석 참조).
        if let s = obj["depthtest"] as? String { t.depthTest = s != "disabled" }
        else if let b = unwrap(obj["depthtest"]) as? Bool { t.depthTest = b }
        // C⑥: colorBlendMode — 이미지 레이어(:1157 인근)와 동일 파스 규약.
        t.colorBlendMode = blendModeVal(obj["colorBlendMode"])
        // C⑨: 아웃라인/배경 박스 파스·보존(실측 스키마: outlinecolor/backgroundcolor 는 "r g b" 벡터).
        t.outline = (unwrap(obj["outline"]) as? Bool) ?? false
        t.outlineColor = vec3(obj["outlinecolor"]) ?? Vec3(x: 0, y: 0, z: 0)
        t.outlineThickness = float(obj["outlinethickness"]) ?? 0
        t.opaqueBackground = (unwrap(obj["opaquebackground"]) as? Bool) ?? false
        t.backgroundColor = vec3(obj["backgroundcolor"]) ?? Vec3(x: 0, y: 0, z: 0)
        // F4-polish①: anchor/padding/backgroundbrightness — 파스·보존만(SceneTextLayer 필드 주석 참조).
        t.anchor = (obj["anchor"] as? String) ?? "none"
        t.padding = uniformVec2(obj["padding"]) ?? Vec2(x: 0, y: 0)
        t.backgroundBrightness = float(obj["backgroundbrightness"]) ?? 1
        return t
    }

    /// 3D 메시 오브젝트("model": `.mdl` 직접 참조 — 2D image→json→puppet 인다이렉션 우회). angles 는 라디안.
    private static func parseModel(_ obj: [String: Any], modelPath: String, order: Int,
                                   visibleScript: String?, userProps: [String: Any] = [:]) -> SceneObject3D {
        var o = SceneObject3D(
            id: intVal(obj["id"]) ?? 0,
            name: (obj["name"] as? String) ?? "",
            model: modelPath,
            origin: vec3(obj["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
            angles: vec3(obj["angles"]) ?? Vec3(x: 0, y: 0, z: 0),
            scale: vec3(obj["scale"]) ?? Vec3(x: 1, y: 1, z: 1),
            // G-D2-10: **모델 오브젝트의 기본값은 true 다.** WE 오브젝트 팩토리의 `model` 분기가
            // 생성 직후 `or WORD PTR [rdi+0x120], 0x800` 으로 castshadow 비트를 켠다(비트 11 =
            // castshadow 는 액세서 썽크 `bts ecx, 0xB` 로 확정). `image`/`particle`/`shape`/`light`
            // ctor 는 이 비트를 켜지 않으므로 **모델에만** 적용한다(아래 parseLight 는 false 유지).
            // 도달이 결정적이다: WE 2.8.42 설치본 씬 전수에서 non-null `model` 오브젝트 **30개가
            // 하나도 빠짐없이 `castshadow` 키를 생략한다** — 즉 종전 `?? false` 는 WE 자체 3D
            // 배경의 그림자를 100% 없애고 있었다(접지감 소실 = 육안 차이 최대급).
            // {user,value} 바인딩도 읽는다(종전 평문 Bool 만 — 바인딩은 전부 false 로 접혔다).
            castShadow: (unwrap(obj["castshadow"]) as? Bool) ?? true,
            parent: intVal(obj["parent"]),
            effects: parseEffects(obj["effects"], userProps: userProps),
            order: order)
        var ps = transformScripts(obj)
        if let vs = visibleScript { ps["visible"] = vs }
        o.propertyScripts = ps
        o.animation = parseAnimationLayers(obj["animationlayers"])
        o.animationLayers = parseAllAnimationLayers(obj["animationlayers"])
        // F696: 명시 렌더 의존 id 목록(레이어 경로와 동형 — 소비는 렌더러 책임).
        o.dependencies = (obj["dependencies"] as? [Any])?.compactMap { intVal($0) } ?? []
        o.attachment = obj["attachment"] as? String   // M(⑤): 파스만(SceneObject3D.attachment 주석 참조)
        for key in ["origin", "angles", "scale", "alpha", "color"] {
            if let bind = obj[key] as? [String: Any], let a = PropertyAnimation.parse(bind), !a.events.isEmpty {
                o.eventTimelines.append(a)
            }
        }
        return o
    }

    /// 3D 라이트 오브젝트("light": 타입 문자열 + 위치/색/반경/강도 등).
    private static func parseLight(_ obj: [String: Any], lightType: String, order: Int) -> SceneLight3D {
        // F750(S-47): CSM 캐스케이드 경계 + 볼류메트릭 샤프트 필드 파스·보존(렌더 소비는 후속 — 필드 주석 참조).
        // 실물은 3키 동반만 존재(스캔 11건) — 방어적으로 부분 저작은 결측 컴포넌트 0 으로 채운다.
        let cd0 = float(obj["cascadedistance0"]), cd1 = float(obj["cascadedistance1"]), cd2 = float(obj["cascadedistance2"])
        let cascades: Vec3? = (cd0 != nil || cd1 != nil || cd2 != nil) ? Vec3(x: cd0 ?? 0, y: cd1 ?? 0, z: cd2 ?? 0) : nil
        var light = SceneLight3D(
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
            castShadow: (unwrap(obj["castshadow"]) as? Bool) ?? false,   // {user,value} 바인딩도 읽는다(종전 평문 Bool 만 — 바인딩은 전부 false 로 접혔다)
            parent: intVal(obj["parent"]),
            order: order,
            cascadeDistances: cascades,
            castVolumetrics: (unwrap(obj["castvolumetrics"]) as? Bool) ?? false,   // castshadow 와 동일 사유
            volumetricsExponent: float(obj["volumetricsexponent"]) ?? 1,
            density: float(obj["density"]) ?? 2,
            // ltube 세그먼트 단점 B(WE g_LTube_OriginB — 키는 wallpaper64.exe 스트링 실측 소문자).
            originB: vec3(obj["originb"]))
        // SceneObject3D/SceneNode3D 의 propertyScripts/transformScripts 와 동형 캡처(파스만 — TODO 위 참조).
        for key in ["color", "intensity", "radius", "origin", "angles"] {
            if let bind = obj[key] as? [String: Any], let sc = bind["script"] as? String { light.propertyScripts[key] = sc }
        }
        return light
    }

    /// W3-①(C8): 2D 가시성 상속 전파 — 파스 말미에 비가시(정적 false, 스크립트 없음) 조상 집합을 만들고,
    /// 자기 visibleScript 가 없는 자식 레이어/텍스트/파티클을 initialVisible=false 로 마킹한다(**드롭
    /// 아님** — JS thisScene.layers 인덱스 정합 보존, F219 와 동일 원칙).
    /// (스크립트를 **가진** 자식은 initialVisible 이 아니라 hiddenByAncestor 로 간다 — 아래 "해소" 참조.) "정적 false 부모"뿐 아니라
    /// user-조건 바인딩이 스냅샷 false 로 해소된 부모도 포함된다(실물 3299228616: 'Clock Layer 2' 그룹
    /// 은 clocklocation 콤보가 선택 안 된 값이라 resolveUserBindings 이후 평문 false 로 굳고,
    /// 그 자식 'number.am.pm' 은 **다른** 콤보(clock24hformat)에 바인딩돼 있어 자기 자신은 true 로
    /// 풀리지만 부모가 꺼져 있으면 같이 숨어야 한다 — WE 규약, 종전엔 부모 체인을 전혀 안 봐서 계속 그려짐).
    /// 비가시 **조상 집합**(invisible)은 nodes3D 만으로 충분하다: 정적 비가시 콘텐츠 오브젝트(레이어/
    /// 텍스트/파티클)도 id 가 있으면 파스 루프가 이미 invNode(SceneNode3D, visible=false)로 보존한다
    /// (V06, :845 부근) — 진짜 그룹 노드든 비가시로 드롭된 콘텐츠든 nodes3D 에 동일하게 나타난다.
    /// 반면 **부모 체인**(parentOf)은 nodes3D 만으로 부족하다 — 조상 탐색이 거쳐 가는 중간 마디는
    /// 가시 오브젝트일 수 있고 그건 nodes3D 에 없다. 그래서 레이어·텍스트·파티클의 parent 를 전부
    /// 등록한다(아래 세 줄). 두 집합의 역할이 다르다는 것이 이 함수의 요점이다.
    /// 레이어의 부모는 `parent` 하나로 읽는다 — 종전 `parent ?? visibilityParent` 는 이펙트 캐리어
    /// quad 가 풀스크린 승격 때문에 `parent` 를 비우던 시절의 이중 경로였고, 승격을 걷어내면서
    /// visibilityParent 가 `parent` 로 흡수돼 사라졌다(effectQuadLayer 의 2차 정정 주석).
    /// imageLayerCompositeIDs 카브아웃(:845 와 동형) — composelayer 합성 소스로 참조되는 레이어는
    /// 부모가 꺼져 있어도 숨기지 않는다(오프스크린 합성용이라 자기 자신의 화면 표시 여부와 무관).
    /// 3D 는 이미 Scene3DMath.worldMatrix 가 조상 AND 로 처리하므로 손대지 않는다(camera3D!=nil 스킵).
    /// 잔여 갭(의도적 무변경): 정적 false 부모 + **스크립트** 자식 조합의 런타임(초-프레임) 재평가는
    /// 후속 — 여기는 파스-타임 정적 스냅샷만 다룬다.
    /// **해소(2026-08-17)**: 위 보류의 *근거* 는 지금도 맞다 — `initialVisible` 은 시드일 뿐이라
    /// 스크립트가 있는 자식에게 그것만 놓으면 `evaluateBool(current:) ?? cur`(프레임 인코더)가
    /// 반환값으로 덮어써 조상 AND 가 사라진다. 그래서 **파스-타임 마킹을 스크립트 자식에게 확대하는
    /// 것은 여전히 틀린 수단**이고 그 판단은 뒤집지 않는다. 뒤집는 것은 *결론* 이다: 조상 집합은
    /// 정의상 "정적 false + visible 스크립트 없음" 뿐이라 그 조상은 이 마운트 동안 절대 켜지지 않고,
    /// 따라서 자식은 자기 스크립트가 무엇을 반환하든 그려지면 안 된다(WE 계층 AND). 시드가 아니라
    /// 하드 게이트가 맞는 수단이며 그것이 `hiddenByAncestor` 다 — 렌더러가 **스크립트를 다 평가한 뒤**
    /// 드로우만 스킵하므로 F219 가 살려 둔 컨트롤러 사이드이펙트(실물 3394601417 'bt')도 그대로 돈다.
    /// 코퍼스 도달(2D 씬, 자기 visible 스크립트 보유 + 비가시 조상): **116오브젝트 / 17씬**
    /// (이미지 92·텍스트 24, 그중 `update()` 보유 86 = 종전 규약에서 스크립트가 되켜던 것들).
    /// 진짜 잔여 갭은 이제 하나다: **조상 자신이 visible 스크립트를 가진 경우**(런타임 조상 평가)는
    /// 여전히 미구현 — invisible 집합이 그런 조상을 애초에 담지 않는다.
    /// 라이브 유저 프로퍼티 토글은 이 마킹을 "고정"시키지 않는다: LibraryViewModel.setProperty →
    /// reapplyIfCurrent → onApply → SceneRenderer.mount 가 매번 SceneDocument.parse 를 새 userProps
    /// 스냅샷으로 재실행하므로(remount = 전체 재파스), 부모 콤보가 켜지면 이 함수도 다음 파스에서
    /// 그 조상을 invisible 집합에서 뺀다 — "정적 마킹이라 옵션을 켜도 자식이 계속 숨는다"는 우려는
    /// 해당 없음(검증: reapplyIfCurrent 는 remount 를 거치지 않는 in-place 패치 경로가 없다).
    /// WAPLE_VIS_INHERIT=0 이면 이 패스 전체를 건너뛴다(진단/코퍼스 블라스트 반경 측정용 — 기본은 항상 켜짐).
    private static func applyVisibilityInheritance(layers: inout [SceneLayer], texts: inout [SceneTextLayer],
                                                    particles: inout [SceneParticle], nodes3D: [SceneNode3D],
                                                    camera3D: SceneCamera3D?, imageLayerCompositeIDs: Set<Int>) {
        guard ProcessInfo.processInfo.environment["WAPLE_VIS_INHERIT"] != "0" else { return }
        guard camera3D == nil, !nodes3D.isEmpty else { return }
        var parentOf: [Int: Int] = [:]
        var invisible: Set<Int> = []
        for n in nodes3D {
            if let p = n.parent { parentOf[n.id] = p }
            if !n.visible && n.propertyScripts["visible"] == nil { invisible.insert(n.id) }
        }
        guard !invisible.isEmpty else { return }
        for l in layers where l.id != 0 { if let p = l.parent { parentOf[l.id] = p } }
        for t in texts where t.id != 0 { if let p = t.parent { parentOf[t.id] = p } }
        // 파티클도 부모 체인의 중간 마디가 된다 — 종전엔 이 한 줄이 없어서 parentOf 에 파티클 id 가
        // 아예 안 들어갔고, 부모가 **가시** 파티클인 자식은 hasInvisibleAncestor 가 parentOf[부모] 를
        // 못 찾아 그 자리에서 false 로 끝났다(비가시 파티클은 :934 의 invNode 로 nodes3D 에 이미 있어
        // 우연히 동작했다 — 그래서 갭이 "가시 파티클을 경유하는 체인"에만 숨어 있었다).
        // 실물 3299228616: `543 Moving Stars_02 → 540 Blinking Stars_01(파티클, visible true)
        // → 239 LonelyCAT VIE(language 콤보 조건 false)` — 540 은 정상 은닉되는데 543 은 계속 그려졌다
        // (파티클을 거치는 체인 30오브젝트/1씬).
        for p in particles where p.id != 0 { if let pp = p.parent { parentOf[p.id] = pp } }
        func hasInvisibleAncestor(_ id: Int?, depth: Int = 0) -> Bool {
            guard let id, depth < 32 else { return false }
            if invisible.contains(id) { return true }
            return hasInvisibleAncestor(parentOf[id], depth: depth + 1)
        }
        for i in layers.indices {
            guard !imageLayerCompositeIDs.contains(layers[i].id),
                  hasInvisibleAncestor(layers[i].parent) else { continue }
            layers[i].hiddenByAncestor = true
            if layers[i].propertyScripts["visible"] == nil { layers[i].initialVisible = false }
        }
        for i in texts.indices {
            guard hasInvisibleAncestor(texts[i].parent) else { continue }
            texts[i].hiddenByAncestor = true
            if texts[i].propertyScripts["visible"] == nil { texts[i].initialVisible = false }
        }
        for i in particles.indices {
            guard hasInvisibleAncestor(particles[i].parent) else { continue }
            particles[i].hiddenByAncestor = true
            if particles[i].visibleScript == nil { particles[i].visible = false }
        }
    }

    /// 레이어 parent 체인 합성: 부모(트랜스폼 그룹 노드/레이어)의 origin/scale/angle 을 이어붙여
    /// 로컬(부모 상대)좌표를 월드(프로젝션 픽셀)로 굽는다 — 예: Hollow Knight 3598808038 의 knight/sword 는
    /// 부모 "PUPPET"(origin 1920,1080/scale 0.72)에 붙고, 3577990983 의 '背景'(origin 부재)은
    /// 그룹 노드(1920,1080)에 붙는다(미합성 시 (0,0) → 흑화면). 부모는 정적 가정.
    /// 퍼펫 파스 실패(폴백 쿼드) 레이어만 종전 위치 유지(luma 가드). **2D 한정**: 3D 씬(camera3D)의
    /// 이미지 레이어는 빌보드 — 렌더러(encodeBillboard)가 부모 월드행렬을 매 프레임 합성(파스-시 합성은 이중 적용 → 제외).
    private static func composeParentTransforms(layers: inout [SceneLayer], nodes3D: [SceneNode3D],
                                                texts: [SceneTextLayer],
                                                camera3D: SceneCamera3D?, package: ScenePackage,
                                                assets: ((String) -> Data?)?) {
        func puppetLoads(_ path: String) -> Bool {
            guard let d = package.data(for: path) ?? assets?(path) else { return false }
            return PuppetModel.parse(d) != nil || Model3D.parse(d) != nil
        }
        // E1: disablePropagation=true 인 레이어는 부모 트랜스폼 상속을 차단 — composeTargets 에서
        // 제외해 저작 로컬 좌표를 그대로 유지한다(코퍼스 실측 34건, 전부 parent 보유라 종전엔
        // 무조건 합성 대상이었다). 이 레이어가 다른 자식의 부모로 쓰일 때는 그 자식이 이 레이어의
        // "저작 로컬 값 = 유효 위치"를 상속받는다(noPropagate 가드 — world() 참조).
        let composeTargets = camera3D != nil ? [] : layers.indices.filter {
            guard layers[$0].parent != nil, !layers[$0].disablePropagation else { return false }
            if let pp = layers[$0].puppet { return puppetLoads(pp) }
            return true
        }
        guard !composeTargets.isEmpty else { return }
        var localT: [Int: (origin: Vec2, scale: Vec2, angle: Float)] = [:]
        var parentOf: [Int: Int] = [:]
        var noPropagate: Set<Int> = []
        for l in layers where l.id != 0 {
            localT[l.id] = (l.origin, l.scale, l.angleZ)
            if let p = l.parent { parentOf[l.id] = p }
            if l.disablePropagation { noPropagate.insert(l.id) }
        }
        for n in nodes3D {
            // F437: 레이어/노드 id 중복 시 레이어 우선 — 종전엔 노드가 레이어의 localT 항목을 덮어써
            // world(레이어id) 가 노드 트랜스폼을 반환했다(비정형 씬 한정).
            guard localT[n.id] == nil else { continue }
            localT[n.id] = (Vec2(x: n.origin.x, y: n.origin.y), Vec2(x: n.scale.x, y: n.scale.y), n.angles.z)
            if let p = n.parent { parentOf[n.id] = p }
        }
        // W3-⑤(a): "부모=텍스트" 케이스(3701356561 Solide H/V 등 이미지 자식) — composeTextParentTransforms
        // 가 이 함수보다 먼저 실행돼(:919) texts 는 이미 월드(또는 루트 로컬=월드) 값으로 확정돼 있다
        // (F057 해소로 angleZ 도 부모 누적 반영 완료). 그래서 parentOf 는 등록하지 않는다(등록하면 텍스트
        // 자신의 부모 체인이 여기서 다시 합성돼 이중 적용된다). 레이어/노드가 같은 id 를 이미 썼으면 그 쪽이 우선(F437 동형).
        for t in texts where t.id != 0 {
            guard localT[t.id] == nil else { continue }
            localT[t.id] = (t.origin, t.scale, t.angleZ)
        }
        // A1/E1: angle 은 scene.json angles 그대로(이미 라디안 — 코퍼스 전부 ≤π 확정, 인코더 규약과 동일).
        // 종전 `* .pi/180` 은 이미 라디안인 값을 도(°)로 오인해 부모 오프셋 회전을 57× 축소했다
        // (852473d 가 렌더 인코더 3곳만 고쳤고 이 합성부는 미동기 — SceneRendererFrameEncoder.swift:405 참조).
        func composed(_ pw: (origin: Vec2, scale: Vec2, angle: Float),
                      _ t: (origin: Vec2, scale: Vec2, angle: Float))
            -> (origin: Vec2, scale: Vec2, angle: Float) {
            let r = pw.angle
            let ca = cosf(r), sa = sinf(r)
            let sx = pw.scale.x * t.origin.x, sy = pw.scale.y * t.origin.y
            return (origin: Vec2(x: pw.origin.x + sx * ca - sy * sa, y: pw.origin.y + sx * sa + sy * ca),
                    scale: Vec2(x: pw.scale.x * t.scale.x, y: pw.scale.y * t.scale.y),
                    angle: pw.angle + t.angle)
        }
        func world(_ id: Int, _ depth: Int) -> (origin: Vec2, scale: Vec2, angle: Float)? {
            guard depth < 32, let t = localT[id] else { return nil }
            guard !noPropagate.contains(id) else { return t }  // E1: 전파 차단 — 조상 재귀 없이 로컬 그대로
            guard let pid = parentOf[id], let pw = world(pid, depth + 1) else { return t }
            return composed(pw, t)
        }
        for i in composeTargets {
            // F436: id 없는(0) 레이어도 parent 가 있으면 합성 — world() 는 localT 에 id 항목이 있어야
            // 해서 id==0 은 nil → 종전 미합성(로컬 좌표 그대로 렌더). 자신 로컬 × 부모 월드를 직접 합성.
            if layers[i].id == 0 {
                guard let pid = layers[i].parent, let pw = world(pid, 0) else { continue }
                let wt = composed(pw, (layers[i].origin, layers[i].scale, layers[i].angleZ))
                layers[i].origin = wt.origin
                layers[i].scale = wt.scale
                layers[i].angleZ = wt.angle
                continue
            }
            guard let wt = world(layers[i].id, 0) else { continue }
            layers[i].origin = wt.origin
            layers[i].scale = wt.scale
            layers[i].angleZ = wt.angle
        }
    }

    /// F691: 2D 씬 라이트의 parent 체인 합성 — 2D 포워드 유니폼(forwardUniforms)은 l.origin 을 그대로
    /// 팩하므로, 부모 붙은 라이트는 여기서 로컬→월드(프로젝션 픽셀)로 굽는다(실물 3351179520: lpoint
    /// origin (-44,300,735) + 부모 노드 (2560,720) → 기대 (2515,1020,735), 종전 로우값 그대로 렌더).
    /// 수식은 composeParentTransforms 의 2D 합성과 동일(origin/scale/angleZ) — x/y 만 회전·스케일 합성하고
    /// z 는 조상 origin.z 누산만(2D 부모는 z 스케일 개념 없음). 3D 씬(camera3D!=nil)은 렌더러
    /// resolveLights 가 월드행렬을 합성하므로 여기선 미적용(이중 합성 방지).
    private static func composeLightParentTransforms(lights: inout [SceneLight3D], layers: [SceneLayer],
                                                     nodes3D: [SceneNode3D], camera3D: SceneCamera3D?) {
        guard camera3D == nil, lights.contains(where: { $0.parent != nil }) else { return }
        var localT: [Int: (origin: Vec2, scale: Vec2, angle: Float, z: Float)] = [:]
        var parentOf: [Int: Int] = [:]
        for l in layers where l.id != 0 {
            localT[l.id] = (l.origin, l.scale, l.angleZ, l.originZ)
            if let p = l.parent { parentOf[l.id] = p }
        }
        for n in nodes3D {
            guard localT[n.id] == nil else { continue }  // 레이어 우선(composeParentTransforms F437 동일)
            localT[n.id] = (Vec2(x: n.origin.x, y: n.origin.y), Vec2(x: n.scale.x, y: n.scale.y), n.angles.z, n.origin.z)
            if let p = n.parent { parentOf[n.id] = p }
        }
        // A1/E1: angle 은 scene.json angles 그대로(이미 라디안) — composeParentTransforms 와 동기.
        func world(_ id: Int, _ depth: Int) -> (origin: Vec2, scale: Vec2, angle: Float, z: Float)? {
            guard depth < 32, let t = localT[id] else { return nil }
            guard let pid = parentOf[id], let pw = world(pid, depth + 1) else { return t }
            let r = pw.angle
            let ca = cosf(r), sa = sinf(r)
            let sx = pw.scale.x * t.origin.x, sy = pw.scale.y * t.origin.y
            return (origin: Vec2(x: pw.origin.x + sx * ca - sy * sa, y: pw.origin.y + sx * sa + sy * ca),
                    scale: Vec2(x: pw.scale.x * t.scale.x, y: pw.scale.y * t.scale.y),
                    angle: pw.angle + t.angle, z: pw.z + t.z)
        }
        for i in lights.indices {
            guard let pid = lights[i].parent, let pw = world(pid, 0) else { continue }
            let r = pw.angle
            let ca = cosf(r), sa = sinf(r)
            let sx = pw.scale.x * lights[i].origin.x, sy = pw.scale.y * lights[i].origin.y
            lights[i].origin = Vec3(x: pw.origin.x + sx * ca - sy * sa,
                                    y: pw.origin.y + sx * sa + sy * ca,
                                    z: pw.z + lights[i].origin.z)
            // ltube 단점 B 도 origin 과 같은 부모-로컬 공간 좌표라 동일 합성으로 월드화한다.
            if var b = lights[i].originB {
                let bx = pw.scale.x * b.x, by = pw.scale.y * b.y
                b = Vec3(x: pw.origin.x + bx * ca - by * sa,
                         y: pw.origin.y + bx * sa + by * ca,
                         z: pw.z + b.z)
                lights[i].originB = b
            }
        }
    }

    /// E1 공용: 레이어+노드(+W3-⑤ 텍스트)에서 부모 체인 로컬 트랜스폼 맵을 구성(레이어 우선, F437 규약 동일).
    /// composeParentTransforms/composeLightParentTransforms 는 검증된 원본 그대로 두고, 신규 소비처
    /// (텍스트/파티클)만 이 헬퍼를 공유한다. texts 는 이 함수 호출부(composeTextParentTransforms 등)가
    /// 스스로를 뮤테이트하기 **전** 스냅샷(값 타입 인자라 호출 시점 로컬값 고정)이라 이중 합성이 아니다 —
    /// 텍스트→텍스트 부모 체인(3516106265: id 790/798/804 parent=783)도 재귀로 정상 합성된다.
    private static func buildParentTransformMap(layers: [SceneLayer], nodes3D: [SceneNode3D], texts: [SceneTextLayer] = [])
        -> (localT: [Int: (origin: Vec2, scale: Vec2, angle: Float)], parentOf: [Int: Int], noPropagate: Set<Int>) {
        var localT: [Int: (origin: Vec2, scale: Vec2, angle: Float)] = [:]
        var parentOf: [Int: Int] = [:]
        var noPropagate: Set<Int> = []
        for l in layers where l.id != 0 {
            localT[l.id] = (l.origin, l.scale, l.angleZ)
            if let p = l.parent { parentOf[l.id] = p }
            if l.disablePropagation { noPropagate.insert(l.id) }
        }
        for n in nodes3D {
            guard localT[n.id] == nil else { continue }
            localT[n.id] = (Vec2(x: n.origin.x, y: n.origin.y), Vec2(x: n.scale.x, y: n.scale.y), n.angles.z)
            if let p = n.parent { parentOf[n.id] = p }
        }
        for t in texts where t.id != 0 {
            guard localT[t.id] == nil else { continue }
            localT[t.id] = (t.origin, t.scale, t.angleZ)
            if let p = t.parent { parentOf[t.id] = p }
            if t.disablePropagation { noPropagate.insert(t.id) }
        }
        return (localT, parentOf, noPropagate)
    }

    /// E1 공용: id 의 월드(부모 체인 합성) 트랜스폼. angle 은 scene.json angles 그대로(라디안).
    private static func worldParentTransform(_ id: Int, _ depth: Int,
                                             localT: [Int: (origin: Vec2, scale: Vec2, angle: Float)],
                                             parentOf: [Int: Int], noPropagate: Set<Int>)
        -> (origin: Vec2, scale: Vec2, angle: Float)? {
        guard depth < 32, let t = localT[id] else { return nil }
        guard !noPropagate.contains(id) else { return t }
        guard let pid = parentOf[id],
              let pw = worldParentTransform(pid, depth + 1, localT: localT, parentOf: parentOf, noPropagate: noPropagate)
        else { return t }
        let r = pw.angle
        let ca = cosf(r), sa = sinf(r)
        let sx = pw.scale.x * t.origin.x, sy = pw.scale.y * t.origin.y
        return (origin: Vec2(x: pw.origin.x + sx * ca - sy * sa, y: pw.origin.y + sx * sa + sy * ca),
                scale: Vec2(x: pw.scale.x * t.scale.x, y: pw.scale.y * t.scale.y),
                angle: pw.angle + t.angle)
    }

    /// E1: 2D 텍스트 오브젝트의 parent 체인 합성 — 레이어/라이트와 동일 규약(로컬→월드 픽셀). origin/scale
    /// 에 더해 F057: 부모 누적 각(pw.angle)을 자식 angleZ 에도 누산한다(이미지 레이어 합성 composed() 와
    /// 동일 의미론 — 텍스트→텍스트 체인 포함. 실물 3146703458 의 ~178° 텍스트, 3516106265 체인). 레이어
    /// 합성 전에 실행해야 한다(레이어가 월드로 덮어써지면 부모-레이어 로컬값이 유실 — F691 라이트와 동일
    /// 이유). W3-⑤: buildParentTransformMap 에 texts 스냅샷도 넘겨 텍스트→텍스트 부모 체인(3516106265:
    /// id 790/798/804 parent=783)과 "부모=텍스트" 인 이미지 자식(composeParentTransforms 쪽, 3701356561)
    /// 을 모두 지원한다.
    private static func composeTextParentTransforms(texts: inout [SceneTextLayer], layers: [SceneLayer],
                                                     nodes3D: [SceneNode3D], camera3D: SceneCamera3D?) {
        guard camera3D == nil,
              texts.contains(where: { $0.parent != nil && !$0.disablePropagation }) else { return }
        let (localT, parentOf, noPropagate) = buildParentTransformMap(layers: layers, nodes3D: nodes3D, texts: texts)
        for i in texts.indices {
            guard !texts[i].disablePropagation, let pid = texts[i].parent,
                  let pw = worldParentTransform(pid, 0, localT: localT, parentOf: parentOf, noPropagate: noPropagate)
            else { continue }
            let r = pw.angle
            let ca = cosf(r), sa = sinf(r)
            let sx = pw.scale.x * texts[i].origin.x, sy = pw.scale.y * texts[i].origin.y
            texts[i].origin = Vec2(x: pw.origin.x + sx * ca - sy * sa, y: pw.origin.y + sx * sa + sy * ca)
            texts[i].scale = Vec2(x: pw.scale.x * texts[i].scale.x, y: pw.scale.y * texts[i].scale.y)
            // F057: 부모 누적 각 상속 — 이미지 레이어 composed()(:1730)와 동일 의미론. pw.angle 은 조상 체인
            // 누적분(worldParentTransform)이라 자신의 로컬 각(angleZ 에 이미 있음)은 여기서 더하지 않는다.
            texts[i].angleZ += pw.angle
        }
    }

    /// E1: 2D 파티클 오브젝트의 parent 체인 합성 — origin/scale(Vec2, 2D 정사영 경로 전용) 만 굽는다.
    /// origin3D/scale3D/angles3D(3D 마운트 경로)는 SceneRenderer3D 가 별도로 parent3D 를 합성하므로 무관.
    /// W3-⑤: texts 는 의도적으로 미포함 — 이 함수는 composeTextParentTransforms **이후** 호출되므로
    /// (:925-927) buildParentTransformMap 에 texts 를 넘기면 이미 월드로 확정된 텍스트에 parentOf 가
    /// 등록돼 조상 체인이 재귀로 다시 합성(이중 적용)된다. "파티클이 텍스트에 붙는" 코퍼스 근거가 없어
    /// 카브아웃 대신 범위에서 제외(스코프 최소주의) — 실물 필요 시 composeTextParentTransforms 처럼
    /// 텍스트 스냅샷(뮤테이트 전)을 별도로 캡처해 전달해야 한다.
    private static func composeParticleParentTransforms(particles: inout [SceneParticle], layers: [SceneLayer],
                                                         nodes3D: [SceneNode3D], camera3D: SceneCamera3D?) {
        guard camera3D == nil,
              particles.contains(where: { $0.parent != nil && !$0.disablePropagation }) else { return }
        let (localT, parentOf, noPropagate) = buildParentTransformMap(layers: layers, nodes3D: nodes3D)
        for i in particles.indices {
            guard !particles[i].disablePropagation, let pid = particles[i].parent,
                  let pw = worldParentTransform(pid, 0, localT: localT, parentOf: parentOf, noPropagate: noPropagate)
            else { continue }
            let r = pw.angle
            let ca = cosf(r), sa = sinf(r)
            let sx = pw.scale.x * particles[i].origin.x, sy = pw.scale.y * particles[i].origin.y
            particles[i].origin = Vec2(x: pw.origin.x + sx * ca - sy * sa, y: pw.origin.y + sx * sa + sy * ca)
            particles[i].scale = Vec2(x: pw.scale.x * particles[i].scale.x, y: pw.scale.y * particles[i].scale.y)
        }
    }

    /// animationlayers → 활성 베이스 애니(숫자 blend≥0.5 & visible 중 blend 최대). 나머지(딕셔너리 blend =
    /// 스크립트/이벤트 제어, 시작≈0)는 무시 → 트리거 전 정지. 실물 젤다: "Idle"(blend 1.0)만 상시 재생.
    private static func parseAnimationLayers(_ raw: Any?) -> AnimationSelection? {
        guard let layers = raw as? [Any] else { return nil }
        var best: (name: String, rate: Float, blend: Float, clipId: Int?)? = nil
        for case let layer as [String: Any] in layers {
            // 바인딩 객체 {"value":false,...} 언랩 — parseAllAnimationLayers 와 동일 해석(숨긴 클립 오선택 방지)
            let visible = (layer["visible"] as? Bool)
                ?? ((layer["visible"] as? [String: Any])?["value"] as? Bool) ?? true
            guard visible else { continue }
            let blend = float(layer["blend"])  // 딕셔너리 blend(스크립트/애니 커브) = 이벤트 트리거 → 제외
            guard let bl = blend, bl >= 0.5 else { continue }
            if best == nil || bl > best!.blend {
                best = ((layer["name"] as? String) ?? "", float(layer["rate"]) ?? 1, bl, intVal(layer["animation"]))
            }
        }
        return best.map { AnimationSelection(name: $0.name, rate: $0.rate, clipId: $0.clipId) }
    }

    /// animationlayers → 전 레이어(다층 블렌드용, 순서 보존). visible/blend/rate 는 정적 초기값
    /// (키프레임은 float()/value 언랩 후 초기값만 — 런타임 키프레임 토글은 미반영). 스크립트 바인딩은
    /// scripts 로 캡처 → 렌더러가 per-frame 재평가(2D 퍼펫 캐스케이드 소비자).
    private static func parseAllAnimationLayers(_ raw: Any?) -> [AnimationLayer] {
        guard let layers = raw as? [Any] else { return [] }
        return layers.compactMap { any in
            guard let l = any as? [String: Any] else { return nil }
            let visible = (l["visible"] as? Bool)
                ?? ((l["visible"] as? [String: Any])?["value"] as? Bool) ?? true
            var al = AnimationLayer(name: (l["name"] as? String) ?? "",
                                    additive: (l["additive"] as? Bool) ?? false,
                                    // F435: 스크립트-only blend(바인딩 객체인데 정적 value 없음)의 기본은 0 — 형제
                                    // 선택 경로 parseAnimationLayers 가 같은 입력을 "시작≈0"으로 간주하는 것과
                                    // 대칭(엔진 생성 실패 시 풀블렌드 포즈 지속 방지). 키 부재는 종전대로 1.
                                    blend: float(l["blend"]) ?? (l["blend"] is [String: Any] ? 0 : 1),
                                    rate: float(l["rate"]) ?? 1,
                                    visible: visible,
                                    // C③: animationlayers[].animation(정수 클립 id) — 모델 파일 클립 id 와
                                    // 대조해 정확한 클립을 고른다(이름 휴리스틱 오선택 회피).
                                    clipId: intVal(l["animation"]))
            // blend/visible/rate 바인딩의 스크립트·이벤트 타임라인(실물: 젤다 blend 의 animationEvent 훅 +
            // options.events 마커, 3396722575 visible 의 훅, 2955378002/3448290956 rate 오디오 배속).
            for key in ["blend", "visible", "rate"] {
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
        userProps: [String: Any] = [:],
        instance: [String: Any]? = nil
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
              let model = AssetJSON.dictionary(modelData),
              let materialPath = model["material"] as? String,
              let materialData = requiredData(materialPath),
              let material = AssetJSON.dictionary(materialData),
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
        // P1 solid_instance: 레이어 obj 의 instance{textures,usertextures} 가 base material 슬롯을
        // 치환(실측 53씬/324오브젝트 — base 는 전건 util/white 라 미병합 시 실텍스처가 흰 솔리드로 소실).
        // usertextures 항목은 평문 문자열 키 또는 {name,type} 딕셔너리(usershortcut/system) — name 이
        // userProps 키. 설정된 유저 값이 instance.textures 보다 우선(위 material usertextures 와 동일 규약).
        // instance.combos 는 실측 전건 {"version":2} 로 파스 계층 소비처 없음 — 스킵.
        if let instance {
            for (slot, raw) in ((instance["textures"] as? [Any]) ?? []).enumerated() {
                guard let name = raw as? String, !name.isEmpty else { continue }
                while textures.count <= slot { textures.append(NSNull()) }
                textures[slot] = name
            }
            for (slot, raw) in ((instance["usertextures"] as? [Any]) ?? []).enumerated() {
                guard let userKey = (raw as? String) ?? ((raw as? [String: Any])?["name"] as? String),
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
                                      assets: ((String) -> Data?)?,
                                      initialVisible: Bool,
                                      userProps: [String: Any] = [:]) -> SceneParticle? {
        // instanceoverride(인스턴스 모디파이어): 프리셋 def 에 배수/CP 대체를 적용해 인스턴스별 다양화
        // (실측 127씬/866건). 종전 통째 드롭 — 재사용 프리셋 전 인스턴스가 동일 기본값으로 렌더됐다.
        let override = particleInstanceOverride(obj["instanceoverride"])
        guard let def = parseParticleDef(path, package: package, visited: [path],
                                         instanceOverride: override, assets: assets,
                                         userProps: userProps) else {
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
        p.id = intVal(obj["id"]) ?? 0   // 부모 체인 룩업 키(SceneParticle.id 주석 참조)
        p.parent = intVal(obj["parent"])
        p.visible = initialVisible
        p.attachment = obj["attachment"] as? String   // M(⑤): 파스만(SceneParticle.attachment 주석 참조)
        // F200: 레이어(parseLayer 의 parallaxDepth 언랩)와 동형 — 미지정 시 1(균일, 무회귀).
        p.parallaxDepth = vec2(obj["parallaxDepth"]) ?? Vec2(x: 1, y: 1)
        // F199: visible 스크립트 캡처(레이어 693-741행과 동일 언랩 규약). obj 는 이미 파라미터로
        // 보유하므로 obj["visible"] 을 직접 재-도출한다 — 호출부(메인 파스 루프)는 이미 initialVisible/
        // visibleScript 를 뽑아둔 상태지만 그 호출부는 배치 A 병행 구역이라 시그니처 변경으로 건드릴 수
        // 없다(접촉 금지). obj 는 동일 원본이므로 재-도출해도 호출부의 578행 게이트 판정과 항상 일치한다.
        if let vis = obj["visible"] as? [String: Any] {
            p.visibleScript = vis["script"] as? String
            if p.visibleScript != nil { p.visibleScriptProps = Self.scriptPropsJSON(vis["scriptproperties"]) }
        }
        // M7: object-level render flags.
        p.disablePropagation = (unwrap(obj["disablepropagation"]) as? Bool) ?? false
        p.copyBackground = (unwrap(obj["copybackground"]) as? Bool) ?? true
        p.clampUVs = (unwrap(obj["clampuvs"]) as? Bool) ?? true   // WE ctor 0x8040 bit15 — 선언부 주석 참조
        p.noInterpolation = (unwrap(obj["nointerpolation"]) as? Bool) ?? false
        p.lockTransforms = (unwrap(obj["locktransforms"]) as? Bool) ?? false
        p.isSolid = (unwrap(obj["solid"]) as? Bool) ?? false
        return p
    }

    /// instanceOverride 는 루트 def 에만 적용(자식 children 재귀에는 비전파 — 보수 규약).
    private static func parseParticleDef(_ path: String, package: ScenePackage,
                                         visited: Set<String>,
                                         instanceOverride: ParticleInstanceOverride? = nil,
                                         assets: ((String) -> Data?)? = nil,
                                         userProps: [String: Any] = [:]) -> ParticleSystemDef? {
        // F430: 이미지 레이어 requiredData 와 동일한 pkg→공유에셋 폴터 — 종전 pkg 한정이라
        // base-assets 에만 있는 파티클 json/머티리얼은 씬에서 통째 드롭됐다.
        func assetData(_ name: String) -> Data? { package.data(for: name) ?? assets?(name) }
        guard let pData = assetData(path),
              let pjson = AssetJSON.dictionary(pData) else {
            return nil
        }
        var material: ParticleMaterial? = nil
        if let matPath = pjson["material"] as? String, let mData = assetData(matPath),
           let mjson = AssetJSON.dictionary(mData) {
            material = ParticleMaterial.parse(mjson, userProps: userProps)
        }
        return ParticleSystemDef.parse(pjson, material: material, instanceOverride: instanceOverride) { childPath in
            guard !visited.contains(childPath), visited.count < 4 else {
                WapleLog.warn("[Waple] particle child cycle/depth cap, dropped: \(childPath)")
                return nil
            }
            return parseParticleDef(childPath, package: package, visited: visited.union([childPath]),
                                    assets: assets, userProps: userProps)
        }
    }

    /// scene object "instanceoverride" 블록 → 타입드 오버라이드. 실측 값 형태(코퍼스 127씬/866건):
    /// 숫자 | {user,value}/{animation,value} 바인딩(float()/vec3() 언랩) | "r g b" 문자열(colorn/
    /// controlpointN). 색 배수는 colorn(0..1) × brightness(스칼라) × color(0..255 → /255) 합성.
    /// id 는 인스턴스 식별자(미적용). 유효 필드 없으면 nil.
    ///
    /// `controlpointangleN` 은 **여전히 미구현**이지만, 종전 주석의 "실코퍼스 전건 0" 은 동봉 자산
    /// 기준으로 **거짓**이다(2026-08-20 재측정). 이 키를 가진 오브젝트 6건 중 **2건이 0 이 아니다**:
    ///   `presets/water/previewdrippingwater/scene.json`  angle1 "0 0 −0.52360" · angle2 "0 0 0.52360"
    ///   `presets/magic/previewvortexorb/scene.json`      angle1 "2.47837 −0.62832 0.02213"(애니 바인딩)
    /// 둘 다 `preview*` 씬이라 **non-preview 도달은 0** 이고, WE 는 이 키를 실제로 읽는다
    /// (문자열 `controlpointangle0..7` @0x140491490+, 프로퍼티 등록 `lea rdx` @0x14024e08e —
    /// 짝이 되는 `controlpoint0` 은 @0x14024dfb6). 그래서 "도달 0 이라 안 읽는다" 가 아니라
    /// "**preview 도달 2건, 미구현**" 이 정확한 상태다. Waple 의 CP 모델이 위치만 들고 회전을
    /// 들지 않으므로 착지하려면 CP 표현부터 넓혀야 한다 — 별건.
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

    private static func parseEffects(_ raw: Any?, userProps: [String: Any] = [:]) -> [SceneEffect] {
        guard let arr = raw as? [Any] else { return [] }
        var out: [SceneEffect] = []
        for case let e as [String: Any] in arr {
            // WE: visible=false 효과는 미적용(사용자 토글 OFF 포함 — {user,value} 는 resolveUserBindings 가
            // 이미 정적 value 로 해석). 종전 무시 → 꺼진 post-process(예 3489263099 halftone)가 적용돼 전화면 흑화.
            // visibleScript!=nil 이면 오브젝트 레벨 게이트(:565-570/578)와 동일하게 정적 false 라도 드롭하지
            // 않고 보존 — {script,value} 로 시작이 false 인 이펙트가 SceneEffect[] 에서 영구 제외되던 결함.
            var effInitialVisible = true
            var effVisibleScript: String? = nil
            var effVisibleScriptProps: String? = nil
            if let vb = e["visible"] as? Bool { effInitialVisible = vb }
            else if let vis = e["visible"] as? [String: Any] {
                if let v = vis["value"] as? Bool { effInitialVisible = v }
                effVisibleScript = vis["script"] as? String
                // X-⑥: 레이어/텍스트 visible 파스(:788-789)와 동형 — scriptproperties 미포집이면 스크립트가
                // scriptProperties.<name> 참조 시 항상 기본값으로 폴백(무동작 수정 방지).
                if effVisibleScript != nil { effVisibleScriptProps = Self.scriptPropsJSON(vis["scriptproperties"]) }
            }
            if !effInitialVisible && effVisibleScript == nil { continue }
            let file = (e["file"] as? String) ?? ""
            // "effects/<name>/effect.json" → name
            let parts = file.split(separator: "/")
            let name = parts.count >= 2 ? String(parts[parts.count - 2]) : file
            // 전체 패스 사용자 데이터 파스(멀티패스 effect.json passes[] 와 인덱스 정렬).
            var passList: [SceneEffectPass] = []
            // **자리를 보존한다.** `for case let passDict as [String: Any]` 는 객체가 아닌 원소를
            // 조용히 건너뛰어 뒤 패스를 한 칸씩 당긴다. 그런데 렌더러는 이 배열을 매니페스트의
            // **원본 인덱스**로 조회하므로(`sceneOverride(forRawPassIndex:)`), 한 칸이라도 밀리면
            // 상수·텍스처·콤보가 통째로 다른 패스에 붙는다. 원본(JsonCpp)은 위치 기반이라
            // null 원소도 자리를 지킨다.
            for element in (e["passes"] as? [Any] ?? []) {
                let passDict = (element as? [String: Any]) ?? [:]
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
                        // X-⑦: {animation:{...}} 키프레임 바인딩(55씬/287건) — 스크립트와 동일하게 value
                        // 언랩보다 먼저 캡처(동일 이유: 아래 float(v)/{value} 언랩이 dict 를 소비해도 무관하게
                        // 독립 필드에 보존). PropertyAnimation.parse 는 "animation" 키 부재 시 nil.
                        if let dict = v as? [String: Any], let anim = PropertyAnimation.parse(dict) {
                            p.constantAnimations[k] = anim
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
                // C⑦a: usershadervalues — {JSON 키=user property 키, JSON 값=셰이더 상수 토큰}(SceneDocument
                // 이미지 레이어 경로와 동일 방향 정정, 상세 근거는 그쪽 주석 참조). 파스 시점에 userProps
                // 룩업해 constantshadervalues 와 동일 슬롯에 병합(런타임 변경은 현재 아키텍처에서 정적 해석).
                if let usv = passDict["usershadervalues"] as? [String: Any] {
                    for (userKey, v) in usv {
                        guard let token = v as? String else { continue }
                        if let raw = userProps[userKey] {
                            if let f = float(raw) { p.constants[token] = [f] }
                            else if let s = raw as? String {
                                let f = floatList(s)
                                if !f.isEmpty { p.constants[token] = f }
                            }
                        }
                    }
                }
                // textures 배열 전체를 슬롯 순서로 캡처. JSON null → nil, 문자열 → 이름.
                if let texs = passDict["textures"] as? [Any] {
                    p.textureNames = texs.map { $0 as? String }
                }
                // F697: usertextures 슬롯 캡처(문자열 키 | {name,type} 딕셔너리 → name) — 레이어
                // 머티리얼 경로의 instance usertextures(:1270 인근)와 동일 정규화 규약.
                if let uts = passDict["usertextures"] as? [Any] {
                    p.userTextureNames = uts.map { ($0 as? String) ?? (($0 as? [String: Any])?["name"] as? String) }
                    // X-③: `$` 로 시작하지 않는(=시스템 키가 아닌) 유저 키는 레이어 material usertextures 와
                    // 동일하게 파스 시점에 userProps 값으로 해석해 textureNames 슬롯을 덮어쓴다(usertextures
                    // 가 textures 보다 우선 — :1637-1644 와 동형 규약). "$mediaThumbnail"/"$mediaPreviousThumbnail"
                    // 같은 시스템 키는 라이브 미디어 폴링이 필요한 동적 값이라 여기서 해석 불가 — userTextureNames
                    // 에 원문 키를 남겨 렌더러가 SceneRenderer.mediaArtworkTexture 로 별도 결속한다.
                    for (slot, key) in p.userTextureNames.enumerated() {
                        guard let key, !key.hasPrefix("$"),
                              let override = userProps[key] as? String,
                              !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        while p.textureNames.count <= slot { p.textureNames.append(nil) }
                        p.textureNames[slot] = override
                    }
                }
                passList.append(p)
            }
            let p0 = passList.first ?? SceneEffectPass()
            var eff = SceneEffect(name: name, constants: p0.constants, textureNames: p0.textureNames,
                                  combos: p0.combos, file: file)
            eff.passList = passList
            // X-⑪: `conditions` 의 좌변은 **이펙트 인스턴스 레벨 `combos`** 다 — 패스 레벨과 다른 것이다
            // (원본 `0x1401e7319` 가 `effects[i]["combos"]` 를 이펙트당 1회 읽어 세 평가 지점이 공유한다).
            // 동봉 씬 57개에서 이 키는 **0건**이고 combos 60건은 전부 패스 레벨이다. 그래서 실측상
            // 좌변은 항상 부재=0 이고, `fluidsimulation` 의 `LIGHTING==1`·`RENDERING==3` 은 전부 false 다.
            // 즉 충실한 구현은 유체의 조명/노멀 패스를 **끄는** 방향이다 — 그게 원본 동작이다.
            // 좌변 리더는 `lenientInt` 가 아니라 `EffectManifest.comboValue` 다 — 원본은 태그
            // 1/2/3 만 받고 `"1"`·`true` 는 0 으로 읽는다(그 함수의 주석 참조). 씬의 다른 정수
            // 필드에 쓰는 관대한 규약을 여기 그대로 쓰면 우리만 조건이 켜지는 자리가 생긴다.
            if let ic = e["combos"] as? [String: Any] {
                for (k, v) in ic { if let i = EffectManifest.comboValue(v) { eff.instanceCombos[k] = i } }
            }
            eff.initialVisible = effInitialVisible
            eff.visibleScript = effVisibleScript
            eff.visibleScriptProps = effVisibleScriptProps
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
    /// colorBlendMode 정규화 — `common_blending.h` 의 ApplyBlending enum 은 **0…32** 뿐이다.
    ///
    /// F530-sweep: 종전엔 파스 값을 그대로 실었고, 소비처인 `SceneRendererFrameEncoder`
    /// (`:1450` 이미지 · `:1629` 텍스트)가 `Int32(...)` 로 좁히면서 범위 밖 값에 **트랩**했다.
    /// `"colorBlendMode": 2147483648` 이나 문자열 `"99999999999"`(실물 씬이 숫자를 문자열로
    /// 싣는 사례는 `intVal` 주석 참조) 하나로 그 레이어가 처음 그려지는 프레임에 앱이 죽었다.
    ///
    /// 파스 지점에 거는 이유는 소비처가 둘이기 때문이다 — 한 자리에서 막으면 둘 다 덮인다.
    /// **클램프가 아니라 0 으로 떨어뜨린다**: 32 로 잘라 붙이면 저작 의도와 무관한 모드
    /// (Negative)가 조용히 적용된다. 미지정 기본값과 같은 normal 로 가는 게 맞다.
    private static func blendModeVal(_ v: Any?) -> Int {
        guard let n = intVal(v), (0...32).contains(n) else { return 0 }
        return n
    }
    private static func vec2(_ v: Any?) -> Vec2? {
        let f = floats(v); return f.count >= 2 ? Vec2(x: f[0], y: f[1]) : nil
    }
    /// F4-polish①: 스칼라(단일 숫자, `float()` 경유) 또는 "x y" 벡터 문자열(`vec2()` 경유) 둘 다 저작되는
    /// 필드(실측: text.padding — 정수/실수 스칼라 1459건 + "x y" 168건). 스칼라는 양축 동일값으로 확장.
    private static func uniformVec2(_ v: Any?) -> Vec2? {
        if let v2 = vec2(v) { return v2 }
        if let s = float(v) { return Vec2(x: s, y: s) }
        return nil
    }
    private static func vec3(_ v: Any?) -> Vec3? {
        let f = floats(v); return f.count >= 3 ? Vec3(x: f[0], y: f[1], z: f[2]) : nil
    }

    /// material.constantshadervalue 엔트리를 파싱: plain 값이면 (value, nil), {script,value} 이면 둘 다 반환.
    /// 스크립트가 있는 경우 scriptproperties 도 보존해 사용자 오버라이드를 주입할 수 있게 한다.
    private static func scriptedConstant(_ v: Any?) -> (value: Any?, script: String?, scriptProps: String?) {
        guard let dict = v as? [String: Any] else { return (unwrap(v), nil, nil) }
        if let script = dict["script"] as? String {
            let props = scriptPropsJSON(dict["scriptproperties"])
            return (unwrap(dict["value"]), script, props)
        }
        return (unwrap(dict["value"]), nil, nil)
    }

    // MARK: - parseLayer 머티리얼 패스 추출 헬퍼

    /// parseLayer 에서 머티리얼 패스(p0) 파싱 결과를 운반하는 내부 구조체.
    private struct MaterialPassResult {
        var blendMode: String = "normal"
        var depthTest: Bool = true
        var depthWrite: Bool = true
        var alphaWriting: String = "default"
        var spritesheetCombo: Bool = false
        var lightingCombo: Bool = false
        var roughness: Float = 0.7
        var metallic: Float = 0
        var specularTint: Vec3 = Vec3(x: 1, y: 1, z: 1)
        var materialScripts: [String: String] = [:]
        var materialScriptProps: [String: String] = [:]
        var materialShader: String? = nil
        var materialCombos: [String: Int] = [:]
        var materialConstants: [String: [Float]] = [:]
        var materialConstantScripts: [String: String] = [:]
        var materialConstantScriptProps: [String: String] = [:]
        var materialTextureNames: [String?] = []
        var materialUserShaderValues: [String: String] = [:]
        var refract: Bool = false
        var normalTextureName: String? = nil
        var refractAmount: Float = 0.05
    }

    /// 머티리얼 패스(passes[0]) 딕셔너리에서 렌더 속성·콤보·상수·텍스처를 추출하는 순수 계산.
    /// parseLayer 에서 분리 — 타입체커 식 깊이 분산 목적(기능 동치, 2026-07-31).
    private static func parseMaterialPassProperties(
        _ p0: [String: Any],
        userProps: [String: Any]
    ) -> MaterialPassResult {
        var result: MaterialPassResult = MaterialPassResult()
        if let bl = p0["blending"] as? String { result.blendMode = bl }
        result.depthTest = (p0["depthtest"] as? String) != "disabled"
        result.depthWrite = (p0["depthwrite"] as? String) != "disabled"
        if let aw = p0["alphawriting"] as? String { result.alphaWriting = aw }
        // SPRITESHEET 콤보(대/소문자 무시, 값 !=0) → 이 레이어는 .tex TEXS 프레임 시간축 재생.
        // LIGHTING 콤보(!=0) → 포워드 라이팅 대상(씬 라이트에 반응). 둘 다 대소문자 무시 매치.
        if let combos = p0["combos"] as? [String: Any] {
            result.spritesheetCombo = combos.contains { $0.key.lowercased() == "spritesheet" && (intVal($0.value) ?? 0) != 0 }
            result.lightingCombo = combos.contains { $0.key.lowercased() == "lighting" && (intVal($0.value) ?? 0) != 0 }
        }
        if let constants = p0["constantshadervalues"] as? [String: Any] {
            let r = scriptedConstant(constants["roughness"])
            if let f = lenientFloat(r.value) { result.roughness = f }
            if let script = r.script { result.materialScripts["roughness"] = script }
            if let props = r.scriptProps { result.materialScriptProps["roughness"] = props }
            let m = scriptedConstant(constants["metallic"])
            if let f = lenientFloat(m.value) { result.metallic = f }
            if let script = m.script { result.materialScripts["metallic"] = script }
            if let props = m.scriptProps { result.materialScriptProps["metallic"] = props }
            let s = scriptedConstant(constants["speculartint"])
            if let v = vec3(s.value) { result.specularTint = v }
            if let script = s.script { result.materialScripts["speculartint"] = script }
            if let props = s.scriptProps { result.materialScriptProps["speculartint"] = props }
        }
        // H1: 커스텀 머티리얼 셰이더/콤보/상수/텍스처 파스 보존.
        if let shader = p0["shader"] as? String { result.materialShader = shader }
        if let combos = p0["combos"] as? [String: Any] {
            for (k, v) in combos {
                if let i = intVal(v) { result.materialCombos[k] = i }
            }
        }
        if let csv = p0["constantshadervalues"] as? [String: Any] {
            for (k, v) in csv {
                if let dict = v as? [String: Any], let sc = dict["script"] as? String {
                    result.materialConstantScripts[k] = sc
                    if let sp = Self.scriptPropsJSON(dict["scriptproperties"]) { result.materialConstantScriptProps[k] = sp }
                }
                if let f = float(v) { result.materialConstants[k] = [f] }
                else if let s = v as? String {
                    let f = floatList(s)
                    if !f.isEmpty { result.materialConstants[k] = f }
                }
                else if let dict = v as? [String: Any] {
                    if let f = float(dict["value"]) { result.materialConstants[k] = [f] }
                    else if let sv = dict["value"] as? String {
                        let f = floatList(sv)
                        if !f.isEmpty { result.materialConstants[k] = f }
                    }
                }
            }
        }
        // C⑦a: usershadervalues — 실물 규약은 {JSON 키=user property 키, JSON 값=셰이더 상수/
        // 머티리얼 토큰 이름}(fantasticcar body.json usershadervalues:{"carbodycolor":"paintcolor"},
        // project.json 에 carbodycolor 만 유저프로퍼티로 등재 — car.frag 어노테이션 "material":
        // "paintcolor" 로 교차검증). 이전 구현은 방향이 반대(k=토큰,v=유저키)라 userProps 룩업이
        // 항상 미스했다. materialUserShaderValues 는 하류(:roughness/:metallic/:speculartint,
        // GLSLTranslator sceneKey)와의 계약대로 여전히 [토큰: userKey]로 채운다.
        // constantshadervalues 파스 후 적용해야 userProps 오버라이드가 기본값을 덮는다.
        if let usv = p0["usershadervalues"] as? [String: Any] {
            for (userKey, v) in usv {
                guard let token = v as? String else { continue }
                result.materialUserShaderValues[token] = userKey
                guard let raw = userProps[userKey] else { continue }
                if let f = float(raw) { result.materialConstants[token] = [f] }
                else if let s = raw as? String {
                    let f = floatList(s)
                    if !f.isEmpty { result.materialConstants[token] = f }
                }
            }
            // 기존 PBR 필드도 usershadervalues 반영(roughness/metallic/speculartint).
            if let key = result.materialUserShaderValues["roughness"], let raw = userProps[key],
               let f = float(raw) { result.roughness = f }
            if let key = result.materialUserShaderValues["metallic"], let raw = userProps[key],
               let f = float(raw) { result.metallic = f }
            if let key = result.materialUserShaderValues["speculartint"], let raw = userProps[key],
               let v = vec3(raw) { result.specularTint = v }
        }
        if let texs = p0["textures"] as? [Any] {
            result.materialTextureNames = texs.map { $0 as? String }
        }
        // H4: REFRACT 콤보 + 노멀맵(textures[1]) + refractAmount 파싱. 노멀맵 없으면 refract=false.
        // 콤보 값은 이 파일의 intVal(= unwrap + lenientInt)로 읽는다. 종전 `as? NSNumber`.intValue 는
        // 문자열 저작 `"REFRACT": "1"` 을 nil 로 떨어뜨려 **굴절을 끄는** 방향으로 조용히 틀렸고
        // ({user,value} 바인딩도 못 읽었다), 이 파일이 그 두 형태를 위해 준비해 둔 헬퍼를 우회했다.
        var refractComboRaw: Any? = nil
        if let combos = p0["combos"] as? [String: Any] { refractComboRaw = combos["REFRACT"] }
        let refractCombo: Bool = intVal(refractComboRaw) == 1
        let normalName: String? = result.materialTextureNames.count > 1 ? result.materialTextureNames[1] : nil
        var refractAmt: Float = float((p0["constantshadervalues"] as? [String: Any])?["ui_editor_properties_refract_amount"]) ?? 0.05
        // usershadervalues 오버라이드(H2 와 동일 규약).
        if let key = result.materialUserShaderValues["ui_editor_properties_refract_amount"],
           let raw = userProps[key], let f = float(raw) {
            refractAmt = f
        }
        result.refract = refractCombo && normalName != nil
        result.normalTextureName = normalName
        result.refractAmount = refractAmt
        return result
    }

    // MARK: - parse general 후처리 추출 헬퍼

    /// parse() 후반의 general 딕셔너리 기반 씬 글로벌 설정 적용(순수 할당, 흐름 제어 없음).
    /// 타입체커 식 깊이 분산 목적(기능 동치, 2026-07-31).
    private static func applyGeneralSettings(to out: inout SceneDocument, general: [String: Any], quality: Quality) {
        // camerashake 전역 지터(D 재감사 #16, 코퍼스 활성 13/168씬). {"user"/"value"} 바인딩(클린룸 15씬)
        // 대비 unwrap. 수식은 렌더러(코퍼스 값분포 근사) — 여기선 원시 파라미터만 보존.
        out.cameraShake = (unwrap(general["camerashake"]) as? Bool) ?? false
        out.cameraShakeAmplitude = float(general["camerashakeamplitude"]) ?? 0.5
        out.cameraShakeRoughness = float(general["camerashakeroughness"]) ?? 1
        out.cameraShakeSpeed = float(general["camerashakespeed"]) ?? 3
        // LDR uses the WE defaults; float/vec3 retain numeric-string and {value} unwrapping without clamps.
        out.bloomStrength = float(general["bloomstrength"]) ?? 2
        out.bloomThreshold = float(general["bloomthreshold"]) ?? 0.65
        out.bloomTint = vec3(general["bloomtint"]) ?? Vec3(x: 1, y: 1, z: 1)
        // HDR 판(#22): 기본값 = 클린룸 확정치(선언부 주석 참조). float/intVal 이 {"user":…,"value":…}
        // 바인딩(실코퍼스 3470948192 등)과 문자열 숫자를 공통 언랩한다.
        // strength 기본 2.0 은 씬 생성자 `0x1401870c2`(`scene+0x3c4` ← `0x40000000`) 실측이다 —
        // 종전 0 은 키를 생략한 HDR 씬의 블룸을 전멸시켰다(선언부 주석: 동봉 영향 0건).
        out.bloomHDRStrength = float(general["bloomhdrstrength"]) ?? 2
        out.bloomHDRThreshold = float(general["bloomhdrthreshold"]) ?? 1
        out.bloomHDRFeather = float(general["bloomhdrfeather"]) ?? 0.1
        out.bloomHDRIterations = intVal(general["bloomhdriterations"]) ?? 8
        out.bloomHDRScatter = float(general["bloomhdrscatter"]) ?? 1.619
        // F695/F692: 씬 전역 줌 + perspective 레이어 원근 FOV(파스·보존 — 소비는 렌더러 책임).
        out.zoom = float(general["zoom"]) ?? 1
        // 미저작 기본 95.0 = 씬 생성자 `0x140186d67`(`scene+0x144` ← `0x42be0000`).
        out.perspectiveOverrideFov = float(general["perspectiveoverridefov"]) ?? 95
        // clearenabled/camerafade(json-keys.txt:667/686) — clearenabled=false 는 acc 미클리어(잔상)라
        // 렌더러가 소비(SceneRenderer.clearEnabled). camerafade 는 의미 미확정이라 파스만(소비 보류).
        out.clearEnabled = (unwrap(general["clearenabled"]) as? Bool) ?? true
        out.cameraFade = (unwrap(general["camerafade"]) as? Bool) ?? true
        // wind/gravity(json-keys.txt:696-700) — 소비자 의미론 미확정, 파스·보존 전용(필드 주석 참조).
        // direction 실측 형태는 "x y z" vec3 문자열(코퍼스 109/161씬) — float()/vec3() 가 {value} 언랩 공통 처리.
        out.windEnabled = (unwrap(general["windenabled"]) as? Bool) ?? false
        out.windStrength = float(general["windstrength"]) ?? 1
        out.windDirection = vec3(general["winddirection"]) ?? Vec3(x: 0.707, y: 0.707, z: 0)
        out.gravityStrength = float(general["gravitystrength"]) ?? 1
        out.gravityDirection = vec3(general["gravitydirection"]) ?? Vec3(x: 0, y: -1, z: 0)
        // H7: 품질 설정(general.quality).
        out.quality = quality
    }
}
