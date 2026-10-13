import Testing
@testable import DuolinkCore

@Suite struct RateMeterTests {
    @Test func hasNoRateBeforeTwoSamples() {
        var meter = RateMeter()
        #expect(meter.record(bytes: 1_000, at: 0) == nil)
    }

    @Test func computesBytesPerSecond() {
        var meter = RateMeter()
        _ = meter.record(bytes: 1_000, at: 10)
        #expect(meter.record(bytes: 3_000, at: 12) == 1_000)
    }

    @Test func handles32BitCounterWrap() {
        // if_data byte counters are 32-bit and wrap after 4 GiB.
        var meter = RateMeter(counterWidth: 32)
        _ = meter.record(bytes: UInt64(UInt32.max) - 99, at: 0)
        #expect(meter.record(bytes: 900, at: 1) == 1_000)
    }

    @Test func treatsACounterResetAsZero() {
        var meter = RateMeter(counterWidth: 64)
        _ = meter.record(bytes: 5_000, at: 0)
        #expect(meter.record(bytes: 10, at: 1) == 0)
    }

    @Test func ignoresSamplesThatDoNotMoveForwardInTime() {
        var meter = RateMeter()
        _ = meter.record(bytes: 0, at: 5)
        #expect(meter.record(bytes: 100, at: 5) == nil)
    }
}
