import Foundation

/// WE VideoWallpaper WM_TIMER 101, 25ms. This models only pause/mute transitions;
/// initial mount and explicit user-volume updates keep their current immediate contract.
struct VideoVolumeRamp {
    static let interval: TimeInterval = 0.025
    private(set) var current: Float
    private(set) var target: Float
    private(set) var paused = false
    private(set) var muted = false
    private(set) var outputEnabled = true
    var goal: Float { paused || muted || !outputEnabled ? 0 : target }
    var isComplete: Bool { current == goal }
    var shouldPauseTransport: Bool { paused && isComplete }

    init(volume: Float) {
        let volume = volume.isFinite ? max(0, min(1, volume)) : 0
        current = volume
        target = volume
    }

    mutating func update(target: Float, paused: Bool, muted: Bool, outputEnabled: Bool) {
        self.target = target.isFinite ? max(0, min(1, target)) : 0
        self.paused = paused
        self.muted = muted
        self.outputEnabled = outputEnabled
        if self.target == 0 || !outputEnabled { current = goal }
    }

    /// Clamp each step at its goal; never let repeated ticks overshoot or oscillate.
    mutating func tick() {
        let goal = goal
        if current > goal { current = max(goal, current - (target * 0.03 + 0.02)) }
        else if current < goal { current = min(goal, current + (target * 0.01 + 0.01)) }
    }
}
