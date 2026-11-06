import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private actor EnrichmentRequestProbe {
    private(set) var calls: [(URL, String?)] = []
    let fail: Bool
    let sitelinks: [String: String]
    private var remainingWikidataFailures: Int
    private var remainingSummaryFailures: Int
    init(fail: Bool = false, sitelinks: [String: String] = ["zhwiki": "泉州市", "enwiki": "Quanzhou"],
         wikidataFailures: Int = 0, summaryFailures: Int = 0) {
        self.fail = fail
        self.sitelinks = sitelinks
        remainingWikidataFailures = wikidataFailures
        remainingSummaryFailures = summaryFailures
    }
    func request(_ url: URL, language: String?) throws -> Data {
        calls.append((url, language))
        if fail { throw URLError(.notConnectedToInternet) }
        if url.host == "api.open-meteo.com" {
            return Data(#"{"current":{"temperature_2m":14.4,"weather_code":61}}"#.utf8)
        }
        if url.host == "www.wikidata.org" {
            if remainingWikidataFailures > 0 {
                remainingWikidataFailures -= 1
                throw URLError(.notConnectedToInternet)
            }
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ids" }?.value ?? ""
            return try JSONSerialization.data(withJSONObject: [
                "entities": [id: ["sitelinks": sitelinks.mapValues { ["title": $0] }]],
            ])
        }
        if remainingSummaryFailures > 0 {
            remainingSummaryFailures -= 1
            throw URLError(.notConnectedToInternet)
        }
        let summary: [String: Any] = [
            "title": url.lastPathComponent,
            "extract": language == "zh-cn" ? "上海的地点介绍。" : "A place introduction to Shanghai.",
            "content_urls": ["desktop": ["page": "https://\(url.host!)/wiki/Shanghai"]],
        ]
        return try JSONSerialization.data(withJSONObject: summary)
    }
}

private func wikidataQuery(language: Language) -> Enricher.Query {
    var query = enrichmentQuery(language: language)
    query.city.id = "q68695"
    query.city.wikidata = "q68695"
    query.city.wikipedia = [:]
    return query
}

private func enrichmentQuery(language: Language, weather: Bool = false) -> Enricher.Query {
    let city = localizationCatalog.city("shanghai")
    return Enricher.Query(city: city, coordinate: city.coordinate, language: language,
                          includeWeather: weather, includePhoto: false, includePlace: true)
}

@Test func weatherCodesAreLocalizedAndUnknownCodesHaveAFallback() {
    for code in [0, 1, 2, 3, 45, 48, 51, 57, 61, 67, 80, 82, 71, 77, 85, 86, 95, 99, -1, 123] {
        let zh = Enricher.weatherName(code, l10n: L10n(language: .zhHans))
        let en = Enricher.weatherName(code, l10n: L10n(language: .en))
        #expect(zh != en && !en.isEmpty && !en.hasPrefix("weather."))
        #expect(!containsHan(en))
    }
    #expect(Enricher.weatherName(999, l10n: L10n(language: .en)) == "Weather unknown")
}

@Test(arguments: Language.allCases)
func wikipediaUsesOnlyTheSelectedLanguageTitleAndSource(language: Language) async throws {
    let probe = EnrichmentRequestProbe()
    var query = enrichmentQuery(language: language)
    query.city.wikidata = "q8686"
    let result = await Enricher.fetch(query, request: { try await probe.request($0, language: $1) }, cache: Enricher.PlaceCache())
    let calls = await probe.calls
    #expect(calls.count == 1)
    let call = try #require(calls.first)
    let host = language == .zhHans ? "zh.wikipedia.org" : "en.wikipedia.org"
    #expect(call.0.host == host)
    #expect(call.0.lastPathComponent == query.city.wikipedia[language.rawValue])
    #expect(call.1 == (language == .zhHans ? "zh-cn" : "en"))
    #expect(call.0.query == nil)
    #expect(Set(result.place.keys) == [language.rawValue])
    #expect(result.place[language.rawValue]?.url?.contains(host) == true)
    #expect(result.weatherCode == nil && result.temperatureC == nil && result.photoData == nil)
}

@Test(arguments: Language.allCases)
func wikipediaFailureDoesNotTryAnotherLanguage(language: Language) async {
    let probe = EnrichmentRequestProbe(fail: true)
    let result = await Enricher.fetch(enrichmentQuery(language: language), request: { try await probe.request($0, language: $1) }, cache: Enricher.PlaceCache())
    #expect(result.place.isEmpty)
    #expect(await probe.calls.count == 1)
}

@Test(arguments: Language.allCases)
func missingWikipediaTitleAndWikidataDoesNotRequestAnotherLanguage(language: Language) async {
    let probe = EnrichmentRequestProbe()
    var query = enrichmentQuery(language: language)
    query.city.wikipedia[language.rawValue] = nil
    query.city.wikidata = nil
    let result = await Enricher.fetch(query, request: { try await probe.request($0, language: $1) }, cache: Enricher.PlaceCache())
    #expect(result.place.isEmpty)
    #expect(await probe.calls.isEmpty)
}

@Test(arguments: Language.allCases)
func wikidataRequestsOnlyTheEntityAndResolvesTheSelectedLanguage(language: Language) async throws {
    let probe = EnrichmentRequestProbe()
    let query = wikidataQuery(language: language)
    let cache = Enricher.PlaceCache()
    let request: Enricher.Request = { try await probe.request($0, language: $1) }
    let result = await Enricher.fetch(query, request: request, cache: cache)
    let repeated = await Enricher.fetch(query, request: request, cache: cache)
    let calls = await probe.calls
    #expect(calls.count == 2)
    let entityCall = try #require(calls.first)
    #expect(entityCall.0.host == "www.wikidata.org" && entityCall.0.path == "/w/api.php")
    let params = Dictionary(uniqueKeysWithValues: try #require(URLComponents(url: entityCall.0, resolvingAgainstBaseURL: false)?.queryItems)
        .map { ($0.name, $0.value ?? "") })
    #expect(params == ["action": "wbgetentities", "ids": "Q68695", "props": "sitelinks", "sitefilter": "zhwiki|enwiki", "format": "json"])
    #expect(entityCall.1 == nil)
    let summaryCall = calls[1]
    #expect(summaryCall.0.host == (language == .zhHans ? "zh.wikipedia.org" : "en.wikipedia.org"))
    #expect(summaryCall.0.lastPathComponent == (language == .zhHans ? "泉州市" : "Quanzhou"))
    #expect(summaryCall.1 == (language == .zhHans ? "zh-cn" : "en"))
    #expect(result.place[language.rawValue]?.title == summaryCall.0.lastPathComponent)
    #expect(repeated.place[language.rawValue] == result.place[language.rawValue])
}

@Test(arguments: Language.allCases)
func missingSelectedWikidataSitelinkIsCachedWithoutLanguageFallback(language: Language) async {
    let otherSite = language == .zhHans ? "enwiki" : "zhwiki"
    let probe = EnrichmentRequestProbe(sitelinks: [otherSite: "Another language"])
    let query = wikidataQuery(language: language)
    let cache = Enricher.PlaceCache()
    let request: Enricher.Request = { try await probe.request($0, language: $1) }
    let result = await Enricher.fetch(query, request: request, cache: cache)
    let repeated = await Enricher.fetch(query, request: request, cache: cache)
    #expect(result.place.isEmpty && repeated.place.isEmpty)
    #expect(await probe.calls.count == 1)
}

@Test func wikidataAndSummaryFailuresCanRetryWithoutCachingTheFailure() async {
    let probe = EnrichmentRequestProbe(wikidataFailures: 1, summaryFailures: 1)
    let query = wikidataQuery(language: .en)
    let cache = Enricher.PlaceCache()
    let request: Enricher.Request = { try await probe.request($0, language: $1) }
    let first = await Enricher.fetch(query, request: request, cache: cache)
    let second = await Enricher.fetch(query, request: request, cache: cache)
    let third = await Enricher.fetch(query, request: request, cache: cache)
    #expect(first.place.isEmpty && second.place.isEmpty)
    #expect(third.place["en"]?.title == "Quanzhou")
    let calls = await probe.calls
    #expect(calls.map { $0.0.host } == ["www.wikidata.org", "www.wikidata.org", "en.wikipedia.org", "en.wikipedia.org"])
}

@Test func placeCacheSeparatesCitiesAndLanguages() async {
    let probe = EnrichmentRequestProbe()
    let cache = Enricher.PlaceCache()
    let request: Enricher.Request = { try await probe.request($0, language: $1) }
    for language in Language.allCases {
        var query = wikidataQuery(language: language)
        _ = await Enricher.fetch(query, request: request, cache: cache)
        query.city.id = "q1733"
        query.city.wikidata = "q1733"
        _ = await Enricher.fetch(query, request: request, cache: cache)
    }
    #expect(await probe.calls.count == 8)
}

@Test func weatherRequestsContainOnlyCoordinatesAndTheRequestedWeatherFields() async throws {
    let probe = EnrichmentRequestProbe()
    var query = enrichmentQuery(language: .en, weather: true)
    query.includePlace = false
    let result = await Enricher.fetch(query, request: { try await probe.request($0, language: $1) }, cache: Enricher.PlaceCache())
    #expect(result.weatherCode == 61 && result.temperatureC == 14 && result.place.isEmpty)
    let call = try #require(await probe.calls.first)
    let components = try #require(URLComponents(url: call.0, resolvingAgainstBaseURL: false))
    let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(params == ["latitude": "31.23", "longitude": "121.47", "current": "temperature_2m,weather_code"])
    #expect(call.1 == nil)
}

@Test func placeholderCitiesMakeNoRequests() async {
    let probe = EnrichmentRequestProbe()
    var query = enrichmentQuery(language: .en, weather: true)
    query.city = localizationCatalog.city("removed-city")
    query.includePhoto = true
    let result = await Enricher.fetch(query, request: { try await probe.request($0, language: $1) }, cache: Enricher.PlaceCache())
    #expect(result.place.isEmpty && result.weatherCode == nil && result.photoData == nil)
    #expect(await probe.calls.isEmpty)
}
