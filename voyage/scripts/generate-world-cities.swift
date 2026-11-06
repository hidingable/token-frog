#!/usr/bin/env swift
// Natural Earth populated places is public domain. Run manually from the repository root.
import Foundation

struct GenerationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct DBF {
    struct Field {
        let offset: Int
        let length: Int
    }

    let bytes: [UInt8]
    let count: Int
    let headerLength: Int
    let recordLength: Int
    let fields: [String: Field]

    init(url: URL) throws {
        let bytes = Array(try Data(contentsOf: url))
        guard bytes.count >= 33 else { throw GenerationError("DBF header is truncated") }
        func littleEndian(_ offset: Int, _ length: Int) -> Int {
            (0..<length).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
        }
        let count = littleEndian(4, 4)
        let headerLength = littleEndian(8, 2)
        let recordLength = littleEndian(10, 2)
        guard headerLength >= 33, recordLength > 1,
              headerLength <= bytes.count, count <= (bytes.count - headerLength) / recordLength,
              bytes[headerLength - 1] == 0x0d else {
            throw GenerationError("DBF has invalid record or header lengths")
        }
        var fields: [String: Field] = [:]
        var offset = 1 // The first byte of every record is its deletion marker.
        for position in stride(from: 32, to: headerLength - 1, by: 32) {
            guard position + 32 <= headerLength - 1 else { throw GenerationError("DBF field descriptor is truncated") }
            let name = String(decoding: bytes[position..<(position + 11)].prefix { $0 != 0 }, as: UTF8.self)
            let length = Int(bytes[position + 16])
            guard fields[name] == nil, offset + length <= recordLength else {
                throw GenerationError("Invalid DBF field: \(name)")
            }
            fields[name] = Field(offset: offset, length: length)
            offset += length
        }
        let required = ["NAME_EN", "NAME_ZH", "ISO_A2", "LATITUDE", "LONGITUDE", "SCALERANK", "FEATURECLA", "WIKIDATAID", "ADM0CAP"]
        for name in required where fields[name] == nil { throw GenerationError("Missing DBF field: \(name)") }
        self.bytes = bytes
        self.count = count
        self.headerLength = headerLength
        self.recordLength = recordLength
        self.fields = fields
    }

    func isDeleted(_ index: Int) -> Bool { bytes[headerLength + index * recordLength] == 0x2a }

    func value(_ name: String, at index: Int) throws -> String {
        let field = fields[name]!
        let start = headerLength + index * recordLength + field.offset
        guard let value = String(bytes: bytes[start..<(start + field.length)], encoding: .utf8) else {
            throw GenerationError("Invalid UTF-8 in row \(index + 1), field \(name)")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct WorldCity {
    let id: String
    let lat: Double
    let lon: Double
    let countryCode: String
    let continent: String
    let tier: Int
    let en: String
    let zh: String
    let scaleRank: Int
}

// Each country has one stable assignment. Transcontinental RU/TR follow the existing
// European city records; Asian records with their own files retain their continents.
// GS is grouped with South America because the catalog supports six continents.
let continentGroups: [(String, String)] = [
    ("africa", "AO BF BI BJ BW CD CF CG CI CM CV DJ DZ EG EH ER ET GA GH GM GN GQ GW KE KM LR LS LY MA MG ML MR MU MW MZ NA NE NG RE RW SC SD SH SL SN SO SS ST SZ TD TG TN TZ UG YT ZA ZM ZW"),
    ("asia", "AE AF AM AZ BD BH BN BT CN CY GE HK ID IL IN IQ IR JO JP KG KH KP KR KW KZ LA LB LK MM MN MO MV MY NP OM PH PK PS QA SA SG SY TH TJ TL TM TW UZ VN YE"),
    ("europe", "AD AL AT AX BA BE BG BY CH CZ DE DK EE ES FI FO FR GB GG GI GR HR HU IE IM IS IT JE LI LT LU LV MC MD ME MK MT NL NO PL PT RO RS RU SE SI SJ SK SM TR UA VA"),
    ("north-america", "AG AI AW BB BL BM BQ BS BZ CA CR CU CW DM DO GD GL GP GT HN HT JM KN KY LC MF MQ MS MX NI PA PM PR SV SX TC TT US VC VG VI"),
    ("south-america", "AR BO BR CL CO EC FK GF GS GY PE PY SR UY VE"),
    ("oceania", "AS AU CK FJ FM GU KI MH MP NC NF NR NU NZ PF PG PN PW SB TK TO TV UM VU WF WS")
]

func continentMapping() throws -> [String: String] {
    var result: [String: String] = [:]
    for (continent, codes) in continentGroups {
        for code in codes.split(separator: " ").map(String.init) {
            guard result.updateValue(continent, forKey: code) == nil else {
                throw GenerationError("Duplicate continent mapping: \(code)")
            }
        }
    }
    return result
}

func normalizedName(_ name: String) -> String {
    name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
}

func distanceKm(lat: Double, lon: Double, to city: WorldCity) -> Double {
    let dLat = (city.lat - lat) * .pi / 180
    let dLon = (city.lon - lon) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
        + cos(lat * .pi / 180) * cos(city.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
    return 6371 * 2 * atan2(sqrt(a), sqrt(1 - a))
}

func quoted(_ text: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(decoding: try encoder.encode(text), as: UTF8.self)
}

func generate() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let content = root.appendingPathComponent("Content", isDirectory: true)
    let dbf = try DBF(url: root.appendingPathComponent(".vendor/natural-earth/ne_10m_populated_places.dbf"))
    let continents = try continentMapping()
    let numberLocale = Locale(identifier: "en_US_POSIX")
    var exclusionCounts: [String: Int] = [:]
    var excluded = 0
    var duplicateCount = 0
    var citiesByID: [String: WorldCity] = [:]
    for index in 0..<dbf.count {
        if dbf.isDeleted(index) {
            exclusionCounts["deleted record", default: 0] += 1
            excluded += 1
            continue
        }
        let feature = try dbf.value("FEATURECLA", at: index)
        let wikidata = try dbf.value("WIKIDATAID", at: index)
        let code = try dbf.value("ISO_A2", at: index)
        var reasons: [String] = []
        if feature == "Scientific station" || feature == "Historic place" { reasons.append(feature) }
        if wikidata.isEmpty { reasons.append("missing WIKIDATAID") }
        if code == "-99" { reasons.append("ISO_A2 -99") }
        if code == "AQ" { reasons.append("AQ") }
        if !reasons.isEmpty {
            for reason in reasons { exclusionCounts[reason, default: 0] += 1 }
            excluded += 1
            continue
        }
        guard wikidata.range(of: #"^Q[1-9][0-9]*$"#, options: .regularExpression) != nil else {
            throw GenerationError("Invalid WIKIDATAID in row \(index + 1): \(wikidata)")
        }
        guard let continent = continents[code] else { throw GenerationError("Missing continent mapping: \(code)") }
        guard let lat = Double(try dbf.value("LATITUDE", at: index)), (-90...90).contains(lat),
              let lon = Double(try dbf.value("LONGITUDE", at: index)), (-180...180).contains(lon),
              let rank = Int(try dbf.value("SCALERANK", at: index)),
              let capital = Int(try dbf.value("ADM0CAP", at: index)) else {
            throw GenerationError("Invalid coordinates, SCALERANK or ADM0CAP in row \(index + 1)")
        }
        let en = try dbf.value("NAME_EN", at: index)
        let sourceZH = try dbf.value("NAME_ZH", at: index)
        guard let zh = sourceZH.applyingTransform(StringTransform("Hant-Hans"), reverse: false) else {
            throw GenerationError("Cannot simplify Chinese name in row \(index + 1): \(sourceZH)")
        }
        for name in [en, zh] where name.isEmpty || name.contains(where: { $0 == "\t" || $0.isNewline }) {
            throw GenerationError("Empty name or TSV separator in row \(index + 1): \(name)")
        }
        guard zh.unicodeScalars.contains(where: { (0x3400...0x9fff).contains($0.value) || (0x20000...0x323af).contains($0.value) }) else {
            throw GenerationError("Chinese name has no Han characters in row \(index + 1): \(zh)")
        }
        let tier = capital == 1 || rank <= 2 ? 1 : rank <= 4 ? 2 : rank <= 7 ? 3 : 4
        let city = WorldCity(id: wikidata.lowercased(), lat: lat, lon: lon, countryCode: code,
                             continent: continent, tier: tier, en: en, zh: zh, scaleRank: rank)
        if let existing = citiesByID[city.id] {
            duplicateCount += 1
            // Equal ranks retain the earlier source record, a stable tie-breaker.
            if city.scaleRank < existing.scaleRank { citiesByID[city.id] = city }
        } else {
            citiesByID[city.id] = city
        }
    }
    let cities = citiesByID.values.sorted { $0.id < $1.id }
    var tsv = "id\tlat\tlon\tcountryCode\tcontinent\ttier\ten\tzh\n"
    for city in cities {
        tsv += [city.id, String(format: "%.4f", locale: numberLocale, city.lat),
                String(format: "%.4f", locale: numberLocale, city.lon), city.countryCode,
                city.continent, String(city.tier), city.en, city.zh].joined(separator: "\t") + "\n"
    }

    let countriesURL = content.appendingPathComponent("countries.json")
    var countries = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: countriesURL))
    let english = Locale(identifier: "en")
    let chinese = Locale(identifier: "zh-Hans")
    // Avoid region-dependent "China mainland" / "Hong Kong, China" forms.
    let fixedNames = ["CN": ["en": "China", "zh-Hans": "中国"],
                      "HK": ["en": "Hong Kong", "zh-Hans": "香港"],
                      "MO": ["en": "Macao", "zh-Hans": "澳门"],
                      "TW": ["en": "Taiwan", "zh-Hans": "台湾"]]
    for code in Set(cities.map(\.countryCode)).sorted() where countries[code] == nil {
        guard let en = english.localizedString(forRegionCode: code), en != code, !en.isEmpty,
              let zh = chinese.localizedString(forRegionCode: code), zh != code, !zh.isEmpty else {
            throw GenerationError("Locale has no English/Chinese country name for \(code)")
        }
        countries[code] = fixedNames[code] ?? ["en": en, "zh-Hans": zh]
    }
    for (code, names) in countries {
        if names.values.contains(where: { $0.contains("中国大陆") || $0.contains("中国香港") || $0.contains("中国澳门") }) {
            throw GenerationError("Region-dependent country name for \(code); add a fixed name before generating")
        }
    }
    let countryRows = try countries.keys.sorted().map { code -> String in
        let names = countries[code]!
        let languages = ["zh-Hans", "en"] + names.keys.filter { $0 != "zh-Hans" && $0 != "en" }.sorted()
        let nameRows = try languages.map { "    \(try quoted($0)): \(try quoted(names[$0]!))" }.joined(separator: ",\n")
        return "  \(try quoted(code)): {\n\(nameRows)\n  }"
    }
    let countriesText = "{\n" + countryRows.joined(separator: ",\n") + "\n}\n"

    let cityFiles = try FileManager.default.contentsOfDirectory(at: content.appendingPathComponent("cities"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    let byName = Dictionary(grouping: cities, by: { normalizedName($0.en) })
    // Authored and source names can differ even for the same city (Cusco / Cuzco).
    let manualMatches = ["cusco": "q5582862"]
    let publishedURL = content.appendingPathComponent("published-ids.txt")
    var published = Set(try String(contentsOf: publishedURL, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init))
    published.formUnion(cities.map(\.id))
    var cityUpdates: [(URL, String)] = []
    var unmatched: [String] = []
    for file in cityFiles {
        let text = try String(contentsOf: file, encoding: .utf8)
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = object["id"] as? String, let names = object["names"] as? [String: String],
              let en = names["en"], let lat = object["lat"] as? Double, let lon = object["lon"] as? Double else {
            throw GenerationError("Incomplete city JSON: \(file.lastPathComponent)")
        }
        published.insert(id)
        let nameMatches: [WorldCity]
        if let wikidata = manualMatches[id] {
            guard let city = citiesByID[wikidata] else {
                throw GenerationError("Manual match for \(id) is missing from the source: \(wikidata)")
            }
            nameMatches = [city]
        } else {
            nameMatches = byName[normalizedName(en)] ?? []
        }
        var candidates: [(city: WorldCity, distance: Double)] = []
        for city in nameMatches {
            let distance = distanceKm(lat: lat, lon: lon, to: city)
            if distance <= 50 { candidates.append((city, distance)) }
        }
        candidates.sort { lhs, rhs in
            if lhs.distance == rhs.distance { return lhs.city.id < rhs.city.id }
            return lhs.distance < rhs.distance
        }
        guard let match = candidates.first else {
            unmatched.append("\(id) (\(en))")
            continue
        }
        let wikidata = match.city.id.uppercased()
        if let existing = object["wikidata"] as? String {
            guard existing.uppercased() == wikidata else {
                throw GenerationError("Existing wikidata for \(id) conflicts with matched \(wikidata)")
            }
        } else {
            // Preserve every byte of authored city content; add only the new field.
            guard let insertion = text.range(of: "\n") else { throw GenerationError("City JSON is not multiline: \(id)") }
            var updated = text
            updated.insert(contentsOf: "  \"wikidata\": \"\(wikidata)\",\n", at: insertion.upperBound)
            cityUpdates.append((file, updated))
        }
    }

    let world = content.appendingPathComponent("world", isDirectory: true)
    try FileManager.default.createDirectory(at: world, withIntermediateDirectories: true)
    try tsv.write(to: world.appendingPathComponent("cities.tsv"), atomically: true, encoding: .utf8)
    try countriesText.write(to: countriesURL, atomically: true, encoding: .utf8)
    try (published.sorted().joined(separator: "\n") + "\n").write(to: publishedURL, atomically: true, encoding: .utf8)
    for (file, text) in cityUpdates { try text.write(to: file, atomically: true, encoding: .utf8) }
    print("Source rows: \(dbf.count)")
    print("Excluded source rows: \(excluded) (criteria below can overlap)")
    for reason in exclusionCounts.keys.sorted() { print("  \(reason): \(exclusionCounts[reason]!)") }
    print("Duplicate Wikidata rows removed: \(duplicateCount)")
    print("Generated cities: \(cities.count); TSV lines including header: \(cities.count + 1); bytes: \(tsv.utf8.count)")
    print("Countries: \(countries.count); city wikidata fields added: \(cityUpdates.count)")
    print("Unmatched existing cities (left without wikidata): \(unmatched.isEmpty ? "none" : unmatched.joined(separator: ", "))")
}

do {
    try generate()
} catch {
    FileHandle.standardError.write(Data("generate-world-cities: \(error)\n".utf8))
    exit(1)
}
