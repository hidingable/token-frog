import Foundation
import Testing
import VoyageCore
@testable import TokenVoyage

private actor EnrichmentRequestProbe {
    private(set) var calls: [(URL, String?)] = []
    let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    func request(_ url: URL, language: String?) throws -> Data {
        calls.append((url, language))
        if fail { throw URLError(.notConnectedToInternet) }
        if url.host == "api.open-meteo.com" {
            return Data(#"{"current":{"temperature_2m":14.4,"weather_code":61}}"#.utf8)
        }
        let summary: [String: Any] = [
            "title": language == "zh-cn" ? "上海" : "Shanghai",
            "extract": language == "zh-cn" ? "上海的地点介绍。" : "A place introduction to Shanghai.",
            "content_urls": ["desktop": ["page": "https://\(url.host!)/wiki/Shanghai"]],
        ]
        return try JSONSerialization.data(withJSONObject: summary)
    }
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
    let query = enrichmentQuery(language: language)
    let result = await Enricher.fetch(query, request: { try await probe.request($0, language: $1) })
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
    let result = await Enricher.fetch(enrichmentQuery(language: language), request: { try await probe.request($0, language: $1) })
    #expect(result.place.isEmpty)
    #expect(await probe.calls.count == 1)
}

@Test(arguments: Language.allCases)
func missingWikipediaTitleDoesNotRequestAnotherLanguage(language: Language) async {
    let probe = EnrichmentRequestProbe()
    var query = enrichmentQuery(language: language)
    query.city.wikipedia[language.rawValue] = nil
    let result = await Enricher.fetch(query, request: { try await probe.request($0, language: $1) })
    #expect(result.place.isEmpty)
    #expect(await probe.calls.isEmpty)
}

@Test func weatherRequestsContainOnlyCoordinatesAndTheRequestedWeatherFields() async throws {
    let probe = EnrichmentRequestProbe()
    var query = enrichmentQuery(language: .en, weather: true)
    query.includePlace = false
    let result = await Enricher.fetch(query, request: { try await probe.request($0, language: $1) })
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
    let result = await Enricher.fetch(query, request: { try await probe.request($0, language: $1) })
    #expect(result.place.isEmpty && result.weatherCode == nil && result.photoData == nil)
    #expect(await probe.calls.isEmpty)
}
