import Foundation
import simd

/// 한 파티클의 상태. 내부 `pos`/`vel`/`rotation` 은 물리 적분값(base).
/// `size`/`alpha`/`color`/`pos`(반환 스냅샷) 는 age 기반 파생값으로 매 step 재계산된다.
public struct Particle {
    public var pos = SIMD3<Float>(0, 0, 0)        // 씬 로컬 좌표(Y-up)
    public var vel = SIMD3<Float>(0, 0, 0)
    public var color = SIMD3<Float>(1, 1, 1)      // 0..1
    public var rotation = SIMD3<Float>(0, 0, 0)   // radians
    public var angularVel = SIMD3<Float>(0, 0, 0)
    public var size: Float = 1
    public var alpha: Float = 1
    public var age: Float = 0
    public var lifetime: Float = 1
    /// 스폰 순 고유 id(자식 인스턴스 ↔ 부모 파티클 연동용).
    public var uid: Int = 0
    /// 스프라이트시트 시퀀스 인덱스(mapsequence 이니셜라이저가 스폰 시 확정). -1 = 미지정
    /// (시트가 있으면 렌더러가 age/frametime 으로 gif 애니).
    public var frame: Float = -1
    public var initialSize: Float = 1
    public var initialAlpha: Float = 1
    public var initialColor = SIMD3<Float>(1, 1, 1)
    // 스폰 시 결정되는 진동 파라미터(절대식 평가).
    var oscPosFreq: Float = 0, oscPosScale: Float = 0, oscPosPhase: Float = 0
    var oscPosMask = SIMD3<Float>(0, 0, 0)
    var oscAlphaFreq: Float = 0, oscAlphaPhase: Float = 0
    var oscSizeFreq: Float = 0, oscSizePhase: Float = 0
    // 난류(turbulence): 스폰 시 결정되는 파티클별 속도/위상(노이즈 흐름장 이류에 사용).
    var turbSpeed: Float = 0, turbPhase: Float = 0
    /// F628: 2번째 이후 turbulence 오퍼레이터의 파티큘별 속도/위상(첫 번째는 위 스칼라 — 시드 비트동일).
    var turbExtra: [(speed: Float, phase: Float)] = []
    // remapvalue 노이즈 입력의 파티클별 위상(탈동기 — 전 파티클 동일 곡선 방지).
    var remapPhase: Float = 0
    /// 트레일 렌더러용 최근 위치 히스토리(로컬 Y-up). oldest→newest, 마지막=현재 위치.
    /// 스프라이트 렌더러에서는 비어 있다(불필요 복사 회피).
    public var history: [SIMD3<Float>] = []
    public init() {}
}

/// 순수 CPU 파티클 시뮬레이터(Metal/벽시계 無, 시드 결정적).
public struct ParticleSimulator {
    private let def: ParticleSystemDef
    private var rng: SplitMix64
    private var particles: [Particle] = []
    private var acc: [Float]
    private var time: Float = 0

    // 파생 오퍼레이터(스폰 시/표시 시 참조) 캐시.
    private let movements: [(gravity: SIMD3<Float>, drag: Float)]
    private let angulars: [(force: SIMD3<Float>, drag: Float)]
    private let sizeChanges: [(st: Float, et: Float, sv: Float, ev: Float)]
    private let colorChanges: [(st: Float, et: Float, sv: SIMD3<Float>, ev: SIMD3<Float>)]
    private let alphaFade: (fin: Float, fout: Float)?
    private let oscPosOp: (fmin: Float, fmax: Float, smin: Float, smax: Float, pmin: Float, pmax: Float, mask: SIMD3<Float>)?
    private let oscAlphaOp: (fmin: Float, fmax: Float, smin: Float, smax: Float, pmin: Float, pmax: Float)?
    /// G-C2-03 페이드 창. 오실레이터는 파티클별 위상을 스폰 때 굳히므로 창은 시뮬 쪽에 둔다.
    private let oscAlphaBlend: BlendWindow
    private let oscPosBlend: BlendWindow
    private let oscSizeOp: (fmin: Float, fmax: Float, smin: Float, smax: Float, pmin: Float, pmax: Float)?
    private let alphaChanges: [(st: Float, et: Float, sv: Float, ev: Float)]
    private enum CachedRemap {
        case velocity(min: SIMD3<Float>, max: SIMD3<Float>, fbm: Bool, scale: Float)
        case speed(min: Float, max: Float, fbm: Bool, scale: Float)
        case general(RemapSpec)   // remapValueEx — 엔진 어휘 확장 파이프라인
    }
    private let remaps: [CachedRemap]
    /// remapValueEx 중 표시 파생(opacity/color/size) 동사 보유 — display() 조기 우회 게이트.
    private let hasDisplayRemaps: Bool
    private let attractors: [(scale: Float, threshold: Float, target: SIMD3<Float>,
                              delete: Bool, flags: Int)]
    /// maintaindistancetocontrolpoint — CP 중심 반지름 `distance` 구면으로 **위치를 투영**한다.
    private let maintainDists: [(distance: Float, variableStrength: Float, target: SIMD3<Float>)]
    /// boids — 순수 입자간 상호작용(CP 무관). 전 파티클을 동시에 봐야 해서 per-particle 루프가
    /// 아니라 **별도 선행 패스**로 돈다.
    private let boidsOps: [(sepThr: Float, nbrThr: Float, maxSpeed: Float,
                            sepF: Float, aliF: Float, cohF: Float, flags: Int)]
    /// boids 서브샘플 위상용 프레임 카운터(실물 `[ctx+0x144]` 는 u32).
    /// **Int 로 둔다** — `UInt32(n)` 같은 좁힘을 만들면 `maxcount` 가 신뢰 경계 밖이라
    /// (`{"maxcount": 9e18}` 이면 `n` 이 UInt32 를 넘어) 트랩이 된다. 실물의 2^32 감김과는
    /// 60fps 기준 2.3년 뒤에나 갈리므로 관측 밖이다.
    private var frameCounter: Int = 0
    private let vortices: [(axis: SIMD3<Float>, dIn: Float, dOut: Float, sIn: Float, sOut: Float,
                            offset: SIMD3<Float>, audio: AudioProcessing?,   // F624: 오디오반응 속도 배수
                            centerForce: Float, ring: VortexRing?, flags: Int)]
    // F628: 난류 흐름장 배열(전 turbulence 오퍼레이터 누적 — 종전 "first wins"는 2번째를 드롭).
    // 파티클별 속도/위상 범위(smin/smax, pmin/pmax)는 스폰 시 뽑아 고정, 나머지는 장 파라미터.
    private let turbulences: [(smin: Float, smax: Float, scale: Float, timeScale: Float,
                              mask: SIMD3<Float>, pmin: Float, pmax: Float, blend: BlendWindow)]
    // G-C2-01 `capvelocity`: 속도 크기 상한(오퍼레이터 출현 순). 실물 VM op 0x12 @0x1402446fd.
    private let velocityCaps: [(maxSpeed: Float, blend: BlendWindow)]
    // G-C2-01 `reducemovementnearcontrolpoint`: CP 근접 감쇠(오퍼레이터 출현 순).
    // invRange/redDelta 는 실물 ctor(0x1401cd38d–0x1401cd3e7)가 굽는 파생값을 그대로 옮긴 것 —
    // 퇴화 케이스 대입값(각각 −0.0 / 1.0)까지 원본과 같다.
    private let reduceMoves: [(target: SIMD3<Float>, distIn: Float, invRange: Float,
                               redIn: Float, redDelta: Float)]
    // 트레일 히스토리 설정(스프라이트면 0 → 미기록).
    private let trailSamples: Int
    // controlpointattract/vortex 가 있으면 속도 상한(폭주 방지, px/s).
    private let speedCap: Float?
    // 이미터 오디오반응 보유 여부(무보유 시 rate 스케일 전면 우회 → 기존 방출 경로 비트동일).
    private let hasEmitterAudio: Bool

    // MARK: - 주기(periodic) 방출 상태 (키 보유 이미터만 활성 — 묵보유 이미터는 기존 경로 비트동일)

    /// [추정] 주기 컨트롤러 상태(WE 에디터 어휘 규약 — 스트링 @0x48f3c0–0x48e2b8, 시뮬 코드는
    /// 디컴파일 코퍼스 누락). ON 윈도우(duration) 동안 rate/버스트 방출(창당 quota 상한),
    /// 잔여 소진 시 OFF 딜레이(delay) 드로 → 다시 ON 드로 반복. 드로 순서: duration → spawn → delay.
    private struct PeriodicState {
        var enabled = false
        var started = false         // 첫 ON 진입(duration 드로) 완료
        var on = false              // 현재 ON 윈도우 진행 중
        var remaining: Float = 0    // 현재 페이즈 잔여 시간
        var emitted = 0             // 현재 ON 윈도우 내 누적 방출 수(quota 판정)
        var window: Float = 0       // 현재 ON 윈도우 총 길이(암시 rate 산정용)
    }
    private var periodicStates: [PeriodicState]

    // MARK: 자식 시스템 상태 (부모 sim 이 링크별 자식 sim 인스턴스를 구동)

    private struct ChildInstance {
        var sim: ParticleSimulator
        let parentUID: Int          // 0 = always(부모 파티클 무관)
        let oneShot: Bool           // spawnBurst/deathBurst — 첫 스텝 후 방출 정지
        var fired: Bool = false
    }
    private var childStates: [[ChildInstance]]
    private var childDisplaysCache: [[Particle]]
    private let parentSeed: UInt64
    private var nextUID = 1
    /// 자식 인스턴스 제어(부모 sim 이 설정): 스폰 위치 오프셋 / 방출 정지(고아·원샷).
    var emitOrigin = SIMD3<Float>(0, 0, 0)
    /// 방출 정지(적분·노화는 계속 — 기존 파티클은 수명대로 드레인). 부모 sim 이 고아/원샷 자식에
    /// 쓰던 채널이고, WE `thisLayer.pause()`(IParticleSystem.pause) 결선도 같은 의미라 렌더러가
    /// 밖에서 세울 수 있게 public 이다 — 가시성 폭만 넓혔고 동작은 불변.
    public var emissionPaused = false
    /// 누적 시간이 방출 게이트(def.startTime)를 통과했는가 — 원샷 자식의 fired 판정(F432).
    var reachedStartTime: Bool { time >= def.startTime }
    /// 라이브 오디오 스펙트럼(렌더러가 매 프레임 주입). nil/무신호(silent) = 오디오반응 스킵 → 기존 rate.
    public var currentAudio: AudioSpectrum16?

    public init(def: ParticleSystemDef, seed: UInt64) {
        self.def = def
        self.rng = SplitMix64(seed: seed)
        self.acc = Array(repeating: 0, count: def.emitters.count)

        var mv: [(SIMD3<Float>, Float)] = []
        var ang: [(SIMD3<Float>, Float)] = []
        var sc: [(st: Float, et: Float, sv: Float, ev: Float)] = []
        var cc: [(st: Float, et: Float, sv: SIMD3<Float>, ev: SIMD3<Float>)] = []
        var af: (Float, Float)? = nil
        var op_: (Float, Float, Float, Float, Float, Float, SIMD3<Float>)? = nil
        var oa: (Float, Float, Float, Float, Float, Float)? = nil
        // 오실레이터는 "첫 인스턴스만 채택" 규약이라 창도 그 인스턴스의 것을 함께 굳힌다.
        var opBlend = BlendWindow.identity
        var oaBlend = BlendWindow.identity
        var attr: [(Float, Float, SIMD3<Float>, Bool, Int)] = []
        var mdist: [(Float, Float, SIMD3<Float>)] = []
        var boids: [(Float, Float, Float, Float, Float, Float, Int)] = []
        var vort: [(SIMD3<Float>, Float, Float, Float, Float, SIMD3<Float>, Float, VortexRing?, Int)] = []
        // F628: 전 turbulence 오퍼레이터 누적(종전 first-wins 드롭 — 3000562427 의 지배 성분 손실).
        var turb: [(Float, Float, Float, Float, SIMD3<Float>, Float, Float, BlendWindow)] = []
        var osz: (Float, Float, Float, Float, Float, Float)? = nil
        var ac: [(st: Float, et: Float, sv: Float, ev: Float)] = []
        var rms: [CachedRemap] = []
        var caps: [(Float, BlendWindow)] = []
        var rmv: [(SIMD3<Float>, Float, Float, Float, Float)] = []
        for (opIdx, op) in def.operators.enumerated() {
            let bw = opIdx < def.operatorBlends.count ? def.operatorBlends[opIdx] : BlendWindow.identity
            switch op {
            case let .movement(g, drag): mv.append((s3(g), drag))
            case let .angularMovement(f, drag): ang.append((s3(f), drag))
            case let .sizeChange(st, sv, ev, et):
                sc.append((st: st, et: et, sv: sv, ev: ev))
            case let .colorChange(st, sv, ev, et):
                cc.append((st: st, et: et, sv: s3(sv), ev: s3(ev)))
            case let .alphaFade(fin, fout): if af == nil { af = (fin, fout) }
            case let .oscillatePosition(fmin, fmax, smin, smax, pmin, pmax, mask):
                if op_ == nil { op_ = (fmin, fmax, smin, smax, pmin, pmax, s3(mask)); opBlend = bw }
            case let .oscillateAlpha(fmin, fmax, smin, smax, pmin, pmax):
                if oa == nil { oa = (fmin, fmax, smin, smax, pmin, pmax); oaBlend = bw }
            case let .controlPointAttract(scale, threshold, target, deleteThreshold, flags):
                attr.append((scale, threshold, s3(target), deleteThreshold, flags))
            case let .maintainDistanceToControlPoint(distance, vs, target):
                mdist.append((distance, vs, s3(target)))
            case let .boids(sepThr, nbrThr, maxSpeed, sepF, aliF, cohF, flags):
                boids.append((sepThr, nbrThr, maxSpeed, sepF, aliF, cohF, flags))
            case let .vortex(axis, dIn, dOut, sIn, sOut, offset, centerForce, ring, flags):
                vort.append((s3(axis), dIn, dOut, sIn, sOut, s3(offset), centerForce, ring, flags))
            case let .turbulence(smin, smax, scale, timeScale, mask, pmin, pmax):
                turb.append((smin, smax, scale, timeScale, s3(mask), pmin, pmax, bw))
            case let .oscillateSize(fmin, fmax, smin, smax, pmin, pmax):
                if osz == nil { osz = (fmin, fmax, smin, smax, pmin, pmax) }
            case let .alphaChange(st, et, sv, ev):
                ac.append((st: st, et: et, sv: sv, ev: ev))
            case let .remapValue(output, fbm, scale):
                switch output {
                case let .velocity(mn, mx): rms.append(.velocity(min: s3(mn), max: s3(mx), fbm: fbm, scale: scale))
                case let .speed(mn, mx): rms.append(.speed(min: mn, max: mx, fbm: fbm, scale: scale))
                }
            case let .remapValueEx(spec):
                rms.append(.general(spec))
            case let .capVelocity(maxSpeed):
                caps.append((maxSpeed, bw))
            case let .reduceMovementNearControlPoint(dIn, dOut, rIn, rOut, target):
                // 실물 ctor 0x1401cd38d: distanceouter == distanceinner 이면 `rcpps` 대신
                // **xmm15** 를 역폭에 심는다(0x1401cd3a7 `movaps xmm0, xmm15`). 0x1401cd3b9:
                // reductionouter == reductioninner 이면 델타에 0 이 아니라 **1.0** 을 심는다.
                //
                // **그 xmm15 는 −0.0 이 아니라 (1,1,1,1) 이다.** 오퍼레이터 루프 프리헤더
                // 0x1401cb184 가 `movdqa xmm15, [0x140492e30]`(=1,1,1,1)을 심고 백에지
                // (0x1401cc476 → 0x1401cb1a0)가 그 값을 유지한다. 같은 함수 앞쪽 **이미터**
                // 구간의 `movss xmm15, [0x140492ff0]`(=−0.0, 0x1401c5bac)은 프리헤더가 덮어써
                // 죽고, `movaps xmm15, [rsp+0x2230]`(0x1401cc4a0)은 **루프가 끝난 뒤**의 복원이다
                // (0x1401c552b 의 프롤로그 저장과 짝). 자매 원소 vortex 의 같은 분기
                // (0x1401cdcd1)도 같은 xmm15 를 읽고 그쪽은 이미 1.0 로 고쳐져 있다 — 한
                // 레지스터를 두 원소가 달리 읽을 수는 없다.
                //
                // 그래서 퇴화 폭은 "t 를 0 으로 죽인다" 가 아니라 **inner 에서 시작하는 폭 1
                // 램프**다. −0.0 이면 거리와 무관하게 redIn 이 걸리는데, 실물은 inner+1 밖에서
                // redOut 으로 넘어간다. `testReduceMovementDegenerateRangeIsUnitWidthRamp` 가
                // 세 지점(안쪽·중간·바깥)으로 그 차이를 못박는다.
                let invRange: Float = dOut == dIn ? 1 : 1 / (dOut - dIn)
                let redDelta: Float = rOut == rIn ? 1 : (rOut - rIn)
                rmv.append((s3(target), dIn, invRange, rIn, redDelta))
            }
        }
        movements = mv.map { (gravity: $0.0, drag: $0.1) }
        angulars = ang.map { (force: $0.0, drag: $0.1) }
        sizeChanges = sc
        colorChanges = cc
        alphaFade = af.map { (fin: $0.0, fout: $0.1) }
        oscPosOp = op_.map { (fmin: $0.0, fmax: $0.1, smin: $0.2, smax: $0.3, pmin: $0.4, pmax: $0.5, mask: $0.6) }
        oscAlphaOp = oa.map { (fmin: $0.0, fmax: $0.1, smin: $0.2, smax: $0.3, pmin: $0.4, pmax: $0.5) }
        oscAlphaBlend = oaBlend
        oscPosBlend = opBlend
        attractors = attr.map { (scale: $0.0, threshold: $0.1, target: $0.2, delete: $0.3, flags: $0.4) }
        maintainDists = mdist.map { (distance: $0.0, variableStrength: $0.1, target: $0.2) }
        boidsOps = boids.map { (sepThr: $0.0, nbrThr: $0.1, maxSpeed: $0.2,
                                sepF: $0.3, aliF: $0.4, cohF: $0.5, flags: $0.6) }
        vortices = vort.indices.map { (axis: vort[$0].0, dIn: vort[$0].1, dOut: vort[$0].2,
                                        sIn: vort[$0].3, sOut: vort[$0].4, offset: vort[$0].5,
                                        audio: $0 < def.vortexAudio.count ? def.vortexAudio[$0] : nil,
                                        centerForce: vort[$0].6, ring: vort[$0].7, flags: vort[$0].8) }   // F624
        turbulences = turb.map { (smin: $0.0, smax: $0.1, scale: $0.2, timeScale: $0.3,
                                  mask: $0.4, pmin: $0.5, pmax: $0.6, blend: $0.7) }
        oscSizeOp = osz.map { (fmin: $0.0, fmax: $0.1, smin: $0.2, smax: $0.3, pmin: $0.4, pmax: $0.5) }
        alphaChanges = ac
        remaps = rms
        hasDisplayRemaps = rms.contains {
            guard case let .general(spec) = $0 else { return false }
            switch spec.verb {
            case .setOpacity, .multiplyOpacity, .setColor, .multiplyColor, .setSize, .multiplySize: return true
            default: return false
            }
        }
        velocityCaps = caps.map { (maxSpeed: $0.0, blend: $0.1) }
        reduceMoves = rmv.map { (target: $0.0, distIn: $0.1, invRange: $0.2, redIn: $0.3, redDelta: $0.4) }
        trailSamples = def.renderer.trailSampleCount
        speedCap = (attr.isEmpty && vort.isEmpty) ? nil : 5000
        hasEmitterAudio = def.emitterAudio.contains { $0 != nil }
        periodicStates = def.emitters.indices.map { i in
            var st = PeriodicState()
            st.enabled = i < def.emitterPeriodic.count && def.emitterPeriodic[i] != nil
            return st
        }
        parentSeed = seed
        childStates = def.children.map { _ in [] }
        childDisplaysCache = def.children.map { _ in [] }
        // 상시(always) 링크는 즉시 1인스턴스 기동(링크 origin 고정 앰비언트).
        for (li, link) in def.children.enumerated() where link.trigger == .always {
            if rollProbability(link.probability) {
                childStates[li].append(makeInstance(link, li: li, uid: 0, origin: s3(link.origin)))
            }
        }
    }

    /// 링크별 자식 표시 스냅샷(직전 step 에서 캐시). 렌더러가 링크별 머티리얼로 드로우.
    public func childDisplay(_ li: Int) -> [Particle] {
        li >= 0 && li < childDisplaysCache.count ? childDisplaysCache[li] : []
    }

    /// F178(E1-③): 경로 기반 자손 파티클 표시 스냅샷 — path[0]=직계 자식 링크, path[1]=그 자식의
    /// 자식 링크(손자)... 각 단계에서 해당 링크의 전 ChildInstance(uid별 다중 인스턴스 가능 — 예:
    /// deathBurst 는 죽는 파티클마다 새 인스턴스)를 평탄화해 다음 단계 입력으로 삼는다. 손자 이상은
    /// 중간 GPUParticleSystem.sim 이 더미(step 미호출)라 그 sim 에서 직접 childDisplay 를 못 타므로,
    /// 렌더러는 항상 루트(실제 스텝되는) sim 에서 이 메서드를 호출해야 한다 — childStates 는 stepChildren
    /// 이 매 프레임 재귀적으로 갱신하므로(각 ChildInstance.sim.step 호출이 그 sim 의 stepChildren 도 구동)
    /// 이 경로는 항상 그 프레임의 최신 스냅샷을 반환한다.
    public func descendantDisplay(path: [Int]) -> [Particle] {
        guard let first = path.first, first >= 0, first < childStates.count else { return [] }
        if path.count == 1 { return childDisplay(first) }
        let rest = Array(path.dropFirst())
        return childStates[first].flatMap { $0.sim.descendantDisplay(path: rest) }
    }

    private mutating func rollProbability(_ p: Float) -> Bool {
        p >= 1 || rng.nextFloat() < p
    }

    private func makeInstance(_ link: ChildLink, li: Int, uid: Int, origin: SIMD3<Float>) -> ChildInstance {
        let mix = UInt64(UInt(bitPattern: uid &* 31 &+ li &+ 1))
        var s = ParticleSimulator(def: link.def, seed: parentSeed &+ 0x9E37_79B9_7F4A_7C15 &* mix)
        s.emitOrigin = origin
        return ChildInstance(sim: s, parentUID: uid,
                             oneShot: link.trigger == .spawnBurst || link.trigger == .deathBurst)
    }

    public var liveCount: Int { particles.count }

    /// dt 만큼 진행 후 살아있는 파티클의 표시 스냅샷을 반환.
    public mutating func step(_ dt: Float) -> [Particle] {
        guard WapleProfiler.enabled else { return _step(dt) }
        let t0 = CFAbsoluteTimeGetCurrent()
        let out = _step(dt)
        WapleProfiler.recordParticleStep(count: out.count, seconds: CFAbsoluteTimeGetCurrent() - t0)
        return out
    }

    private mutating func _step(_ dt: Float) -> [Particle] {
        time += dt
        let countBeforeEmission = particles.count
        // 방출(starttime 이후, 자식 원샷/고아는 정지). burst(실물 instantaneous)는 생성 1회 일괄 스폰,
        // rate(연속)와 독립 병행(F621).
        // F438: dt==0(정지/재드로 스냅샷 재방출 — SceneRenderer3D:1096/SceneRenderer:1451)은 실행 이력
        // (time>0)이 있는 sim 에서만 방출 금지 — step(0) 이 acc/RNG/전멸 후 버스트 재발화 상태를 변이하지
        // 않게. 무이력(time==0) sim 의 초기 버스트는 종전대로 발화(기존 스위트·최초 드로 호환).
        if !emissionPaused, dt > 0 || time == 0, time >= def.startTime {
            let wasEmpty = particles.isEmpty  // 버스트 재발화 판정은 스텝 진입 시점 기준(다중 이미터 동시 발화)
            for i in def.emitters.indices {
                let e = def.emitters[i]
                if periodicStates[i].enabled {
                    // 주기 키 보유 이미터: 주기 컨트롤러가 표준 rate/burst 방출을 대체한다
                    // ("전멸 시 재버스트" 추정(아래 레거시 분기)과의 관계 — 주기 키가 있으면 전멸
                    // 조건 대신 ON 윈도우 진입이 버스트/방출 트리거. 없으면 레거시 무회귀).
                    stepPeriodicEmission(i, e, dt: dt)
                    continue
                }
                if e.burst > 0, wasEmpty {
                    // ponytail: 전멸 시 재버스트 루프 — 실 WE 는 자식(eventfollow) 트리거가 주 용법,
                    // Stage B(children)에서 트리거 발화로 대체 예정.
                    // max(0, …): periodicEnterOn(:539)의 동형 식과 맞춘다 — particles.count 가
                    // def.maxCount 를 넘은 순간(자식 병합·인스턴스 오버라이드로 상한이 줄어든 경우)
                    // 우변이 음수가 되고 `0..<음수` 는 Range 생성에서 곧바로 트랩한다.
                    for _ in 0..<max(0, min(e.burst, def.maxCount - particles.count)) {
                        particles.append(spawn(e, index: i))
                    }
                }
                // F621: rate 분기는 burst 유무와 무관 — 실물 instantaneous(생성 1회)와 rate(연속)는
                // 독립 필드로 병행(WE 문서 "Further particles will be spawned according to the
                // configuration"). rate==0(burst-only)이면 acc 가 0 유지 → 기존 경로와 비트동일.
                // 오디오반응: 무보유/무신호 시 스케일 1(× 1.0 은 IEEE 정확 → 기존 acc 누적 비트동일).
                acc[i] += e.rate * emitterRateScale(i) * dt
                while acc[i] >= 1, particles.count < def.maxCount {
                    acc[i] -= 1
                    particles.append(spawn(e, index: i))
                }
                if particles.count >= def.maxCount { acc[i] = min(acc[i], 1) }  // 누적 폭주 방지
            }
        }
        // 신규 스폰 → follow/spawnBurst 자식 인스턴스 생성(스폰 위치 기준, 링크 캡/확률).
        if !def.children.isEmpty, particles.count > countBeforeEmission {
            for li in def.children.indices {
                let link = def.children[li]
                guard link.trigger == .follow || link.trigger == .spawnBurst else { continue }
                // 인덱스 순회(슬라이스 버퍼 보유 회피). guard 순서 유지 필수 — rollProbability 의
                // RNG 호출 순서가 바뀌면 시드 결정성(GT luma 기준선)이 깨진다.
                for pi in countBeforeEmission..<particles.count {
                    guard childStates[li].count < link.maxInstances else { break }
                    guard rollProbability(link.probability) else { continue }
                    let p = particles[pi]
                    childStates[li].append(makeInstance(link, li: li, uid: p.uid, origin: p.pos + s3(link.origin)))
                }
            }
        }
        // boids 는 전 파티클의 위치·속도를 동시에 봐야 하므로 per-particle 루프 **앞**에서 돈다.
        if !boidsOps.isEmpty { applyBoids(dt) }
        // 적분(controlpointattract/vortex 힘 → movement/angularMovement) + 노화.
        for k in particles.indices {
            _integrateParticle(at: k, dt: dt)
        }
        // 컬(+deathBurst 자식은 사망 위치에서 발화).
        let hasDeathLinks = def.children.contains { $0.trigger == .deathBurst }
        var dying: [Particle] = []
        if hasDeathLinks { dying = particles.filter { $0.age > $0.lifetime } }
        particles.removeAll { $0.age > $0.lifetime }
        if !dying.isEmpty {
            for li in def.children.indices where def.children[li].trigger == .deathBurst {
                let link = def.children[li]
                for p in dying {
                    guard childStates[li].count < link.maxInstances else { break }
                    guard rollProbability(link.probability) else { continue }
                    childStates[li].append(makeInstance(link, li: li, uid: p.uid, origin: p.pos + s3(link.origin)))
                }
            }
        }
        stepChildren(dt)
        // 표시 스냅샷.
        return particles.map { display($0) }
    }

    /// 개별 파티클 적분: remap → 힘(attract/vortex) → speedCap → movement → 위치 → 난류 → 각속도 → 트레일.
    /// _step 핫루프에서 호출 — 배열 할당 없음, RNG 드로 없음(결정적 시퀀스 불변).
    @inline(__always)
    private mutating func _integrateParticle(at k: Int, dt: Float) {
        particles[k].age += dt
        // remapvalue: velocity 는 매 스텝 덮어쓰기(작가가 낙하속도를 노이즈로 직접 기술),
        // speed 는 이번 스텝 적분에만 곱하는 비파괴 배수(저장 vel 불변 → 복리 폭주 없음).
        // F440: 덮어쓰기는 힘 오퍼레이터 **이전**에 — 종전엔 같은 스텝의 attract/vortex 가속을
        // 전량 덮어써 힘 오퍼레이터가 묠력화됐다(speedCap 도 그 경로에서는 무의미).
        var speedFactor: Float = 1
        var remapAddVel = SIMD3<Float>(0, 0, 0)   // remapValueEx addvelocity — 이번 스텝 적분 전용(비파괴)
        if !remaps.isEmpty {
            let base = (particles[k].remapPhase + particles[k].age) * Self.remapInputK
            for r in remaps {
                switch r {
                case let .velocity(mn, mx, fbm, scale):
                    let x = base * scale
                    let t = SIMD3(remapNoise01(fbm, x, SIMD3(0, 0, 0)),
                                  remapNoise01(fbm, x, SIMD3(19.3, 71.7, 5.1)),
                                  remapNoise01(fbm, x, SIMD3(53.2, 11.9, 97.4)))
                    particles[k].vel = mn + (mx - mn) * t
                case let .speed(mn, mx, fbm, scale):
                    speedFactor *= mn + (mx - mn) * remapNoise01(fbm, base * scale, SIMD3(7.7, 33.1, 61.9))
                case let .general(spec):
                    // 확장 파이프라인 — 물리 동사는 여기서, 표시 파생 동사는 display() 에서 적용.
                    let (val, w) = remapEval(spec, particles[k])
                    guard w > 0 else { continue }
                    switch spec.verb {
                    case .setVelocity:
                        particles[k].vel += (val - particles[k].vel) * w   // w=1 → 덮어쓰기(레거시 동형)
                    case .addVelocity:
                        remapAddVel += val * w
                    case .multiplySpeed:
                        speedFactor *= 1 + (val.x - 1) * w                 // w=1 → val.x(레거시 동형)
                    case .setRotation:
                        particles[k].rotation += (val - particles[k].rotation) * w
                    case .addRotation:
                        particles[k].rotation += val * (w * dt)            // [추정] 가산율(dt 곱)
                    case .setAngularVelocity:
                        particles[k].angularVel += (val - particles[k].angularVel) * w
                    case .addAngularVelocity:
                        particles[k].angularVel += val * (w * dt)
                    case .setOpacity, .multiplyOpacity, .setColor, .multiplyColor,
                         .setSize, .multiplySize:
                        break   // 표시 파생 — display() 적용
                    }
                }
            }
        }
        // 힘 오퍼레이터는 movement 적분 전에 속도를 갱신(같은 step 위치에 반영).
        // vel/pos 로컬 호이스트: `&particles[k].vel` inout 과 같은 배열 읽기가 한 호출에 겹치면
        // 호출마다 배열 전체가 COW 복사된다(attractor×particle×step — 무거운 씬 실측 병목).
        if !attractors.isEmpty || !vortices.isEmpty {
            var vel = particles[k].vel
            let pos = particles[k].pos
            // deletethreshold: 어느 attractor 든 근접 삭제 판정 시 true — 전 attractor 는 끝까지
            // 적용(단락 평가 금지 — 호출 생략이 없어야 delete=false 경로 산술이 종전과 동일).
            var attractDelete = false
            for a in attractors { attractDelete = applyAttract(a, to: &vel, pos: pos, dt: dt) || attractDelete }
            for v in vortices {
                // F624: vortex 오디오반응 = 접선 속도 × 응답 배수(무신호/묵보유 1 → 비트동일).
                applyVortex(v, to: &vel, pos: pos, dt: dt, audioScale: audioResponseScale(v.audio))
            }
            particles[k].vel = vel
            // 근접 삭제(deletethreshold 키 보유 attractor 한정): 수명 초과로 마킹 — 아래 컬 경로
            // (deathBurst 자식 발화 포함)를 그대로 탄다. RNG 드로 無 → 무키 씬 비트동일.
            if attractDelete { particles[k].age = particles[k].lifetime + 1 }
        }
        if let cap = speedCap {
            let sp = simd_length(particles[k].vel)
            if sp > cap { particles[k].vel *= cap / sp }
        }
        for m in movements {
            particles[k].vel += m.gravity * dt
            if m.drag > 0 { particles[k].vel *= max(0, 1 - m.drag * dt) }
        }
        // G-C2-01: `reducemovementnearcontrolpoint` · `capvelocity` 는 **movement 뒤**다.
        // 동봉 저작 순서가 전건 [movement, …, reducemovement/capvelocity] 이고, 실물 VM 은
        // 오퍼레이터를 저작 순서대로 돌리며 movement(op 0x01)가 속도 갱신과 위치 적분을 함께 한다.
        // Waple 은 위치 적분이 이 블록 **뒤**라, 감쇠/클램프가 이번 프레임 변위에 한 프레임 일찍
        // 반영된다(원본은 다음 프레임). 중력 뒤라는 순서는 원본과 같다 — 힘 단계(attract/vortex)에
        // 두면 감쇠 후 중력이 다시 실려 "정지"가 성립하지 않는다.
        if !reduceMoves.isEmpty {
            let pos = particles[k].pos
            var vel = particles[k].vel
            for r in reduceMoves { applyReduceMovement(r, to: &vel, pos: pos, dt: dt) }
            particles[k].vel = vel
        }
        // capvelocity: 방향 보존 스칼라 클램프. 실물 op 0x12 는 `s = min(1, maxspeed/|v|)` 를
        // 곱하므로 |v| ≤ maxspeed 이면 s=1 로 무동작 — 상한 미도달 파티클은 산술이 종전과 같다.
        for cap in velocityCaps {
            let sq = simd_length_squared(particles[k].vel)
            guard sq > 0 else { continue }
            var s = min(1, cap.maxSpeed / sq.squareRoot())
            // G-C2-03: 스케일 계수 자리의 가중은 `s = 1 + w·(s₀ − 1)` — `new = old + w·(unweighted − old)`
            // 의 특수형이다. 창이 비활성이면 w = 1 이라 산술이 종전과 같다.
            // 동봉 `thunderbolt_child_spawner` 의 capvelocity(blendin 0.2/0.2)가 이 경로를 탄다.
            let w = cap.blend.weight(lifeFraction: lifeFraction(particles[k]))
            if w != 1 { s = 1 + w * (s - 1) }
            if s < 1 { particles[k].vel *= s }
        }
        // remapValueEx addvelocity: remapAddVel==0 이면 종전 산술 그대로(레거시 비트동일),
        // 아니면 이번 스텝 적분에만 가산(저장 vel 불변 — speed 배수와 같은 비파괴 규약).
        if remapAddVel == SIMD3<Float>(0, 0, 0) {
            particles[k].pos += particles[k].vel * speedFactor * dt
        } else {
            particles[k].pos += (particles[k].vel + remapAddVel) * speedFactor * dt
        }
        // 난류 — **속도에 누적한다.** 종전에는 위치에 이류시켰다(아래 ①). 그 차이는 양적이 아니라
        // 정성적이다: 이류는 `|변위| ≤ speed·dt` 로 프레임마다 유계라 수명이 아무리 길어도 변위가
        // `speed·lifetime` 을 못 넘지만, 속도 누적은 랜덤워크(`≈ speed·dt·√n`)라 변위가 **초선형**으로
        // 자란다. 수명이 긴 시스템일수록 격차가 커진다.
        //
        // ① 실물 핸들러는 위치 배열(0x1402429dd–0x1402429eb, `rcx/rdx/r8`)을 노이즈 좌표용으로만 읽고,
        //    꼬리 0x140242d3a–0x140242d54 에서 **속도 배열**(0x1402429f7–0x140242a05, `r15/r12/r13`)에
        //    `addps`+`movups` 한다. 이 저장소에서 직접 확인했다.
        // ② 종전 주석이 "배수 사슬이 절반만 추적돼 있어 아직 안 옮겼다" 를 이유로 미뤄 뒀는데,
        //    그 사슬을 전부 닫았다 — `turbulenceAcceleration` 주석의 ②~⑤ 참조. dt 는 정확히 한 번,
        //    선형으로만 들어간다(실물은 `dtScaled`; ≥40fps 에서 `dt` 와 같으므로 여기선 `dt`).
        // ③ 속도 상한은 걸지 않는다. 실물도 `capvelocity` 오퍼레이터가 있을 때만 건다.
        //
        // F628: 전 turbulence 오퍼레이터 누적 — 첫 번째는 turbSpeed/turbPhase(기존 비트동일),
        // 2번째 이후는 turbExtra(다중 오퍼레이터 시스템만 신규 드로).
        if !turbulences.isEmpty {
            let nTurb = lifeFraction(particles[k])
            if particles[k].turbSpeed > 0 {
                let a = turbulenceAcceleration(turbulences[0], pos: particles[k].pos, speed: particles[k].turbSpeed,
                                               phase: particles[k].turbPhase, time: time)
                // 가산 델타 자리의 가중은 그대로 곱이다(`old + w·delta`).
                particles[k].vel += a * (dt * turbulences[0].blend.weight(lifeFraction: nTurb))
            }
            for (ti, extra) in particles[k].turbExtra.enumerated() where extra.speed > 0 {
                guard ti + 1 < turbulences.count else { break }
                let a = turbulenceAcceleration(turbulences[ti + 1], pos: particles[k].pos, speed: extra.speed,
                                               phase: extra.phase, time: time)
                particles[k].vel += a * (dt * turbulences[ti + 1].blend.weight(lifeFraction: nTurb))
            }
        }
        // maintaindistancetocontrolpoint: CP 중심 반지름 `distance` 구면으로 위치를 당긴다.
        // 실물 루프 0x140241bd0..0x140241cbc 를 그대로 옮긴 것 —
        //     d = pos − target ;  k = (distance/|d| − 1)·s ;  pos += k·d
        // (M = I · O = 0 축약. 유일한 실사용처의 CP0 이 시스템 원점이라 성립 —
        //  ParticleSystem.MaintainDistance 주석의 근거 참조.)
        //
        // **속도는 건드리지 않는다.** 저장은 위치 배열 셋(0x140241c96·c9e·caa)뿐이다.
        // 실물 오퍼레이터 순서(magic_vortex_orb: movement → alphafade → vortex_v2 →
        // maintaindistance → controlpointattract)에 맞춰 위치 적분 뒤에 둔다.
        if !maintainDists.isEmpty {
            for m in maintainDists {
                let d = particles[k].pos - m.target
                let len = simd_length(d)
                guard len > 1e-6 else { continue }   // 실물은 rsqrtps 근사라 0 에서 발산한다
                // s: `variablestrength ≠ 0` 이면 `clamp01(vs·dt)`(0x1402419a0 `mulss xmm0,
                // [rbp+0x2008]`= arg2 = 생 dt → 0x1401d8df0 = min(1,max(0,x))), **0 이면 상수 1.0**
                // — 즉 반지름 `distance` 구면으로의 즉시 투영(하드 제약)이다.
                //
                // 종전엔 이 자리를 "VM 2번째 인자 dt·min(1,0.025/dt)^0.7" 로 적었다. 틀렸다.
                // 분기가 같을 때 실행하는 것은 `movaps xmm11, xmm2`(base 0x14024199a ·
                // ext 0x140241cef)인데, 그 `xmm2` 는 핸들러 인자가 아니라 **op 디스패치
                // 프리앰블이 opcode 마다 새로 심는 스칼라 상수 1.0** 이다
                // (`movss xmm2, [0x140492704]` @0x14023fd77, 그 뒤 `jmp rax` @0x14023fdc7 까지
                // 재대입 없음 — 두 핸들러의 진입~분기 사이에도 xmm2 기입이 없다).
                // `shufps xmm11,xmm11,0` 로 4레인에 편다. 호출부에서 xmm2 레지스터가 3번째 인자
                // dtScaled 를 나르는 것과 혼동한 것이다 — dtScaled 는 프리앰블이 [rbp+0x5f0]/xmm8
                // 로 따로 보관하고, xmm2 는 프리앰블 스크래치다.
                //
                // 도달: 동봉 `maintaindistancetocontrolpoint` 3건이 전부 `variablestrength: 5`라
                // vs≠0 분기만 탄다 — 관측 회귀는 없고 키를 뺀 씬에서 갈린다.
                let s = m.variableStrength != 0
                    ? max(0, min(1, m.variableStrength * dt))
                    : 1
                particles[k].pos += d * ((m.distance / len - 1) * s)
            }
        }
        // F431/F439: 선형 movement(위 280-283행)와 동형 — force/drag 는 전 오퍼레이터에 누적하고
        // rotation 적분은 스텝당 1회. 종전엔 루프 안에서 적분해 angularmovement N개면 N회 중복
        // 적분(F439), 0개면 angularvelocityrandom 의 초기 각속도가 영구 사장(F431)됐다.
        for a in angulars {
            // 선형 movement(위 280-283행)와 대칭인 drag 감쇠(F188) — drag 미지정(0)이면 종전대로
            // 등가속 무감쇠 누적(무회귀).
            particles[k].angularVel += a.force * dt
            if a.drag > 0 { particles[k].angularVel *= max(0, 1 - a.drag * dt) }
        }
        particles[k].rotation += particles[k].angularVel * dt
        // 트레일 위치 히스토리(dt>0 만 — step(0) 스냅샷 중복 방지). 링버퍼로 trailSamples 유지.
        // display() 반환 스냅샷(d.pos)과 동형으로 oscillateposition 오프셋을 반영(F177) — base pos
        // 만 기록하면 spriteTrail/rope 리본이 sprite 쿼드(d.pos 사용)와 달리 진동을 놓친다.
        if trailSamples > 0, dt > 0 {
            particles[k].history.append(particles[k].pos + oscPositionOffset(particles[k]))
            if particles[k].history.count > trailSamples {
                particles[k].history.removeFirst(particles[k].history.count - trailSamples)
            }
        }
    }

    /// 자식 인스턴스 일괄 스텝: follow 는 부모 현재 위치로 방출 원점 갱신(부모 사망 → 방출 정지 후 드레인),
    /// 원샷(spawn/death 버스트)은 startTime 도달 첫 스텝 후 방출 정지(F432). 드레인 완료 인스턴스는 제거.
    private mutating func stepChildren(_ dt: Float) {
        guard !def.children.isEmpty else { return }
        var uidPos: [Int: SIMD3<Float>] = [:]
        if childStates.enumerated().contains(where: { !$0.1.isEmpty && def.children[$0.0].trigger == .follow }) {
            for p in particles { uidPos[p.uid] = p.pos }
        }
        for li in def.children.indices {
            let link = def.children[li]
            var displays: [Particle] = []
            // take-패턴 인플레이스 변이: `for var inst`(값 복사→keep 재조립)는 버퍼 공유 탓에
            // 인스턴스마다 파티클 배열 전체를 매 스텝 COW 복사한다 — GT 스위트 실측 병목.
            var insts = childStates[li]
            childStates[li] = []   // 원본 참조 해제 → insts 버퍼 unique → 변이가 제자리
            for i in insts.indices {
                if link.trigger == .follow {
                    if let pp = uidPos[insts[i].parentUID] { insts[i].sim.emitOrigin = pp + s3(link.origin) }
                    else { insts[i].sim.emissionPaused = true }   // 고아 — 드레인만
                }
                insts[i].sim.currentAudio = currentAudio   // 오디오 하향 전파(무신호면 무영향 → 무회귀)
                displays.append(contentsOf: insts[i].sim.step(dt))
                // F432: startTime 게이트 도달 전에는 fired 마킹하지 않는다 — 종전엔 첫 스텝(누적
                // time=첫 dt) 후 무조건 정지해 startTime > 첫 dt 인 원샷 자식(rain splash 류)이
                // 한 개도 방출하지 못한 채 드레인 0 으로 제거됐다.
                if insts[i].oneShot, !insts[i].fired, insts[i].sim.reachedStartTime {
                    insts[i].fired = true; insts[i].sim.emissionPaused = true
                }
            }
            insts.removeAll { $0.sim.emissionPaused && $0.sim.liveCount == 0 }
            childStates[li] = insts
            childDisplaysCache[li] = displays
        }
    }

    // MARK: - 주기(periodic) 방출

    /// [추정] 주기 방출 컨트롤러(PeriodicEmission 키 보유 이미터 전용 — 표준 rate/burst 경로 대체,
    /// WE 에디터 어휘 규약). 사이클: ON(duration 구간 드로) — 창 내 rate 방출(quota=maxtoemitperperiod
    /// 상한, rate==0 && burst==0 이면 quota 를 창 길이에 균등 분배하는 암시 rate) → OFF(delay 구간
    /// 드로) → 반복. burst>0 이면 매 ON 진입 시 창 버스트(레거시 "전멸 재버스트"의 주기형 대응).
    private mutating func stepPeriodicEmission(_ i: Int, _ e: Emitter, dt: Float) {
        guard i < def.emitterPeriodic.count, let per = def.emitterPeriodic[i] else { return }
        var st = periodicStates[i]
        if !st.started { st.started = true; periodicEnterOn(&st, i, e, per) }
        // 방출이 잔여 감소/전이보다 먼저 — remaining 이 이번 스텝에 0 이 되는 경계 스텝도 창 내 방출로 센다.
        if st.on {
            var rate = e.rate * emitterRateScale(i)
            if rate <= 0, e.burst == 0, per.maxPerPeriod > 0, st.window > 0 {
                rate = Float(per.maxPerPeriod) / st.window   // [추정] 창 내 균등 분배
            }
            acc[i] += rate * dt
            while acc[i] >= 1, particles.count < def.maxCount,
                  per.maxPerPeriod == 0 || st.emitted < per.maxPerPeriod {
                acc[i] -= 1
                particles.append(spawn(e, index: i))
                st.emitted += 1
            }
            if particles.count >= def.maxCount
                || (per.maxPerPeriod > 0 && st.emitted >= per.maxPerPeriod) { acc[i] = min(acc[i], 1) }
        }
        st.remaining -= dt
        // 페이즈 전이. duration/delay 가 연속 0 이면 remaining 이 양수로 안 돌아오는 설정이
        // 가능 — 홉 상한 16 으로 무한루프 방호(무크래시 폴터 관례).
        var hops = 0
        while st.remaining <= 0, hops < 16 {
            hops += 1
            if st.on {
                st.on = false
                st.remaining += max(0, rng.range(per.delayMin, per.delayMax))
            } else {
                periodicEnterOn(&st, i, e, per)
            }
        }
        periodicStates[i] = st
    }

    /// ON 윈도우 진입: duration 드로 → 쿼터 리셋 → (burst>0 이면) 창 진입 버스트(quota/캡 상한).
    private mutating func periodicEnterOn(_ st: inout PeriodicState, _ i: Int, _ e: Emitter, _ per: PeriodicEmission) {
        st.on = true
        st.window = max(0, rng.range(per.durationMin, per.durationMax))
        st.remaining += st.window
        st.emitted = 0
        if e.burst > 0 {
            let quota = per.maxPerPeriod > 0 ? per.maxPerPeriod : .max
            let n = max(0, min(e.burst, quota, def.maxCount - particles.count))
            for _ in 0..<n {
                particles.append(spawn(e, index: i))
                st.emitted += 1
            }
        }
    }

    // MARK: - 오디오반응 rate 변조

    /// 이미터 오디오반응 rate 배수. 무보유/무반응(params nil)/무신호(currentAudio nil·silent) = 1(기존 rate 유지).
    /// 신호가 있을 때만 AudioResponse(구간평균→smoothstep(bounds)→pow→saturate, shake.vert 1:1)를 곱한다.
    /// → 무음 A/B(공급자 부재 = currentAudio nil)는 기존 방출 경로와 비트동일. WE 충실도는 신호 존재 시 발현.
    private func emitterRateScale(_ i: Int) -> Float {
        guard hasEmitterAudio, i < def.emitterAudio.count else { return 1 }
        return audioResponseScale(def.emitterAudio[i])
    }

    /// F624: 오퍼레이터 부착 오디오반응 배수(vortex 속도). nil/무신호 = 1(× 1.0 은 IEEE 정확 → 비트동일).
    private func audioResponseScale(_ ap: AudioProcessing?) -> Float {
        guard let ap, let audio = currentAudio, !audio.isSilent else { return 1 }
        // **파티클/이미터 경로는 구간 MAX 다** — 셰이더의 구간평균이 아니다(AudioResponse.Reduction).
        // 실물 0x14022a8a0 이 러닝 MAX 를 잡고 나눗셈을 하지 않는다. 종전엔 셰이더 규약을
        // 그대로 재사용해, 베이스만 뜬 스펙트럼에서 WE 1.0 vs Waple 0.0 으로 갈렸다.
        return AudioResponse.compute(left: audio.left, right: audio.right, mode: ap.mode,
                                     freqMin: ap.freqStart, freqMax: ap.freqEnd,
                                     bounds: ap.bounds, power: ap.exponent, multiply: 1,
                                     reduction: .peak)
    }

    // MARK: - 스폰

    /// F620: 이미터 초기속도 샘플. speedmax>speedmin 일 때만 RNG 드로(range 고정호출이라 무조건 소비) —
    /// speed 키 부재(0,0)인 기존 시스템은 드로 0 → RNG 시퀀스·스폰 결과 비트동일.
    private mutating func emitterSpeedSample(_ index: Int) -> Float {
        guard index < def.emitterSpeed.count else { return 0 }
        let sp = def.emitterSpeed[index]
        if sp.y > sp.x { return rng.range(sp.x, sp.y) }
        return sp.x
    }

    private mutating func spawn(_ emitter: Emitter, index: Int) -> Particle {
        var p = Particle()
        switch emitter {
        case let .sphere(origin, directions, dmin, dmax, _, _, sign):
            let u = randomUnitVector()
            var dir = normalizeSafe(u * s3(directions))
            // sign: 축별 반구 강제(실물 rain splash "sign":"0 1 0" = 위로만 튐).
            let sg = s3(sign)
            if sg.x != 0 { dir.x = sg.x > 0 ? abs(dir.x) : -abs(dir.x) }
            if sg.y != 0 { dir.y = sg.y > 0 ? abs(dir.y) : -abs(dir.y) }
            if sg.z != 0 { dir.z = sg.z > 0 ? abs(dir.z) : -abs(dir.z) }
            p.pos = s3(origin) + dir * rng.range(dmin, dmax)
            // F620: 이미터 speedmin/speedmax = 방출 방향(dir) 초기속도(WE 문서: movement 오퍼레이터와
            // 결합하는 particle speed). 실물도 이미터가 먼저 속도를 쓰고 그 뒤 스폰 VM 이 돈다 —
            // 그래서 `velocityrandom` 핸들러가 `addss` 로 **누적**한다(0x14023bbea–0x14023bbf7).
            // 종전에는 그 이니셜라이저가 여기 초기속도를 덮어썼다(apply 의 velocityRandom 주석 참조).
            let speed = emitterSpeedSample(index)
            if speed != 0 { p.vel = dir * speed }
        case let .box(origin, dmax, _, _):
            let d = s3(dmax)
            // F627: distancemin 지정 시 두 코너의 성분별 AABB(음수/역순 축은 성분별 min/max 정규화 —
            // 실물 "500 500 0"~"1000 256 0" 처럼 min>max 축 존재). 부재 시 ±distanceMax 대칭 레거시.
            // 두 경로 모두 드로 3개라 RNG 시퀀스 길이는 동일.
            if index < def.boxDistanceMin.count, let mn = def.boxDistanceMin[index] {
                let lo = s3(mn)
                p.pos = s3(origin) + SIMD3(rng.range(min(lo.x, d.x), max(lo.x, d.x)),
                                           rng.range(min(lo.y, d.y), max(lo.y, d.y)),
                                           rng.range(min(lo.z, d.z), max(lo.z, d.z)))
            } else {
                p.pos = s3(origin) + SIMD3(rng.range(-d.x, d.x), rng.range(-d.y, d.y), rng.range(-d.z, d.z))
            }
            // F620(box): 방향 정의가 없어 균등 랜덤 방향 근사 — 코퍼스 box speed 는 전부 0(묵발동).
            let speed = emitterSpeedSample(index)
            if speed != 0 { p.vel = randomUnitVector() * speed }
        }
        p.pos += emitOrigin   // 자식 인스턴스: 부모 위치(또는 링크 origin) 오프셋. 루트는 0.
        p.uid = nextUID; nextUID += 1
        // F622: animationmode=randomframe — 스폰 시 시퀀스 인덱스 1개 확정(sheetFrameIndex 가
        // 프레임 수로 접는다). mapsequence 이니셜라이저가 있으면 뒤의 apply 가 덮어써 그쪽이 승
        // (cherry_blossoms 류 — 각도→프레임 명시 매핑이 더 구체적).
        if def.animationMode == .randomframe { p.frame = rng.range(0, 4096) }
        for ini in def.initializers { apply(ini, to: &p) }
        if let o = oscPosOp {
            p.oscPosFreq = rng.range(o.fmin, o.fmax)
            p.oscPosScale = rng.range(o.smin, o.smax)
            p.oscPosPhase = rng.range(o.pmin, o.pmax) * 2 * .pi
            p.oscPosMask = o.mask
        }
        if let o = oscAlphaOp {
            p.oscAlphaFreq = rng.range(o.fmin, o.fmax)
            // oscPos/oscSize 와 동형 range 샘플(F184) — phasemin/max 부재(기본 0) 시 전 파티클 동위상
            // (fireworks 근동기 의도). 종전엔 항상 rng.nextFloat()*2π 완전 랜덤이라 desync 를 강제했다.
            p.oscAlphaPhase = rng.range(o.pmin, o.pmax) * 2 * .pi
        }
        if let o = oscSizeOp {
            p.oscSizeFreq = rng.range(o.fmin, o.fmax)
            p.oscSizePhase = rng.range(o.pmin, o.pmax) * 2 * .pi
        }
        if let t = turbulences.first {
            p.turbSpeed = rng.range(t.smin, t.smax)
            // 실물 위상은 `r·(pmax − pmin)` 이다 — `pmin` 을 더하지 않는다(0x140242a70 에 `mulps` 만
            // 있고 `pmin`(레코드 +0x70)을 읽는 명령이 핸들러에 없다). `range(0, Δ)` 로 쓰면 드로 수와
            // 소비 순서가 그대로라 다른 오퍼레이터의 난수열이 밀리지 않는다.
            p.turbPhase = rng.range(0, t.pmax - t.pmin)
            // F628: 2번째 이후 오퍼레이터도 스폰 샘플(단일 오퍼레이터 시스템은 드로 0 → 비트동일).
            for extra in turbulences.dropFirst() {
                p.turbExtra.append((speed: rng.range(extra.smin, extra.smax),
                                    phase: rng.range(0, extra.pmax - extra.pmin)))
            }
        }
        if !remaps.isEmpty { p.remapPhase = rng.range(0, 100) }
        // 스폰 위치(+ 위상 오프셋, F177)를 트레일 시작점으로 — oscPos 위상이 0 이 아니면 age=0 에서도
        // 오프셋이 존재해(sin(phase)≠0) base pos 로 시드하면 트레일 시작점이 어긋난다.
        if trailSamples > 0 { p.history = [p.pos + oscPositionOffset(p)] }
        return p
    }

    // MARK: - 힘 오퍼레이터(가정: 실물 파라미터명에서 도출 — 물리 정밀 불요, 유계성 우선)

    /// controlpointattract: 대상(헤드리스=origin, 기본 0)을 향한(scale>0)/반대(scale<0) 가속.
    /// 감쇠 = min(1, threshold/dist) → 근접 시 최대, 멀수록 1/r 로 약화(폭주 억제). |scale|=px/s^2.
    /// delete=true(deletethreshold @0x48f988)이면 threshold 이내 근접 파티클을 삭제(true 반환) —
    /// 엔진 어휘상 근접 삭제가 정본, 영구 잔류+감쇠 추정은 키 부재 씬의 폴터로만 유지(무회귀).
    /// controlpointattract. 실물 VM base 핸들러 op 0x0a @0x140241554 / 가중 변형 op 0x20
    /// @0x14024172d 를 1:1 로 옮긴 것 — 두 핸들러는 블렌드 가중 곱 하나만 다르다.
    /// ```
    ///   accel  = dt · scale                    ; 0x140241738 (mulps xmm8, [r14+0x40])
    ///   invThr = rcpps(threshold)              ; 0x14024173d
    ///   dist   = sqrtps(|d|²)                  ; 0x1402418b0  (rsqrt 이 아니라 진짜 sqrt)
    ///   inRange= (FLT_MIN < dist) && (dist < threshold)   ; 0x1402418b8 · 0x1402418c2
    ///   step   = (1 − dist·invThr) · accel     ; 0x1402418ce–0x1402418d8
    ///   if (flags&2 && dist < step) step = dist            ; 0x1402418dc–0x1402418e4
    ///   step  *= w                             ; 0x1402418e9 (블렌드 창, 기본 w ≡ 1)
    ///   if (inRange) vel −= (d/dist)·step      ; 0x1402418f0–0x140241929
    /// ```
    /// **[2026-08-20 수식 정정]** 종전의 `min(1, threshold/dist)` 는 모양이 반대였다:
    ///  · 사거리 — 종전은 무한(threshold 밖에서도 1/r 로 계속 당김), 실물은 **하드 컷오프**
    ///  · 근접부 — 종전은 threshold 안쪽 전부 1.0 포화, 실물은 dist→0 에서 1, threshold 에서 **0**
    /// 즉 `threshold` 는 "포화 반경" 이 아니라 **작용 반경 겸 선형 감쇠 스케일**이다.
    private func applyAttract(_ a: (scale: Float, threshold: Float, target: SIMD3<Float>,
                                    delete: Bool, flags: Int),
                              to vel: inout SIMD3<Float>, pos: SIMD3<Float>, dt: Float) -> Bool {
        let d = a.target - pos
        let dist = simd_length(d)
        // **[미구현 — 실물과 다르다]** 실물의 삭제는 (a) `flags & 1` 게이트(0x14024193d)를 지나고
        // (b) 점–점이 아니라 **직전 위치→현재 위치 선분과 CP 의 최단거리 제곱**을
        // `deletethreshold²` 와 비교하며(0x14022a2e7) (c) `age = lifetime` 대입으로 표현돼
        // 다음 틱에 죽는다. 여기 셋 다 없다. 다만 flags 기본 2 에는 bit0 이 없고, 동봉
        // `controlpointattract`(all 34 · unique 29 — `spec/assets/particle-corpus.json`)가
        // `deletethreshold` 를 전건 생략하므로 **실코퍼스에서는 양쪽 다 무동작**이다.
        // 게이트만 먼저 맞춰 둔다 — 키만 보고 삭제하던 종전 경로가 더 위험하다.
        if a.delete, (a.flags & 1) != 0, a.threshold > 0, dist < a.threshold { return true }
        guard dist > 1e-4, a.threshold > 0, dist < a.threshold else { return false }
        var step = (1 - dist / a.threshold) * a.scale * dt
        // flags bit1 = 오버슛 클램프. 기본값 2 에 들어 있으므로 **기본은 켜져 있다**.
        if (a.flags & 2) != 0, dist < step { step = dist }
        vel += (d / dist) * step
        return false
    }

    /// G-C2-01 `reducemovementnearcontrolpoint`: CP 로부터의 거리로 감쇠율을 램프해 속도를 줄인다.
    /// 실물 VM 핸들러 op 0x0d @0x14024268f 를 1:1 로 옮긴 것 —
    /// ```
    ///   d   = p − cp                          ; 0x140242711–0x140242730 (subps × 3)
    ///   len = rsqrtps(|d|²)·|d|²              ; 0x140242749 (≈ sqrt, 12비트 근사)
    ///   t   = min(1, (len − [+0x50])·[+0x60]) ; 0x140242753–0x14024275d
    ///   t   = max(0, t)                       ; 0x140242761
    ///   r   = t·[+0x80] + [+0x70]             ; 0x140242764–0x14024276c
    ///   r   = min(1, r·dt); r = max(0, r)     ; 0x140242771–0x14024277c ([rbp+0xf0] = 스텝 dt)
    ///   v  *= (1 − r)                         ; 0x14024277f–0x14024279f
    /// ```
    /// `[+0x50]=distanceinner`, `[+0x60]=1/(outer−inner)`, `[+0x70]=reductioninner`,
    /// `[+0x80]=reductionouter−reductioninner` (ctor 0x1401cd38d–0x1401cd3e7).
    /// 즉 reduction 은 **초당 감쇠율**이고 dt 를 곱한 뒤 0..1 로 잘려 `v ×= (1−r)` 에 들어간다 —
    /// thunderbolt 의 reductioninner 1000 은 안쪽에서 사실상 정지(1프레임 내 r→1), 기본값 100 도
    /// 60fps 에서 r=1.67→1 로 정지다. 바깥(reductionouter 기본 0)에서는 r=0 → 무동작.
    /// rsqrtps 근사는 재현하지 않고 정확한 sqrt 를 쓴다(상대오차 ≤ 1.5e-3, 램프 클램프 안에서 무의미).
    private func applyReduceMovement(_ r: (target: SIMD3<Float>, distIn: Float, invRange: Float,
                                           redIn: Float, redDelta: Float),
                                     to vel: inout SIMD3<Float>, pos: SIMD3<Float>, dt: Float) {
        let len = simd_length(pos - r.target)
        let t = max(0, min(1, (len - r.distIn) * r.invRange))
        let reduction = max(0, min(1, (r.redIn + t * r.redDelta) * dt))
        if reduction > 0 { vel *= (1 - reduction) }
    }

    /// vortex: axis 를 회전축, offset 를 중심으로 하는 소용돌이. 회전면 반경 dist 에 따라
    /// speedInner(distanceInner)→speedOuter(distanceOuter) 보간한 접선 속도를 가속으로 부여.
    /// F624: audioScale = 오디오반응 배수(WE 문서: particle speed 를 오디오에 연결 — 1 이면 무영향).
    /// centerForce(RVA **0x48f9f8** — 종전 주석의 0x48e7c8 은 문자열 `"olor"` 중간을 가리켰다):
    /// vortex_v2 전용이고 `flags & 1` 이 아니라 **`flags & 2`** 게이트를 지나야 파스된다.
    /// ring(RVA **0x48faa8/0x48fab8/0x48fad0/0x48fae0** — 종전의 0x48e8a8–0x48e8e0 은 포그 키다):
    /// vortex_v2 전용, **`flags & 4`** 게이트. 힘 수식은 아래 본문 주석대로 아직 [추정]이다.
    private func applyVortex(_ v: (axis: SIMD3<Float>, dIn: Float, dOut: Float, sIn: Float, sOut: Float,
                                   offset: SIMD3<Float>, audio: AudioProcessing?,
                                   centerForce: Float, ring: VortexRing?, flags: Int),
                             to vel: inout SIMD3<Float>, pos: SIMD3<Float>, dt: Float, audioScale: Float) {
        // 축은 **파스 시점에** 정규화된다(0x1401cdc16–0x1401cdc58). |axis| ≤ 0.001 이면 스킵이
        // 아니라 **(0,0,1) 로 대체**한다 — 종전의 `guard … else { return }`(무동작)와 다르다.
        let axisN = simd_length(v.axis) > 0.001 ? normalizeSafe(v.axis) : SIMD3<Float>(0, 0, 1)
        let rel = pos - v.offset
        // **flags bit0 이 없으면 축 성분을 빼지 않는다** — 런타임이 `andps xmm2, mask`(0x140243316)
        // 로 proj 를 통째로 0 으로 만들어 radial 이 3D 전체가 된다. 기본 flags = 0 이라 이쪽이
        // 기본 경로다(종전엔 항상 투영했다).
        let proj = (v.flags & 1) != 0 ? simd_dot(rel, axisN) : 0
        let radial = rel - axisN * proj
        let len2 = simd_length_squared(radial)
        guard len2 > 1e-8 else { return }
        let dist = sqrt(len2)
        let n = radial / dist
        // invRange 는 굽는 시점에 정해진다: `dOut == dIn` 이면 **1.0**(0 이 아니라 폭 1 램프),
        // `dOut < dIn` 이면 `rcpps` 가 음수를 내 **역램프**가 된다. 종전의 `dOut > dIn ? … : 0`
        // 은 두 경우를 모두 "램프 없음" 으로 접었다.
        let invRange: Float = v.dOut == v.dIn ? 1 : 1 / (v.dOut - v.dIn)
        let t = max(0, min(1, (dist - v.dIn) * invRange))
        let speed = v.sIn + (v.sOut - v.sIn) * t
        // 접선 = `cross(n, axis)`. 두 가지가 종전과 다르다:
        //  ① **순서** — 실물은 0x14024338d/0x14024339f/0x1402433a2 에서
        //     (n.y·a.z − n.z·a.y, n.z·a.x − n.x·a.z, n.x·a.y − n.y·a.x) = n × a 를 만든다.
        //     종전의 `cross(axisN, radial)` = a × r 은 **부호가 반대**라 소용돌이가 거꾸로 돌았다.
        //  ② **정규화하지 않는다** — flags bit0 이 없으면 |n × a| = sinθ 라 축에 가까운 파티클일수록
        //     느리게 돈다. 종전엔 normalizeSafe 로 그 감쇠를 지웠다.
        let tangent = simd_cross(n, axisN)

        // centerforce **[2026-08-20 모델 정정]**. 종전은 "축을 향한 등가속 인력"
        // (`vel -= n·(cf·dt)`)이었는데 실측은 형태도 차원도 다르다:
        // ```
        //   cfOverDt   = centerforce / dt                       ; 0x14024345c divps · 0x14024346b
        //   radial′    = radial(pos + vel·dt)                   ; proj 는 현재 값을 재사용
        //   radialScale= (dist / |radial′| − 1) · cfOverDt       ; 0x140243961–0x140243988
        //   vel       += tangent·speed + radial′·radialScale    ; 0x14024398f–0x1402439a3
        // ```
        // `dist/dist′ − 1 ≈ −v_r·dt/dist` 이므로 `Δv ≈ −centerforce · v_r · n` —
        // **dt 가 상쇄되는 무차원 반경속도 감쇠**(매 스텝 `v_radial *= 1 − cf`)이지 힘이 아니다.
        // 기본 1.0 은 "반경 속도를 완전히 죽여 궤도 반경을 고정" 이라는 뜻이고, 정지한 파티클
        // (v = 0 → dist′ = dist)에는 **아무 작용도 하지 않는다**. 종전 모델은 cf 1.0 에서
        // 초당 1단위 가속으로 중심으로 무너뜨렸다 — 부호 규약도 "중심을 향한 인력" 이 아니라
        // 멀어지는 중이면 안쪽, 다가오는 중이면 바깥쪽이다.
        //
        // 예측 반경은 **이 오퍼레이터의 접선 가산 이전 속도**로 만든다 — 실물은 루프 앞머리에서
        // 속도를 한 번 읽고 두 기여를 함께 더한다(0x1402439a0 `addps xmm1, xmm5`).
        // 그래서 여기서도 tangent 를 먼저 더하지 않고 마지막에 함께 더한다.
        var delta = tangent * (speed * audioScale) * dt
        if v.centerForce != 0, dt > 0 {
            let relP = (pos + vel * dt) - v.offset
            let radialP = relP - axisN * proj
            let distP = simd_length(radialP)
            if distP > 1e-6 {
                // `(dist − distP)/distP` 는 실물의 `dist/distP − 1` 과 대수적으로 같지만
                // **수치적으로 훨씬 안정하다.** 후자는 두 거리가 가까울 때(= dt 가 작을 때)
                // 1.0 근처에서 빼기 때문에 float32 해상도(~1e-7)에 먹히는데, 그 결과가 곧바로
                // `1/dt` 로 증폭된다. 실물은 `rsqrtps` 근사까지 겹쳐 애초에 비트동일이 불가능하니
                // 여기서는 조건수가 나은 쪽을 쓴다.
                delta += radialP * ((dist - distP) / distP * v.centerForce / dt)
            }
        }
        vel += delta
        // ring **[힘 수식 추정 · 게이트는 실측]**: `flags & 4` 가 없으면 파서가 nil 을 주므로
        // 여기 오지 않는다(런타임 `test byte [r14+0x110],4` @0x1402434eb). 동봉 코퍼스의
        // vortex_v2 5건은 전부 bit2 가 없어 이 경로에 **한 번도 들어오지 않는다**.
        //
        // 순서도 다르다: 실물은 ring 항을 centerforce 와 **같은 radialScale 에 합쳐** 예측 반경
        // `radial′` 에 한 번 곱한다. 여기서는 위 `delta` 를 먼저 더한 뒤 현재 `n` 에 따로 적용한다.
        // flags 6(둘 다 켬)에서 값이 갈리는데, 그런 인스턴스가 동봉에 없어 수식 확정과 함께
        // 미룬다 — 고칠 때 이 두 항을 한 벡터로 합치는 것부터 해야 한다.
        if let ring = v.ring, ring.pullForce != 0 {
            let ringDelta = dist - ring.radius          // 위 `delta` 를 가리지 않게 이름을 나눈다
            let halfW = max(0, ring.width) * 0.5
            if abs(ringDelta) > halfW, abs(ringDelta) - halfW <= max(0, ring.pullDistance) {
                vel -= n * (ring.pullForce * dt) * (ringDelta > 0 ? 1 : -1)
            }
        }
    }

    /// Particle initializer 분포 성형. exponent==1은 종전 raw 산술과 RNG 시퀀스를 보존한다.
    private mutating func randomFactor(exponent: Float) -> Float {
        let raw = rng.nextFloat()
        return exponent == 1 ? raw : powf(raw, max(0.0001, exponent))
    }

    private mutating func randomRange(_ min: Float, _ max: Float, exponent: Float) -> Float {
        min + (max - min) * randomFactor(exponent: exponent)
    }

    private mutating func apply(_ ini: Initializer, to p: inout Particle) {
        switch ini {
        case let .lifetimeRandom(mn, mx, exp):
            p.lifetime = max(0.0001, randomRange(mn, mx, exponent: exp))
        case let .sizeRandom(mn, mx, exp):
            p.initialSize = randomRange(mn, mx, exponent: exp); p.size = p.initialSize
        case let .colorRandom(mn, mx, exp):
            // [보존/추측] 공유 t 로 min↔max 색 라인을 유지. WE RGB 박스형 분산이 실측되면 color만 A/B 재검토.
            let t = randomFactor(exponent: exp)
            let c = SIMD3(mn.x + (mx.x - mn.x) * t,
                          mn.y + (mx.y - mn.y) * t,
                          mn.z + (mx.z - mn.z) * t) / 255
            p.initialColor = c; p.color = c
        case let .alphaRandom(mn, mx, exp):
            let f = randomFactor(exponent: exp)
            p.initialAlpha = mn + (mx - mn) * f; p.alpha = p.initialAlpha
        case let .velocityRandom(mn, mx, exp):
            // [보존/추측] vector 스프레드와 기존 draw 수를 보존하는 성분별 독립 t.
            let x = randomRange(mn.x, mx.x, exponent: exp)
            let y = randomRange(mn.y, mx.y, exponent: exp)
            let z = randomRange(mn.z, mx.z, exponent: exp)
            // **덮어쓰지 않고 더한다.** 실물 핸들러 0x14023bac6 의 꼬리가 그렇게 한다 —
            // `mov rax, [rdi+0x2c8]`(속도 X 배열) → `addss xmm0, [rax+r12*4]` →
            // `movss [rax+r12*4], xmm0` (0x14023bbea–0x14023bbf7), Y(0x2d0)·Z(0x2d8)도 동형.
            // 이미터가 먼저 `p.vel = dir·speed` 를 쓰므로(:739/:755) 덮어쓰면 그 초기속도가 사라진다.
            // 형제인 `turbulentVelocityRandom`(아래)은 이미 `+=` 였다 — 비일관이 여기서 끝난다.
            // 종전 주석은 "velocityrandom 이 있으면 뒤의 apply 가 덮어쓴다(기존 조합 순서 유지)" 로
            // 이 동작을 **의도된 무회귀**라고 적었는데, 그건 실물 확인 전의 보수적 선택이었다.
            // 도달(동봉 자산 실측): 이미터 speed 가 0이 아니면서 velocityrandom 을 함께 쓰는 시스템
            // 3파일 / 고유 2건 — `exampleturbolence3d`(sphere −6..−2), `presets/stars/starfield`
            // (sphere 1.0 고정, 프리뷰 사본 포함 2). speed 기본값이 0 이라(:1445) 나머지는 무영향.
            p.vel += SIMD3(x, y, z)
        case let .rotationRandom(mn, mx, exp):
            let x = randomRange(mn.x, mx.x, exponent: exp)
            let y = randomRange(mn.y, mx.y, exponent: exp)
            let z = randomRange(mn.z, mx.z, exponent: exp)
            p.rotation = SIMD3(x, y, z)
        case let .angularVelocityRandom(mn, mx, exp):
            let x = randomRange(mn.x, mx.x, exponent: exp)
            let y = randomRange(mn.y, mx.y, exponent: exp)
            let z = randomRange(mn.z, mx.z, exponent: exp)
            p.angularVel = SIMD3(x, y, z)
        case let .turbulentVelocityRandom(smin, smax, _, _):
            // ponytail: scale/offset 은 파스만(방향 균등 랜덤 근사, 미적용) — 실물 스키마 반례 확보 시 배선
            p.vel += randomUnitVector() * rng.range(smin, smax)
        case let .colorList(colors):
            guard !colors.isEmpty else { break }
            let idx = min(colors.count - 1, Int(rng.nextFloat() * Float(colors.count)))
            let c = s3(colors[idx])   // 0..1 스케일(실측 — colorrandom 의 /255 와 다름)
            p.initialColor = c; p.color = c
        case let .hsvColorRandom(hueMin, hueMax, satMin, satMax, valMin, valMax, hueSteps, hueNoise, satNoise, valNoise):
            // h/s/v 는 서로 무관한 축 — velocityRandom 과 같이 채널별 독립 t(공유 t 아님).
            // 노이즈 키(huenoise/saturationnoise/valuenoise) 보유 채널은 rng 드로 대신 스폰 위치 기반
            // 값노이즈로 t 산출 [추정 — 근처 파티클이 유사 채널값 공유]. 노이즈 채널은 드로 0 — 키 부재
            // 채널만 레거시 드로를 소비하므로 무키 씬은 드로 3 으로 비트동일.
            let h: Float
            if hueNoise != 0 {
                h = hueMin + (hueMax - hueMin) * 0.5 * (1 + valueNoise3(p.pos * hueNoise + SIMD3<Float>(11.1, 0, 0)))
            } else if hueSteps > 0 {
                // huesteps [추정]: [hueMin,hueMax] steps 등분 이산 선택 — 드로 1(레거시와 동일 개수).
                let k = min(hueSteps - 1, Int(rng.nextFloat() * Float(hueSteps)))
                h = hueMin + (hueMax - hueMin) * (hueSteps > 1 ? Float(k) / Float(hueSteps - 1) : 0)
            } else {
                h = randomRange(hueMin, hueMax, exponent: 1)
            }
            let s: Float
            if satNoise != 0 {
                s = satMin + (satMax - satMin) * 0.5 * (1 + valueNoise3(p.pos * satNoise + SIMD3<Float>(0, 23.7, 0)))
            } else {
                s = randomRange(satMin, satMax, exponent: 1)
            }
            let v: Float
            if valNoise != 0 {
                v = valMin + (valMax - valMin) * 0.5 * (1 + valueNoise3(p.pos * valNoise + SIMD3<Float>(0, 0, 41.3)))
            } else {
                v = randomRange(valMin, valMax, exponent: 1)
            }
            let c = hsv2rgb(h: h, s: s, v: v)
            p.initialColor = c; p.color = c
        case let .mapSequence(count, _, between):
            // 시퀀스 위치 t(0..1) → frame = t·count. 시트 폴드(mirror/loop)는 렌더 시 sheetFrameIndex.
            let t: Float
            if between {
                // CP0→CP1 구간 투영(클램프). 구간 퇴화 시 0.
                let a = s3(def.controlPoints[0]), bb = s3(def.controlPoints[1])
                let d = bb - a
                let len2 = simd_length_squared(d)
                t = len2 > 1e-8 ? max(0, min(1, simd_dot(p.pos - a, d) / len2)) : 0
            } else {
                // CP0 기준 각도(0..2π → 0..1).
                // F630: 실물 "axis"(회전축)로 각도 평면 선택 — 기본 z축=XY 평면(레거시 비트동일).
                // [보존/추측] 회전 방향(atan2 인자 순서)은 WE 미확정 — 지배 성분 축만 평면을 바꾼다.
                let rel = p.pos - s3(def.controlPoints[0])
                let ax = def.mapSequenceAxis.map { s3($0) } ?? SIMD3<Float>(0, 0, 1)
                let m = simd_abs(ax)
                let angle: Float
                if simd_length(ax) < 1e-6 { angle = atan2(rel.y, rel.x) }       // 퇴화 축 → 레거시
                else if m.y >= m.x, m.y >= m.z { angle = atan2(rel.x, rel.z) }  // Y축 → XZ 평면
                else if m.x >= m.z { angle = atan2(rel.y, rel.z) }              // X축 → YZ 평면
                else { angle = atan2(rel.y, rel.x) }                            // Z축 → XY 평면(레거시)
                t = (angle + .pi) / (2 * .pi)
            }
            p.frame = t * max(0, count)
        case let .positionOffsetRandom(mn, mx):
            // [보존/추측] velocityRandom 과 동형 성분별 독립 t(드로 3).
            p.pos += SIMD3(randomRange(mn.x, mx.x, exponent: 1),
                           randomRange(mn.y, mx.y, exponent: 1),
                           randomRange(mn.z, mx.z, exponent: 1))
        case .inheritControlPointVelocity, .inheritValueFromEvent, .remapInitialValue:
            break   // 이벤트 시스템 연동 보류 — 시뮬 무시(RNG 드로 0)
        }
    }

    // MARK: - 표시 파생

    private func display(_ p: Particle) -> Particle {
        var d = p
        let n = p.lifetime > 0 ? min(1, p.age / p.lifetime) : 1
        // size
        d.size = p.initialSize
        for op in sizeChanges {
            d.size *= lerp(op.sv, op.ev, changeProgress(n, op.st, op.et))
        }
        if let os = oscSizeOp {
            // F832: frequency 단위 = "수명당 진동 횟수"(WE 공식 디자이너 문서 operator.html:
            // "The minimum/maximum number of oscillations per particle lifetime" — oscillate
            // position/alpha/size 3종 동일 문구) — 종전 age 곱(Hz 해석)은 수명이 긴 파티클에서
            // 실제보다 빠르게 진동했다. n = age/lifetime(위 :602, clamped).
            let osc01 = 0.5 * (1 + sin(2 * .pi * p.oscSizeFreq * n + p.oscSizePhase))
            d.size *= lerp(os.smin, os.smax, osc01)
        }
        // color
        d.color = p.initialColor
        for op in colorChanges {
            let t = changeProgress(n, op.st, op.et)
            d.color *= op.sv + (op.ev - op.sv) * t
        }
        // alpha
        var a = p.initialAlpha
        if let af = alphaFade { a *= fadeFactor(n, af.fin, af.fout) }
        for op in alphaChanges {
            a *= lerp(op.sv, op.ev, changeProgress(n, op.st, op.et))
        }
        if let oa = oscAlphaOp {
            // 자매 oscillateSize(위 sizeOp 분기)와 동형 직접보간 — scaleMin/Max 는 파티클별 랜덤화 없이
            // def 고정값을 그대로 보간 양끝으로 쓴다(F184: 종전 "1 - scale*osc" 감산식은 peak 가 항상 1
            // 로 고정되고 trough 만 scale 로 눌리는 별개 수식이었다).
            // F832: frequency 단위 = 수명당 진동 횟수(age 가 아니라 n = age/lifetime 곱) — 위 sizeOp 분기 주석 참조.
            let osc01 = 0.5 * (1 + sin(2 * .pi * p.oscAlphaFreq * n + p.oscAlphaPhase))
            var f = lerp(oa.smin, oa.smax, osc01)
            // G-C2-03: 배율 자리의 가중(`f = 1 + w·(f₀ − 1)`). 동봉 `fireworks3hit` 이 이 경로다.
            let w = oscAlphaBlend.weight(lifeFraction: n)
            if w != 1 { f = 1 + w * (f - 1) }
            a *= f
        }
        d.alpha = max(0, min(1, a))
        // remapValueEx 표시 파생 동사(opacity/color/size) — age/time 기반 파생값이라 display 단계에서
        // 재평가(age 기반 파생 재계산 아키텍처와 동형). w=1 이면 set*=덮어쓰기/multiply*=그대로 곱.
        if hasDisplayRemaps {
            for r in remaps {
                guard case let .general(spec) = r else { continue }
                let (val, w) = remapEval(spec, p)
                guard w > 0 else { continue }
                switch spec.verb {
                case .setSize: d.size += (val.x - d.size) * w
                case .multiplySize: d.size *= 1 + (val.x - 1) * w
                case .setColor: d.color += (val - d.color) * w
                case .multiplyColor: d.color *= SIMD3<Float>(1, 1, 1) + (val - SIMD3<Float>(1, 1, 1)) * w
                case .setOpacity: d.alpha = max(0, min(1, d.alpha + (val.x - d.alpha) * w))
                case .multiplyOpacity: d.alpha = max(0, min(1, d.alpha * (1 + (val.x - 1) * w)))
                default: break   // 물리 동사는 _step 적분 단계 적용
                }
            }
        }
        // pos 진동 오프셋(절대식, base 에 비누적) — 트레일 히스토리 기록(_step/spawn)과 동일 공식 공유.
        d.pos = p.pos + oscPositionOffset(p)
        return d
    }

    /// 진동 위치 오프셋(절대식, base pos 불변) — display() 스냅샷과 트레일 히스토리 기록(_step 291행·
    /// spawn 404행)이 동일 공식을 공유한다(F177: 히스토리가 base pos 만 기록하면 spriteTrail/rope
    /// 리본이 oscillateposition 진동을 반영하지 못해 sprite 쿼드[d.pos 사용]와 비대칭이 생긴다).
    /// boids — 실물 VM op 0x11 @0x140244121 을 그대로 옮긴다.
    ///
    /// 스칼라로 옮기면서 지킨 것 둘:
    ///  ① **서브샘플링**. 실물은 `i = phase·4` 에서 `N·4` 씩 건너뛰므로 **4-입자 그룹 단위**로
    ///     `g ≡ phase (mod N)` 인 그룹만 갱신한다. `N = count/100 + 1` 이라 100개 미만이면 N = 1
    ///     (동봉 실사용 2종은 maxcount 16 이라 항상 전수 갱신). 가속 계수에 `N` 을 곱하는 것이
    ///     그 보상이다.
    ///  ② **제자리 갱신**. 실물은 j 루프에서 배열을 직접 읽으므로 앞선 i 의 갱신이 뒤에 보인다.
    ///     복사본을 쓰면 순서 의존성이 사라져 달라진다.
    ///
    /// 실물은 `rsqrtps` 근사(≤1.5e-3)를 쓰고 여기선 정확한 `sqrt` 를 쓴다 — 비트동일은 불가능하다.
    private mutating func applyBoids(_ dt: Float) {
        let count = particles.count
        guard count > 0 else { return }
        let n = count / 100 + 1
        let phase = frameCounter % n          // n ≥ 1 이 위 정의로 보장된다
        frameCounter &+= 1
        let fn = Float(n)
        for op in boidsOps {
            let sepF = op.sepF * fn * dt
            let aliF = op.aliF * fn * dt
            let cohF = op.cohF * fn * dt
            let maxSq = op.maxSpeed * op.maxSpeed
            var g = phase
            while g * 4 < count {
                for i in (g * 4)..<min(g * 4 + 4, count) {
                    var sepAcc = SIMD3<Float>(0, 0, 0), velAcc = SIMD3<Float>(0, 0, 0)
                    var posAcc = SIMD3<Float>(0, 0, 0)
                    var sepCnt: Float = 0, nCnt: Float = 0
                    let pi = particles[i].pos, vi = particles[i].vel
                    // 실물은 이웃 후보를 **생존 마스크로 거른다**: `mov rsi,[rbp+0x50]`(lifetime 배열,
                    // 0x1402442cd) → `movups xmm0,[rsi+r8*4]` → `cmpneqps xmm0, 0`(0x1402442f4) →
                    // `[rbp+0x1e0]` 에 담아 **분리 마스크와 이웃 마스크 양쪽에** AND 한다
                    // (0x1402443e0 · 0x140244401). 그건 실물의 입자 배열이 **고정 슬랩**이고
                    // lifetime 0 이 곧 빈 슬롯이기 때문이다 — 죽은 슬롯을 이웃으로 세지 않겠다는 뜻.
                    //
                    // **Waple 에 그 마스크를 옮겨 심으면 죽은 코드가 된다.** 이유가 둘이고 둘 다 독립이다:
                    // (a) `particles` 는 매 스텝 `removeAll { age > lifetime }` 으로 **압축**돼 빈 슬롯이
                    //     없다 — 실물 마스크가 하려는 일을 자료구조가 이미 한다.
                    // (b) `lifetimeRandom` 이 `max(0.0001, ·)` 로 **바닥을 깐다**(:923). 그래서
                    //     `lifetimerandom(min:0,max:0)` 이라도 lifetime 은 0 이 아니라 1e-4 다.
                    // 2026-08-20 에 `guard particles[j].lifetime != 0` 을 넣었다가 되돌린다 — 실측
                    // (dt 5e-5, lifetimerandom 0/0)에서 lifetime 이 1e-4 로 나와 가드가 한 번도 서지
                    // 않았고, 핫루프의 (i,j) 쌍마다 도는 비교만 남았다. 위 두 성질은
                    // `testBoidsNeverSeesZeroLifetimeNeighbor` 가 못박는다 — 둘 중 하나가 깨지면
                    // 그 테스트가 먼저 울고, 그때 이 마스크를 되살리면 된다.
                    for j in 0..<count where j != i {
                        let d = pi - particles[j].pos
                        let l2 = simd_length_squared(d)
                        guard l2 != 0 else { continue }   // 실물 `cmpneqps xmm2, 0` — 자기 자신 제외
                        let l = l2.squareRoot()
                        if l < op.sepThr {
                            sepAcc += d * (op.sepThr / l - 1)   // 0x1402443e7 `subps … 1.0`
                            sepCnt += 1
                        }
                        if l < op.nbrThr {
                            velAcc += particles[j].vel
                            posAcc += particles[j].pos
                            nCnt += 1
                        }
                    }
                    var dv = SIMD3<Float>(0, 0, 0)
                    if sepCnt > 0 { dv += sepAcc * (sepF / sepCnt) }
                    if nCnt > 0 {
                        dv += (velAcc / nCnt - vi) * aliF + (posAcc / nCnt - pi) * cohF
                    }
                    var v = vi + dv
                    // flags bit0 = 속도 상한. **이미 상한보다 빠른 입자는 면제**된다
                    // (`max(|vel₀|², maxspeed²) < |v|²` 비교) — 단순 클램프가 아니다.
                    if op.flags & 1 != 0 {
                        let vSq = simd_length_squared(v)
                        if max(simd_length_squared(vi), maxSq) < vSq, vSq > 0 {
                            v *= op.maxSpeed / vSq.squareRoot()
                        }
                    }
                    particles[i].vel = v
                }
                g += n
            }
        }
    }

    /// 파티클 수명 비율 `f = age/lifetime`. G-C2-03 가중의 입력이며, 사망 판정과 같은 규약으로
    /// lifetime ≤ 0 이면 1 로 본다(display() 의 clamp 와 동형).
    private func lifeFraction(_ p: Particle) -> Float {
        p.lifetime > 0 ? min(1, p.age / p.lifetime) : 1
    }

    private func oscPositionOffset(_ p: Particle) -> SIMD3<Float> {
        guard p.oscPosScale > 0 else { return SIMD3(0, 0, 0) }
        // F832: frequency 단위 = "수명당 진동 횟수"(WE 공식 디자이너 문서 operator.html — oscillate
        // position/alpha/size 공통) — 종전 age 곱(Hz 해석)은 수명>1s 파티클에서 과속 진동.
        // lifetime<=0 방어: n=1(display() :602 의 clamp 와 동일 규약).
        let n = p.lifetime > 0 ? min(1, p.age / p.lifetime) : 1
        // G-C2-03: 위치 오프셋은 가산 델타라 가중을 그대로 곱한다. 동봉 `thunderbolt` 가 이 경로다.
        let off = p.oscPosScale * sin(2 * .pi * p.oscPosFreq * n + p.oscPosPhase)
            * oscPosBlend.weight(lifeFraction: n)
        return p.oscPosMask * off
    }

    // MARK: - remapvalue 노이즈

    /// 노이즈 입력 시간 배율: (위상+age)·K·inputScale. 실물 inputScale ~8-10 에서 부드러운
    /// 초당 ~1유닛 진행이 되게 잡은 상수(bit-exact 불요 — 유계·결정성·자연스러움만 요구).
    private static let remapInputK: Float = 0.1

    /// [0,1] 노이즈. fbm = 3옥타브 값노이즈(계수합 정규화), 아니면 단일 값노이즈. salt 로 성분 탈상관.
    private func remapNoise01(_ fbm: Bool, _ x: Float, _ salt: SIMD3<Float>) -> Float {
        let p = SIMD3<Float>(x, 0, 0) + salt
        let n: Float
        if fbm {
            n = (valueNoise3(p) + 0.5 * valueNoise3(p * 2) + 0.25 * valueNoise3(p * 4)) / 1.75
        } else {
            n = valueNoise3(p)
        }
        return 0.5 * (1 + max(-1, min(1, n)))
    }

    /// [0,1] N옥타브 값노이즈(계수 1, 1/2, 1/4… 합 정규화) — remapValueEx transformoctaves 소비.
    /// 레거시 remapNoise01(fbm=true) 와 octaves=3 은 동일 산술(레거시는 기존 함수 유지 — 비트동일).
    private func remapNoiseOctaves(_ octaves: Int, _ x: Float, _ salt: SIMD3<Float>) -> Float {
        var sum: Float = 0, amp: Float = 1, norm: Float = 0
        var p = SIMD3<Float>(x, 0, 0) + salt
        for _ in 0..<max(1, octaves) {
            sum += amp * valueNoise3(p)
            norm += amp
            amp *= 0.5
            p *= 2
        }
        return 0.5 * (1 + max(-1, min(1, sum / norm)))
    }

    /// remapValueEx 입력 CP 룩업(범위 밖 id → 원점).
    private func remapCP(_ id: Int) -> SIMD3<Float> {
        id >= 0 && id < def.controlPoints.count ? s3(def.controlPoints[id]) : SIMD3(0, 0, 0)
    }

    /// remapValueEx 평가(순수 — RNG 無, 스폰 시드 remapPhase 만 참조): 입력 신호 → transform([0,1])
    /// → operation 셰이핑 → 출력 범위 매핑 + blend 창(수명 비율) 가중. step/display 양쪽에서 결정적 재평가.
    private func remapEval(_ spec: RemapSpec, _ p: Particle) -> (value: SIMD3<Float>, weight: Float) {
        let n = p.lifetime > 0 ? min(1, p.age / p.lifetime) : 1
        // 1) 입력 신호([추정] 의미론 — RemapInput doc 주석 참조).
        let x: Float
        switch spec.input {
        case .none:
            x = (p.remapPhase + p.age) * Self.remapInputK * spec.inputScale   // 레거시 동형
        case .some(.lifetimeFraction):
            x = n * spec.inputScale
        case .some(.particleSystemTime), .some(.layerTime), .some(.runtime), .some(.timeOfDay):
            x = time * spec.inputScale   // [추정] 시계열 근사(헤드리스 결정성 우선)
        case .some(.velocity):
            x = simd_length(p.vel) * spec.inputScale
        case .some(.deltaToControlPoint), .some(.distanceToControlPoint):
            x = simd_length(p.pos - remapCP(spec.inputCP0)) * spec.inputScale
        case .some(.directionToControlPoint):
            let d = normalizeSafe(remapCP(spec.inputCP0) - p.pos)
            x = d[min(2, max(0, spec.component))] * spec.inputScale
        case .some(.positionBetweenControlPoints):
            let a = remapCP(spec.inputCP0), b = remapCP(spec.inputCP1)
            let ab = b - a
            let len2 = simd_length_squared(ab)
            x = (len2 > 1e-8 ? max(0, min(1, simd_dot(p.pos - a, ab) / len2)) : 0) * spec.inputScale
        case .some(.layerOrigin):
            x = simd_length(p.pos) * spec.inputScale
        }
        // 2) transform → v01 ∈ [0,1]. 노이즈는 remapPhase 솔트로 파티클 탈동기(레거시 동형).
        let v01: Float
        switch spec.transform {
        case .none:
            v01 = max(0, min(1, x))
        case .some(.triangle):
            let f = x - x.rounded(.down)
            v01 = 1 - abs(2 * f - 1)
        case .some(.simplexnoise):
            v01 = remapNoiseOctaves(1, x, SIMD3(p.remapPhase, 0, 0))   // [추정] 값노이즈 근사
        case .some(.fbmnoise):
            v01 = remapNoiseOctaves(spec.octaves, x, SIMD3(p.remapPhase, 0, 0))
        }
        // 3) operation 단항 셰이핑(RemapOperation doc 주석 참조 — multiply/average 는 항등 보류).
        let v: Float
        switch spec.operation {
        case .remap, .multiply, .average: v = v01
        case .subtract: v = 1 - v01
        case .square: v = v01 * v01
        }
        // 4) blend 창(수명 비율). **[2026-08-20 실측으로 교체]** 종전 구현의 결함 셋:
        //  ① `blendoutstart`/`blendoutend` 기본이 0 이었다(실물 1.0/1.0). 가드 덕에 우연히
        //     같은 결과였지만, `blendoutstart` 만 명시한 자산에서 갈렸다.
        //  ② `blendinend <= blendinstart` 를 통째로 건너뛰었다. 실물은
        //     `inStart = min(bis, bie − 1e-4)` 로 클램프해 **하드 스텝**이 된다 —
        //     동봉 `thunderbolt_child_spawner` 의 `capvelocity` 0.2/0.2 가 정확히 그 경우다.
        //  ③ 활성화 게이트(0.01/0.99)가 없었다. 실물은 탈락하면 가중 코드를 아예 안 돈다.
        // 유도·게이트·런타임 수식은 `BlendWindow` 주석에 적었다.
        let w = spec.blendWindow.weight(lifeFraction: n)
        let mn = s3(spec.outMin), mx = s3(spec.outMax)
        return (mn + (mx - mn) * v, w)
    }

    // MARK: - 난류 흐름장

    /// 난류 **가속도**(속도에 더할 값). 실물 핸들러 0x14024295a–0x140242d5a 를 그대로 옮긴 것 —
    /// 아래 다섯 가지를 전부 이 저장소에서 직접 디스어셈블해 확인했다.
    ///
    /// ① **누적 대상은 속도다.** 프리헤더가 위치 배열 `[sys+0x2b0/0x2b8/0x2c0]` 을 `rcx/rdx/r8` 로
    ///    (0x1402429dd–0x1402429eb), 속도 배열 `[sys+0x2c8/0x2d0/0x2d8]` 을 `r15/r12/r13` 으로
    ///    (0x1402429f7–0x140242a05) 잡는다. 꼬리(0x140242d3a–0x140242d54)의 `addps`+`movups` 대상은
    ///    **`r15/r12/r13`** — 위치는 노이즈 좌표를 만드는 데만 읽는다.
    /// ② **위상은 스칼라 하나**이고 세 축이 공유한다. `xmm6 = r·(pmax−pmin)`(0x140242a70) 에
    ///    `xmm14`(= t·timescale)를 더한다(0x140242a81). **`pmin` 은 더하지 않는다** — 실물이 아예
    ///    안 읽는다(레코드 +0x70 에 심기는 하지만 핸들러가 참조하지 않는다).
    /// ③ **좌표는 `(pos + 위상) · scale`** 이다. 위상을 먼저 더하고(0x140242a93/97/9c) 그 뒤에
    ///    세 성분 모두 같은 `xmm12`(= scale, 0x1402429f2)를 곱한다(0x140242aa1/a5/a9). 종전 구현은
    ///    `pos·scale + 위상` 이라 위상이 scale 을 안 받았고, 시간항에 임의 상수 `turbTimeK = 0.01` 과
    ///    축별 배분 `(0.7, 1.3, 1.0)` 을 얹고 있었다 — 실물엔 둘 다 없다. `scale ≠ 0.01` 인 씬에서
    ///    시간 진화 속도가 그만큼 틀렸다는 뜻이다.
    /// ④ **세 성분은 같은 좌표 삼중항의 순환치환**으로 탈상관한다(가산 오프셋 없음). mask=7 분기의
    ///    호출 셋(0x140242c73/c86/c7e, 0x140242ca5/cbc/cb8, 0x140242ce6/cea)과 결과 적재
    ///    (0x140242caa→xmm9→velX, 0x140242cd3→xmm10→velY, 0x140242cf9→xmm0→velZ)를 맞춰 보면
    ///        aX = N(cz, cx, cy) · aY = N(cy, cz, cx) · aZ = N(cx, cy, cz)
    ///    종전의 큰 상수 오프셋 `(19.3,71.7,5.1)`/`(53.2,11.9,97.4)` 은 근거 없는 임의값이었다.
    /// ⑤ **배수 사슬에 숨은 항이 없다.** `mask ⊙ dtScaled` 는 루프 밖에서 한 번 굳히고
    ///    (0x1402429cf/0x140242a14/0x140242a37 → `[rbp+0x70]`/`[rbp]`/`[rbp+0x10]`), 노이즈에 곱한 뒤
    ///    (0x140242cfc/d0f/d18) 마지막에 speed(`xmm11`)를 곱한다(0x140242d2e/32/36). 전부 스칼라 곱이라
    ///    순서는 산술적으로 무관하다 — 중요한 것은 dt 가 **정확히 한 번, 선형으로만** 들어간다는 것.
    ///
    /// 노이즈 커널 자체는 여전히 다르다(실물은 Gustavson 3D 심플렉스 ×32 @0x1400fd010, 여기는 값노이즈).
    /// 커널 교체는 별건이다 — 이 함수가 고치는 것은 **좌표·배수·누적 대상**이고, 그 셋이 궤적의
    /// 정성적 성질(유계 이류 → 랜덤워크)을 결정한다.
    private func turbulenceAcceleration(_ t: (smin: Float, smax: Float, scale: Float, timeScale: Float,
                                              mask: SIMD3<Float>, pmin: Float, pmax: Float,
                                              blend: BlendWindow),
                                        pos: SIMD3<Float>, speed: Float, phase: Float, time: Float) -> SIMD3<Float> {
        // ②③: ph 는 세 축 공통 스칼라, 좌표는 (pos + ph)·scale.
        let ph = phase + time * t.timeScale
        let c = (pos + SIMD3(repeating: ph)) * t.scale
        // ④: 같은 삼중항의 순환치환 3회.
        let ax = valueNoise3(SIMD3(c.z, c.x, c.y))
        let ay = valueNoise3(SIMD3(c.y, c.z, c.x))
        let az = valueNoise3(SIMD3(c.x, c.y, c.z))
        return SIMD3(ax * t.mask.x, ay * t.mask.y, az * t.mask.z) * speed
    }

    // MARK: - 헬퍼

    private mutating func randomUnitVector() -> SIMD3<Float> {
        let z = rng.range(-1, 1)
        let t = rng.range(0, 2 * .pi)
        let r = sqrtf(max(0, 1 - z * z))
        return SIMD3(r * cosf(t), r * sinf(t), z)
    }
}

private func s3(_ v: Vec3) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }

/// HSV(0..1 각 축, h 는 순환) → RGB(0..1). 표준 6구간 변환 — hsvcolorrandom 이니셜라이저 전용.
/// h 비유한(랜덤 범위 오버플로 등 극단 코퍼스값) 방어: Int(hh) 는 NaN/Inf 에서 트랩하므로 무크래시
/// 그레이 폴백(감사 V06 포화 클램프·TexImage maxDim 가드와 동일 관례 — 오역보다 폴백).
private func hsv2rgb(h: Float, s: Float, v: Float) -> SIMD3<Float> {
    let vv = max(0, min(1, v))
    guard h.isFinite, s > 0 else { return SIMD3(vv, vv, vv) }
    let ss = max(0, min(1, s))
    // h 순환(음수/1 초과 모두 [0,1) 로 랩) 후 6구간(색상환) 스케일.
    let hh = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
    let i = Int(hh) % 6
    let f = hh - hh.rounded(.down)
    let p = vv * (1 - ss)
    let q = vv * (1 - ss * f)
    let t = vv * (1 - ss * (1 - f))
    switch i {
    case 0: return SIMD3(vv, t, p)
    case 1: return SIMD3(q, vv, p)
    case 2: return SIMD3(p, vv, t)
    case 3: return SIMD3(p, q, vv)
    case 4: return SIMD3(t, p, vv)
    default: return SIMD3(vv, p, q)
    }
}

// MARK: - 결정적 값노이즈(외부 의존 無)

/// 정수 격자 해시 → [-1,1]. 좌표 3성분을 정수 믹싱 후 xorshift finalize.
private func hashLattice(_ ix: Int32, _ iy: Int32, _ iz: Int32) -> Float {
    var h = UInt32(bitPattern: ix) &* 0x8da6_b343
    h = h &+ UInt32(bitPattern: iy) &* 0xd816_3841
    h = h &+ UInt32(bitPattern: iz) &* 0xcb1a_b31f
    h ^= h >> 16; h = h &* 0x7feb_352d
    h ^= h >> 15; h = h &* 0x846c_a68b
    h ^= h >> 16
    return Float(h) * (2.0 / Float(UInt32.max)) - 1.0  // [-1,1]
}
/// smootherstep(6t^5-15t^4+10t^3) — 1·2차 도함수 연속으로 격자 아티팩트 억제.
private func fade5(_ t: Float) -> Float { t * t * t * (t * (t * 6 - 15) + 10) }
/// 3D 값노이즈([-1,1] 근사). 정수 격자 8코너 삼선형 보간(fade5 가중).
private func valueNoise3(_ raw: SIMD3<Float>) -> Float {
    // Int32 변환 트랩(오버플로/NaN) 방지: 좌표를 안전 범위로 접는다(결정적, 시각적 무영향).
    func wrap(_ v: Float) -> Float { v.isFinite ? v.truncatingRemainder(dividingBy: 1_000_000) : 0 }
    let p = SIMD3<Float>(wrap(raw.x), wrap(raw.y), wrap(raw.z))
    let fx = floorf(p.x), fy = floorf(p.y), fz = floorf(p.z)
    let ix = Int32(fx), iy = Int32(fy), iz = Int32(fz)
    let tx = fade5(p.x - fx), ty = fade5(p.y - fy), tz = fade5(p.z - fz)
    func c(_ dx: Int32, _ dy: Int32, _ dz: Int32) -> Float { hashLattice(ix &+ dx, iy &+ dy, iz &+ dz) }
    let x00 = c(0, 0, 0) + (c(1, 0, 0) - c(0, 0, 0)) * tx
    let x10 = c(0, 1, 0) + (c(1, 1, 0) - c(0, 1, 0)) * tx
    let x01 = c(0, 0, 1) + (c(1, 0, 1) - c(0, 0, 1)) * tx
    let x11 = c(0, 1, 1) + (c(1, 1, 1) - c(0, 1, 1)) * tx
    let y0 = x00 + (x10 - x00) * ty
    let y1 = x01 + (x11 - x01) * ty
    return y0 + (y1 - y0) * tz
}

private func normalizeSafe(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let len = simd_length(v)
    return len > 1e-6 ? v / len : SIMD3(0, 0, 0)
}
private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
/// 수명 비율 진행도. 시간값은 보존하고 계산 결과만 clamp한다(음수 span은 역보간).
private func changeProgress(_ n: Float, _ st: Float, _ et: Float) -> Float {
    let span = et - st
    if span == 0 { return n >= st ? 1 : 0 }
    return max(0, min(1, (n - st) / span))
}
/// alphaFade: fadeIn(수명 비율) 동안 0→1, fadeOut(말미 비율) 동안 1→0.
private func fadeFactor(_ n: Float, _ fin: Float, _ fout: Float) -> Float {
    let i = fin > 0 ? max(0, min(1, n / fin)) : 1
    let o = fout > 0 ? max(0, min(1, (1 - n) / fout)) : 1
    return i * o
}
