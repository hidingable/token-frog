import Foundation

public struct LetterText: Equatable, Sendable {
    public var title: String
    public var voice: String
    public var signature: String
    public var itinerary: [String]
}

/// Builds the fictional pet voice and the factual itinerary. Sourced facts are stored on the letter itself.
public enum LetterComposer {
    public static func text(for letter: Letter) -> LetterText {
        let city = City.named(letter.cityId)
        let signature = "—— \(letter.pet.displayName)"
        if letter.kind == .departure {
            return LetterText(
                title: "出发信 · \(city.name)",
                voice: "行李收好了，我从\(city.name)出发。你的每 1 万 token，都会变成我路上的 1 公里。到了地方就写信给你。",
                signature: signature,
                itinerary: ["里程规则：1 万 token = 1 km"]
            )
        }

        let target = letter.transitTargetId.flatMap(City.find)
        let title = target.map { "第 \(letter.id) 封 · 前往\($0.name)途中" } ?? "第 \(letter.id) 封 · \(city.name)"
        return LetterText(title: title, voice: voice(letter, city: city, target: target), signature: signature, itinerary: itinerary(letter))
    }

    private static func voice(_ letter: Letter, city: City, target: City?) -> String {
        let quirk = quirks[letter.pet]?[letter.id % 3] ?? ""
        if let target {
            return "这一天还没走到\(target.name)，今晚就在路上歇脚。\(quirk)"
        }
        var parts: [String] = []
        if letter.isDeepVisit {
            parts.append("昨天走得不多，正好在\(city.name)慢慢逛了一整天。")
        } else if letter.arrivals.count > 1 {
            let passed = letter.arrivals.dropLast().compactMap { City.find($0)?.name }.joined(separator: "、")
            parts.append("这一天跑得真远，路过\(passed)，最后在\(city.name)停下。")
        } else {
            parts.append("我到\(city.name)了。")
        }
        if let country = letter.newCountries.last {
            parts.append("护照上多了一个\(country)的章。")
        }
        parts.append(quirk)
        return parts.joined()
    }

    private static func itinerary(_ letter: Letter) -> [String] {
        var lines = ["\(Format.tokens(letter.fuel)) token = \(Format.km(fuel: letter.fuel))"]
        if let percent = letter.compareToMedianPercent {
            if percent == 0 {
                lines.append("和平时差不多")
            } else {
                lines.append(percent > 0 ? "比平时多 \(percent)%" : "比平时少 \(-percent)%")
            }
        }
        if !letter.vehicles.isEmpty {
            lines.append(letter.vehicles.map { "\(Vehicle.name($0.client)) \($0.percent)%" }.joined(separator: " · "))
        }
        return lines
    }

    private static let quirks: [PetKind: [String]] = [
        .pigeon: ["邮差帽被风吹歪了，我又把它扶正。", "邮包还很轻，下一封信也装得下。", "我在屋顶上数了数今天的云。"],
        .snail: ["我不着急，壳里的金币叮当响。", "慢一点也能到，我一直这么觉得。", "今晚把壳擦亮了，明天接着走。"],
        .suitcase: ["今天又多了一张旅行贴纸。", "我把自己的搭扣检查了两遍。", "轮子有点累，不过还能走。"],
        .letter: ["我把今天的事都折进了身体里。", "风大的时候，我得贴着墙走。", "邮戳盖在身上，有一点痒。"],
    ]
}
