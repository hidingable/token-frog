struct SplitMix64 {
    enum Salt: UInt64 {
        case carriedItem = 0xB430_824D_F590_A167
        case itemTrigger = 0x720E_C7E2_A965_153B
        case dropRarity = 0xD510_B3C1_873A_E629
        case dropItem = 0x3CF9_EA61_0B28_754D
        case roadClue = 0x6C1B_E342_A859_07DF
        case looseBoard = 0x921A_5D73_08C4_B6EF
        case friend = 0xDF81_630A_2B49_E7C5
        case friendNote = 0x8E52_C4A9_71D0_3FB6
        case identity = 0xA37D_6E20_C915_4B8F
        case usageEvent = 0x45BC_921A_7D36_E08F
    }

    var state: UInt64

    init(seed: UInt32, stopCount: Int) {
        state = (UInt64(seed) << 32) | UInt64(UInt32(truncatingIfNeeded: stopCount))
    }

    init(seed: UInt32, stopCount: Int, salt: Salt) {
        self.init(seed: seed, stopCount: stopCount)
        state ^= salt.rawValue
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
