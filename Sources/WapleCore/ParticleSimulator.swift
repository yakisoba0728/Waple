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
    private let oscSizeOp: (fmin: Float, fmax: Float, smin: Float, smax: Float, pmin: Float, pmax: Float)?
    private let alphaChanges: [(st: Float, et: Float, sv: Float, ev: Float)]
    private enum CachedRemap {
        case velocity(min: SIMD3<Float>, max: SIMD3<Float>, fbm: Bool, scale: Float)
        case speed(min: Float, max: Float, fbm: Bool, scale: Float)
    }
    private let remaps: [CachedRemap]
    private let attractors: [(scale: Float, threshold: Float, target: SIMD3<Float>)]
    private let vortices: [(axis: SIMD3<Float>, dIn: Float, dOut: Float, sIn: Float, sOut: Float,
                            offset: SIMD3<Float>, audio: AudioProcessing?)]   // F624: 오디오반응 속도 배수
    // F628: 난류 흐름장 배열(전 turbulence 오퍼레이터 누적 — 종전 "first wins"는 2번째를 드롭).
    // 파티클별 속도/위상 범위(smin/smax, pmin/pmax)는 스폰 시 뽑아 고정, 나머지는 장 파라미터.
    private let turbulences: [(smin: Float, smax: Float, scale: Float, timeScale: Float,
                              mask: SIMD3<Float>, pmin: Float, pmax: Float)]
    // 트레일 히스토리 설정(스프라이트면 0 → 미기록).
    private let trailSamples: Int
    // controlpointattract/vortex 가 있으면 속도 상한(폭주 방지, px/s).
    private let speedCap: Float?
    // 이미터 오디오반응 보유 여부(무보유 시 rate 스케일 전면 우회 → 기존 방출 경로 비트동일).
    private let hasEmitterAudio: Bool

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
    var emissionPaused = false
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
        var attr: [(Float, Float, SIMD3<Float>)] = []
        var vort: [(SIMD3<Float>, Float, Float, Float, Float, SIMD3<Float>)] = []
        // F628: 전 turbulence 오퍼레이터 누적(종전 first-wins 드롭 — 3000562427 의 지배 성분 손실).
        var turb: [(Float, Float, Float, Float, SIMD3<Float>, Float, Float)] = []
        var osz: (Float, Float, Float, Float, Float, Float)? = nil
        var ac: [(st: Float, et: Float, sv: Float, ev: Float)] = []
        var rms: [CachedRemap] = []
        for op in def.operators {
            switch op {
            case let .movement(g, drag): mv.append((s3(g), drag))
            case let .angularMovement(f, drag): ang.append((s3(f), drag))
            case let .sizeChange(st, sv, ev, et):
                sc.append((st: st, et: et, sv: sv, ev: ev))
            case let .colorChange(st, sv, ev, et):
                cc.append((st: st, et: et, sv: s3(sv), ev: s3(ev)))
            case let .alphaFade(fin, fout): if af == nil { af = (fin, fout) }
            case let .oscillatePosition(fmin, fmax, smin, smax, pmin, pmax, mask):
                if op_ == nil { op_ = (fmin, fmax, smin, smax, pmin, pmax, s3(mask)) }
            case let .oscillateAlpha(fmin, fmax, smin, smax, pmin, pmax):
                if oa == nil { oa = (fmin, fmax, smin, smax, pmin, pmax) }
            case let .controlPointAttract(scale, threshold, target):
                attr.append((scale, threshold, s3(target)))
            case let .vortex(axis, dIn, dOut, sIn, sOut, offset):
                vort.append((s3(axis), dIn, dOut, sIn, sOut, s3(offset)))
            case let .turbulence(smin, smax, scale, timeScale, mask, pmin, pmax):
                turb.append((smin, smax, scale, timeScale, s3(mask), pmin, pmax))
            case let .oscillateSize(fmin, fmax, smin, smax, pmin, pmax):
                if osz == nil { osz = (fmin, fmax, smin, smax, pmin, pmax) }
            case let .alphaChange(st, et, sv, ev):
                ac.append((st: st, et: et, sv: sv, ev: ev))
            case let .remapValue(output, fbm, scale):
                switch output {
                case let .velocity(mn, mx): rms.append(.velocity(min: s3(mn), max: s3(mx), fbm: fbm, scale: scale))
                case let .speed(mn, mx): rms.append(.speed(min: mn, max: mx, fbm: fbm, scale: scale))
                }
            }
        }
        movements = mv.map { (gravity: $0.0, drag: $0.1) }
        angulars = ang.map { (force: $0.0, drag: $0.1) }
        sizeChanges = sc
        colorChanges = cc
        alphaFade = af.map { (fin: $0.0, fout: $0.1) }
        oscPosOp = op_.map { (fmin: $0.0, fmax: $0.1, smin: $0.2, smax: $0.3, pmin: $0.4, pmax: $0.5, mask: $0.6) }
        oscAlphaOp = oa.map { (fmin: $0.0, fmax: $0.1, smin: $0.2, smax: $0.3, pmin: $0.4, pmax: $0.5) }
        attractors = attr.map { (scale: $0.0, threshold: $0.1, target: $0.2) }
        vortices = vort.indices.map { (axis: vort[$0].0, dIn: vort[$0].1, dOut: vort[$0].2,
                                        sIn: vort[$0].3, sOut: vort[$0].4, offset: vort[$0].5,
                                        audio: $0 < def.vortexAudio.count ? def.vortexAudio[$0] : nil) }   // F624
        turbulences = turb.map { (smin: $0.0, smax: $0.1, scale: $0.2, timeScale: $0.3, mask: $0.4, pmin: $0.5, pmax: $0.6) }
        oscSizeOp = osz.map { (fmin: $0.0, fmax: $0.1, smin: $0.2, smax: $0.3, pmin: $0.4, pmax: $0.5) }
        alphaChanges = ac
        remaps = rms
        trailSamples = def.renderer.trailSampleCount
        speedCap = (attr.isEmpty && vort.isEmpty) ? nil : 5000
        hasEmitterAudio = def.emitterAudio.contains { $0 != nil }
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
                if e.burst > 0, wasEmpty {
                    // ponytail: 전멸 시 재버스트 루프 — 실 WE 는 자식(eventfollow) 트리거가 주 용법,
                    // Stage B(children)에서 트리거 발화로 대체 예정.
                    for _ in 0..<min(e.burst, def.maxCount - particles.count) {
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
        // 적분(controlpointattract/vortex 힘 → movement/angularMovement) + 노화.
        for k in particles.indices {
            particles[k].age += dt
            // remapvalue: velocity 는 매 스텝 덮어쓰기(작가가 낙하속도를 노이즈로 직접 기술),
            // speed 는 이번 스텝 적분에만 곱하는 비파괴 배수(저장 vel 불변 → 복리 폭주 없음).
            // F440: 덮어쓰기는 힘 오퍼레이터 **이전**에 — 종전엔 같은 스텝의 attract/vortex 가속을
            // 전량 덮어써 힘 오퍼레이터가 묠력화됐다(speedCap 도 그 경로에서는 무의미).
            var speedFactor: Float = 1
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
                    }
                }
            }
            // 힘 오퍼레이터는 movement 적분 전에 속도를 갱신(같은 step 위치에 반영).
            // vel/pos 로컬 호이스트: `&particles[k].vel` inout 과 같은 배열 읽기가 한 호출에 겹치면
            // 호출마다 배열 전체가 COW 복사된다(attractor×particle×step — 무거운 씬 실측 병목).
            if !attractors.isEmpty || !vortices.isEmpty {
                var vel = particles[k].vel
                let pos = particles[k].pos
                for a in attractors { applyAttract(a, to: &vel, pos: pos, dt: dt) }
                for v in vortices {
                    // F624: vortex 오디오반응 = 접선 속도 × 응답 배수(무신호/묵보유 1 → 비트동일).
                    applyVortex(v, to: &vel, pos: pos, dt: dt, audioScale: audioResponseScale(v.audio))
                }
                particles[k].vel = vel
            }
            if let cap = speedCap {
                let sp = simd_length(particles[k].vel)
                if sp > cap { particles[k].vel *= cap / sp }
            }
            for m in movements {
                particles[k].vel += m.gravity * dt
                if m.drag > 0 { particles[k].vel *= max(0, 1 - m.drag * dt) }
            }
            particles[k].pos += particles[k].vel * speedFactor * dt
            // 난류 이류(advection): 노이즈 흐름장 속도로 위치를 이동. vel 에 누적하지 않으므로
            // |변위| ≤ turbSpeed·dt 로 유계(속도 상한 불요). movement 후 pos 를 사용해 궤적을 따라 흐른다.
            // F628: 전 turbulence 오퍼레이터 누적 — 첫 번째는 turbSpeed/turbPhase(기존 비트동일),
            // 2번째 이후는 turbExtra(다중 오퍼레이터 시스템만 신규 드로).
            if !turbulences.isEmpty {
                if particles[k].turbSpeed > 0 {
                    let v = turbulenceVelocity(turbulences[0], pos: particles[k].pos, speed: particles[k].turbSpeed,
                                               phase: particles[k].turbPhase, time: time)
                    particles[k].pos += v * dt
                }
                for (ti, extra) in particles[k].turbExtra.enumerated() where extra.speed > 0 {
                    guard ti + 1 < turbulences.count else { break }
                    let v = turbulenceVelocity(turbulences[ti + 1], pos: particles[k].pos, speed: extra.speed,
                                               phase: extra.phase, time: time)
                    particles[k].pos += v * dt
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
        return AudioResponse.compute(left: audio.left, right: audio.right, mode: ap.mode,
                                     freqMin: ap.freqStart, freqMax: ap.freqEnd,
                                     bounds: ap.bounds, power: ap.exponent, multiply: 1)
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
            // 결합하는 particle speed). velocityrandom 이니셜라이저가 있으면 뒤의 apply 가 덮어쓴다
            // (기존 조합 순서 유지 — velocityrandom 有 시스템 무회귀).
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
            p.turbPhase = rng.range(t.pmin, t.pmax)
            // F628: 2번째 이후 오퍼레이터도 스폰 샘플(단일 오퍼레이터 시스템은 드로 0 → 비트동일).
            for extra in turbulences.dropFirst() {
                p.turbExtra.append((speed: rng.range(extra.smin, extra.smax),
                                    phase: rng.range(extra.pmin, extra.pmax)))
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
    private func applyAttract(_ a: (scale: Float, threshold: Float, target: SIMD3<Float>),
                              to vel: inout SIMD3<Float>, pos: SIMD3<Float>, dt: Float) {
        let d = a.target - pos
        let dist = simd_length(d)
        guard dist > 1e-4 else { return }
        let dir = d / dist
        let atten: Float = a.threshold > 0 ? min(1, a.threshold / dist) : 1
        vel += dir * (a.scale * atten) * dt
    }

    /// vortex: axis 를 회전축, offset 를 중심으로 하는 소용돌이. 회전면 반경 dist 에 따라
    /// speedInner(distanceInner)→speedOuter(distanceOuter) 보간한 접선 속도를 가속으로 부여.
    /// F624: audioScale = 오디오반응 배수(WE 문서: particle speed 를 오디오에 연결 — 1 이면 무영향).
    private func applyVortex(_ v: (axis: SIMD3<Float>, dIn: Float, dOut: Float, sIn: Float, sOut: Float,
                                   offset: SIMD3<Float>, audio: AudioProcessing?),
                             to vel: inout SIMD3<Float>, pos: SIMD3<Float>, dt: Float, audioScale: Float) {
        let axisN = normalizeSafe(v.axis)
        guard simd_length(axisN) > 1e-6 else { return }
        let rel = pos - v.offset
        let radial = rel - axisN * simd_dot(rel, axisN)
        let dist = simd_length(radial)
        guard dist > 1e-4 else { return }
        let t: Float = v.dOut > v.dIn ? max(0, min(1, (dist - v.dIn) / (v.dOut - v.dIn))) : 0
        let speed = v.sIn + (v.sOut - v.sIn) * t
        let tangent = normalizeSafe(simd_cross(axisN, radial))
        vel += tangent * (speed * audioScale) * dt
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
            p.vel = SIMD3(x, y, z)
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
        case let .hsvColorRandom(hueMin, hueMax, satMin, satMax, valMin, valMax):
            // h/s/v 는 서로 무관한 축 — velocityRandom 과 같이 채널별 독립 t(공유 t 아님).
            let h = randomRange(hueMin, hueMax, exponent: 1)
            let s = randomRange(satMin, satMax, exponent: 1)
            let v = randomRange(valMin, valMax, exponent: 1)
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
            a *= lerp(oa.smin, oa.smax, osc01)
        }
        d.alpha = max(0, min(1, a))
        // pos 진동 오프셋(절대식, base 에 비누적) — 트레일 히스토리 기록(_step/spawn)과 동일 공식 공유.
        d.pos = p.pos + oscPositionOffset(p)
        return d
    }

    /// 진동 위치 오프셋(절대식, base pos 불변) — display() 스냅샷과 트레일 히스토리 기록(_step 291행·
    /// spawn 404행)이 동일 공식을 공유한다(F177: 히스토리가 base pos 만 기록하면 spriteTrail/rope
    /// 리본이 oscillateposition 진동을 반영하지 못해 sprite 쿼드[d.pos 사용]와 비대칭이 생긴다).
    private func oscPositionOffset(_ p: Particle) -> SIMD3<Float> {
        guard p.oscPosScale > 0 else { return SIMD3(0, 0, 0) }
        // F832: frequency 단위 = "수명당 진동 횟수"(WE 공식 디자이너 문서 operator.html — oscillate
        // position/alpha/size 공통) — 종전 age 곱(Hz 해석)은 수명>1s 파티클에서 과속 진동.
        // lifetime<=0 방어: n=1(display() :602 의 clamp 와 동일 규약).
        let n = p.lifetime > 0 ? min(1, p.age / p.lifetime) : 1
        let off = p.oscPosScale * sin(2 * .pi * p.oscPosFreq * n + p.oscPosPhase)
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

    // MARK: - 난류 흐름장

    /// timescale(1..1000) → 노이즈 시간좌표 스케일. 중간값(~50)에서 ~0.5 cycle/s 의 부드러운 흐름이
    /// 되도록 잡은 상수(bit-exact 아님 — 결정성/유계성/자연스러움만 요구). timeScale 부재(0)면 정적장.
    private static let turbTimeK: Float = 0.01

    /// 노이즈 흐름장 속도([-speed, +speed]^3, mask 게이트). pos·scale 로 공간 주파수, time·timeScale 로
    /// 시간 진화, phase 로 파티클별 위상 오프셋을 준다. 세 성분은 큰 오프셋으로 탈상관한 값노이즈.
    private func turbulenceVelocity(_ t: (smin: Float, smax: Float, scale: Float, timeScale: Float,
                                         mask: SIMD3<Float>, pmin: Float, pmax: Float),
                                    pos: SIMD3<Float>, speed: Float, phase: Float, time: Float) -> SIMD3<Float> {
        let base = pos * t.scale + SIMD3(phase, phase, phase)
        let tw = time * t.timeScale * Self.turbTimeK
        let timeVec = SIMD3<Float>(tw * 0.7, tw * 1.3, tw)
        // 성분별 탈상관 오프셋(임의 큰 상수).
        let vx = valueNoise3(base + timeVec)
        let vy = valueNoise3(base + timeVec + SIMD3(19.3, 71.7, 5.1))
        let vz = valueNoise3(base + timeVec + SIMD3(53.2, 11.9, 97.4))
        return SIMD3(vx * t.mask.x, vy * t.mask.y, vz * t.mask.z) * speed
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
