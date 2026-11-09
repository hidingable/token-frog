import Foundation

public enum JourneyMigrations {
    // Persisted M0 country names are a permanent migration contract.
    public static let legacyCountryCodes: [String: String] = [
        "中国": "CN",
        "台湾": "TW",
        "韩国": "KR",
        "日本": "JP",
        "俄罗斯": "RU",
        "蒙古": "MN",
        "越南": "VN",
        "泰国": "TH",
        "柬埔寨": "KH",
        "马来西亚": "MY",
        "新加坡": "SG",
        "印度尼西亚": "ID",
        "菲律宾": "PH",
        "缅甸": "MM",
        "孟加拉国": "BD",
        "尼泊尔": "NP",
        "印度": "IN",
        "斯里兰卡": "LK",
        "乌兹别克斯坦": "UZ",
        "哈萨克斯坦": "KZ",
        "阿联酋": "AE",
        "阿曼": "OM",
        "卡塔尔": "QA",
        "约旦": "JO",
        "土耳其": "TR",
        "格鲁吉亚": "GE",
        "希腊": "GR",
        "意大利": "IT",
        "奥地利": "AT",
        "捷克": "CZ",
        "德国": "DE",
        "瑞士": "CH",
        "法国": "FR",
        "荷兰": "NL",
        "英国": "GB",
        "爱尔兰": "IE",
        "冰岛": "IS",
        "挪威": "NO",
        "瑞典": "SE",
        "芬兰": "FI",
        "西班牙": "ES",
        "葡萄牙": "PT",
        "摩洛哥": "MA",
        "埃及": "EG",
        "埃塞俄比亚": "ET",
        "肯尼亚": "KE",
        "坦桑尼亚": "TZ",
        "南非": "ZA",
        "纳米比亚": "NA",
        "马达加斯加": "MG",
        "尼日利亚": "NG",
        "加纳": "GH",
        "塞内加尔": "SN",
        "澳大利亚": "AU",
        "新西兰": "NZ",
        "斐济": "FJ",
        "美国": "US",
        "加拿大": "CA",
        "墨西哥": "MX",
        "古巴": "CU",
        "巴拿马": "PA",
        "哥伦比亚": "CO",
        "厄瓜多尔": "EC",
        "秘鲁": "PE",
        "玻利维亚": "BO",
        "智利": "CL",
        "阿根廷": "AR",
        "乌拉圭": "UY",
        "巴西": "BR",
    ]

    public static func countryCode(for legacyName: String) -> String {
        legacyCountryCodes[legacyName] ?? "ZZ"
    }

    static func migrateV2(_ original: [String: Any]) -> [String: Any] {
        var json = original
        json.removeValue(forKey: "nextChoiceId")
        return json
    }

    static func migrateV4(_ original: [String: Any]) -> [String: Any] {
        var json = original
        if let letters = json["letters"] as? [[String: Any]] {
            json["letters"] = letters.map { original in
                var letter = original
                letter.removeValue(forKey: "weather")
                let title = letter.removeValue(forKey: "placeTitle") as? String
                let summary = letter.removeValue(forKey: "placeSummary") as? String
                let url = letter.removeValue(forKey: "placeURL") as? String
                if let title {
                    let language = title.range(of: #"\p{Han}"#, options: .regularExpression) == nil ? "en" : "zh-Hans"
                    var place: [String: Any] = ["title": title, "summary": summary ?? ""]
                    if let url { place["url"] = url }
                    letter["place"] = [language: place]
                }
                return letter
            }
        }
        return json
    }

    static func migrateV1(_ original: [String: Any], catalog: CityCatalog) throws -> [String: Any] {
        var json = original
        if let stamps = json["stamps"] as? [[String: Any]] {
            json["stamps"] = stamps.map { stamp in
                var stamp = stamp
                stamp["countryCode"] = countryCode(for: stamp.removeValue(forKey: "country") as? String ?? "")
                return stamp
            }
        }
        func migrateCountries(_ record: [String: Any]) -> [String: Any] {
            var record = record
            if let countries = record["newCountries"] as? [String] {
                record["newCountries"] = countries.map { countryCode(for: $0) }
            }
            return record
        }
        if let days = json["days"] as? [String: [String: Any]] { json["days"] = days.mapValues(migrateCountries) }
        if let letters = json["letters"] as? [[String: Any]] { json["letters"] = letters.map(migrateCountries) }
        let current = (json["currentCityId"] as? String).flatMap { catalog.find($0) }
        let target = (json["targetCityId"] as? String).flatMap { catalog.find($0) }
        let origin = current?.coordinate ?? target?.coordinate ?? Coordinate(lat: 0, lon: 0)
        let destination = target?.coordinate ?? current?.coordinate ?? Coordinate(lat: 0, lon: 0)
        json["legFrom"] = ["lat": origin.lat, "lon": origin.lon]
        json["legTo"] = ["lat": destination.lat, "lon": destination.lon]
        if let current, let target {
            json["legCost"] = JourneyState.cost(from: current, to: target)
        } else {
            json["legCost"] = max((json["legFuel"] as? Int ?? 0) + fuelPerKm, fuelPerKm)
        }
        json["targetCountryCode"] = target?.countryCode
        return json
    }
}

extension SaveMigrations {
    public static func journey(catalog: CityCatalog) -> SaveMigrations {
        SaveMigrations(currentVersion: JourneyState.currentVersion, steps: [
            1: { try JourneyMigrations.migrateV1($0, catalog: catalog) },
            2: { JourneyMigrations.migrateV2($0) },
            3: { $0 },
            4: { JourneyMigrations.migrateV4($0) },
            5: { $0 }, // Opening history starts now; never infer absence from usage or old mail.
        ])
    }
}
