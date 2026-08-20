import Foundation
import simd

// MARK: - 요소 타입

public enum Emitter: Equatable {
    /// 평면화 가능한 구 분포. dir = normalize(randUnit ⊙ directions); pos = origin + dir*rand(distMin,distMax).
    /// burst = 실물 "instantaneous"(버스트 개수, 0=연속 rate 방출). sign = 축별 방향 강제(+1/-1, 0=무클램프).
    case sphere(origin: Vec3, directions: Vec3, distanceMin: Float, distanceMax: Float,
                rate: Float, burst: Int, sign: Vec3)
    /// 박스 분포. 기본 pos.axis = origin.axis + rand(-distanceMax.axis, +distanceMax.axis).
    /// F620: 실물 speedmin/speedmax(초기속도)와 F627 distancemin(코너 쌍)은 케이스 시그니처 무회귀를
    /// 위해 def.emitterSpeed/def.boxDistanceMin 병렬 배열에 둔다(emitterAudio 와 동형).
    case box(origin: Vec3, distanceMax: Vec3, rate: Float, burst: Int)

    public var rate: Float {
        switch self {
        case let .sphere(_, _, _, _, r, _, _): return r
        case let .box(_, _, r, _): return r
        }
    }

    public var burst: Int {
        switch self {
        case let .sphere(_, _, _, _, _, b, _): return b
        case let .box(_, _, _, b): return b
        }
    }
}

public enum Initializer: Equatable {
    case lifetimeRandom(min: Float, max: Float, exponent: Float = 1)
    case sizeRandom(min: Float, max: Float, exponent: Float = 1)
    /// 0..255. [보존/추측] 한 t 로 min↔max 색 라인을 보간; WE RGB 축별 draw 반증 시 color만 재검토.
    case colorRandom(min: Vec3, max: Vec3, exponent: Float = 1)
    case alphaRandom(min: Float, max: Float, exponent: Float)
    /// [보존/추측] 방향/회전 스프레드 보존을 위해 성분별 독립 t를 사용한다.
    case velocityRandom(min: Vec3, max: Vec3, exponent: Float = 1)
    case rotationRandom(min: Vec3, max: Vec3, exponent: Float = 1)          // radians
    case angularVelocityRandom(min: Vec3, max: Vec3, exponent: Float = 1)   // radians/s
    case turbulentVelocityRandom(speedMin: Float, speedMax: Float, scale: Float, offset: Float)
    case colorList(colors: [Vec3])                     // 0..1 (실물 "r g b" 문자열 목록) — 균등 랜덤 선택
    /// S5④: HSV 공간 색 랜덤(magic_color_sparkle 등 프리셋 — 실물 예제 huemin/huemax/saturationmin/max/
    /// valuemin/max, 전부 0..1 스케일). 종전 case 이름 불인식 → 전 initializer drop(무색 랜덤 = 백색 고정).
    /// h/s/v 는 colorRandom(공유 t, RGB 라인 보간)과 달리 서로 무관한 축이라 velocityRandom 과 같이
    /// 채널별 독립 t. [보존/추측] "huesteps"(코퍼스 실측 2/4 존재, 이산 색상환 스텝 수)는 미구현 —
    /// 연속 hue 랜덤으로 근사(전무→근사, 폴백 방향 유지). 반증 시 재검토.
    case hsvColorRandom(hueMin: Float, hueMax: Float, satMin: Float, satMax: Float, valMin: Float, valMax: Float,
                        hueSteps: Int = 0, hueNoise: Float = 0, satNoise: Float = 0, valNoise: Float = 0)
    // hueSteps = 실물키 huesteps(코퍼스 실측 2/4, 이산 색상환 스텝 수 — [추정] 구간 등분 인덱스 선택,
    // 0=연속 랜덤 레거시). hueNoise/satNoise/valNoise = 실물키 huenoise/saturationnoise/valuenoise
    // (@0x48f5c0–0x48e3e0 — [추정] 스폰 위치 값노이즈로 채널 t 산출, 0=부재 시 레거시 rng 드로
    // — 무키 씬 비트동일).
    /// 스프라이트시트 프레임 선택(스폰 시 확정). between=false: CP0 기준 각도 → 시퀀스,
    /// true: CP0→CP1 구간 투영 → 시퀀스. count=시퀀스 길이(시트 프레임 수와 다를 수 있음 — mirror 폴드).
    case mapSequence(count: Float, mirror: Bool, between: Bool)
    /// 스폰 위치 오프셋 랜덤(실물키 positionoffsetrandom 의 offsetmin/offsetmax @0x48f580/398).
    /// [보존/추측] velocityRandom 과 동형 성분별 독립 t.
    case positionOffsetRandom(offsetMin: Vec3, offsetMax: Vec3)
    /// 파스·보존 전용(이벤트 시스템 연동 보류 — 시뮬레이터 무시, RNG 드로 0).
    /// 실물 inheritcontrolpointvelocity. 주입기 0x1401bad80..0x1401bb00e, 게이트 `stricmp`@0x1401c8586,
    /// 이니셜라이저 VM opcode 8 → 핸들러 0x14023bc32(오퍼레이터 VM 과 **다른** 인터프리터
    /// 0x14023b340, 점프테이블 0x14023fa78, 스폰 시 1회 실행).
    ///
    /// **[2026-08-20 키 정정]** `scale` 은 이 원소의 키가 **아니다** — 주입기에도 핸들러에도
    /// "scale" 문자열 참조가 없다(유령 필드였다). 실물 키는 `min`(0.1, movabs 0x3fb99999a0000000
    /// @0x1401bade5) · `max`(0.2, 0x3fc99999a0000000 @0x1401baea3) · `controlpoint`(0)뿐이고,
    /// 파스가 `min` 과 **`max − min`** 을 각각 레코드 +0x04/+0x08 에 저장한다(0x1401c865d `subss`).
    ///
    /// 의미: **CP 속도 벡터에 곱하는 균일 난수 스칼라 배율의 범위**(3성분 공통).
    ///   `v = (CP.pos − CP.prevPos) / [ctx+0x150]` ; `s = min + U[0,1)·(max − min)` ; `vel += M₃ₓ₃·(s·v)`
    /// RNG 는 **드로 1회**(0x14023bd06 → 0x1401f87a0, `(r>>8)/2^24`) — 구현하면 이후 이니셜라이저의
    /// RNG 시퀀스가 밀리므로 시뮬 착지는 별도 라운드로 미룬다. `controlpoint` 클램프는 없다
    /// (대신 CP 배열 크기를 인덱스에 맞춰 키운다 — controlpointattract 의 `>=7u → 7` 과 다르다).
    case inheritControlPointVelocity(controlPoint: Int, min: Float, max: Float)
    /// 파스·보존 전용(이벤트 시스템 연동 보류). 실물 inheritinitialvaluefromevent / inheritvaluefromevent.
    case inheritValueFromEvent(name: String, valueName: String?)
    /// 파스·보존 전용(이벤트 시스템 연동 보류). 실물 remapinitialvalue — 출력 리맵 스펙 미확정.
    case remapInitialValue(output: String?, min: Vec3?, max: Vec3?)
}

/// 시퀀스 인덱스(스폰 시 0..count) → 시트 프레임 인덱스. mirror=핑퐁(주기 2N-2), 아니면 순환.
public func sheetFrameIndex(sequence: Float, frameCount: Int, mirror: Bool) -> Int {
    guard frameCount > 0, sequence.isFinite else { return 0 }
    let rounded = sequence.rounded(.down)
    let s = rounded <= 0 ? 0 : (rounded >= Float(Int.max) ? Int.max : Int(rounded))
    guard frameCount > 1 else { return 0 }
    if mirror {
        let period = 2 * frameCount - 2
        let m = s % period
        return m < frameCount ? m : period - m
    }
    return s % frameCount
}

/// vortex_v2 ring 키. **[2026-08-20 주소 정정]** 종전 주석의 `@0x48faa8–0x48e8e0` 은 틀렸다 —
/// 그 자리는 `fogstartdensity`/`camerafade` 류의 카메라·포그 키다. 실측 RVA 는
/// ringradius 0x48faa8 · ringpulldistance 0x48fab8 · ringpullforce 0x48fad0 · ringwidth 0x48fae0.
/// (같은 주석 블록의 다른 주소들도 같은 폭으로 어긋나 있었다 — 아래 `case vortex` 참조.)
///
/// **WE 는 이 네 키를 vortex_v2 에서 무조건 주입한다** — 직교/원근 두 분기 어디로 가든 주입은
/// 일어나고 값만 갈린다(0x1401bf632 `test sil,sil` → ortho 300/50/10/50, 원근 1.0/0.25/0.05/0.2).
/// 따라서 "키가 하나도 없으면 링이 없다"는 상태는 WE 에 대응물이 없다.
///
/// 다만 **힘의 형태는 아직 측정된 것이 아니다.** 아래 [추정] 은 유지한다: 회전면 반경 dist 가
/// 링 대역(|dist−radius| ≤ width/2) 밖이고 pullDistance 이내이면 링 원주를 향한 반경 방향
/// 인력(pullForce)을 가한다. 상수는 실측이고 수식은 추정이라는 뜻이다 — 둘을 섞어 읽지 마라.
public struct VortexRing: Equatable {
    public let radius: Float
    public let pullDistance: Float
    public let pullForce: Float
    public let width: Float
    public init(radius: Float, pullDistance: Float, pullForce: Float, width: Float) {
        self.radius = radius; self.pullDistance = pullDistance
        self.pullForce = pullForce; self.width = width
    }
}

public enum ParticleOperator: Equatable {
    case movement(gravity: Vec3, drag: Float)
    case alphaFade(fadeInTime: Float, fadeOutTime: Float)          // 수명 비율 0..1 (fadeOut 0=없음)
    /// 수명 비율 구간에서 factor를 보간해 현재 크기에 곱한다.
    case sizeChange(startTime: Float, startValue: Float, endValue: Float, endTime: Float = 1)
    /// 수명 비율 구간에서 RGB factor를 성분별 보간해 현재 색에 곱한다.
    case colorChange(startTime: Float, startValue: Vec3, endValue: Vec3, endTime: Float = 1)
    /// 각가속 + 선형 movement(위 61행)와 대칭인 drag 감쇠(기본 0=무감쇠, 종전 동작 무회귀).
    case angularMovement(force: Vec3, drag: Float = 0)
    /// 위상 진동: alpha ×= lerp(scaleMin, scaleMax, 0.5(1+sin(2πf·(age/lifetime)+phase))). 파티클별 f/phase 는
    /// 스폰 시 range(min,max) 샘플(phasemin/max 부재 시 0 — 전 파티클 동위상, fireworks 근동기 의도).
    /// f 단위 = 수명당 진동 횟수(F832, WE 공식 디자이너 문서 operator.html — oscillate 3종 공통).
    case oscillateAlpha(frequencyMin: Float, frequencyMax: Float, scaleMin: Float, scaleMax: Float,
                        phaseMin: Float = 0, phaseMax: Float = 0)
    case oscillatePosition(frequencyMin: Float, frequencyMax: Float, scaleMin: Float, scaleMax: Float,
                           phaseMin: Float, phaseMax: Float, mask: Vec3)
    /// 컨트롤포인트로의 인력/척력. 주입기 0x1401bdee0..0x1401be293(5조각), 게이트 `stricmp`@0x1401cc9da.
    ///
    /// **[2026-08-20] 대상은 `origin` 도 `offset` 도 아니라 컨트롤포인트다.**
    /// "origin" 은 이 원소의 주입기·핸들러 구간에 참조가 아예 없고(유령 키), `offset` 은 파스는
    /// 되지만 **런타임에서 위치로 쓰이지 않는다** — 핸들러의 유일한 참조가
    /// `lea r8, [r14+0x10]`(0x14024194e)이고 그건 삭제 함수에 넘기는 베이스 포인터다.
    /// 실제 대상은 `CP[controlpoint].worldPos`(0x140241769–0x140241794 → 0x140241856 `subps`).
    ///
    /// **[2026-08-20 미해결]** `deleteThreshold` 를 Bool 로 두고 있으나 실물은 **실수 거리**다:
    /// 주입이 jsoncpp type tag 3(`mov byte [rbp-0x50],3` @0x1401be1a9, `cvtps2pd` @0x1401be1ca)이고
    /// 읽기도 `asFloat`(0x1401ccbaa) 직후 **`mulss xmm6,xmm6`**(0x1401ccbef)로 제곱해 레코드에 넣는다.
    /// 부재 기본은 ortho **15.0** / 원근 0.5 — 동봉 `controlpointattract`(all 34 · unique 29)가 **전건 이 키를 생략**하므로
    /// 기본값이 항상 발화하는 자리다. 다만 그 제곱값이 어느 방향 비교에 쓰이는지, `flags`(기본 **2**,
    /// 유일하게 magic_vortex_orb 만 `0` 으로 끈다)가 게이트인지가 아직 미측정이라 **타입을 바꾸지
    /// 않았다**. 측정 없이 Bool→Float 로 바꾸면 전 인스턴스에서 파티클을 지우기 시작한다.
    /// `flags` 기본은 **2**(주입기 0x1401be245 `mov qword [rbp-0x58], 2`). 비트는 핸들러가
    /// 딱 두 곳에서만 읽는다:
    ///   · bit0(1) — **근접 삭제 활성화**(0x14024193d). 기본값 2 에는 없으므로 **기본은 꺼짐**.
    ///   · bit1(2) — **오버슛 클램프**(0x140241750 → 0x1402418dc–0x1402418e4):
    ///     `if (dist < step) step = dist` — 이번 스텝의 속도 증분을 CP 까지의 거리로 상한.
    /// 동봉 `controlpointattract`(all 34 · unique 29) 중 `flags` 를 적는 것은
    /// `magic_vortex_orb`(0) 하나뿐이고, 그것이 끄는 건
    /// **오버슛 클램프 하나**다(bit0 은 기본값에서도 이미 꺼져 있다).
    case controlPointAttract(scale: Float, threshold: Float, target: Vec3, deleteThreshold: Bool = false,
                             flags: Int = 2)
    /// 컨트롤포인트 중심의 반지름 `distance` 구면으로 **위치를 투영**한다(속도는 안 건드린다).
    /// 주입기 0x1401be2a0..0x1401be5d0(5조각), 게이트 `stricmp`@0x1401ccdcc, VM opcode 0x0b,
    /// 런타임 핸들러 0x14024197a. 레코드: distance @+0x10 · variablestrength @+0x14 ·
    /// controlpoint @+0x60(stride 0xd0, 배열 `[sys+0x400]`).
    ///
    /// 실측 루프(0x140241bd0..0x140241cbc, 4-wide SIMD)를 그대로 옮기면:
    ///     p  = pos + O ;  d = p − C
    ///     k  = (distance / |M·d| − 1) · s
    ///     pos' = p + k·d                       // 0x140241c96·0x140241c9e·0x140241caa 에 저장
    /// `M`/`O` 는 CP 의 변환 행렬·원점 합성인데, 유일한 실사용처(Magic "Vortex orb")의 CP0 이
    /// `{"id": 0}` = 시스템 원점이라 M = I · O = 0 으로 축약된다. 그래서 **G-C2-02(CP 전면 지원)
    /// 없이도 원본과 같아진다** — 종전 "CP 지원 없으면 어차피 no-op" 판단은 이 원소엔 거짓이다
    /// (외부 분기가 `입자 수 == 0` 하나뿐이라 퇴화 가드가 아예 없다).
    ///
    /// `s` 는 0x140241992 의 `ucomiss` 분기다:
    ///   · variablestrength ≠ 0 → `clamp01(variablestrength · dt)`
    ///     (0x1402419a0 `mulss xmm0, [rbp+0x2008]` = arg2 = **생 dt**, 0x1401d8df0 = clamp01)
    ///   · variablestrength = 0 → **상수 1.0** — 반지름 `distance` 구면으로의 즉시 투영이다.
    ///
    /// **[2026-08-20 정정]** 종전엔 후자를 "VM 의 2번째 인자 `dt·min(1,0.025/dt)^0.7`
    /// (0x140237724–0x14023774f) — 매우 느린 수렴이지 즉시 스냅이 아니다" 라고 적었다. 틀렸다.
    /// 같을 때 실행하는 것은 `movaps xmm11, xmm2`(base 0x14024199a · ext 0x140241cef)이고, 그
    /// `xmm2` 는 핸들러 인자가 아니라 **op 디스패치 프리앰블이 opcode 마다 새로 심는 스칼라
    /// 상수 1.0** 이다(`movss xmm2, [0x140492704]` @0x14023fd77 → `jmp rax` @0x14023fdc7 까지
    /// 재대입 없음). 호출부에서 xmm2 레지스터가 3번째 인자 dtScaled 를 나르는 것과 혼동한
    /// 것이다 — dtScaled 는 프리앰블이 `[rbp+0x5f0]`/xmm8 에 따로 보관한다.
    /// 이름 그대로 `variablestrength` 를 적어야 비로소 "가변(연성)" 수렴이 된다.
    case maintainDistanceToControlPoint(distance: Float, variableStrength: Float, target: Vec3)
    /// 무리 행동(분리·정렬·응집). 주입기 0x1401bf700, 게이트 `stricmp`@0x1401ce402
    /// (문자열 `"boids"`@0x14048ff7c — 전 바이너리 lea 참조 1곳 0x1401ce3fb), VM opcode 0x11 →
    /// 핸들러 **0x140244121**. 컨트롤포인트를 전혀 참조하지 않는 순수 입자간 상호작용이다.
    ///
    /// 실측 구조(0x140244121–0x14024421e 앞머리 + 0x140244304– 내부 루프):
    /// ```
    ///   N     = count/100 + 1              ; magic-div 0x51eb851f, shr 6 → +1 (0x140244153–0x140244167)
    ///   phase = frameCounter % N           ; [ctx+0x144] (0x140244161, 0x14024416d)
    ///   sepF  = separationfactor·N·dtScaled ; 0x1402441ab  (아래 둘도 동형)
    ///   for 4-입자 그룹 g where g ≡ phase (mod N):     ; i = phase·4, step N·4
    ///     for each j (살아있고 j ≠ i):
    ///       d = pos[i] − pos[j] ; L = |d|            ; rsqrtps 근사
    ///       if L < separationthreshold: sepAcc += (separationthreshold/L − 1)·d ; sepCnt++
    ///       if L < neighborthreshold:   velAcc += vel[j] ; posAcc += pos[j] ; nCnt++
    ///     dv = (sepCnt ? sepF/sepCnt·sepAcc : 0)
    ///        + (nCnt ? aliF·(velAcc/nCnt − vel[i]) + cohF·(posAcc/nCnt − pos[i]) : 0)
    ///     v = vel[i] + dv
    ///     if (flags & 1) && max(|vel[i]|², maxspeed²) < |v|²: v *= maxspeed/|v|
    ///     vel[i] = v                       ; 위치는 건드리지 않는다
    /// ```
    /// `N` 곱셈은 서브샘플링 보상이다. 분리항이 `maintaindistancetocontrolpoint` 와 **같은
    /// `(threshold/L − 1)` 형태**를 쓴다.
    ///
    /// 부재 기본값(실측): separationthreshold ortho **20**(0x1401bf726) / 원근 0.02 ·
    /// neighborthreshold **50**(0x1401bf7f5) / 0.2 · maxspeed **500**(0x1401bf8c4) / 1 ·
    /// separationfactor **15**(f64 @0x140492818, 플래그 무관) · alignmentfactor **1**(0x1401bf9fd) ·
    /// cohesionfactor **2**(0x1401bfa14) · flags **1**(`mov qword [rbp-0x40], 1` @0x1401bfa69).
    /// flags bit0 = 속도 상한 활성화 — **기본이 켜져 있다**. 동봉 실사용 2종은 `flags: 0` 으로 끈다.
    case boids(separationThreshold: Float, neighborThreshold: Float, maxSpeed: Float,
               separationFactor: Float, alignmentFactor: Float, cohesionFactor: Float, flags: Int)
    /// 축 기준 소용돌이. 실물키: axis, distanceinner/outer, speedinner/outer, offset(중심).
    /// 확장 키. **[2026-08-20 주소 정정]** 이 블록의 RVA 가 전부 계통적으로 어긋나 있었다
    /// (0x48e7c8 은 `"olor"` 중간, 0x48e7e0 은 `fogdistancestart`). 실측:
    /// centerforce 0x48f9f8 · variablestrength 0x48fa08 · reductioninner 0x48fa40 ·
    /// reductionouter 0x48f9c8 · ring 0x48faa8/0x48fab8/0x48fad0/0x48fae0.
    ///
    /// centerforce 는 축 중심을 향한 반경 인력(의미 명확, 구현). **참조가 전 바이너리에 단 2곳**
    /// — vortex_v2 주입기(lea @0x1401bf5f5)와 vortex_v2 핸들러(@0x1401ce07a)뿐이라 자매
    /// `vortex` 와는 무관하다.
    ///
    /// variablestrength/reductioninner/reductionouter 는 **여기 소유가 아니다**:
    /// variablestrength 는 maintaindistancetocontrolpoint 계열, reduction* 는
    /// reducemovementnearcontrolpoint 계열만 참조한다. 두 vortex 어느 쪽도 읽지 않는다 —
    /// 파스·보존 전용으로 남기되 기본값을 심으면 안 된다.
    /// `flags` 는 파스만 하는 값이 아니라 **동작을 가르는 게이트**다(실측):
    ///   · bit0 — 축 성분 제거(축 투영). **비면 `radial = d` 3D 전체**를 쓴다.
    ///     런타임이 `andps xmm2, mask`(0x140243316)로 `proj` 를 통째로 0 으로 만든다.
    ///   · bit1 — vortex_v2 의 `centerforce` 파스 게이트(`test r14b,2` / `je` @0x1401ce074).
    ///   · bit2 — vortex_v2 의 ring 모드(`test byte [r14+0x110],4` @0x1402434eb).
    /// 기본 0 이라 셋 다 꺼져 있다. 동봉 실코퍼스: vortex 는 1·1·부재×5, vortex_v2 는
    /// 3·2·2·2·부재 — **bit2 를 가진 인스턴스가 하나도 없다**.
    case vortex(axis: Vec3, distanceInner: Float, distanceOuter: Float,
                speedInner: Float, speedOuter: Float, offset: Vec3,
                centerForce: Float = 0, ring: VortexRing? = nil, flags: Int = 0)
    /// 결정적 노이즈 흐름장 난류. 실물키(정찰 55인스턴스): speedmin/speedmax(파티클별 속도 범위),
    /// scale(공간 주파수), timescale(시간 진화 속도), mask(축별 게이트 "x y z"),
    /// phasemin/phasemax(파티클별 위상 오프셋).
    ///
    /// **난류는 위치가 아니라 속도에 더한다** — 핸들러 프리앰블이 잡는 포인터가 못박는다
    /// (0x1402429dd–0x140242a05):
    ///   `rcx/rdx/r8  = [sys+0x2b0/0x2b8/0x2c0]` = **위치** — 노이즈 좌표를 만드는 데만 읽는다
    ///   `r15/r12/r13 = [sys+0x2c8/0x2d0/0x2d8]` = **속도** — 꼬리에서 여기에 누적한다
    /// 꼬리 0x140242d3a–0x140242d54: `addps xmm, [r15+rdi*4]` → `movups [r15+rdi*4], xmm` ×3.
    /// 즉 난류는 **가속(force)** 이고, 저작 순서상 movement 의 적분 뒤에 실리므로 다음 프레임
    /// 변위에 나타나며 뒤따르는 `reducemovementnearcontrolpoint` 의 감쇠를 그대로 받는다.
    ///
    /// **[2026-08-20 해소] 배수 사슬을 전부 닫았다.** 종전 주석은 여기가 "절반만 추적됐다"며
    /// 수정을 미뤄 뒀는데, 남아 있던 `dtScaled` 삽입점이 확정됐다 — 사슬 전체는 이렇다:
    ///
    ///     ph = r·(pmax − pmin) + t·timescale        0x140242a70 → 0x140242a81  (pmin 은 미참조)
    ///     c  = (pos + ph) · scale                   0x140242a93/97/9c → 0x140242aa1/a5/a9
    ///     n  = ( N(c.z,c.x,c.y), N(c.y,c.z,c.x), N(c.x,c.y,c.z) )   순환치환, 가산 오프셋 없음
    ///     v += n ⊙ (mask · dtScaled) · (smin + r·(smax−smin)) · audio · blendW
    ///          mask·dtScaled 는 루프 밖에서 한 번 굳힌다 0x1402429cf/0x140242a14/0x140242a37
    ///          노이즈에 곱함 0x140242cfc/d0f/d18 → speed 곱함 0x140242d2e/32/36 → 속도에 addps
    ///
    /// 전부 스칼라 곱이라 곱하는 **순서**는 산술적으로 무관하다. 중요한 것은 dt 가 정확히 한 번
    /// 선형으로만 들어간다는 것 — 숨은 배수가 없으니 "배수를 틀려 발산" 할 여지가 없다.
    /// (오디오 배수는 동봉 코퍼스 도달 0. `audioResponse` = 0x14022a8a0, 구간 MAX.)
    ///
    /// 부재 기본값은 주입기 0x1401beb80 에서 온다 — timescale 은 **0(정적장)이 아니다**
    /// (직교 20.0 / 원근 1.0). 파스 지점 주석 참조.
    case turbulence(speedMin: Float, speedMax: Float, scale: Float, timeScale: Float,
                    mask: Vec3, phaseMin: Float, phaseMax: Float)
    /// 크기 진동: size ×= lerp(scaleMin, scaleMax, 0.5(1+sin(2πf·(age/lifetime)+phase))). 파티클별 f/phase 스폰 샘플.
    case oscillateSize(frequencyMin: Float, frequencyMax: Float, scaleMin: Float, scaleMax: Float,
                       phaseMin: Float, phaseMax: Float)
    /// 수명 비율 구간에서 alpha factor를 보간해 현재 알파에 곱한다.
    case alphaChange(startTime: Float, endTime: Float, startValue: Float, endValue: Float)
    /// 노이즈 리맵: velocity = 범위 보간(덮어쓰기, 매 스텝) / speed = 적분 속도 배수(비파괴 — 복리 방지).
    /// 노이즈 입력은 파티클별 위상 + age (근사 — WE 정의 미공개, 유계·탈동기·결정성 보장).
    case remapValue(output: RemapOutput, fbm: Bool, inputScale: Float)
    /// remapvalue 확장 파이프라인(엔진 어휘 전종 — input/operation/transform/동사형 출력/blend 창).
    /// 확장 키가 하나라도 있거나 출력이 velocity/speed 외 동사형이면 이 케이스로 파스된다.
    case remapValueEx(spec: RemapSpec)
    /// `capvelocity` — 속도 크기 상한. 실물 VM 핸들러 op 0x12 @0x1402446fd:
    /// `s = min(1, maxspeed·rsqrt(|v|²)); v *= s` — 방향 보존 스칼라 클램프다.
    /// 실물 주입기 0x1401bfab0: `maxspeed` 부재 기본값 = **100**(0x1404928f8, 2D 픽셀 단위 경로)
    /// / 1.0(0x140492704, 월드 단위 경로). Waple 은 2D 픽셀 경로만 쓰므로 100 을 심는다.
    case capVelocity(maxSpeed: Float)
    /// `reducemovementnearcontrolpoint` — CP 근처에서 속도를 감쇠. 실물 VM 핸들러 op 0x0d
    /// @0x14024268f 를 그대로 옮긴 식(레지스터 주석은 ParticleSimulator.applyReduceMovement 참조):
    /// `t = clamp01((|p−cp| − distIn)·invRange); r = clamp01((redIn + t·redDelta)·dt); v *= (1 − r)`.
    /// `invRange`/`redDelta` 는 ctor(0x1401cd38d–0x1401cd3e7)가 미리 계산해 레코드에 굽는 값이고,
    /// 퇴화 케이스의 대입값(invRange=−0.0, redDelta=1.0)까지 원본과 같게 재현한다.
    /// 실물 주입기 0x1401be810 부재 기본값: controlpoint=0(정수) · distanceinner=100 · distanceouter=350
    /// · reductioninner=100(0x140492840, 조건 없는 double) · reductionouter=0.
    case reduceMovementNearControlPoint(distanceInner: Float, distanceOuter: Float,
                                        reductionInner: Float, reductionOuter: Float,
                                        target: Vec3)
}

public enum RemapOutput: Equatable {
    /// 레거시 출력 "velocity" — 엔진 어휘 setvelocity 계열로 해석(매 스텝 덮어쓰기). 동작 무회귀.
    case velocity(min: Vec3, max: Vec3)
    /// 레거시 출력 "speed" — 엔진 어휘 multiplyspeed 계열로 해석(적분 속도 비파괴 배수). 동작 무회귀.
    case speed(min: Float, max: Float)
}

/// remapvalue 출력 동사(wallpaper64.exe 스트링 @0x491fd0–0x490eb0). set*=덮어쓰기, add*=가산
/// ([추정] rotation/angularvelocity 는 프레임 독립을 위해 dt 곱 가산율), multiply*=곱.
/// opacity/color/size 는 표시 파생(display 단계) 적용, velocity/speed/rotation/angularvelocity 는
/// 스텝 적분 단계 적용. 레거시 문자열 매핑: "velocity"→setVelocity, "speed"→multiplySpeed.
public enum RemapVerb: String, Equatable {
    case setVelocity = "setvelocity"
    case addVelocity = "addvelocity"
    case multiplySpeed = "multiplyspeed"
    case setOpacity = "setopacity"
    case multiplyOpacity = "multiplyopacity"
    case setColor = "setcolor"
    case multiplyColor = "multiplycolor"
    case setSize = "setsize"
    case multiplySize = "multiplysize"
    case setRotation = "setrotation"
    case addRotation = "addrotation"
    case setAngularVelocity = "setangularvelocity"
    case addAngularVelocity = "addangularvelocity"
}

/// remapvalue 입력 소스(wallpaper64.exe 스트링 @0x491e78–0x490d60). [추정] 시계열 류(layertime/
/// runtime/timeofday)는 헤드리스 결정성 우선으로 시뮬 누적시간 근사. directiontocontrolpoint 는
/// component 키로 성분 선택(기본 x).
public enum RemapInput: String, Equatable {
    case lifetimeFraction = "lifetimefraction"
    case particleSystemTime = "particlesystemtime"
    case layerTime = "layertime"
    case velocity = "velocity"
    case deltaToControlPoint = "deltatocontrolpoint"
    case distanceToControlPoint = "distancetocontrolpoint"
    case directionToControlPoint = "directiontocontrolpoint"
    case positionBetweenControlPoints = "positionbetweentwocontrolpoints"
    case layerOrigin = "layerorigin"
    case runtime = "runtime"
    case timeOfDay = "timeofday"
}

/// remapvalue operation(엔진 어휘). [추정] 정규화값 v∈[0,1] 의 단항 셰이핑으로 해석(제2 피연산자
/// 부재): remap=항등(기본), subtract=1−v, square=v². multiply/average 는 단항 의미 부호화 불가 —
/// 파스·보존 전용(항등 적용).
public enum RemapOperation: String, Equatable {
    case remap, subtract, multiply, average, square
}

/// remapvalue transformfunction(엔진 어휘). [추정] simplexnoise 는 코퍼스에 심플렉스 구현이 없어
/// 단일 옥타브 값노이즈 근사. fbmnoise 는 transformoctaves(@0x48f8d8, 기본 3) 옥타브 합성.
public enum RemapTransform: String, Equatable {
    case triangle, simplexnoise, fbmnoise
}

/// remapvalue 확장 스펙(엔진 어휘 전종 파스). 의미 구현 가능한 것만 시뮬레이터가 소비하고
/// 나머지(outputcontrolpoint0/1, multiply/average operation)는 보존 전용.
/// 오퍼레이터 페이드 창(G-C2-03). 공용 파서 **0x1401c2a40 .. 0x1401c2e4e**(`.pdata` 5조각)가
/// 네 키를 읽어 파라미터 넷을 굽고, 런타임 **0x14022a530**(`.pdata` 엔트리 없는 리프, SSE packed)
/// 가 그것으로 수명 비율 `f = age/lifetime` 에 대한 가중치를 낸다.
///
/// 키와 부재 기본값(전부 플래그 무관, ortho/원근 분기 없음):
/// `blendinstart` 0 · `blendinend` 0 · `blendoutstart` **1.0**(movabs @0x1401c2c26) ·
/// `blendoutend` **1.0**(f64 @0x140492778, 로드 @0x1401c2cd3).
///
/// 유도(0x1401c2d80–0x1401c2e04), `eps = 1e-4`(@0x1404925fc):
/// ```
///   inStart = min(blendinstart, blendinend − eps)      ; 0x1401c2d9f–0x1401c2da8
///   outEnd  = max(blendoutend,  blendoutstart + eps)   ; 0x1401c2dae–0x1401c2db7
///   P0 = inStart · P1 = rcp(blendinend − inStart) · P2 = outEnd · P3 = rcp(outEnd − blendoutstart)
/// ```
/// 런타임: `w = clamp01((f − P0)·P1) · clamp01((P2 − f)·P3)`.
/// **세 번째 파라미터는 outStart 가 아니라 outEnd 다** — 이 자리를 틀리면 페이드아웃이 뒤집힌다.
///
/// 활성화 게이트(0x1401c2deb–0x1401c2e33). 통과할 때만 레코드의 opcode 를 base → ext 로
/// 승격하고, 아니면 가중 코드가 **아예 실행되지 않는다**(w ≡ 1):
/// ```
///   (blendinend > 0.01 || blendoutstart < 0.99)
///   && (blendoutstart − blendinend > 0.01 || inDur > 0.01 || outDur > 0.01)
/// ```
/// 기본값 0/0/1/1 은 첫 조건에서 탈락한다.
///
/// 적용은 오퍼레이터마다 필드별 `new = old + w·(unweighted − old)` 다. 스케일 계수 자리에서는
/// `s = 1 + w·(s₀ − 1)` 로 보이지만 그건 같은 lerp 의 특수형이다.
public struct BlendWindow: Equatable {
    public let inStart: Float
    public let invInDur: Float
    public let outEnd: Float
    public let invOutDur: Float
    /// 게이트를 통과했는가. false 면 가중치는 항상 1 이다.
    public let active: Bool

    public init(inStart bis: Float, inEnd bie: Float, outStart bos: Float, outEnd boe: Float) {
        let eps: Float = 1e-4
        let start = min(bis, bie - eps)
        let end = max(boe, bos + eps)
        let inDur = bie - start
        let outDur = end - bos
        inStart = start
        outEnd = end
        invInDur = 1 / inDur
        invOutDur = 1 / outDur
        active = (bie > 0.01 || bos < 0.99)
            && (bos - bie > 0.01 || inDur > 0.01 || outDur > 0.01)
    }

    /// 창 없음(가중치 항상 1). 직접 조립한 def 나 인덱스 밖 접근의 기본값이다.
    public static let identity = BlendWindow(inStart: 0, inEnd: 0, outStart: 1, outEnd: 1)

    /// `f` = 파티클 수명 비율(age/lifetime). 실물은 `rcpps` 근사라 비트동일 재현은 불가능하다.
    public func weight(lifeFraction f: Float) -> Float {
        guard active else { return 1 }
        let a = max(0, min(1, (f - inStart) * invInDur))
        let b = max(0, min(1, (outEnd - f) * invOutDur))
        return a * b
    }
}

public struct RemapSpec: Equatable {
    public let verb: RemapVerb
    /// nil = input 키 부재 → 레거시 동형 노이즈 입력((remapPhase+age)·K·inputScale).
    public let input: RemapInput?
    public let operation: RemapOperation      // 부재 remap
    public let transform: RemapTransform?     // nil = 변환 없음(입력을 0..1 클램프해 직접 매핑 [추정])
    public let octaves: Int                   // transformoctaves (기본 3)
    public let inputScale: Float              // transforminputscale (기본 1)
    public let outMin: Vec3                   // outputrangemin (스칼라 브로드캐스트)
    public let outMax: Vec3                   // outputrangemax
    /// blendinstart/end · blendoutstart/end. 실물 RVA 는 **0x48f850/0x48f860/0x48f870/0x48f880**
    /// (종전 주석의 0x48e650–0x48e680 은 어긋난 주소다). 부재 기본은 0/0/**1**/**1** 이고
    /// 유도·게이트는 `BlendWindow` 주석 참조 — 종전의 "전부 0 이면 무창" 은 기본값부터 틀렸다.
    public let blendInStart: Float
    public let blendInEnd: Float
    public let blendOutStart: Float
    public let blendOutEnd: Float
    public let inputCP0: Int                  // inputcontrolpoint0 (기본 0)
    public let inputCP1: Int                  // inputcontrolpoint1 (기본 1)
    public let outputCP0: Int                 // outputcontrolpoint0/1 — 파스·보존 전용(소비처 보류)
    public let outputCP1: Int
    public let component: Int                 // component: 0=x/1=y/2=z (기본 0)
    /// 네 키에서 유도한 페이드 창. 게이트 판정까지 포함한다.
    public var blendWindow: BlendWindow {
        BlendWindow(inStart: blendInStart, inEnd: blendInEnd,
                    outStart: blendOutStart, outEnd: blendOutEnd)
    }
    public init(verb: RemapVerb, input: RemapInput?, operation: RemapOperation,
                transform: RemapTransform?, octaves: Int, inputScale: Float,
                outMin: Vec3, outMax: Vec3,
                blendInStart: Float, blendInEnd: Float, blendOutStart: Float, blendOutEnd: Float,
                inputCP0: Int, inputCP1: Int, outputCP0: Int, outputCP1: Int, component: Int) {
        self.verb = verb; self.input = input; self.operation = operation
        self.transform = transform; self.octaves = octaves; self.inputScale = inputScale
        self.outMin = outMin; self.outMax = outMax
        self.blendInStart = blendInStart; self.blendInEnd = blendInEnd
        self.blendOutStart = blendOutStart; self.blendOutEnd = blendOutEnd
        self.inputCP0 = inputCP0; self.inputCP1 = inputCP1
        self.outputCP0 = outputCP0; self.outputCP1 = outputCP1; self.component = component
    }
}

/// F622: 실물 def 최상위 "animationmode"(스프라이트시트 재생 모드). 부재/미지 = frametime 기반
/// 기본 재생(기존 폴터). sequence = 수명에 걸쳐 순차 재생(×sequencemultiplier — 프레임 수가
/// 필요해 렌더 경로 소비, 본 갭에서는 파스·보존), randomframe = 스폰 시 랜덤 프레임 1개 고정
/// (시뮬이 p.frame 을 스폰 확정 → 정지 파티클의 프레임 깜빡임 해소).
public enum ParticleAnimationMode: String, Equatable {
    case sequence
    case randomframe
}

/// F626: 실물 렌더러 "orientation"(공식 문서: screen=기본 빌보드, upright=Y축 고정, fixed=축 고정).
/// 파스·보존 전용 — 실제 쿼드 배향은 WapleRender 경로 소비(본 갭 스코프 밖).
public enum ParticleOrientation: Equatable {
    case screen
    case upright
    case fixed(axis: Vec3)
}

/// 파티클 렌더러. sprite = 빌보드 쿼드. F790 부터 분화 — rope/ropeTrail 만 위치 히스토리 리본,
/// spriteTrail 은 WE 공식 의미(속도 방향 신장 쿼드 — spriteTrailStretch 참고)로 정정.
/// isTrail 은 3D 경로 호환을 위해 spriteTrail 을 여전히 포함(2D 경로만 신장 쿼드로 분기).
public enum RendererKind: Equatable {
    case sprite
    case spriteTrail(maxLength: Float, length: Float, minLength: Float)
    case rope(subdivision: Int)
    case ropeTrail(length: Float, subdivision: Int)
    case unsupported(String)

    /// 히스토리 리본 계열인가. spriteTrail 은 2D 경로에선 F790 신장 쿼드로 분기하고
    /// 리본을 그리지 않는다 — 이 플래그는 3D 경로 소비·refract 제외 판정 호환으로 유지.
    public var isTrail: Bool {
        switch self {
        case .spriteTrail, .rope, .ropeTrail: return true
        default: return false
        }
    }

    /// C4-(iii): REFRACT 디스패치 게이트 전용 — rope/ropeTrail(위치 히스토리 리본)만 배제한다.
    /// spriteTrail(F790 신장 쿼드)은 sprite 와 동형의 쿼드 지오메트리라 REFRACT 정접 대상(코퍼스
    /// additive+REFRACT 10씬 중 rain_on_the_glass1 등 spriteTrail 실측) — isTrail(위, 벡터
    /// reservation/appendRibbon 분기용)과 달리 spriteTrail 을 false 로 분리한다.
    public var isRopeTrail: Bool {
        switch self {
        case .rope, .ropeTrail: return true
        default: return false
        }
    }

    /// 리본에 보관할 위치 히스토리 샘플 수(step 당 1샘플, captureFrames=30fps 가정).
    /// spriteTrail=maxlength(세그먼트 수 근사), ropeTrail=length(초)×30, rope=subdivision(F629,
    /// 부재/0 시 종전 고정 16). F625: 캡 24→240 — maxlength 100/ropetrail 수초 트레일이 24샘플
    /// (30fps 0.8초)로 절단됐다. WE spritetrail 의 length 는 "speed×length 신장" 의미(공식 문서)라
    /// 샘플 수에 쓰지 않는다(속도-신장 렌더 = F790 에서 2D 경로 소비. 히스토리는 3D 경로 호환으로 유지).
    public var trailSampleCount: Int {
        func clamp(_ v: Int) -> Int { min(240, max(4, v)) }
        func clampedRounded(_ value: Float) -> Int? {
            guard value.isFinite, value > 0 else { return nil }
            if value >= 240 { return 240 }
            return clamp(Int(value.rounded()))
        }
        switch self {
        case let .spriteTrail(maxLength, _, _):
            return clampedRounded(maxLength) ?? 8
        case .rope:
            // **[2026-08-20]** 종전엔 `subdivision` 을 샘플 수로 썼다(F629). 그 매핑은 WE 근거가
            // 없다 — 실물 `subdivision` 은 커브 세분 횟수([0,32] 클램프)이지 히스토리 길이가
            // 아니다. 이제 주입 기본이 4 로 확정됐으므로 그 값을 그대로 흘리면 부재 11건의
            // 샘플이 16 → 4 로 **눈에 보이게 줄어든다** — 근거 없는 매핑에 새 정밀도를 얹는 꼴이다.
            // 리본 지오메트리를 실측할 때까지 대역값 16 을 유지한다.
            return 16
        case let .ropeTrail(length, subdivision):
            return clampedRounded(length * 30) ?? clampedRounded(Float(subdivision)) ?? 12
        default:
            return 0
        }
    }

    /// spritetrail = "속도 방향으로 신장된 쿼드". **WE 가 셰이더 원문을 동봉한다** —
    /// `assets/shaders/common_particles.h`:
    ///
    /// ```glsl
    /// float trailLength = length(localVelocity);
    /// localVelocity /= trailLength;
    /// up = localVelocity * max(g_RenderVar0.z, min(trailLength * g_RenderVar0.x, g_RenderVar0.y));
    /// ```
    /// 그리고 `ComputeParticlePosition` 이 두 축 모두에 `positionAndSize.w`(= size)를 곱한다:
    /// ```glsl
    /// positionAndSize.xyz + (positionAndSize.w * right * (uvs.x-0.5)
    ///                      - positionAndSize.w * up   * (uvs.y-0.5) * textureRatio)
    /// ```
    /// 비-트레일 경로에서 `up` 은 단위벡터이므로, 트레일의 `up` 크기가 곧 **size 배수**다.
    /// `g_RenderVar0 = (length, maxlength, minlength)` — 클램프 순서가 `max(min, min(·, max))` 라
    /// `minlength > maxlength` 면 minlength 가 이긴다.
    ///
    /// **[2026-08-20] H3 핫픽스를 되돌린다.** H3 는 `length` 부재 시 신장을 항등 1 로 돌렸고
    /// 근거를 "length 는 speed 의 유일한 승수라 부재 시엔 신장 자체가 정의되지 않는다" 로 적었다.
    /// 그 전제가 틀렸다 — 주입기 0x1401c0af0 이 부재에도 `length` 에 **0.05**(0x1401c0b55),
    /// `maxlength` 에 **10.0**(0x1401c0c13)을 심으므로 신장은 언제나 정의된다.
    ///
    /// H3 가 관측한 회귀(rain_on_the_glass 흰 스미어)의 실제 원인은 그 직전 폴백
    /// `mul = 1` → `s = speed`(수백)였다. `s = speed·0.05` 는 그보다 20배 작다 — 즉 H3 는
    /// **한 번도 시험되지 않은 값**을 두고 반대편 극단(무신장)으로 넘어간 것이다. 다만
    /// `maxlength = 6` 인 그 프리셋은 실물에서도 speed 120 부터 포화하므로 **WE 자신이 굵은
    /// 스트릭을 그린다** — H3 가 "명백한 회귀" 로 판정한 비교 대상은 WE 가 아니라 Waple 의 옛
    /// 리본 구현이었다.
    ///
    /// 결과적으로 `length` 부재 13건 · `maxlength` 부재 11건(동봉 44 중)의 **그림이 달라진다** —
    /// Mac 골든 재검토 대상이다. 근거가 바이트(주입기)와 WE 동봉 셰이더 원문 둘이라, 관측
    /// 판단(옛 구현과의 비교)보다 우선한다.
    public func spriteTrailStretch(speed: Float) -> Float {
        guard case let .spriteTrail(maxLength, length, minLength) = self else { return 1 }
        // 셰이더 원문 그대로: max(minlength, min(speed·length, maxlength)).
        // 종전엔 `min`/`max` 순서가 반대였고(minlength > maxlength 에서 갈린다),
        // `maxLength <= 0` 을 1 로 바꿔치는 보정이 있었다 — 실물은 그 값을 그대로 써서
        // 신장 0(퇴화 쿼드)을 만든다. 동봉 저작값에 0 은 없다(2·3·20·1.5).
        return max(minLength, min(speed * length, maxLength))
    }
}

public enum BlendKind: Equatable { case additive, translucent }

public struct ParticleMaterial: Equatable {
    public let textureName: String?
    public let blend: BlendKind
    /// REFRACT 콤보(스크린 굴절): 노멀맵(normalTextureName=textures[1]) 의 xy 로 씬 컬러 타깃을 재샘플해 곱한다.
    public let refract: Bool
    public let normalTextureName: String?
    public let refractAmount: Float   // g_RefractAmount (WE 기본 0.05)
    /// M(④): combos.FOG(genericparticle.frag/genericropeparticle.frag 기본 1 — 명시 0 만 씬 포그 제외).
    /// 메시 경로(SceneRenderer3D.loadMesh3DMaterial `foggy`)와 동일 기본값·게이트 규약.
    public let foggy: Bool
    /// C4-(ii): g_Overbright(genericparticle.frag/genericropeparticle.frag — material 유니폼,
    /// 기본 1.0, range [0,5]). RGB 만 곱(알파 제외). 기본 1 이면 렌더 비트동일(무회귀).
    public let overbright: Float
    public init(textureName: String?, blend: BlendKind,
                refract: Bool = false, normalTextureName: String? = nil, refractAmount: Float = 0.05,
                foggy: Bool = true, overbright: Float = 1) {
        self.textureName = textureName; self.blend = blend
        self.refract = refract; self.normalTextureName = normalTextureName; self.refractAmount = refractAmount
        self.foggy = foggy; self.overbright = overbright
    }

    public static func parse(_ json: [String: Any], userProps: [String: Any] = [:]) -> ParticleMaterial {
        guard let passes = json["passes"] as? [Any], let p0 = passes.first as? [String: Any] else {
            return ParticleMaterial(textureName: nil, blend: .translucent)
        }
        let blend: BlendKind = (p0["blending"] as? String) == "additive" ? .additive : .translucent
        let names = (p0["textures"] as? [Any])?.compactMap { $0 as? String } ?? []
        let albedo = names.first(where: { !$0.isEmpty })
        // combos.REFRACT==1 + textures[1] 노멀맵 + constantshadervalues.ui_editor_properties_refract_amount.
        // 콤보 값은 이 파일의 pint 로 읽는다(종전 `as? NSNumber`.intValue 직접 캐스트 — 헬퍼 우회).
        // 파티클 규약은 **문자열 스칼라 거부·언랩 없음**(:1115 헬퍼 주석)이라 pint = strictInt 를 쓴다 —
        // 씬 경로(SceneDocument 의 intVal)처럼 "1" 을 받아주지 않는 것은 이 파일의 의도된 계약이다.
        var refractComboRaw: Any? = nil
        if let combos = p0["combos"] as? [String: Any] { refractComboRaw = combos["REFRACT"] }
        let refract = pint(refractComboRaw) == 1
        let normalName = (names.count > 1 && !names[1].isEmpty) ? names[1] : nil
        var refractAmount = pfloat((p0["constantshadervalues"] as? [String: Any])?["ui_editor_properties_refract_amount"]) ?? 0.05
        // C⑦a: usershadervalues — {JSON 키=user property 키, JSON 값=셰이더 상수 토큰}(SceneDocument
        // 이미지 레이어 경로와 동일 방향 정정). 파스 시점에 userProps 룩업(런타임 변경은 정적 해석).
        if let usv = p0["usershadervalues"] as? [String: Any] {
            for (userKey, v) in usv {
                guard let token = v as? String, token == "ui_editor_properties_refract_amount" else { continue }
                if let raw = userProps[userKey], let f = pfloat(raw) { refractAmount = f }
            }
        }
        // M(④): FOG 콤보 기본 1(WE 선언) — 명시 0 만 제외. 메시 경로(SceneRenderer3D:608)와 동일하게
        // 키 대소문자 무시(REFRACT 는 기존 정확일치 관례 보존 — 섞지 않음).
        var foggy = true
        if let combos = p0["combos"] as? [String: Any],
           let v = combos.first(where: { $0.key.lowercased() == "fog" })?.value {
            foggy = ((v as? NSNumber)?.intValue ?? 1) != 0
        }
        // C4-(ii): constantshadervalues.ui_editor_properties_overbright(refract_amount 와 동일 파스 패턴).
        // 미명시 시 WE 기본 1.0(무변화 — 60씬 중 값이 다른 씬만 실질 변화).
        let overbright = pfloat((p0["constantshadervalues"] as? [String: Any])?["ui_editor_properties_overbright"]) ?? 1
        return ParticleMaterial(textureName: albedo, blend: blend,
                                refract: refract && normalName != nil, normalTextureName: normalName,
                                refractAmount: refractAmount, foggy: foggy, overbright: overbright)
    }
}

// MARK: - 자식 시스템 링크 (실물 children[] — 107링크 실측)

/// 자식 발화 방식. 실물 type: eventfollow(부모 파티클 추종) / 무type·static(상시, 링크 origin 고정) /
/// eventspawn(부모 스폰 지점 1회) / eventdeath(부모 사망 지점 1회 — rain splash).
public enum ChildTrigger: Equatable { case always, follow, spawnBurst, deathBurst }

public struct ChildLink: Equatable {
    public let def: ParticleSystemDef
    public let trigger: ChildTrigger
    public let maxInstances: Int
    public let probability: Float
    public let origin: Vec3
    public init(def: ParticleSystemDef, trigger: ChildTrigger, maxInstances: Int,
                probability: Float, origin: Vec3) {
        self.def = def; self.trigger = trigger; self.maxInstances = maxInstances
        self.probability = probability; self.origin = origin
    }
}

// MARK: - 인스턴스 오버라이드 (scene object "instanceoverride")

/// 씬 오브젝트의 파티클 인스턴스 모디파이어 — 동일 프리셋 def 를 인스턴스별로 다양화하는 장치
/// (실측 127씬/866건: 눈·불티·버블 재사용). 스칼라는 프리셋 값에 곱하는 **배수**(WE 에디터
/// Count/Rate/Size/… 인스턴스 슬라이더 — 실물 shimmering_particles alpha:10 등 >1 도 유효),
/// controlPoints 는 CP 오프셋 **절대 대체**. 씬 규약 값 언랩({user,value}/문자열)은 SceneDocument 책임.
public struct ParticleInstanceOverride: Equatable {
    public var count: Float? = nil      // maxcount·버스트(instantaneous) 배수
    public var rate: Float? = nil       // 이미터 rate 배수
    public var size: Float? = nil
    public var alpha: Float? = nil
    public var speed: Float? = nil      // 초기 속도(velocityrandom/turbulent) 배수
    public var lifetime: Float? = nil
    /// colorn × brightness × color/255 합성 색 배수(0..1 스페이스, 성분별 곱).
    public var colorMultiplier: Vec3? = nil
    /// controlpointN "x y z" — CP 오프셋 절대 대체(id 0..7).
    public var controlPoints: [Int: Vec3] = [:]
    public init() {}
    public var isEmpty: Bool {
        count == nil && rate == nil && size == nil && alpha == nil && speed == nil
            && lifetime == nil && colorMultiplier == nil && controlPoints.isEmpty
    }
}

// MARK: - 오디오반응 (실측 audioprocessing* — 이미터/이니셜라이저/오퍼레이터 부착, 본 구현은 이미터 rate 스코프)

/// 이미터·오퍼레이터 오디오반응 파라미터(WE audioprocessing*).
///
/// 축약은 **경로마다 다르다.** 셰이더 경로는 구간평균(`pulse.vert` 원문의 `/= (max−min+1)`)이고,
/// CPU 파티클 경로는 구간 **MAX** 다(실물 0x14022a8a0 이 러닝 MAX 를 잡고 나눗셈이 없다 —
/// `AudioResponse.Reduction` 참조). 그 뒤는 같다:
/// smoothstep(bounds) → pow(exponent) → saturate → ×1 = rate 배수(0..1).
/// mode 1..3(L/R/Both평균)만 활성 — 0/부재는 nil(무반응, 기존 rate 유지 → 무음 폴백의 근거).
public struct AudioProcessing: Equatable {
    public let mode: Int
    public let freqStart: Float
    public let freqEnd: Float
    public let bounds: SIMD2<Float>
    public let exponent: Float
    public init(mode: Int, freqStart: Float, freqEnd: Float, bounds: SIMD2<Float>, exponent: Float) {
        self.mode = mode; self.freqStart = freqStart; self.freqEnd = freqEnd
        self.bounds = bounds; self.exponent = exponent
    }

    /// 이미터/오퍼레이터 json 의 audioprocessing* 키 → AudioProcessing. mode 1..3 아니면 nil.
    ///
    /// **[2026-08-20] 기본값을 셰이더 경로에서 유추하지 않는다.** 종전엔 "셰이더 오디오 경로
    /// (SceneRendererResources.audioParams)와 정합" 이라며 freqEnd 15 · exponent 1 을 썼는데,
    /// 파티클 경로는 자체 주입기(0x1401c1e20)를 가지고 값이 다르다. 실측은 아래 각 자리에.
    /// bounds 문자열 `"0.8 1.0"` 의 RVA 는 0x48f3b8 이다 — 종전 `@0x48f3b8` 은 파일 오프셋이고
    /// (+0x1200), "귀속 추정" 표기도 과소였다(태그 4 · len 7 로 확정된다).
    static func parse(_ o: [String: Any]) -> AudioProcessing? {
        guard let mode = strictInt(o["audioprocessingmode"]), mode >= 1, mode <= 3 else { return nil }
        return AudioProcessing(
            mode: mode,
            // 부재 기본값은 전부 주입기 0x1401c1e20 실측이다. 종전엔 freqEnd 15 · exponent 1 로
            // **셰이더 오디오 경로에서 유추**했는데, 파티클 경로는 자체 기본값 집합을 가진다.
            freqStart: strictFloat(o["audioprocessingfrequencystart"]) ?? 0,   // 0x1401c20eb, 값 0
            // **[2026-08-20 정정] 15 가 아니라 1 이다** — `mov r8d, 1` @0x1401c212e → `H_INT`
            // @0x1401c213e. 15 는 23.4Hz–14.7kHz 를 한 덩어리로 뭉개고, 1 은 23.4–187.5Hz
            // 두 밴드만 고른다. 저역 반응이 통째로 달라진다.
            freqEnd: strictFloat(o["audioprocessingfrequencyend"]) ?? 1,
            // 문자열 `"0.8 1.0"`@0x14048f3b8(len 7), 태그 4 — 종전 "귀속 추정" 표기는 과소였다.
            bounds: bounds2(o["audioprocessingbounds"]) ?? SIMD2(0.8, 1.0),
            // **[2026-08-20 정정] 1 이 아니라 2.0 이다** — `movabs rcx, 0x4000000000000000`
            // @0x1401c1f77 → `mov [rax], rcx` @0x1401c1f81 (태그 3 = double).
            exponent: strictFloat(o["audioprocessingexponent"]) ?? 2)
    }
}

/// "min max" 문자열 → SIMD2(앞 두 성분). vec3 파서는 3성분 요구라 2성분 bounds 전용.
private func bounds2(_ v: Any?) -> SIMD2<Float>? {
    guard let s = v as? String else { return nil }
    let parts = s.split(separator: " ").compactMap { Float($0) }
    guard parts.count >= 2 else { return nil }
    return SIMD2(parts[0], parts[1])
}

/// rope/ropetrail 렌더러 확장 키. 파스·모델 노출 전용 — 렌더 소비는 WapleRender 배선 보류.
///
/// **[2026-08-20 전면 정정]** 종전 주석의 스트링 클러스터 `@0x48fbb0–0x48ea18` 은 파일
/// 오프셋이었다(RVA 는 +0x1200 = `0x48fbb0–0x48fc18`; `0x48e9b0` 을 RVA 로 읽으면
/// `"winddirection"` 에 착지한다). 타입·기본값·귀속도 셋 다 틀려 있었다.
///
/// **어느 렌더러가 어느 키를 읽는가** — 각 키 문자열의 lea 참조를 세 핸들러 구간
/// (spritetrail 0x1401cfe16–0x1401cff28 · rope 0x1401cff28–0x1401d00b4 ·
/// ropetrail 0x1401d00b4–0x1401d02d9)으로 갈라 전수 확인했다:
///   · spritetrail = length · maxlength · minlength
///   · rope        = subdivision · uvscale · uvscrolling · **uvsmoothing**
///   · ropetrail   = length · segments · subdivision · uvscale · uvscrolling · **fadealpha · fadesize**
/// 교집합은 uvscale·uvscrolling·subdivision 뿐이다. 종전엔 여섯 키를 두 렌더러에 뭉뚱그려
/// 읽었는데, `uvsmoothing` 은 rope 전용이고 `fade*`/`segments` 는 ropetrail 전용이다.
///
/// **타입** — `fadealpha`/`fadesize`/`uvscrolling`/`uvsmoothing` 은 실수량이 아니라 **불리언
/// 체크박스**다(주입 태그 5, 소비는 비트 세팅). 동봉 자산도 전건 JSON `true`/`false` 리터럴이다
/// (`uvscrolling: true` 8건 · `uvsmoothing: false` 12건 · `fadealpha: true` 4건). Swift 쪽
/// `strictFloat(true)` 가 1.0 을 돌려주는 바람에 "페이드량 1.0" 처럼 보였을 뿐이다.
///
/// **주입 기본값**(부재 시) — rope 주입기 0x1401c0c90 · ropetrail 0x1401c1070:
///   · rope.uvsmoothing = **true**  (태그 5, 값 바이트 1 @0x1401c0dd3) ← 부재 13/25 건이 여기 걸린다
///   · rope.uvscrolling = false     (태그 5, 값 r14b, `xor r14d,r14d` @0x1401c0cc0)
///   · uvscale          = 1         (rope 0x1401c0fd7 / ropetrail `H_INT` r8d=1 @0x1401c13a3)
///   · ropetrail.segments = **4**   (`mov qword [rax], 4` @0x1401c119c, 핸들러 clamp [2,32])
///   · ropetrail.fadealpha/fadesize = false (`H_BOOL` r8d=0 @0x1401c13c5 / 0x1401c13e1)
public struct RopeRenderOptions: Equatable {
    /// ropetrail 전용 · 불리언.
    public var fadeAlpha: Bool = false
    public var fadeSize: Bool = false
    /// rope·ropetrail 공통. 핸들러는 `asFloat` 후 **역수** `1/uvscale` 을 시스템에 싣고,
    /// `uvscale == 0` 이면 아무것도 쓰지 않는다(0x1401d0014 · 0x1401d0285). 여기선 원값을 보존한다.
    public var uvScale: Float = 1
    public var uvScrolling: Bool = false
    /// rope 전용 · 불리언 · **부재 기본 true**.
    public var uvSmoothing: Bool = true
    /// ropetrail 전용.
    public var segments: Int = 4
    public init() {}
}

// MARK: - 주기(periodic) 방출

/// 이미터 주기 방출. RVA 는 전부 실측이다(종전엔 파일 오프셋을 RVA 로 적어 +0x1200 어긋났고,
/// delay 둘은 물음표가 붙은 추정이었다 — `scripts/dev/check-rdata-citations.py` 참조):
/// minperiodicduration @0x48f3c0 · maxperiodicduration @0x48f3d8 · minperiodicdelay @0x48f3f0 ·
/// maxperiodicdelay @0x48f408 · maxtoemitperperiod @0x48f4b8 (0x48f3c0–0x48f4b8 클러스터). [추정] 의미론(WE 에디터 어휘 규약): ON 윈도우(duration 구간 랜덤)
/// 동안 rate/burst 방출(창당 maxtoemitperperiod 상한, 0=무상한) → OFF 딜레이(delay 구간 랜덤) → 반복.
/// rate==0 && burst==0 이면 창 내에 maxtoemitperperiod 를 균등 분배(암시 rate = quota/duration).
/// 키 부재 이미터(nil)는 기존 방출 경로(RNG 드로 순서 포함)와 비트동일.
public struct PeriodicEmission: Equatable {
    public let durationMin: Float   // minperiodicduration
    public let durationMax: Float   // maxperiodicduration (부재 시 0 — 주입 없음)
    public let delayMin: Float      // minperiodicdelay
    public let delayMax: Float      // maxperiodicdelay (부재 시 0 — 주입 없음)
    public let maxPerPeriod: Int    // maxtoemitperperiod (0 = 창 내 상한 없음)
    public init(durationMin: Float, durationMax: Float, delayMin: Float, delayMax: Float, maxPerPeriod: Int) {
        self.durationMin = durationMin; self.durationMax = durationMax
        self.delayMin = delayMin; self.delayMax = delayMax
        self.maxPerPeriod = maxPerPeriod
    }
}

// MARK: - 시스템 정의

public struct ParticleSystemDef: Equatable {
    public let emitters: [Emitter]
    public let initializers: [Initializer]
    public let operators: [ParticleOperator]
    public let renderer: RendererKind
    public let maxCount: Int
    public let startTime: Float
    public let material: ParticleMaterial?
    public let children: [ChildLink]
    /// 컨트롤포인트 오프셋(id 0..7, 시스템 로컬 좌표). mapsequence/트리거류가 참조.
    public var controlPoints: [Vec3] = Array(repeating: Vec3(x: 0, y: 0, z: 0), count: 8)
    /// 이미터별 오디오반응(emitters 와 병렬; nil=무반응). 비어 있으면 전 이미터 무반응(기존 def·테스트 호환).
    public var emitterAudio: [AudioProcessing?] = []
    /// F620: 이미터별 speedmin/speedmax(emitters 와 병렬) — 방출 방향을 따르는 초기속도
    /// (WE 문서: "particle speed in conjunction with a movement Operator"). (0,0)=무속도(기존 동작).
    public var emitterSpeed: [SIMD2<Float>] = []
    /// F627: box 이미터별 distancemin(emitters 와 병렬; sphere 는 nil — 구 distancemin 은 케이스 필드).
    /// nil = ±distanceMax 대칭 레거시. 실물은 distancemin/distancemax 코너 쌍(음수·혼합 부호 유효).
    public var boxDistanceMin: [Vec3?] = []
    /// F624: vortex 오퍼레이터별 오디오반응(def.operators 중 vortex 출현 순 병렬; nil=묵반응).
    /// WE 문서: vortex 오디오반응은 "particle speed 를 오디오에 연결" → 속도 배수.
    public var vortexAudio: [AudioProcessing?] = []
    /// G-C2-03 오퍼레이터별 페이드 창(`operators` 와 1:1 병렬). 비어 있으면 창 없음으로 본다
    /// (직접 조립한 def 의 무회귀 경로). 대상 원소 13종은 `BlendWindow` 주석 참조 —
    /// **대상이 아닌 원소가 키를 적어도 WE 는 무시하므로** 소비 여부는 시뮬레이터가 가른다.
    public var operatorBlends: [BlendWindow] = []
    /// 이미터별 주기 방출(emitters 와 병렬; nil=무주기 — 기존 rate/burst 경로 비트동일).
    /// 병렬 배열 관례(emitterAudio/emitterSpeed/boxDistanceMin 동형) — Emitter 케이스 시그니처 무회귀.
    public var emitterPeriodic: [PeriodicEmission?] = []
    /// F623: 실물 def "flags" 비트(1=worldspace, 4=perspective z-원근).
    ///
    /// [정정 2026-08-01] 종전 주석은 "파스·보존 전용(렌더 소비는 후속)" 이라고 적혀 있었는데
    /// **bit1 은 이미 소비된다** — SceneRenderer3D.swift:2050 `(sys.def.flags & 1)`.
    /// 실제 소비 현황(코퍼스 전수 실측, spec/engine/particle-fields.json):
    ///   bit1 worldspace  — 58씬 저작 · **소비됨**
    ///   bit2 (의미 미상) — 26씬 저작 · 미소비
    ///   bit4 perspective — **70씬 저작 · 미소비** (현재 최대 갭)
    /// bit4 는 번들 프리셋 A/B 가 '깊이 정렬' 이 아니라 '원근 **크기 스케일**' 을 지지한다
    /// (bit4 조는 z 부피에 뿌리면서 sizechange·oscillatesize 를 0/30 으로 안 쓴다 —
    ///  엔진이 z 로 크기를 만들어 준다는 뜻). 다만 **공식은 모른다** — 기준 거리도 1/z 여부도
    /// 미확인이라 그럴듯한 원근식을 지어 넣으면 안 된다(스케일 부재보다 더 눈에 띌 수 있다).
    public var flags: Int = 0
    /// F622: 스프라이트시트 재생 모드/배속. animationMode nil = frametime 기반 기본 재생(기존 폴터).
    public var animationMode: ParticleAnimationMode? = nil
    public var sequenceMultiplier: Float = 1
    /// F626: 렌더러 orientation(기본 screen — 기존 스크린 빌보드 폴터와 동일).
    public var orientation: ParticleOrientation = .screen
    /// F630: mapsequencearoundcontrolpoint "axis"(회전 평면 선택, 기본 z축=XY 평면 레거시).
    public var mapSequenceAxis: Vec3? = nil
    /// rope/ropetrail 렌더러 확장 키(@0x48fbb0–0x48ea18) — 모델 노출 전용(렌더 소비 보류).
    public var ropeOptions: RopeRenderOptions? = nil

    public init(emitters: [Emitter], initializers: [Initializer], operators: [ParticleOperator],
                renderer: RendererKind, maxCount: Int, startTime: Float, material: ParticleMaterial?,
                children: [ChildLink] = []) {
        self.emitters = emitters; self.initializers = initializers; self.operators = operators
        self.renderer = renderer; self.maxCount = maxCount; self.startTime = startTime; self.material = material
        self.children = children
    }

    /// remapvalue 출력 문자열 → 동사. 레거시 "velocity"/"speed" 는 엔진 어휘 setvelocity/multiplyspeed
    /// 계열로 해석해 같은 동사에 매핑(레거시 비트동일 경로는 확장 키 부재 시에만 — 위 파스 분기 참조).
    private static func remapVerb(_ output: String?) -> RemapVerb? {
        switch output {
        case "velocity", "setvelocity": return .setVelocity
        case "speed", "multiplyspeed": return .multiplySpeed
        default: return output.flatMap { RemapVerb(rawValue: $0) }
        }
    }

    /// initializer JSON 배열 → (이니셜라이저 목록, mapSequenceAxis) 조립.
    /// F630: mapsequencearoundcontrolpoint "axis" — 마지막 지정 축이 승.
    private static func parseInitializers(_ jsonArray: [Any]) -> (inits: [Initializer], mapSeqAxis: Vec3?) {
        var inits: [Initializer] = []
        var mapSeqAxis: Vec3? = nil   // F630: mapsequencearoundcontrolpoint "axis"
        for case let i as [String: Any] in jsonArray {
            switch i["name"] as? String {
            case "lifetimerandom":
            // [2026-08-20] **부재 기본값은 중립값이 아니라 원본 주입기 상수다.** WE 는 원소 팩토리
            // 직전에 기본값 주입기를 돌린다 — `if (!json.find(k)) json[k] = C;` 꼴이고, 상수 C 는
            // 코드에만 있어서 자산 통계로는 절대 복원되지 않는다. 아래 값은 전부 그 주입기를
            // 디스어셈블해 읽은 것이다(주입기 = `Json::Value::find`(0x140087490) 호출 뒤
            // `test rax,rax` / `jne`(키 있으면 건너뜀) 패턴).
            // lifetimerandom 주입기 0x1401b9c40: max 만 1.0(0x1401b9d12) 을 심고 min 은 상수를
            // 심지 않는다 = **0**. 실물 도달 0건이지만 기록을 맞춘다.
                inits.append(.lifetimeRandom(min: injected(i, "min", 0), max: injected(i, "max", 1),
                                             exponent: pexponent(i["exponent"]) ?? 1))
            case "sizerandom":
                // 주입기 0x1401b9e70(게이트 `stricmp` "sizerandom"). 둘 다 ortho/원근 조건부다:
                //   min: `test dl,dl` → ortho **5.0**(0x140492858) / 원근 0.001(0x140492608) @0x1401b9e96
                //   max: `test sil,sil` → ortho **50.0**(0x1404928cc) / 원근 1.0(0x140492704) @0x1401b9f6a
                // 종전 1/1 은 "중립값" 추정이었다 — 어느 분기에도 없는 값이다. 동봉 287 인스턴스가
                // 전건 min·max 를 명시하므로 관측 회귀는 0이고, 키를 뺀 씬에서만 갈린다.
                inits.append(.sizeRandom(min: injected(i, "min", 5), max: injected(i, "max", 50),
                                         exponent: pexponent(i["exponent"]) ?? 1))
            case "colorrandom":
            // colorrandom 주입기 0x1401ba110: min = "0 0 0"(0x1401ba16e), max = "255 255 255"
            // (0x1401ba264), exponent = 1.0(0x1401ba332). 종전 min 기본값 (255,255,255)는
            // "중립값" 추정이었다. 실물 도달 0건(258건 전건 min 명시)이라 동작 변화는 없다.
                inits.append(.colorRandom(min: injectedVec3(i, "min", Vec3(x: 0, y: 0, z: 0)),
                                          max: injectedVec3(i, "max", Vec3(x: 255, y: 255, z: 255)),
                                          exponent: pexponent(i["exponent"]) ?? 1))
            case "alpharandom":
                // **[2026-08-20 정정] 추론이 아니라 실측이다.** 아래 옛 주석은 "같은 스위치의 관례상
                // 부재 기본값은 중립값" 이라는 유추로 min 을 1 로 놓았는데, 원본 주입기
                // 0x1401baa10 이 min = **0.05**(0x1401baa70) · max = 1.0(0x1401baaec) 를 심는다.
                // 즉 WE 의 중립은 불투명(1)이 아니라 거의 투명(0.05)이다.
                //
                // 옛 주석이 든 반증은 여전히 유효하되 결론이 달라진다: `wind-blur.json {"min":0.8}`
                // 은 min 이 명시돼 있어 영향 없고, min/max 둘 다 부재인 것은 동봉 `alpharandom`(all 53 · unique 35) 중 **1건**뿐이다.
                // 그 1건이 [0.05,1] 로 바뀐다 — [1,1] 고정보다 원본에 맞다.
                // (032b66d 의 ??0 은 여전히 틀렸다. 0.05 는 0 이 아니다.)
                inits.append(.alphaRandom(min: injected(i, "min", 0.05), max: injected(i, "max", 1),
                                          exponent: pexponent(i["exponent"]) ?? 1))
            case "velocityrandom":
                // 주입기 0x1401bac50(게이트 `stricmp` "velocityrandom"). 둘 다 문자열 주입이고
                // ortho/원근 조건부다(`test bl,bl` → `cmovne`):
                //   min: ortho **"-32 -32 0"**(0x14048f660) / 원근 "-1 -1 -1"(0x14048f670) @0x1401bac6d
                //   max: ortho **"32 32 0"**(0x14048f680) / 원근 "1 1 1"(0x14048f4ec)   @0x1401bac93
                // 종전 (0,0,0)/(0,0,0) 은 어느 분기에도 없는 값이라 "속도 없음" 을 만들었다.
                // 동봉 120 인스턴스가 전건 min·max 를 명시하므로 관측 회귀는 0이다.
                inits.append(.velocityRandom(min: injectedVec3(i, "min", Vec3(x: -32, y: -32, z: 0)),
                                             max: injectedVec3(i, "max", Vec3(x: 32, y: 32, z: 0)),
                                             exponent: pexponent(i["exponent"]) ?? 1))
            case "rotationrandom":
                inits.append(.rotationRandom(min: pvec3(i["min"]) ?? Vec3(x: 0, y: 0, z: 0),
                                             // 부재 기본 max (0,0,2π) — **키 귀속 확정**(2026-08-20).
                                             // 주입기 0x1401bb390 이 min="0 0 0"(0x1401bb3ee),
                                             // max="0 0 6.28318530717"(0x1401bb4c0) 를 심는다.
                                             // 종전 "인접 추정" 은 이제 실측이다.
                                             max: pvec3(i["max"]) ?? Vec3(x: 0, y: 0, z: 6.28318530717),
                                             exponent: pexponent(i["exponent"]) ?? 1))
            case "angularvelocityrandom":
            // 주입기 0x1401bb9c0: min = "0 0 -5"(0x1401bba1e, 길이 6) · max = "0 0 5"(0x1401bbafe,
            // 길이 5) · exponent = 1.0(0x1401bbbe0). 종전 (0,0,0)/(0,0,0)은 **회전이 아예 없다**.
            // 동봉 `angularvelocityrandom`(all 46 · unique 26) 중 min·max 를 둘 다 생략한 것이
            // **all 8 · unique 4** — 그것들이 안 돌고 있었다.
                inits.append(.angularVelocityRandom(min: injectedVec3(i, "min", Vec3(x: 0, y: 0, z: -5)),
                                                    max: injectedVec3(i, "max", Vec3(x: 0, y: 0, z: 5)),
                                                    exponent: pexponent(i["exponent"]) ?? 1))
            case "turbulentvelocityrandom":
                // 주입기 **0x1401bb030** — 귀속 사슬: `stricmp`@0x1401c874f 'turbulentvelocityrandom'
                // → 호출부 0x1401c8782. (주의: 바로 앞 0x1401bad80 은 'inheritcontrolpointvelocity'
                // 의 주입기다. `.pdata` 조각이 연속이라 두 함수를 하나로 병합하면 이 셋이 통째로
                // 엉뚱한 원소에 붙는다 — 0x1401bad80 은 0x1401bb00c 에서 `ret` 하고 0x1401bb030 이
                // 새 프롤로그다. 함수 경계는 xref 가 있는 조각 시작으로 잡아야 한다.)
                //
                // speedmin/speedmax 는 **직교투영 플래그 의존**(아래 `injected` 주석 참조):
                // ortho 100/250(0x1401bb056·0x1401bb12a), 원근 0.5/1.0(0x1401bb060·0x1401bb134).
                // 어느 분기든 0 이 아니다 — 종전 0 은 난류 초기속도를 통째로 껐다.
                inits.append(.turbulentVelocityRandom(speedMin: injected(i, "speedmin", 100),   // 0x1401bb07b
                                                      speedMax: injected(i, "speedmax", 250),  // 0x1401bb14d
                                                      scale: injected(i, "scale", 1),          // 0x1401bb338 (플래그 무관)
                                                      offset: injected(i, "offset", 0)))       // 0x1401bb34a (플래그 무관)
            case "colorlist":
                // 실물: colors = ["r g b", ...] 0..1 스케일(colorrandom 의 0..255 와 다름 — 실측).
                let colors = (i["colors"] as? [Any] ?? []).compactMap { pvec3($0) }
                if !colors.isEmpty { inits.append(.colorList(colors: colors)) }
            case "hsvcolorrandom":
                // **[2026-08-20 정정] "데모 예제 = 기본값" 추정은 6필드 중 4필드가 틀렸다.**
                // 주입기 0x1401ba3e0 — 귀속 사슬: `stricmp`(0x1402c10d0) 호출 @0x1401c783a 가
                // 'hsvcolorrandom' 과 비교 → 같으면 0x1401c786d 에서 이 함수를 부른다. 두 번째 호출부
                // 0x1401c4b31 은 `memcmp`(0x140420ff0) 호출 @0x1401c4b20 으로 **같은 문자열**을
                // 비교하는 다른 디스패처라, 두 경로 모두 같은 원소를 가리킨다(귀속 단일).
                //
                // WE 의 중립은 "채도·명도 고정 1" 이 아니라 **0.5 에서 1 까지 무작위**다. 그리고
                // max 는 min 을 **승계하지 않는다** — 둘 다 독립 상수다. saturationmin 만 준
                // 자산(magic_color_sparkle 류)은 종전 [min,min] 고정이었지만 원본은 [min,1] 이다.
                let hueMin = injected(i, "huemin", 0)            // 0x1401ba408 (레지스터 0)
                let hueMax = injected(i, "huemax", 1)            // 0x1401ba4b7
                let satMin = injected(i, "saturationmin", 0.5)   // 0x1401ba669 → movsd @0x140492758
                let satMax = injected(i, "saturationmax", 1)     // 0x1401ba6d9 (승계 아님 — 상수)
                let valMin = injected(i, "valuemin", 0.5)        // 0x1401ba6f0
                let valMax = injected(i, "valuemax", 1)          // 0x1401ba716 (승계 아님 — 상수)
                inits.append(.hsvColorRandom(hueMin: hueMin, hueMax: hueMax,
                                             satMin: satMin, satMax: satMax,
                                             valMin: valMin, valMax: valMax,
                                             // huesteps 부재 기본은 0(연속)이 아니라 **6**(0x1401ba56d,
                                             // 인라인 tag=int) — 6단 색상환 양자화다.
                                             hueSteps: max(0, injectedInt(i, "huesteps", 6)),
                                             hueNoise: pfloat(i["huenoise"]) ?? 0,
                                             satNoise: pfloat(i["saturationnoise"]) ?? 0,
                                             valNoise: pfloat(i["valuenoise"]) ?? 0))
            case "mapsequencearoundcontrolpoint":
                // count 부재 기본은 0(= 시퀀스 없음)이 아니라 **32**(주입기 0x1401bbc90, 인라인
                // tag=int @0x1401bbcaf). 게이트: `stricmp`@0x1401c993a → 호출부 0x1401c9970.
                inits.append(.mapSequence(count: injected(i, "count", 32),
                                          mirror: (i["limitbehavior"] as? String) == "mirror", between: false))
                // F630: "0 1 0" 같은 회전축 — 각도 평면 선택(기본 z축 레거시, 마지막 지정 승).
                mapSeqAxis = pvec3(i["axis"]) ?? mapSeqAxis
            case "mapsequencebetweencontrolpoints":
                // count 부재 기본 **32**(주입기 0x1401bc080, 인라인 tag=int @0x1401bc09f).
                // 게이트: `stricmp`@0x1401ca1e1 → 호출부 0x1401ca214.
                inits.append(.mapSequence(count: injected(i, "count", 32),
                                          mirror: (i["limitbehavior"] as? String) == "mirror", between: true))
            case "positionoffsetrandom":
                inits.append(.positionOffsetRandom(offsetMin: pvec3(i["offsetmin"]) ?? Vec3(x: 0, y: 0, z: 0),
                                                   offsetMax: pvec3(i["offsetmax"]) ?? Vec3(x: 0, y: 0, z: 0)))
            case "inheritcontrolpointvelocity":
                // 이벤트 시스템 연동 보류 — 파스·보존까지만(시뮬 무시).
                inits.append(.inheritControlPointVelocity(
                    controlPoint: pint(i["controlpoint"]) ?? 0,
                    min: injected(i, "min", 0.1),      // 0x1401bade5 (플래그 무관)
                    max: injected(i, "max", 0.2)))     // 0x1401baea3 (플래그 무관)
            case "inheritinitialvaluefromevent", "inheritvaluefromevent":
                // 이벤트 시스템 연동 보류 — 파스·보존까지만(시뮬 무시).
                inits.append(.inheritValueFromEvent(name: i["name"] as? String ?? "",
                                                    valueName: i["value"] as? String))
            case "remapinitialvalue":
                // 이벤트 시스템 연동 보류 — 파스·보존까지만(시뮬 무시).
                inits.append(.remapInitialValue(output: i["output"] as? String,
                                                min: pvec3OrScalar(i["min"]),
                                                max: pvec3OrScalar(i["max"])))
            case let other:
                WapleLog.warn("[Waple] SP4 unsupported initializer dropped: \(other ?? "nil")")
            }
        }
        return (inits, mapSeqAxis)
    }

    /// operator JSON 배열 → (파싱된 오퍼레이터, attract CP 인덱스 쌍, vortex 오디오반응) 조립.
    /// controlpointattract 의 CP id 는 controlpoint 배열이 오퍼레이터보다 뒤에 파스되므로
    /// (ops 인덱스, cpid) 만 보관했다가 def 조립 직전에 target 재조립(감사 V04).
    /// 컨트롤포인트 인덱스 클램프. WE 는 세 원소에서 **같은 규약**을 쓴다 —
    /// `ebx = 7; cmp eax, ebx; cmovb ebx, eax` (vortex 0x1401cdc11–0x1401cdc1c ·
    /// vortex_v2 0x1401ce1b1–0x1401ce1c2) 또는 `cmp eax,7 / jae → mov eax,7`
    /// (controlpointattract 0x1401ccc65 → 0x1401ccd01 · maintaindistancetocontrolpoint
    /// 0x1401cce37·0x1401cce9c). 비교가 **부호 없는** `cmovb`/`jae` 라서 음수도 7 로 간다 —
    /// `min(max(cp,0),7)` 로 두면 음수가 0 이 되어 갈린다.
    /// **도수 인용 규약.** 아래 주석들이 "동봉 N건" 을 인용할 때는 반드시 범위를 밝힌다 —
    /// `all`(파일 전수, 프리뷰 사본 포함) 또는 `unique`(파일 내용 sha256 중복 제거).
    /// 동봉 트리에는 프리셋 원본과 **바이트 동일한 프리뷰 사본**이 섞여 있어 그냥 세면 거의
    /// 두 배가 된다. 범위 없이 쓴 숫자들이 실제로 서로 어긋났다(`controlpointattract` 를
    /// "35인스턴스" 라고 적었는데 all 34 · unique 29 로 **어느 쪽도 아니었다**).
    /// 정본은 `spec/assets/particle-corpus.json`(생성기 `measure_particle_corpus.py`)이고
    /// `check_particle_corpus_census.py` 가 자산과의 일치를 CI 에서 강제한다.
    private static func clampControlPoint(_ cp: Int) -> Int {
        (cp < 0 || cp >= 7) ? 7 : cp
    }

    private static func parseOperators(_ jsonArray: [Any]) -> (ops: [ParticleOperator],
                                                               attractCPIds: [(op: Int, cp: Int)],
                                                               vortexAudio: [AudioProcessing?],
                                                               blends: [BlendWindow]) {
        var ops: [ParticleOperator] = []
        var attractCPIds: [(op: Int, cp: Int)] = []
        // F624: vortex 출현 순 병렬 오디오반응(WE: vortex 오디오반응 = particle speed 를 오디오에 연결).
        var vortexAudio: [AudioProcessing?] = []
        // G-C2-03 페이드 창은 **오퍼레이터마다 enum 연관값을 늘리는 대신 병렬 테이블**로 둔다.
        // 대상이 13종인데(BlendWindow 주석) 그만큼 case 를 바꾸면 소비처가 전부 어긋나고,
        // 창의 산술은 원소와 무관하게 동일하다 — 자리를 하나만 두는 편이 옳다.
        // 인덱스는 `ops` 와 1:1 이다(원소 하나가 ops 를 0개 또는 1개 추가하므로 아래 while 로 맞춘다).
        var blends: [BlendWindow] = []
        for case let o as [String: Any] in jsonArray {
            defer {
                // WE 는 이 네 키를 **공용 파서 하나**(0x1401c2a40)에서만 읽는다. 대상이 아닌 원소가
                // 키를 적어 놓아도(동봉에 실제로 있다) 무시되므로, 소비 여부는 시뮬레이터가 가른다.
                let w = BlendWindow(inStart: pfloat(o["blendinstart"]) ?? 0,
                                    inEnd: pfloat(o["blendinend"]) ?? 0,
                                    outStart: pfloat(o["blendoutstart"]) ?? 1,
                                    outEnd: pfloat(o["blendoutend"]) ?? 1)
                while blends.count < ops.count { blends.append(w) }
            }
            switch o["name"] as? String {
            case "movement":
                ops.append(.movement(gravity: pvec3(o["gravity"]) ?? Vec3(x: 0, y: 0, z: 0), drag: pfloat(o["drag"]) ?? 0))
            case "alphafade":
                // **[2026-08-20] 부재 기본값은 0 이 아니라 0.5 다.** 원본 주입기 0x1401bce50 이
                // `fadeintime`(0x1401bce63) · `fadeouttime`(0x1401bcf23) 둘 다에
                // `movabs rbp, 0x3fe0000000000000`(= 0.5, 0x1401bce71) 을 심는다 — `Json::Value::find`
                // (0x140087490) 가 null 을 낼 때만이다.
                //
                // 상수 확인(재검증 2026-08-20): `movabs rbp, 0x3fe0000000000000`(0x1401bce71)
                // = f64 **0.5** 하나를 `fadeintime`·`fadeouttime` **양쪽에 재사용**한다.
                // 각 키 앞의 `find` → `test rax,rax` → `jne` 가 키가 있으면 주입을 건너뛴다.
                //
                // 이게 이번 라운드에서 도달이 가장 큰 자리다. **[2026-08-20 범위 명시]** 종전
                // "177건 중 97건" 은 범위 표기가 없었다 — 동봉 트리를 **내용 해시로 중복 제거**한
                // 값이다(프리뷰 사본이 원본과 바이트 동일이라 그렇게 세지 않으면 두 배로 뛴다).
                // 실측을 다시 하면:
                //   · 동봉 트리 전체(사본 포함)   250건 — fadeouttime 부재 138 · fadeintime 부재 29
                //   · 내용 해시 중복 제거          178건 — fadeouttime 부재  94 · fadeintime 부재 20
                // 어느 범위로 보든 **fadeouttime 부재가 절반을 넘는다**는 것이 요지다.
                //
                // fadeOut 0 은 `fadeFactor` 에서 페이드를 통째로 끄므로, 그 인스턴스들은 수명
                // 끝에 **팝** 하고 사라졌다 — WE 는 수명의 마지막 50% 에 걸쳐 서서히 사라진다.
                ops.append(.alphaFade(fadeInTime: injected(o, "fadeintime", 0.5),
                                      fadeOutTime: injected(o, "fadeouttime", 0.5)))
            case "sizechange":
                ops.append(.sizeChange(startTime: pfloat(o["starttime"]) ?? 0,
                                       startValue: pfloat(o["startvalue"]) ?? 1,
                                       endValue: pfloat(o["endvalue"]) ?? 0,
                                       endTime: pfloat(o["endtime"]) ?? 1))
            case "colorchange":
                ops.append(.colorChange(startTime: pfloat(o["starttime"]) ?? 0,
                                        startValue: pvec3(o["startvalue"]) ?? Vec3(x: 1, y: 1, z: 1),
                                        endValue: pvec3(o["endvalue"]) ?? Vec3(x: 0, y: 0, z: 0),
                                        endTime: pfloat(o["endtime"]) ?? 1))
            case "angularmovement":
                // F188: drag 파싱 — movement(위 497-498행)의 선형 drag 와 대칭(부재 시 0, 무회귀).
                ops.append(.angularMovement(force: pvec3(o["force"]) ?? Vec3(x: 0, y: 0, z: 0),
                                            drag: pfloat(o["drag"]) ?? 0))
            case "oscillatealpha":
                // fmax 부재 시 fmin 승계(scaleMax 와 동일 패턴) — 역범위 rng.range(fmin, 0) 방지(감사 V03).
                // scalemax 기본은 scalemin 승계가 아니라 1 고정(비퇴화, F189/F190) — 자매 oscillatesize 는
                // scale 생략 시 상수(무진동)가 정답이지만, alpha 는 scale 생략 인스턴스(데모·
                // magic_color_sparkle 등)도 트윙클을 내야 한다(실측: smax 가 smin 을 승계하면 scale
                // 전체 생략은 진폭 0, scalemin 단독 지정은 진폭이 상수로 죽는다 — WE 데모는 frequency 만
                // 지정하고도 가시 진동을 낸다).
                // **[2026-08-20] 주파수 기본값은 승계가 아니라 고정 상수다.** 주입기 0x1401bd910 이
                // frequencymin = 1.0(0x1401bd979) · frequencymax = **10.0**(0x1401bda2f) ·
                // scalemax = 1.0(0x1401bdb85, `movsd` @0x140492778) 을 심는다. 즉 fmax 는 fmin 을
                // 승계하지 않는다 — 위 "역범위 방지" 주석의 승계는 이제 불필요하다(둘 다 상수라
                // 역범위가 생기지 않는다). frequency 0 은 sin 을 상수로 만들어 연산자를 무력화하므로
                // 동봉 `oscillatealpha`(all 36 · unique 24) 중 frequencymin 부재 all 6·unique 3,
                // frequencymax 부재 all 4·unique 2 가 죽어 있었다.
                let smin = pfloat(o["scalemin"]) ?? 0
                let fmin = injected(o, "frequencymin", 1)
                ops.append(.oscillateAlpha(frequencyMin: fmin, frequencyMax: injected(o, "frequencymax", 10),
                                           scaleMin: smin, scaleMax: injected(o, "scalemax", 1),
                                           phaseMin: injected(o, "phasemin", 0), phaseMax: injected(o, "phasemax", 2 * .pi)))
            case "oscillateposition":
                // 주입기 0x1401bd5d0: frequencymin = 1.0(0x1401bd716) · frequencymax = **5.0**
                // (0x1401bd7cc). 자매 alpha/size 는 10.0 인데 **여기만 5.0** 이다 — 승계였다면
                // 절대 나오지 않을 값이라, 이 하나가 "고정 상수" 해석의 반증 가능한 증거다.
                let smin = pfloat(o["scalemin"]) ?? 0
                let fmin = injected(o, "frequencymin", 1)
                // **[2026-08-20 정정] 조건의 출처를 박았다 — 실측 동작은 0.5 가 아니라 10.0 이다.**
                // 종전 주석은 "파티클 시스템 최상위 JSON `flags` 에 bit10 이 없다" 로 0.5 를 골랐는데,
                // 그 bit10 은 JSON `flags` 가 아니라 **C++ 오브젝트 플래그**다(아래 `injected` 주석).
                // 동봉 두 트리 scene.json 355개 중 347개(97.7%)가 세운다.
                ops.append(.oscillatePosition(frequencyMin: fmin, frequencyMax: injected(o, "frequencymax", 5),
                                              scaleMin: smin, scaleMax: injected(o, "scalemax", 10),   // 0x1401bd8b5 (원근 0.5)
                                              phaseMin: injected(o, "phasemin", 0), phaseMax: injected(o, "phasemax", 2 * .pi),
                                              mask: injectedVec3(o, "mask", Vec3(x: 1, y: 1, z: 0))))
            case "controlpointattract":
                // **[2026-08-20] 대상은 항상 컨트롤포인트다.** 런타임 핸들러(0x14024172d)는
                // `[r14+0xb4]`(cp 인덱스)로 `[sys+0x400]` 배열에서 CP 를 꺼내 그 위치만 쓴다
                // (0x140241769–0x140241794 복사·splat → 0x140241856 이후 `subps`).
                // `offset`(레코드 +0x10)은 **위치로 전혀 쓰이지 않는다** — 전 핸들러에서 참조가
                // `lea r8, [r14+0x10]`(0x14024194e) 한 곳뿐이고, 그건 삭제 함수에 넘기는 베이스
                // 포인터로 그쪽은 `[r8+0x50]`(= deletethreshold²)만 읽는다.
                //
                // 그래서 (a) `controlpoint` 부재 시에도 **CP0 을 바인딩**하고(주입 기본 0),
                // (b) `offset` 을 target 으로 쓰지 않는다. 동봉 `controlpointattract`(all 34 · unique 29) 중 cp 미지정 all 9·unique 8 은
                // 전건 CP0 이 원점이라 관측은 안 바뀌지만, CP 를 옮긴 씬에서 갈린다.
                //
                // 클램프는 **부호 없는** `cmp eax,7 / jae → mov eax,7`(0x1401ccc65 → 0x1401ccd01)
                // 이라 음수도 7 로 간다. `cpid < 8` 로 통과시키던 종전 규약과 다르다.
                attractCPIds.append((op: ops.count, cp: clampControlPoint(pint(o["controlpoint"]) ?? 0)))
                ops.append(.controlPointAttract(
                    scale: injected(o, "scale", 512),          // 0x140492934 (원근 20.0 @0x14049288c)
                    threshold: injected(o, "threshold", 512),  // 0x140492934 (원근 5.0 @0x140492858)
                    // 위 주석 참조 — 아래 CP 재베이크가 항상 덮어쓴다. `offset` 은 런타임에서
                    // 위치로 쓰이지 않으므로 여기서도 읽지 않는다.
                    target: Vec3(x: 0, y: 0, z: 0),
                    deleteThreshold: (pint(o["deletethreshold"]) ?? 0) != 0,
                    flags: pint(o["flags"]) ?? 2))   // 0x1401be245 — 주입 기본 2
            case "boids":
                ops.append(.boids(
                    separationThreshold: injected(o, "separationthreshold", 20),  // 0x1401bf726 (원근 0.02)
                    neighborThreshold: injected(o, "neighborthreshold", 50),      // 0x1401bf7f5 (원근 0.2)
                    maxSpeed: injected(o, "maxspeed", 500),                       // 0x1401bf8c4 (원근 1.0)
                    separationFactor: injected(o, "separationfactor", 15),        // f64 @0x140492818, 플래그 무관
                    alignmentFactor: injected(o, "alignmentfactor", 1),           // 0x1401bf9fd
                    cohesionFactor: injected(o, "cohesionfactor", 2),             // 0x1401bfa14
                    flags: pint(o["flags"]) ?? 1))                                // 0x1401bfa69 — 기본 1
            case "maintaindistancetocontrolpoint":
                // WE 는 `controlpoint` 부재 시 0 을 심는다(int 헬퍼 @0x1401be1fd 계열) — 실사용
                // 인스턴스(magic_vortex_orb)가 정확히 그 경우다. 이 원소는 지금까지 통째로
                // 드롭돼 있었으므로 CP0 바인딩에 회귀 위험이 없다.
                attractCPIds.append((op: ops.count, cp: clampControlPoint(pint(o["controlpoint"]) ?? 0)))
                ops.append(.maintainDistanceToControlPoint(
                    distance: injected(o, "distance", 200),          // 0x1401be2bc (원근 1.0 @0x1401be2c6)
                    variableStrength: injected(o, "variablestrength", 0),  // 0x1401be4d9, 플래그 무관
                    target: Vec3(x: 0, y: 0, z: 0)))                 // 아래 CP 재베이크에서 채운다
            case "vortex":
                // 중심은 `offset` 이 아니라 **CP 위치 + offset** 이다(실측 0x1402431be–0x14024322c:
                // `[r14+0xc0]` = cp 인덱스 → stride 0xd0 배열 `[sys+0x400]` → translation 을 splat 한 뒤
                // `addps` 로 offset 세 성분을 더한다). 아래 CP 재베이크에서 합쳐 굽는다 —
                // 동봉 `vortex`(all 9 · unique 7)는 전건 CP0 = 원점이라 관측은 안 바뀌지만, CP 를 옮긴 씬에서 갈린다.
                attractCPIds.append((op: ops.count, cp: clampControlPoint(pint(o["controlpoint"]) ?? 0)))
                // 주입기 0x1401bef00 .. 0x1401bf2c6 (`.pdata` 3조각 — 언와인드 체인으로 병합해야
                // 한다. 조각 하나만 읽으면 `speedinner` 의 상수가 **3번째 조각 첫 명령**
                // 0x1401bf22e 라 통째로 안 보인다). 게이트 `stricmp`@0x1401cd8a9 → "vortex",
                // 주입기 호출 @0x1401cd8e1.
                //
                // 종전 `?? 0` 은 소용돌이를 **아예 안 돌게** 만들었다: dOut(0) > dIn(0) 이 거짓 →
                // 보간 t = 0 → speed = sIn = 0 → 접선 가속이 0 이다. 실코퍼스 9건 중
                // distance* 부재 2건 · speedinner 부재 1건이 그 상태였다.
                ops.append(.vortex(axis: pvec3(o["axis"]) ?? Vec3(x: 0, y: 0, z: 1),   // "0 0 1", 플래그 무관
                                   // 아래 셋만 ortho/원근 조건부다(`test sil` → 0x14010daa0 이 읽는
                                   // `[scene+0x118]` bit10 = general.orthogonalprojection).
                                   distanceInner: injected(o, "distanceinner", 500),   // 0x1401bf0e3 (원근 1.0)
                                   distanceOuter: injected(o, "distanceouter", 650),   // 0x1401bf1ad (원근 2.0)
                                   speedInner: injected(o, "speedinner", 2500),        // 0x1401bf22e (원근 1.0)
                                   speedOuter: injected(o, "speedouter", 0),           // 0x1401bf24f xorps, 플래그 무관
                                   offset: pvec3(o["offset"]) ?? Vec3(x: 0, y: 0, z: 0),  // "0 0 0", 플래그 무관
                                   // `centerforce` 는 v1 의 키가 **아니다** — "centerforce"@0x14048f9f8
                                   // 를 집는 lea 가 전 바이너리에 2곳뿐이고 둘 다 v2 다(주입기
                                   // 0x1401bf5f5 ∈ 0x1401bf2d0, ctor 0x1401ce07a ∈ vortex_v2 구간).
                                   // 종전엔 주석으로 그렇게 적어 놓고 코드는 키를 **읽었다** —
                                   // `{"name":"vortex","centerforce":5}` 면 WE 는 무시하는데 Waple 은
                                   // 반경 감쇠를 걸었다. 상수 0 으로 못박는다.
                                   centerForce: 0,
                                   flags: pint(o["flags"]) ?? 0))
                vortexAudio.append(AudioProcessing.parse(o))
            case "vortex_v2":
                // v2 의 중심은 **CP 위치 그대로**다 — v1 과 달리 offset 을 더하지 않는다
                // (프리앰블에 `addps [r14+0x10..0x30]` 이 없다). v2 는 offset 키 자체를 읽지 않아
                // 파스가 (0,0,0) 을 넣으므로, 아래 재베이크의 "CP + offset" 이 자동으로 CP 가 된다.
                attractCPIds.append((op: ops.count, cp: clampControlPoint(pint(o["controlpoint"]) ?? 0)))
                // 주입기 0x1401bf2d0 .. 0x1401bf6f8 (`.pdata` 3조각). **진입점 주의**: `centerforce`
                // 주입 호출부 0x1401bf5ff 이 속한 조각의 시작(0x1401bf3c8)은 진입점이 아니다 —
                // 그 조각만 읽으면 수치 주입 12개 중 11개를 놓친다. 게이트 `stricmp`@0x1401cde40.
                //
                // [2026-08-20 정정] 종전 주석의 "speedouter 부재 = speedinner 승계" 는 틀렸다.
                // 주입기는 0x1401bf5e0 에서 `xorps xmm2,xmm2` 로 **0.0** 을 심고 플래그와도
                // 무관하다(자매 vortex 의 0x1401bf24f 도 동일). 승계 규칙은 WE 에 없다.
                //
                // [2026-08-20 정정] `offset` 은 vortex_v2 에 **없다**. "offset" 문자열을 lea 로
                // 집는 곳이 전 바이너리에 10군데인데, vortex_v2 주입기 구간과 그 핸들러
                // (0x1401cde7e..0x1401ce3f0) 안에는 하나도 없다 — 자매 `vortex` 쪽
                // (0x1401bef1a·0x1401bef69, 핸들러 0x1401cd8e6)에만 있다. JSON 에 적어도 WE 는
                // 무시하므로 여기서도 무시한다(실코퍼스 5건 전부 부재라 관측 무영향).
                //
                // **[2026-08-20 재정정 — 주입과 소비는 다르다]** ring 4키는 주입기에서 무조건
                // 주입되지만(0x1401bf632 의 `test sil,sil` 은 "어떤 값이냐"만 가른다), **소비는
                // `flags & 4` 게이트를 지나야 한다**: 런타임이 `test byte [r14+0x110], 4`
                // (0x1402434eb) 로 보고 비면 `je 0x1402437f8`(0x14024356f)로 **비-ring 루프**로
                // 간다. 즉 주입 상수는 JSON 에 실리지만 힘으로는 쓰이지 않는다.
                //
                // 이 구분을 놓쳐 직전 커밋에서 ring 을 항상 켰다 — 동봉 vortex_v2 5건의 flags 는
                // 3·2·2·2·부재로 **어느 것도 bit2(=4)를 갖지 않으므로 실코퍼스에서 ring 은 한 번도
                // 켜지지 않는다**. `magic_vortex_orb` 는 ring 키를 적어 두고도 flags 가 2라 꺼져 있다.
                //
                // **상수는 실측이지만 링의 힘 수식은 여전히 추정이다** — VortexRing 주석 참조.
                let v2Flags = pint(o["flags"]) ?? 0
                let v2Ring: VortexRing? = (v2Flags & 4) == 0 ? nil : VortexRing(
                    radius: injected(o, "ringradius", 300),             // 0x1401bf637 (원근 1.0)
                    pullDistance: injected(o, "ringpulldistance", 50),  // 0x1401bf644 (원근 0.25)
                    pullForce: injected(o, "ringpullforce", 10),        // 0x1401bf65e (원근 0.05)
                    width: injected(o, "ringwidth", 50))                // xmm6 @0x1401bf6b5 (원근 0.2)
                ops.append(.vortex(axis: pvec3(o["axis"]) ?? Vec3(x: 0, y: 0, z: 1),  // "0 0 1", 플래그 무관
                                   distanceInner: injected(o, "distanceinner", 500),  // 0x1401bf3df (원근 1.0)
                                   distanceOuter: injected(o, "distanceouter", 650),  // 0x1401bf4a4 (원근 2.0)
                                   speedInner: injected(o, "speedinner", 2500),       // 0x1401bf56e (원근 1.0)
                                   speedOuter: injected(o, "speedouter", 0),          // 0x1401bf5e0 xorps, 플래그 무관
                                   offset: Vec3(x: 0, y: 0, z: 0),                    // WE 는 읽지 않는다(위 참조)
                                   // vortex_v2 **만** centerforce 를 심는다(0x1401bf5ff, 플래그 무관 1.0).
                                   // 자매 `vortex`(주입기 0x1401bef00)는 centerforce 문자열조차 없으므로
                                   // 그쪽 `?? 0` 은 옳다 — 두 원소를 같이 고치면 안 된다.
                                   // `flags & 2` 일 때만 읽는다 — 아니면 핸들러가 0x1401ce0b0 에서
                                   // `xorps xmm9,xmm9` 로 0 을 굽는다(`test r14b,2` / `je` @0x1401ce074).
                                   centerForce: (v2Flags & 2) != 0 ? injected(o, "centerforce", 1) : 0,
                                   // `variablestrength`/`reductioninner`/`reductionouter` 는 v2 의 키도
                                   // 아니다. 각 문자열의 lea 를 전수로 보면 전자는 주입기 0x1401be2a0 과
                                   // ctor 0x1401ccf0b(= maintaindistancetocontrolpoint), 후자 둘은 주입기
                                   // 0x1401be810 과 ctor 0x1401cd252/0x1401cd285
                                   // (= reducemovementnearcontrolpoint) 에만 있다. 소용돌이 어느 쪽도
                                   // 읽지 않으므로 "파스·보존" 필드째 들어냈다.
                                   ring: v2Ring, flags: v2Flags))
                vortexAudio.append(AudioProcessing.parse(o))
            case "turbulence":
                // **[2026-08-20 정정] 종전 상수는 추정이었고, 진짜 주입기는 0x1401beb80 이다.**
                // 귀속 사슬: `stricmp`(0x1402c10d0) 호출 @0x1401cd423 이 'turbulence' 와 비교 →
                // 같으면 0x1401cd45c 에서 0x1401beb80 을 부른다. (종전 조사에서 "0x1401bb32x 근처"
                // 로 본 timescale/scale = 1.0/1.0 은 **turbulentvelocityrandom** 것이다 — 위 참조.)
                //
                // scale 0.01 은 우연히 맞았다(ortho 분기). timescale 0 은 **양쪽 분기 어디에도 없다**:
                // ortho 20.0(0x1401bebb1) · 원근 1.0(xmm7 @0x1401beba5). 정적장이 아니라 시간에 따라
                // 흐르는 장이다. mask 도 ortho 는 (1,1,0) — 2D 씬에서 z 를 잠근다.
                ops.append(.turbulence(speedMin: injected(o, "speedmin", 500),      // 0x1401bed85 (원근 1.0)
                                       speedMax: injected(o, "speedmax", 1000),     // 0x1401bee64 (원근 5.0)
                                       scale: injected(o, "scale", 0.01),           // 0x1401becc5 (원근 0.5)
                                       timeScale: injected(o, "timescale", 20),     // 0x1401bebd4 (원근 1.0)
                                       mask: injectedVec3(o, "mask", Vec3(x: 1, y: 1, z: 0)), // 0x1401bec98 (원근 "1 1 1")
                                       phaseMin: injected(o, "phasemin", 0),        // 0x1401beec5 (플래그 무관)
                                       phaseMax: injected(o, "phasemax", 0)))       // 0x1401beeed (플래그 무관)
            case "oscillatesize":
                // 주입기 0x1401bdbf0: frequencymin = 1.0(0x1401bdc59) · frequencymax = 10.0
                // (0x1401bdd0f) · scalemin = **0.8**(0x1401bddc5) · scalemax = **1.2**
                // (0x1401bde6f, `movsd` @0x140492790). 종전 (1, 승계)는 진폭 0(= 무진동)이라
                // 동봉 `oscillatesize`(all 8 · unique 5) 중 scalemin 부재 all 2·unique 1,
                // scalemax 부재 all 2·unique 1 이 죽어
                // 있었다. WE 는 크기를 ±20% 로 맥동시킨다.
                let smin = injected(o, "scalemin", 0.8)
                let fmin = injected(o, "frequencymin", 1)
                ops.append(.oscillateSize(frequencyMin: fmin, frequencyMax: injected(o, "frequencymax", 10),
                                          scaleMin: smin, scaleMax: injected(o, "scalemax", 1.2),
                                          phaseMin: injected(o, "phasemin", 0), phaseMax: injected(o, "phasemax", 2 * .pi)))
            case "alphachange":
                ops.append(.alphaChange(startTime: pfloat(o["starttime"]) ?? 0,
                                        endTime: pfloat(o["endtime"]) ?? 1,
                                        startValue: pfloat(o["startvalue"]) ?? 1,
                                        endValue: pfloat(o["endvalue"]) ?? 0))
            case "remapvalue":
                let fbm = (o["transformfunction"] as? String) == "fbmnoise"
                // 부재 기본 2.0 — 주입기 0x1401bfbb0(게이트 `stricmp`@0x1401ce667 'remapvalue'
                // → 호출부 0x1401ce6a0), 실수 주입기 호출 @0x1401bfff3. 플래그 무관.
                let scale = injected(o, "transforminputscale", 2)
                let outputName = (o["output"] as? String)?.lowercased()
                // 확장 키(엔진 어휘) 존재 여부 — 전부 부재 + 레거시 출력(velocity/speed)이면
                // 기존 .remapValue 경로(시뮬 비트동일 무회귀).
                let extKeys = ["input", "operation", "transformoctaves",
                               "blendinstart", "blendinend", "blendoutstart", "blendoutend",
                               "inputcontrolpoint0", "inputcontrolpoint1",
                               "outputcontrolpoint0", "outputcontrolpoint1", "component"]
                let hasExt = extKeys.contains { o[$0] != nil }
                if !hasExt, outputName == "velocity" {
                    ops.append(.remapValue(output: .velocity(min: pvec3OrScalar(o["outputrangemin"]) ?? Vec3(x: 0, y: 0, z: 0),
                                                             max: pvec3OrScalar(o["outputrangemax"]) ?? Vec3(x: 0, y: 0, z: 0)),
                                           fbm: fbm, inputScale: scale))
                } else if !hasExt, outputName == "speed" {
                    ops.append(.remapValue(output: .speed(min: pfloat(o["outputrangemin"]) ?? 0,
                                                          max: pfloat(o["outputrangemax"]) ?? 1),
                                           fbm: fbm, inputScale: scale))
                } else if let verb = remapVerb(outputName) {
                    let spec = RemapSpec(
                        verb: verb,
                        input: (o["input"] as? String).flatMap { RemapInput(rawValue: $0.lowercased()) },
                        operation: (o["operation"] as? String).flatMap { RemapOperation(rawValue: $0.lowercased()) } ?? .remap,
                        transform: (o["transformfunction"] as? String).flatMap { RemapTransform(rawValue: $0.lowercased()) },
                        octaves: max(1, pint(o["transformoctaves"]) ?? 3),
                        inputScale: scale,
                        outMin: pvec3OrScalar(o["outputrangemin"]) ?? Vec3(x: 0, y: 0, z: 0),
                        outMax: pvec3OrScalar(o["outputrangemax"]) ?? Vec3(x: 1, y: 1, z: 1),
                        blendInStart: pfloat(o["blendinstart"]) ?? 0,
                        blendInEnd: pfloat(o["blendinend"]) ?? 0,
                        // 부재 기본은 0 이 아니라 **1.0** 이다(0x1401c2c26 movabs / 0x1401c2cd3).
                        blendOutStart: pfloat(o["blendoutstart"]) ?? 1,
                        blendOutEnd: pfloat(o["blendoutend"]) ?? 1,
                        inputCP0: pint(o["inputcontrolpoint0"]) ?? 0,
                        inputCP1: pint(o["inputcontrolpoint1"]) ?? 1,
                        outputCP0: pint(o["outputcontrolpoint0"]) ?? 0,
                        outputCP1: pint(o["outputcontrolpoint1"]) ?? 1,
                        component: pcomponent(o["component"]) ?? 0)
                    ops.append(.remapValueEx(spec: spec))
                } else {
                    WapleLog.warn("[Waple] remapvalue unsupported output dropped: \(outputName ?? "nil")")
                }
            case "capvelocity":
                // G-C2-01. 주입기 0x1401bfab0 이 `maxspeed` 부재에 100 을 심는다(2D 경로 상수
                // 0x1404928f8; 월드 단위 경로는 1.0). 동봉 `capvelocity`(all 3 · unique 3)는 전건 maxspeed 명시라
                // 이 기본값이 실제로 도달하진 않지만 기록을 원본에 맞춘다.
                //
                // blendinstart/blendinend(동봉 `capvelocity` 3건 전건 보유)는 **여기서 소비하지 않는다** — 실물은
                // 블렌드 창이 유의미할 때만 opcode 를 0x12→0x26 으로 올려 가중 핸들러
                // (0x140244790)를 타고, 그 가중치는 `w=clamp01((f−inStart)·invIn)·clamp01((outStart−f)·invOut)`
                // (0x14022a530) 로 `s = 1 + w·(s₀−1)` 를 만든다. 오퍼레이터 공통 블렌딩은 G-C2-03 의
                // 몫이라 여기선 무가중(w≡1) 적용이다 — 드롭보다 원본에 가깝고, G-C2-03 이 들어오면
                // 이 자리만 가중치를 곱하면 된다.
                ops.append(.capVelocity(maxSpeed: injected(o, "maxspeed", 100)))
            case "reducemovementnearcontrolpoint":
                // G-C2-01. 동봉 9인스턴스(오퍼레이터 미구현 중 최다)로 도달이 가장 크다.
                // controlpoint 는 주입기 0x1401be834–0x1401be87f 가 **정수 0 을 심으므로**
                // (타입 태그 1=intValue @0x1401be862, 값 0 @0x1401be87f) 키 부재도 CP0 바인딩이다.
                // 실제로 thunderbolt.json 은 CP 무명시(→CP0)와 controlpoint:1 을 한 쌍으로 쓴다.
                // **[2026-08-20]** 종전 주석의 "controlpointattract 의 '키 있을 때만' 규약과
                // 다르다" 는 이제 사실이 아니다 — 그쪽도 항상 CP 를 바인딩하도록 고쳤다.
                // 클램프도 `clampControlPoint` 로 통일한다(0x1401cd2ec·0x1401cd351 의 `cmp eax,7`
                // 은 부호 없는 비교라 음수도 7 이다 — `min(max(0,cp),7)` 은 0 으로 보냈다).
                attractCPIds.append((op: ops.count, cp: clampControlPoint(pint(o["controlpoint"]) ?? 0)))
                ops.append(.reduceMovementNearControlPoint(
                    distanceInner: injected(o, "distanceinner", 100),
                    distanceOuter: injected(o, "distanceouter", 350),
                    reductionInner: injected(o, "reductioninner", 100),
                    reductionOuter: injected(o, "reductionouter", 0),
                    target: Vec3(x: 0, y: 0, z: 0)))
            case let other:
                WapleLog.warn("[Waple] SP4 unsupported operator dropped: \(other ?? "nil")")
            }
        }
        return (ops, attractCPIds, vortexAudio, blends)
    }

    /// resolveChild: 자식 json 경로 → def (호출측이 pkg/머티리얼/재귀 리졸브 담당). nil 리졸브 = 링크 드롭+로그.
    /// instanceOverride: 씬 오브젝트 "instanceoverride"(루트 def 전용 — 자식 children 은 비전파 보수 규약).
    /// 파스 **중** 적용해야 하는 이유: controlpointattract 의 target 이 CP 로 베이크되므로(아래 attractCPIds
    /// 재바인딩) CP 오버라이드는 베이크 전에 반영돼야 한다 — 사후 def 복제는 이 지점에 못 미친다.
    public static func parse(_ json: [String: Any], material: ParticleMaterial?,
                             instanceOverride: ParticleInstanceOverride? = nil,
                             resolveChild: ((String) -> ParticleSystemDef?)? = nil) -> ParticleSystemDef {
        var emitters: [Emitter] = []
        // emitters 와 병렬(같은 case 에서 함께 append) — 오디오반응 rate 변조에 이미터별 파라미터 공급.
        var emitterAudio: [AudioProcessing?] = []
        // F620/F627: speedmin/speedmax·box distancemin 도 emitters 와 병렬로 함께 append.
        var emitterSpeed: [SIMD2<Float>] = []
        var boxDistanceMin: [Vec3?] = []
        // 주기 방출(minperiodicduration…maxtoemitperperiod @0x48f3c0–0x48e2b8)도 emitters 와 병렬.
        var emitterPeriodic: [PeriodicEmission?] = []
        /// **[2026-08-20] "[추정]" 을 뗀다 — 이미터 base 파서(0x1401c1c70)를 끝까지 읽었다.**
        ///
        /// 다섯 키의 저장 위치와 처리가 전부 확정이다:
        ///   minperiodicduration → [+0x18](0x1401c1d66)   maxperiodicduration → [+0x1c](0x1401c1dac)
        ///   minperiodicdelay    → [+0x20](0x1401c1d89)   maxperiodicdelay    → [+0x24](0x1401c1dcf)
        ///   maxtoemitperperiod  (0x1401c1dd4)
        /// 그리고 함수 꼬리(0x1401c1deb-0x1401c1e0c)가 **min 을 max 로 클램프**한다:
        ///   `[+0x18] = minss([+0x1c], [+0x18])` · `[+0x20] = minss([+0x24], [+0x20])`
        /// max 는 건드리지 않는다 — 즉 min > max 면 min 이 내려가고 범위가 [max, max] 가 된다.
        ///
        /// **부재 기본값은 0 이 아니다** — 다섯 키 전부 주입 대상이다. 이미터 기본값 주입기
        /// (진입 **0x1401b8df0**)의 꼬리 0x1401b907d-0x1401b90f5 가 심는다:
        ///     minperiodicduration = 2.0(0x1401b907d)   maxperiodicduration = 3.0(0x1401b9094)
        ///     minperiodicdelay    = 1.0(0x1401b90ab)   maxperiodicdelay    = 2.0(0x1401b90c2)
        ///     maxtoemitperperiod  = 0  (정수 헬퍼 0x1401d7be0 으로 tail-jmp)
        /// 실수 주입은 공용 헬퍼 0x1401d7d30 이 한다 — `strlen` → `find`(0x140087490) →
        /// `test rax,rax` / `jne`(있으면 건너뜀) → `cvtss2sd` → 저장. 여기도 **부재일 때만**이다.
        ///
        /// **[정정 2026-08-20] 이 자리를 한 번 틀렸다.** 직전 커밋은 "주기 키에는 기본값 주입이
        /// 없다(= 전부 0)" 고 적었는데 정반대다. 원인은 디스어셈블 방법이었다 — 주입기를
        /// 0x1401b8e09 부터 **고정 바이트 창**으로 읽었는데 그 주소는 함수 진입이 아니라 체인된
        /// `.pdata` 조각의 경계였고, 창이 `instantaneous` 블록에서 끊겨 주기 꼬리를 통째로 놓쳤다.
        /// 교훈: 함수 경계는 `.pdata` 로 잡되 **체인된 조각을 병합**해야 한다. 고정 창은 안 된다.
        ///
        /// 실물 도달 0: 주기 키를 쓰는 이미터 5개(thunderbolt ×2, thunderbolt_beam_child ×2,
        /// water_droplets_periodic)가 네 min/max 를 **전건 명시**하고 전건 min ≤ max 다.
        /// 워크샵 자산이 max 를 생략하면 직전 코드는 창 길이가 0 으로 붕괴해 방출이 죽었다.
        func parsePeriodic(_ e: [String: Any]) -> PeriodicEmission? {
            let dMin = pfloat(e["minperiodicduration"]), dMax = pfloat(e["maxperiodicduration"])
            let pMin = pfloat(e["minperiodicdelay"]), pMax = pfloat(e["maxperiodicdelay"])
            let quota = pint(e["maxtoemitperperiod"])
            guard dMin != nil || dMax != nil || pMin != nil || pMax != nil || quota != nil else { return nil }
            let dLo = injected(e, "minperiodicduration", 2), dHi = injected(e, "maxperiodicduration", 3)
            let pLo = injected(e, "minperiodicdelay", 1), pHi = injected(e, "maxperiodicdelay", 2)
            // 꼬리 클램프(0x1401c1deb-0x1401c1e0c): min 만 max 로 내린다. max 는 안 건드린다.
            return PeriodicEmission(durationMin: Swift.min(dLo, dHi), durationMax: dHi,
                                    delayMin: Swift.min(pLo, pHi), delayMax: pHi,
                                    maxPerPeriod: max(0, quota ?? 0))
        }
        // **[2026-08-20] `rate` 부재 기본값은 0 이 아니라 10.0 이다.** 이미터 기본값 주입기
        // 0x1401b8e09 가 `movabs rcx, 0x4024000000000000`(= 10.0, 0x1401b8e59) 을 심는다 —
        // `Json::Value::find`(0x140087490) 가 null 을 낼 때만이다. 실물 도달은 293건 중 4건
        // (sphererandom 2 + boxrandom 2)으로 작지만, 그 4건은 종전에 **연속 방출이 없었다**.
        //
        // 테스트 픽스처 9곳이 `instantaneous` 만 주고 `rate` 를 생략하고 있었다 — 전부
        // "버스트 전용" 의도라 `"rate":0` 을 명시해 기본값과 분리했다. 픽스처가 기본값에
        // 묵시적으로 기대던 것을 드러낸 것이지, 기대를 바꾼 게 아니다.
        for case let e as [String: Any] in (json["emitter"] as? [Any] ?? []) {
            // F620: speedmin 부재 시 0, speedmax 부재 시 speedmin 승계(고정속도) — 부호 있는 초기속도.
            let speedMin = pfloat(e["speedmin"]) ?? 0
            let speedMax = pfloat(e["speedmax"]) ?? speedMin
            switch e["name"] as? String {
            case "sphererandom":
                emitters.append(.sphere(
                    origin: pvec3(e["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
                    // 부재 기본 (1,1,0) — **인접 추정이 아니라 실측이다**(2026-08-20). 주입기가
                    // 0x1401b9339 에서 `mov eax, [0x14048f488]` + 0x1401b934c 의 5번째 바이트를
                    // 복사해 길이 5 문자열 "1 1 0" 을 만든다(find @0x1401b92fd, tag=4).
                    directions: injectedVec3(e, "directions", Vec3(x: 1, y: 1, z: 0)),
                    distanceMin: injected(e, "distancemin", 0),    // 0x1401b944a (플래그 무관)
                    // distancemax 는 직교투영 플래그 의존: ortho **256**(0x1401b9454), 원근 1.0
                    // (0x1401b945e). 주입기 0x1401b9100, 게이트 `stricmp`@0x1401c5c7c 'sphererandom'
                    // → 호출부 0x1401c5cb2. 도달 2/542 로 작지만 0 은 어느 분기도 아니다.
                    distanceMax: injected(e, "distancemax", 256),  // 0x1401b9470
                    rate: injected(e, "rate", 10),   // 주입기 0x1401b8e09 → 10.0(0x1401b8e59). 위 주석 참조.
                    burst: pint(e["instantaneous"]) ?? 0,
                    sign: pvec3(e["sign"]) ?? Vec3(x: 0, y: 0, z: 0)))
                emitterAudio.append(AudioProcessing.parse(e))
                emitterSpeed.append(SIMD2(speedMin, speedMax))
                boxDistanceMin.append(nil)
                emitterPeriodic.append(parsePeriodic(e))
            case "boxrandom":
                emitters.append(.box(
                    origin: pvec3(e["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
                    // 부재 기본은 (0,0,0)(= 원점 붕괴)이 아니다. 문자열 주입기 0x1401d7e80 호출
                    // @0x1401b9838(주입기 0x1401b9520, 게이트 `stricmp`@0x1401c6397 → 호출부
                    // 0x1401c63cd)이 심는데, **플래그 무관이 아니라 조건부**다:
                    //     0x1401b971b  lea rsi, "1 1 1"          ; 원근 기본
                    //     0x1401b981d  lea rax, "256 256 0"      ; 직교 기본
                    //     0x1401b9824  test r15b, r15b / cmovne rsi, rax
                    // 직교가 실물 씬의 대부분(동봉 트리 169/171 · 두 트리+설치본 347/355)이고,
                    // 원근 판정 씬은 조건부 상수 원소를 아예 안 쓴다 → **(256, 256, 0)** 이 실측 동작이다.
                    // z=0 인 것도 직교 서사와 맞는다(turbulence 의 mask "1 1 0" 과 같은 이유).
                    // 51건 중 4건이 생략한다.
                    // (`layerimage` 주입기 0x1401b9930 에는 distancemax 가 **없으므로** 그쪽은 안 건드린다.)
                    distanceMax: injectedVec3OrScalar(e, "distancemax", Vec3(x: 256, y: 256, z: 0)),
                    rate: injected(e, "rate", 10),   // 주입기 0x1401b8e09 → 10.0(0x1401b8e59). 위 주석 참조.
                    burst: pint(e["instantaneous"]) ?? 0))
                emitterAudio.append(AudioProcessing.parse(e))
                emitterSpeed.append(SIMD2(speedMin, speedMax))
                boxDistanceMin.append(pvec3OrScalar(e["distancemin"]))
                emitterPeriodic.append(parsePeriodic(e))
            case "layerimage":
                // E1(②): layerimage(레이어 이미지 픽셀에서 방출) — 케이스 자체가 없어 무조건 드롭돼
                // 이 이미터만 가진 시스템은 emitters=[] 로 파티클을 0개도 생성하지 못했다. 픽셀 불투명
                // 분포 샘플링은 디코드 텍스처(WapleRender 전용) 접근이 필요해 파스 단계(WapleCore)에서는
                // 불가 — sphererandom/boxrandom과 동일한 공용 필드(origin/distancemax/distancemin/rate/
                // instantaneous)만 읽어 균등 박스 방출로 폴백한다. 캐비엇: 이미지 알파 마스크는 반영하지
                // 않음(균등분포) — 코퍼스 실측 n=1(rate 외 필드 미관측)이라 이 필드들은 부재 시 boxrandom과
                // 동일한 원점 스폰(distanceMax=0)으로 퇴화한다(무크래시, "0개"보다는 개선).
                emitters.append(.box(
                    origin: pvec3(e["origin"]) ?? Vec3(x: 0, y: 0, z: 0),
                    distanceMax: pvec3OrScalar(e["distancemax"]) ?? Vec3(x: 0, y: 0, z: 0),
                    rate: injected(e, "rate", 10),   // 주입기 0x1401b8e09 → 10.0(0x1401b8e59). 위 주석 참조.
                    burst: pint(e["instantaneous"]) ?? 0))
                emitterAudio.append(AudioProcessing.parse(e))
                // layerimage 만 speed 기본이 0 이 아니다 — 주입기 0x1401b9930 이 speedmin=0.1
                // (0x1401b9a5d) · speedmax=0.2(0x1401b9b1b) 를 심는다(둘 다 플래그 무관).
                // sphererandom/boxrandom 주입기는 둘 다 0.0 이라 위 공용 계산이 그대로 맞다.
                emitterSpeed.append(SIMD2(injected(e, "speedmin", 0.1), injected(e, "speedmax", 0.2)))
                boxDistanceMin.append(pvec3OrScalar(e["distancemin"]))
                emitterPeriodic.append(parsePeriodic(e))
            case let other:
                WapleLog.warn("[Waple] SP4 unsupported emitter dropped: \(other ?? "nil")")
            }
        }

        var (inits, mapSeqAxis) = Self.parseInitializers(json["initializer"] as? [Any] ?? [])

        // 인스턴스 오버라이드(배수) 적용 — 이미터 rate/버스트, 이니셜라이저 min/max.
        // 배수 대상 이니셜라이저가 프리셋에 없으면 주입(스폰 기본 1 × 배수 = 배수 자체; m==1 은 무의미라
        // 생략). speed 는 속도원 부재 시 0×배수=0 — 주입 없음. 색 배수는 colorrandom(0..255)·colorlist
        // (0..1) 양쪽에 성분별 곱(선형 배수라 스페이스 무관), 색 이니셜라이저 부재 시 colorList([배수]) 주입
        // (스폰 기본 백색 × 배수 = 배수 자체).
        if let ov = instanceOverride, !ov.isEmpty {
            func mul(_ v: Vec3, _ m: Vec3) -> Vec3 { Vec3(x: v.x * m.x, y: v.y * m.y, z: v.z * m.z) }
            func scale(_ v: Vec3, _ m: Float) -> Vec3 { Vec3(x: v.x * m, y: v.y * m, z: v.z * m) }
            func scaledBurst(_ b: Int, _ m: Float) -> Int { saturatedCount(Float(b) * m) }  // 감사 V06: 포화 클램프
            if ov.rate != nil || ov.count != nil {
                let rm = ov.rate ?? 1, cm = ov.count ?? 1
                emitters = emitters.map { e in
                    switch e {
                    case let .sphere(origin, directions, dMin, dMax, rate, burst, sign):
                        return .sphere(origin: origin, directions: directions, distanceMin: dMin,
                                       distanceMax: dMax, rate: rate * rm, burst: scaledBurst(burst, cm), sign: sign)
                    case let .box(origin, distanceMax, rate, burst):
                        return .box(origin: origin, distanceMax: distanceMax,
                                    rate: rate * rm, burst: scaledBurst(burst, cm))
                    }
                }
            }
            inits = inits.map { i in
                switch i {
                case let .lifetimeRandom(mn, mx, e) where ov.lifetime != nil:
                    return .lifetimeRandom(min: mn * ov.lifetime!, max: mx * ov.lifetime!, exponent: e)
                case let .sizeRandom(mn, mx, e) where ov.size != nil:
                    return .sizeRandom(min: mn * ov.size!, max: mx * ov.size!, exponent: e)
                case let .alphaRandom(mn, mx, e) where ov.alpha != nil:
                    return .alphaRandom(min: mn * ov.alpha!, max: mx * ov.alpha!, exponent: e)
                case let .velocityRandom(mn, mx, e) where ov.speed != nil:
                    return .velocityRandom(min: scale(mn, ov.speed!), max: scale(mx, ov.speed!), exponent: e)
                case let .turbulentVelocityRandom(sMin, sMax, sc, off) where ov.speed != nil:
                    return .turbulentVelocityRandom(speedMin: sMin * ov.speed!, speedMax: sMax * ov.speed!,
                                                    scale: sc, offset: off)
                case let .colorRandom(mn, mx, e) where ov.colorMultiplier != nil:
                    return .colorRandom(min: mul(mn, ov.colorMultiplier!), max: mul(mx, ov.colorMultiplier!), exponent: e)
                case let .colorList(colors) where ov.colorMultiplier != nil:
                    return .colorList(colors: colors.map { mul($0, ov.colorMultiplier!) })
                default:
                    return i
                }
            }
            func lacks(_ isKind: (Initializer) -> Bool) -> Bool { !inits.contains(where: isKind) }
            if let m = ov.size, m != 1, lacks({ if case .sizeRandom = $0 { return true } else { return false } }) {
                inits.append(.sizeRandom(min: m, max: m))
            }
            if let m = ov.alpha, m != 1, lacks({ if case .alphaRandom = $0 { return true } else { return false } }) {
                inits.append(.alphaRandom(min: m, max: m, exponent: 1))
            }
            if let m = ov.lifetime, m != 1, lacks({ if case .lifetimeRandom = $0 { return true } else { return false } }) {
                inits.append(.lifetimeRandom(min: m, max: m))
            }
            if let c = ov.colorMultiplier, c != Vec3(x: 1, y: 1, z: 1),
               lacks({ if case .colorRandom = $0 { return true }
                       if case .colorList = $0 { return true } else { return false } }) {
                inits.append(.colorList(colors: [c]))
            }
        }

        var (ops, attractCPIds, vortexAudio, operatorBlends) = Self.parseOperators(json["operator"] as? [Any] ?? [])

        // **[2026-08-20] `renderer` 키 부재는 "미지원" 이 아니라 sprite 다.** 파서가
        // `isArray`(0x1400888a0)에 실패하면 그 자리에서 오브젝트(태그 7)를 만들어
        // `{name:"sprite"}` 를 **주입한다**(0x1401c58a9–0x1401c58ce).
        //
        // **빈 배열 `[]` 은 다르다** — isArray 를 통과하므로 주입이 걸리지 않고 렌더러가 0개로
        // 남는다. 종전엔 두 경우를 `.unsupported("none")` 하나로 뭉갰다(동봉 부재 6 · 빈 배열 4).
        let rawRenderer = json["renderer"]
        var renderer: RendererKind = (rawRenderer as? [Any]) == nil ? .sprite : .unsupported("none")
        var orientation: ParticleOrientation = .screen
        var ropeOpts: RopeRenderOptions? = nil
        if let r0 = (rawRenderer as? [Any])?.first as? [String: Any] {
            let n = r0["name"] as? String ?? "none"
            switch n {
            case "sprite": renderer = .sprite
            case "spritetrail":
                // F790: minlength 추가 파스(JSON null → pfloat nil → 0 = 클램프 부재).
                //
                // **[2026-08-20 기본값 정정]** 주입기 0x1401c0af0 은 `length` 에 0.05
                // (`movabs rcx, 0x3fa99999a0000000` @0x1401c0b55, 태그 3)를, `maxlength` 에 10.0
                // (`0x4024000000000000` @0x1401c0c13)을 심는다. `minlength` 는 **주입하지 않는다**
                // (그 키의 lea 가 주입기 안에 없다) — 부재는 0 = 하한 없음이 맞다.
                //
                // 종전 0/0 은 `spriteTrailStretch` 의 `guard length > 0` 폴백을 태워 **부재
                // 인스턴스의 신장을 항등 1 로** 만들었다. 즉 H3 핫픽스의 전제("length 부재 시엔
                // 신장 자체가 정의되지 않는다")가 무너진다 — WE 는 부재에도 0.05 를 심으므로
                // 신장은 언제나 정의된다. 동봉 44건 중 length 부재 13 · maxlength 부재 11 이
                // 이 경로다: 신장이 1 → `clamp(speed·0.05, minlength, 10)` 으로 바뀐다.
                // **2D spritetrail 의 그림이 실제로 달라지는 변경이다** — 골든 재검토 대상.
                renderer = .spriteTrail(maxLength: injected(r0, "maxlength", 10),
                                        length: injected(r0, "length", 0.05),
                                        minLength: pfloat(r0["minlength"]) ?? 0)
            case "rope":
                // 주입 4(`mov qword [rax], 4` @0x1401c0d00), 핸들러 clamp [0,32](0x1401cffbd).
                renderer = .rope(subdivision: min(32, max(0, pint(r0["subdivision"]) ?? 4)))
            case "ropetrail":
                // 주입 length 1.0(`0x3ff0000000000000` @0x1401c10da), 핸들러 `maxss 0.001` 하한
                // (0x1401d0149). subdivision 주입 1(`mov qword [rax], 1` @0x1401c128a), clamp [0,32].
                renderer = .ropeTrail(length: max(0.001, injected(r0, "length", 1)),
                                      subdivision: min(32, max(0, pint(r0["subdivision"]) ?? 1)))
            default:
                renderer = .unsupported(n); WapleLog.warn("[Waple] SP4 unsupported renderer (drawn as sprite): \(n)")
            }
            // F626: orientation("screen"/"upright"/"fixed") + axis — 파스·보존(렌더 소비는 후속).
            switch r0["orientation"] as? String {
            case "upright": orientation = .upright
            case "fixed": orientation = .fixed(axis: pvec3(r0["axis"]) ?? Vec3(x: 0, y: 0, z: 1))
            default: orientation = .screen
            }
            // rope/ropetrail 확장 키 — **렌더러마다 읽는 키가 다르다**(RopeRenderOptions 주석의
            // 핸들러별 lea 전수 참조). 부재 기본값은 주입기 실측이라 이제 "키가 하나도 없으면 nil"
            // 이 아니라 **항상 주입값으로 채운 옵션**을 싣는다 — 부재는 "값 없음" 이 아니라
            // "엔진 기본값" 이기 때문이다(rope 의 uvsmoothing 부재 13건이 전부 true 로 간다).
            switch renderer {
            case .rope:
                var opts = RopeRenderOptions()
                opts.uvScale = injected(r0, "uvscale", 1)              // 0x1401c0fd7
                opts.uvScrolling = pbool(r0["uvscrolling"]) ?? false   // 태그 5, r14b = 0
                opts.uvSmoothing = pbool(r0["uvsmoothing"]) ?? true    // 태그 5, 값 1 @0x1401c0dd3
                ropeOpts = opts
            case .ropeTrail:
                var opts = RopeRenderOptions()
                opts.uvScale = injected(r0, "uvscale", 1)              // H_INT r8d=1 @0x1401c13a3
                opts.uvScrolling = pbool(r0["uvscrolling"]) ?? false   // 태그 5, bpl = 0 (`xor ebp,ebp`@0x1401c109a)
                opts.fadeAlpha = pbool(r0["fadealpha"]) ?? false       // H_BOOL r8d=0 @0x1401c13c5
                opts.fadeSize = pbool(r0["fadesize"]) ?? false         // H_BOOL r8d=0 @0x1401c13e1
                // 주입 4(0x1401c119c), 핸들러 clamp [2,32](0x1401d0186).
                opts.segments = min(32, max(2, pint(r0["segments"]) ?? 4))
                ropeOpts = opts
            default: break
            }
        }

        // **[2026-08-20] 부재 기본 100 은 근거가 없었다 — 실물은 0 이다.** `maxcount` 에는
        // 주입기가 없고, 파서가 `isNumeric`(0x140088880)에 실패하면 `xor r15d,r15d` →
        // `mov [r13], eax` 로 **0** 을 심는다(0x1401c5784–0x1401c57a2). 동봉 289 시스템이
        // 전건 저작하므로 도달은 0이다.
        //
        // 0 하한과 65536 상한은 그대로 둔다 — 실물엔 없는 **Waple 의 의도된 가드**다
        // (음수가 시뮬 버스트 Range 상한으로 흘러 트랩, 감사 V02 / 코퍼스 100000 설정 씬의
        // CPU 시뮬 과부하, 감사 D-corpus G7).
        var maxCount = max(0, pint(json["maxcount"]) ?? 0)
        if let m = instanceOverride?.count {
            maxCount = saturatedCount(Float(maxCount) * m)  // 감사 V06: Int 범위 밖 곱 트랩 — 포화 클램프
        }
        // 상한 65536: 코퍼스 100000 설정 씨 CPU 시뮬 과부하 방지(감사 D-corpus G7).
        maxCount = min(65536, maxCount)

        var children: [ChildLink] = []
        if let resolve = resolveChild {
            for case let c as [String: Any] in (json["children"] as? [Any] ?? []) {
                guard let path = c["name"] as? String else { continue }
                guard let childDef = resolve(path) else {
                    WapleLog.warn("[Waple] particle child resolve failed, dropped: \(path)")
                    continue
                }
                let trigger: ChildTrigger
                switch c["type"] as? String {
                case nil, "static": trigger = .always
                case "eventfollow": trigger = .follow
                case "eventspawn": trigger = .spawnBurst
                case "eventdeath": trigger = .deathBurst
                case let other:
                    WapleLog.warn("[Waple] particle child unknown type '\(other ?? "")' → follow 취급: \(path)")
                    trigger = .follow
                }
                // 자식 maxInstances 에도 루트 maxCount 와 **같은 상한**을 건다(:1032-1037).
                // 루트는 음수 0 클램프 + 65536 상한으로 CPU 시뮬을 묶어두는데 이 자리만 pint 원값을
                // 그대로 썼다 — 자식 인스턴스는 스폰된 부모 파티클 하나당 ParticleSimulator 를 통째로
                // 하나씩 할당하므로(ParticleSimulator:305) 루트 파티클 한 개보다 훨씬 비싼 단위인데
                // 상한이 없었다. 새 한계를 발명하지 않고 루트와 같은 값을 쓰고, 잘리면 로그를 남긴다.
                // **[2026-08-20] 자식 `maxcount` 부재 기본은 상수 10 이다** — children 주입기
                // 0x1401c1430 이 `mov r8d, 0xa` → `H_INT` 로 심는다(0x1401c16f5–0x1401c1705).
                // 종전 `trigger == .always ? 1 : 루트 maxcount` 는 근거 없는 유추였고, 동봉
                // 자식 선언의 72%가 이 키를 생략한다 — `static` 자식이 특히 1 vs 10 으로 갈렸다.
                let rawMaxInstances = max(0, pint(c["maxcount"]) ?? 10)
                let maxInstances = min(65536, rawMaxInstances)
                if maxInstances != rawMaxInstances {
                    WapleLog.warn("[Waple] particle child maxcount \(rawMaxInstances) → \(maxInstances) 클램프: \(path)")
                }
                children.append(ChildLink(
                    def: childDef, trigger: trigger,
                    maxInstances: maxInstances,
                    probability: pfloat(c["probability"]) ?? 1,
                    origin: pvec3(c["origin"]) ?? Vec3(x: 0, y: 0, z: 0)))
            }
        }

        var controlPoints = Array(repeating: Vec3(x: 0, y: 0, z: 0), count: 8)
        // **[2026-08-20] 슬롯은 `id` 가 아니라 배열 위치다.** 실물 파서는 고정 8회를 돌며
        // (`inc r14d` / `cmp r14d, 8` @0x1401d0807–0x1401d080a) `operator[](i)`(0x140086540)로
        // 원소를 꺼내고, 슬롯 주소를 `shl rdi, 5` + `[rdi + r13 + 0xa4]`(0x1401d0593–0x1401d05ae)
        // 로 **인덱스 × 32** 에서 만든다. `"id"` 문자열은 이 경로에서 한 번도 참조되지 않는다.
        // 원소가 오브젝트(태그 7)가 아니면 그 자리를 건너뛴다(`cmp byte [rax+8],7` @0x1401d053e).
        //
        // 종전엔 `cp["id"]` 로 슬롯을 골라, **`id` 가 없는 CP 를 통째로 버렸다**. 동봉 코퍼스는
        // 1816 원소가 전건 `id == 배열인덱스`라 도달이 0이지만 모델이 틀렸다.
        //
        // 읽는 키는 offset·angles·flags·parentcontrolpoint 넷이다(0x1401d0552·0x1401d06ce·
        // 0x1401d0561·0x1401d0573 — 뒤 둘은 uint 주입기 0x1401d8280, 기본 0). Waple 은 아직
        // offset 만 소비한다 — 나머지 셋은 **의미 미측정**이라 파스도 하지 않는다(유령 필드를
        // 만드느니 안 읽는 편이 낫다. `spec` 과 fixplan §2-A B5 에 남겨 뒀다).
        for (slot, element) in (json["controlpoint"] as? [Any] ?? []).enumerated() where slot < 8 {
            guard let cp = element as? [String: Any] else { continue }   // 비-오브젝트는 그 자리를 비운다
            if let off = pvec3(cp["offset"]) { controlPoints[slot] = off }
        }
        // 인스턴스 CP 오버라이드(절대 대체)는 attract target 재베이크 **전에** — 재베이크 후면 attract 가
        // 프리셋 CP 를 계속 본다(실측: CP 오버라이드 51오브젝트 중 22가 attract 보유).
        if let ov = instanceOverride {
            for (id, off) in ov.controlPoints where id >= 0 && id < 8 { controlPoints[id] = off }
        }
        for (i, cpid) in attractCPIds {
            switch ops[i] {
            case let .controlPointAttract(scale, threshold, _, deleteThreshold, flags):
                ops[i] = .controlPointAttract(scale: scale, threshold: threshold,
                                              target: controlPoints[cpid],
                                              deleteThreshold: deleteThreshold, flags: flags)
            case let .vortex(axis, dIn, dOut, sIn, sOut, offset, cf, ring, flags):
                ops[i] = .vortex(axis: axis, distanceInner: dIn, distanceOuter: dOut,
                                 speedInner: sIn, speedOuter: sOut,
                                 offset: Vec3(x: controlPoints[cpid].x + offset.x,
                                              y: controlPoints[cpid].y + offset.y,
                                              z: controlPoints[cpid].z + offset.z),
                                 centerForce: cf, ring: ring, flags: flags)
            case let .maintainDistanceToControlPoint(distance, vs, _):
                ops[i] = .maintainDistanceToControlPoint(distance: distance, variableStrength: vs,
                                                         target: controlPoints[cpid])
            case let .reduceMovementNearControlPoint(dIn, dOut, rIn, rOut, _):
                // attract 와 같은 자리에서 CP 를 굽는다(인스턴스 오버라이드 반영 후).
                ops[i] = .reduceMovementNearControlPoint(distanceInner: dIn, distanceOuter: dOut,
                                                         reductionInner: rIn, reductionOuter: rOut,
                                                         target: controlPoints[cpid])
            default:
                break
            }
        }

        var def = ParticleSystemDef(
            emitters: emitters, initializers: inits, operators: ops, renderer: renderer,
            maxCount: maxCount, startTime: pfloat(json["starttime"]) ?? 0, material: material,
            children: children)
        def.controlPoints = controlPoints
        // 인스턴스 오버라이드는 emitters 를 .map(순서/개수 보존)만 하므로 emitterAudio 병렬성 유지.
        def.emitterAudio = emitterAudio
        def.emitterSpeed = emitterSpeed
        def.boxDistanceMin = boxDistanceMin
        def.emitterPeriodic = emitterPeriodic
        def.vortexAudio = vortexAudio
        def.operatorBlends = operatorBlends
        def.flags = pint(json["flags"]) ?? 0                                        // F623
        // F622: animationmode("sequence"/"randomframe")·sequencemultiplier(배속, 기본 1).
        def.animationMode = (json["animationmode"] as? String).flatMap { ParticleAnimationMode(rawValue: $0) }
        def.sequenceMultiplier = pfloat(json["sequencemultiplier"]) ?? 1
        def.orientation = orientation
        def.mapSequenceAxis = mapSeqAxis
        def.ropeOptions = ropeOpts
        return def
    }
}

// MARK: - 파싱 헬퍼 (공용 JSONNumerics 위임 — 파티클 규약: 문자열 스칼라 거부, 언랩 없음)

private func pfloat(_ v: Any?) -> Float? { strictFloat(v) }

/// **기본값 주입기 규약** — 원본은 원소 팩토리 직전에 `if (!json.find(k)) json[k] = C;` 를 돌린다.
/// 결정적으로 **키가 없을 때만** 상수를 심는다. 키가 **있는데 값이 못 읽히는 경우**
/// (`"rate": 1e300` 처럼 Float 범위를 넘는 값)는 주입 대상이 **아니다** — 원본에서도
/// `find` 가 노드를 찾으므로 주입을 건너뛰고 그 노드의 `asFloat` 결과를 쓴다.
///
/// 이 구분이 없으면 `pfloat(d[k]) ?? C` 가 두 경우를 뭉뚱그려, 신뢰불가 입력이 오히려
/// **엔진 기본값으로 승격**된다. 실제로 그렇게 넣었다가
/// `testHugeNumericParticleValuesDefaultInsteadOfTrapping`(rate 1e300 → 0 기대)이 잡았다.
private func injected(_ d: [String: Any], _ key: String, _ constant: Float) -> Float {
    d[key] == nil ? constant : (pfloat(d[key]) ?? 0)
}

/// `injected(_:_:_:)` 의 Vec3 판(문자열 `"x y z"` 규약). 부재만 주입, 그 외는 0 벡터.
private func injectedVec3(_ d: [String: Any], _ key: String, _ constant: Vec3) -> Vec3 {
    d[key] == nil ? constant : (pvec3(d[key]) ?? Vec3(x: 0, y: 0, z: 0))
}

/// `injected(_:_:_:)` 의 Int 판. 원본은 실수(0x1401d7d30)·정수(**0x1401d7be0**, 값 태그 1)·
/// 문자열(0x1401d7e80, 태그 4)·불(0x1401d8120, 태그 5) 네 종류의 주입기를 쓴다.
private func injectedInt(_ d: [String: Any], _ key: String, _ constant: Int) -> Int {
    d[key] == nil ? constant : (pint(d[key]) ?? 0)
}

/// `injectedVec3(_:_:_:)` 의 스칼라 브로드캐스트 허용판 — 값이 **있을 때**의 파싱 경로는
/// `pvec3OrScalar` 그대로 두고 부재일 때만 상수를 심는다(이미터 `distancemax` 용).
private func injectedVec3OrScalar(_ d: [String: Any], _ key: String, _ constant: Vec3) -> Vec3 {
    d[key] == nil ? constant : (pvec3OrScalar(d[key]) ?? Vec3(x: 0, y: 0, z: 0))
}

/// **직교투영 분기 — 위 주입 상수 중 일부는 씬 단위 플래그에 따라 값이 둘이다.**
///
/// 주입기들은 두 번째 인자로 `bool` 을 받는다(호출부가 전부 `movzx edx, byte ptr [rbp+0x2238]`
/// 로 넘긴다 — 예: 0x1401c5cb2 · 0x1401c8782 · 0x1401cd45c · 0x1401cde79 · 0x1401cc0bd).
/// 그 바이트는 디스패처(0x1401c5490) 진입 직후 0x1401c5b75 의 접근자 `0x14010daa0` 결과이고,
/// 접근자는 `[rcx+0x118] >> 10 & 1` 을 읽는다. 그 비트는 0x14018768a 에서
/// `scene.general.orthogonalprojection`(키 문자열 @0x1401874ec) 이
/// `auto: true` 이거나 `width`·`height` 가 **둘 다 0 이 아닐 때** 세워진다
/// (0x140187565 / 0x1401875df → `[+0xe0]` bit3 → `[+0x118]` bit10; 기본은 0x1401872ca 에서 clear).
///
/// 즉 **직교(2D 픽셀 좌표) 씬이면 세워진다**. 상수의 성격도 그와 일치한다 —
/// 세워졌을 때는 픽셀 스케일(속도 100/250, 반경 300, 거리 256), 아니면 단위 스케일(0.5/1.0, 1.0).
/// `turbulence` 의 mask 가 ortho 에서 (1,1,0) 으로 z 를 잠그는 것이 결정적 방증이다.
///
/// 동봉 두 트리의 `scene.json` 355개 중 **347개(97.7%)** 가 이 비트를 세운다
/// (`orthogonalprojection` 부재 8건만 clear). 그래서 위 상수들은 **ortho 분기**를 채택했고,
/// 원근 분기 값은 각 자리 주석에 함께 남겼다.
///
/// 이 사실은 종전 `oscillateposition.scalemax` 판단(“JSON `flags` 에 bit10 이 없으니 0.5”)을
/// 뒤집는다 — 그 bit10 은 JSON `flags` 키가 아니라 C++ 오브젝트 플래그였다.
private enum OrthogonalProjectionBranch {}
/// JSON false/true는 NSNumber로도 브리지되므로 exponent 숫자 경로에서 명시적으로 배제한다.
private func pexponent(_ v: Any?) -> Float? {
    if let number = v as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
    return pfloat(v)
}
private func pint(_ v: Any?) -> Int? { strictInt(v) }
/// jsoncpp `asBool`(0x140086300) 대응 — `movzx eax, byte [rcx]` 로 **태그와 무관하게** 값
/// 워드의 하위 바이트를 본다. 즉 실물은 JSON `true`/`false` 뿐 아니라 숫자 0/비0 도 받는다.
/// 동봉 자산은 rope/ropetrail 불리언 키를 전건 JSON 리터럴로 적지만(`uvscrolling: true` 8건 ·
/// `uvsmoothing: false` 12건 · `fadealpha: true` 4건), 워크샵이 `1`/`0` 을 적을 수 있어 둘 다 받는다.
/// 읽을 수 없는 값(문자열·범위 밖)은 nil 을 돌려 **부재와 구분**한다 — 주입은 부재에만 일어난다.
private func pbool(_ v: Any?) -> Bool? {
    if v == nil || v is NSNull { return nil }
    if let b = v as? Bool { return b }
    if let i = strictInt(v) { return i != 0 }
    return nil
}
/// 감사 V06: Float→Int 스케일 변환 포화 클램프 — 곱이 Int 범위를 넘는(또는 NaN) 워크샵 입력의
/// Int() 변환 트랩(SIGTRAP, maxcount 1e9 × override count 1e12 실재현) 방지.
/// 0 하한은 V02 음수 클램프와 동일 정책, 상한 포화는 sheetFrameIndex(:52)와 동형.
private func saturatedCount(_ v: Float) -> Int {
    let p = v.rounded()
    guard p.isFinite else { return 0 }
    return p <= 0 ? 0 : (p >= Float(Int.max) ? Int.max : Int(p))
}
private func pvec3(_ v: Any?) -> Vec3? { stringVec3(v) }
/// "x y z" 벡터 또는 단일 스칼라(브로드캐스트).
private func pvec3OrScalar(_ v: Any?) -> Vec3? {
    if let vec = pvec3(v) { return vec }
    if let s = pfloat(v) { return Vec3(x: s, y: s, z: s) }
    return nil
}
/// remapvalue "component": "x"/"y"/"z" 문자열 또는 0/1/2 숫자 → 0/1/2.
private func pcomponent(_ v: Any?) -> Int? {
    if let s = v as? String {
        switch s.lowercased() {
        case "x": return 0
        case "y": return 1
        case "z": return 2
        default: return Int(s)
        }
    }
    return pint(v)
}
