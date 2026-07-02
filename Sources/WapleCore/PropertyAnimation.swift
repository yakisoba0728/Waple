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

/// 씬 오브젝트 프로퍼티 애니메이션(성분별 트랙 c0..c2). 순수 평가기 — TDD.
public struct PropertyAnimation: Equatable {
    public let tracks: [[PropertyKeyframe]]
    public let fps: Float
    public let length: Float     // frames
    public let mode: String      // "single"(끝 클램프) | "loop"(랩) — 실측 코퍼스의 전부
    public let relative: Bool    // true 면 base + v

    public init(tracks: [[PropertyKeyframe]], fps: Float, length: Float, mode: String, relative: Bool) {
        self.tracks = tracks; self.fps = fps; self.length = length; self.mode = mode; self.relative = relative
    }

    /// t(초) 시점의 성분 값. 트랙 없음 → base 유지.
    public func value(component: Int, atTime t: Float, base: Float) -> Float {
        guard component < tracks.count, !tracks[component].isEmpty else { return base }
        let track = tracks[component]
        var frame = t * fps
        if mode == "loop", length > 0 {
            frame = frame.truncatingRemainder(dividingBy: length)
            if frame < 0 { frame += length }
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

    /// 바인딩 딕셔너리 {"animation": {...}, "value": ...} → PropertyAnimation. 형식 이상 → nil.
    public static func parse(_ binding: [String: Any]) -> PropertyAnimation? {
        guard let a = binding["animation"] as? [String: Any] else { return nil }
        func f(_ v: Any?) -> Float? {
            if let d = v as? Double { return Float(d) }
            if let i = v as? Int { return Float(i) }
            return nil
        }
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
            guard a[key] != nil else { break }
            guard let t = keyframes(a[key]) else { return nil }
            tracks.append(t)
        }
        guard !tracks.isEmpty else { return nil }
        let opts = a["options"] as? [String: Any] ?? [:]
        return PropertyAnimation(
            tracks: tracks,
            fps: f(opts["fps"]) ?? 30,
            length: f(opts["length"]) ?? (tracks.compactMap { $0.last?.frame }.max() ?? 0),
            mode: (opts["mode"] as? String) ?? "single",
            relative: (a["relative"] as? Bool) ?? false)
    }
}
