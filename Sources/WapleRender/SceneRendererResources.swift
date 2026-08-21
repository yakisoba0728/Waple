import AppKit
import MetalKit
import simd
import WapleCore

// SceneRenderer 리소스 빌더(갓클래스 3분할 ①, 2026-07-04 — 코드 이동 + private→internal 만, 로직 무변경):
// mount 시 GPU 리소스화 경로 — 에셋 로드(pkg → base-assets 폴백), 레이어/효과(손-포팅·GLSL 번역)/
// 파티클/텍스트 빌드, 텍스처·파이프라인 팩토리. per-frame 인코딩은 SceneRendererFrameEncoder.swift,
// 3D 서브시스템은 SceneRenderer3D.swift 참조.
extension SceneRenderer {
    /// F4: `SceneRenderer.assetProbeCache` 의 값 타입이라 internal 이어야 한다(저장 프로퍼티는
    /// 확장에 둘 수 없어 선언이 SceneRenderer.swift 에 있다). 케이스·의미는 종전과 동일.
    enum BaseAssetURLProbe {
        case url(URL)
        case missing
        case rejected
    }

    struct AudioParams { let mode: Int; let freqMin: Float; let freqMax: Float; let bounds: SIMD2<Float>; let power: Float; let multiply: Float }
    /// 효과 바인딩: 손-포팅(기존 규약: float* P buffer(0) + aux texture(1+) + audioResp buffer(1))
    /// 또는 GLSL→MSL 변환본(reflection 규약: float4* p buffer(0) + EngineU buffer(1) + slot 텍스처 + audioL/R buffer(2/3)).
    /// 변환 효과의 1개 패스(멀티패스: effect.json passes[] — target=fbo 인덱스(nil=효과 출력),
    /// binds=(슬롯, 소스: -1=previous(효과 입력)|fbo 인덱스)).
    struct TranslatedPass {
        let pipeline: MTLRenderPipelineState
        let material: [SIMD4<Float>]
        let aux: [(slot: Int, tex: MTLTexture)]
        let binds: [(slot: Int, source: Int)]
        let target: Int?
        /// T09-D2: 매니페스트 `passes[].compose` — "이 패스의 출력이 **다음 패스의 `previous`** 가 된다"
        /// (= 이펙트 **내부** 핑퐁). 원본 파스 `0x1401e7d96–0x1401e7dcf`: 태그 5(boolean)만 수용하고
        /// (`0x1401e7dac`) 참이면 패스 플래그(pass+0x14)에 비트 0x2 를 세우며(`0x1401e7dc3`)
        /// 이펙트의 compose 개수(effect+0x140)를 하나 올린다(`0x1401e7dc7`).
        /// 소비처는 체인 루프 `0x1401e9b8f–0x1401e9bf0` — applyEffect 의 핑퐁 주석 참조.
        let compose: Bool
        let usesAudio: Bool
        let texRes: [SIMD4<Float>]
        /// 슬롯별(0..7, texRes 와 동일 상한) 샘플러 어드레싱(F162/F163): 1=clamp/0=repeat.
        /// bind(fbo/previous, 자산 없음) 슬롯은 항상 clamp, aux(실 자산) 슬롯은 TexImage.clampUVs —
        /// buildPassBindings 가 빌드 시 1 회 계산(런타임 재계산 불요 — 자산 정체성은 패스 고정).
        let texWrap: [Float]
        /// 감사 V07: 슬롯별 샘플 필터(1=nearest/0=linear — TexImage.noInterpolation, WE tex Flags bit0).
        /// bind 슬롯은 선형(단, 체인 첫 이펙트의 previous=베이스 직결은 baseNoInterp — 손-포팅 fbNearest
        /// 의 V06 정합과 동일), aux 슬롯은 자산 플래그. texWrap 과 동일하게 빌드 시 1 회 계산.
        let texFilter: [Float]
        /// 상수 프로퍼티 스크립트(슬롯 → 엔진) — per-frame 평가로 material 갱신(컬러 사이클 등).
        var scripts: [(slot: Int, engine: TextScriptEngine)] = []
        /// F-X4: `_rt_FullFrameBuffer` 어노테이션/텍스처명을 가진 aux 슬롯 — 빌드 시점엔 흰색 1×1 로
        /// 채워두고(무회귀 폴백), 씬 컬러 스냅샷을 확보한 호출부(runFrameBufferLayer 등)만 draw 시점에
        /// applyEffect(fullFrameSnapshot:) 로 실제 배경을 덮어 바인드한다(godrays/shine COPYBG).
        let fullFrameSlots: [Int]
        /// X-②: command:"swap"(셰이더 없음, 실물 fluidsimulation velocity/dye 더블버퍼) — non-nil 이면
        /// draw 를 건너뛰고 fboTex.swapAt(source,target) 만 수행(무비용 핑퐁). pipeline 은 미사용 placeholder.
        let swapPair: (source: Int, target: Int)?
        /// X-③: usertextures 의 시스템 키($mediaThumbnail/$mediaPreviousThumbnail) 슬롯 — fullFrameSlots
        /// 와 동일 패턴(빌드 시점 흰색 1×1 폴백, draw 시점에 SceneRenderer.mediaArtworkTexture/
        /// mediaPreviousArtworkTexture 로 덮어씀). previous=true 면 이전 프레임 아트워크.
        let mediaArtworkSlots: [(slot: Int, previous: Bool)]
        /// X-⑦: 상수 키프레임 애니메이션(슬롯 → PropertyAnimation) — per-frame value(atTime:) 로 material
        /// 갱신(스크립트와 동일 위치, 레이어 origin/scale/alpha 애니와 동일 평가기).
        var animations: [(slot: Int, anim: PropertyAnimation)] = []
    }
    /// X-①: 이름 있는 FBO 1개의 할당 스펙 — 세 갈래다.
    ///   ① `fit`(실물 cursorripple `fit:512`, fluidsimulation `fit:256`) — **정사각이 아니다**.
    ///      dst 를 알아야 풀리므로 `fittedBox(base…)` 로 프레임/빌드 시점에 계산한다(W-FIT).
    ///   ② `width`/`height`(실물 glitter 256×256) — 절대 픽셀.
    ///   ③ 둘 다 없으면 종전 `dst/scale`.
    /// X-⑧: `format`(픽셀 포맷) · `unique`(프레임 간 지속) · `clearColor`(생성 1회 초기화) 추가.
    struct FBOSpec {
        let scale: Int
        let declaredWidth: Int?
        let declaredHeight: Int?
        /// W-FIT: `fit:N` 봉투 한 변. **치수가 아니다** — `fittedBox(base…)` 로만 풀어라
        /// (규약 전문·VA 는 `EffectManifest.FBO.fittedBox` 주석).
        let fit: Int?
        /// 하위호환 표현(= `width`/`height` 선언, 없으면 `fit` 봉투). `fit != nil` 이면
        /// **정사각 봉투**라 실제 치수가 아니다.
        var fixedWidth: Int? { declaredWidth ?? fit }
        var fixedHeight: Int? { declaredHeight ?? fit }
        /// 이미 Metal 포맷으로 해석된 값 — `rgba_backbuffer` 의 HDR 분기는 빌드 시점에 끝난다
        /// (씬의 HDR 여부는 마운트 시 확정이고 프레임마다 바뀌지 않는다).
        let pixelFormat: MTLPixelFormat
        let unique: Bool
        let clearColor: SIMD4<Float>?
        init(scale: Int, declaredWidth: Int?, declaredHeight: Int?, fit: Int? = nil,
             pixelFormat: MTLPixelFormat = .rgba8Unorm, unique: Bool = false,
             clearColor: SIMD4<Float>? = nil) {
            self.scale = scale
            self.declaredWidth = declaredWidth; self.declaredHeight = declaredHeight; self.fit = fit
            self.pixelFormat = pixelFormat; self.unique = unique; self.clearColor = clearColor
        }

        /// W-FIT: `fit` 이 있으면 실제 치수, 없으면 `nil`(= 소비처가 종전 경로 유지).
        func fittedBox(baseWidth: Int, baseHeight: Int) -> (width: Int, height: Int)? {
            guard let fit = fit else { return nil }
            return EffectManifest.FBO.fittedBox(fit: fit, declaredWidth: declaredWidth,
                                                declaredHeight: declaredHeight, scale: scale,
                                                baseWidth: baseWidth, baseHeight: baseHeight)
        }
    }

    /// X-⑧(G-A5-05/G-B2-03): `unique:true` FBO 의 **프레임 간 지속 저장소**.
    ///
    /// 참조형인 이유는 `EffectVisibleGate` 와 같다 — `EffectGPU` 는 배열 안에서 값복사되는
    /// 구조체라, 상태를 구조체 필드로 들면 프레임마다 복사본이 갈린다. 인스턴스가 상태를 든다.
    ///
    /// 왜 풀(pooledOffscreen)로는 안 되나: 풀은 `(포맷, 폭, 높이)` 키의 체크아웃 카운터라
    /// **같은 이름의 FBO 가 프레임마다 같은 텍스처를 받는다는 보장이 없다**. 이펙트 가시성이
    /// 토글되거나 레이어 순서가 바뀌면 체크아웃 순서가 밀리고, 유체 시뮬은 직전 프레임의
    /// 자기 출력을 읽으므로 그 순간 상태가 남의 버퍼로 바뀐다. `unique` 는 그 계약을 깬다.
    final class UniqueFBOStore {
        /// fboSpecs 인덱스 → 지속 텍스처. `command:"swap"` 은 이 배열의 원소를 맞바꾸므로
        /// 핑퐁이 프레임을 넘어 유지된다(종전엔 프레임 로컬 배열을 바꿔 매 프레임 리셋됐다).
        var textures: [MTLTexture?] = []
        // (종전에 있던 `baseWidth`/`baseHeight` 는 제거했다 — dst 크기 변화로 **전부** 파기하면
        //  `fit:` 절대 크기 버퍼까지 날아간다. 이제 소비처가 인덱스별로 (폭, 높이, 포맷)을 대조해
        //  어긋난 것만 버린다.)
        /// 아직 `clearColor` 초기화를 못 받은 인덱스. 생성 직후 1회만 비운다 —
        /// **매 프레임 비우면 누적 자체가 성립하지 않는다**(그게 이 버퍼들의 존재 이유다).
        /// T09-D1 이후 소비처가 하나 늘었다: 스크립트의 `executeMaterialFunction(name)` 요청도
        /// 여기로 들어온다(applyEffect 의 드레인 블록). 그쪽은 unique 가 아닌 인덱스도 넣을 수
        /// 있고 — 실물 클리어 루프에 unique 분기가 없다 — 어느 쪽이든 클리어 직후 비워지므로
        /// "이 집합에 든 것만 이번 프레임에 비운다" 는 규약은 그대로다.
        var pendingClear: Set<Int> = []
        /// S5-2: 예산 초과로 공유 풀 폴백을 택했다는 경고를 **이펙트 인스턴스당 1회만** 낸다.
        /// 이 경로는 프레임마다 지나가므로 무조건 로그하면 로그가 프레임 예산을 잡아먹는다.
        var budgetWarned = false
    }

    enum EffectBind {
        case handPort(params: [Float], aux: [MTLTexture], audio: AudioParams?)
        case translated(passes: [TranslatedPass], fboSpecs: [FBOSpec], uniqueStore: UniqueFBOStore)
    }
    /// X-⑥: 이펙트 visible 스크립트 per-frame 게이트 — 참조형이라 EffectGPU 가 배열 안에서 값복사돼도
    /// (레이어/텍스트 propScripts 와 달리 build-once 캐시라 uid 키 dict 대신 인스턴스 자체가 상태를 든다)
    /// current 는 동일 인스턴스에 누적(스크립트의 상대 토글 — 예: `return !current` — 용).
    final class EffectVisibleGate {
        let engine: TextScriptEngine
        var current: Bool
        init(engine: TextScriptEngine, initial: Bool) { self.engine = engine; self.current = initial }
    }
    struct EffectGPU {
        let pipeline: MTLRenderPipelineState
        let bind: EffectBind
        /// X-⑥: visibleScript 보유 이펙트만 non-nil(스크립트 없는 절대다수는 무비용 nil — 매 프레임 항상 적용).
        var visibleGate: EffectVisibleGate? = nil
        /// 출력 패스(target==nil)의 콤보에 DIRECTDRAW=1 이 있는가 — true 면 이 이펙트의 체인 결과는
        /// straight-alpha 가 아니라 **premultiplied** 다(WE 규약: DIRECTDRAW 는 albedo=0 에서
        /// ApplyBlending(31)=A+B·opacity 로 색×커버리지를 직접 낸다). 소비처는 encodeLayer 의
        /// f_main_premul 분기. 코퍼스 도달은 lightshafts 41패스/23씬 전건이다(아래 makeTranslatedEffect 주석).
        var outputPremultiplied: Bool = false
        /// T09-D1: 매니페스트 `functions` 를 **fboSpecs 좌표**로 푼 표 — 이름 → 클리어할 인덱스들.
        /// 소비처는 applyEffect 의 pendingClear 블록 하나뿐이고, `thisObject.executeMaterialFunction(name)`
        /// 요청(TextScriptEngine.drainMaterialFunctionCalls)을 이 표로 인덱스로 옮긴다.
        /// **비어 있으면 그 블록이 통째로 건너뛰어져 종전 경로와 비트 동일**이다 — 동봉 `effect.json`
        /// 128건 중 `functions` 보유는 `effects/fluidsimulation` **1건**뿐이라(전수 파스 실측, preview
        /// 사본에도 없다) 나머지 127건은 드레인(JS 왕복)조차 일어나지 않는다.
        /// 표를 짓는 곳은 buildTranslatedEffect 의 `functionClears`.
        var functionClears: [String: [Int]] = [:]
    }

    /// T09-D1 **순수 로직**: 머티리얼 함수 요청 이름들 → 이번 프레임에 클리어할 FBO 인덱스 집합.
    ///
    /// 인코더에서 떼어낸 이유는 검증 가능성이다 — Metal 도 JSContext 도 안 타므로 리눅스에서
    /// 단독 컴파일·실행으로 없는 이름·중복 호출·범위 밖 인덱스를 전수 확인할 수 있다.
    ///
    ///   · `table` 에 없는 이름은 **무시**한다. 실물도 `functions` 선형 탐색이 miss 면 아무 일도
    ///     하지 않고 반환한다(0x1401ee403–0x1401ee40c 의 루프 탈출 → 0x1401ee509 로 직행).
    ///   · 같은 이름을 여러 번 불러도 집합이 흡수한다. 실물은 호출마다 클리어하지만
    ///     (0x1401ee440–0x1401ee4fe), 같은 프레임에서 같은 색으로 두 번 비운 결과는 한 번과 같다.
    ///   · `0..<fboCount` 밖은 버린다. 표는 빌드 시점에 이미 유효 인덱스만 담지만, 소비 시점의
    ///     `fboTex` 가 더 짧을 수 있는 경로(할당 실패 조기 반환)가 있어 상한을 한 번 더 본다.
    static func materialFunctionClearTargets(_ requests: [String],
                                             table: [String: [Int]],
                                             fboCount: Int) -> Set<Int> {
        guard !requests.isEmpty, !table.isEmpty, fboCount > 0 else { return [] }
        var out: Set<Int> = []
        for name in requests {
            guard let indices = table[name] else { continue }
            for i in indices where i >= 0 && i < fboCount { out.insert(i) }
        }
        return out
    }

    /// **하위호환 폴백 전용으로 축소됨**(2026-08-21, docs/re/package-format.md §7.1).
    ///
    /// 종전에는 이것이 마운트 **선택자**였다 — 폴더에 `scene.pkg`/`gifscene.pkg` 가 있으면
    /// `project.json` 의 `file` 과 무관하게 그것을 열었다. WE 는 `file` 하나로 정하고 `.pkg` 는
    /// 그 파일이 디스크에 없을 때만 도는 폴백이다(`0x14011e330`–`0x14011e3f9` · 마운트 디스패처
    /// `0x14010df40`). 그래서 결정 전체가 `ScenePackage.resolveMountSource(...)` 로 갔고,
    /// 이 두 이름 탐색은 그 결정의 **마지막 단**(선언된 `file` 이 아예 없을 때)으로만 남는다.
    ///
    /// 본체를 `ScenePackage.legacyPackageURL(in:)` 로 옮긴 이유는 검증 가능성이다 — 결정 전체가
    /// WapleCore 에 있어야 리눅스 테스트(`ScenePackageWEParityTests`)가 물린다. WapleRender 는
    /// Metal 전용이라 리눅스에서 빌드 자체가 안 된다.
    ///
    /// 이 자리를 지우지 않는 이유: `SceneRendererPathFallbackTests`
    /// `testScenePackageDiscoveryIsCaseInsensitive` 가 이 메서드를 직접 부른다(대소문자 보존
    /// 파일시스템에서 `Scene.pkg` 를 집는지 재는 테스트다). 그쪽은 이 과제의 소유가 아니다.
    func pkgURL(in folder: URL) -> URL? {
        ScenePackage.legacyPackageURL(in: folder)
    }

    /// 텍스처/에셋 바이트 로드: 패키지 우선, 없으면 공유 기본 에셋 디렉터리에서 폴백.
    /// 공유에서 찾거나 둘 다 없을 때만 로그(in-pkg 일반 경로는 조용히).
    func assetData(_ name: String, package: ScenePackage) -> Data? {
        guard case .data(let data) = probeAssetData(name, package: package) else {
            return nil
        }
        return data
    }

    private func probeAssetData(_ name: String, package: ScenePackage) -> SharedAssetProbeResult {
        if let d = packageData(name, package: package) { return .data(d) }
        guard WallpaperPathSecurity.normalizedRelativePath(name) != nil else {
            NSLog("%@", "[Waple] rejected shared asset path: \(name)")
            return .rejected
        }
        // 루트를 우선순위대로 훑는다(사용자 설치본 → 동봉본). `.rejected` 는 **즉시 반환** —
        // 이건 보안 판정이지 "이 루트에 없음"이 아니다(sharedAssetProbe(_:roots:) 와 같은 규약).
        for base in assetBaseRoots {
            switch baseAssetURLProbe(for: name, root: base) {
            case .url(let url):
                if let d = try? Data(contentsOf: url) {
                    NSLog("%@", "[Waple] asset from shared base: \(name)")
                    return .data(d)
                }
            case .rejected:
                NSLog("%@", "[Waple] rejected shared asset path: \(name)")
                return .rejected
            case .missing:
                break
            }
        }
        NSLog("%@", "[Waple] asset missing (pkg+shared): \(name)")
        return .missing
    }

    func resolveRequiredAsset<T>(
        _ candidates: [String],
        package: ScenePackage,
        decode: (Data) -> T?,
        alternate: () -> T? = { nil }
    ) -> T? {
        var foundBytes = false
        var rejected = false
        for candidate in candidates {
            switch probeAssetData(candidate, package: package) {
            case .data(let data):
                foundBytes = true
                if let value = decode(data) { return value }
            case .missing:
                break
            case .rejected:
                rejected = true
            }
        }
        if let value = alternate() { return value }
        guard !foundBytes,
              !rejected,
              !candidates.isEmpty,
              candidates.allSatisfy({ WallpaperPathSecurity.normalizedRelativePath($0) != nil }) else {
            return nil
        }
        markMissingRequiredSharedAsset()
        return nil
    }

    /// 레이어의 텍스처가 video-.tex 면 내장 MP4 를 추출(레이어별 고유 캐시키 — 한 씬 다중 video 대비)해
    /// SceneVideoLayer 공급자를 만든다. 비디오 아니거나 추출 실패(LZ4-mp4 등)면 nil → 호출부는 일반 이미지
    /// 경로로 폴백(video 페이로드는 TexDecoder.rgba 가 nil → 레이어 스킵, 형제 보존).
    func videoLayerProvider(_ layer: SceneLayer, package: ScenePackage, sceneID: String, index: Int) -> SceneVideoLayer? {
        guard let data = package.data(for: layer.textureEntryName),
              let tex = TexImage.parse(data), tex.payload == .video,
              let mp4 = VideoTextureExtractor.extractMP4(
                textureEntryName: layer.textureEntryName, package: package, sceneID: sceneID,
                cacheKey: "\(sceneID)_\(index)", cacheDir: VideoTextureExtractor.defaultCacheDir())
        else { return nil }
        return SceneVideoLayer(mp4URL: mp4)
    }

    /// 레이어/텍스트 공용 이펙트 체인 빌드(F741: buildLayers 루프에서 무수정 추출 — 정책 단일화).
    /// 디버그: WAPLE_EFFECT_SKIP=이름,이름 → 해당 효과 제외(파리티 이분용, WAPLE_MP_TRUNC 와 세트).
    /// baseNoInterp(감사 V06): 베이스 텍스처의 NoInterpolation — **체인 첫** 손-포팅 이펙트의 fb 만
    /// nearest(fb=베이스 직결은 첫 이펙트뿐, 2번째+ 는 FBO 출력이라 선형 유지가 WE 정합).
    func buildEffectChain(_ sceneEffects: [SceneEffect], package: ScenePackage, device: MTLDevice,
                          texW: Int, texH: Int, compositeImageTextures: [Int: String] = [:],
                          baseNoInterp: Bool = false) -> [EffectGPU] {
        var effects: [EffectGPU] = []
        let skipNames = Set((ProcessInfo.processInfo.environment["WAPLE_EFFECT_SKIP"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        for eff in sceneEffects {
            // F201 후속 + X-⑥: parseEffects 는 visible={value:false,script} 이펙트도 SceneEffect[] 에
            // 보존한다(데이터 무손실). visible 스크립트를 update 유무로 분류한다:
            //  · hasUpdate(진짜 시간/오디오 등 매 프레임 다른 값 가능) → per-frame 게이트로 effects 배열에
            //    상시 보존(아래 visibleGate). 이 경우만 effects.isEmpty 의미가 "이번 프레임 무이펙트"에서
            //    "이번 씬에 동적 이펙트 있음"으로 바뀐다 — noInterp nearest 판정(:1115 근방·SceneRenderer.swift
            //    nearest 라이브러리 게이트)이 이 레이어를 linear 로 보게 되는 게 유일한 잔여 트레이드오프
            //    (동적 게이트를 여는 대가 — 기존엔 이런 이펙트가 아예 존재할 수 없었으므로 신규 기능의
            //    불가피한 부수효과이지 회귀가 아니다).
            //  · update 없음(init-only, 이벤트 훅만 있고 update 없는 경우 포함 — 그런 스크립트는
            //    evaluateBool 이 항상 nil 이라 아래서 eff.initialVisible 로 폴백) → 빌드 시점 1 회
            //    정적 해석(engine.evaluateBool). 결과가 세션 내내 불변이므로 게이트 불요 —
            //    effects.isEmpty 의미도 완전히 보존(비트동일: 해석 결과 false 면 구 "항상 드롭"과
            //    동일하게 여기서 continue, true 면 무게이트로 항상 적용).
            // 실 코퍼스 17씬(예 2902406982·3113287126·3538758087)의 이벤트-훅 이펙트는 update 도
            // 의미있는 init 반환도 없어 정적 해석이 eff.initialVisible(false)로 폴백 → 구 드롭과 동치.
            var visibleGate: EffectVisibleGate? = nil
            var effectiveInitialVisible = eff.initialVisible
            // G-C4-01: 이펙트 프로퍼티에 붙은 스크립트의 `thisObject` 는 **그 이펙트**(IEffect)다 —
            // 실물 dino_run 의 godrays visible 스크립트가 `thisObject.getMaterial(0).raythreshold = …`
            // 로 패스 머티리얼 상수를 조정한다. 종전엔 thisObject 가 thisLayer(= 레이어 심)라
            // `getMaterial is not a function` TypeError 로 applyUserProperties 훅 전체가 죽었다.
            // 되읽은 쓰기는 아래 buildTranslatedEffect → buildPassMaterial 로 넘겨 패스 상수에 싣는다.
            var effectMaterialWrites: [[String: [Float]]] = []
            if let vs = eff.visibleScript {
                if let engine = makeScriptEngine(vs, scriptPropsJSON: eff.visibleScriptProps,
                                                 owner: .effect(materials: eff.passList.map(\.constants))) {
                    if engine.hasUpdate {
                        visibleGate = EffectVisibleGate(engine: engine, initial: eff.initialVisible)
                        hasAnimations = true  // buildPassMaterial 의 constantshadervalues 애니와 동일 규율
                        effectiveInitialVisible = true  // 게이트가 실제 가시성을 판정 — 아래 드롭 우회
                    } else {
                        effectiveInitialVisible = engine.evaluateBool(current: eff.initialVisible) ?? eff.initialVisible
                    }
                    // 로드 + applyUserProperties + (update 없으면) init 이 모두 끝난 뒤 되읽는다.
                    effectMaterialWrites = engine.boundObjectMaterialWrites
                }
                // else: 엔진 생성 실패(문법 오류 등) — effectiveInitialVisible 은 정적 초기값 그대로(무회귀).
            }
            if !effectiveInitialVisible { continue }
            if skipNames.contains(eff.name) { continue }
            // 폴터 체인(Step 5, 2026-07-02 실물 검증 후 전환): **translated 우선** — pkg 동봉 GLSL 은
            // 실제 WE 셰이더라 손-포팅 근사보다 항상 정확(실측: 근사 shake 가 5중 체인에서 과대 팬).
            // GLSL 부재/번역·컴파일 실패 시 손-포팅(스톡 7종) 폴터 → 둘 다 실패 시 스킵+로그.
            if var translated = buildTranslatedEffect(eff, package: package, device: device,
                                                      texW: texW, texH: texH,
                                                      compositeImageTextures: compositeImageTextures,
                                                      // 감사 V07: 베이스 NoInterpolation 은 체인 첫 이펙트의
                                                      // previous(=베이스 직결)만 nearest(아래 fbNearest 와 동일 게이트).
                                                      baseNoInterp: baseNoInterp && effects.isEmpty,
                                                      scriptMaterialWrites: effectMaterialWrites) {
                translated.visibleGate = visibleGate
                effects.append(translated)
            } else if var handPort = buildHandPortEffect(eff, package: package, device: device,
                                                         fbNearest: baseNoInterp && effects.isEmpty) {
                handPort.visibleGate = visibleGate
                effects.append(handPort)
            } else {
                NSLog("%@", "[Waple] effect skipped (no translatable GLSL, no hand-port): \(eff.name)")
            }
        }
        return effects
    }

    /// 레이어를 후→전 순서(JSON 순서)로 GPU 리소스화. 디코드 실패 레이어는 스킵.
    func buildLayers(doc: SceneDocument, package: ScenePackage, device: MTLDevice, sceneID: String) -> [GPULayer] {
        // E1(⑥): SceneRenderer.swift:1122(projW/projH 인스턴스 프로퍼티)와 동일하게 클램프 — 종전엔 이
        // 쿼드 정점 계산만 무클램프 doc.projectionWidth/Height 를 써서, projection 이 0인 씬(파서는
        // 명시적 0을 그대로 통과시킨다, SceneDocument.swift:729-730)에서 pxToNDC 0-나눗셈으로 정적
        // 레이어만 NaN 소실되는 비대칭이 있었다(애니/스크립트 경로는 이미 클램프된 projW/projH 사용).
        let w = Float(max(1, doc.projectionWidth)), h = Float(max(1, doc.projectionHeight))
        var out: [GPULayer] = []
        // attachment 자식들이 공유하는 부모 퍼펫 캐시(경로→파스 결과, 실패도 캐시 — 재파스 방지).
        var attachPuppets: [String: PuppetModel?] = [:]
        // F720: `_rt_imageLayerComposite_<id>` 정적 치환 맵(레이어 id → 베이스 이미지 텍스처) —
        // 3D 경로(SceneRenderer3D.build3D)와 동일 규약. 효과 슬롯 바인드(buildPassBindings)가 소비.
        let compositeImageTextures = doc.layers.reduce(into: [Int: String]()) { acc, layer in
            guard layer.id != 0, !layer.textureEntryName.isEmpty else { return }
            acc[layer.id] = layer.textureEntryName
        }
        for (uid, layer) in doc.layers.enumerated() {
            // 솔리드 마커(""): 무텍스처 flat 머티리얼 → 흰색 1x1 — 기존 tint 경로(color×brightness, alpha)가 필을 만든다.
            // 컴포지션(_rt_) 레이어: 텍스처는 런타임 스냅샷 — 여기선 placeholder + 효과 dims 를 프로젝션으로 근사
            // (효과 texRes 는 주로 텍셀 오프셋 용도; 화면 크기는 draw 시 결정 — 설계 §3).
            // 텍스처 + (스프라이트시트면) TEXS 프레임. effW/effH = 효과 dst 크기(스프라이트는 프레임 dims —
            // 효과는 시트가 아니라 프레임 1장에 적용, buildDisplayTextures 가 프레임 추출 후 체인).
            let mtl: MTLTexture
            let effW: Int, effH: Int
            var frames: [TexImage.TexFrame] = []
            var videoLayer: SceneVideoLayer? = nil   // 비디오-텍스처 레이어면 프레임 공급자(그 외 nil)
            if layer.textureEntryName.isEmpty {  // 솔리드/컴포지션 placeholder
                guard let t = makeTexture(Data([255, 255, 255, 255]), 1, 1, device) else { continue }
                mtl = t
                // 컴포지션 효과 dims 는 화면 근사, 솔리드는 레이어 크기 — 1×1 이면 공간 가변 효과
                // (waterwaves/scroll 등) 체인 전체가 1픽셀 타깃으로 퇴화(단색화).
                // F530: 거대 size/projection 의 Int() 변환 트랩 방지 — safeFloatToInt(FrameEncoder) 경유.
                effW = layer.isFrameBuffer ? Self.safeFloatToInt(projW, floor: 1) : Self.safeFloatToInt(layer.size.x, floor: 1)
                effH = layer.isFrameBuffer ? Self.safeFloatToInt(projH, floor: 1) : Self.safeFloatToInt(layer.size.y, floor: 1)
            } else if let sv = videoLayerProvider(layer, package: package, sceneID: sceneID, index: uid),
                      let ph = makeTexture(Data([0, 0, 0, 0]), 1, 1, device) {
                // 비디오-텍스처 레이어: 씬을 통째로 VideoRenderer 로 스왑(형제 소실)하지 않고 일반 레이어로
                // 합성한다. mtl 은 1×1 clear placeholder — 실제 프레임은 buildDisplayTextures 가 프레임별
                // (라이브: AVPlayerItemVideoOutput / 헤드리스: AVAssetImageGenerator)로 공급. 디코드 실패 시
                // placeholder(투명)라 형제 레이어는 그대로 보존. rect/blend/opacity 는 아래 일반 경로가 존중.
                mtl = ph
                effW = Self.safeFloatToInt(layer.size.x, floor: 1)  // F530: Int() 트랩 가드
                effH = Self.safeFloatToInt(layer.size.y, floor: 1)
                videoLayer = sv
                hasVideoLayer = true
            } else if layer.spritesheet,
                      let sprite = resolveTextureWithFrames(layer.textureEntryName, package: package, device: device),
                      sprite.frames.count > 1 {
                // SPRITESHEET 콤보 + TEXS 다중 프레임 → gif 애니. resolveTextureWithFrames 가 아틀라스
                // (멀티페이지는 세로 스택 + frame.y 페이지 오프셋) + 프레임을 준다. 단일 프레임(count≤1)은
                // 정지 이미지와 동등 → 아래 일반 경로로(무-프레임, 상시 리드로 유발 안 함).
                mtl = sprite.texture
                frames = sprite.frames
                effW = Self.safeFloatToInt(sprite.frames[0].atlasWidth, floor: 1)  // F530: Int() 트랩 가드
                effH = Self.safeFloatToInt(sprite.frames[0].atlasHeight, floor: 1)
            } else if let loaded: (texture: MTLTexture, width: Int, height: Int) = resolveRequiredAsset(
                [layer.textureEntryName],
                package: package,
                decode: { data in
                    guard let tex = TexImage.parse(data),
                          let up = makeImageTexture(tex: tex, data: data, device: device) else {
                        return nil
                    }
                    return (up.texture, up.width, up.height)
                },
                alternate: {
                    guard let decoded = bitmapRGBAFile(layer.textureEntryName),
                          let texture = makeTexture(decoded.pixels, decoded.width, decoded.height, device) else {
                        return nil
                    }
                    return (texture, decoded.width, decoded.height)
                }
            ) {
                mtl = loaded.texture
                effW = loaded.width
                effH = loaded.height
            } else {
                // E1(⑥): 진단성 — 종전엔 텍스처 바이트를 찾았어도 디코드(TexImage.parse/makeImageTexture)에
                // 실패하면 레이어가 아무 로그 없이 통째로 드롭됐다(buildLayers 는 마운트당 1회라 스팸 무관).
                WapleLog.warn("[Waple] layer texture decode failed, layer dropped: \(layer.textureEntryName)")
                continue
            }
            // 스프라이트 프레임 있으면 상시 리드로 필요(gif 재생) — needsDisplay 정책은 shouldAnimate 로.
            if !frames.isEmpty { hasAnimations = true }
            let verts = Self.quadVertices(layer: layer, projW: w, projH: h)
            guard let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<SIMD4<Float>>.stride * verts.count) else { continue }
            let tint = SIMD4<Float>(layer.color.x * layer.brightness, layer.color.y * layer.brightness,
                                    layer.color.z * layer.brightness, layer.alpha)
            // 이펙트 체인 빌드는 buildEffectChain 으로 추출(F741 — 텍스트 경로와 정책 공유, 동작 무수정).
            // 감사 V06+V07: 베이스 텍스처의 NoInterpolation — 손-포팅 체인 첫 이펙트 fb(V06)와 무효과
            // 베이스의 f_main nearest 변형(V07, GPULayer.noInterp) 양쪽이 소비하므로 상시 조회로 변경
            // (V06 는 이펙트 보유 시에만 조회했다).
            // C⑧a: 오브젝트 레벨 nointerpolation 오버라이드(SceneDocument.swift 파싱, 종전 렌더 미소비)를
            // 헤더 값과 OR — 오브젝트가 명시 요청하면 헤더가 linear 여도 nearest 를 강제한다(감사 C⑧a
            // 발산 실측: 오브젝트=true·헤더=false 47쌍). 헤더가 true 인데 오브젝트 키가 JSON 부재(파스는
            // 둘 다 false 로 접힘 — tri-state 미보존)라도 OR 라 기존 헤더발 nearest 는 그대로 보존(무회귀).
            let noInterp = layer.noInterpolation || resolveTextureNoInterpolation(layer.textureEntryName, package: package)
            let effects = buildEffectChain(layer.effects, package: package, device: device,
                                           texW: effW, texH: effH,
                                           compositeImageTextures: compositeImageTextures,
                                           baseNoInterp: noInterp)
            if !effects.isEmpty { hasEffects = true }
            if !layer.animations.isEmpty { hasAnimations = true }
            // 퍼펫(.mdl): 스키닝 메시. WE 규약(changelog: "Only load puppet ref if file exists on
            // global file system") — ref 부재는 정상(기본 models/1x1.json 의 미베이크 puppet 등, 실측
            // 2955378002 에서만 50 레이어)이라 조용히 일반 쿼드. 다른 선택적 에셋과 동일하게 quietAssetData
            // 로 로드하고, **바이트는 있으나 파싱 실패**한 실결함만 로그(과침묵 방지).
            var puppetModel: PuppetModel? = nil
            if let pp = layer.puppet, let bytes = quietAssetData(pp, package: package) {
                if let pm = PuppetModel.parse(bytes) {
                    puppetModel = pm
                    if !pm.animations.isEmpty { hasAnimations = true }
                } else {
                    NSLog("%@", "[Waple] puppet mdl load failed (static quad fallback): \(pp)")
                }
            }
            // 레이어 프로퍼티 스크립트(visible/color/alpha/origin/scale/angles): 씬 공유 컨텍스트에서
            // per-frame 평가. visible 을 먼저 로드 — 실물 컨트롤러(3394601417 'bt')의 top-level shared
            // 초기화가 같은 오브젝트의 다른 스크립트보다 앞서도록. update 없는 스크립트(사이드이펙트
            // 전용)도 로드는 하되 연속 렌더(hasAnimations)는 유발하지 않는다.
            // origin/scale/angles(F331): 3D 빌보드 경로(SceneRenderer3D.Billboard3D)는 이미 동일
            // propertyScripts 를 소비 — 2D encodeLayer 도 동형으로 quadDirty→quadVertices 재계산.
            var propScripts: [(key: String, engine: TextScriptEngine)] = []
            for key in ["visible", "color", "alpha", "origin", "scale", "angles"] {
                guard let src = layer.propertyScripts[key] else { continue }
                if key == "visible", Self.isVectorValuedVisibleScript(src) {
                    NSLog("%@", "[Waple] skipped vector-valued visible script")
                    continue
                }
                let ownerName = layer.name.isEmpty ? nil : layer.name
                // F743(S-34): currentLayerIndex = doc.layers 인덱스(디스크립터 순서 = doc.layers+doc.texts)
                // — 중복명/묘명 레이어의 thisLayer 오바인딩 해소.
                if let e = makeScriptEngine(src, layerName: ownerName, currentLayerIndex: uid,
                                            scriptPropsJSON: layer.propertyScriptProps[key]) {
                    propScripts.append((key, e))
                    if e.hasUpdate { hasAnimations = true }
                }
            }
            // animationlayers blend/visible/rate 바인딩 스크립트(실물 rate 오디오 배속 2955378002/3448290956,
            // visible 토글 15씬): per-frame 재평가용 엔진. 정적 파스값은 초기값으로 유지(encodeLayer effLayers).
            var animLayerScripts: [(layerIndex: Int, key: String, engine: TextScriptEngine)] = []
            for (idx, al) in layer.animationLayers.enumerated() {
                for (key, src) in al.scripts {
                    if let e = makeScriptEngine(src, layerName: layer.name.isEmpty ? nil : layer.name,
                                                currentLayerIndex: uid) {  // F743(S-34): 디스크립터 인덱스 직결
                        animLayerScripts.append((idx, key, e))
                        if e.hasUpdate { hasAnimations = true }
                    }
                }
            }
            // material.constantshadervalue.scripted — PBR scalar per-frame evaluation (roughness/metallic/speculartint).
            var materialScripts: [(key: String, engine: TextScriptEngine)] = []
            for key in ["roughness", "metallic", "speculartint"] {
                guard let src = layer.materialScripts[key] else { continue }
                if let e = makeScriptEngine(src, layerName: layer.name.isEmpty ? nil : layer.name,
                                            currentLayerIndex: uid,
                                            scriptPropsJSON: layer.materialScriptProps[key]) {
                    materialScripts.append((key, e))
                    if e.hasUpdate { hasAnimations = true }
                }
            }
            // attachment(이름 본-슬롯 부착): 부모 레이어의 퍼펫 모델에서 부착점(MDAT)을 찾아 스펙 구성.
            // 부모/퍼펫/부착점 어느 하나라도 부재 → nil = 무부착 폴백(기존 베이크 위치 그대로 — 무회귀·무크래시).
            var attach: SceneRenderer.PuppetAttach? = nil
            if let attName = layer.attachment, let pid = layer.parent,
               let parentDef = doc.layers.first(where: { $0.id == pid }), let pp = parentDef.puppet {
                let pm: PuppetModel?
                if let cached = attachPuppets[pp] {
                    pm = cached
                } else {
                    pm = quietAssetData(pp, package: package).flatMap { PuppetModel.parse($0) }
                    attachPuppets[pp] = pm
                }
                if let pm, pm.attachments.contains(where: { $0.name == attName }) {
                    attach = SceneRenderer.PuppetAttach(
                        model: pm, name: attName,
                        parentOrigin: SIMD2(parentDef.origin.x, parentDef.origin.y),
                        parentScale: SIMD2(parentDef.scale.x, parentDef.scale.y),
                        parentAngle: parentDef.angleZ,
                        parentLayers: parentDef.animationLayers)
                    if !pm.animations.isEmpty { hasAnimations = true }  // 본 애니 추종 = 연속 리드로
                }
            }
            // 포워드 라이팅 대상 게이트(좁게): 씬 라이트(forwardLit) + LIGHTING:1 콤보 + 일반 이미지
            // 레이어만(퍼펫/컴포지션/colorBlend 는 별도 특수 경로라 제외 → 무회귀). base litRect 산출,
            // 애니 레이어는 encodeLayer 가 per-frame 재계산.
            let layerLit = forwardLit && layer.lighting && !layer.isFrameBuffer
                && puppetModel == nil && layer.colorBlendMode == 0
            let lrect = layerLit
                ? Self.litRect(origin: layer.origin, size: layer.size, scale: layer.scale,
                          angleZ: layer.angleZ, alignment: layer.alignment, originZ: layer.originZ)
                : (SIMD4<Float>.zero, SIMD4<Float>.zero)
            var gpuLayer = GPULayer(texture: mtl, vertexBuffer: vbuf, tint: tint,
                                parallaxDepth: SIMD2<Float>(layer.parallaxDepth.x, layer.parallaxDepth.y),
                                effects: effects, texWidth: effW, texHeight: effH,
                                order: layer.order, uid: uid,
                                blendAdditive: layer.blendMode == "additive",
                                isFrameBuffer: layer.isFrameBuffer,
                                copyBackground: layer.copyBackground,
                                def: (layer.animations.isEmpty && puppetModel == nil && propScripts.isEmpty
                                      && attach == nil) ? nil : layer,
                                puppet: puppetModel, propScripts: propScripts,
                                animLayerScripts: animLayerScripts,
                                materialScripts: materialScripts,
                                initialVisible: layer.initialVisible,
                                hiddenByAncestor: layer.hiddenByAncestor,
                                colorBlendMode: layer.colorBlendMode, frames: frames,
                                isLit: layerLit,
                                pbrMaterial: PBRMaterialUniforms(
                                    scalars: SIMD4(layer.roughness, layer.metallic, 0, 0),
                                    specularTint: SIMD4(layer.specularTint.x, layer.specularTint.y,
                                                        layer.specularTint.z, 0)),
                                litRect: lrect, video: videoLayer, attach: attach,
                                // F722: 비디오/프레임버퍼가 아닌 정적 이미지 레이어만 미디어 아트워크 대상
                                // (비디오는 프레임 공급자가 base 를 덮고, 컴포지션은 스냅샷 경로라 무의미).
                                mediaArtwork: (videoLayer == nil && !layer.isFrameBuffer)
                                    ? mediaArtworkKind(textureEntryName: layer.textureEntryName, package: package)
                                    : .none,
                                noInterp: noInterp)
            // H1: 커스텀 머티리얼 셰이더 파이프라인 빌드(실패 시 nil → QuadShaders 폴터).
            if layer.materialShader != nil {
                gpuLayer.customShader = buildCustomLayerShader(layer, texture: mtl, package: package,
                                                               device: device, pixelFormat: accPixelFormat)
                // 커스텀 셰이더 경로는 변환 행렬 산출에 def 가 필요 — 빌드 성공 시에만 유지.
                // materialShader 문자엧만으로는 판별 불가(genericimage4 같은 빌트인 이름도 잡히므로).
                if gpuLayer.customShader != nil, gpuLayer.def == nil {
                    gpuLayer.def = layer
                }
            }
            // H4: REFRACT — 노멀맵 로드 + refractAmount. 실패 시 refract 미설정 → identity 폴터(무크래시).
            if layer.refract, let normalName = layer.normalTextureName,
               let n = resolveRefractNormal(normalName, package: package, device: device) {
                gpuLayer.refract.enabled = true
                gpuLayer.refract.normalTexture = n.texture
                gpuLayer.refract.normalRG88 = n.rg88
                gpuLayer.refract.amount = layer.refractAmount
            }
            out.append(gpuLayer)
        }
        return out
    }

    static func isVectorValuedVisibleScript(_ source: String) -> Bool {
        let compact = source.replacingOccurrences(of: "\r", with: "\n")
        let valueMutationPatterns = ["value.x =", "value.y =", "value.z =", "value.x=", "value.y=", "value.z="]
        if valueMutationPatterns.contains(where: { compact.contains($0) }) { return true }
        if compact.range(of: #"return\s+new\s+Vec[234]?\b"#, options: .regularExpression) != nil { return true }
        if compact.range(of: #"value\s*=\s*new\s+Vec[234]?\b"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// 손-포팅 효과(검증된 스톡 7종) 빌드. 미지원 이름이면 nil(→ 변환 경로 시도).
    /// fbNearest(감사 V06): 레이어 베이스 텍스처의 NoInterpolation — fb(texture(0)) 샘플만 nearest.
    func buildHandPortEffect(_ eff: SceneEffect, package: ScenePackage, device: MTLDevice,
                             fbNearest: Bool = false) -> EffectGPU? {
        guard let src = EffectShaders.source(for: eff.name, fbNearest: fbNearest),
              let params = EffectShaders.params(for: eff.name, constants: eff.constants, combos: eff.combos),
              let pipe = effectPipeline(source: src, device: device) else { return nil }
        let audio = audioParams(for: eff)
        if audio != nil { hasAudio = true }
        // slot0 은 framebuffer → aux 는 slot1.. 디코드. 디코드 실패는 흰색 1x1 폴백.
        // 레거시 frag(mask=texture(1)) 와 waterripple(normal=1, mask=2) 모두 위해
        // 최소 2개 슬롯을 흰색으로 채워 미바인드 텍스처를 방지한다.
        // F265 예외: shake 의 aux[0](slot1=flow map, WE 기본 util/noflow)은 흰색(=1.0)이면
        // flowMask=(1-0.498)*2≈1 로 상시 대각 드리프트가 생겨 "기본 flow=noflow → flowMask≈0"(F265 evidence)
        // 와 모순 — 명시 바인드가 없을 때만 중립 회색(byte 127≈0.498 → flowMask≈0)으로 대체.
        // F412 예외: waterripple 의 aux[0](slot1=노멀맵)도 흰색이면 언팩(rgb*2-1) 후 n=(1,1,1) 이라
        // 마스크 유효 영역 전체가 상시 대각 변위(정적 왜곡) — 중립 노멀 (128,128,255)(언팩 (0,0,1)=무왜곡)으로 대체.
        var aux: [MTLTexture] = []
        // slot0=framebuffer 라 aux 는 index i+1 로 바인드 — 126개 캡(Metal 텍스처 인자테이블 128 상한).
        let auxNames = eff.textureNames.count > 1 ? Array(eff.textureNames[1...].prefix(126)) : []
        for (i, name) in auxNames.enumerated() {
            if eff.name == "shake", i == 0, name == nil, let neutral = makeTexture(Data([127, 127, 0, 255]), 1, 1, device) {
                aux.append(neutral); continue
            }
            if eff.name == "waterripple", i == 0, name == nil, let neutral = makeTexture(Data([128, 128, 255, 255]), 1, 1, device) {
                aux.append(neutral); continue
            }
            // F830: pulse 의 aux[0](slot1=noise)은 WE 기본 "util/noise"(pulse.frag g_Texture1 default) —
            // 흰색 1x1 폴터면 noise=1×noiseAmount 상수 오프셋이 돼 시간 스크롤 노이즈가 사라진다.
            // noiseAmount=0(기본) 이면 결과 무관하나 noise>0 실씬에서 유효.
            if eff.name == "pulse", i == 0, name == nil,
               let t = resolveTexture("util/noise", package: package, device: device) {
                aux.append(t); continue
            }
            // F831: pulse 의 aux[1](slot2=opacity mask)은 MASK 콤보 ON 인데 미바인드면 WE
            // paintdefaultcolor "0 0 0 1"(블랙) = 전면 마스크아웃(효과 미적용). 흰색이면 반대로 전면 적용.
            if eff.name == "pulse", i == 1, name == nil, (eff.combos["MASK"] ?? 0) != 0,
               let black = makeTexture(Data([0, 0, 0, 255]), 1, 1, device) {
                aux.append(black); continue
            }
            guard let t = resolveTexture(name, package: package, device: device) else { continue }
            aux.append(t)
        }
        while aux.count < 2 {
            let isShakeFlowPad = eff.name == "shake" && aux.isEmpty
            let isWaterrippleNormalPad = eff.name == "waterripple" && aux.isEmpty  // F412
            // F830: textures 배열 자체가 짧은 pulse 도 slot1 기본은 util/noise(위 루프와 동일 계약).
            if eff.name == "pulse", aux.isEmpty,
               let t = resolveTexture("util/noise", package: package, device: device) {
                aux.append(t); continue
            }
            // F831: MASK 콤보 ON pulse 의 slot2 패드는 paintdefault 블랙(위 루프와 동일 계약).
            let isPulseMaskPad = eff.name == "pulse" && aux.count == 1 && (eff.combos["MASK"] ?? 0) != 0
            guard let tex = makeTexture(
                isShakeFlowPad ? Data([127, 127, 0, 255]) : isWaterrippleNormalPad ? Data([128, 128, 255, 255]) :
                isPulseMaskPad ? Data([0, 0, 0, 255]) : Data([255, 255, 255, 255]),
                1, 1, device) else { break }
            aux.append(tex)
        }
        return EffectGPU(pipeline: pipe, bind: .handPort(params: params, aux: aux, audio: audio))
    }

    /// GLSL→MSL 변환 효과 빌드(멀티패스): effect.json 매니페스트(passes/fbos) → 패스별 셰이더 로드 →
    /// translate → 파이프라인 → 바인드 플랜. 어느 단계든 실패하면 nil(→ 손-포팅 폴백 → 스킵). 무회귀.
    /// 5책임 분해(2026-07-04, 동작 불변): ① 매니페스트 로드(loadEffectManifest) ② copy 명령 패스
    /// 합성(makeCopyPass) ③ 셰이더/머티리얼 메타 해석(resolvePassShaderMeta) ④ 콤보 해석
    /// (resolvePassCombos) ⑤ 머티리얼 상수/스크립트(buildPassMaterial) + 바인드·texRes·aux·target
    /// 플랜(buildPassBindings).
    /// scriptMaterialWrites(G-C4-01): 이펙트 프로퍼티 스크립트가 `thisObject.getMaterial(i)` 로 쓴
    /// 상수. 인덱스 = raw 패스 인덱스. 기본 [] = 종전 동작(무회귀).
    func buildTranslatedEffect(_ eff: SceneEffect, package: ScenePackage, device: MTLDevice,
                               texW: Int, texH: Int, compositeImageTextures: [Int: String] = [:],
                               // 감사 V07: 베이스 텍스처 NoInterpolation — previous bind(=효과 입력 src,
                               // 체인 첫 이펙트는 베이스 직결) 슬롯의 texFilter 를 nearest 로.
                               baseNoInterp: Bool = false,
                               scriptMaterialWrites: [[String: [Float]]] = []) -> EffectGPU? {
        // 디버그 바이섹션 스위치: 실물 씬에서 번역 효과만 끄고 A/B 비교(시각 아티팩트 책임 분리).
        if ProcessInfo.processInfo.environment["WAPLE_DISABLE_TRANSLATED"] == "1" { return nil }
        // #include 리졸버: pkg→베이스에셋→내장(확정-의미 서브셋, common_blending.h) 순.
        // X-⑨: 이펙트-로컬 루트 우선(effectScopedData 주석 — 스톡 46/46 이 자기 shaders/materials 를 갖는다).
        let effectRoot = SceneRenderer.effectLocalRoot(eff)
        let include: (String) -> String? = { header in
            for cand in ["shaders/\(header)", header] {
                if let d = self.effectScopedData(cand, root: effectRoot, package: package),
                   let s = String(data: d, encoding: .utf8) { return s }
            }
            return BuiltinShaderIncludes.lookup(header)
        }
        let manifest = loadEffectManifest(eff, package: package)
        // 중복 이름은 **뒤가 이긴다**. `EffectManifest`(:63-78)는 치수만 8192 로 클램프하고 이름
        // 유일성은 보지 않으며, 매니페스트는 pkg 우선 조회(:644 quietAssetData)라 워크샵 pkg 가 자체
        // `effects/<name>/effect.json` 을 실으면 그대로 도달한다. 이 줄은 loadEffectManifest 바로
        // 다음이라 셰이더 해석보다 **먼저** 터졌다. 동봉 자산 101개 전수 파스에서 중복은 0건 —
        // 정상 자산은 영향 없고, 저작 오류·악의 입력만 여기로 온다.
        // X-⑪(G-A5-07/G-B2-05): `conditions` 가 거짓인 FBO 는 **아예 만들지 않는다**.
        // 참조는 전부 이름 기반이고 이름→인덱스 변환이 이 필터 **뒤에** 일어나므로 벡터가 압축돼도
        // 어긋나지 않는다. 좌변은 이펙트 인스턴스 레벨 combos 다(패스 레벨과 다른 것 — SceneEffect
        // 주석 참조). 동봉 자산 기준으로 `fluidsimulation` 의 `_rt_SmokeNormal`(LIGHTING==1)이
        // 여기서 빠지고, 그것을 쓰는 패스·바인드가 **같은 조건**이라 함께 사라진다.
        let instanceCombos = eff.instanceCombos
        let liveFbos = manifest.fbos.filter {
            EffectManifest.evaluate($0.conditions, combos: instanceCombos)
        }
        if liveFbos.count != manifest.fbos.count {
            NSLog("%@", "[Waple] conditions: \(eff.name) 의 fbo \(manifest.fbos.count - liveFbos.count)개 비활성")
        }
        let fboIndex = Dictionary(liveFbos.enumerated().map { ($1.name, $0) },
                                  uniquingKeysWith: { _, later in later })
        // X-⑧: fbo 인덱스별 Metal 포맷. 패스 파이프라인의 컬러 어태치먼트 포맷은 **그 패스가
        // 쓰는 타깃의 포맷과 일치해야 한다**(불일치 = Metal 파이프라인 생성 실패/미정의).
        // 타깃 없는 패스(효과 출력)는 체인 dst 포맷 — 이 렌더러의 이펙트 체인 dst 는
        // pooledOffscreen(bgra:false) = rgba8Unorm 고정이다.
        // `hdrActive` 는 마운트에서 이미 확정이다(`SceneRenderer.mount` 가 sceneIsHDR/sceneQuality 를
        // 잡은 뒤 buildLayers 를 부른다) — 빌드 시점 1 회 해석으로 충분하고 프레임마다 흔들리지 않는다.
        let fboFormats = liveFbos.map { SceneRenderer.metalFormat($0.format, hdr: hdrActive) }
        let outputFormat = MTLPixelFormat.rgba8Unorm
        func targetFormat(_ name: String?) -> MTLPixelFormat {
            guard let n = name, let i = fboIndex[n] else { return outputFormat }
            return fboFormats[i]
        }
        let lw = Float(max(1, texW)), lh = Float(max(1, texH))
        var passes: [TranslatedPass] = []
        var anyAudio = false
        // 출력 패스(target==nil)가 DIRECTDRAW 면 체인 결과가 premultiplied — EffectGPU 로 실어 보낸다.
        var outputPremultiplied = false
        // G-B2-06 **정정(2026-08-20)**: 씬의 `effects[].passes[]` 는 매니페스트 `passes[]` 의
        // **원본 배열 인덱스**로 정렬된다 — 명령 패스도 슬롯을 하나 소비한다.
        //
        // 종전엔 반대로 갔다. "motionblur 는 effect.json 3패스(셰이더 2 + copy 1)인데 씬 패스는
        // 2개, fluidsimulation 은 20(18 + swap 2)인데 씬 패스는 18개" 라는 **개수 세기**만 보고
        // 셰이더 패스만 세는 커서를 뒀는데, 원본을 뜯으니 그 추론이 틀렸다.
        //
        // 원본 파서(`0x1401e7170`)에는 명령 패스를 조기 continue 시키는 분기가 **없다**.
        // `material` 이 문자열이 아니면 `jne 0x1401e7b3e` 로 **머티리얼 로드만** 건너뛰고 곧장
        // command 파싱으로 합류하며, 명령 패스도 정식으로 패스 벡터에 push 된다(stride 0x30).
        // 루프 증가점 `0x1401e814e`(`inc ebx`) 로 점프하는 명령은 루프 전체에서 단 하나
        // (`0x1401e7a04` = conditions 탈락)뿐이고 나머지는 전부 fall-through 다. 그리고 씬
        // 오버라이드는 `0x1401e7a6e` 의 `mov edx, ebx` — **같은 ebx** 로 조회한다.
        //
        // 개수가 안 맞았던 진짜 이유: 씬 배열이 짧으면 초과 인덱스는 에러가 아니라 **오버라이드
        // 없음**이다(JsonCpp non-const `operator[](ArrayIndex)` 가 nullValue 를 삽입해 반환 —
        // `0x14008672e`). fluidsimulation 은 명령 패스가 배열 **끝**이라 에디터가 후행 빈 원소를
        // 잘라낸 것이고, motionblur 는 명령 패스가 **중간**이라 씬 `passes[1]` 이 빈 `{}` 로
        // 남아 있다. 즉 `motionblur_combine`(원본 인덱스 2)은 `passes[1]` 이 아니라 범위 밖인
        // `passes[2]` 를 받는다 — 어느 쪽이든 오버라이드가 없어 동봉 자산에서는 결과가 같지만,
        // 명령 패스가 중간에 있는 워크샵 자산에서는 상수·텍스처가 통째로 한 칸씩 밀린다.
        for (i, mp) in manifest.passes.enumerated() {
            // X-⑪: 조건이 거짓이면 이 패스를 통째로 건너뛴다. `i` 는 `enumerated()` 라
            // 씬 오버라이드 인덱스 정렬이 자동으로 보존된다 — 원본도 인덱스만 올리고 continue 한다.
            guard EffectManifest.evaluate(mp.conditions, combos: instanceCombos) else {
                NSLog("%@", "[Waple] conditions: \(eff.name) 패스 \(i) 비활성")
                continue
            }
            if mp.command == "copy" {
                guard let copy = makeCopyPass(mp, effName: eff.name, fboIndex: fboIndex,
                                              lw: lw, lh: lh, device: device,
                                              pixelFormat: targetFormat(mp.target)) else { return nil }
                passes.append(copy)
                continue
            }
            // X-②: command:"swap"(셰이더 없음, 실물 fluidsimulation velocity/dye 더블버퍼) — 무비용
            // 포인터 교환. 종전엔 이 분기가 없어 셰이더 패스로 오해석돼(material/shader 부재 →
            // "effects/<name>" 관례 조회 실패) 이펙트 전체가 드롭됐다.
            if mp.command == "swap" {
                if let swap = makeSwapPass(mp, effName: eff.name, fboIndex: fboIndex, device: device) {
                    passes.append(swap)
                }
                continue    // 못 풀어도 이 패스만 생략 — 인덱스는 enumerated() 라 영향 없다
            }
            let meta = resolvePassShaderMeta(mp, eff: eff, manifest: manifest, package: package, root: effectRoot)
            guard let vData = effectScopedData("shaders/\(meta.base).vert", root: effectRoot, package: package),
                  let fData = effectScopedData("shaders/\(meta.base).frag", root: effectRoot, package: package),
                  let vert = String(data: vData, encoding: .utf8),
                  let frag = String(data: fData, encoding: .utf8) else { return nil }
            let scenePass = SceneRenderer.sceneOverride(forRawPassIndex: i, in: eff.passList)
            let combos = resolvePassCombos(vert: vert, frag: frag, scenePass: scenePass,
                                           matCombos: meta.matCombos, matTextures: meta.matTextures,
                                           effectRoot: effectRoot, package: package)
            guard let t = GLSLTranslator.translate(vertex: vert, fragment: frag, combos: combos, include: include) else {
                NSLog("%@", "[Waple] GLSL translate failed: \(eff.name) pass \(i)")
                return nil
            }
            let passFormat = targetFormat(mp.target)
            guard let pipe = translatedPipeline(msl: t.msl, device: device, pixelFormat: passFormat) else {
                // X-⑧: 포맷을 로그에 넣는다 — 여기서 실패하면 이펙트가 통째로 폴백하는데, 종전 메시지로는
                // MSL 컴파일 실패인지 어태치먼트 포맷 거부인지 구분이 안 됐다.
                NSLog("%@", "[Waple] translated MSL compile failed: \(eff.name) pass \(i) "
                          + "target=\(mp.target ?? "(output)") format=\(passFormat.rawValue)")
                return nil
            }
            let (material, passScripts, passAnimations) =
                buildPassMaterial(t, scenePass: scenePass,
                                  scriptWrites: i < scriptMaterialWrites.count ? scriptMaterialWrites[i] : [:])
            guard let plan = buildPassBindings(mp, effName: eff.name, translation: t, scenePass: scenePass,
                                               matTextures: meta.matTextures, manifest: manifest,
                                               fbos: liveFbos, fboIndex: fboIndex, lw: lw, lh: lh,
                                               package: package, device: device,
                                               compositeImageTextures: compositeImageTextures,
                                               baseNoInterp: baseNoInterp, root: effectRoot,
                                               instanceCombos: instanceCombos) else { return nil }
            if t.usesAudio { anyAudio = true }
            if plan.target == nil, combos["DIRECTDRAW"] == 1 { outputPremultiplied = true }
            passes.append(TranslatedPass(pipeline: pipe, material: material, aux: plan.aux,
                                         binds: plan.binds, target: plan.target, compose: mp.compose,
                                         usesAudio: t.usesAudio,
                                         texRes: plan.texRes, texWrap: plan.texWrap, texFilter: plan.texFilter,
                                         scripts: passScripts, fullFrameSlots: plan.fullFrameSlots, swapPair: nil,
                                         mediaArtworkSlots: plan.mediaArtworkSlots, animations: passAnimations))
        }
        // 출력(타깃 없는 패스)이 하나도 없으면 화면에 아무것도 못 쓴다 → 폴백.
        guard passes.contains(where: { $0.target == nil }) else { return nil }
        if anyAudio { hasAudio = true }
        NSLog("%@", "[Waple] effect via GLSL→MSL translator: \(eff.name) (passes=\(passes.count)/\(manifest.passes.count) fbos=\(liveFbos.count)/\(manifest.fbos.count) audio=\(anyAudio))")
        // DIRECTDRAW 체인 결과는 premultiplied — 합성서(f_main)가 알파를 한 번 더 곱하지 않도록 표시한다.
        // 코퍼스 전수(460 pkg)에서 DIRECTDRAW 는 lightshafts 41패스/23씬이 전부이고, 전건이
        // ① 이미지 없는 shape:quad 오브젝트의 ② 유일한 이펙트의 ③ 유일한(=출력) 패스이며
        // ④ colorBlendMode=0 ⑤ 비-`_rt_` ⑥ 2D 오르토 씬(camera3D 없음)이다. 그래서 소비처는
        // encodeLayer 의 f_main 분기 하나로 충분하다 — f_compose/f_blend/f_lit/3D 빌보드 경로에는
        // 대응 변형을 두지 않았다(도달 0건). 도달이 생기면 그 경로는 종전 동작으로 남는다(무크래시).
        let specs = liveFbos.enumerated().map { i, f in
            FBOSpec(scale: f.scale, declaredWidth: f.declaredWidth, declaredHeight: f.declaredHeight,
                    fit: f.fit,
                    pixelFormat: fboFormats[i], unique: f.unique, clearColor: f.clearColor)
        }
        // T09-D1: `functions` 를 **fboSpecs 좌표**로 옮겨 둔다(소비는 applyEffect 의 pendingClear 블록).
        //
        // 좌표계가 다르다는 게 핵심이다. `Function.fboIndices` 는 파스가 **원시** `manifest.fbos`
        // 에서 이름을 찾아 넣은 값인데(EffectManifest.parseFunctions — 0x1401e8630–0x1401e867d 의
        // 선형 탐색, 0x1401e8691 에서 그 인덱스를 push), `fboSpecs` 는 X-⑪ 의 `conditions` 필터로
        // **압축된** `liveFbos` 좌표다. 조건으로 빠진 fbo 가 앞쪽에 하나만 있어도 그 뒤 인덱스가
        // 전부 한 칸씩 밀린다 — 동봉 fluidsimulation 은 유일한 조건부 fbo(`_rt_SmokeNormal`,
        // LIGHTING==1)가 배열 **끝**(원시 8)이라 우연히 원시==live 지만, 워크샵 이펙트에서는
        // 그대로 어긋난다. 그래서 원시→live 사상을 지어 옮기고, 조건으로 사라진 fbo 를 가리키던
        // 원소는 **버린다**(존재하지 않는 타깃이라 실물에도 클리어할 대상이 없다).
        //
        // 매니페스트에 `functions` 가 없으면(동봉 128건 중 127건 — 전수 파스 실측) 이 블록이 통째로 안 돌고
        // 표는 빈 채로 남아 프레임 경로가 종전과 같아진다 — `EffectManifest.evaluate` 재호출 비용도
        // 그때는 0이다(빌드 시점 1회이고, 조건 평가는 순수·결정적이라 위 `liveFbos` 필터와 같은 답).
        var functionClears: [String: [Int]] = [:]
        if !manifest.functions.isEmpty {
            var rawToLive = [Int](repeating: -1, count: manifest.fbos.count)
            var liveCursor = 0
            for r in manifest.fbos.indices
            where EffectManifest.evaluate(manifest.fbos[r].conditions, combos: instanceCombos) {
                rawToLive[r] = liveCursor
                liveCursor += 1
            }
            for fn in manifest.functions {
                // 실물은 이름으로 **첫 일치**를 쓴다(0x1401ee3d0–0x1401ee40a). `parseFunctions` 가
                // 사전 키를 도는 터라 이름 중복은 애초에 생길 수 없지만, 표를 덮어쓰지 않아
                // 그 규약을 코드로도 남긴다.
                guard functionClears[fn.name] == nil else { continue }
                let mapped = fn.fboIndices.compactMap { r -> Int? in
                    guard r >= 0, r < rawToLive.count, rawToLive[r] >= 0 else { return nil }
                    return rawToLive[r]
                }
                // 실물은 인덱스가 하나도 없는 항목을 아예 만들지 않는다(0x1401e884a) — 여기서도
                // 조건 탈락으로 전멸한 항목은 표에 넣지 않아 "없는 이름" 과 같은 취급이 되게 한다.
                guard !mapped.isEmpty else { continue }
                functionClears[fn.name] = mapped
            }
        }
        return EffectGPU(pipeline: passes[0].pipeline,
                         bind: .translated(passes: passes, fboSpecs: specs,
                                           uniqueStore: UniqueFBOStore()),
                         outputPremultiplied: outputPremultiplied,
                         functionClears: functionClears)
    }

    /// ① 매니페스트 로드: effect.json 이 없으면 관례 단일 패스("effects/<name>" 셰이더).
    private func loadEffectManifest(_ eff: SceneEffect, package: ScenePackage) -> EffectManifest {
        let effectJSONPath = eff.file.isEmpty ? "effects/\(eff.name)/effect.json" : eff.file
        if let d = quietAssetData(effectJSONPath, package: package), let m = EffectManifest.parse(d) {
            return m
        }
        return EffectManifest(passes: [.init(material: nil, shader: nil, target: nil, binds: [])], fbos: [])
    }

    /// ② 명령 패스(셰이더 없음): "copy" = source fbo → target fbo 지속(실물 motionblur 의 누적 버퍼).
    /// 통과(passthrough) 파이프라인으로 합성해 기존 멀티패스 실행 경로를 그대로 재사용(루프 무변경).
    /// 미해석 이름/파이프라인 실패 → nil(효과 전체 폴백).
    private func makeCopyPass(_ mp: EffectManifest.Pass, effName: String, fboIndex: [String: Int],
                              lw: Float, lh: Float, device: MTLDevice,
                              pixelFormat: MTLPixelFormat = .rgba8Unorm) -> TranslatedPass? {
        // G-A5-04 정책을 명령 패스에도 적용한다. 종전엔 이름 하나만 못 풀어도 nil 을 돌려줬고,
        // 호출부가 그걸 그대로 `return nil` 로 흘려 **이펙트가 통째로 사라졌다**. 원본은 target 을
        // 0xFF(= 효과 출력)로 초기화하고 이름이 맞을 때만 덮어쓰므로 여전히 그린다.
        // `format` 없는 fbo 를 드롭하는 규약이 들어오면서 이 경로의 도달이 실제로 생겼다 —
        // motionblur 의 `_rt_FullCompoBuffer1` 에서 format 만 빠져도 이펙트가 레이어에서 증발했다.
        guard let pipe = passthroughEffectPipeline(device: device, pixelFormat: pixelFormat) else {
            NSLog("%@", "[Waple] copy pass pipeline 생성 실패: \(effName)"); return nil
        }
        let srcIdx = mp.source.flatMap { fboIndex[$0] } ?? -1        // -1 = 효과 입력(previous)
        let tgtIdx = mp.target.flatMap { fboIndex[$0] }              // nil = 효과 출력
        if mp.source != nil, srcIdx < 0 {
            WapleLog.warn("[Waple] copy pass 의 source 를 못 풀었다(\(effName)) — 효과 입력으로 폴백")
        }
        if mp.target != nil, tgtIdx == nil {
            WapleLog.warn("[Waple] copy pass 의 target 을 못 풀었다(\(effName)) — 효과 출력으로 폴백")
        }
        let dims = SIMD4<Float>(lw, lh, lw, lh)
        var wrap = [Float](repeating: 0, count: 8)
        wrap[0] = 1  // slot0 = fbo bind(자산 없음) → 항상 clamp.
        // 명령 패스는 `compose` 를 안 읽는다 — 원본 파서도 command 패스에 같은 키 파스를 태우지만
        // 동봉 자산에 도달 0건이고(compose 보유 2건은 전부 셰이더 패스), false 가 종전 동작이다.
        return TranslatedPass(pipeline: pipe, material: [], aux: [],
                              binds: [(0, srcIdx)], target: tgtIdx, compose: false, usesAudio: false,
                              texRes: [SIMD4<Float>](repeating: dims, count: 8), texWrap: wrap,
                              texFilter: [Float](repeating: 0, count: 8),  // fbo→fbo 복사 — 자산 없음, 선형 고정
                              scripts: [], fullFrameSlots: [], swapPair: nil, mediaArtworkSlots: [], animations: [])
    }

    /// X-②: command:"swap"(셰이더 없음) — source/target fbo 이름을 인덱스로 해석해 포인터 교환만
    /// 예약(draw 없음, makeCopyPass 와 동일 미해석 정책 — 실패 시 효과 전체 폴백). pipeline 은
    /// applyEffect 가 swapPair 를 보고 즉시 continue 하므로 실제로 바인드·드로우되지 않는 placeholder.
    /// 반환 nil 의 의미가 **"이 패스를 생략한다"** 로 바뀌었다(종전: "이펙트 전체 폴백").
    /// 교환할 대상이 없으면 교환을 안 하면 그만이고, 그것 때문에 이펙트를 죽일 이유가 없다.
    private func makeSwapPass(_ mp: EffectManifest.Pass, effName: String, fboIndex: [String: Int],
                              device: MTLDevice) -> TranslatedPass? {
        guard let srcName = mp.source, let srcIdx = fboIndex[srcName],
              let tgtName = mp.target, let tgtIdx = fboIndex[tgtName],
              let pipe = passthroughEffectPipeline(device: device) else {
            WapleLog.warn("[Waple] swap pass 의 대상을 못 풀었다(\(effName)) — 이 패스만 생략")
            return nil
        }
        return TranslatedPass(pipeline: pipe, material: [], aux: [],
                              binds: [], target: nil, compose: false, usesAudio: false,
                              texRes: [SIMD4<Float>](repeating: .zero, count: 8),
                              texWrap: [Float](repeating: 0, count: 8), texFilter: [Float](repeating: 0, count: 8),
                              scripts: [], fullFrameSlots: [], swapPair: (srcIdx, tgtIdx), mediaArtworkSlots: [], animations: [])
    }

    /// ③ 셰이더 이름 + 머티리얼 메타(combos/textures) 해석 — 패스에 shader 가 없으면 material JSON
    /// (passes[0])에서, 그마저 없으면 관례 "effects/<name>".
    private func resolvePassShaderMeta(_ mp: EffectManifest.Pass, eff: SceneEffect,
                                       manifest: EffectManifest, package: ScenePackage,
                                       root: String? = nil)
        -> (base: String, matCombos: [String: Int], matTextures: [String?]) {
        var shaderName = mp.shader
        var matCombos: [String: Int] = [:]
        var matTextures: [String?] = []
        if shaderName == nil, let matPath = mp.material,
           let mData = effectScopedData(matPath, root: root, package: package),
           let mjson = AssetJSON.dictionary(mData),
           let mp0 = (mjson["passes"] as? [Any])?.first as? [String: Any] {
            shaderName = mp0["shader"] as? String
            for (k, v) in (mp0["combos"] as? [String: Any]) ?? [:] {
                if let n = v as? Int { matCombos[k] = n }
                else if let d = v as? Double, let n = safeInt(d) { matCombos[k] = n }
            }
            if let texs = mp0["textures"] as? [Any] { matTextures = texs.map { $0 as? String } }
        }
        // G-B4-08: 관례 폴백의 basename 후보로 `replacementkey` 를 먼저 본다. 동봉 최상위
        // effect.json 46개가 전건 이 키를 갖고 7개가 디렉터리명과 다르다(EffectManifest 주석 참조).
        //
        // **[2026-08-20 근거 정정] 이건 WE 규약이 아니라 우리 휴리스틱이다.** 문자열
        // `replacementkey` 는 `wallpaper64.exe` 에 **ASCII·UTF-16LE 모두 0건**이다(전수 검색).
        // 즉 플레이어는 이 키를 읽지 않는다 — 동봉 자산 68개 파일이 갖고 있으니 **에디터/저작
        // 도구 쪽 키**다. 종전 서술("basename 은 … `replacementkey` 다")은 원본 근거가 없다.
        //
        // 그래도 코드를 그대로 두는 이유: 아래 실재 확인 때문에 **틀릴 수 없는 휴리스틱**이기
        // 때문이다. 셰이더가 실제로 있을 때만 채택하므로 최악이라도 디렉터리명 폴백과 같다.
        // 다만 "WE 가 이렇게 한다" 는 근거로 인용하면 안 된다 — WE 가 실제로 어떻게 관례
        // 폴백의 이름을 정하는지는 **확인 못 했다**(파서가 이 키를 안 읽는다는 것만 확정).
        //
        // 다만 **그 키를 맹신하지 않는다.** 7개 중 6개는 실제 자산명과 맞는데
        // (`watercaustics→caustics` 의 머티리얼이 `caustics.json`, `blurprecise→blur_precise` 가
        // `blur_precise_gaussian_x.json` …) `depthparallax→iris` 하나는 어긋난다 — 그 이펙트의
        // 머티리얼은 `depthparallax.json` 이라, iris 를 복제해 만들고 키를 안 고친 저작 흔적으로
        // 보인다. 그래서 replacementkey 로 만든 경로에 **셰이더가 실재할 때만** 채택하고,
        // 아니면 디렉터리명으로 돌아간다. 폴백은 원래 최후 수단이라 이 한 번의 조회 비용은 무해하다.
        if let shaderName { return (shaderName, matCombos, matTextures) }
        if let key = manifest.replacementKey, key != eff.name,
           effectScopedData("shaders/effects/\(key).frag", root: root, package: package) != nil {
            return ("effects/\(key)", matCombos, matTextures)
        }
        return ("effects/\(eff.name)", matCombos, matTextures)
    }

    /// ④ 콤보 해석. 우선순위: 머티리얼 기본 < scene 패스 지정.
    /// WE 규약: 샘플러 주석의 "combo":"X" 는 그 슬롯에 텍스처가 바인딩되면 자동 활성
    /// (실물 reflection/waterwaves/shake 의 페인트 마스크 — 미적용 시 마스크 무시 = 전화면 적용 사고).
    /// WE `.tex-json` 의 `format` 문자열 → `.tex` 헤더 format 필드(= `shaders/common_fragment.h` 의
    /// `FORMAT_*` 값). **동봉 자산에서 짝지어 실측한 표다** — 이름에서 유추하지 않았다.
    /// 동봉 트리 `*.tex-json` 과 같은 이름의 `*.tex`(매직 `TEXV0005`, format = 오프셋 18 의 u32) 272쌍:
    ///
    ///     rgba8888 →0(130쌍) · r8 →9(60) · rg88 →8(50) · rgba8888n →0(19)
    ///     dxt5n →4(4) · dxt5 →4(4) · rgb888 →**0**(4) · rg88n →8(1)
    ///
    /// 두 가지가 이름 기반 유추와 다르다:
    ///   · `n` 접미(노멀맵 표기)는 코드를 **바꾸지 않는다** — rgba8888n·dxt5n·rg88n 이 각각 베이스와 같다.
    ///   · `rgb888` 은 `FORMAT_RGB888(1)` 이 아니라 **0(RGBA8888)** 으로 컴파일된다. 24비트 GPU
    ///     포맷이 없어 리소스컴파일러가 디스크에서 RGBA8 로 편다.
    ///
    /// 이 표는 `scripts/spec/check_tex_format_map.py` 가 매 CI 마다 동봉 자산에서 다시 측정해 대조한다.
    private static let texJSONFormatCodes: [String: Int] = [
        "rgba8888": 0, "rgba8888n": 0, "rgb888": 0,
        "dxt5": 4, "dxt5n": 4,
        "rg88": 8, "rg88n": 8,
        "r8": 9,
    ]

    /// `formatcombo` 슬롯의 `TEXnFORMAT` 값 — **컴파일된 `.tex` 가 없어 소스 폼(.png)으로 해석되는
    /// 텍스처에만** 준다. `.tex` 가 하나라도 잡히면 nil 이다.
    ///
    /// 왜 `.tex` 를 일부러 제외하는가. Waple 의 `TexDecoder._decodeMip` 은 GPU 네이티브 포맷을 올리지
    /// 않고 **전부 CPU 에서 RGBA8 로 편다**. 그때 채널 배치를 이미 WE 셰이더의 *변환 후* 모양으로
    /// 맞춰 둔다(TexDecoder.swift:228-282):
    ///
    ///     r8(9)  → (v,v,v,v)        `ConvertTexture0Format` 의 `vec4(1,1,1,.r)` 과 같은 자리에 값이 온다
    ///     rg88(8)→ (b0,b0,b0,b1)    `.rrrg` 를 **디코드가 이미 적용**한 모양이다
    ///
    /// 그래서 `.tex` 로 온 rg88/r8 에 `TEXnFORMAT` 을 심으면 셰이더가 **변환을 두 번** 건다
    /// (`ConvertTexture0Format((b0,b0,b0,b1))` → `.rrrg` → `(b0,b0,b0,b0)`, 알파 소실).
    /// 지금의 "정의 없음 = 0" 이 그 경로에선 **맞는** 값이다.
    ///
    /// 소스 폼은 사정이 다르다. `.tex` 가 없으면 Waple 은 짝인 `.png` 를 그대로 디코드하므로 버퍼에
    /// 진짜 (R,G,B,A) 가 들어온다 — `.tex-json` 이 `rg88*` 이라고 적은 텍스처면 R·G 가 실제로 그 두
    /// 채널이고, 이때 `DecompressNormal` 의 `rg` 분기가 정확히 맞는다.
    private func sourceFormTexFormatCode(_ name: String, root: String?, package: ScenePackage) -> Int? {
        let base = name.hasSuffix(".tex") ? [name] : ["materials/\(name).tex", name]
        let texCandidates = SceneRenderer.effectLocalTextureCandidates(base).filter { $0.hasSuffix(".tex") }
        // 컴파일본이 하나라도 잡히면 위 이유로 손대지 않는다.
        for c in texCandidates where effectScopedData(c, root: root, package: package) != nil { return nil }
        for c in texCandidates {
            guard let d = effectScopedData(String(c.dropLast(4)) + ".tex-json", root: root, package: package),
                  let obj = AssetJSON.dictionary(d),
                  let fmt = obj["format"] as? String else { continue }
            return Self.texJSONFormatCodes[fmt.lowercased()]
        }
        return nil
    }

    private func resolvePassCombos(vert: String, frag: String, scenePass: SceneEffectPass,
                                   matCombos: [String: Int], matTextures: [String?],
                                   effectRoot: String?, package: ScenePackage) -> [String: Int] {
        // G-A3-1: 저작 콤보 키의 **대소문자가 선언과 다를 수 있다.**
        // 실측(동봉 WEAssets + WE 설치본 씬 전수):
        //  · 셰이더 `[COMBO]` 선언 이름은 **82종 전부 대문자**(소문자·혼합 0종).
        //  · 그런데 씬이 저작하는 콤보 키는 66종 중 **15종이 소문자**이고 그 사용이 **56회**다
        //    (`paintwork` `normalmap` `lightmap` `reflection` `spritesheet` `metal` `selfillum` …).
        // 즉 WE 는 대소문자를 무시하고 맞춘다. 종전의 정확일치 조회는 그 56회를 통째로 놓쳐
        // 선언 기본값(대개 0)으로 굳혔다 — WE 자기 배경 `fantasticcar` 가 `"paintwork":1` 로
        // 저작하는데 셰이더는 `#ifdef PAINTWORK` 라서 **차체가 칠해지지 않는다**.
        //
        // 규약: **정확일치 우선**, 없을 때만 선언 이름 집합에서 대소문자 무시로 찾아 그 철자로
        // 정규화한다. 이러면 (a) 기존 대문자 저작은 비트동일이고 (b) 혼합 케이스 선언(워크샵
        // 셰이더에 있을 수 있다 — 동봉 자산엔 0종)도 자기 철자로 정확히 맞는다.
        let declared = ShaderPreprocessor.parseComboDefaults(vert)
            .merging(ShaderPreprocessor.parseComboDefaults(frag), uniquingKeysWith: { a, _ in a })
        var canonicalByLowercased: [String: String] = [:]
        for name in declared.keys where canonicalByLowercased[name.lowercased()] == nil {
            canonicalByLowercased[name.lowercased()] = name
        }
        func canonical(_ key: String) -> String {
            if declared[key] != nil { return key }                 // 정확일치 우선
            return canonicalByLowercased[key.lowercased()] ?? key  // 선언에 없으면 원문 보존
        }
        var combos: [String: Int] = [:]
        for (k, v) in matCombos { combos[canonical(k)] = v }
        for (k, v) in scenePass.combos { combos[canonical(k)] = v }
        for (slot, comboName) in GLSLTranslator.samplerCombos(frag) where combos[comboName] == nil {
            let sceneBound = slot < scenePass.textureNames.count && scenePass.textureNames[slot] != nil
            let matBound = slot < matTextures.count && matTextures[slot] != nil
            if sceneBound || matBound { combos[comboName] = 1 }
        }
        // **[2026-08-20] `TEXnFORMAT` 을 심는다 — 종전엔 아무도 정의하지 않아 항상 0 이었다.**
        //
        // `common_fragment.h` 의 `DecompressNormal` 은 노멀 언팩을 텍스처 **포맷**으로 가른다:
        //     #if TEX1FORMAT == FORMAT_RG88   normal.xy = normal.rg * 2 - 1
        //     #else                           normal.xy = normal.wy * 2 - 1
        //
        // 정의가 없으면 전처리기가 0 을 주므로 항상 else 분기다. `effects/refraction` 의 노멀맵은
        // `.tex` 가 없고 소스 `refractnormal.png` 가 **알파 없는 RGB**(256×256 colorType 2 실측)라
        // `normal.w` 가 1.0 상수다 → `normal.x = 1·2−1 = 1`, `normal.z = sqrt(saturate(1−1−y²)) = 0`.
        // 굴절 무늬의 x 성분이 통째로 죽고 전화면 균일 가로 시프트가 된다. 짝인 `.tex-json` 이
        // `"format":"rg88n"`(→ 코드 8 = FORMAT_RG88)이라 그 값을 심으면 `rg` 분기로 (R,G) 를 읽는다.
        //
        // 슬롯 판정은 반드시 `formatComboSlots`(`"formatcombo":true`)여야 한다. `samplerCombos` 의
        // `"combo"` 로는 **정작 refract.frag:8 이 안 걸린다** — 그 줄엔 `"combo"` 가 없다.
        //
        // `code != 0` 으로 거르는 이유: 0 은 미정의와 같은 값이라 심어도 그림이 안 변하는데 콤보 키가
        // 늘면 파이프라인 변형 캐시 키만 갈라진다. 동봉 전수 기준 실제로 값이 붙는 자리는
        // refraction 슬롯 1 **한 곳뿐**이다(lightshafts 슬롯 2 의 `gradient_iridescent` 는 rgba8888=0,
        // waterripple/waterflow 는 `formatcombo` 자체가 없다).
        for slot in GLSLTranslator.formatComboSlots(frag).sorted() {
            let key = "TEX\(slot)FORMAT"
            guard combos[key] == nil else { continue }
            let bound = (slot < scenePass.textureNames.count ? scenePass.textureNames[slot] : nil)
                ?? (slot < matTextures.count ? matTextures[slot] : nil)
            guard let bound, !bound.isEmpty,
                  let code = sourceFormTexFormatCode(bound, root: effectRoot, package: package),
                  code != 0 else { continue }
            combos[key] = code
        }
        return combos
    }

    /// ⑤a 머티리얼 상수 벡터 + 상수 프로퍼티 스크립트 엔진(시간 함수 → 연속 렌더 필요 마킹) + X-⑦
    /// 상수 키프레임 애니메이션(동일 이유로 연속 렌더 필요).
    /// scriptWrites(G-C4-01): 이 패스에 대해 이펙트 스크립트가 thisObject 로 쓴 상수(authored 값을 덮는다).
    private func buildPassMaterial(_ t: TranslatedShader, scenePass: SceneEffectPass,
                                   scriptWrites: [String: [Float]] = [:])
        -> (material: [SIMD4<Float>], scripts: [(slot: Int, engine: TextScriptEngine)],
            animations: [(slot: Int, anim: PropertyAnimation)]) {
        let constants = scenePass.constants
        let resolved: (MaterialParam) -> [Float] = { p in
            scriptWrites[p.sceneKey] ?? constants[p.sceneKey] ?? p.defaultValue
        }
        var material: [SIMD4<Float>] = t.materialParams.map { p in
            let v = resolved(p)
            return SIMD4<Float>(v.count > 0 ? v[0] : 0, v.count > 1 ? v[1] : 0,
                                v.count > 2 ? v[2] : 0, v.count > 3 ? v[3] : 0)
        }
        var passScripts: [(slot: Int, engine: TextScriptEngine)] = []
        var passAnimations: [(slot: Int, anim: PropertyAnimation)] = []
        // G-C4-01: 패스 상수에 붙은 스크립트의 `thisObject` 는 **이 패스의 머티리얼**(IMaterial)이다 —
        // 실물 razer_vortex 3건이 `thisObject.colormode = parseInt(userProperties…)` 로 쓴다. 종전엔
        // thisObject 가 thisLayer 라 그 값이 남의 레이어 심에 조용히 얹히고 셰이더엔 닿지 않았다.
        // 씨앗은 슬롯 현재값 **전체** — WE 계약상 스크립트는 자기 상수만이 아니라 머티리얼 전체를 본다.
        var seed: [String: [Float]] = [:]
        var slotOfKey: [String: Int] = [:]
        for (slot, p) in t.materialParams.enumerated() {
            seed[p.sceneKey] = resolved(p)
            slotOfKey[p.sceneKey] = slot
        }
        for (slot, p) in t.materialParams.enumerated() {
            if let src = scenePass.constantScripts[p.sceneKey],
               let engine = makeScriptEngine(src, scriptPropsJSON: scenePass.constantScriptProps[p.sceneKey],
                                             owner: .material(constants: seed)) {
                passScripts.append((slot, engine))
                if engine.hasUpdate { hasAnimations = true }  // 스크립트 상수는 시간 함수 — 연속 렌더 필요
                // 값이 씨앗 그대로면 스크립트가 안 쓴 것 — 건너뛴다. update 로만 동작하는 상수 스크립트
                // (실물 razer_bedroom 무지개 6건)는 여기서 아무 일도 일어나지 않는다(무회귀).
                for (key, comps) in engine.boundObjectMaterialWrites.first ?? [:] where seed[key] != comps {
                    guard let target = slotOfKey[key] else { continue }
                    var v = material[target]
                    for (c, f) in comps.prefix(4).enumerated() { v[c] = f }
                    material[target] = v
                }
            }
            if let anim = scenePass.constantAnimations[p.sceneKey] {
                passAnimations.append((slot, anim))
                hasAnimations = true  // X-⑦: 키프레임 상수도 시간 함수 — 연속 렌더 필요
            }
        }
        return (material, passScripts, passAnimations)
    }

    /// ⑤b 바인드/texRes/aux/target 플랜. 미지 바인드·타깃 이름 → nil(효과 전체 폴백).
    /// 바인드: previous → -1, 이름 → fbo 인덱스. 부재 시 관례 previous@0.
    /// texRes + 정적 aux: 바인드 슬롯은 소스 dims(fbo = 레이어/scale), 그 외 선언 슬롯은 텍스처 해석.
    /// WE 규약: g_TextureXResolution = (paddedW, paddedH, imageW, imageH) — .zw 는 역수가 아니라 실치수
    /// (gaussian 등이 g_Scale/…Resolution.z 로 텍셀 오프셋 계산; 역수면 오프셋 폭주 → 화면 백화).
    private func buildPassBindings(_ mp: EffectManifest.Pass, effName: String, translation t: TranslatedShader,
                                   scenePass: SceneEffectPass, matTextures: [String?],
                                   manifest: EffectManifest, fbos: [EffectManifest.FBO], fboIndex: [String: Int],
                                   lw: Float, lh: Float, package: ScenePackage, device: MTLDevice,
                                   compositeImageTextures: [Int: String] = [:],
                                   baseNoInterp: Bool = false, root: String? = nil,
                                   instanceCombos: [String: Int] = [:])
        -> (binds: [(slot: Int, source: Int)], texRes: [SIMD4<Float>], aux: [(slot: Int, tex: MTLTexture)],
            texWrap: [Float], texFilter: [Float], target: Int?, fullFrameSlots: [Int],
            mediaArtworkSlots: [(slot: Int, previous: Bool)])? {
        var binds: [(slot: Int, source: Int)] = []
        for b in mp.binds {
            // X-⑪: bind 조건이 거짓이면 **그 슬롯만 언바인드**되고 패스는 정상 실행된다.
            // 슬롯 번호가 JSON 에 명시돼 있으므로 다른 바인드의 슬롯이 밀리지 않는다.
            guard EffectManifest.evaluate(b.conditions, combos: instanceCombos) else {
                NSLog("%@", "[Waple] conditions: \(effName) bind 슬롯 \(b.index) 비활성")
                continue
            }
            // 신뢰불가 effect.json index — Metal frag 텍스처 인자테이블 상한(macOS 128) 밖이면
            // setFragmentTexture assertion 크래시. 미지 바인드와 동일하게 효과 전체 폴백.
            guard (0..<128).contains(b.index) else {
                NSLog("%@", "[Waple] bind index oob \(b.index) in \(effName)"); return nil
            }
            // G-A5-04: WE 는 미지 이름에 **이펙트를 버리지 않는다**. effect.json 파서
            // (원본 0x1401e7170)가 bind 소스를 `0xffffffff`(= −1, 이펙트 입력)로 초기화하고
            // (0x1401e7eef) `fbos[]` 이름 선형 탐색에 **일치했을 때만** 덮어쓴다(0x1401e7f81).
            // 그리고 원본 바이너리 전체에 `"previous"` 리터럴이 없다(ASCII 1건은
            // `"#base: disabled by previous error"` 안, UTF-16LE 0건) — 즉 WE 의 규약은
            // "previous 라는 이름"이 아니라 "**fbos[] 에 없는 이름은 전부 −1**" 이다.
            // 종전처럼 드롭하면 이름 하나 틀린 워크샵 effect.json 에서 WE 는 (약간 틀리게라도)
            // 그리고 Waple 은 이펙트가 통째로 사라진다. 진단 가치는 로그로 남긴다.
            if let idx = fboIndex[b.name] { binds.append((b.index, idx)) }
            else {
                if b.name != "previous" { NSLog("%@", "[Waple] unknown bind '\(b.name)' in \(effName) — 이펙트 입력(-1)으로 폴백") }
                binds.append((b.index, -1))
            }
        }
        if binds.isEmpty { binds = [(0, -1)] }
        let bindSlots = Set(binds.map { $0.slot })
        var texRes = [SIMD4<Float>](repeating: SIMD4(lw, lh, lw, lh), count: 8)
        // F162/F163: bind(fbo/previous) 슬롯은 TexImage 가 없는 파이프라인-내부 렌더타깃 — 항상 clamp
        // (콘텐츠 경계 밖 랩은 아티팩트, W4a 실측). aux(실 자산) 슬롯은 아래에서 TexImage.clampUVs 로 채운다.
        var texWrap = [Float](repeating: 0, count: 8)
        for (slot, source) in binds where slot < 8 && source >= 0 {
            let fbo = fbos[source]
            // W-FIT(2026-08-21): `fit` 은 정사각이 아니라 "긴 변을 N 으로, 종횡비 보존, 확대 금지" 다
            // (`EffectManifest.FBO.fittedBox` — 원본 `0x1401eb2cc`–`0x1401eb381`). 이 슬롯의
            // `g_TextureNResolution` 이 곧 셰이더의 `aspect = res.y/res.x` 와 `texelSize` 라,
            // 여기서 정사각을 실으면 유체 시뮬의 중력·염료 에미터·커서 반경이 전부 어긋난다.
            //
            // `fit` **미선언 FBO 는 아래 두 갈래 종전 그대로** 둔다 — 특히 scale 갈래의 나눗셈은
            // 정수 바닥이 아니라 부동소수(`lh/s`)라, 여기서 정수화하면 dst 가 scale 로 나누어
            // 떨어지지 않는 모든 씬에서 값이 움직인다(무회귀 규약).
            // 베이스는 이 함수의 인자 `lw`/`lh`(= 호출부 `Float(max(1, texW))`, 1214 위 727행) 다.
            // `texW`/`texH` 라는 이름은 이 스코프에 **없다** — 여긴 Metal 전용이라 CI 밖에서는
            // `swiftc -parse` 만 돌아 타입체크가 안 되고, 그래서 990aa2a 가 macOS 빌드를 깼다.
            // `Int(exactly:)` 로 받는다 — `Int(Float)` 는 범위를 넘으면 클램프가 아니라 **트랩**이고
            // (check_int_narrowing 게이트가 이 총수를 감시한다), `lw`/`lh` 는 위 727행에서
            // `Float(max(1, texW))` 로 만들어진 정수값이라 `exactly:` 는 실측상 항상 성공한다.
            // 실패(비정수·범위 초과)하면 1 로 떨어져 `fittedBox` 의 `max(4, ·)` 하한이 받는다.
            if let box = fbo.fittedBox(baseWidth: Int(exactly: lw) ?? 1, baseHeight: Int(exactly: lh) ?? 1) {
                let fw = Float(box.width), fh = Float(box.height)
                texRes[slot] = SIMD4(fw, fh, fw, fh)
            } else if let fw = fbo.fixedWidth, let fh = fbo.fixedHeight {
                texRes[slot] = SIMD4(Float(fw), Float(fh), Float(fw), Float(fh))
            } else {
                let s = Float(fbo.scale)
                texRes[slot] = SIMD4(lw / s, lh / s, lw / s, lh / s)
            }
        }
        for slot in bindSlots where slot < 8 { texWrap[slot] = 1 }
        // X-①: `uvs:"repeat"` FBO(실물 glitter `_rt_GlitterTiles` 타일 아틀라스)를 소스로 삼는 bind 슬롯은
        // 위의 기본 clamp 를 repeat 로 재정의.
        for (slot, source) in binds where slot < 8 && source >= 0 && fbos[source].uvsRepeat {
            texWrap[slot] = 0
        }
        // 감사 V07: 슬롯별 샘플 필터(1=nearest/0=linear — TexImage.noInterpolation, WE tex Flags bit0).
        // previous(bind -1) 슬롯은 baseNoInterp(체인 첫 이펙트의 베이스 직결 — applyEffect 가 previous 를
        // 항상 효과 입력 src 로 바인드)일 때만 nearest, fbo bind 슬롯은 선형(FBO 출력 — 손-포팅 fbNearest
        // 의 V06 정합과 동일). aux 슬롯은 아래에서 자산 플래그로 채운다.
        var texFilter = [Float](repeating: 0, count: 8)
        if baseNoInterp {
            for (slot, source) in binds where slot < 8 && source == -1 { texFilter[slot] = 1 }
        }
        var aux: [(slot: Int, tex: MTLTexture)] = []
        var fullFrameSlots: [Int] = []
        var mediaArtworkSlots: [(slot: Int, previous: Bool)] = []
        for slot in t.textureSlots where slot > 0 && slot < 128 && !bindSlots.contains(slot) {
            // X-③: usertextures 의 시스템 키($mediaThumbnail/$mediaPreviousThumbnail, 47씬/268슬롯) —
            // 유저 키(비-시스템)는 이미 파스 시점에 textureNames 로 병합됐다(SceneDocument.parseEffects
            // usertextures 루프) — 여기서는 라이브 미디어 폴링이 필요한 동적 슬롯만 별도 기록해
            // draw 시점(applyEffect)에 SceneRenderer.mediaArtworkTexture 로 덮어쓴다(fullFrameSlots 와
            // 동일 패턴 — 빌드 시점엔 흰색 1×1 로 무회귀 유지).
            if slot < scenePass.userTextureNames.count, let uk = scenePass.userTextureNames[slot] {
                if uk == "$mediaThumbnail" { mediaArtworkSlots.append((slot, false)) }
                else if uk == "$mediaPreviousThumbnail" { mediaArtworkSlots.append((slot, true)) }
            }
            var name = slot < scenePass.textureNames.count ? scenePass.textureNames[slot] : nil
            if name == nil, slot < matTextures.count { name = matTextures[slot] }
            // F-X4: 씬/머티리얼 어느 쪽도 슬롯을 지정하지 않으면 셰이더 샘플러 주석의
            // `"default":"경로"`(WE 관례: util/noise, pattern/voronoi_local, _rt_FullFrameBuffer 등)로
            // 폴백 — 종전엔 이 어노테이션이 통째로 버려져 흰색 1×1 이 됐다(패턴/노이즈 기반 이펙트 왜곡).
            if name == nil { name = t.textureDefaults[slot] }
            // F720: `_rt_imageLayerComposite_<id>` = 참조 레이어의 런타임 컴포지트 RTT. 종전엔 `_rt_` 접두어
            // 슬롯을 continue 로 스킵해 해당 샘플러가 영구 미바인드(Metal 검증 실패/미정의 읽기 + blend/
            // clipping_mask 콘텐츠 소실). 3D 경로(SceneRenderer3D.loadMesh3DMaterial)와 동일한 정적 치환:
            // 참조 레이어의 베이스 이미지 텍스처로 대체하고, 해석 불가(id 미상/기타 _rt_)는 nil 로 둬
            // resolveTexture 의 흰색 1×1 폴터가 바인드를 보장하게 한다(미바인드 방지가 우선 — 오역보다 폴터).
            // F-X4: `_rt_FullFrameBuffer`(godrays/shine 의 COPYBG 콤보 등) 는 씬 컬러 스냅샷이 필요한
            // **동적** 슬롯이라 정적 치환 불가 — 슬롯 번호만 기록해 draw 시점(applyEffect) 에 실제 스냅샷을
            // 가진 호출부가 있으면 덮어쓴다. 빌드 시점엔 흰색 1×1 로 채워 무회귀 유지(폴백 없으면 백색 합성).
            if let n = name, n.hasPrefix("_rt_") {
                name = nil
                if n.hasPrefix("_rt_imageLayerComposite_") {
                    let digits = n.dropFirst("_rt_imageLayerComposite_".count).prefix { $0.isNumber }
                    if let layerID = Int(digits) { name = compositeImageTextures[layerID] }
                } else if n == "_rt_FullFrameBuffer" {
                    fullFrameSlots.append(slot)
                }
            }
            // F1: 이 슬롯 이름은 **이펙트-로컬** 이름이다 — 셋 다(씬 패스 오버라이드 · 머티리얼 json
            // `textures[]` · 셰이더 샘플러 주석 `"default"`) 이펙트 루트 기준 상대 경로다. 셰이더와
            // 머티리얼은 이미 `effectScopedData` 로 그 루트를 보는데 텍스처만 전역 조회라 이펙트가
            // 자기 자산을 못 찾았다. 동봉 자산 실측(2026-08-20): 최상위 이펙트 머티리얼이 참조하는
            // 텍스처는 전부 3건인데 **3건 전부** 팩 루트에서 미해석 → 흰색 1×1 폴백이었다
            // (refraction/refractnormal · waterflow/waterflowphase · waterripple/waterripplenormal).
            // `root` 는 전역 미스 뒤에만 쓰이므로 순수 가산이다.
            if let tex = resolveTexture(name, package: package, device: device, root: root) {
                aux.append((slot, tex))
                if slot < 8 {
                    let w = Float(max(1, tex.width)), h = Float(max(1, tex.height))
                    texRes[slot] = SIMD4(w, h, w, h)
                    texWrap[slot] = resolveTextureClampUVs(name, package: package, root: root) ? 1 : 0
                    texFilter[slot] = resolveTextureNoInterpolation(name, package: package, root: root) ? 1 : 0  // 감사 V07
                }
            }
        }
        // G-A5-04: 미지 target 도 마찬가지다. WE 는 target 인덱스를 `0xFF`(= 타깃 없음 =
        // 이펙트 출력에 직접 기록)로 초기화하고(0x1401e7a99) 이름이 맞을 때만 덮어쓴다.
        let target: Int? = mp.target.flatMap { fboIndex[$0] }
        if mp.target != nil, target == nil {
            NSLog("%@", "[Waple] unknown target '\(mp.target ?? "")' in \(effName) — 이펙트 출력으로 폴백")
        }
        return (binds, texRes, aux, texWrap, texFilter, target, fullFrameSlots, mediaArtworkSlots)
    }

    /// F162/F163: 텍스처 자산의 ClampUVs 헤더 플래그(TexImage.swift:126, WE tex Flags bit0x2)만 저비용
    /// 조회 — 헤더만 재파스(디코드 없음, 씬 빌드 1 회성이라 무해). 실패/부재는 false(=repeat, WE 기본 어드레싱).
    /// P⑥: internal 로 완화(기존 private) — SceneRenderer3D.buildCustomMeshShader 가 2D buildCustomLayerShader
    /// 와 동형의 aux 텍스처 wrap/filter 산출에 재사용(다른 파일의 같은 타입 extension이라 private 미접근).
    /// F1: `root` 를 주면 전역 미스 뒤에 이펙트-로컬 루트도 본다(기본 nil = 종전 동작 그대로).
    func resolveTextureClampUVs(_ name: String?, package: ScenePackage, root: String? = nil) -> Bool {
        guard let name else { return false }
        let candidates = name.hasSuffix(".tex") ? [name] : ["materials/\(name).tex", name]
        for c in candidates {
            if let d = quietAssetData(c, package: package), let tex = TexImage.parse(d) { return tex.clampUVs }
        }
        // F1: **전역이 전부 빗나간 뒤에만** 이펙트-로컬을 본다. 소스 폼(.png)은 TEXV0005 헤더가 없어
        // `TexImage.parse` 가 nil → 루프를 그냥 지나가고 종전대로 false 다. 실측상 그게 맞다 —
        // 이 3건의 `.tex-json` 은 `{"format","nomip"}` 뿐이라 `clampuvs`/`nointerpolation` 키가 없고,
        // 그건 WE 기본(repeat/linear)과 같다.
        if root?.isEmpty == false {
            for c in SceneRenderer.effectLocalTextureCandidates(candidates) {
                if let d = effectScopedData(c, root: root, package: package),
                   let tex = TexImage.parse(d) { return tex.clampUVs }
            }
        }
        return false
    }

    /// 감사 V06: 텍스처 자산의 NoInterpolation 헤더 플래그(TexImage.swift:126, WE tex Flags bit0x1)만 저비용
    /// 조회 — 헤더만 재파스(resolveTextureClampUVs 와 동일 패턴). 실패/부재는 false(=linear, WE 기본 필터).
    /// F1: `root` 규약은 `resolveTextureClampUVs` 와 동일(기본 nil = 종전 동작 그대로).
    func resolveTextureNoInterpolation(_ name: String?, package: ScenePackage, root: String? = nil) -> Bool {
        guard let name else { return false }
        let candidates = name.hasSuffix(".tex") ? [name] : ["materials/\(name).tex", name]
        for c in candidates {
            if let d = quietAssetData(c, package: package), let tex = TexImage.parse(d) { return tex.noInterpolation }
        }
        if root?.isEmpty == false {
            for c in SceneRenderer.effectLocalTextureCandidates(candidates) {
                if let d = effectScopedData(c, root: root, package: package),
                   let tex = TexImage.parse(d) { return tex.noInterpolation }
            }
        }
        return false
    }

    /// F722: 레이어의 머티리얼이 시스템 미디어 텍스처($mediaThumbnail/$mediaPreviousThumbnail)를 요청하는지
    /// 감지. 파서가 해석한 textureEntryName("materials/X.tex")과 같은 basename 의 머티리얼 json("materials/X.json")을
    /// 다시 읽어 passes[0].usertextures 의 시스템 키(문자열 또는 {name,type:"system"})를 찾는다 — 파스 계층이
    /// 시스템 키를 userProps 에서 조회해 실패로 끝난 뒤라(실측 12wp 의 Album Cover 머티리얼) 렌더 측 재판독이 필요.
    /// 감지 실패(무 json/무 usertextures)는 .none — 대부분의 레이어, 기존 정적 텍스처 그대로(무회귀).
    func mediaArtworkKind(textureEntryName: String, package: ScenePackage) -> SceneRenderer.MediaArtworkKind {
        guard textureEntryName.hasSuffix(".tex") else { return .none }
        let jsonName = String(textureEntryName.dropLast(4)) + ".json"
        guard let d = quietAssetData(jsonName, package: package),
              let m = AssetJSON.dictionary(d),
              let passes = m["passes"] as? [Any],
              let p0 = passes.first as? [String: Any],
              let userTextures = p0["usertextures"] as? [Any] else { return .none }
        var found: SceneRenderer.MediaArtworkKind = .none
        for raw in userTextures {
            let key = (raw as? String) ?? ((raw as? [String: Any])?["name"] as? String)
            if key == "$mediaThumbnail" { found = .current }
            else if key == "$mediaPreviousThumbnail", found == .none { found = .previous }
        }
        return found
    }

    /// F722: 미디어 아트워크 원본 바이트(JPEG/PNG — MediaPoller 공급) → RGBA8 텍스처.
    /// 디코드 실패 시 nil(호출부는 이전 텍스처/placeholder 유지). bitmapRGBAFile 과 동일 디코드 규약.
    func decodeArtworkTexture(_ data: Data, device: MTLDevice) -> MTLTexture? {
        guard let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else { return nil }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return makeTexture(Data(pixels), width, height, device)
    }

    /// assetData 의 조용한 버전: pkg→베이스에셋 조회하되 미스에 로그 없음(소스 프로브는 미스가 정상).
    /// X-⑨(G-B2-08/G-B4-01): **이펙트-로컬 자산 루트**를 먼저 보고, 없으면 종전대로 팩 루트로 간다.
    ///
    /// 동봉 자산 실측: 스톡 이펙트 `effects/<name>/` **46/46 전건**이 자기 `shaders/` 와
    /// `materials/` 를 갖는다. 그리고 팩 루트에는 `shaders/effects/` 디렉터리가 **아예 없다**.
    /// 그런데 매니페스트·머티리얼이 적는 경로는 그 로컬 루트 기준의 상대 경로다:
    ///
    ///     effects/fluidsimulation/effect.json  → "material": "materials/effects/fluidsimulation_advection.json"
    ///     …/materials/effects/fluidsimulation_advection.json → "shader": "effects/fluidsimulation_advection"
    ///     실물 위치: effects/fluidsimulation/shaders/effects/fluidsimulation_advection.frag
    ///
    /// 종전엔 팩 루트에서만 찾아서 이 46종이 **전건 해석 불가**였다(번들에 들어 있는데 사장).
    /// 포맷/지속을 고쳐도 셰이더 자체를 못 찾으면 유체는 여전히 안 돈다 — 같은 묶음인 이유다.
    ///
    /// 루트 우선이 안전한 이유: 폴백이 종전 경로 그대로라 워크샵 pkg(자기 루트 없이 팩 루트에
    /// 셰이더를 싣는 형태)는 무회귀다. 로컬 루트에 자산이 있으면 그건 저작자가 그 이펙트용으로
    /// 실은 것이므로 우선하는 게 맞다(자기 `common.h` 를 싣는 경우 포함).
    func effectScopedData(_ name: String, root: String?, package: ScenePackage) -> Data? {
        let scoped: String? = (root?.isEmpty == false) ? "\(root!)/\(name)" : nil
        // **조회 순서가 이 함수의 전부다.** 씬 pkg 가 베이스 자산을 **항상** 이기고,
        // 각 출처 안에서만 이펙트-로컬 루트가 팩 루트보다 앞선다.
        //
        //   ① pkg  : <root>/<name>      ② pkg  : <name>
        //   ③ base : <root>/<name>      ④ base : <name>
        //
        // 처음엔 `quietAssetData(<root>/<name>)` → `quietAssetData(<name>)` 로 썼는데 **틀렸다.**
        // `quietAssetData` 자체가 pkg→base 순으로 훑기 때문에, ①이 pkg 에서 빗나가면 곧장 base 의
        // ③을 집어 pkg 의 ②를 영원히 가린다. 실제로 그 순간 워크샵 pkg 가 자기 `shaders/effects/
        // opacity.frag` 를 실어도 **동봉 스톡 opacity 셰이더가 이겼다**(회귀 테스트
        // `testShippedGLSLWinsOverHandPort` 가 이걸 잡았다). 씬이 실어 보낸 자산을 번들 자산이
        // 덮는 것은 어떤 경우에도 옳지 않다.
        if let s = scoped, let d = packageData(s, package: package) { return d }
        if let d = packageData(name, package: package) { return d }
        // 베이스 자산은 **루트별로** 훑는다. `baseAssetData(scoped)` 를 전 루트에 대해 먼저 돌리면
        // 동봉본의 `<root>/<name>` 이 사용자 설치본의 `<name>` 을 이겨서, `assetBaseRoots` 가
        // 명시한 우선순위(사용자 설치본 → 동봉본)가 뒤집힌다.
        for base in assetBaseRoots {
            // 스코프 경로가 `.rejected`(경로 이탈)여도 평문 조회는 막지 않는다 — 루트 문자열이
            // 이상한 것과 자산 이름이 이상한 것은 다른 문제다.
            if let s = scoped, case .url(let u) = baseAssetURLProbe(for: s, root: base),
               let d = try? Data(contentsOf: u) { return d }
            switch baseAssetURLProbe(for: name, root: base) {
            case .url(let u):
                if let d = try? Data(contentsOf: u) { return d }
            case .rejected:
                return nil          // 이름 자체가 이탈 — 다음 루트에서 성공하면 안 된다
            case .missing:
                break
            }
        }
        return nil
    }

    /// `quietAssetData` 의 **베이스 루트 부분만** — pkg 조회는 하지 않는다.
    /// `effectScopedData` 가 pkg/base 우선순위를 직접 엮으려면 두 단계가 분리돼 있어야 한다.
    func baseAssetData(_ name: String) -> Data? {
        // 다중 루트(사용자 설치본 → 동봉본). `.rejected` 는 즉시 nil — 경로 이탈을 다음 루트로
        // 흘려보내면 거기서 성공할 수 있다(probeAssetData·sharedAssetProbe 와 같은 규약).
        for base in assetBaseRoots {
            switch baseAssetURLProbe(for: name, root: base) {
            case .url(let url):
                if let d = try? Data(contentsOf: url) { return d }
            case .rejected:
                return nil
            case .missing:
                break
            }
        }
        return nil
    }

    /// 이펙트가 자기 자산을 두는 루트 = `effect.json` 이 있는 디렉터리.
    /// `eff.file` 이 명시되면 그 부모, 아니면 관례 `effects/<name>`.
    static func effectLocalRoot(_ eff: SceneEffect) -> String? {
        if !eff.file.isEmpty {
            // **백슬래시를 먼저 정규화한다.** `eff.file` 은 scene.json 원문 그대로이고
            // (`SceneDocument.parseEffects` 는 정규화하지 않는다), 인접 두 계층은 이미 정규화한다 —
            // `WallpaperPathSecurity.normalizedRelativePath` 와 `ScenePackage.normalizedLookupKey`
            // 둘 다 `\` → `/` 치환을 한다. 그래서 `"effects\fluidsimulation\effect.json"` 인 씬은
            // **매니페스트는 정상 로드되는데 루트만 nil** 이 되어, 18개 셰이더가 전건 팩 루트로
            // 떨어져 미스 → 이펙트 통째 드롭이라는 최악의 조합이 된다.
            let normalized = eff.file.replacingOccurrences(of: "\\", with: "/")
            guard let slash = normalized.lastIndex(of: "/") else { return nil }
            let dir = String(normalized[normalized.startIndex..<slash])
            return dir.isEmpty ? nil : dir
        }
        return eff.name.isEmpty ? nil : "effects/\(eff.name)"
    }

    /// F1: 이펙트-로컬 폴백 후보 — **전역 후보가 전부 빗나간 뒤에만** 쓴다.
    /// 입력은 `resolveTexture*` 가 만든 그 후보 목록(`["materials/<name>.tex", <name>]`)이고,
    /// 여기에 `.tex` 후보마다 **소스 폼**(`.png`)을 뒤에 덧붙인다.
    ///
    /// 소스 폼이 필요한 이유(실측 2026-08-20 — 동봉 `Resources/WEAssets` 와 WE 설치본
    /// `wallpaper_engine/assets` 가 같은 레이아웃):
    ///
    ///     effects/refraction/materials/effects/refractnormal.{png,tex-json}   ← 있다
    ///     effects/refraction/materials/effects/refractnormal.tex              ← **없다**
    ///     effects/refraction/preview/materials/effects/refractnormal.tex      ← 에디터 프리뷰 전용
    ///
    /// 즉 **스코프만 고쳐서는 이 3건이 여전히 안 뜬다** — 종전 진단이 여기서 틀렸다.
    /// WE 는 `.tex` 가 없으면 그 자리에서 `resourcecompiler64.exe -tex -i "<src>"` 로 컴파일한다
    /// (원본 문자열 `"resourcecompiler64.exe"` · `".tex-json"` · `" -tex -i \""` ·
    /// `"Recompiling texture: %S"`). Waple 에는 그 컴파일러가 없으므로 `.png` 를 직접 디코드한다 —
    /// 프리뷰 `.tex` 페이로드와 소스 `.png` 의 RGBA8 이 **바이트 동일**임을 확인했다
    /// (waterripplenormal 256×256 = 262,144 B, waterflowphase 32×32 = 4,096 B 전건 일치).
    ///
    /// 설치본 `.tex-json` 298건 중 짝 `.tex` 가 없는 것은 26건뿐이고 그중 22건은 에디터 프리뷰
    /// (`presets/*/preview*`, `.tga`)·1건은 소스조차 없다. **런타임이 실제로 참조하는 것은 이 3건뿐이고
    /// 셋 다 `.png`** 라 `.png` 만 다룬다.
    ///
    /// 프리뷰 `.tex` 로 폴백하지 않는 이유: 페이로드는 실측상 같아도 에디터 전용 관례에 의존하게 되고,
    /// refraction 은 프리뷰가 `rgba8888` 로 컴파일돼 있어 정본 `.tex-json` 의 `rg88n` 과 어긋난다.
    static func effectLocalTextureCandidates(_ candidates: [String]) -> [String] {
        candidates + candidates.filter { $0.hasSuffix(".tex") }.map { String($0.dropLast(4)) + ".png" }
    }

    func quietAssetData(_ name: String, package: ScenePackage) -> Data? {
        if let d = packageData(name, package: package) { return d }
        return baseAssetData(name)
    }

    /// pkg 전용 에셋 조회(베이스 팩 폴터 없음) — 커스텀 셰이더 소스처럼 씬 번들만 인정해야 하는 프로브용.
    func packageData(_ name: String, package: ScenePackage) -> Data? {
        // 종전엔 미스 시 `entries.first(where: caseInsensitiveCompare)` 로 **전량 선형 스캔**을 했다.
        // 그건 죽은 코드다 — `package.data(for:)` 가 이미 정확 인덱스와 정규화 인덱스(백슬래시
        // 치환 + 소문자화) 둘을 보고, 정규화가 `caseInsensitiveCompare` 보다 더 관대하다.
        // 스코프 조회가 들어오면서 이 함수 호출이 **2배**가 됐고(`fluidsimulation` 1빌드에 139회),
        // `maxEntries` 65,536 이라 악의 pkg 최악이 수백만 비교가 된다.
        package.data(for: name)
    }

    private func baseAssetURL(for name: String, root: URL) -> URL? {
        guard case .url(let url) = baseAssetURLProbe(for: name, root: root) else { return nil }
        return url
    }

    /// F4: (루트, 이름) 메모를 씌운 프로브. **순수 메모다** — 판정 본체는
    /// `uncachedBaseAssetURLProbe` 그대로이고, 4단 조회 순서도 호출부의 `.rejected` 즉시-반환
    /// 규약도 로그도 건드리지 않는다(본체는 로그를 내지 않는다 — 로그는 전부 호출부에 있다).
    /// 그래서 **어떤 입력에 대해서도** 관측 결과가 캐시 유무와 같다.
    ///
    /// 유일한 가정은 "한 번의 씬 빌드가 도는 동안 베이스 루트의 파일시스템은 그대로다" 이고,
    /// 그건 이미 암묵적으로 깔려 있던 것이다(베이스 루트는 WE 설치본/앱 번들 = 읽기 전용이고,
    /// 빌드 도중 거기에 쓰는 코드는 없다).
    private func baseAssetURLProbe(for name: String, root: URL) -> BaseAssetURLProbe {
        // 키에 루트를 넣는다 — 같은 이름이 루트마다 다르게 풀린다(사용자 설치본 vs 동봉본).
        // `\u{0}` 은 경로에도 자산명에도 올 수 없어(normalizedRelativePath 가 NUL 을 거부한다)
        // 구분자로 안전하다.
        let key = "\(root.path)\u{0}\(name)"
        if let hit = assetProbeCache[key] { return hit }
        let result = uncachedBaseAssetURLProbe(for: name, root: root)
        if assetProbeCache.count < SceneRenderer.assetProbeCacheLimit { assetProbeCache[key] = result }
        return result
    }

    private func uncachedBaseAssetURLProbe(for name: String, root: URL) -> BaseAssetURLProbe {
        guard let path = WallpaperPathSecurity.normalizedRelativePath(name) else { return .rejected }
        let rootURL = root.standardizedFileURL
        let exactCandidate = rootURL.appendingPathComponent(path).standardizedFileURL
        guard WallpaperPathSecurity.contains(exactCandidate, in: rootURL) else { return .rejected }
        if FileManager.default.fileExists(atPath: exactCandidate.path) {
            guard let exact = WallpaperPathSecurity.containedFileURL(path, root: root) else {
                return .rejected
            }
            return .url(exact)
        }
        let realRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        var current = rootURL
        for part in path.split(separator: "/").map(String.init) {
            guard let children = try? FileManager.default.contentsOfDirectory(at: current,
                                                                              includingPropertiesForKeys: nil),
                  let match = children.first(where: {
                      $0.lastPathComponent.caseInsensitiveCompare(part) == .orderedSame
                  }) else { return .missing }
            current = match.standardizedFileURL
            guard WallpaperPathSecurity.contains(current, in: rootURL) else { return .rejected }
            let realCurrent = current.resolvingSymlinksInPath().standardizedFileURL
            guard WallpaperPathSecurity.contains(realCurrent, in: realRoot) else { return .rejected }
        }
        guard FileManager.default.fileExists(atPath: current.path) else { return .missing }
        return .url(current)
    }

    /// 변환 효과 파이프라인. 정점 디스크립터: a_Position float3@0, a_TexCoord float2@12, stride 20,
    /// 버퍼 인덱스 4(p=buffer0 / eng=buffer1 와 충돌 회피 — 스파이크 증명 규약).
    /// command=copy 패스용 통과 파이프라인(g_Texture0 을 그대로 target 에 기록). translated 실행 규약과
    /// 동일한 버텍스 디스크립터/버퍼 인덱스를 쓰도록 GLSL 통과 셰이더를 번역해 캐시.

    /// X-⑧: 포맷별로 캐시한다 — copy 패스의 타깃이 r16f 면 통과 파이프라인도 r16f 여야 한다.
    /// 종전 단일 캐시(`_passthroughPipeline`)는 첫 요청 포맷을 이후 전부에 재사용해서,
    /// 포맷이 갈리는 순간 조용히 틀린 파이프라인을 돌려줬을 것이다.
    func passthroughEffectPipeline(device: MTLDevice,
                                   pixelFormat: MTLPixelFormat = .rgba8Unorm) -> MTLRenderPipelineState? {
        if let p = _passthroughPipelines[pixelFormat.rawValue] { return p }
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
        """
        guard let t = GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]),
              let p = translatedPipeline(msl: t.msl, device: device, pixelFormat: pixelFormat) else { return nil }
        _passthroughPipelines[pixelFormat.rawValue] = p
        return p
    }

    /// X-⑧: `pixelFormat` 은 **이 패스가 쓰는 타깃의 실제 포맷**이다. 종전엔 `.rgba8Unorm`
    /// 하드코딩이라 fbo 포맷을 살리는 순간 타깃-파이프라인 불일치로 Metal 이 거부한다.
    /// 기본값을 둔 이유는 호출부 중 타깃이 항상 효과 출력(rgba8)인 곳이 있어서다(무회귀).
    func translatedPipeline(msl: String, device: MTLDevice,
                            pixelFormat: MTLPixelFormat = .rgba8Unorm) -> MTLRenderPipelineState? {
        let lib: MTLLibrary
        do {
            lib = try WapleProfiler.compile(msl) { try device.makeLibrary(source: msl, options: nil) }
        } catch {
            // 실패 원인 진단용: 첫 에러 줄만(대개 undefined identifier = common.h 함수 부재).
            let first = "\(error)".split(separator: "\n").first(where: { $0.contains("error:") }) ?? ""
            NSLog("%@", "[Waple] translated MSL compile error: \(first)")
            return nil
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "ev_main")
        pd.fragmentFunction = lib.makeFunction(name: "ef_main")
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 4
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 4
        vd.layouts[4].stride = 20
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = pixelFormat
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

    /// G-B2-06: 매니페스트 `passes[]` 의 **원본 배열 인덱스**로 씬 오버라이드를 고른다.
    /// 범위 밖은 에러가 아니라 **오버라이드 없음** — 원본은 JsonCpp non-const
    /// `operator[](ArrayIndex)`(`0x140086540`)라 없는 인덱스에 nullValue 를 넣고 그 참조를
    /// 돌려준다(`0x14008672e`). 클램프도 랩어라운드도 예외도 없다.
    /// 규약이 한 줄짜리라 인라인해도 되지만, 이건 한 번 틀렸던 자리라 테스트가 붙도록 뺐다.
    static func sceneOverride(forRawPassIndex i: Int, in passList: [SceneEffectPass]) -> SceneEffectPass {
        (i >= 0 && i < passList.count) ? passList[i] : SceneEffectPass()
    }

    /// X-⑧: effect.json 의 `fbos[].format` → Metal 픽셀 포맷.
    ///
    /// 매핑은 이름이 아니라 **원본의 enum → DXGI 점프 테이블**(`0x1400d2a20`, 28-way)에서 왔다.
    /// 이름으로 추론하면 둘이 틀린다:
    ///   `rgb565`    → B5G6R5(85)가 아니라 **DXGI 28 = RGBA8_UNORM**
    ///   `rgba8888s` → SNORM(31)이 아니라 **DXGI 28 = RGBA8_UNORM**
    /// 3채널 이름(`rgb*`)은 전부 대응 4채널로 승격된다(24비트 렌더 타깃이 없다).
    ///
    /// **sRGB 는 어디에도 없다** — 28개 arm 중 `_SRGB` DXGI 값이 0건이라 `rgba8888` 은
    /// `.rgba8Unorm_srgb` 가 아니라 선형 `.rgba8Unorm` 이다.
    ///
    /// `rgba_backbuffer`/`rgb_backbuffer` 만 조건부다 — 파서가 해시맵 조회 **전에** strcmp 로
    /// 가로채 HDR 이면 float enum, 아니면 8비트 enum 으로 치환한다(`0x1401e7562`/`0x1401e759e`).
    /// 두 쌍의 최종 DXGI 는 각각 같아서(10 / 28) 여기서도 같은 Metal 포맷으로 떨어진다.
    ///
    /// 블록압축(`bc7`/`dxt1`/`dxt3`/`dxt5`)은 원본 표에 있지만 **렌더 타깃이 될 수 없다** —
    /// D3D11 도 Metal 도 압축 포맷에 그리지 못한다. 텍스처 로드 경로와 표를 공유하는 것으로
    /// 보이며, fbo 로 지정되면 그릴 수 없으므로 rgba8 로 떨어뜨린다(이펙트를 죽이는 대신).
    /// 동봉 자산의 fbo 55건 중 압축 포맷은 0건이다.
    ///
    /// 미지/미선언(nil)은 rgba8 — 원본이 해시맵 miss 에서 0(rgba8888)을 돌려주는 것과 같다.
    static func metalFormat(_ f: EffectManifest.FBO.Format?, hdr: Bool) -> MTLPixelFormat {
        guard let f else { return .rgba8Unorm }
        switch f {
        case .rgba8888, .rgb888, .rgb565, .rgba8888s: return .rgba8Unorm
        case .rg88:                                   return .rg8Unorm
        case .r8:                                     return .r8Unorm
        case .rgba16161616f, .rgb161616f:             return .rgba16Float
        case .rg1616f:                                return .rg16Float
        case .r16f:                                   return .r16Float
        case .rgba16161616, .rgb161616:               return .rgba16Unorm
        case .rgba16161616S, .rgb161616S:             return .rgba16Snorm
        case .rgba1010102:                            return .rgb10a2Unorm
        case .rgbaBackbuffer, .rgbBackbuffer:         return hdr ? .rgba16Float : .rgba8Unorm
        // 렌더 불가 — 위 주석 참조.
        case .bc7, .dxt5, .dxt3, .dxt1:               return .rgba8Unorm
        }
    }

    /// H1: 레이어 커스텀 셰이더 파이프라인. 정점 디스크립터는 translatedPipeline 과 동일(a_Position float3@0,
    /// a_TexCoord float2@12, stride 20, buffer 4). 색상 어태치먼트는 레이어 블렌드 모드에 맞춘다.
    func translatedLayerPipeline(msl: String, device: MTLDevice, pixelFormat: MTLPixelFormat, additive: Bool) -> MTLRenderPipelineState? {
        let lib: MTLLibrary
        do {
            lib = try WapleProfiler.compile(msl) { try device.makeLibrary(source: msl, options: nil) }
        } catch {
            let first = "\(error)".split(separator: "\n").first(where: { $0.contains("error:") }) ?? ""
            NSLog("%@", "[Waple] custom layer MSL compile error: \(first)")
            return nil
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "ev_main")
        pd.fragmentFunction = lib.makeFunction(name: "ef_main")
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 4
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 4
        vd.layouts[4].stride = 20
        pd.vertexDescriptor = vd
        let att = pd.colorAttachments[0]!
        att.pixelFormat = pixelFormat
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add; att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .one; att.sourceAlphaBlendFactor = .one
        if additive {
            att.destinationRGBBlendFactor = .one
            att.destinationAlphaBlendFactor = .one
        } else {
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

    /// H1: 레이어 머티리얼 커스텀 셰이더 빌드. 성공 시 CustomLayerShader, 실패 시 nil(→ QuadShaders 폴터).
    /// buildTranslatedEffect 의 5책임 분해를 2D 레이어에 맞춰 단순화한 버전.
    /// 셰이더 소스(.vert/.frag)는 씬 패키지 안 것만 인정 — 베이스 에셋 팩의 WE 빌트인 셰이더
    /// (genericimage4 등)까지 이 경로로 빨려 들어오면 검증된 QuadShaders 경로를 불필요하게 우회한다
    /// (3394601417 주야 토글 회귀 실증). include(common.h 등)만 베이스 팩 폴터 허용.
    func buildCustomLayerShader(_ layer: SceneLayer, texture: MTLTexture, package: ScenePackage, device: MTLDevice,
                                pixelFormat: MTLPixelFormat) -> CustomLayerShader? {
        guard let shaderName = layer.materialShader else { return nil }
        let include: (String) -> String? = { header in
            for cand in ["shaders/\(header)", header] {
                if let d = self.quietAssetData(cand, package: package), let s = String(data: d, encoding: .utf8) { return s }
            }
            return BuiltinShaderIncludes.lookup(header)
        }
        guard let vData = packageData("shaders/\(shaderName).vert", package: package),
              let fData = packageData("shaders/\(shaderName).frag", package: package),
              let vert = String(data: vData, encoding: .utf8),
              let frag = String(data: fData, encoding: .utf8) else {
            NSLog("%@", "[Waple] custom layer shader source missing: \(shaderName)")
            return nil
        }
        var combos = layer.materialCombos
        for (slot, comboName) in GLSLTranslator.samplerCombos(frag) where combos[comboName] == nil {
            let bound = slot < layer.materialTextureNames.count && layer.materialTextureNames[slot] != nil
            if bound { combos[comboName] = 1 }
        }
        guard let t = GLSLTranslator.translate(vertex: vert, fragment: frag, combos: combos,
                                               include: include, premultiplyOutput: true) else {
            NSLog("%@", "[Waple] custom layer GLSL translate failed: \(shaderName)")
            return nil
        }
        let additive = layer.blendMode == "additive"
        guard let pipe = translatedLayerPipeline(msl: t.msl, device: device,
                                                 pixelFormat: pixelFormat, additive: additive) else {
            NSLog("%@", "[Waple] custom layer pipeline compile failed: \(shaderName)")
            return nil
        }
        let material: [SIMD4<Float>] = t.materialParams.map { p in
            let v = layer.materialConstants[p.sceneKey] ?? p.defaultValue
            return SIMD4<Float>(v.count > 0 ? v[0] : 0, v.count > 1 ? v[1] : 0,
                                v.count > 2 ? v[2] : 0, v.count > 3 ? v[3] : 0)
        }
        var scripts: [(slot: Int, engine: TextScriptEngine)] = []
        for (slot, p) in t.materialParams.enumerated() {
            if let src = layer.materialConstantScripts[p.sceneKey],
               let engine = makeScriptEngine(src, scriptPropsJSON: layer.materialConstantScriptProps[p.sceneKey]) {
                scripts.append((slot, engine))
                if engine.hasUpdate { hasAnimations = true }
            }
        }
        let lw = Float(max(1, texture.width)), lh = Float(max(1, texture.height))
        var texRes = [SIMD4<Float>](repeating: SIMD4(lw, lh, lw, lh), count: 8)
        var texWrap = [Float](repeating: 0, count: 8)
        var texFilter = [Float](repeating: 0, count: 8)
        texRes[0] = SIMD4(lw, lh, lw, lh)
        texWrap[0] = resolveTextureClampUVs(layer.textureEntryName, package: package) ? 1 : 0
        texFilter[0] = resolveTextureNoInterpolation(layer.textureEntryName, package: package) ? 1 : 0
        var aux: [(slot: Int, tex: MTLTexture)] = []
        for slot in t.textureSlots where slot > 0 && slot < 128 {
            let name = slot < layer.materialTextureNames.count ? layer.materialTextureNames[slot] : nil
            if let tex = resolveTexture(name, package: package, device: device) {
                aux.append((slot, tex))
                if slot < 8 {
                    let w = Float(max(1, tex.width)), h = Float(max(1, tex.height))
                    texRes[slot] = SIMD4(w, h, w, h)
                    texWrap[slot] = resolveTextureClampUVs(name, package: package) ? 1 : 0
                    texFilter[slot] = resolveTextureNoInterpolation(name, package: package) ? 1 : 0
                }
            }
        }
        return CustomLayerShader(pipeline: pipe, material: material, aux: aux,
                                 texRes: texRes, texWrap: texWrap, texFilter: texFilter,
                                 scripts: scripts)
    }

    /// 효과 보조 텍스처 슬롯 이름 → MTLTexture. 이름 nil/디코드 실패 → 흰색 1x1 폴백
    /// (마스크는 흰색=효과 전체 적용으로 정상. 노멀맵은 흰색≠중립 — 언팩 시 (1,1,1)=상시 대각
    /// 변위라 waterripple 은 buildHandPortEffect 에서 중립 (128,128,255)로 별도 처리, F412).
    /// "effects/X"/"masks/X" 같은 상대 이름은 "materials/<name>.tex" 로 해석, raw 이름도 시도.
    /// F1: `root`(= `SceneRenderer.effectLocalRoot`)를 주면 전역 미스 뒤에 이펙트-로컬 루트도 본다.
    /// 기본 nil = 종전 동작 그대로(레이어·파티클·3D·손-포팅 호출부는 호출 형태조차 안 바뀐다).
    func resolveTexture(_ name: String?, package: ScenePackage, device: MTLDevice,
                        root: String? = nil) -> MTLTexture? {
        resolveTextureWithFrames(name, package: package, device: device, root: root)?.texture
    }

    /// `.tex`(TEXV0005) 바이트 → 텍스처 + TEXS 프레임. `resolveTextureWithFrames` 의 `decode:` 본문을
    /// **그대로** 떼어낸 것(로직·주석 무변경) — F1 의 이펙트-로컬 폴백이 같은 디코드를 재사용해야 해서
    /// 클로저 밖으로 뺐다. 둘이 갈리면 "루트만 다른데 다르게 디코드되는 텍스처"가 생긴다.
    private func decodeTexAsset(_ d: Data, device: MTLDevice)
        -> (texture: MTLTexture, frames: [TexImage.TexFrame])? {
        guard let tex = TexImage.parse(d) else { return nil }
        let multipage = tex.imageCount > 1
        if multipage, !tex.frames.isEmpty,
           let stacked = stackedAtlas(tex: tex, data: d, device: device) {
            return stacked
        }
        // 단일-이미지 다중프레임 시트는 아틀라스 전체 보존(imgW/imgH 크롭 시 frame≥1 소실 → 흑화).
        // keepFullAtlas 는 makeImageTexture 가 full decode dims 로 상주(BC 면 네이티브, 비-BC 면 CPU rgba8) —
        // spriteFrameTexture 가 f_spriteframe 샘플로 프레임을 뽑으므로 아틀라스가 BC 로 상주해도 무방.
        if let dec = makeImageTexture(tex: tex, data: d, device: device,
                                      keepFullAtlas: !multipage && tex.frames.count > 1) {
            let texture = dec.texture
            // 멀티페이지인데 stackedAtlas 실패(스택 높이>16384 등) → 프레임 좌표가 페이지-상대라 그대로
            // 쓰면 imageId≥1 프레임이 page0 좌표를 읽는 **조용한 오프레임**. frames=[] 로 정지 폴백
            // (page 0 표시)해 "틀린 애니" 대신 "정지"로 명예로운 실패(advisor). 단일 image 는 frames
            // 정상(전부 id0, 오프셋 무관). 영향 실측 6씬(3379048027 7페이지/420프레임 sumH 52920,
            // 3363252053·3448877775 7페이지, 3577990983 5페이지, 3000562427 day/night 3페이지).
            // ponytail: 진짜 고침 = 페이지별 텍스처 또는 온디맨드 프레임 스트리밍(초대형 시트 ~1.7GB) — 재설계.
            return (texture, multipage ? [] : tex.frames)
        }
        return nil
    }

    /// 텍스처 + 스프라이트시트 프레임(TEXS). 파티클이 프레임 UV 서브렉트에 사용(레이어는 texture 만).
    func resolveTextureWithFrames(_ name: String?, package: ScenePackage, device: MTLDevice,
                                  root: String? = nil)
        -> (texture: MTLTexture, frames: [TexImage.TexFrame])? {
        if let name {
            let candidates = name.hasSuffix(".tex")
                ? [name]
                : ["materials/\(name).tex", name]
            if let resolved: (texture: MTLTexture, frames: [TexImage.TexFrame]) = resolveRequiredAsset(
                candidates,
                package: package,
                decode: { d in decodeTexAsset(d, device: device) },
                // F1: `alternate` 는 `resolveRequiredAsset` 이 **candidates 루프를 전부 돈 뒤에만**
                // 부르는 훅이다. 그래서 오늘 해석되는 자산은 여기까지 내려오지 않는다 — 순수 가산이고,
                // 겸사겸사 `markMissingRequiredSharedAsset()` 오탐도 막는다.
                //
                // 스코프 조회는 `effectScopedData` 를 **그대로** 쓴다(4티어 ①pkg-scoped ②pkg-plain
                // ③base-scoped ④base-plain). ②·④ 는 위 루프가 이미 빗나간 바로 그 조회라 다시 봐도
                // 결과가 같고 실질적으로 ①·③ 만 새로 본다 — 그 함수가 지키는 "씬 pkg 가 베이스를
                // 항상 이긴다" 순서를 재구현 없이 물려받는다.
                alternate: {
                    guard root?.isEmpty == false else { return nil }
                    for c in SceneRenderer.effectLocalTextureCandidates(candidates) {
                        guard let d = effectScopedData(c, root: root, package: package) else { continue }
                        if let v = decodeTexAsset(d, device: device) { return v }
                        // 소스 폼(.png)은 TEXV0005 헤더가 없어 `TexImage.parse` 가 nil — ImageIO 로 직접
                        // 디코드한다(`decodeArtworkTexture` = bitmapRGBAFile 과 동일 규약, RGBA8 상주).
                        // 실측 3건 전부 알파 없는 RGB PNG 라 premultipliedLast 는 항등이다.
                        // 스프라이트 프레임은 `.tex` 의 TEXS 청크에만 있으므로 frames=[](정지).
                        if let t = decodeArtworkTexture(d, device: device) { return (texture: t, frames: []) }
                    }
                    return nil
                }
            ) {
                return resolved
            }
            // **이름이 있었는데 해석에 실패한** 경우만 시끄럽게 만든다. 흰 1×1 폴백 자체는 유지한다
            // (미바인드 Metal 검증 실패보다 낫다는 기존 판단) — 문제는 그게 **조용했다**는 것이다.
            // 흰색은 곱셈 항등원이라 마스크·그라디언트·노이즈 슬롯에서 "효과가 안 걸린 것처럼" 보이거나
            // (fx0·fx1 = 1 로 노이즈가 통째로 사라짐) 반대로 전화면에 걸려, 진단이 상류 원인을 못 찾는다.
            // 실측 사례: `util/clouds_N`(존재하는 것은 clouds_256) 이 조용히 백색이 됐다.
            // 이름이 nil 인 호출(선언만 있고 아무도 바인드하지 않은 샘플러 슬롯 — lightshafts 의 MASK
            // 미사용 g_Texture3 등)은 설계상 placeholder 라 로그하지 않는다.
            // F1: 스코프 조회가 있었으면 그것도 적는다 — 종전 메시지로는 "이펙트 루트를 봤는데도
            // 없다"와 "아예 안 봤다"가 구분되지 않아, 이 사고를 로그만 보고는 못 짚었다.
            let scopedTried = (root?.isEmpty == false)
                ? " · effect-local root '\(root ?? "")': \(SceneRenderer.effectLocalTextureCandidates(candidates).joined(separator: ", "))"
                : ""
            WapleLog.warn("[Waple] texture unresolved → white 1×1 placeholder: \(name) (tried \(candidates.joined(separator: ", "))\(scopedTried))")
        }
        return makeTexture(Data([255, 255, 255, 255]), 1, 1, device).map { ($0, []) }
    }

    /// REFRACT 노멀맵 아틀라스 + RG88 여부. 프레임 UV 는 알베도와 공유(동일 그리드 가정) → 전체 아틀라스만 필요.
    /// resolveTextureWithFrames 와 동일 디코드 경로(멀티페이지 스택/keepFullAtlas)로 알베도와 레이아웃 정합.
    /// rg88 플래그는 pf_refract 의 노멀 언팩 분기용(WE DecompressNormalWithMask 의 FORMAT_RG88 vs DXT).
    func resolveRefractNormal(_ name: String?, package: ScenePackage, device: MTLDevice)
        -> (texture: MTLTexture, rg88: Bool)? {
        guard let name else { return nil }
        let candidates = name.hasSuffix(".tex") ? [name] : ["materials/\(name).tex", name]
        return resolveRequiredAsset(candidates, package: package, decode: { d -> (texture: MTLTexture, rg88: Bool)? in
            guard let tex = TexImage.parse(d) else { return nil }
            let rg88 = tex.payload == .rg88
            let multipage = tex.imageCount > 1
            if multipage, !tex.frames.isEmpty, let stacked = stackedAtlas(tex: tex, data: d, device: device) {
                return (stacked.texture, rg88)
            }
            if let dec = makeImageTexture(tex: tex, data: d, device: device,
                                          keepFullAtlas: !multipage && tex.frames.count > 1) {
                return (dec.texture, rg88)
            }
            return nil
        })
    }

    /// M3: mf_normal DecompressNormal 포맷 분류 — WE common_fragment.h:18-30 TEX1FORMAT 3분기 대응.
    /// 0=블록압축(DXT1/2/3=BC1-3, 바이어스 0.965 분기), 1=RG88(2채널, 바이어스 없음 별도 채널),
    /// 2=그 외(비압축 RGBA8888/R8/임베디드PNG 등, 바이어스 없음 w/y 분기). BC7 은 코퍼스 미관측이라 미분류.
    private func normalMapFormatCode(_ payload: TexImage.PayloadKind) -> Float {
        switch payload {
        case .bc1, .bc2, .bc3: return 0
        case .rg88: return 1
        default: return 2
        }
    }

    /// M3 노멀맵 텍스처 + DecompressNormal 포맷 분류(mf_normal 전용). resolveRefractNormal 과 동일
    /// 디코드 경로(멀티페이지 스택/keepFullAtlas)라 알베도와 레이아웃 정합 — refract 의 rg88 단일 플래그와
    /// 달리 mf_normal 은 라이팅용 정식 DecompressNormal(2채널+Z재구성)이 필요해 포맷 코드 3분기로 분리.
    func resolveNormalMapFormat(_ name: String?, package: ScenePackage, device: MTLDevice)
        -> (texture: MTLTexture, formatCode: Float)? {
        guard let name else { return nil }
        let candidates = name.hasSuffix(".tex") ? [name] : ["materials/\(name).tex", name]
        return resolveRequiredAsset(candidates, package: package, decode: { d -> (texture: MTLTexture, formatCode: Float)? in
            guard let tex = TexImage.parse(d) else { return nil }
            let formatCode = normalMapFormatCode(tex.payload)
            let multipage = tex.imageCount > 1
            if multipage, !tex.frames.isEmpty, let stacked = stackedAtlas(tex: tex, data: d, device: device) {
                return (stacked.texture, formatCode)
            }
            if let dec = makeImageTexture(tex: tex, data: d, device: device,
                                          keepFullAtlas: !multipage && tex.frames.count > 1) {
                return (dec.texture, formatCode)
            }
            return nil
        })
    }

    /// 다중 image 아틀라스 페이지를 **세로로 이어붙인 단일 텍스처**로 합치고 frame.y 에 페이지별 누적
    /// y-오프셋을 더한다(frame.imageId = 페이지). GPUParticleSystem/GPULayer.texture 단일 유지 → 프레임
    /// 인코더/blit 무변경. 실측(2026-07-10, 코퍼스 멀티페이지 7종): 페이지 dims 가 **불균일**하다(예
    /// 鸟_00020: page0 7680×7920, page1 5760×2880) — 종전 same-dims 가드는 여기서 nil 폴백해 page1
    /// 프레임을 오프셋 없이(atlasY=0) 렌더했다(조용한 오프레임 — advisor #1). 이제 max-width × sum-height
    /// 로 패딩 스택하고 각 페이지를 (0, 누적y)에 행-복사한다. **균일 페이지는 종전과 byte-identical 배치**
    /// (maxW=pw, 누적y=page*ph) → 파티클 무회귀. 스택 높이/폭이 Metal 한계(16384) 초과면 nil → 호출자가
    /// 정지 폴백(frames=[], 조용한 오프레임 대신 명예로운 정지). **디코드 전 조기 거부**: 패딩 decodeHeight
    /// 합으로 먼저 검사해 초대형 시트(7페이지 sumH 52920 등, 1.7GB)의 무의미한 전-페이지 디코드를 회피.
    /// 레이어/파티클 공용(resolveTextureWithFrames). ponytail: 텍스처 배열 대신 패딩 세로 스택(폭 작은
    /// 페이지 우측 패딩은 UV 밖이라 무해). 16384 초과 시트의 진짜 고침 = 페이지별 텍스처/온디맨드 스트리밍(재설계).
    private func stackedAtlas(tex: TexImage, data: Data, device: MTLDevice)
        -> (texture: MTLTexture, frames: [TexImage.TexFrame])? {
        // 조기 거부(디코드 전): 패딩 decodeHeight 합 = 스택 높이 상한(실제 크롭 후는 ≤). 초과면 초대형
        // 디코드 착수 전 nil. decodeWidth/Height 는 무경계 UInt32 유래라 오버플로도 함께 차단.
        let padH = tex.mips.reduce(0) { $0 + $1.decodeHeight }
        let padW = tex.mips.map { $0.decodeWidth }.max() ?? 0
        guard padW > 0, padH > 0, padW <= 16384, padH <= 16384 else { return nil }
        var pages: [(pixels: Data, width: Int, height: Int)] = []
        for i in 0..<tex.imageCount {
            guard let p = TexDecoder.rgba(from: tex, data: data, imageIndex: i) else { return nil }
            pages.append(p)
        }
        guard !pages.isEmpty else { return nil }
        let maxW = pages.map { $0.width }.max() ?? 0
        let totalH = pages.map { $0.height }.reduce(0, +)
        guard maxW > 0, totalH > 0, maxW <= 16384, totalH <= 16384 else { return nil }  // 실제 크롭 후 재확인(방어)
        var yOff: [Int] = []; var cy = 0                     // 페이지별 누적 y(균일이면 page*ph)
        for p in pages { yOff.append(cy); cy += p.height }
        var stacked = Data(count: maxW * totalH * 4)          // 제로 버퍼(폭 작은 페이지 우측은 0 잔존)
        stacked.withUnsafeMutableBytes { dstRaw in
            guard let dst = dstRaw.baseAddress else { return }
            for (i, p) in pages.enumerated() {
                p.pixels.withUnsafeBytes { srcRaw in
                    guard let src = srcRaw.baseAddress else { return }
                    let rowBytes = p.width * 4
                    for row in 0..<p.height {                  // 행 단위 복사(불균일 폭 → dst stride=maxW)
                        memcpy(dst + ((yOff[i] + row) * maxW) * 4, src + row * rowBytes, rowBytes)
                    }
                }
            }
        }
        let adjusted = tex.frames.map { fr -> TexImage.TexFrame in
            let page = max(0, min(pages.count - 1, fr.imageId))   // imageId = 페이지 인덱스(범위 클램프)
            return TexImage.TexFrame(imageId: fr.imageId, time: fr.time, x: fr.x, y: fr.y + Float(yOff[page]),
                                     width: fr.width, height: fr.height, widthY: fr.widthY, heightX: fr.heightX)
        }
        guard let m = makeTexture(stacked, maxW, totalH, device) else { return nil }
        return (m, adjusted)
    }

    /// 효과의 AUDIOPROCESSING 콤보 + 오디오 상수 → AudioParams(없으면 nil). draw 시 audioResponse 계산에 사용.
    func audioParams(for eff: SceneEffect) -> AudioParams? {
        let mode = eff.audioMode
        guard mode >= 1, mode <= 3 else { return nil }
        let c = eff.constants
        let bounds = c["audiobounds"] ?? [0.5, 1.0]
        return AudioParams(
            mode: mode,
            freqMin: c["frequencymin"]?.first ?? 0,
            // **WE 선언 기본값은 1 이다** — `effects/pulse/shaders/effects/pulse.vert` 의
            // `g_AudioFrequencyMax` 어노테이션이 `"default":1`(range [0,15]). 종전 15 는 전 대역을
            // 고르는 값이라, 비선형 밴드 매핑이 들어온 지금은 23.4–187.5 Hz 여야 할 대역이
            // 23.4–14671.9 Hz 로 벌어진다. 씬 상수는 constantshadervalues 에서만 채워지고 셰이더
            // 선언 기본값은 파스하지 않으므로 이 폴백이 곧 실효 기본값이다.
            freqMax: c["frequencymax"]?.first ?? 1,
            bounds: SIMD2<Float>(bounds.count > 0 ? bounds[0] : 0.5, bounds.count > 1 ? bounds[1] : 1.0),
            power: c["audioexponent"]?.first ?? 1,
            multiply: c["audioamount"]?.first ?? 1)
    }

    /// 파티클 시스템별 텍스처/시뮬/블렌드 준비. 텍스처는 material 의 첫 텍스처(없으면 흰색 폴백).
    /// 자식 링크는 부모 직후에 자체 머티리얼의 GPU 시스템으로 추가(드로우는 부모 sim.childDisplay).
    func buildParticles(doc: SceneDocument, package: ScenePackage, device: MTLDevice) -> [GPUParticleSystem] {
        var out: [GPUParticleSystem] = []
        func makeSystem(def: ParticleSystemDef, seed: UInt64, sp: SceneParticle,
                        childOf: (parent: Int, link: Int)? = nil) -> GPUParticleSystem? {
            guard let (tex, frames) = resolveTextureWithFrames(def.material?.textureName,
                                                               package: package, device: device) else { return nil }
            let mirror = def.initializers.contains {
                if case .mapSequence(_, true, _) = $0 { return true }; return false
            }
            var g = GPUParticleSystem(
                sim: ParticleSimulator(def: def, seed: seed), def: def, seed: seed,
                texture: tex, blendAdditive: def.material?.blend == .additive,
                origin: SIMD2<Float>(sp.origin.x, sp.origin.y),
                scale: SIMD2<Float>(sp.scale.x, sp.scale.y),
                texRatio: Float(tex.height) / Float(max(1, tex.width)), order: sp.order,
                isTrail: def.renderer.isTrail, childOf: childOf,
                frames: frames, mapSeqMirror: mirror)
            // F200: 마우스 시차 가중치(레이어 buildLayers 의 GPULayer.parallaxDepth 배선과 동형) — 2D 전용.
            g.parallaxDepth = SIMD2<Float>(sp.parallaxDepth.x, sp.parallaxDepth.y)
            // 3D 씬 배치(2D 는 위 origin/scale Vec2 만 사용 — 아래 필드 무시).
            g.parent3D = sp.parent
            g.origin3D = SIMD3<Float>(sp.origin3D.x, sp.origin3D.y, sp.origin3D.z)
            g.scale3D = SIMD3<Float>(sp.scale3D.x, sp.scale3D.y, sp.scale3D.z)
            g.angles3D = SIMD3<Float>(sp.angles3D.x, sp.angles3D.y, sp.angles3D.z)
            g.visible3D = sp.visible
            // E1(④): 2D 정사영 경로 visible — 정적 초기값 + per-frame 재평가용 스크립트 엔진(F199 캡처
            // 소비). 종전엔 어디서도 읽지 않아 저작자가 숨긴 파티클 시스템이 항상 렌더됐다.
            g.initialVisible = sp.visible
            g.hiddenByAncestor = sp.hiddenByAncestor
            if let src = sp.visibleScript {
                // detachedLayer: 파티클은 thisScene.layers 디스크립터에 없다 — 엔진 전용 thisLayer 를
                // 줘야 `thisLayer.pause()`(WE IParticleSystem) 상태가 이 시스템에만 묶인다.
                g.visibleEngine = makeScriptEngine(src, scriptPropsJSON: sp.visibleScriptProps,
                                                   detachedLayer: true)
            }
            // REFRACT: 노멀맵(textures[1]) 로드 + refractAmount. 실패 시 refract 미설정 → identity 폴백(무크래시).
            if let mat = def.material, mat.refract, let normalName = mat.normalTextureName,
               let n = resolveRefractNormal(normalName, package: package, device: device) {
                g.refract = true
                g.normalTexture = n.texture
                g.normalRG88 = n.rg88
                g.refractAmount = mat.refractAmount
            }
            // 감사 V07: 알베도 NoInterpolation(TexImage flags bit0) — encodeParticle 이 nearest 변형
            // 파이프라인을 선택(레이어 buildLayers 의 GPULayer.noInterp 배선과 동형).
            // C⑧a: 오브젝트 레벨 nointerpolation 오버라이드도 OR(레이어 경로와 동일 규약·근거).
            g.noInterp = sp.noInterpolation || resolveTextureNoInterpolation(def.material?.textureName, package: package)
            // M(④): combos.FOG(기본 1) — encode3DParticles 가 pf3d_fog 파이프라인 선택에 사용.
            g.foggy = def.material?.foggy ?? true
            // C4-(ii): g_Overbright(기본 1) — encodeParticle/encodeRefractParticle/encode3DParticles 가 소비.
            g.overbright = def.material?.overbright ?? 1
            return g
        }
        // E1(③): F178 — children[]는 파스/시뮬 모두 깊이4 재귀를 지원하나(SceneDocument.parseParticleDef
        // 의 visited.count<4 사이클/깊이 캡이 상한), 종전엔 이 GPU화 루프가 직계 자식(1단)만 순회해
        // 손자 이상은 CPU/RNG 시뮬 비용만 내고 화면에 그려지지 않았다. def.children 를 재귀 순회해
        // 모든 깊이의 자손에 GPUParticleSystem 을 만든다 — childOf.parent 는 항상 "직계" 부모의 GPU
        // 배열 인덱스(트리 구조 그대로)이고, draw/step 소비처는 이 체인을 루트까지 거슬러 올라가 실제
        // (스텝되는) 루트 sim 에서 경로 기반으로 표시 스냅샷을 얻는다(중간 자식의 sim 은 더미 — 미스텝).
        func appendChildren(of def: ParticleSystemDef, parentIdx: Int, seed: UInt64, sp: SceneParticle, depth: Int) {
            guard depth < 8 else { return }  // 방어적 상한(파스 단계 캡이 실질 상한 — 여긴 안전망)
            for (li, link) in def.children.enumerated() {
                let childSeed = seed &+ UInt64(li) &+ 1
                if let child = makeSystem(def: link.def, seed: childSeed, sp: sp,
                                          childOf: (parent: parentIdx, link: li)) {
                    let childIdx = out.count
                    out.append(child)
                    appendChildren(of: link.def, parentIdx: childIdx, seed: childSeed, sp: sp, depth: depth + 1)
                }
            }
        }
        for (i, sp) in doc.particles.enumerated() {
            let seed = UInt64(0x9E37_79B9_7F4A_7C15 &+ UInt64(i))
            guard let parent = makeSystem(def: sp.def, seed: seed, sp: sp) else { continue }
            let parentIdx = out.count
            out.append(parent)
            appendChildren(of: sp.def, parentIdx: parentIdx, seed: seed, sp: sp, depth: 0)
        }
        // 이미터 오디오반응이 있으면 라이브 오디오 공급자 기동 대상(mount 의 hasAudio 게이트 → provider.start()).
        if out.contains(where: { $0.def.emitterAudio.contains { $0 != nil } }) { hasAudio = true }
        return out
    }

    /// 파티클 파이프라인. frag 가 premultiplied-alpha 출력 → src=one.
    /// additive: dst=one(가산), translucent: dst=oneMinusSrcAlpha(일반 over).
    /// nearest(감사 V07): 알베도 NoInterpolation 시스템 전용 — ParticleShaders.nearestSource(pf_main 샘플러만
    /// filter::nearest, 어드레스 모드 보존). false 면 기존 소스와 비트동일(무회귀).
    func particlePipeline(additive: Bool, nearest: Bool = false, device: MTLDevice) -> MTLRenderPipelineState? {
        let src = nearest ? ParticleShaders.nearestSource : ParticleShaders.source
        guard let lib = try? WapleProfiler.compile(src, { try device.makeLibrary(source: src, options: nil) }) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "pv_main")
        pd.fragmentFunction = lib.makeFunction(name: "pf_main")
        let a = pd.colorAttachments[0]!
        a.pixelFormat = accPixelFormat   // A2: acc 를 타깃으로 하므로 acc 포맷과 일치(HDR=float)
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

    /// REFRACT 스프라이트 파이프라인. vert=pv_main 공유, frag=pf_refract(노멀 오프셋 씬 재샘플·곱).
    /// C4-(iii): translucent(over, 기존)/additive(가산 — 코퍼스 additive+REFRACT 10씬 실측) 두 블렌드
    /// 변형을 additive 인자로 선택(프래그먼트 함수·소스는 공유, 블렌드 상태만 분기).
    func refractParticlePipelineBuild(additive: Bool, device: MTLDevice) -> MTLRenderPipelineState? {
        guard let lib = try? WapleProfiler.compile(ParticleShaders.source, { try device.makeLibrary(source: ParticleShaders.source, options: nil) }) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "pv_main")
        pd.fragmentFunction = lib.makeFunction(name: "pf_refract")
        let a = pd.colorAttachments[0]!
        a.pixelFormat = accPixelFormat
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

    /// H4: REFRACT 이미지 레이어 파이프라인. vert=v_main 공유, frag=f_refract(노멀 오프셋 씬 재샘플·곱).
    /// 블렌드는 premultiplied-over(레이어 기본) — refract 코퍼스는 전부 translucent/additive 아님.
    func refractLayerPipelineBuild(device: MTLDevice) -> MTLRenderPipelineState? {
        guard let lib = try? WapleProfiler.compile(QuadShaders.source, { try device.makeLibrary(source: QuadShaders.source, options: nil) }) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "v_main")
        pd.fragmentFunction = lib.makeFunction(name: "f_refract")
        let a = pd.colorAttachments[0]!
        a.pixelFormat = accPixelFormat
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

    func effectPipeline(source: String, device: MTLDevice) -> MTLRenderPipelineState? {
        guard let lib = try? WapleProfiler.compile(source, { try device.makeLibrary(source: source, options: nil) }) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "ev_main")
        pd.fragmentFunction = lib.makeFunction(name: "ef_main")
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        return try? WapleProfiler.pipe { try device.makeRenderPipelineState(descriptor: pd) }
    }

    func makeOffscreen(_ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: max(w,1), height: max(h,1), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: d)
    }

    /// X-⑧: 임의 포맷 오프스크린(effect.json `fbos[].format` 전용). usage 는 다른 팩토리와 동일하게
    /// renderTarget|shaderRead — fbo 는 항상 타깃이자 다음 패스의 소스다.
    func makeOffscreenFormatted(_ w: Int, _ h: Int, _ device: MTLDevice, format: MTLPixelFormat) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(w,1), height: max(h,1), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: d)
    }

    /// A2 HDR: float(rgba16Float) 누적 타깃 — >1.0 합 보존(bgra8 하드클램프 백화 방지). 톤맵 패스 입력.
    func makeOffscreenHDR(_ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(w,1), height: max(h,1), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: d)
    }

    /// 헤드리스 캡처용 bgra8 타겟(라이브 파이프라인과 동일 포맷, getBytes 가능하도록 .shared).
    func makeOffscreenBGRA(_ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: max(w,1), height: max(h,1), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    /// 반사(REFLECTION) 전용 스냅샷 — **밉체인을 갖는다.**
    ///
    /// WE 는 `texSample2DLod(g_Texture3, uv, roughness * g_Texture3MipMapInfo)` 로 러프니스만큼
    /// 흐려진 밉을 반사한다(`generic4.frag:159`). 우리 스냅샷은 밉이 없어 레벨 0 고정이었고,
    /// 그래서 반사 소스가 가늘고 성긴 씬에서는 밝은 텍셀에 맞은 픽셀만 튀고 나머지는 검게 남았다
    /// (3470948192 의 성단이 그 사례 — 검은 알베도라 반사가 유일한 광원인데, 블러가 없으니
    /// 매끈한 흰 테 대신 알갱이진 점만 나왔다).
    ///
    /// `pooledOffscreen` 을 그대로 쓰지 않는 이유: 그 풀은 밉 없는 텍스처를 크기별로 재사용하고
    /// acc 블릿·컴포지션 등 여러 경로가 공유한다. 밉을 켜면 그 전부의 메모리가 1.33배가 되고
    /// blit 정합 전제도 흔들린다 — 반사만 별도 풀을 쓴다.
    func reflectionSnapshot(_ w: Int, _ h: Int, _ device: MTLDevice, hdr: Bool) -> MTLTexture? {
        let key = "refl\(hdr ? "h" : "b")\(max(w, 1))x\(max(h, 1))"
        if let t = reflectionSnapshotPool[key] { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: hdr ? .rgba16Float : .bgra8Unorm,
            width: max(w, 1), height: max(h, 1), mipmapped: true)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private   // 밉 생성이 GPU 전용이라 shared 일 이유가 없다
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        reflectionSnapshotPool[key] = t
        return t
    }

    func makeTexture(_ rgba: Data, _ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        rgba.withUnsafeBytes { ptr in
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: w * 4)
        }
        return t
    }

    /// 네이티브 BC 업로드: LZ4 해제된 raw BC 블록을 `.bc1/2/3_rgba`(sRGB 아님 — rgba8Unorm 선형 파이프라인과
    /// 동일 취급)로 직접 올린다. bytesPerRow=소스 decode-dims stride 라 Metal 이 패딩 블록을 스킵(크롭 무비용,
    /// 부분 엣지 블록은 GPU 엣지 클램프 — 실측 검증). CPU DXT 디코드·RGBA 상주(≈12× 큼) 동시 회피.
    func makeBCTexture(_ bc: TexDecoder.NativeBCUpload, _ device: MTLDevice) -> MTLTexture? {
        let pf: MTLPixelFormat
        switch bc.format {
        case .bc1: pf = .bc1_rgba
        case .bc2: pf = .bc2_rgba
        case .bc3: pf = .bc3_rgba
        }
        guard bc.width > 0, bc.height > 0 else { return nil }
        // mipCount>1(bc.levels>1)이면 mipmapLevelCount 전체 할당 + 레벨별 업로드(TEX 저장 mip 체인 —
        // TexDecoder.nativeBC 가 레벨별 크롭 규약으로 채움). 레벨 검증 실패 시 단일 레벨(종전 동작 무회귀).
        let levels = validMipLevels(bc)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pf, width: bc.width, height: bc.height,
                                                            mipmapped: levels.count > 1)
        if levels.count > 1 { desc.mipmapLevelCount = levels.count }   // 저장 체인이 최대 레벨보다 짧을 수 있음(실물 DJK_1: 9/11)
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        for (i, lv) in levels.enumerated() {
            lv.blocks.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                t.replace(region: MTLRegionMake2D(0, 0, lv.width, lv.height), mipmapLevel: i,
                          withBytes: base, bytesPerRow: lv.bytesPerRow)
            }
        }
        return t
    }

    /// mip 체인 업로드 전 검증: 레벨별 타깃 dims == max(1, base >> L) 진행 + Metal 허용 레벨 수 이내.
    /// 하나라도 어긋나면 첫 레벨만 반환(= 단일 레벨 업로드, 종전과 비트동일).
    private func validMipLevels(_ bc: TexDecoder.NativeBCUpload) -> [TexDecoder.NativeBCUpload.NativeBCMipLevel] {
        let first = bc.levels.first ?? TexDecoder.NativeBCUpload.NativeBCMipLevel(
            blocks: bc.blocks, width: bc.width, height: bc.height, bytesPerRow: bc.bytesPerRow)
        guard bc.levels.count > 1 else { return [first] }
        let maxLevels = 1 + Int(log2(Double(max(bc.width, bc.height))).rounded(.down))
        guard bc.levels.count <= maxLevels else { return [first] }
        for (i, lv) in bc.levels.enumerated() {
            guard lv.width > 0, lv.height > 0,
                  lv.width == max(1, bc.width >> i), lv.height == max(1, bc.height >> i) else { return [first] }
        }
        return bc.levels
    }

    /// 다중 mip rgba8 업로드(mipCount>1 텍스처의 CPU 경로): levels[0] = mip0(makeTexture 와 동일 내용·dims).
    /// 레벨 검증(dims 진행 = max(1, base >> L), 픽셀 수, Metal 레벨 상한) 실패 시 nil → 호출자가 단일 레벨
    /// makeTexture 폴백(무회귀). generateMipmaps 미사용 — WE 가 저장한 mip 을 그대로 올리는 게 정본 근접
    /// (저장 데이터가 곧 엔진이 축소 시 샘플하는 데이터라는 추론 — RE 확정 아님, TexImage.mipChain 주석 참조).
    func makeMipmappedTexture(_ levels: [(pixels: Data, width: Int, height: Int)], _ device: MTLDevice) -> MTLTexture? {
        guard let first = levels.first, levels.count > 1, first.width > 0, first.height > 0 else { return nil }
        let maxLevels = 1 + Int(log2(Double(max(first.width, first.height))).rounded(.down))
        guard levels.count <= maxLevels else { return nil }
        for (i, lv) in levels.enumerated() {
            guard lv.width == max(1, first.width >> i), lv.height == max(1, first.height >> i),
                  lv.pixels.count >= lv.width * lv.height * 4 else { return nil }
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: first.width,
                                                            height: first.height, mipmapped: true)
        desc.mipmapLevelCount = levels.count
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        for (i, lv) in levels.enumerated() {
            lv.pixels.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                t.replace(region: MTLRegionMake2D(0, 0, lv.width, lv.height), mipmapLevel: i,
                          withBytes: base, bytesPerRow: lv.width * 4)
            }
        }
        return t
    }

    /// 씬 이미지 텍스처 1장 → MTLTexture(+dims). BC(DXT)면 네이티브 BC 업로드 시도(supportsBC 게이트 +
    /// WAPLE_BC_NATIVE!=0 킬스위치), 비-BC/멀티페이지/미지원이면 기존 CPU rgba()+makeTexture 폴백.
    /// 반환 dims 는 두 경로 동일(파리티). buildLayers·resolveTextureWithFrames·3D 빌보드 공용.
    /// keepFullAtlas(스프라이트 아틀라스)도 네이티브 BC 허용 — spriteFrameTexture 가 blit.copy 가 아닌
    /// f_spriteframe 샘플로 프레임을 뽑으므로 아틀라스가 BC 로 상주해도 무방(전 크롭 금지 위해 nativeBC 에 full dims 요청).
    func makeImageTexture(tex: TexImage, data: Data, device: MTLDevice, keepFullAtlas: Bool = false)
        -> (texture: MTLTexture, width: Int, height: Int)? {
        if ProcessInfo.processInfo.environment["WAPLE_BC_NATIVE"] != "0",
           device.supportsBCTextureCompression,
           let bc = TexDecoder.nativeBC(from: tex, data: data, properties: variantProperties, keepFullAtlas: keepFullAtlas),
           let t = makeBCTexture(bc, device) {
            return (t, bc.width, bc.height)
        }
        // CPU 경로 mip 체인(mipCount>1 + 기본 image + 비아틀라스 — rgbaLevels 가 자격 판정): 전체 레벨 디코드·
        // 업로드. 반환 dims 는 levels[0] = rgba() 와 동일(파리티). 자격 외/검증 실패 시 nil → 기존 단일 레벨 경로.
        if let levels = TexDecoder.rgbaLevels(from: tex, data: data, properties: variantProperties,
                                              keepFullAtlas: keepFullAtlas),
           let first = levels.first,
           let t = makeMipmappedTexture(levels, device) {
            return (t, first.width, first.height)
        }
        guard let dec = TexDecoder.rgba(from: tex, data: data, properties: variantProperties, keepFullAtlas: keepFullAtlas),
              let t = makeTexture(dec.pixels, dec.width, dec.height, device) else { return nil }
        return (t, dec.width, dec.height)
    }

    private func bitmapRGBAFile(_ path: String) -> (pixels: Data, width: Int, height: Int)? {
        guard path.hasPrefix("/"),
              let image = NSImage(contentsOfFile: path),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0 else { return nil }
        let width = cg.width
        let height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (Data(pixels), width, height)
    }

    /// 텍스트 오브젝트 준비: 폰트 바이트(pkg→base-assets) + 스크립트 엔진 + 초기 텍스트 래스터.
    func buildTexts(doc: SceneDocument, package: ScenePackage, device: MTLDevice) -> [GPUText] {
        var out: [GPUText] = []
        // F741(S-13): 텍스트 이펙트의 _rt_imageLayerComposite 바인드용 치환 맵(buildLayers 와 동일 규약).
        let compositeImageTextures = doc.layers.reduce(into: [Int: String]()) { acc, layer in
            guard layer.id != 0, !layer.textureEntryName.isEmpty else { return }
            acc[layer.id] = layer.textureEntryName
        }
        for (uid, t) in doc.texts.enumerated() {
            let isSystem = t.font.hasPrefix("systemfont_") || t.font.isEmpty
            let fontData = isSystem ? nil : quietAssetData(t.font, package: package)
            if !isSystem && fontData == nil { NSLog("%@", "[Waple] text font missing (system fallback): \(t.font)") }
            // F743(S-34): JS 디스크립터 인덱스 = doc.layers.count + uid(sceneScriptLayers 의 이미지→텍스트 순서).
            let descriptorIndex = doc.layers.count + uid
            // 씬 공유 컨텍스트 로드(top-level 사이드이펙트 실행). update 없는 스크립트는 텍스트 갱신에
            // 못 쓰므로 엔진 nil 취급(정적 텍스트 유지) — 로드 자체는 shared 통신을 위해 수행.
            let loaded = t.script.flatMap { makeScriptEngine($0, layerName: t.name.isEmpty ? nil : t.name,
                                                             currentLayerIndex: descriptorIndex,
                                                             scriptPropsJSON: t.scriptProps) }
            if t.script != nil && loaded == nil { NSLog("%@", "[Waple] text script failed to load (empty text): \(t.script!.prefix(60))") }
            let engine = (loaded?.hasUpdate == true) ? loaded : nil
            let initial = engine != nil ? (engine!.evaluate(current: t.text) ?? "") : t.text
            // 프로퍼티 스크립트(origin/scale/alpha/color/angles/visible, F218/F219): 레이어 propScripts
            // 와 동일 규약(visible 먼저 로드 — top-level shared 사이드이펙트 순서).
            var propScripts: [(key: String, engine: TextScriptEngine)] = []
            for key in ["visible", "color", "alpha", "origin", "scale", "angles"] {
                guard let src = t.propertyScripts[key] else { continue }
                let ownerName = t.name.isEmpty ? nil : t.name
                if let e = makeScriptEngine(src, layerName: ownerName, currentLayerIndex: descriptorIndex,
                                            scriptPropsJSON: t.propertyScriptProps[key]) {
                    propScripts.append((key, e))
                    if e.hasUpdate { hasAnimations = true }
                }
            }
            var g = GPUText(texture: nil, vertexBuffer: nil,
                            tint: SIMD4(t.color.x, t.color.y, t.color.z, t.alpha),
                            order: t.order, engine: engine, lastText: initial,
                            fontData: fontData, systemFontName: isSystem ? t.font : nil, def: t,
                            uid: uid, initialVisible: t.initialVisible,
                            hiddenByAncestor: t.hiddenByAncestor, propScripts: propScripts)
            rasterize(&g, device: device)
            // F741(S-13): 텍스트 effects[](F693 파스·보존)를 래스터 텍스처에 적용할 GPU 체인 —
            // 레이어와 동일 빌더(buildEffectChain). texRes 는 초기 래스터 dims 로 베이크(문자열이
            // 바뀌어 재래스터돼도 효과 해상도는 초기값 유지 — ponytail: 갱신 시 재빌드는 후속 과제).
            if !t.effects.isEmpty, g.texture != nil {
                g.effects = buildEffectChain(t.effects, package: package, device: device,
                                             texW: max(1, Int(g.rasterWidth)), texH: max(1, Int(g.rasterHeight)),
                                             compositeImageTextures: compositeImageTextures)
                if !g.effects.isEmpty { hasEffects = true }
            }
            if engine != nil { hasScriptedText = true }
            out.append(g)
        }
        return out
    }

    /// 텍스트 재래스터: lastText → 텍스처 + 앵커 정렬 쿼드. 빈 텍스트 → 텍스처 nil(드로우 스킵).
    /// rasterWidth/Height(비-스케일 글리프 픽셀 크기)를 저장 — encodeText 가 프로퍼티 스크립트로
    /// per-frame 지오메트리를 재계산할 때 재래스터 없이 재사용한다.
    func rasterize(_ g: inout GPUText, device: MTLDevice) {
        guard let r = TextRasterizer.render(text: g.lastText, fontData: g.fontData,
                                            systemFontName: g.systemFontName, pointSize: g.def.pointSize,
                                            maxWidth: g.def.maxWidth, maxRows: g.def.maxRows,
                                            ellipsis: g.def.overflowEllipsis, justify: g.def.justify,
                                            align: g.def.horizontalAlign) else {
            g.texture = nil; g.vertexBuffer = nil
            return
        }
        g.texture = makeTexture(r.rgba, r.width, r.height, device)
        g.rasterWidth = Float(r.width); g.rasterHeight = Float(r.height)
        let w = Float(r.width) * g.def.scale.x, h = Float(r.height) * g.def.scale.y
        let x0: Float
        switch g.def.horizontalAlign {
        case "left": x0 = g.def.origin.x
        case "right": x0 = g.def.origin.x - w
        default: x0 = g.def.origin.x - w / 2
        }
        // W1-yaxis: y0 은 항상 "박스의 작은 쪽 scene-y"(y0+h 가 큰 쪽) — top/bottom 케이스는
        // quadVertices/alignedCenter 의 새 y-up 부호(top→+hh, bottom→−hh)와 정합하도록 스왑
        // (textAlignmentString 주석의 "정확히 일치" 불변 유지 — encodeText 의 애니 재계산 경로가
        // quadVertices 를 그대로 쓰므로 이 정적 경로도 같은 관례를 따라야 함).
        let y0: Float
        switch g.def.verticalAlign {
        case "top": y0 = g.def.origin.y - h
        case "bottom": y0 = g.def.origin.y
        default: y0 = g.def.origin.y - h / 2
        }
        // uv(0,0) 이 화면 위쪽(scene-y 큰 쪽 = y0+h)에 오도록 quadVertices 와 동형으로 재페어링.
        let tl = sceneToNDC(x0, y0 + h), tr = sceneToNDC(x0 + w, y0 + h)
        let br = sceneToNDC(x0 + w, y0), bl = sceneToNDC(x0, y0)
        let verts: [SIMD4<Float>] = [
            SIMD4(tl.x, tl.y, 0, 0), SIMD4(tr.x, tr.y, 1, 0), SIMD4(br.x, br.y, 1, 1),
            SIMD4(tl.x, tl.y, 0, 0), SIMD4(br.x, br.y, 1, 1), SIMD4(bl.x, bl.y, 0, 1),
        ]
        g.vertexBuffer = device.makeBuffer(bytes: verts, length: MemoryLayout<SIMD4<Float>>.stride * verts.count)
    }
}

/// T09-D2: 이펙트 **내부** 패스 라우팅(= `passes[].compose` 핑퐁)의 결정 로직.
///
/// 원본(체인 루프 `0x1401e9b8f–0x1401e9bf0`)은 패스를 그린 **직후** 패스 플래그 비트 0x2(compose,
/// 파스 `0x1401e7d96–0x1401e7dcf`)를 보고, 렌더 타깃 핑퐁 쌍 `renderer+0x2c8`/`+0x2d0` 에서
/// 반대쪽으로 갈아탄다(`0x1401e9bad–0x1401e9bf0`: 현 타깃 pop → 반대쪽 push → 패리티 `edi` 반전).
/// 그 패리티는 다음 드로우(`0x1401e9b85` 의 4번째 인자 `r9d = edi`)로 넘어가 **`previous` 가 어느
/// 쪽을 읽는지**를 정한다. 즉 compose 의 의미는 "이 패스의 출력이 다음 패스의 `previous` 가 된다".
///
/// ⚠️ 실측 정정: 갈아타기 가드는 "뒤에 패스가 남았는가" 가 **아니다**. `0x1401e9b9a–0x1401e9ba5` 는
/// `inc r15d; cmp r15d, [rsp+0x180]; jge skip` 로, 전역 렌더타깃 예산 `[rsp+0x180]` 과 비교한다.
/// 그 예산은 `0x1401e951a` 에서 `renderer+0x320` 을 읽어 온 값이고(`0x1401e9522`; 플래그
/// `renderer+0x304 & 0x10` 이 꺼져 있으면 −1 — `0x1401e952b`), `renderer+0x320` 은 풀 산정
/// `0x1401e6300–0x1401e63a6` 이 켜진 이펙트마다 `composeCount + 1` 을 누산한 총합이다
/// (`0x1401e633f`·`0x1401e6345`·`0x1401e6347`). `r15d` 는 compose 패스마다 1(`0x1401e9b9a`),
/// 이펙트가 끝날 때마다 1(`0x1401e9c5c`) 오르므로 총 증가량이 정확히 그 총합이다 → **compose 패스
/// 에서는 예산이 항상 남아 있어 갈아타기가 무조건 일어난다**(예산 비교는 안전 클램프).
///
/// 그럼에도 아래 규칙이 "뒤에 출력 패스가 남았을 때만" 갈아타는 이유: 원본의 핑퐁 쌍은 **렌더러
/// 전역**이라 마지막 compose 가 갈아타도 이펙트 출력의 소재지가 패리티(`0x1401e9c96`: `edi = r12d`)
/// 로 다음 이펙트에 그대로 전달된다. Waple 의 `applyEffect` 는 호출부가 준 `dst` 로 나가야 하는
/// src→dst 계약이므로, 마지막 출력 패스만은 스크래치가 아니라 실제 `dst` 로 고정해야 등가다
/// (끝난 뒤 블릿으로 옮기면 복사가 1회 늘 뿐 결과는 같다 — 그래서 안 한다).
///
/// Metal 비의존 순수 값 로직이다 — 리눅스에서 이 타입만 떼어 컴파일·실행해 표를 검증한다.
enum EffectChainRouting {
    /// 패스의 `previous`(bind source == −1) 슬롯이 읽을 곳.
    enum Source: Equatable {
        /// `applyEffect(src:)` — 이펙트 입력. compose 가 하나도 없으면 전 패스가 이 값이다(= 종전 동작).
        case effectInput
        /// 앞선 compose 패스가 써 둔 스크래치 오프스크린.
        case scratch(Int)
    }
    /// 패스가 그려 넣을 곳.
    enum Sink: Equatable {
        /// 이름 있는 fbo(`pass.target != nil`) — 핑퐁 대상이 아니다.
        case fbo
        /// compose 패스이고 뒤에 출력 패스가 더 남았다 → 스크래치로 나가고 다음 패스의 `previous` 가 된다.
        case scratch(Int)
        /// 이펙트 출력 = `applyEffect(dst:)`.
        case output
        /// `command:"swap"` — 드로우가 없다(포인터 교환만).
        case none
    }
    struct Route: Equatable {
        let sink: Sink
        let source: Source
    }
    /// 라우팅에 필요한 패스 속성만 추린 입력(파이프라인/텍스처 무관 — 그래서 순수 함수가 된다).
    struct PassKind: Equatable {
        /// `TranslatedPass.target != nil`.
        let hasFBOTarget: Bool
        /// `TranslatedPass.compose`.
        let compose: Bool
        /// `TranslatedPass.swapPair != nil`.
        let isSwap: Bool
        init(hasFBOTarget: Bool, compose: Bool, isSwap: Bool = false) {
            self.hasFBOTarget = hasFBOTarget
            self.compose = compose
            self.isSwap = isSwap
        }
    }
    struct Plan: Equatable {
        /// 입력과 1:1 대응(같은 개수·같은 순서).
        let routes: [Route]
        /// 필요한 스크래치 오프스크린 장수. 0 이면 **호출부는 스크래치를 한 장도 잡지 않는다**
        /// (= compose 없는 이펙트의 무회귀 조기 분기).
        let scratchCount: Int
    }

    /// 상한: `passes.filter(\.compose).count`(원본의 `composeCount + 1` 풀 산정 `0x1401e633f` 와 같은
    /// 세는 법 — 원본은 이펙트 출력분 +1 을 더 잡지만 Waple 은 그 자리를 `dst` 가 대신한다).
    /// 실제로는 그보다 적을 수 있다(마지막 출력 패스의 compose 는 갈아타지 않으므로).
    static func plan(_ passes: [PassKind]) -> Plan {
        // 드로우하는 출력 패스(= fbo 타깃 없음 & swap 아님)의 총 개수 — "마지막 하나" 를 알아야
        // 그것만 `dst` 로 고정할 수 있다. swap 패스도 `target == nil` 이라(makeSwapPass) 반드시 제외한다.
        let outputTotal = passes.filter { !$0.hasFBOTarget && !$0.isSwap }.count
        var routes: [Route] = []
        routes.reserveCapacity(passes.count)
        var source: Source = .effectInput
        var scratchCount = 0
        var outputsSeen = 0
        for p in passes {
            if p.isSwap {
                // 드로우 없음 — 체인 상태(source)도 건드리지 않는다.
                routes.append(Route(sink: .none, source: source))
                continue
            }
            if p.hasFBOTarget {
                // fbo 타깃 패스: compose 여도 갈아타지 않는다. 원본은 타깃을 안 보고 갈아타지만,
                // 그렇게 하면 `previous` 가 **아무도 안 쓴** 핑퐁 반대쪽을 가리키게 된다(원본에서도
                // 그 자리는 미기록 상태다). 동봉 자산의 compose 2건은 전부 출력 패스라 도달 0건이고,
                // 워크샵 자산에서도 "쓰레기를 읽는 쪽" 보다 "체인을 유지하는 쪽" 이 안전하다.
                routes.append(Route(sink: .fbo, source: source))
                continue
            }
            outputsSeen += 1
            let isLastOutput = (outputsSeen == outputTotal)
            if p.compose && !isLastOutput {
                let idx = scratchCount
                scratchCount += 1
                routes.append(Route(sink: .scratch(idx), source: source))
                source = .scratch(idx)      // 다음 패스의 `previous` = 방금 쓴 스크래치
            } else {
                // compose 가 아니면 종전과 동일하게 그냥 `dst` 로 쓴다(뒤 패스가 덮어써도 종전 동작
                // 그대로 — 원본도 갈아타지 않으면 같은 렌더 타깃에 연속으로 쓴다).
                routes.append(Route(sink: .output, source: source))
            }
        }
        return Plan(routes: routes, scratchCount: scratchCount)
    }
}
