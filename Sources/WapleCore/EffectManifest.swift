import Foundation

/// effect.json 매니페스트(실물 스키마): 멀티패스 + 이름 있는 FBO(다운스케일 타깃).
/// bind.name "previous" = 효과 입력(레이어 베이스 또는 이전 효과 출력), 그 외 = fbos 의 이름.
/// target 부재 = 효과 출력에 기록.
public struct EffectManifest: Equatable {
    public struct Bind: Equatable {
        public let name: String
        public let index: Int
        public init(name: String, index: Int) { self.name = name; self.index = index }
    }
    public struct Pass: Equatable {
        public let material: String?   // materials/....json (일반)
        public let shader: String?     // 직지정 스타일(passes[0].shader)
        public let target: String?     // fbo 이름 | nil(효과 출력)
        public let binds: [Bind]
        public let command: String?    // "copy" 등 셰이더 없는 명령 패스(실물 motionblur 의 buffer 지속)
        public let source: String?     // command=copy 의 원본 fbo 이름
        public init(material: String?, shader: String?, target: String?, binds: [Bind],
                    command: String? = nil, source: String? = nil) {
            self.material = material; self.shader = shader; self.target = target; self.binds = binds
            self.command = command; self.source = source
        }
    }
    public struct FBO: Equatable {
        public let name: String
        public let scale: Int          // 해상도 나눗수(4 = 1/4) — fixedWidth/fixedHeight 가 있으면 무시.
        /// X-①: `fit`(정사각 고정 크기, 실물 cursorripple `_rt_EightBuffer1/2` fit:512) 또는
        /// `width`+`height`(실물 glitter `_rt_GlitterTiles` 256×256) — dst 비례 대신 절대 픽셀 크기.
        /// nil 이면 종전처럼 scale 기반(dst/scale).
        public let fixedWidth: Int?
        public let fixedHeight: Int?
        /// X-①: `uvs:"repeat"` — 텍셀 랩(실물 glitter 타일 아틀라스). 기본 false(=clamp, 기존 bind-slot 관례).
        public let uvsRepeat: Bool
        public init(name: String, scale: Int, fixedWidth: Int? = nil, fixedHeight: Int? = nil, uvsRepeat: Bool = false) {
            self.name = name; self.scale = scale
            self.fixedWidth = fixedWidth; self.fixedHeight = fixedHeight; self.uvsRepeat = uvsRepeat
        }
    }

    public let passes: [Pass]
    public let fbos: [FBO]

    public init(passes: [Pass], fbos: [FBO]) { self.passes = passes; self.fbos = fbos }

    public static func parse(_ data: Data) -> EffectManifest? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawPasses = obj["passes"] as? [[String: Any]], !rawPasses.isEmpty else { return nil }
        var passes: [Pass] = []
        for p in rawPasses {
            var binds: [Bind] = []
            for b in (p["bind"] as? [[String: Any]]) ?? [] {
                guard let name = b["name"] as? String, let idx = safeInt(b["index"]), idx >= 0 else { continue }
                binds.append(Bind(name: name, index: idx))
            }
            passes.append(Pass(material: p["material"] as? String,
                               shader: p["shader"] as? String,
                               target: p["target"] as? String,
                               binds: binds,
                               command: p["command"] as? String,
                               source: p["source"] as? String))
        }
        var fbos: [FBO] = []
        // X-①-sweep: **개수**도 상한을 둔다. 종전엔 치수(8192)만 클램프했는데, 소비처
        // (`SceneRendererFrameEncoder.swift:1958-1963`, `:301-315`)가 선언된 FBO 를 **사용 여부와
        // 무관하게 매 프레임 체크아웃**하므로 개수만으로 GPU 메모리와 프레임 시간을 밀어낼 수 있다.
        // 64 인 이유: 동봉 자산 101개 effect.json 의 최대가 한 자릿수라 정상 저작은 근처에도 안 온다.
        let maxFBOs = 64
        for f in (obj["fbos"] as? [[String: Any]]) ?? [] {
            guard fbos.count < maxFBOs else { break }
            guard let name = f["name"] as? String else { continue }
            let scale = safeInt(f["scale"]) ?? 1
            // X-①: 8192 클램프 — 신뢰불가 effect.json 정수가 makeTexture 에 그대로 흘러가 과대 할당/
            // 실패를 유발하지 않도록(B1 8192 가드와 동일 원칙). 0 이하는 무시(scale 기반 폴백 유지).
            func clampedFixed(_ v: Any?) -> Int? {
                guard let n = safeInt(v), n > 0 else { return nil }
                return Swift.min(n, 8192)
            }
            var fixedW = clampedFixed(f["fit"])
            var fixedH = fixedW
            if let w = clampedFixed(f["width"]) { fixedW = w }
            if let h = clampedFixed(f["height"]) { fixedH = h }
            let uvsRepeat = (f["uvs"] as? String) == "repeat"
            fbos.append(FBO(name: name, scale: Swift.max(1, scale), fixedWidth: fixedW, fixedHeight: fixedH, uvsRepeat: uvsRepeat))
        }
        return EffectManifest(passes: passes, fbos: fbos)
    }

    private static func safeInt(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double {
            guard d.isFinite, d >= Double(Int.min), d < Double(Int.max) else { return nil }
            return Int(d)
        }
        return nil
    }
}
