// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation

enum CustomGestureAction: Codable, Equatable, Sendable {
    case keyboardShortcut(TapKeyBinding)
    case typeText(String)

    var summary: String {
        switch self {
        case let .keyboardShortcut(binding):
            return "Keyboard shortcut · \(binding.displayString)"
        case let .typeText(text):
            let singleLine = text.replacingOccurrences(of: "\n", with: "↵")
            let preview = singleLine.count > 36
                ? String(singleLine.prefix(35)) + "…"
                : singleLine
            return "Type text · “\(preview)”"
        }
    }

    var symbol: String {
        switch self {
        case .keyboardShortcut: return "keyboard"
        case .typeText: return "text.cursor"
        }
    }

    var isValid: Bool {
        switch self {
        case let .keyboardShortcut(binding): return binding.isValid
        case let .typeText(text): return !text.isEmpty
        }
    }
}

struct CustomGestureEvent: Codable, Equatable, Sendable {
    let features: [Double]
    /// Zero for the first impact and the elapsed time since the preceding
    /// impact for every later event in the same performance.
    let intervalSincePrevious: TimeInterval

    var isValid: Bool {
        features.count == ImpactFeatures.expectedCount
            && features.allSatisfy(\.isFinite)
            && intervalSincePrevious.isFinite
            && intervalSincePrevious >= 0
    }
}

struct CustomGestureSample: Codable, Equatable, Sendable {
    let events: [CustomGestureEvent]

    var isValid: Bool {
        guard !events.isEmpty, events.allSatisfy(\.isValid) else { return false }
        guard events[0].intervalSincePrevious == 0 else { return false }
        return events.dropFirst().allSatisfy { $0.intervalSincePrevious > 0 }
    }
}

struct CustomGesturePattern: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var action: CustomGestureAction
    let samples: [CustomGestureSample]

    var eventCount: Int {
        samples.first?.events.count ?? 0
    }

    var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmedName.isEmpty,
            action.isValid,
            samples.count == CustomGestureMatcher.requiredTrainingSampleCount,
            samples.allSatisfy(\.isValid),
            let eventCount = samples.first?.events.count,
            eventCount > 0
        else { return false }
        return samples.allSatisfy { $0.events.count == eventCount }
    }
}

enum CustomGestureStore {
    static let defaultsKey = "customGestures.patterns"

    static func load(from defaults: UserDefaults) -> [CustomGesturePattern] {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([CustomGesturePattern].self, from: data)
        else { return [] }

        var seenIDs: Set<UUID> = []
        return decoded.filter { pattern in
            pattern.isValid && seenIDs.insert(pattern.id).inserted
        }
    }

    static func save(_ patterns: [CustomGesturePattern], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(patterns) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

enum CustomGestureMatcher {
    static let requiredTrainingSampleCount = 3

    /// Existing tap classification weights compensate for acceleration being
    /// reported in g while rotation is reported in degrees per second. Using
    /// the same shape here makes a learned wrist-rest knock distinguishable
    /// from display-edge taps without making force the dominant signal.
    private static let featureWeights = [2.0, 2.0, 1.0, 0.03, 0.03, 0.05]
    private static let minimumFeatureTolerance = 0.35
    private static let maximumFeatureTolerance = 2.5
    private static let featureToleranceMultiplier = 2.5
    private static let minimumTimingTolerance: TimeInterval = 0.12
    private static let maximumTimingTolerance: TimeInterval = 0.5
    private static let timingToleranceMultiplier = 2.5

    static func bestFullMatch(
        for events: [CustomGestureEvent],
        among patterns: [CustomGesturePattern]
    ) -> CustomGesturePattern? {
        patterns
            .compactMap { pattern -> (CustomGesturePattern, Double)? in
                guard pattern.eventCount == events.count,
                      let score = matchScore(events, pattern: pattern)
                else { return nil }
                return (pattern, score)
            }
            .min(by: { $0.1 < $1.1 })?
            .0
    }

    static func matchingPrefixes(
        for events: [CustomGestureEvent],
        among patterns: [CustomGesturePattern]
    ) -> [CustomGesturePattern] {
        patterns.filter { pattern in
            events.count < pattern.eventCount
                && matchScore(events, pattern: pattern) != nil
        }
    }

    /// Wait just long enough for the next learned knock. The upper bound
    /// prevents an abandoned prefix from delaying an ordinary display-tap
    /// action indefinitely.
    static func continuationTimeout(
        afterEventCount eventCount: Int,
        for patterns: [CustomGesturePattern]
    ) -> TimeInterval {
        let waits = patterns.compactMap { pattern -> TimeInterval? in
            guard eventCount > 0, eventCount < pattern.eventCount else { return nil }
            let intervals = pattern.samples.map {
                $0.events[eventCount].intervalSincePrevious
            }
            guard let average = intervals.average else { return nil }
            return average + timingTolerance(for: intervals) + 0.2
        }
        return min(max(waits.max() ?? 0.7, 0.45), 2.0)
    }

    static func samplesAreConsistent(
        _ candidate: CustomGestureSample,
        with accepted: [CustomGestureSample]
    ) -> Bool {
        guard let reference = accepted.first,
              candidate.isValid,
              candidate.events.count == reference.events.count
        else { return false }

        for index in candidate.events.indices {
            let candidateEvent = candidate.events[index]
            let referenceEvent = reference.events[index]
            // This is deliberately looser than runtime matching. Its purpose
            // is to catch an accidental extra knock or a clearly different
            // motion while still allowing the three repetitions to teach the
            // matcher the user's natural variation.
            guard featureDistance(candidateEvent.features, referenceEvent.features) <= 4.0 else {
                return false
            }
            if index > 0,
               abs(candidateEvent.intervalSincePrevious - referenceEvent.intervalSincePrevious) > 0.6 {
                return false
            }
        }
        return true
    }

    private static func matchScore(
        _ observed: [CustomGestureEvent],
        pattern: CustomGesturePattern
    ) -> Double? {
        guard !observed.isEmpty, observed.count <= pattern.eventCount else { return nil }

        var featureTolerances: [Double] = []
        var timingTolerances: [TimeInterval] = []
        for eventIndex in observed.indices {
            let trainedFeatures = pattern.samples.map { $0.events[eventIndex].features }
            featureTolerances.append(featureTolerance(for: trainedFeatures))
            if eventIndex == 0 {
                timingTolerances.append(0)
            } else {
                timingTolerances.append(
                    timingTolerance(
                        for: pattern.samples.map {
                            $0.events[eventIndex].intervalSincePrevious
                        }
                    )
                )
            }
        }

        return pattern.samples.compactMap { sample -> Double? in
            var score = 0.0
            for index in observed.indices {
                let distance = featureDistance(
                    observed[index].features,
                    sample.events[index].features
                )
                let featureTolerance = featureTolerances[index]
                guard distance <= featureTolerance else { return nil }
                score += distance / featureTolerance

                if index > 0 {
                    let timingDifference = abs(
                        observed[index].intervalSincePrevious
                            - sample.events[index].intervalSincePrevious
                    )
                    let timingTolerance = timingTolerances[index]
                    guard timingDifference <= timingTolerance else { return nil }
                    score += timingDifference / timingTolerance
                }
            }
            return score / Double(observed.count)
        }.min()
    }

    private static func featureTolerance(for trainedFeatures: [[Double]]) -> Double {
        var maximumDistance = 0.0
        for leftIndex in trainedFeatures.indices {
            for rightIndex in trainedFeatures.indices where rightIndex > leftIndex {
                maximumDistance = max(
                    maximumDistance,
                    featureDistance(
                        trainedFeatures[leftIndex],
                        trainedFeatures[rightIndex]
                    )
                )
            }
        }
        return min(
            max(
                minimumFeatureTolerance,
                maximumDistance * featureToleranceMultiplier
            ),
            maximumFeatureTolerance
        )
    }

    private static func timingTolerance(for intervals: [TimeInterval]) -> TimeInterval {
        guard let average = intervals.average else { return minimumTimingTolerance }
        let maximumDeviation = intervals.map { abs($0 - average) }.max() ?? 0
        return min(
            max(
                minimumTimingTolerance,
                maximumDeviation * timingToleranceMultiplier
            ),
            maximumTimingTolerance
        )
    }

    private static func featureDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == featureWeights.count, rhs.count == featureWeights.count else {
            return .infinity
        }
        return zip(zip(lhs, rhs), featureWeights).reduce(0) { result, item in
            let ((left, right), weight) = item
            let delta = (left - right) * weight
            return result + delta * delta
        }
    }
}

private extension Collection where Element == TimeInterval {
    var average: TimeInterval? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }
}
