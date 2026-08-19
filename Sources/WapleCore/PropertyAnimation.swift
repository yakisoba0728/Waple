import Foundation

/// 프로퍼티 키프레임(실물 스키마): frame 위치, 값, 앞/뒤 베지어 핸들(프레임/값 오프셋).
/// lockangle/locklength 는 에디터 UX(핸들 편집 제약)라 재생엔 불필요 — 핸들 좌표에 이미 반영돼 있다.
public struct PropertyKeyframe: Equatable {
    public let frame: Float
    public let value: Float
    public let frontEnabled: Bool
    public let frontX: Float
    public let frontY: Float
    public let backEnabled: Bool
    public let backX: Float
    public let backY: Float

    public init(frame: Float, value: Float, frontEnabled: Bool, frontX: Float, frontY: Float,
                backEnabled: Bool, backX: Float, backY: Float) {
        self.frame = frame; self.value = value
        self.frontEnabled = frontEnabled; self.frontX = frontX; self.frontY = frontY
        self.backEnabled = backEnabled; self.backX = backX; self.backY = backY
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

/// 씬 오브젝트 프로퍼티 애니메이션(성분별 트랙 c0..c2). 순수 평가기 — TDD.
public struct PropertyAnimation: Equatable {
    public let tracks: [[PropertyKeyframe]]
    public let fps: Float
    public let length: Float     // frames
    public let mode: String      // "single"(끝 클램프) | "loop"(랩) | "mirror"(왕복 — 젤다 sky change)
    public let relative: Bool    // true 면 base + v
    public let events: [AnimationMarker]   // options.events 마커(없으면 빈 배열)
    /// C⑤: options.startpaused — 스크립트가 play() 하기 전까지 정지(frame 0) 상태로 저작됐다는 계약
    /// (lib.sceneScript.d.ts IAnimation.play "Start playing the animation if it's paused or stopped").
    /// play()/pause() 런타임 제어(스크립트 트리거 연결)는 미구현이라 이 값이 true 인 애니는 항상 frame 0
    /// 값으로 고정 평가된다 — WE 는 트리거 전까지 이 상태이므로 "영구 미발화"보다 "즉시 재생+고착"보다
    /// 정합적(마운트 직후 다수 상태와 일치). 트리거 이후 값은 여전히 미반영(별건 — caveats 참조).
    public let startPaused: Bool

    public init(tracks: [[PropertyKeyframe]], fps: Float, length: Float, mode: String, relative: Bool,
                events: [AnimationMarker] = [], startPaused: Bool = false) {
        self.tracks = tracks; self.fps = fps; self.length = length; self.mode = mode; self.relative = relative
        self.events = events; self.startPaused = startPaused
    }

    /// t(초) 시점의 성분 값. 트랙 없음 → base 유지. startPaused → 항상 frame 0(C⑤).
    public func value(component: Int, atTime t: Float, base: Float) -> Float {
        guard component < tracks.count, !tracks[component].isEmpty else { return base }
        let track = tracks[component]
        var frame = (startPaused ? 0 : t) * fps
        if mode == "loop", length > 0 {
            frame = frame.truncatingRemainder(dividingBy: length)
            if frame < 0 { frame += length }
        } else if mode == "mirror", length > 0 {
            // 왕복: 2L 주기 폴드 — firedMarkers/PuppetPose.frame 과 동일 규약(감사 V01).
            frame = frame.truncatingRemainder(dividingBy: 2 * length)
            if frame < 0 { frame += 2 * length }
            if frame > length { frame = 2 * length - frame }
        } else {
            frame = max(0, min(frame, length))
        }
        let raw = evaluate(track: track, frame: frame)
        return relative ? base + raw : raw
    }

    private func evaluate(track: [PropertyKeyframe], frame: Float) -> Float {
        if frame <= track[0].frame { return track[0].value }
        if let last = track.last, frame >= last.frame { return last.value }
        for i in 0..<(track.count - 1) {
            let k1 = track[i], k2 = track[i + 1]
            guard frame >= k1.frame, frame <= k2.frame else { continue }
            return segment(k1, k2, frame: frame)
        }
        return track[0].value
    }

    /// 큐빅 베지어 구간: P0=(k1.f,k1.v), P1=P0+front, P2=P3+back, P3=(k2.f,k2.v).
    /// disabled 핸들 → 끝점과 동일(양쪽 disabled = 선형과 동치). x 는 단조 → 이분법으로 t̂ 해석.
    private func segment(_ k1: PropertyKeyframe, _ k2: PropertyKeyframe, frame: Float) -> Float {
        let p0x = k1.frame, p0y = k1.value
        let p3x = k2.frame, p3y = k2.value
        let p1x = k1.frontEnabled ? p0x + k1.frontX : p0x
        let p1y = k1.frontEnabled ? p0y + k1.frontY : p0y
        let p2x = k2.backEnabled ? p3x + k2.backX : p3x
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

    /// 마커 크로싱 검출(순수): 누적 프레임이 (prevF, curF] 구간을 지나는 동안 통과한 마커 이름들(통과 시각순).
    /// 누적 프레임 F = 재생초 × fps × rate — 모드 무관 단조 증가 클록(draw 루프가 틱마다 전달).
    /// - single/clamp: 각 마커는 평생 1회(F 가 마커를 지나는 단 한 번 — 경계 포함 prevF < m ≤ curF).
    ///   frame 0 마커는 최초 틱에 발화(호출측 초기 prevF = -1 규약; 젤다 item_start/surprise 가 frame 0).
    /// - loop: 주기 L 확장(m + kL). mirror: 주기 2L, 위상 {m, 2L−m}(왕복 — 양방향 각 1회).
    /// - 랩당 1회 보장: 한 틱이 여러 주기를 건너뛰면(가림 복귀 등) 마지막 한 주기만 발화(폭주 방지).
    /// - 일시정지: draw 정지로 틱 자체가 없음 + curF ≤ prevF 가드(재개 시 startTime 시프트로 F 연속).
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
                    backX: f(back["x"]) ?? 0, backY: f(back["y"]) ?? 0))
            }
            return out.sorted { $0.frame < $1.frame }
        }
        var tracks: [[PropertyKeyframe]] = []
        for key in ["c0", "c1", "c2"] {
            // 누락 성분은 빈 트랙으로 자리 유지(value(component:) 가 위치 인덱싱) — break 는
            // c1/c2 만 있는 애니를 통째 드롭하고 c0+c2 에서 c2 를 유실한다.
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
        return PropertyAnimation(
            tracks: tracks,
            fps: f(opts["fps"]) ?? 30,
            length: f(opts["length"]) ?? (tracks.compactMap { $0.last?.frame }.max() ?? 0),
            mode: (opts["mode"] as? String) ?? "single",
            relative: (a["relative"] as? Bool) ?? false,
            events: events,
            // C⑤: startpaused(=스크립트 play() 전까지 정지) — 부재/false 는 종전대로 무조건 재생(무회귀).
            startPaused: (opts["startpaused"] as? Bool) ?? false)
    }
}
