import Foundation
import IOKit.ps

/// A snapshot of where the Mac's power is coming from.
public struct PowerState: Equatable {
    public let isOnACPower: Bool
    public let isCharging: Bool
    /// 0–100, or nil if it could not be read.
    public let percentRemaining: Int?
    /// Estimated seconds of battery left, or nil when unknown.
    ///
    /// macOS reports 65535 minutes as a sentinel meaning "cannot estimate" — which
    /// is what it always reports while on AC, and briefly after unplugging while
    /// the estimate settles. Treating that sentinel as ~45 days of runtime would
    /// make any power guard useless, so it is normalised to nil here.
    public let secondsRemaining: TimeInterval?

    public init(
        isOnACPower: Bool,
        isCharging: Bool,
        percentRemaining: Int?,
        secondsRemaining: TimeInterval?
    ) {
        self.isOnACPower = isOnACPower
        self.isCharging = isCharging
        self.percentRemaining = percentRemaining
        self.secondsRemaining = secondsRemaining
    }
}

public enum PowerVerdict: Equatable {
    case proceed
    /// On battery with too little runtime to finish. Not an error — the next poll
    /// after plugging in will archive it.
    case insufficientBattery(secondsRemaining: TimeInterval?, secondsNeeded: TimeInterval)
}

/// Decides whether there is enough power to finish an archive.
///
/// The guard is deliberately narrow. Requiring AC outright would mean a laptop on
/// a desk with 100% charge refuses to work, which is user-hostile for no safety
/// gain. What actually matters is whether the battery will outlast the job, so that
/// is what gets checked — and only when running on battery at all.
public struct PowerMonitor {

    /// Multiplier applied to the estimated archive duration.
    ///
    /// The estimate is a guess built on past throughput, and running out of power
    /// partway through wastes the whole job, so the requirement is padded.
    public static let safetyFactor: Double = 1.5

    /// Assumed throughput when nothing has been measured yet, in bytes/second.
    ///
    /// Deliberately pessimistic — roughly half the ~56 MB/s observed on this
    /// hardware — because underestimating throughput makes the guard cautious,
    /// while overestimating it lets a doomed run start.
    public static let conservativeBytesPerSecond: Double = 25_000_000

    private let readState: () -> PowerState

    public init(readState: @escaping () -> PowerState = PowerMonitor.currentState) {
        self.readState = readState
    }

    public func estimatedDuration(
        forSourceBytes bytes: Int64,
        observedBytesPerSecond: Double? = nil
    ) -> TimeInterval {
        let rate = max(observedBytesPerSecond ?? Self.conservativeBytesPerSecond, 1)
        return Double(bytes) / rate
    }

    public func verdict(
        forSourceBytes bytes: Int64,
        observedBytesPerSecond: Double? = nil
    ) -> PowerVerdict {
        let state = readState()
        // Plugged in: nothing to run out of.
        if state.isOnACPower { return .proceed }

        let needed = estimatedDuration(
            forSourceBytes: bytes, observedBytesPerSecond: observedBytesPerSecond
        ) * Self.safetyFactor

        // Unknown runtime on battery: allow it. Refusing on missing information
        // would make the app stop working whenever the estimate is unavailable,
        // which is a worse failure than a possibly-interrupted archive that can
        // simply be retried.
        guard let remaining = state.secondsRemaining else { return .proceed }

        guard remaining >= needed else {
            return .insufficientBattery(secondsRemaining: remaining, secondsNeeded: needed)
        }
        return .proceed
    }

    // MARK: Reading the system

    public static func currentState() -> PowerState {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
                  as? [CFTypeRef]
        else {
            // Desktops and unreadable states both land here. Reported as AC so the
            // guard does not block a machine that has no battery at all.
            return PowerState(
                isOnACPower: true, isCharging: false,
                percentRemaining: nil, secondsRemaining: nil)
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            let type = description[kIOPSPowerSourceStateKey] as? String
            let onAC = type == kIOPSACPowerValue

            var percent: Int?
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                percent = Int((Double(current) / Double(max)) * 100)
            }

            var seconds: TimeInterval?
            if let minutes = description[kIOPSTimeToEmptyKey] as? Int,
               minutes > 0, minutes != 65535 {
                seconds = TimeInterval(minutes * 60)
            }

            return PowerState(
                isOnACPower: onAC,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                percentRemaining: percent,
                secondsRemaining: onAC ? nil : seconds
            )
        }

        return PowerState(
            isOnACPower: true, isCharging: false,
            percentRemaining: nil, secondsRemaining: nil)
    }
}
