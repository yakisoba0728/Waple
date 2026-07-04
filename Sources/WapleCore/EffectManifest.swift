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
        public let scale: Int          // 해상도 나눗수(4 = 1/4)
        public init(name: String, scale: Int) { self.name = name; self.scale = scale }
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
                guard let name = b["name"] as? String, let idx = b["index"] as? Int else { continue }
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
        for f in (obj["fbos"] as? [[String: Any]]) ?? [] {
            guard let name = f["name"] as? String else { continue }
            let scale = (f["scale"] as? Int) ?? Int(f["scale"] as? Double ?? 1)
            fbos.append(FBO(name: name, scale: Swift.max(1, scale)))
        }
        return EffectManifest(passes: passes, fbos: fbos)
    }
}
