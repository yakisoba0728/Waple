import Foundation
import WapleCore

/// The authored slider metadata used by both the control and its committed value.
struct PropertySliderConfiguration {
    let range: ClosedRange<Double>
    let step: Double
    let decimalPlaces: Int

    init(_ property: WallpaperProperty) {
        let minimum = property.min.flatMap { $0.isFinite ? $0 : nil } ?? 0
        let lower = minimum < Double.greatestFiniteMagnitude ? minimum : 0
        let fallbackMaximum = property.type.lowercased() == "volume" ? 100 : lower + 1
        let maximum = property.max.flatMap { $0.isFinite ? $0 : nil } ?? fallbackMaximum
        let upper = maximum > lower ? maximum : lower.nextUp
        range = lower...upper

        let authoredStep = property.step.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let precision = property.precision {
            decimalPlaces = Swift.min(4, Swift.max(1, precision)) - 1
        } else if let authoredStep {
            decimalPlaces = (0...6).first { places in
                let scaled = authoredStep * pow(10, Double(places))
                return scaled.isFinite && abs(scaled - scaled.rounded()) < 0.0000001
            } ?? 6
        } else {
            decimalPlaces = 0
        }
        let derivedStep = property.fraction == true ? pow(10, -Double(decimalPlaces)) : 1
        step = authoredStep ?? derivedStep
    }

    func clampedValue(_ value: Double) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return Swift.min(range.upperBound, Swift.max(range.lowerBound, value))
    }

    func committedValue(_ value: Double) -> Double {
        let clamped = clampedValue(value)
        let ticks = ((clamped - range.lowerBound) / step).rounded()
        let snapped = range.lowerBound + ticks * step
        return snapped.isFinite ? clampedValue(snapped) : clamped
    }

    func formattedValue(_ value: Double) -> String {
        String(format: "%.*f", decimalPlaces, clampedValue(value))
    }
}
