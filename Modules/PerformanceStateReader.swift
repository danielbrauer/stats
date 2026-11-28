import Foundation

#if arch(arm64)
final class PerformanceStateReader {
    private let channels: CFMutableDictionary
    private let subscription: IOReportSubscriptionRef
    private let includesChannel: (String) -> Bool
    private let lock = NSLock()
    private var previous: (sample: CFDictionary, time: TimeInterval)?

    init?(group: String, subgroup: String? = nil, includesChannel: @escaping (String) -> Bool) {
        guard let report = IOReportCopyChannelsInGroup(group as CFString, subgroup as CFString?, 0, 0, 0)?.takeRetainedValue(),
              let channels = CFDictionaryCreateMutableCopy(nil, 0, report) else { return nil }

        var subscribed: Unmanaged<CFMutableDictionary>?
        let subscription = IOReportCreateSubscription(nil, channels, &subscribed, 0, nil)
        subscribed?.release()
        guard let subscription else { return nil }

        self.channels = channels
        self.subscription = subscription
        self.includesChannel = includesChannel
    }

    func read(interval: TimeInterval) -> Double? {
        self.lock.lock()
        defer { self.lock.unlock() }

        guard let sample = IOReportCreateSamples(self.subscription, self.channels, nil)?.takeRetainedValue() else {
            self.previous = nil
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        let previous = self.previous
        self.previous = (sample, now)
        guard let previous, now - previous.time <= max(2, interval * 2),
              let delta = IOReportCreateSamplesDelta(previous.sample, sample, nil)?.takeRetainedValue() as? [String: Any],
              let channels = delta["IOReportChannels"] as? NSArray else { return nil }

        var weightedState: Double = 0
        var activeTime: Double = 0
        for case let channel as NSDictionary in channels {
            let sample = channel as CFDictionary
            guard let name = IOReportChannelGetChannelName(sample)?.takeUnretainedValue() as String?,
                  self.includesChannel(name) else { continue }

            // The tables list operating points from lowest to highest. Keep
            // zero-residency states in the scale so it stays fixed under load.
            var times: [Double] = []
            for index in 0..<max(0, IOReportStateGetCount(sample)) {
                guard let state = IOReportStateGetNameForIndex(sample, index)?.takeUnretainedValue() as String?,
                      state.first == "P" || state.first == "V",
                      state.dropFirst().first?.isNumber == true else { continue }
                times.append(Double(max(0, IOReportStateGetResidency(sample, index))))
            }
            guard times.count > 1 else { continue }
            for (rank, time) in times.enumerated() {
                activeTime += time
                weightedState += time * Double(rank) / Double(times.count - 1)
            }
        }
        return activeTime > 0 ? weightedState / activeTime : nil
    }

    func reset() {
        self.lock.lock()
        self.previous = nil
        self.lock.unlock()
    }
}
#endif
