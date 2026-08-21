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
///
/// **보간 종류는 둘뿐이다 — 큐빅 베지어와 계단(step). 이징 열거형은 존재하지 않는다**
/// (2026-08-21 클러스터 AF, 상수 **적재** 자리를 셌다 — 호출 자리가 아니다).
/// 키프레임 파서 `0x1401a8ce0–0x1401a940c` 안에서 flags 레지스터(`r13d`)에 상수를 넣는 자리는
/// **정확히 넷**이다: `mov r13d, 4`(0x1401a8fed, step) · `xor r13d, r13d`(0x1401a8ff8, 없음) ·
/// `mov r13d, 1`(0x1401a9050, back) · `or r13d, 2`(0x1401a90dd, front). 저장은
/// `mov [r14+8], r13d`(0x1401a9148)와 `mov [rsi+rbp+8], r13d`(0x1401a9257) 둘. 즉 flags 워드가
/// 가질 수 있는 값은 `{0,1,2,3,4}` 뿐이고 **커브 타입 태그가 들어갈 자리가 없다**.
/// 에디터의 `beziermode` 는 여섯 가지지만(`["both","left","right","none","magic"]`
/// scripts.js char@554808 + `"step"` char@566452) 전부 이 세 비트 + 핸들 좌표로 접힌다 —
/// `magic` 은 저작 시점에 이웃 프레임 간격으로 핸들 x/y 를 자동 배치하는 것뿐이고
/// (char@556010 `a.back.magic&&(a.back.x=-.5-s,a.back.y=-.1*r)`), 그 결과가 좌표에 구워진다.
public struct PropertyKeyframe: Equatable {
    public let frame: Float
    public let value: Float
    /// flags bit1. **런타임 평가기는 이 비트를 읽지 않는다**(2026-08-21 클러스터 AF 확정).
    /// 키프레임 배열을 stride **0x1c** 로 인덱싱하는 함수는 `imul r,r,0x1c` 전수 스캔으로 넷뿐이고
    /// (파서 0x1401a8ce0 · `wrapLoop` 0x1401a98b0 · 평가기 0x1401a9bc0 · 벡터 복사 0x1401aa430),
    /// 그 넷 안에서 키프레임 flags 를 **읽는** 명령은 딱 둘이다: `test r10b, 2`(0x1401a9b48 —
    /// `wrapLoop` 이 **첫** 키프레임의 bit1 을 보고 끝점 back 을 만들지 결정) 와
    /// `test byte ptr [r10+r11+8], 4`(0x1401a9d18 — 평가기의 step). 복사 함수는 flags 를 아예 안
    /// 본다. **bit0 은 넷 어디서도 읽히지 않는다** — 쓰기만 셋이다(파서 `mov r13d,1` 0x1401a9050 ·
    /// `wrapLoop` 의 `or eax,1` 0x1401a9b51 / `and eax,0xfffffffe` 0x1401a9b66).
    /// 즉 `enabled` 는 **파스 시점에 x/y 를 읽을지**만 정하고, 곡선은 언제나 x/y 만 본다.
    public let frontEnabled: Bool
    public let frontX: Float
    public let frontY: Float
    /// flags bit0. 위 `frontEnabled` 주석 참조 — **읽는 자리가 하나도 없다.**
    public let backEnabled: Bool
    public let backX: Float
    public let backY: Float
    /// 계단 보간. **이 키프레임이 구간의 오른쪽**일 때 그 구간 전체가 왼쪽 키프레임 값으로 고정된다
    /// (평가기 VA 0x1401a9d18 `test byte ptr [r10+r11+8], 4` — 읽는 쪽이 오른쪽 키프레임의 flags).
    /// 동봉·설치본 자산 도달 0(애니 블록 7개 전수 미기재)이지만 에디터가 저작한다
    /// (`beziermode === 'step'` → `keyframe.step = true`).
    ///
    /// - Important: 실물 파서는 `step` 이 서면 **핸들을 아예 읽지 않는다**(0x1401a8fe8 →
    ///   `mov r13d, 4` 0x1401a8fed → `jmp 0x1401a910a`). 그래서 `PropertyAnimation.parse` 가
    ///   내놓는 step 키프레임은 항상 `frontEnabled == backEnabled == false` 이고 네 좌표가 0 이다.
    ///   생성자는 이 불변식을 강제하지 않는다 — `wrapLooped` 의 덮기 경로가 실물처럼
    ///   "flags bit0 만 지우고 bit2·핸들 잔존값은 보존" 하는지 테스트가 직접 조립해 확인하기
    ///   때문이다(실물 0x1401a9b66 `and eax, 0xfffffffe`).
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

    // **`options.random` 은 이 빌드에서 죽은 비트다 — 반증 기록(2026-08-21).**
    // 종전 주석은 "런타임 상태의 몫이라 미구현" 이라고만 했는데, 실제로는 **WE 자신이 읽지 않는다**.
    //   ① 파서는 정상이다 — `find "random"`(0x1401a9777) → `cmp byte ptr [rsi+8], 5`(0x1401a97f9)
    //      → `asBool`(0x140086300) → 5번째 인자로 넘겨(0x1401a9850) `or dword ptr [rbx+0xc], 4`
    //      (0x1401a8ca5) 로 flags bit2 를 세운다. 여기까지는 형제 5키와 완전히 같은 모양이다.
    //   ② **소비가 없다.** flags 워드는 옵션 구조체 `+0xc`(= 애니 객체 `+0x44`) 한 자리뿐이라
    //      읽는 쪽은 `[X+0xc]` 이나 `[X+0x44]` 로드를 거칠 수밖에 없다. `.text` 전체
    //      (4,344,320바이트 · 재동기 선형 스윕 1,146,785 명령)를 `.pdata` 병합 함수 단위로 훑어
    //      그런 로드에서 시작해 **함수 끝까지** 레지스터 복사를 따라가며 bit2 가 선 즉시값으로
    //      `test`/`and`/`bt`/`cmp` 하는 자리를 전수 수집하면 바이너리 전체 54건이고 **애니 코드에는
    //      0건**이다. 애니 영역 유일 히트 0x1401aa147 `and dword ptr [rbx+0xc], 0x7fffffff` 는
    //      미러 방향비트를 지우는 마스크라 bit2 를 **보존**한다(읽지 않는다).
    //      애니 상태 flags 를 실제로 읽는 자리는 이게 전부이고 전부 다른 비트다 —
    //      0x1401a9f69 로드 → 0x1401a9f73(bit29|30) · 0x1401a9f88(bit1 single) ·
    //      0x1401a9fb7 `shr r12d, 0x1f`(bit31 역주행) · 0x1401aa055(bit0 mirror);
    //      0x1401aa147·0x1401aa165(bit31 토글) · 0x1401aa181(bit30 single 종료);
    //      0x1401a5762(bit4 wraploop); 스크립트 IAnimation 제어 0x1401707f7·0x14017080e(play) ·
    //      0x140170827(pause) · 0x140170837·0x140170845(stop) · 0x140170867(isPlaying)은
    //      bit29/30 만 만진다.
    //      **고정 창 스윕으로는 이 판정을 못 한다** — 로드 0x1401a9f69 에서 bit0 검사 0x1401aa055
    //      까지가 65 명령이라 20명령 창이면 대조군(mirror)조차 못 찾는다. 종전 주석이 그 창으로
    //      "대조군을 전부 찾아낸다" 고 적었던 것은 사실이 아니다(2026-08-21 재검증에서 정정).
    //      함수 전체 추적으로 바꾸면 대조군 bit0·bit1·bit4·bit29/30 이 전부 잡히고 bit2 만 0 이다.
    //   ③ 에디터도 안 쓴다 — 로케일에 `ui_editor_animation_modal_random_start_frame`
    //      ("Random start frame")이 남아 있지만 `ui/` 전체에서 그 키를 참조하는 곳이 **0건**이다
    //      (형제 `..._start_paused` 1건 · `..._loop_wrap` 3건 — `grep -ro` 전수 실측).
    //      애니 옵션 화이트리스트에도 없다: 퍼펫 `case"length":case"fps":case"wraploop":
    //      case"smoothing":case"stiffness":case"mode":case"events"`(scripts.js char@235954),
    //      카메라경로는 같은 형태에서 `wraploop`/`mode`/`events` 만(char@281098).
    //   ④ 자산 도달 0 — 동봉·설치본 애니 7블록 전수에 키 자체가 없다.
    // 그래서 파스도 소비도 하지 않는다. 세 층(런타임·에디터·자산) 모두에서 흔적만 남은 키라
    // 의미를 확정할 근거가 없고, 추측 구현은 무회귀를 깬다. WE 가 이 비트를 되살리면
    // 그때 시작 프레임 난수화를 붙일 자리는 평가기가 아니라 마운트 시점의 시간 오프셋이다.

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
            // `length <= 0` 은 이제 `parse` 가 nil 로 떨어뜨리므로(VA 0x1401a8c43 — 아래 parse 주석)
            // **파스 경로에서는 죽은 가지**다. 공개 `init` 으로 직접 조립한 애니만 여기 닿는다 —
            // `truncatingRemainder(dividingBy: 0)` 가 NaN 을 뱉는 것을 막는 방어선으로 남긴다.
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
    ///
    /// 경계 세 자리는 실물과 명령 단위로 대조했다(2026-08-21 재검증, 클러스터 K):
    /// - `frame <= kf[0].frame` → `kf[0].value` (VA 0x1401a9cb8 `cmp ebx,[r10]` / `jg` 로
    ///   "첫 키프레임보다 크지 않으면" 그 자리에서 `[r10+4]` 를 돌려준다).
    /// - `frame >= kf[n-1].frame` → `kf[n-1].value` (탐색 인덱스가 `count` 까지 올라간 뒤
    ///   VA 0x1401a9cf5 `jg 0x1401a9ec7` → `imul rax,(i-1),0x1c` → `[r10+rax+4]`).
    ///   키프레임 1개짜리 트랙은 두 분기가 같은 값을 준다.
    /// - 키프레임 0개 트랙은 WE 가 **0.0** 을 돌려준다(VA 0x1401a9bfd `cmp [rcx],rax` → `xorps`).
    ///   Waple 은 `value(component:)` 에서 base 를 유지한다. **이 갈림은 이 타입 안에서 닫을 수
    ///   없다**(2026-08-21 클러스터 Q 재평가 — 종전 "누락 채널 관용과 짝" 이라는 근거보다 강한
    ///   구조적 이유가 있다):
    ///   * WE 가 실제로 쓰는 규칙은 "빈 트랙 → 0.0" 이 아니라 **트랙 수 == 프로퍼티 성분 수**
    ///     라는 전부-아니면-전무 게이트다. 등록기가 서술자 태그를 성분 수로 바꿔
    ///     (1→2 · 2→3 · 3→4 · 그 외 1, 0x140176750–0x140176771) 트랙 수
    ///     `([r15+0x28]-[r15+0x20])/0x30` 와 `sete`(0x14017679e) 로 비교해 `[anim+0x18]` 에 굽고,
    ///     per-frame 소비자가 그 바이트가 0 이면 트랙을 **한 번도 평가하지 않는다**
    ///     (0x14017241f `cmp byte ptr [rbx+0x18], 0` → `je 0x1401726ad`).
    ///     즉 c0+c2 처럼 채널이 비면 WE 는 "c1 만 잃는" 게 아니라 **애니 전체가 꺼져** 정적
    ///     `value` 로 떨어진다(캐스케이드 0x1401a56dd 로 트랙 수가 1 이 되고 vec3 성분 수 3 과
    ///     어긋나기 때문이다).
    ///   * `PropertyAnimation` 은 프로퍼티의 성분 수를 모른다 — 그건 `origin`(vec3)인지
    ///     `alpha`(float)인지 아는 `SceneDocument` 의 정보다. 그래서 WE 의 게이트를 여기 옮길 수
    ///     없고, 게이트 없이 0.0 만 돌리면 **누락 채널이 base 대신 0 으로 눌린다** — 실물이 하지
    ///     않는 일이다(실물은 그 경우 애니를 끈다).
    ///   * WE 에서 이 0.0 분기에 실제로 닿는 유일한 입력은 **명시적 빈 배열** `"cN": []` 다
    ///     (키프레임 파서 0x1401a8ce0 은 빈 배열에서 false 를 돌리지만 호출부가 반환값을 보지
    ///     않고 그대로 push 한다 — 0x1401a56ec/0x1401a56fc). Waple 은 그 입력에서 트랙을
    ///     비워 두고, 뒤가 전부 비면 `parse` 가 nil 을 돌려 정적 `value` 로 떨어진다.
    ///   동봉·설치본 코퍼스 도달 0(트랙 19개 전수가 키프레임 2개, 빈 배열 0건).
    ///   성분 수 게이트를 정말 옮기려면 `parse` 에 프로퍼티 성분 수를 넘겨야 한다 —
    ///   docs/re/property-animation.md §6 의 넘길 것 참조.
    private func evaluate(track: [PropertyKeyframe], frame: Float) -> Float {
        if frame <= track[0].frame { return track[0].value }
        guard let last = track.last else { return 0 }
        if frame >= last.frame { return last.value }
        for i in 1..<track.count {
            let k1 = track[i - 1], k2 = track[i]
            guard k1.frame <= frame, frame < k2.frame else { continue }
            // 왼쪽 끝점에 정확히 앉으면 곡선을 풀지 않고 그 값이다(VA 0x1401a9d0f
            // `cmp r9d, ebx` → `je 0x1401a9ec0` → `mov eax,[r10+r11-0x18]` = kf[i-1].value).
            // step 분기와 **같은 타깃**이다. WE 는 정수 프레임만 평가해서 이 분기가 키프레임마다
            // 매번 걸리지만, Waple 은 연속 프레임이라 정확히 맞을 때만 걸린다. 단조 X(u) 에서는
            // 이분법이 어차피 u≈0 으로 수렴해 같은 값이고, `front.x < 0` 처럼 X(u) 가 구간 앞으로
            // 튀어나가는 저작에서만 갈린다(동봉 코퍼스 front.x 전수 양수 — 도달 0).
            if k1.frame == frame { return k1.value }
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
    /// **`enabled` 비트를 여기서 보지 않는다**(2026-08-21 클러스터 AF 에서 고쳤다). 실물 평가기
    /// 0x1401a9bc0 은 제어점을 조립할 때 flags 를 **step(bit2) 하나만** 본다(0x1401a9d18) —
    /// `mulss xmm9,[r10+r11-8]`(k1.frontX) · `mulss xmm8,[r10+r11+0xc]`(k2.backX) ·
    /// `addss xmm0,[r10+r11-4]`(k1.frontY) · `addss xmm0,[r10+r11+0x10]`(k2.backY) 넷이 전부
    /// **무조건** 실행된다. disabled 핸들이 접히는 것은 **파서**가 x/y 를 아예 읽지 않아 0 으로
    /// 남기 때문이다(0x1401a8fd1 의 `xorps xmm6/7/8/9` → 0x1401a8ffb/0x1401a907f 의 `test`
    /// 로 읽기 블록을 건너뜀). 그래서 `parse` 쪽에서 0 을 굽고 여기서는 좌표를 그대로 쓴다.
    ///
    /// 종전 구현은 반대로 파스에서 좌표를 담고 **여기서** `enabled` 로 접었다. 코퍼스에서는
    /// 동치지만(76/76 이 명시 bool + 좌표 일치) `wrapLooped` 의 **덮기 경로**에서 갈렸다:
    /// 그 경로는 실물처럼 flags bit0 만 지우고 backX/backY 를 남기는데(0x1401a9b66), 평가기가
    /// bit0 을 안 보므로 **실물에서는 그 잔존 좌표가 그대로 곡선을 휜다**. 합성 반례
    /// (`kf0{front disabled}`, `kf1{frame == length, back{-1, +20}}`, `wraploop`)에서 frame 31 값이
    /// **10.000000 ↔ 18.888773** 으로 갈렸다. 코퍼스 도달 0(덮기 경로 자체가 0건).
    ///
    /// 근 찾기는 WE 가 `u=0` 에서 0.999 를 반씩 줄이며 `|X(u)-frame| < 0.01` 프레임에서 멈추는
    /// 이분법이다(VA 0x1401a9d90–0x1401a9e23, 상한 1000회, 이후 `clamp(u, 0, 1)`).
    /// Waple 은 [0,1] 24회 이분법으로 **더 정확히** 푼다 — WE 의 0.01 프레임 허용오차는
    /// 값으로 최대 0.02(위 0→100/60프레임 구간 실측) 만큼 덜 수렴한 값을 낸다.
    private func segment(_ k1: PropertyKeyframe, _ k2: PropertyKeyframe, frame: Float) -> Float {
        let p0x = k1.frame, p0y = k1.value
        let p3x = k2.frame, p3y = k2.value
        let half = 0.5 * (p3x - p0x)
        let p1x = p0x + half * k1.frontX
        let p1y = p0y + k1.frontY
        let p2x = p3x + half * k2.backX
        let p2y = p3y + k2.backY
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

    /// `options.wraploop` 후처리(VA 0x1401a98b0–0x1401a9bb3, 호출부 VA 0x1401a5762–0x1401a5793).
    /// 엔진 시그니처는 `void wrapLoop(int lengthFrames /*ecx*/, vector<Keyframe>* track /*rdx*/)` 다 —
    /// 호출부가 `mov ecx, [r13+0x48]`(0x1401a5780) · `mov rdx, rbx`(0x1401a5784) 로 넘기고
    /// 트랙 벡터를 stride **0x30** 으로 순회한다(Track = `vector<Keyframe>`+0x00 · 프레임 캐시
    /// `vector<float>`+0x18). 키프레임 stride 는 **0x1c**(0x1401a98d9 의 `imul rax, 0x6db6…db7`
    /// = ÷7 후 0x1401a98fb `imul rax, rax, 0x1c`).
    /// 에디터 라벨이 그대로 규약이다 — "Sets the last frame of the animation equal to the first
    /// frame, resulting in a smooth loop that ends exactly where it starts"
    /// (`locale/ui_en-us.json: ui_editor_animation_modal_loop_wrap_help_body`).
    ///
    /// 1. `frame > length` 인 꼬리 키프레임을 버린다(1개가 남으면 거기서 멈춘다 — 0x1401a9935 `jbe`).
    ///    그 뒤 개수가 다시 2 미만이면 **아무것도 쓰지 않고** 반환한다(0x1401a996e `jbe 0x1401a9b90`).
    ///    버린 것을 되돌리지는 않는다 — vector 의 end 포인터를 이미 줄여 놨다(0x1401a993e).
    /// 2. 남은 마지막이 `frame == length` 면 그 자리를 덮고, 아니면 `frame = length` 키프레임을 붙인다.
    ///    붙이는 쪽은 `{frame=length, 나머지 전부 0}` 으로 초기화되므로 front 는 disabled, step 은 0 이다.
    /// 3. 그 끝점의 **value = 첫 키프레임의 value**, **back 핸들 = −(첫 키프레임의 front 핸들)**
    ///    (VA 0x1401a9b58 `xorps` 부호반전, 0x1401a9b5f 저장, 0x1401a9b8b 에서 value 저장).
    ///    첫 키프레임의 front 가 disabled 면 끝점의 back 도 disabled 다(VA 0x1401a9b66 `and eax,~1`).
    ///
    /// **샘플러의 "마지막→처음 랩어라운드" 가 아니다.** 흔한 오독이라 못박아 둔다: WE 는 평가기에
    /// 순환 구간을 넣지 않는다. 위 세 단계는 전부 **파스 시점에 키프레임 배열 자체를 다시 쓰는**
    /// 후처리이고(호출부가 트랙 벡터를 stride 0x30 으로 순회한다 — 0x1401a5769–0x1401a5793),
    /// 평가기(0x1401a9bc0)와 시간 진행(0x1401a9f60)은 bit4 를 아예 읽지 않는다. 그래서
    /// - 끝점의 들어오는 핸들은 첫 키프레임의 `back` 이 아니라 **`front` 를 부호반전한 것**이다
    ///   (0x1401a9b48 `test r10b, 2` = 첫 키프레임 flags bit1 → 0x1401a9b58 `xorps` 부호마스크
    ///   0x140492ff0 `{0x80000000}×4` → 0x1401a9b5f `movsd [rcx-0x10]` 로 backX·backY 동시 저장).
    ///   첫 키프레임의 `back` 을 그대로 쓰면(순환 보간의 자연스러운 오독) 다른 곡선이 나온다.
    ///   **접선까지 같아지는 것은 조건부다** — 이 파일의 제어점 규약은 `P1 = P0 + (0.5·dx·front.x,
    ///   front.y)` / `P2 = P3 + (0.5·dx·back.x, back.y)` 라 x 성분에 구간폭 `dx` 가 곱해진다.
    ///   그래서 끝점의 나가는 기울기가 frame 0 의 들어오는 기울기와 **정확히** 같아지는 것은
    ///   마지막 구간폭이 첫 구간폭과 같을 때뿐이다. 동봉 두 블록은 키프레임이 0/30 이고 끝점이
    ///   60 이라 `dx` 가 둘 다 30 — 정확히 맞는다. 일반 저작에서는 "핸들 부호반전" 이지
    ///   "기울기 일치" 가 아니다(에디터 라벨의 *smooth* 는 전자를 가리킨다).
    /// - `frame > length` 인 키프레임은 **파괴된다** — 순환 보간 해석에는 없는 부작용이다.
    /// - `frame == length` 가 이미 있으면 붙이는 게 아니라 **덮는다**(front 핸들과 step 비트는 보존).
    ///
    /// **`mode` 와 직교한다.** 호출부는 flags bit4 하나만 보고 mode 비트(bit0 mirror/bit1 single)를
    /// 보지 않는다 — `parse` 의 wraploop 주석 참조. `"loop"` 강제는 에디터 저작 측 제약이다.
    ///
    /// 도달(2026-08-21 재측정 — 동봉 트리와 설치본 `assets/` 는 같은 집합, `projects/` 는 애니 0건):
    /// 애니 블록 **7개 / 파일 6개**, `wraploop` 키는 7/7 에 있고 값은 `true` 2 · `null` 5.
    /// `true` 2블록은 둘 다 같은 파일
    /// `scenes/particleelementpreviews/maintaindistancebetweencontrolpoints/scene.json` 의
    /// `/objects/0/origin` 과 `/objects/1/instanceoverride/controlpoint1` 이고, 저장소 규약상
    /// **non-preview** 다(경로 세그먼트 중 `preview` 로 **시작**하는 것이 없다 —
    /// `particleelementpreviews` 는 `particle` 로 시작한다). `null` 5블록은 preview 4 +
    /// non-preview 1(`presets/magic/preset.json`)이다.
    ///
    /// **코퍼스 도달과 Waple 파스 도달**(2026-08-21 후속 — 클러스터 M 이
    /// `instanceoverride` 애니 드롭을 고쳤다). `SceneDocument.parseObject` 는 오브젝트 애니를
    /// `["origin","scale","alpha","angles","color"]` 다섯 키에서만 캡처하지만,
    /// `instanceoverride` 아래 바인딩은 이제 `SceneParticle.instanceOverrideAnimations` 로
    /// 보존된다(`SceneDocumentFidelityTests.testInstanceOverrideAnimationBindingIsCaptured`).
    /// 그래서 `true` 2블록은 **둘 다** 이 후처리를 탄다 — `/objects/0/origin` 과
    /// `/objects/1/instanceoverride/controlpoint1`. 도달 0 인 `null` 블록 중
    /// `effects/blendgradient/preview/.../constantshadervalues/multiply` 는
    /// `constantAnimations`(SceneDocument.swift:2839) 경로로 도달한다.
    ///
    /// 실측 어긋남: 두 블록 다 `length: 60` 인데 키프레임이 `frame 0`/`frame 30` 뿐이라
    /// 미적용이면 타임라인 **후반 절반이 정지**한다. `/objects/1/…/controlpoint1` 의 c1 은
    /// `436.42032 → 145.37645` 라 끝점 복귀 폭이 **291.04387 = 값 범위 전체**,
    /// `/objects/0/origin` 의 c1 은 `0 → -126.1462` 라 126.1462 다.
    /// **Waple 은 이제 둘 다 본다**(클러스터 M 의 `instanceoverride` 캡처 이후). 전자의
    /// `436.42032 → 145.37645` 트랙은 `PropertyAnimation` 평가로 실제 재현되는 것이
    /// 독립 확인됐다(클러스터 M 이 테스트로 잠갔다).
    ///
    /// - Note: WE 는 2번의 "덮기" 경로에서 flags bit0 만 지우고(0x1401a9b66 `and eax, 0xfffffffe`)
    ///   backX/backY 는 남긴다. Waple 의 평가기는 `backEnabled` 를 게이트로 쓰므로 그 잔존값이
    ///   실효하지 않는다 — 동봉 자산 도달 0(wraploop 두 블록 모두 마지막 키프레임이 length 와
    ///   달라 "붙이기" 경로). 그래도 잔존값 자체는 보존한다(엔진과 필드 단위로 일치시켜 두면
    ///   나중에 라운드트립·비교가 생겨도 갈리지 않는다).
    /// - Note: **`length` 의 i32 화는 닫혔다**(2026-08-21 클러스터 Q). WE 는 `length` 를
    ///   `asInt`(0x1401a9815 → 0x140085ee0, 태그 3 은 `cvttsd2si` 0x140085f12 = 0 방향 절단)로
    ///   **한 번** 정수화하고 그 정수 하나가 끝점 프레임(`[r13+0x48]` → 0x1401a5780)에도
    ///   루프 주기(`+0x08 = (float)length/fps`, 0x1401a8c37–0x1401a8c46)에도 쓰인다.
    ///   종전 Waple 은 끝점만 절단하고 `PropertyAnimation.length` 는 Float 를 유지해
    ///   `length: 45.9` 에서 끝점 45 · 랩 45.9 로 갈렸다 — 이제 `parse` 가 한 번 절단해
    ///   `length` 자체를 정수로 만든다(도달 0: 코퍼스 `length` 전수 정수 60×6 · 30×1).
    ///   키프레임 `frame` 도 같은 규약으로 닫았다(`asInt` 0x1401a8fb5 → 파스에서 0 방향 절단).
    ///   잔여 어긋남: 태그 1/2(int/uint)에서 실물은 `mov eax,[rcx]` 로 하위 32비트만 취한다.
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
    ///
    /// **스키마 전집합**(2026-08-21 클러스터 K 재측정 — 동봉 트리 + 설치본 `assets/`·`projects/`
    /// JSON **3,655개** 전수, JSONC(주석·후행 콤마) 관용 파서로 파스 실패 0):
    /// `"animation"` 객체는 **14블록**(동봉 7 + `assets/` 7, 두 트리 같은 집합 · `projects/` 0),
    /// 파일 6개. 애니 객체 키는 `c0`(7/7) · `options`(7/7) · `c1`(6/7) · `c2`(6/7) ·
    /// `relative`(1/7, bool `true`) 뿐이고 **`c3` 는 0** 이다.
    /// `options` 키는 `fps`·`length`·`mode`·`wraploop` **넷뿐**이고
    /// (`fps` = 20×4/30×2/15×1 · `length` = 60×6/30×1 · `mode` = loop 6/mirror 1 ·
    ///  `wraploop` = `true` 2/`null` 5), **`random`·`startpaused`·`events` 는 0/7** 이다.
    /// 키프레임 키는 `frame`(i32 ×38) · `value`(×38) · `front`(×38) · `back`(×38) ·
    /// `lockangle`(×38) · `locklength`(×38) — **`step` 은 0** 이다.
    /// 핸들 키는 `enabled`(bool ×76) · `x`(×76) · `y`(×76) · `magic`(bool ×56).
    ///
    /// 파서가 실제로 읽는 키는 이 전집합의 **부분집합**이다. 옵션 파서(0x1401a96b0)가
    /// `Json::Value::find` 하는 것은 정확히 여섯 — `length`(0x1401a96d2) · `fps`(0x1401a96f8) ·
    /// `mode`(0x1401a9744) · `random`(0x1401a9777) · `startpaused`(0x1401a979d) ·
    /// `wraploop`(0x1401a97c3) 이고, `events` 는 **옵션 파서 안이 아니라** 바인딩 파서가
    /// 같은 `options` 노드에서 따로 찾는다(0x1401a57a3, 태그 6 배열일 때만 0x1401a9410 호출).
    /// 키프레임 파서(0x1401a8ce0)는 `value`·`frame`·`back`·`front`·`enabled`·`x`·`y`·`step`
    /// 여덟만 읽는다. 따라서 **`lockangle`·`locklength`·`magic` 은 파스되지 않는다** —
    /// 세 문자열은 `wallpaper64.exe`·`scenescript64.dll`·`resourceutil64.dll`·
    /// `cloneextensions64.dll`·`resourcecompiler64.exe`·`diagnostics64.exe` **어디에도 없다**
    /// (ASCII·UTF-16LE 전수 검색 0건 — `beziermode` 도 마찬가지다). 에디터 JS 전용이다.
    public static func parse(_ binding: [String: Any]) -> PropertyAnimation? {
        guard let a = binding["animation"] as? [String: Any] else { return nil }
        // 공용 유한-검사 파서(Double/Int 만 — 키프레임 규약). NaN/Inf/Float 범위 밖 → nil → 바인딩 드롭.
        // (종전 로컬 구현은 isFinite 미검사였으나 JSON 표준상 NaN/Inf 리터럴 불가라 실입력 도달 희박.)
        //
        // **불리언은 숫자가 아니다.** 애니 스키마에서 숫자를 읽는 자리는 여덟이고 전부
        // `movzx eax,[X+8]; dec eax; cmp eax,2; ja` 로 **jsoncpp 태그 1..3(int/uint/real)만**
        // 통과시킨다 — `value`/`frame`(0x1401a8e73 / 0x1401a8e83) · 핸들 `x`/`y` 네 자리
        // (0x1401a904c · 0x1401a9069 · 0x1401a90d9 · 0x1401a90f4) · `options.length`/`fps`
        // (0x1401a9714 / 0x1401a9723) · `events[].frame`(0x1401a9511). 태그 5(bool)는 전부 탈락이다.
        // 그런데 리눅스 Foundation 은 `bool` 도 `NSNumber` 로 주고 `as? Double` 이 **1.0 을
        // 돌려준다**(실측: `{"a":true}` → `strictFloat` == `Optional(1.0)`, `as? Int` == `Optional(1)`).
        // `isJSONBool` 게이트가 없으면 `{"x": true}` 가 핸들 좌표 1.0 이 되어 원본(0)과 갈린다.
        // 이 게이트를 붙이면 갈림이 어떻게 닫히는지는 자리마다 다르다:
        //   · 핸들 `x`/`y`, `events[].frame` → **원본과 정확히 일치**(전자는 0, 후자는 항목 드롭).
        //   · `value`/`frame` → 이제 **원본과 정확히 일치**한다(그 키프레임만 건너뛴다 —
        //     2026-08-21 클러스터 Q, 아래 `keyframes` 주석의 `0x1401a9319` 확정).
        //   · `options.length`/`fps` → 원본은 "애니 전체 드롭" 이고 Waple 은 "기본값
        //     (30 / 마지막 프레임)" 이라 여전히 다르다(부재 관용과 같은 자리 — 아래 참조).
        //     적어도 **불리언을 숫자로 읽지는 않는다**(이 파일이 이미 택한 관용 정책과 일관).
        // 동봉·설치본 코퍼스 도달 **0** — 위 여덟 자리의 값 타입 census 가 전건 int/float 이다
        // (`frame` int×38 · `value` int11/float27 · 핸들 `x` int52/float24 · `y` int46/float30 ·
        //  `fps` int×7 · `length` int×7 · `events` 0건). 그래서 코퍼스 위에서 **비트 동일**이다.
        func f(_ v: Any?) -> Float? { EffectManifest.isJSONBool(v) ? nil : strictFloat(v) }
        // **애니 스키마의 bool 여섯 자리는 전부 `cmp byte ptr [..+8], 5` 로 jsoncpp 태그를 먼저
        // 보지만, 검사가 실패했을 때 무엇이 되는지는 두 부류로 갈린다.** 종전 주석은 여섯을 한
        // 덩어리로 묶고 "태그 5 아니면 전부 false" 라고 적었는데 **틀렸다**(2026-08-21 재검증에서
        // 디스어셈으로 반증). 실제 분기 타깃은 이렇다:
        //
        //   | 자리 | 태그 검사 | 실패 분기 | 부재/비-bool 결과 |
        //   |---|---|---|---|
        //   | `options.wraploop`    | 0x1401a985d | `jne 0x1401a9887`(or 건너뜀) | **false** |
        //   | `options.startpaused` | 0x1401a97df | `jne 0x1401a97f6` → `xor r13d,r13d` | **false** |
        //   | `options.random`      | 0x1401a97f9 | `jne 0x1401a9810` → `xor edi,edi`  | **false** |
        //   | 키프레임 `step`        | 0x1401a8f77 | `jne 0x1401a8faf` → `xor sil,sil`  | **false** |
        //   | `back.enabled`        | 0x1401a8ebb | `jne 0x1401a8eed` → **`mov bpl,1`**  | **true** |
        //   | `front.enabled`       | 0x1401a8f1c | `jne 0x1401a8f4e` → **`mov r14b,1`** | **true** |
        //
        // 즉 핸들 두 자리만 **폴라리티가 반대**다. `back`/`front` 가 객체(태그 7)이기만 하면
        // (바깥 검사 0x1401a8e94 `cmp byte ptr [r15+8], 7` / 0x1401a8ef5 `cmp byte ptr [r14+8], 7`)
        // `enabled` 는 **기본 켜짐**이고, 끄는 방법은 **진짜 bool `false` 하나뿐**이다.
        // (r15 = `back`(find 0x1401a8e2d) · r14 = `front`(find 0x1401a8e54) — 이름 대응도 종전
        //  주석이 뒤집어 적었다.) 핸들 자체가 없거나 객체가 아니면 disabled 다.
        //
        // **태그 게이트 자체는 장식이 아니라 하중을 받는다** — `asBool`(0x140086300)은 관대해서
        // 태그 1/2 를 `cmp qword ptr [rcx], 0; setne al`(0x14008634b)로, 태그 3(real)을 double
        // 비교(0x14008632e)로 받아 **`1` 을 true 로 돌려준다**. 태그 0(null)만
        // `xor al,al`(0x14008635a). 앞단 태그 검사가 없었다면 WE 도 `"wraploop": 1` 을 true 로
        // 읽었을 것이다. 그래서 `false` 부류 네 자리에는 이 게이트가 필요하고,
        // `true` 부류 두 자리에는 **게이트를 그대로 옮기면 오히려 원본과 갈린다**(아래 handleEnabled).
        //
        // 종전 Waple 은 맨 `as? Bool` 이었고 이게 원본과 **반대로 갈리는 입력**이 있다.
        // Foundation 의 `JSONSerialization` 은 숫자와 불리언을 똑같이 `NSNumber` 로 주고 Swift 의
        // 동적 캐스트가 둘을 섞는다 — 리눅스 실측: `{"wraploop":1}` → `as? Bool` == **true**,
        // `{"wraploop":1.0}` → **true**(`{"wraploop":"true"}`·`null` 은 nil 이라 우연히 맞았다).
        // 즉 `"wraploop": 1` 한 줄이 WE 에서는 무시되는데 Waple 에서는 트랙을 통째로 다시 쓰게 했다.
        // `EffectManifest.isJSONBool` 이 이미 `NSNumber.objCType == "c"` 로 이 구분을 하고 있어
        // 그대로 재사용한다.
        //
        // **동봉·설치본 도달 0** — 애니 7블록의 bool 값을 전수 타입 census 하면
        // `wraploop` null×5 / bool×2, `front`/`back` 의 `enabled` 는 **양면 합쳐 bool×76**
        // (키프레임 38 × 2면, 전부 진짜 bool), `step`·`random`·`startpaused` 는 아예 없다.
        // 숫자·문자열로 적힌 bool 도, `enabled` 를 생략한 핸들도 한 건도 없으므로 이 게이트도
        // 아래 `handleEnabled` 도 코퍼스 위에서 **비트 동일**이고, 손으로 저작된 값만 갈린다.
        func b(_ v: Any?) -> Bool { EffectManifest.isJSONBool(v) && (v as? Bool) == true }
        /// 핸들(`front`/`back`)의 `enabled` — 위 표의 **true 부류**. 객체가 아니면 disabled,
        /// 객체면 `enabled` 가 진짜 bool 일 때만 그 값을 쓰고 **부재·비-bool 은 enabled** 다
        /// (VA 0x1401a8ebb back / 0x1401a8f1c front, 실패 분기가 `mov …,1`).
        ///
        /// 종전 트리의 미커밋 변경은 여기에도 `b()` 를 걸어 **원본과 반대로** 만들었다 —
        /// `{"front":{"x":1,"y":5}}`(enabled 생략)를 WE 는 그 핸들로 곡선을 휘게 읽는데
        /// `b()` 를 걸면 직선이 된다. 그 변경 **직전** 코드(`(v as? Bool) == true`)는
        /// `"enabled": 1` 에서는 우연히 원본과 같았고 부재에서는 역시 틀렸다.
        /// 코퍼스 도달 0(76/76 이 명시 bool)이라 어느 쪽도 동봉 자산을 바꾸지 않지만,
        /// 원본과 갈리는 방향으로 굳힐 이유가 없어 실물 규칙을 그대로 옮긴다.
        func handleEnabled(_ h: [String: Any]?) -> Bool {
            guard let h = h else { return false }   // 태그 7 아님 → disabled
            let e = h["enabled"]
            return EffectManifest.isJSONBool(e) ? ((e as? Bool) == true) : true
        }
        func keyframes(_ arr: Any?) -> [PropertyKeyframe]? {
            // 배열(태그 6)이 아니면 nil — 호출부가 애니 전체를 드롭한다. WE 는 여기서
            // **캐스케이드로 중단**하지만(0x1401a56dd 등) 결과는 같다: 남은 트랙 수가 프로퍼티
            // 성분 수와 어긋나 등록기가 애니를 통째로 끈다(아래 `parse` 말미의 §도달 주석).
            guard let list = arr as? [Any] else { return nil }
            var out: [PropertyKeyframe] = []
            for element in list {
                // **비객체 원소는 그 항목만 건너뛴다.** WE 는 원소마다 `find`(0x1401a8ddb 등)를
                // 걸고 그 결과 태그로만 판정하므로, 객체가 아닌 원소는 `value`/`frame` 이 태그 0
                // 으로 잡혀 아래 태그 게이트에서 그대로 탈락한다(= 항목 건너뜀).
                guard let k = element as? [String: Any] else { continue }
                // **`value`/`frame` 이 숫자가 아니면 그 키프레임만 건너뛴다** — 실물의 두 태그
                // 게이트 `dec eax; cmp eax,2; ja`(0x1401a8e7d `value` · 0x1401a8e8e `frame`)의
                // 분기 타깃 `0x1401a9319` 는 **함수 탈출이 아니라 루프 진행부**다(거기서
                // `[rbx+0x10]`/`[rbx+8]` 로 red-black 트리 이터레이터를 전진시키고
                // 0x1401a9356/0x1401a938c 에서 루프 머리 `0x1401a8db6` 로 되돌아간다).
                // 즉 나머지 키프레임은 정상으로 남고 트랙 자체는 살아 있다. 2026-08-21 클러스터 Q
                // 재검증에서 확정 — 종전 Waple 은 여기서 `return nil` 로 **애니 전체**를 버렸다.
                // 같은 규약이 `frame <= 직전 frame` 드롭(0x1401a8fc1 `jle 0x1401a9311`)에도 쓰인다.
                // (코퍼스 도달 0: `frame` int×38 · `value` int11/float27 — 전건 숫자다.)
                guard let rawFrame = f(k["frame"]), let value = f(k["value"]) else { continue }
                // 키프레임 `frame` 은 엔진에서 **i32** 다 — `asInt`(0x1401a8fb5 → 0x140085ee0)가
                // 태그 3(real)을 `cvttsd2si`(0x140085f12) 로 **0 방향 절단**하고, 저장부가
                // `mov dword ptr [r14], r12d`(0x1401a9145) 로 구조체 +0x00 에 i32 로 굽는다.
                // 평가기도 `int frame` 을 받는다(`movsxd rbp, edx` 0x1401a9be3).
                // 코퍼스 도달 0(frame 전수 int). 잔여 어긋남: 태그 1/2(int/uint)일 때 실물은
                // `mov eax,[rcx]`(0x140085f1e)로 **하위 32비트만** 취해 2^31 이상에서 감싼다 —
                // 여기서는 감싸지 않는다.
                let frame = rawFrame.rounded(.towardZero)
                // step: 이 키프레임이 오른쪽인 구간을 계단으로(파스 VA 0x1401a8f56–0x1401a8fb2).
                let step = b(k["step"])
                // **step 이 서면 WE 는 핸들을 아예 읽지 않는다** — `test sil,sil`(0x1401a8fe8) 이
                // 참이면 `mov r13d, 4`(0x1401a8fed) 로 flags 를 bit2 **하나만** 세우고
                // `jmp 0x1401a910a` 로 `back`/`front` 블록 두 개를 통째로 건너뛴다. 네 좌표는
                // 진입부의 `xorps xmm6/7/8/9`(0x1401a8fd1–0x1401a8fdc)가 깔아 둔 0 으로 남고,
                // flags 의 bit0(back)·bit1(front)도 서지 않는다. 즉 저장된 키프레임은
                // `{frame, value, flags=4, 0,0,0,0}` 이다(저장부 0x1401a9127–0x1401a9148).
                //
                // **관측 가능한 자리는 이 키프레임의 *오른쪽* 구간이다.** step 은 자기 왼쪽 구간을
                // 계단으로 만드니 그쪽에선 핸들이 어차피 안 쓰이지만, `front` 는 **다음 구간**
                // `[k_step, k_next]` 의 P1 을 정한다. 종전 Waple 은 step 키프레임의 `front` 를
                // 그대로 담아 그 다음 구간이 원본과 다른 곡선이 됐다.
                // `back` 은 이 키프레임이 트랙의 **마지막**이고 `wraploop` 이 켜졌을 때만 드러난다 —
                // 덮기 경로가 flags bit0 만 지우고 backX/backY 는 남기기 때문이다(0x1401a9b66).
                // (동봉·설치본 코퍼스 도달 **0** — `step` 키는 애니 7블록 38키프레임 어디에도 없다.
                //  에디터는 `beziermode === 'step'` 으로 저작한다.)
                // (`nil` 을 흘리면 `handleEnabled` 가 disabled 를, `f(nil?[…])` 가 0 을 준다 —
                //  실물의 "안 읽는다" 와 필드 단위로 같은 결과다.)
                let front = step ? nil : k["front"] as? [String: Any]
                let back = step ? nil : k["back"] as? [String: Any]
                // **disabled 핸들의 x/y 는 읽지 않는다** — 실물 파서는 진입부에서
                // `xorps xmm6/7/8/9`(0x1401a8fd1–0x1401a8fdc)로 네 좌표를 0 으로 깔고,
                // `test bpl,bpl`(0x1401a8ffb, back.enabled) / `test r14b,r14b`(0x1401a907f,
                // front.enabled)가 거짓이면 `find("x")`/`find("y")` 블록을 **통째로 건너뛴다**
                // (각각 `je 0x1401a907f` / `je 0x1401a910a`). 저장부(0x1401a912d–0x1401a9139,
                // 0x1401a913f)는 그 0 을 그대로 굽는다.
                // 종전 Waple 은 여기서 좌표를 담고 `segment()` 에서 `enabled` 로 접었다 —
                // 코퍼스 위에서는 동치지만 `wrapLooped` 덮기 경로에서 갈렸다(`segment` 주석).
                let frontOn = handleEnabled(front)
                let backOn = handleEnabled(back)
                out.append(PropertyKeyframe(
                    frame: frame, value: value,
                    frontEnabled: frontOn,
                    frontX: frontOn ? (f(front?["x"]) ?? 0) : 0,
                    frontY: frontOn ? (f(front?["y"]) ?? 0) : 0,
                    backEnabled: backOn,
                    backX: backOn ? (f(back?["x"]) ?? 0) : 0,
                    backY: backOn ? (f(back?["y"]) ?? 0) : 0,
                    step: step))
            }
            // WE 는 **정렬하지 않고** `frame <= 직전 frame` 인 키프레임을 버린다(VA 0x1401a8fc1
            // `cmp eax, [rsp+0xe8]` / `jle`, 초기 비교값 -1 → frame < 0 도 탈락). Waple 은 정렬로
            // 관용한다 — 동봉·설치본 애니 블록 7개는 전수 오름차순이라 도달 0 이고, 정렬 쪽이
            // 어긋난 저작을 조용히 버리는 대신 그리기 때문이다.
            //
            // 정렬은 **안정**이어야 한다. `frame` 을 i32 로 절단하면서 서로 다른 저작 프레임이
            // 같은 정수로 겹칠 수 있게 됐는데(`10.2`/`10.9` → 둘 다 10), Swift 의 `sorted(by:)`
            // 는 동률 순서를 보장하지 않는다. 원래 인덱스를 2차 키로 써 동률에서 저작 순서를
            // 유지한다 — 그래야 "중복 시각은 **마지막 중복**이 왼쪽 끝점" 이라는 평가기 규약
            // (`evaluate` 주석 · `testTrackBoundaryCases`)이 결정적이 된다.
            // 실물은 겹친 둘 중 **앞의 것**을 남긴다(뒤가 `jle` 로 탈락) — 여기서는 뒤가 이긴다.
            // 코퍼스 도달 0(frame 전수 int, 트랙마다 서로 다른 2개).
            return out.enumerated()
                .sorted { $0.element.frame == $1.element.frame ? $0.offset < $1.offset
                                                              : $0.element.frame < $1.element.frame }
                .map { $0.element }
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
            // c0+c2 면 c2 유실. **그리고 거기서 끝이 아니다**: 트랙 수가 프로퍼티 성분 수와
            // 어긋나면 등록기가 `[anim+0x18] = 0`(0x1401767a1)을 굽고 per-frame 소비자가
            // 애니를 통째로 건너뛴다(0x14017241f) — 즉 실물은 "채널 하나 유실" 이 아니라
            // **애니 전체 무효 → 정적 `value`** 다(자세한 대조는 `evaluate` 주석).
            // Waple 은 성분 수를 모르므로 그 게이트를 옮길 수 없다. 자리를 지켜 관용한다:
            // 동봉·설치본 애니 7블록이 전수 c0(+c1+c2) 연속이라 **도달 0** 이고, 비연속 저작에서
            // 조용히 채널을 잃는 쪽이 나쁘다.
            guard a[key] != nil else { tracks.append([]); continue }
            guard let t = keyframes(a[key]) else { return nil }
            tracks.append(t)
        }
        while tracks.last?.isEmpty == true { tracks.removeLast() }
        guard !tracks.isEmpty else { return nil }
        // WE 는 `options` 자체가 **객체(태그 7)여야** 애니를 만든다 — 옵션 파서 진입부가
        // `cmp byte ptr [rcx+8], 7`(0x1401a96bb)로 걸러 false 를 돌리고, 호출부도 파서를 부르기 전에
        // 같은 검사를 한 번 더 한다(0x1401a56a6 `cmp byte ptr [r15+8], 7` → `jne 0x1401a57e1`).
        // 즉 `options` 부재/비객체는 **애니 전체 드롭**이다. Waple 은 빈 딕셔너리로 관용한다 —
        // 아래 `length`/`fps` 와 같은 이유(동봉·설치본 7블록 전수가 options 객체를 갖고 있어 도달 0,
        // 그리고 정지시키는 쪽이 더 나쁜 실패)다.
        let opts = a["options"] as? [String: Any] ?? [:]
        // 이벤트 마커: options.events[] = {frame, name}(실물 3737268876). 형식 이상 항목은 드롭.
        let events: [AnimationMarker] = ((opts["events"] as? [[String: Any]]) ?? []).compactMap { e in
            guard let name = e["name"] as? String, let frame = f(e["frame"]) else { return nil }
            return AnimationMarker(name: name, frame: frame)
        }
        // fps / length 는 WE 에서 **필수**다 — 옵션 파서가 둘 다 숫자 타입(1..3)이 아니면 false 를
        // 돌리고(VA 0x1401a9714–0x1401a972d), `fps <= 0` 이나 `length/fps <= 0` 이어도 false 라
        // (VA 0x1401a8c21 / 0x1401a8c43) 호출부가 트랙을 **하나도 파스하지 않고**
        // (VA 0x1401a56c0 `test al,al` → `je 0x1401a57e1`) 그 결과 애니가 통째로 무효가 된다
        // (성분 수 게이트 — 아래 ③).
        // Waple 은 **타입이 어긋나거나 부재일 때만** 30fps · 마지막 키프레임 길이로 기워 넣는다:
        // 동봉·설치본 7블록 전수가 fps·length 를 모두 적어 도달 0 이고, 부재 시 정지시키는 쪽이
        // 더 나쁜 실패다. **퇴화 값(`<= 0`)은 아래에서 `nil` 로 떨어뜨린다** — 그건 부재가 아니라
        // 명시된 "재생 불가" 이고, 실물도 그 값에서 애니를 무효화한다.
        //
        // `length` 는 엔진에서 **i32** 다 — 옵션 파서가 `asInt`(0x1401a9815)로 **한 번** 정수화해
        // (태그 3 은 `cvttsd2si` = 0 방향 절단, 0x140085f12) 그 정수를 `init` 의 `r8d` 로 넘기고
        // (0x1401a984d), `init` 은 그걸 상태 구조체 `+0x10` 에 그대로 쓰고(0x1401a8c1d)
        // `(float)length / fps` 를 `+0x08`(초 단위 길이)에 쓴다(0x1401a8c37–0x1401a8c46).
        // 즉 **끝점 프레임(wraploop `[r13+0x48]`)과 루프/미러 주기(`+0x08`)가 같은 정수**다.
        // 종전 Waple 은 `wrapLooped` 끝점만 절단하고 `length` 는 Float 로 남겨 `length: 45.9` 에서
        // 끝점 45 · 랩 주기 45.9 로 갈렸다 — 여기서 한 번 절단해 두 자리를 다시 붙인다.
        // 코퍼스 도달 0(`length` 전수 정수 60×6 · 30×1).
        let length = (f(opts["length"])?.rounded(.towardZero))
            ?? (tracks.compactMap { $0.last?.frame }.max() ?? 0)
        let fps = f(opts["fps"]) ?? 30
        // **`fps <= 0` / `length <= 0` 은 애니가 아예 없는 것과 같다**(2026-08-21 클러스터 Q 확정).
        //   ① `AnimOptions::init`(0x1401a8c10)이 `comiss xmm2(0.0), xmm1(fps)` → `jae 0x1401a8cc4`
        //      (0x1401a8c21)로 **`fps <= 0`** 에서, 그리고 `comiss xmm2(0.0), xmm0(length/fps)` →
        //      `jae`(0x1401a8c43)로 **`length/fps <= 0`** 에서 `xor al,al`(0x1401a8cc9)을 돌린다.
        //      `fps` 는 정확히 0 이든 음수든 **같은 명령 한 자리**에서 걸린다(`0 >= fps`).
        //      두 번째 검사 시점에는 이미 `fps > 0` 이므로 `length/fps <= 0` ⟺ `length <= 0` 이다.
        //   ② 호출부는 `test al,al` → `je 0x1401a57e1`(0x1401a56c0)로 **c0..c3 파스 블록 전체를
        //      건너뛴다** — 트랙 벡터가 비어 있는 채로 남는다.
        //   ③ 그런데 애니 객체는 **버려지지 않는다** — 실패 경로도 성공 경로와 합류해
        //      `0x1401a57e9`에서 등록기 `0x140175880` 에 그대로 넘어간다. 애니를 실제로 끄는 것은
        //      등록기 안의 **성분 수 일치 게이트**다: 프로퍼티 서술자의 태그
        //      (`[r15+0x10]` → `[rcx]`, 0x140176750)를 성분 수로 바꾸고(1→2 · 2→3 · 3→4 · 그 외 1,
        //      0x140176755–0x140176771), 트랙 수 `([r15+0x28]-[r15+0x20])/0x30` 와 비교해
        //      `sete al` → `mov byte ptr [r15+0x18], al`(0x14017679e/0x1401767a1) 을 굽는다.
        //      per-frame 소비자가 그 바이트를 게이트로 쓴다(`cmp byte ptr [rbx+0x18], 0` →
        //      `je 0x1401726ad`, 0x14017241f) — 0 이면 트랙을 한 번도 평가하지 않고 넘어가므로
        //      **바인딩의 정적 `value` 가 그대로 남는다**.
        //      (종전 문서는 이걸 "호출부가 애니를 통째로 버린다" 고 적었는데, 버리는 게 아니라
        //       성분 수 0 ≠ 1..4 로 꺼지는 것이다. 관측 결과는 같다.)
        //   ④ 종전 Waple 은 `"fps": 0` 이면 `frame = t·0 = 0`, `"length": 0` 이면
        //      `max(0, min(frame, 0))` 로 **첫 키프레임 값에 고착**했다 — 정적 `value` 가 아니다.
        //      `nil` 을 돌리면 호출부(`SceneDocument.swift:1827` 등)가 `anims[key]` 를 세우지
        //      않으므로 정적 언랩만 남아 실물과 **정확히 같아진다**.
        // 도달 0(코퍼스 `fps` = 15/20/30 · `length` = 30/60). `length` 절단과 맞물려
        // `"length": 0.5` 도 여기서 걸린다 — 실물도 `asInt` 로 0 이 되어 같은 자리에서 걸린다.
        guard fps > 0, length > 0 else { return nil }
        // wraploop 은 **bool 일 때만** 선다(VA 0x1401a985d `cmp byte ptr [rbx+8], 5` → 0x1401a9881
        // `or dword ptr [r12+0xc], 0x10`) — 실물에 흔한 `"wraploop": null` 은 타입 0 이라 세워지지
        // 않는다(동봉·설치본 7블록 중 5개가 null, 2개가 true).
        //
        // **`mode` 와 직교한다 — 어느 쪽도 상대를 이기지 않는다.** 런타임에는 모드 게이트가
        // 아예 없다: 옵션 파서가 flags bit4 를 mode 와 무관하게 세우고(0x1401a9881), 호출부는
        // `test byte ptr [r13+0x44], 0x10` **하나만** 보고 트랙마다 후처리를 돈다
        // (0x1401a5762–0x1401a5793). 초기화(0x1401a8c10)가 세우는 mirror(bit0)·single(bit1)은
        // 시간 진행(0x1401a9f60)에서만 읽히고 bit4 를 건드리지 않는다. 즉 `wraploop` 은
        // **파스 시점의 키프레임 배열 재작성**이고 `mode` 는 **재생 시점의 클록 정책**이라,
        // `{"mode":"mirror","wraploop":true}` 는 "랩된 트랙을 미러 재생" 으로 둘 다 걸린다.
        // 모드 제약은 **에디터에만** 있다 — 체크박스가 `ng-if="settings.mode === \'loop\'"`
        // (scripts.js char@810392)이고 저장 시 `"loop"!==e.mode&&delete e.wraploop`(char@575499)
        // 라 저작이 막힐 뿐이다. 그래서 여기서도 mode 를 보지 않는다
        // (동봉 도달: `mirror`+wraploop 조합 0건 — `true` 2블록 다 `"loop"`).
        // (scripts.js 오프셋 인용은 이 파일·docs/re/property-animation.md 전부 **문자 오프셋**이다.
        //  파일이 UTF-8 이라 바이트 오프셋과 최대 238 만큼 다르다 — 바이트 1,187,134 / 문자 1,186,896.)
        let wrapLoop = b(opts["wraploop"])
        // `length` 는 위에서 이미 i32 화돼 있다(`asInt` VA 0x1401a9815 → 0 방향 절단) — 끝점
        // 프레임과 루프 주기가 같은 정수를 쓴다. 호출부도 같은 정수를 넘긴다
        // (`mov ecx, dword ptr [r13+0x48]` 0x1401a5780 = 상태 구조체 `+0x10`).
        if wrapLoop {
            tracks = tracks.map { wrapLooped($0, lengthFrames: length) }
        }
        return PropertyAnimation(
            tracks: tracks,
            fps: fps,
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
            startPaused: b(opts["startpaused"]),
            wrapLoop: wrapLoop)
    }
}
