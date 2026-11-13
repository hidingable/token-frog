import Foundation
import VoyageCore

struct IdentityDisplay {
    let name: String
    let basis: String
    let letterID: Int?

    init?(journey: JourneyState, care: CareState, catalog: CityCatalog, now: Date, l10n: L10n) {
        guard IdentityRules.stages.contains(Stage.current(companionDays: care.companionDays.count)),
              let raw = care.identity, let identity = TravellerIdentity(rawValue: raw) else { return nil }
        let latest = journey.letters.filter { $0.kind == .identity && $0.identitySettlement?.identity == identity }
            .max { $0.id < $1.id }
        name = LetterComposer.localized(latest?.identitySettlement?.names ?? catalog.identities.entry(identity).name, l10n: l10n)!
        basis = switch identity {
        case .liaison: l10n("identity.basis.liaison")
        case .sketcher: l10n("identity.basis.sketcher")
        case .gourmet: l10n("identity.basis.gourmet")
        case .collector: l10n("identity.basis.collector")
        case .pathfinder: l10n("identity.basis.pathfinder")
        case .neighbour: l10n("identity.basis.neighbour")
        }
        letterID = latest.flatMap { $0.deliverAt <= now ? $0.id : nil }
    }
}
