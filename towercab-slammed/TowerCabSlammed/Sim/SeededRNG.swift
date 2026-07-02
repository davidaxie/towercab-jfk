import Foundation

/// Deterministic xoshiro256** — seeded per shift (PRD §9.3). Never use
/// SystemRandomNumberGenerator inside the sim: seeds must replay identically.
public struct SeededRNG: RandomNumberGenerator {
    private var s: (UInt64, UInt64, UInt64, UInt64)

    public init(seed: UInt64) {
        // splitmix64 to expand the seed
        var x = seed &+ 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            x &+= 0x9E3779B97F4A7C15
            var z = x
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        s = (next(), next(), next(), next())
    }

    private static func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }

    public mutating func next() -> UInt64 {
        let result = Self.rotl(s.1 &* 5, 7) &* 9
        let t = s.1 << 17
        s.2 ^= s.0
        s.3 ^= s.1
        s.1 ^= s.2
        s.0 ^= s.3
        s.2 ^= t
        s.3 = Self.rotl(s.3, 45)
        return result
    }

    public mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9007199254740992.0)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    public mutating func chance(_ p: Double) -> Bool {
        double(in: 0...1) < p
    }

    public mutating func pick<T>(_ items: [T]) -> T {
        items[Int(next() % UInt64(items.count))]
    }
}
