import Foundation

/// scene.json 효과 항목의 패스별 사용자 데이터(effect.json passes[] 와 인덱스 정렬).
public struct SceneEffectPass: Equatable {
    public var constants: [String: [Float]] = [:]
    /// 상수에 걸린 프로퍼티 스크립트(키 → JS 소스) — 렌더러가 per-frame 평가(컬러 사이클 등).
    public var constantScripts: [String: String] = [:]
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
    public let origin: Vec2
    /// origin 의 3성분째(월드 z) — 2D 씬에선 무시(origin 은 씬 픽셀 xy). 3D 씬 빌보드가 월드 위치로 사용.
    public var originZ: Float = 0
    /// 부모 오브젝트 id(3D 씬 빌보드의 트랜스폼 계층 — 태양계 이미지는 대부분 그룹 노드에 붙는다). nil=루트.
    public var parent: Int? = nil
    public let size: Vec2
    public let scale: Vec2
    public let angleZ: Float
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
    /// 프로퍼티 스크립트(color/alpha/visible — 키 → JS 소스). per-frame 평가(실물: 미디어 썸네일 컬러
    /// 전환, 주야 컨트롤러). visible 스크립트가 있는 레이어는 파스에서 드롭하지 않는다.
    public var propertyScripts: [String: String] = [:]
    /// visible 의 정적 value(초기 표시). visible 스크립트가 있을 때만 false 로도 남는다 —
    /// 스크립트 없는 정적 false 는 파스에서 레이어 자체가 드롭된다.
    public var initialVisible: Bool = true
}

/// 씬 내 파티클 시스템 인스턴스. def(파티클 정의) + 씬 배치(origin/scale, 씬 픽셀 좌표).
public struct SceneParticle: Equatable {
    public let def: ParticleSystemDef
    public let origin: Vec2
    public let scale: Vec2
    /// scene.json objects[] 내 인덱스(레이어와 공유하는 z-순서).
    public var order: Int = 0
}

/// 텍스트 오브젝트(시계/날짜/곡정보 등). text 는 평문 또는 JS 프로퍼티 스크립트(script)로 계산.
public struct SceneTextLayer: Equatable {
    public let text: String              // 평문(스크립트면 "")
    public let script: String?           // {"script": ...} — update(value) 가 텍스트 반환
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
    public let castShadow: Bool
    public let parent: Int?
    public var order: Int = 0
    public init(id: Int, name: String, type: String, origin: Vec3, angles: Vec3, color: Vec3,
                radius: Float, intensity: Float, exponent: Float, castShadow: Bool, parent: Int?, order: Int = 0) {
        self.id = id; self.name = name; self.type = type
        self.origin = origin; self.angles = angles; self.color = color
        self.radius = radius; self.intensity = intensity; self.exponent = exponent
        self.castShadow = castShadow; self.parent = parent; self.order = order
    }
}

public struct SceneDocument: Equatable {
    public let projectionWidth: Int
    public let projectionHeight: Int
    public let clearColor: Vec3
    public let parallaxEnabled: Bool
    public let parallaxAmount: Float
    public let parallaxMouseInfluence: Float
    public let layers: [SceneLayer]
    public let particles: [SceneParticle]
    public var texts: [SceneTextLayer] = []
    /// 3D 씬 카메라 — orthogonalprojection 부재(null) + camera{eye,center,up} + fov 존재 시 세팅. 2D=nil.
    public var camera3D: SceneCamera3D? = nil
    /// 3D 메시 오브젝트(`.mdl` 직접 참조). 2D 씬에서는 빈 배열.
    public var objects3D: [SceneObject3D] = []
    /// 3D 라이트 오브젝트.
    public var lights3D: [SceneLight3D] = []
    /// 트랜스폼-온리 그룹 노드(parent 계층 합성용). 비가시(false) 노드도 기록 — 서브트리 판정에 필요.
    public var nodes3D: [SceneNode3D] = []
}

public enum SceneDocumentError: Error, Equatable { case noScene }

extension SceneDocument {
    /// - assets: 공유(base-assets) 리졸버 — pkg 에 없는 모델/머티리얼 JSON(models/util/solidlayer.json 등)의
    ///   폴백. WapleCore 는 순수하므로 파일 IO 는 호출자가 클로저로 주입한다(렌더러: BaseAssetsSettings 디렉터리).
    /// - userProps: 유저 속성 오버라이드(키 → 값). scene.json 의 `{"user": "키", "value": 기본}` 바인딩을
    ///   파스 전에 트리 전체에서 일괄 해석한다(visible/alpha/color/effect 상수 등 모든 바인딩 지점 공통).
    public static func parse(package: ScenePackage, assets: ((String) -> Data?)? = nil,
                             userProps: [String: Any] = [:]) throws -> SceneDocument {
        guard let sceneData = package.data(for: "scene.json") ?? package.data(for: "gifscene.json"),
              var scene = (try? JSONSerialization.jsonObject(with: sceneData)) as? [String: Any] else {
            throw SceneDocumentError.noScene
        }
        if !userProps.isEmpty {
            scene = (resolveUserBindings(scene, userProps: userProps, depth: 0) as? [String: Any]) ?? scene
        }
        let general = scene["general"] as? [String: Any] ?? [:]
        let proj = general["orthogonalprojection"] as? [String: Any] ?? [:]
        let pw = (proj["width"] as? Int) ?? 1920
        let ph = (proj["height"] as? Int) ?? 1080
        let clear = vec3(general["clearcolor"]) ?? Vec3(x: 0, y: 0, z: 0)
        let parallaxEnabled = (general["cameraparallax"] as? Bool) ?? false
        let parallaxAmount = float(general["cameraparallaxamount"]) ?? 1
        let parallaxMouseInfluence = float(general["cameraparallaxmouseinfluence"]) ?? 1

        // 3D 카메라: orthogonalprojection 이 딕셔너리가 아니고(3D 씬은 null) camera{eye,center,up}+fov 존재.
        // fov 는 float() 로 언랩 — 실물(젤다)은 {"script":...,"value":50} 스크립트 프로퍼티로 온다.
        var camera3D: SceneCamera3D? = nil
        if !(general["orthogonalprojection"] is [String: Any]),
           let camDict = scene["camera"] as? [String: Any],
           let eye = vec3(camDict["eye"]), let center = vec3(camDict["center"]),
           let up = vec3(camDict["up"]), let fov = float(general["fov"]) {
            camera3D = SceneCamera3D(eye: eye, center: center, up: up, fov: fov,
                                     nearZ: float(general["nearz"]) ?? 0.01,
                                     farZ: float(general["farz"]) ?? 10000)
        }

        var layers: [SceneLayer] = []
        var particles: [SceneParticle] = []
        var texts: [SceneTextLayer] = []
        var objects3D: [SceneObject3D] = []
        var lights3D: [SceneLight3D] = []
        var nodes3D: [SceneNode3D] = []
        for (order, any) in (scene["objects"] as? [Any] ?? []).enumerated() {
            guard let obj = any as? [String: Any] else { continue }
            // `visible` 은 평문 불리언 | 바인딩 객체 {"value":Bool, "script":JS} 두 형태. 스크립트가 있는
            // 이미지 레이어는 정적 false 여도 유지(런타임 토글 + 컨트롤러 top-level 사이드이펙트 —
            // 실물 3394601417 'bt') — 그 외 오브젝트는 정적 false 시 기존대로 드롭.
            var initialVisible = true
            var visibleScript: String? = nil
            if let b = obj["visible"] as? Bool { initialVisible = b }
            else if let vis = obj["visible"] as? [String: Any] {
                if let v = vis["value"] as? Bool { initialVisible = v }
                visibleScript = vis["script"] as? String
            }
            // 트랜스폼-온리 그룹(콘텐츠 키 없음 + id 보유): 계층 노드로 기록(비가시도 포함 — 서브트리
            // 가시성 판정에 필요)하고 다음으로. 종전에는 조용히 버려져 parent 참조가 끊겼다.
            if !["image", "model", "particle", "text", "light"].contains(where: { obj[$0] != nil }),
               let nodeID = intVal(obj["id"]) {
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
                nodes3D.append(node)
                continue
            }
            if !initialVisible && (visibleScript == nil || !(obj["image"] is String)) { continue }
            if let imagePath = obj["image"] as? String {
                guard let resolved = resolveLayerTexture(imagePath: imagePath, package: package, assets: assets) else {
                    continue  // 사유별 로그는 resolveLayerTexture 내부에서.
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
                for key in ["origin", "scale", "alpha", "angles", "color"] {
                    if let bind = obj[key] as? [String: Any], let a = PropertyAnimation.parse(bind) {
                        anims[key] = a
                    }
                    if let bind = obj[key] as? [String: Any], let sc = bind["script"] as? String {
                        propScripts[key] = sc  // 정적 value 는 기존 언랩이 처리 — 스크립트는 per-frame 재평가
                    }
                }
                if let vs = visibleScript { propScripts["visible"] = vs }
                // 퍼펫 모델: model json 의 "puppet" 키(스키닝 메시 — 렌더러가 .mdl 로드).
                var puppetPath: String? = nil
                if let md = package.data(for: imagePath) ?? assets?(imagePath),
                   let mj = (try? JSONSerialization.jsonObject(with: md)) as? [String: Any] {
                    puppetPath = mj["puppet"] as? String
                }
                layers.append(SceneLayer(
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
                ))
                layers[layers.count - 1].puppet = puppetPath
                layers[layers.count - 1].propertyScripts = propScripts
                layers[layers.count - 1].initialVisible = initialVisible
                // 3D 씬 빌보드용: origin 의 z 성분(월드)과 부모 계층 보존(2D 경로는 origin.xy 만 사용 — 무영향).
                let originFull = floats(obj["origin"])
                layers[layers.count - 1].originZ = originFull.count >= 3 ? originFull[2] : 0
                layers[layers.count - 1].parent = intVal(obj["parent"])
            } else if let particlePath = obj["particle"] as? String {
                if var p = parseParticle(particlePath, obj: obj, package: package) {
                    p.order = order
                    particles.append(p)
                }
            } else if obj["text"] != nil {
                // 텍스트: 평문 문자열 또는 {"script": JS} — 내용은 렌더러/스크립트 엔진이 채운다.
                var plain = ""
                var script: String? = nil
                if let s = obj["text"] as? String { plain = s }
                else if let d = obj["text"] as? [String: Any], let js = d["script"] as? String { script = js }
                texts.append(SceneTextLayer(
                    text: plain, script: script,
                    font: (obj["font"] as? String) ?? "systemfont_arial",
                    pointSize: float(obj["pointsize"]) ?? 16,
                    color: vec3(obj["color"]) ?? Vec3(x: 1, y: 1, z: 1),
                    alpha: float(obj["alpha"]) ?? 1,
                    horizontalAlign: (obj["horizontalalign"] as? String) ?? "center",
                    verticalAlign: (obj["verticalalign"] as? String) ?? "center",
                    origin: vec2(obj["origin"]) ?? Vec2(x: 0, y: 0),
                    scale: vec2(obj["scale"]) ?? Vec2(x: 1, y: 1),  // 배율은 scale 필드 — size 는 레이아웃 박스(오독 시 거대 글리프)
                    order: order))
            } else if let modelPath = obj["model"] as? String {
                // 3D 메시: `.mdl` 직접 참조(2D image→json→puppet 인다이렉션 우회). angles 는 라디안.
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
                objects3D.append(o)
            } else if let lightType = obj["light"] as? String {
                lights3D.append(SceneLight3D(
                    id: intVal(obj["id"]) ?? 0,
                    name: (obj["name"] as? String) ?? "",
                    type: lightType,
                    origin: vec3(obj["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
                    angles: vec3(obj["angles"]) ?? Vec3(x: 0, y: 0, z: 0),
                    color: vec3(obj["color"]) ?? Vec3(x: 1, y: 1, z: 1),
                    radius: float(obj["radius"]) ?? 0,
                    intensity: float(obj["intensity"]) ?? 1,
                    exponent: float(obj["exponent"]) ?? 1,
                    castShadow: (obj["castshadow"] as? Bool) ?? false,
                    parent: intVal(obj["parent"]),
                    order: order))
            }
        }
        return SceneDocument(projectionWidth: pw, projectionHeight: ph, clearColor: clear,
                             parallaxEnabled: parallaxEnabled, parallaxAmount: parallaxAmount,
                             parallaxMouseInfluence: parallaxMouseInfluence, layers: layers, particles: particles,
                             texts: texts, camera3D: camera3D, objects3D: objects3D, lights3D: lights3D,
                             nodes3D: nodes3D)
    }

    /// 레이어 소스 해석 결과.
    private enum LayerTexture {
        case entry(String)                    // 일반 텍스처 엔트리
        case solid                            // 무텍스처 머티리얼(flat) → 솔리드 필
        case frameBuffer(fullscreen: Bool)    // _rt_FullFrameBuffer → 컴포지션 레이어
    }

    /// image(model) → material → texture name → "materials/<name>.tex". nil = 해석 실패(드롭+로그).
    private static func resolveLayerTexture(imagePath: String, package: ScenePackage,
                                            assets: ((String) -> Data?)? = nil) -> LayerTexture? {
        func data(_ name: String) -> Data? { package.data(for: name) ?? assets?(name) }
        guard let modelData = data(imagePath),
              let model = (try? JSONSerialization.jsonObject(with: modelData)) as? [String: Any],
              let materialPath = model["material"] as? String,
              let materialData = data(materialPath),
              let material = (try? JSONSerialization.jsonObject(with: materialData)) as? [String: Any],
              let passes = material["passes"] as? [Any],
              let pass0 = passes.first as? [String: Any] else {
            NSLog("%@", "[Waple] image layer texture resolve failed: \(imagePath)")
            return nil
        }
        // 텍스처 배열은 빈 슬롯을 null 로 표기할 수 있으므로(예: [null, "real.tex"]),
        // 첫 항목이 아니라 첫 non-null·non-empty 문자열을 사용한다.
        let textures = pass0["textures"] as? [Any] ?? []
        guard let name = textures.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) else {
            // 무텍스처 머티리얼(예: util/solidlayer 의 shader "flat") → 솔리드 필.
            return .solid
        }
        if name.hasPrefix("_rt_") {
            // 프레임버퍼 참조(fullscreen/compose/project layer) → 컴포지션 레이어.
            let fullscreen = (model["fullscreen"] as? Bool) ?? (model["autosize"] as? Bool) ?? false
            return .frameBuffer(fullscreen: fullscreen)
        }
        // 머티리얼의 텍스처 이름은 materials/ 상대 + 무확장("util/white" → "materials/util/white.tex").
        // pkg 에 실제로 있는 후보를 우선하고, 없으면 관례 경로를 반환(렌더러가 base-assets 폴백 시도).
        let candidates = name.hasSuffix(".tex") ? [name] : ["materials/\(name).tex", name]
        for c in candidates where package.entries.contains(where: { $0.name == c }) { return .entry(c) }
        return .entry(candidates[0])
    }

    /// scene object 의 `particle` 경로 → particles/X.json + material → SceneParticle.
    /// origin/scale 은 씬 픽셀 좌표(첫 2성분). 로드/파싱 실패 → nil + 로그.
    private static func parseParticle(_ path: String, obj: [String: Any], package: ScenePackage) -> SceneParticle? {
        guard let pData = package.data(for: path),
              let pjson = (try? JSONSerialization.jsonObject(with: pData)) as? [String: Any] else {
            NSLog("%@", "[Waple] SP4 particle load failed: \(path)")
            return nil
        }
        var material: ParticleMaterial? = nil
        if let matPath = pjson["material"] as? String, let mData = package.data(for: matPath),
           let mjson = (try? JSONSerialization.jsonObject(with: mData)) as? [String: Any] {
            material = ParticleMaterial.parse(mjson)
        }
        let def = ParticleSystemDef.parse(pjson, material: material)
        return SceneParticle(def: def,
                             origin: vec2(obj["origin"]) ?? Vec2(x: 0, y: 0),
                             scale: vec2(obj["scale"]) ?? Vec2(x: 1, y: 1))
    }

    private static func parseEffects(_ raw: Any?) -> [SceneEffect] {
        guard let arr = raw as? [Any] else { return [] }
        var out: [SceneEffect] = []
        for case let e as [String: Any] in arr {
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
                        if let i = v as? Int { p.combos[k] = i }
                        else if let d = v as? Double { p.combos[k] = Int(d) }
                    }
                }
                if let cs = passDict["constantshadervalues"] as? [String: Any] {
                    for (k, v) in cs {
                        if let d = v as? Double { p.constants[k] = [Float(d)] }
                        else if let i = v as? Int { p.constants[k] = [Float(i)] }
                        else if let s = v as? String {
                            let f = s.split(separator: " ").compactMap { Float($0) }
                            if !f.isEmpty { p.constants[k] = f }
                        }
                        else if let dict = v as? [String: Any] {
                            // 바인딩 객체 {script/user/value} — 정적 value 언랩 + 스크립트 캡처(per-frame 평가용).
                            if let sc = dict["script"] as? String { p.constantScripts[k] = sc }
                            if let d = dict["value"] as? Double { p.constants[k] = [Float(d)] }
                            else if let i = dict["value"] as? Int { p.constants[k] = [Float(i)] }
                            else if let sv = dict["value"] as? String {
                                let f = sv.split(separator: " ").compactMap { Float($0) }
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

    /// `{"user": "키", ...}` 바인딩의 value 를 유저 오버라이드로 치환(재귀, 깊이 제한).
    private static func resolveUserBindings(_ node: Any, userProps: [String: Any], depth: Int) -> Any {
        guard depth < 32 else { return node }
        if var dict = node as? [String: Any] {
            if let user = dict["user"] as? String, let override = userProps[user] {
                dict["value"] = override
            }
            for (k, v) in dict { dict[k] = resolveUserBindings(v, userProps: userProps, depth: depth + 1) }
            return dict
        }
        if let arr = node as? [Any] {
            return arr.map { resolveUserBindings($0, userProps: userProps, depth: depth + 1) }
        }
        return node
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

    /// 바인딩 객체 {"animation":..., "value": X} → X(정적 값), 아니면 원값.
    /// 실물 씬은 origin/alpha 등 대부분의 프로퍼티에 이 형태를 쓴다(애니메이션 재생은 후속 기능).
    private static func unwrap(_ v: Any?) -> Any? {
        if let d = v as? [String: Any], let inner = d["value"] { return inner }
        return v
    }
    private static func floats(_ v: Any?) -> [Float] {
        ((unwrap(v) as? String) ?? "").split(separator: " ").compactMap { Float($0) }
    }
    private static func float(_ v: Any?) -> Float? {
        let u = unwrap(v)
        if let d = u as? Double { return Float(d) }
        if let i = u as? Int { return Float(i) }
        return nil
    }
    private static func intVal(_ v: Any?) -> Int? {
        let u = unwrap(v)
        if let i = u as? Int { return i }
        if let d = u as? Double { return Int(d) }
        return nil
    }
    private static func vec2(_ v: Any?) -> Vec2? {
        let f = floats(v); return f.count >= 2 ? Vec2(x: f[0], y: f[1]) : nil
    }
    private static func vec3(_ v: Any?) -> Vec3? {
        let f = floats(v); return f.count >= 3 ? Vec3(x: f[0], y: f[1], z: f[2]) : nil
    }
}
