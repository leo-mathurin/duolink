import Foundation

/// Turns a monotonically increasing byte counter into a bytes-per-second rate.
public struct RateMeter: Sendable {
    private let counterWidth: Int
    private var last: (bytes: UInt64, time: TimeInterval)?

    /// `counterWidth` is the bit width of the source counter, so that a
    /// smaller value is read as a wrap instead of a reset.
    public init(counterWidth: Int = 64) {
        self.counterWidth = counterWidth
    }

    /// Records a sample and returns the rate since the previous one.
    public mutating func record(bytes: UInt64, at time: TimeInterval) -> Double? {
        defer { if last == nil || time > last!.time { last = (bytes, time) } }
        guard let last, time > last.time else { return nil }

        let delta: UInt64
        if bytes >= last.bytes {
            delta = bytes - last.bytes
        } else if counterWidth < 64, last.bytes < (UInt64(1) << counterWidth) {
            delta = (UInt64(1) << counterWidth) - last.bytes + bytes
        } else {
            delta = 0
        }
        return Double(delta) / (time - last.time)
    }
}

/// Download and upload rates, in bytes per second.
public struct Throughput: Equatable, Sendable {
    public var down: Double
    public var up: Double

    public init(down: Double = 0, up: Double = 0) {
        self.down = down
        self.up = up
    }
}
