import Foundation

/// 프로퍼티 키프레임(실물 스키마 — 파서 VA 0x1401a8ce0–0x1401a9400):
/// `{frame, value, front{enabled,x,y}, back{enabled,x,y}, step}`.
///
/// 엔진 내부 표현은 **28바이트 구조체**다(저장부 VA 0x1401a9127–0x1401a9148):
/// `+0x00 i32 frame · +0x04 f32 value · +0x08 u32 flags · +0x0c f32 backX · +0x10 backY ·
///  +0x14 frontX · +0x18 frontY`. flags 는 bit0=back enabled · bit1=front enabled · bit2=step
/// (조립부 VA 0x1401a8fed/0x1401a9050/0x1401a90dd).
///
/// **lockangle/locklength/magic 은 재생에 없다** — 세 문자열 모두 wallpaper64.exe 에 xref 0건이고
/// 에디터 JS 에만 있다(`ui/dist/scripts/scripts.js`: `beziermode` 가 magic/step 을 고르고
/// lockangle/locklength 는 핸들 드래그 제약). 핸들 좌표에 이미 반영돼 있다.
public struct PropertyKeyframe: Equatable {
    public let frame: Float
    public let value: Float
    public let frontEnabled: Bool
    public let frontX: Float
    public let frontY: Float
    public let backEnabled: Bool
    public let backX: Float
    public let backY: Float
    /// 계단 보간. **이 키프레임이 구간의 오른쪽**일 때 그 구간 전체가 왼쪽 키프레임 값으로 고정된다
    /// (평가기 VA 0x1401a9d18 `test byte ptr [r10+r11+8], 4` — 읽는 쪽이 오른쪽 키프레임의 flags).
    /// 동봉·설치본 자산 도달 0(애니 블록 7개 전수 미기재)이지만 에디터가 저작한다
    /// (`beziermode === 'step'` → `keyframe.step = true`).
    public let step: Bool

    public init(frame: Float, value: Float, frontEnabled: Bool, frontX: Float, frontY: Float,
                backEnabled: Bool, backX: Float, backY: Float, step: Bool = false) {
        self.frame = frame; self.value = value
        self.frontEnabled = frontEnabled; self.frontX = frontX; self.frontY = frontY
        self.backEnabled = backEnabled; self.backX = backX; self.backY = backY
        self.step = step
    }
}

/// 타임라인 이벤트 마커(실물 스키마 2026-07-10, 3737268876 젤다 40지점):
/// `animation.options.events[] = {"frame": 750, "name": "walk_end"}` — 프레임 단위 명명 마커.
/// 재생이 마커 프레임을 지나는 순간 스크립트 훅 animationEvent(event{name}) 가 발화된다.
/// 퍼펫 .mdl(MDLA0006 트레일러의 f32초 + JSON cstring)도 동일 {frame,name} 페이로드를 쓴다.
public struct AnimationMarker: Equatable {
    public let name: String
    public let frame: Float
    public init(name: String, frame: Float) { self.name = name; self.frame = frame }
}

/// 씬 오브젝트 프로퍼티 애니메이션(성분별 트랙 c0..c3). 순수 평가기 — TDD.
///
/// **엔진 상태 구조체**(옵션 초기화 VA 0x1401a8c10–0x1401a8cd1, 시간 진행 VA 0x1401a9f60–0x1401aa1b4):
/// `+0x00 f32 1/fps · +0x04 f32 time(초) · +0x08 f32 length/fps(초) · +0x0c u32 flags · +0x10 i32 length`.
/// flags 는 bit0=mirror · bit1=single · bit2=random(랜덤 시작 프레임) · bit4=wraploop ·
/// bit29=startpaused · bit30=single 종료 · bit31=미러 역주행. `mode` 는 **stricmp** 로 비교하고
/// (VA 0x1401a8c78 "mirror" / 0x1401a8c91 "single") 둘 다 아니면 flags 0 = loop 다.
public struct PropertyAnimation: Equatable {
    public let tracks: [[PropertyKeyframe]]
    public let fps: Float
    public let length: Float     // frames
    public let mode: String      // "single"(끝 클램프) | "loop"(랩) | "mirror"(왕복 — 젤다 sky change)
    public let relative: Bool    // true 면 base + v
    /// options.wraploop — "마지막 프레임을 첫 프레임과 같게" 만드는 매끄러운 루프.
    /// 파스 시점에 트랙에 이미 반영돼 있다(`wrapLooped(_:lengthFrames:)`). 이 값은 보존용이다.
    public let wrapLoop: Bool
    public let events: [AnimationMarker]   // options.events 마커(없으면 빈 배열)
    /// C⑤: options.startpaused — 스크립트가 play() 하기 전까지 정지(frame 0) 상태로 저작됐다는 계약
    /// (lib.sceneScript.d.ts IAnimation.play "Start playing the animation if it's paused or stopped").
    /// play()/pause() 런타임 제어(스크립트 트리거 연결)는 미구현이라 이 값이 true 인 애니는 항상 frame 0
    /// 값으로 고정 평가된다 — WE 는 트리거 전까지 이 상태이므로 "영구 미발화"보다 "즉시 재생+고착"보다
    /// 정합적(마운트 직후 다수 상태와 일치). 트리거 이후 값은 여전히 미반영(별건 — caveats 참조).
    public let startPaused: Bool

    // `options.random`(flags bit2, 파스 VA 0x1401a9777 "random" → 0x1401a8ca5 `or dword [rbx+0xc], 4`)
    // 은 에디터의 "Random start frame"(`ui_editor_animation_modal_random_start_frame`)이다.
    // 인스턴스마다 시작 시각을 난수로 밀어야 해서 **평가기가 아니라 런타임 상태**의 몫이고,
    // 동봉·설치본 애니 7블록에 **도달 0** 이라 파스도 소비도 하지 않는다.

    public init(tracks: [[PropertyKeyframe]], fps: Float, length: Float, mode: String, relative: Bool,
                events: [AnimationMarker] = [], startPaused: Bool = false, wrapLoop: Bool = false) {
        self.tracks = tracks; self.fps = fps; self.length = length; self.mode = mode; self.relative = relative
        self.events = events; self.startPaused = startPaused; self.wrapLoop = wrapLoop
    }

    /// 모드 판정은 **대소문자 무시**다(WE 는 `stricmp` — VA 0x1401a8c78 / 0x1401a8c91).
    /// 인식하지 못하는 문자열은 flags 0 = **loop** 이지 클램프가 아니다.
    private var isMirror: Bool { mode.caseInsensitiveCompare("mirror") == .orderedSame }
    private var isSingle: Bool { mode.caseInsensitiveCompare("single") == .orderedSame }

    /// t(초) 시점의 성분 값. 트랙 없음 → base 유지. startPaused → 항상 frame 0(C⑤).
    ///
    /// **WE 는 정수 프레임에서만 곡선을 풀고 인접 두 프레임을 선형 보간한다**
    /// (소비단 VA 0x1401723d8–0x140172490: `f0 = clamp(trunc(time/spf), 0, length-1)` ·
    /// `f1 = min(f0+1, length)` · `frac = fmodf(time, spf)/spf` · `v = at(f0)·(1-frac) + at(f1)·frac`,
    /// 트랙 평가기 VA 0x1401a9bc0 은 그 정수 프레임 값을 vector<float> 에 메모이즈한다).
    /// Waple 은 **연속 프레임에서 직접** 곡선을 푼다 — 실측으로 어긋남이 무시 가능하기 때문이다:
    /// 동봉 자산 7블록을 두 방식으로 전수 대조하면 최대 차이가 0.00156(값 범위 1.0 의 0.16%)이고,
    /// 그것도 mirror 반환점(t == 길이) 한 점의 `f0` 클램프 때문이다. 나머지 구간은 ≤1.3e-15 다.
    /// 반대로 정수 양자화를 그대로 옮기면 `fmodf(time, 1/fps)` 가 정확한 프레임 경계에서
    /// 0 이 아니라 ≈spf 를 돌려(float32 로 frac ≈ 0.999997) 샘플이 한 프레임 앞서는 아티팩트까지
    /// 따라온다 — 실측 5.6% 편차가 전부 이 경계 인공물이었다. 정확도를 잃고 부동소수 취약성만
    /// 얻는 교환이라 옮기지 않는다.
    public func value(component: Int, atTime t: Float, base: Float) -> Float {
        guard component < tracks.count, !tracks[component].isEmpty else { return base }
        let track = tracks[component]
        var frame = (startPaused ? 0 : t) * fps
        if isSingle || length <= 0 {
            // single: WE 는 time 을 duration 에서 멈추고 flags bit30 을 세운다(VA 0x1401aa177).
            // length <= 0 은 WE 가 애니 자체를 드롭하는 입력이라(VA 0x1401a8c43) 종전 클램프 유지.
            frame = max(0, min(frame, length))
        } else if isMirror {
            // 왕복: 2L 주기 폴드 — WE 는 방향 비트(bit31)를 토글하는 상태 기계지만(VA 0x1401aa129)
            // 단조 클록에서는 삼각파와 동치다. firedMarkers/PuppetPose.frame 과 동일 규약(감사 V01).
            frame = frame.truncatingRemainder(dividingBy: 2 * length)
            if frame < 0 { frame += 2 * length }
            if frame > length { frame = 2 * length - frame }
        } else {
            // loop(= 인식 못 한 모드 포함): time = fmodf(time, duration) (VA 0x1401aa0cf).
            frame = frame.truncatingRemainder(dividingBy: length)
            if frame < 0 { frame += length }
        }
        let raw = evaluate(track: track, frame: frame)
        return relative ? base + raw : raw
    }

    /// 구간 탐색은 **반개구간** `k1.frame <= frame < k2.frame` 이다(VA 0x1401a9cd8–0x1401a9ce9).
    /// 닫힌구간으로 잡으면 `frame == k2.frame` 일 때 step 키프레임이 한 프레임 늦게 튄다.
    private func evaluate(track: [PropertyKeyframe], frame: Float) -> Float {
        if frame <= track[0].frame { return track[0].value }
        guard let last = track.last else { return 0 }
        if frame >= last.frame { return last.value }
        for i in 1..<track.count {
            let k1 = track[i - 1], k2 = track[i]
            guard k1.frame <= frame, frame < k2.frame else { continue }
            // step: 오른쪽 키프레임의 flags bit2 가 구간 전체를 왼쪽 값으로 고정(VA 0x1401a9d18).
            if k2.step { return k1.value }
            return segment(k1, k2, frame: frame)
        }
        return track[0].value
    }

    /// 큐빅 베지어 구간(제어점 조립 VA 0x1401a9d60–0x1401a9e9a).
    ///
    /// **핸들의 x 는 프레임 오프셋이 아니라 "구간 절반" 단위다** — `dx = k2.frame - k1.frame` 일 때
    ///   `P0 = (f0, v0)` · `P1 = (f0 + 0.5·dx·front.x, v0 + front.y)`
    ///   `P2 = (f1 + 0.5·dx·back.x,  v1 + back.y)`  · `P3 = (f1, v1)`
    /// 로 조립한다(VA 0x1401a9d60 `mulss xmm8, xmm12(0.5)` → 0x1401a9d6d/0x1401a9d74 에서
    /// back.x/front.x 와 곱하고 0x1401a9d82/0x1401a9d87 에서 끝점 프레임을 더한다).
    /// **y 에는 스케일이 없다**(VA 0x1401a9e58/0x1401a9e8f 의 맨 `addss`).
    /// 종전 Waple 은 x 도 오프셋 그대로 더해 곡선이 완전히 달랐다 — 동봉 자산 실측으로
    /// 최대 **값 범위의 13.71%**(blendgradient multiply, maintaindistance c1) 어긋났다.
    /// 저작 기본값 `front.x=+1 / back.x=-1` 은 이 규약에서 두 제어점이 구간 중점에 모이는
    /// 대칭 ease 이고, 종전 규약에서는 끝점에 거의 붙은 전혀 다른 곡선이었다.
    ///
    /// `enabled=false` 핸들은 WE 가 **파스 단계에서 x/y 를 읽지 않아 0** 이다
    /// (VA 0x1401a8ff8 / 0x1401a8f53) — 여기서 끝점으로 접는 것과 동치이고, 양쪽이 0 이면
    /// x·y 가 같은 u 다항식을 타므로 정확히 선형이 된다.
    ///
    /// 근 찾기는 WE 가 `u=0` 에서 0.999 를 반씩 줄이며 `|X(u)-frame| < 0.01` 프레임에서 멈추는
    /// 이분법이다(VA 0x1401a9d90–0x1401a9e23, 상한 1000회, 이후 `clamp(u, 0, 1)`).
    /// Waple 은 [0,1] 24회 이분법으로 **더 정확히** 푼다 — WE 의 0.01 프레임 허용오차는
    /// 값으로 최대 0.02(위 0→100/60프레임 구간 실측) 만큼 덜 수렴한 값을 낸다.
    private func segment(_ k1: PropertyKeyframe, _ k2: PropertyKeyframe, frame: Float) -> Float {
        let p0x = k1.frame, p0y = k1.value
        let p3x = k2.frame, p3y = k2.value
        let half = 0.5 * (p3x - p0x)
        let p1x = k1.frontEnabled ? p0x + half * k1.frontX : p0x
        let p1y = k1.frontEnabled ? p0y + k1.frontY : p0y
        let p2x = k2.backEnabled ? p3x + half * k2.backX : p3x
        let p2y = k2.backEnabled ? p3y + k2.backY : p3y
        func bez(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ u: Float) -> Float {
            let m = 1 - u
            return m * m * m * a + 3 * m * m * u * b + 3 * m * u * u * c + u * u * u * d
        }
        // x(u) = frame 를 이분법으로(단조 가정; 핸들이 구간을 벗어나도 수렴).
        var lo: Float = 0, hi: Float = 1
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if bez(p0x, p1x, p2x, p3x, mid) < frame { lo = mid } else { hi = mid }
        }
        return bez(p0y, p1y, p2y, p3y, (lo + hi) / 2)
    }

    /// `options.wraploop` 후처리(VA 0x1401a98b0–0x1401a9b90, 호출부 VA 0x1401a5762–0x1401a5793).
    /// 에디터 라벨이 그대로 규약이다 — "Sets the last frame of the animation equal to the first
    /// frame, resulting in a smooth loop that ends exactly where it starts"
    /// (`locale/ui_en-us.json: ui_editor_animation_modal_loop_wrap_help_body`).
    ///
    /// 1. `frame > length` 인 꼬리 키프레임을 버린다(키프레임 2개 미만이 되면 중단).
    /// 2. 남은 마지막이 `frame == length` 면 그 자리를 덮고, 아니면 `frame = length` 키프레임을 붙인다.
    /// 3. 그 끝점의 **value = 첫 키프레임의 value**, **back 핸들 = −(첫 키프레임의 front 핸들)**
    ///    (VA 0x1401a9b58 `xorps` 부호반전, 0x1401a9b5f 저장, 0x1401a9b8b 에서 value 저장).
    ///    첫 키프레임의 front 가 disabled 면 끝점의 back 도 disabled 다(VA 0x1401a9b66 `and eax,~1`).
    ///
    /// 도달: 동봉·설치본 애니 블록 7개 중 **2개**가 `wraploop: true`
    /// (`assets/scenes/particleelementpreviews/maintaindistancebetweencontrolpoints/scene.json`,
    /// length 60 인데 마지막 키프레임이 frame 30 — 미적용이면 타임라인 **후반 절반이 정지**한다.
    /// 실측 최대 차이 291.0 = 값 범위 전체).
    ///
    /// - Note: WE 는 2번의 "덮기" 경로에서 flags bit0 만 지우고 backX/backY 는 남긴다. Waple 의
    ///   평가기는 `backEnabled` 를 게이트로 쓰므로 그 잔존값이 실효하지 않는다 — 동봉 자산 도달 0
    ///   (wraploop 두 블록 모두 마지막 키프레임이 length 와 달라 "붙이기" 경로).
    static func wrapLooped(_ track: [PropertyKeyframe], lengthFrames: Float) -> [PropertyKeyframe] {
        guard track.count > 1, let first = track.first else { return track }
        var out = track
        while out.count > 1, let last = out.last, last.frame > lengthFrames { out.removeLast() }
        guard out.count > 1 else { return out }
        let backEnabled = first.frontEnabled
        let backX = backEnabled ? -first.frontX : 0
        let backY = backEnabled ? -first.frontY : 0
        let lastIndex = out.count - 1
        if out[lastIndex].frame == lengthFrames {
            let l = out[lastIndex]
            out[lastIndex] = PropertyKeyframe(
                frame: l.frame, value: first.value,
                frontEnabled: l.frontEnabled, frontX: l.frontX, frontY: l.frontY,
                backEnabled: backEnabled, backX: backEnabled ? backX : l.backX,
                backY: backEnabled ? backY : l.backY, step: l.step)
        } else {
            out.append(PropertyKeyframe(
                frame: lengthFrames, value: first.value,
                frontEnabled: false, frontX: 0, frontY: 0,
                backEnabled: backEnabled, backX: backX, backY: backY))
        }
        return out
    }

    /// 마커 크로싱 검출(순수): 누적 프레임이 (prevF, curF] 구간을 지나는 동안 통과한 마커 이름들(통과 시각순).
    /// 누적 프레임 F = 재생초 × fps × rate — 모드 무관 단조 증가 클록(draw 루프가 틱마다 전달).
    /// - single/clamp: 각 마커는 평생 1회(F 가 마커를 지나는 단 한 번 — 경계 포함 prevF < m ≤ curF).
    ///   frame 0 마커는 최초 틱에 발화(호출측 초기 prevF = -1 규약; 젤다 item_start/surprise 가 frame 0).
    /// - loop: 주기 L 확장(m + kL). mirror: 주기 2L, 위상 {m, 2L−m}(왕복 — 양방향 각 1회).
    /// - 랩당 1회 보장: 한 틱이 여러 주기를 건너뛰면(가림 복귀 등) 마지막 한 주기만 발화(폭주 방지).
    /// - 일시정지: draw 정지로 틱 자체가 없음 + curF ≤ prevF 가드(재개 시 startTime 시프트로 F 연속).
    ///
    /// **엔진 대조**(VA 0x1401a9ff5–0x1401aa016): WE 는 마커 시각을 **초**로 들고 있고
    /// (`event.t = frame × (1/fps)`, 파스 VA 0x1401a9540 `mulss xmm0, xmm6`), 순방향 발화 조건이
    /// `oldTime <= e.t < newTime` 인 **반대쪽 반개구간**이다. 여기는 `prevF < m ≤ curF` 로 닫는다 —
    /// 초기 prevF = -1 규약과 맞물려 frame 0 마커가 최초 틱에 발화하려면 오른쪽이 닫혀야 한다.
    /// 경계 한 틱의 차이라 실물 마커(젤다 40지점)에서 관측 가능한 차이가 없다.
    public static func firedMarkers(events: [AnimationMarker], length: Float, mode: String,
                                    prevF: Float, curF: Float) -> [String] {
        guard curF > prevF, !events.isEmpty else { return [] }
        // 위상 누적은 **Double** 로 한다(공개 시그니처는 Float 유지 — 호출부가 Float 를 넘긴다).
        // 종전 구현은 이 산술을 전부 Float 로 했는데, Float32 는 가수 24비트라 t 가 2^24 를 넘으면
        // ulp(t) > period 가 되어 `t += period` 가 **무연산**이 된다. 이 루프의 유일한 탈출 조건이
        // `t <= curF` 라서 렌더 스레드가 영원히 돈다 — 수치 확인: 30fps·period == 1 프레임이면
        // curF ≈ 2^24 = 가동 6.47일, period == 8 이면 ~52일. 아래 `((lo - p) / period)` 의
        // `.rounded(.down) + 1` 역시 2^24 위에서 +1 이 흡수돼 같은 지점에서 무너진다.
        var hits: [(t: Double, i: Int, name: String)] = []
        if (mode == "loop" || mode == "mirror"), length > 0 {
            let len = Double(length)
            let period = mode == "loop" ? len : 2 * len
            let cur = Double(curF)
            let lo = max(Double(prevF), cur - period)  // ponytail: 큰 틱 갭은 마지막 한 주기만 — WE 실측 불가, 폭주 방지 우선
            for (i, e) in events.enumerated() {
                var phases: [Double]
                if mode == "loop" {
                    var p = Double(e.frame).truncatingRemainder(dividingBy: period)
                    if p < 0 { p += period }
                    phases = [p]
                } else {
                    let m = min(max(Double(e.frame), 0), len)
                    phases = (m == 0 || m == len) ? [m] : [m, 2 * len - m]
                }
                for p in phases {
                    // 첫 히트 t = p + k·period > lo 부터 curF 이하 전부.
                    var t = p + max(((lo - p) / period).rounded(.down) + 1, 0) * period
                    // 2차 방어선(하드 상한). lo = max(prevF, curF - period) 라 스캔 구간 길이는
                    // **최대 한 주기**이고 히트 간격이 정확히 period 이므로, 위상당 히트는 구조적으로
                    // 1회(경계 부동소수 오차로 2회)를 넘을 수 없다. Double 전환으로 무한루프 자체는
                    // 사라졌지만, 문서화된 "폭주 방지" 의도를 코드로 못박아 period 가 비정상적으로
                    // 작아지는 어떤 경로에서도 이 루프가 프레임을 잡아먹지 못하게 한다.
                    var iter = 0
                    while t <= cur && iter < 4 {
                        if t > lo { hits.append((t, i, e.name)) }
                        t += period
                        iter += 1
                    }
                }
            }
        } else {  // single/clamp(+길이 0 안전): 단조 통과 1회
            for (i, e) in events.enumerated() where prevF < e.frame && e.frame <= curF {
                hits.append((Double(e.frame), i, e.name))
            }
        }
        return hits.sorted { $0.t == $1.t ? $0.i < $1.i : $0.t < $1.t }.map { $0.name }
    }

    /// 바인딩 딕셔너리 {"animation": {...}, "value": ...} → PropertyAnimation. 형식 이상 → nil.
    public static func parse(_ binding: [String: Any]) -> PropertyAnimation? {
        guard let a = binding["animation"] as? [String: Any] else { return nil }
        // 공용 유한-검사 파서(Double/Int 만 — 키프레임 규약). NaN/Inf/Float 범위 밖 → nil → 바인딩 드롭.
        // (종전 로컬 구현은 isFinite 미검사였으나 JSON 표준상 NaN/Inf 리터럴 불가라 실입력 도달 희박.)
        func f(_ v: Any?) -> Float? { strictFloat(v) }
        func keyframes(_ arr: Any?) -> [PropertyKeyframe]? {
            guard let list = arr as? [[String: Any]] else { return nil }
            var out: [PropertyKeyframe] = []
            for k in list {
                guard let frame = f(k["frame"]), let value = f(k["value"]) else { return nil }
                let front = k["front"] as? [String: Any] ?? [:]
                let back = k["back"] as? [String: Any] ?? [:]
                out.append(PropertyKeyframe(
                    frame: frame, value: value,
                    frontEnabled: (front["enabled"] as? Bool) ?? false,
                    frontX: f(front["x"]) ?? 0, frontY: f(front["y"]) ?? 0,
                    backEnabled: (back["enabled"] as? Bool) ?? false,
                    backX: f(back["x"]) ?? 0, backY: f(back["y"]) ?? 0,
                    // step: 이 키프레임이 오른쪽인 구간을 계단으로(파스 VA 0x1401a8f56–0x1401a8fb2).
                    step: (k["step"] as? Bool) ?? false))
            }
            // WE 는 **정렬하지 않고** `frame <= 직전 frame` 인 키프레임을 버린다(VA 0x1401a8fc1
            // `cmp eax, [rsp+0xe8]` / `jle`, 초기 비교값 -1 → frame < 0 도 탈락). Waple 은 정렬로
            // 관용한다 — 동봉·설치본 애니 블록 7개는 전수 오름차순이라 도달 0 이고, 정렬 쪽이
            // 어긋난 저작을 조용히 버리는 대신 그리기 때문이다.
            return out.sorted { $0.frame < $1.frame }
        }
        var tracks: [[PropertyKeyframe]] = []
        // G-D2-8: 트랙은 **4개**다. WE 의 프로퍼티 바인딩 파서가 `c0`/`c1`/`c2`/`c3` 를 차례로
        // FindMember 한다(원본 .rdata 의 네 키가 연속 배치). 4성분 프로퍼티(이펙트 패스의 float4
        // `constantshadervalues` 등)에 키프레임이 걸리면 종전엔 넷째 채널이 정적값으로 굳었다.
        // 네 키의 문자열이 .rdata 에 연속 배치돼 있다(0x14048eef4 "c0" / …eef8 "c1" / …eefc "c2" /
        // 0x14048ef00 "c3", 4바이트 간격) — 조회부 VA 0x1401a560e–0x1401a5691.
        for key in ["c0", "c1", "c2", "c3"] {
            // 누락 성분은 빈 트랙으로 자리 유지(value(component:) 가 위치 인덱싱).
            // WE 는 여기서 **캐스케이드로 중단**한다(VA 0x1401a56dd/0x1401a5701/0x1401a5720/
            // 0x1401a573e: 각 채널이 배열이 아니면 뒤를 통째 버린다) — c0 이 없으면 트랙 0개,
            // c0+c2 면 c2 유실. Waple 은 자리를 지켜 관용한다: 동봉·설치본 애니 7블록이 전수
            // c0(+c1+c2) 연속이라 **도달 0** 이고, 비연속 저작에서 조용히 채널을 잃는 쪽이 나쁘다.
            guard a[key] != nil else { tracks.append([]); continue }
            guard let t = keyframes(a[key]) else { return nil }
            tracks.append(t)
        }
        while tracks.last?.isEmpty == true { tracks.removeLast() }
        guard !tracks.isEmpty else { return nil }
        let opts = a["options"] as? [String: Any] ?? [:]
        // 이벤트 마커: options.events[] = {frame, name}(실물 3737268876). 형식 이상 항목은 드롭.
        let events: [AnimationMarker] = ((opts["events"] as? [[String: Any]]) ?? []).compactMap { e in
            guard let name = e["name"] as? String, let frame = f(e["frame"]) else { return nil }
            return AnimationMarker(name: name, frame: frame)
        }
        // fps / length 는 WE 에서 **필수**다 — 옵션 파서가 둘 다 숫자 타입(1..3)이 아니면 false 를
        // 돌리고(VA 0x1401a9714–0x1401a972d), `fps <= 0` 이나 `length/fps <= 0` 이어도 false 라
        // (VA 0x1401a8c21 / 0x1401a8c43) 호출부가 **애니 전체를 버린다**(VA 0x1401a56c0 `je`).
        // Waple 은 30fps · 마지막 키프레임 길이로 기워 넣는다: 동봉·설치본 7블록 전수가 fps·length
        // 를 모두 적어 도달 0 이고, 부재 시 정지시키는 쪽이 더 나쁜 실패다.
        let length = f(opts["length"]) ?? (tracks.compactMap { $0.last?.frame }.max() ?? 0)
        // wraploop 은 **bool 일 때만** 선다(VA 0x1401a985d `cmp byte ptr [rbx+8], 5`) —
        // 실물에 흔한 `"wraploop": null` 은 타입 0 이라 세워지지 않는다(설치본 7블록 중 5개가 null).
        let wrapLoop = (opts["wraploop"] as? Bool) ?? false
        // 길이는 엔진에서 i32 다(`asInt` VA 0x1401a9815) — 소수 길이는 0 방향 절단.
        let lengthFrames = length.rounded(.towardZero)
        if wrapLoop {
            tracks = tracks.map { wrapLooped($0, lengthFrames: lengthFrames) }
        }
        return PropertyAnimation(
            tracks: tracks,
            fps: f(opts["fps"]) ?? 30,
            length: length,
            // G-D2-6: **부재 기본값은 loop 다.** WE 애니 헤더 초기화가 flags 를 0 으로 두고
            // `"mirror"` 일 때만 `|= 0x1`, `"single"` 일 때만 `|= 0x2` 를 세운다 — 즉 `mode` 가
            // 없거나 `"loop"` 면 둘 다 0 이고, 에디터가 아는 모드 집합이 {loop, single, mirror}
            // 3개뿐이므로 0 은 배타적으로 loop 다. 종전 `?? "single"` 은 mode 를 생략한 애니를
            // 마지막 키프레임에서 정지시켰다(회전 프로펠러·깜빡임·스크롤이 첫 사이클 뒤 멈춤).
            mode: (opts["mode"] as? String) ?? "loop",
            // WE 는 `relative` **키의 존재만** 보고 base 를 키프레임 값에 더해 굽는다
            // (VA 0x1401a53a3 `test rax,rax` — bool 값을 읽지 않는다. 굽기 VA 0x1401a89a0).
            // 즉 `"relative": false` 도 상대로 취급된다. Waple 은 bool 을 읽는다 — 설치본에서
            // `relative` 는 1회 등장하고 값이 true 라 **도달 0**, 그리고 false 를 상대로 읽는 쪽이
            // 저작 의도에 반한다. (베이스 합산 자체는 동치다: 베지어가 value 에 대해 아핀이라
            // 키프레임마다 b 를 더하나 결과에 b 를 더하나 같다.)
            relative: (a["relative"] as? Bool) ?? false,
            events: events,
            // C⑤: startpaused(=스크립트 play() 전까지 정지) — 부재/false 는 종전대로 무조건 재생(무회귀).
            // 엔진에서도 이 비트(flags 0x20000000, VA 0x1401a8cb0)가 시간 진행을 통째로 막는다
            // (VA 0x1401a9f73 `test r14d, 0x60000000` → 즉시 return), 그래서 값이 frame 0 에 고정된다.
            startPaused: (opts["startpaused"] as? Bool) ?? false,
            wrapLoop: wrapLoop)
    }
}
