import Foundation

public enum RoomSlot: String, CaseIterable, Sendable {
    case windowsill, cabinet, wall, floor
}

/// Fixed placements augment the original shelf. Neither placement nor movement grants rewards.
public enum RoomDecor {
    public static func isUnlocked(_ care: CareState) -> Bool {
        let stage = Stage.current(companionDays: care.companionDays.count)
        return [.teen, .traveler, .veteran, .legend].contains(stage)
    }

    public static func item(in slot: RoomSlot, care: CareState) -> String? {
        care.roomPlacements?.first { $0.slot == slot.rawValue }?.itemID
    }

    @discardableResult
    public static func place(_ itemID: String?, in slot: RoomSlot, care: inout CareState, library: ItemLibrary) -> Bool {
        guard isUnlocked(care) else { return false }
        if let itemID {
            guard library.find(itemID)?.kind == "souvenir", care.souvenirs.contains(where: { $0.id == itemID }) else { return false }
        }
        var placements = care.roomPlacements ?? []
        placements.removeAll { $0.slot == slot.rawValue || (itemID != nil && $0.itemID == itemID) }
        if let itemID {
            for index in care.souvenirs.indices where care.souvenirs[index].id == itemID {
                care.souvenirs[index].shelved = false
            }
            placements.append(.init(slot: slot.rawValue, itemID: itemID))
        }
        care.roomPlacements = placements
        return true
    }

    /// Called at load/import boundaries. First shelf occurrence wins, then first valid placement.
    /// Saved IDs are untrusted: use sets and iteration, never a trapping unique-key dictionary.
    public static func clean(care: inout CareState, library: ItemLibrary?) {
        var displayed: Set<String> = []
        for index in care.souvenirs.indices where care.souvenirs[index].shelved {
            let id = care.souvenirs[index].id
            if displayed.count >= CareRules.shelfCapacity || !displayed.insert(id).inserted {
                care.souvenirs[index].shelved = false
            }
        }
        guard let placements = care.roomPlacements else { return }
        let owned = Set(care.souvenirs.map(\.id))
        var slots: Set<String> = []
        care.roomPlacements = placements.filter { placement in
            guard RoomSlot(rawValue: placement.slot) != nil, owned.contains(placement.itemID),
                  library.map({ $0.find(placement.itemID)?.kind == "souvenir" }) ?? true else { return false }
            guard !slots.contains(placement.slot), !displayed.contains(placement.itemID) else { return false }
            slots.insert(placement.slot)
            displayed.insert(placement.itemID)
            return true
        }
    }
}
