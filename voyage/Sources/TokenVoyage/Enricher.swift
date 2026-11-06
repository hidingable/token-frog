import AppKit
import Foundation
import ImageIO
import VoyageCore

struct Enrichment: Sendable {
    var weatherCode: Int?
    var temperatureC: Int?
    var place: [String: Letter.Place] = [:]
    var photoData: Data?
}

/// Fetches the sourced parts of a letter. Requests carry only a place identifier or coordinate, never usage.
enum Enricher {
    private static let userAgent = "TokenVoyage/0.1 (personal desktop app)"
    private static let placeCache = PlaceCache()
    static let maximumJSONBytes = 2 * 1_024 * 1_024
    static let maximumPhotoBytes = 5 * 1_024 * 1_024
    private static let session = URLSession(configuration: sessionConfiguration(), delegate: RedirectPolicy(), delegateQueue: nil)

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    static func allowsRedirect(to url: URL) -> Bool {
        guard let url = SafeLink.url(url.absoluteString), let host = url.host else { return false }
        return ["open-meteo.com", "wikipedia.org", "wikidata.org", "upload.wikimedia.org"].contains {
            SafeLink.host(host, belongsTo: $0)
        }
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map { allowsRedirect(to: $0) } == true ? request : nil)
        }
    }

    /// This input deliberately has no usage, project, or journey data.
    struct Query: Sendable {
        var city: City
        var coordinate: Coordinate
        var language: Language
        var includeWeather: Bool
        var includePhoto: Bool
        var includePlace: Bool
    }

    typealias Fetch = @Sendable (Query) async -> Enrichment
    typealias Request = @Sendable (URL, String?) async throws -> Data

    /// A run-local cache, injectable so isolated requests and tests never share results.
    actor PlaceCache {
        private struct Key: Hashable {
            let cityID: String
            let language: Language
        }
        private var values: [Key: CachedPlace] = [:]

        fileprivate func value(cityID: String, language: Language) -> CachedPlace? {
            values[Key(cityID: cityID, language: language)]
        }

        fileprivate func store(_ value: CachedPlace, cityID: String, language: Language) {
            values[Key(cityID: cityID, language: language)] = value
        }
    }

    static func fetch(_ query: Query, request: Request = networkRequest, cache: PlaceCache = placeCache) async -> Enrichment {
        guard !query.city.isPlaceholder else { return Enrichment() }
        async let weather = query.includeWeather ? fetchWeather(query.coordinate, request: request) : nil
        async let page = query.includePlace || query.includePhoto
            ? fetchPlace(query.city, language: query.language, request: request, cache: cache) : nil
        let (conditions, summary) = await (weather, page)
        var result = Enrichment(weatherCode: conditions?.code, temperatureC: conditions?.temperature)
        if let summary {
            if query.includePlace, let extract = summary.extract, !extract.isEmpty {
                result.place[query.language.rawValue] = Letter.Place(
                    title: summary.title, summary: String(extract.prefix(180)), url: summary.content_urls?.desktop?.page
                )
            }
            if query.includePhoto, let source = summary.thumbnail?.source, let url = SafeLink.url(source),
               url.host?.lowercased() == "upload.wikimedia.org",
               let data = try? await request(url, nil), data.count <= maximumPhotoBytes {
                result.photoData = data
            }
        }
        return result
    }

    private static func networkRequest(_ url: URL, language: String? = nil) async throws -> Data {
        try await networkRequest(url, language: language) { request in
            let (bytes, response) = try await session.bytes(for: request)
            return (bytes, response, { bytes.task.cancel() })
        }
    }

    /// The transport supplies a stream, so oversized bodies are cancelled before they can be buffered in full.
    static func networkRequest<Body: AsyncSequence>(
        _ url: URL, language: String? = nil,
        transport: (URLRequest) async throws -> (bytes: Body, response: URLResponse, cancel: @Sendable () -> Void)
    ) async throws -> Data where Body.Element == UInt8 {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let language { request.setValue(language, forHTTPHeaderField: "Accept-Language") }
        let (bytes, response, cancel) = try await transport(request)
        defer { cancel() }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let limit = url.host?.lowercased() == "upload.wikimedia.org" ? maximumPhotoBytes : maximumJSONBytes
        guard response.expectedContentLength <= Int64(limit) else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }

    private struct WeatherResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
        }
        let current: Current
    }

    private static func fetchWeather(_ coordinate: Coordinate, request: Request) async -> (code: Int, temperature: Int)? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", coordinate.lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", coordinate.lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
        ]
        guard let url = components?.url,
              let data = try? await request(url, nil),
              data.count <= maximumJSONBytes,
              let decoded = try? JSONDecoder().decode(WeatherResponse.self, from: data) else { return nil }
        return (decoded.current.weather_code, Int(decoded.current.temperature_2m.rounded()))
    }

    static let weatherKeys = [
        "weather.clear", "weather.partlyCloudy", "weather.overcast", "weather.fog", "weather.drizzle",
        "weather.rain", "weather.snow", "weather.thunderstorm", "weather.unknown",
    ]

    static func weatherName(_ code: Int, l10n: L10n) -> String {
        let index: Int
        switch code {
        case 0: index = 0
        case 1, 2: index = 1
        case 3: index = 2
        case 45, 48: index = 3
        case 51...57: index = 4
        case 61...67, 80...82: index = 5
        case 71...77, 85, 86: index = 6
        case 95...99: index = 7
        default: index = 8
        }
        return l10n(weatherKeys[index])
    }

    fileprivate struct PageSummary: Decodable, Sendable {
        struct Thumbnail: Decodable, Sendable { let source: String }
        struct ContentURLs: Decodable, Sendable {
            struct Desktop: Decodable, Sendable {
                let page: String?
                private enum CodingKeys: String, CodingKey { case page }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    let value = try container.decode(String.self, forKey: .page)
                    if let url = SafeLink.url(value), let host = url.host, SafeLink.host(host, belongsTo: "wikipedia.org") {
                        page = url.absoluteString
                    } else {
                        page = nil
                    }
                }
            }
            let desktop: Desktop?
        }
        let title: String
        let extract: String?
        let thumbnail: Thumbnail?
        let content_urls: ContentURLs?
    }

    fileprivate enum CachedPlace: Sendable {
        case missing
        case title(String)
        case summary(PageSummary)
    }

    private struct WikidataResponse: Decodable {
        struct Entity: Decodable {
            struct Sitelink: Decodable { let title: String }
            let sitelinks: [String: Sitelink]?
        }
        let entities: [String: Entity]
    }

    private static func fetchPlace(_ city: City, language: Language, request: Request, cache: PlaceCache) async -> PageSummary? {
        let host = language == .zhHans ? "zh" : "en"
        let title: String
        switch await cache.value(cityID: city.id, language: language) {
        case .summary(let summary): return summary
        case .missing: return nil
        case .title(let cachedTitle): title = cachedTitle
        case nil:
            if let localTitle = city.wikipedia[language.rawValue], !localTitle.isEmpty {
                title = localTitle
            } else {
                guard let wikidata = city.wikidata else { return nil }
                var components = URLComponents(string: "https://www.wikidata.org/w/api.php")
                components?.queryItems = [
                    URLQueryItem(name: "action", value: "wbgetentities"),
                    URLQueryItem(name: "ids", value: wikidata.uppercased()),
                    URLQueryItem(name: "props", value: "sitelinks"),
                    URLQueryItem(name: "sitefilter", value: "zhwiki|enwiki"),
                    URLQueryItem(name: "format", value: "json"),
                ]
                guard let url = components?.url else { return nil }
                do {
                    let data = try await request(url, nil)
                    guard data.count <= maximumJSONBytes else { return nil }
                    let response = try JSONDecoder().decode(WikidataResponse.self, from: data)
                    guard let resolved = response.entities[wikidata.uppercased()]?.sitelinks?["\(host)wiki"]?.title,
                          !resolved.isEmpty else {
                        await cache.store(.missing, cityID: city.id, language: language)
                        return nil
                    }
                    title = resolved
                    // Keep a resolved title if the subsequent summary request temporarily fails.
                    await cache.store(.title(title), cityID: city.id, language: language)
                } catch {
                    return nil
                }
            }
        }
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))),
              let url = URL(string: "https://\(host).wikipedia.org/api/rest_v1/page/summary/\(encoded)"),
              let data = try? await request(url, language == .zhHans ? "zh-cn" : "en"),
              data.count <= maximumJSONBytes,
              let summary = try? JSONDecoder().decode(PageSummary.self, from: data) else { return nil }
        await cache.store(.summary(summary), cityID: city.id, language: language)
        return summary
    }

    /// Downsamples to 96x48, then maps to a 16 colour palette with light ordered dithering.
    static func pixelate(_ data: Data, palette: [UInt32]) -> Data? {
        guard data.count <= maximumPhotoBytes,
              let imageSource = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let source = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 192,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        let width = 96
        let height = 48
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            let aspect = max(Double(width) / Double(source.width), Double(height) / Double(source.height))
            let drawWidth = Double(source.width) * aspect
            let drawHeight = Double(source.height) * aspect
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: (Double(width) - drawWidth) / 2, y: (Double(height) - drawHeight) / 2, width: drawWidth, height: drawHeight))
            return true
        }
        guard drawn else { return nil }

        let bayer: [Int] = [-6, 2, -4, 4, 6, -2, 8, 0, -3, 5, -5, 3, 7, -1, 9, 1]
        var pixels = [UInt32?](repeating: nil, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let shift = bayer[(y % 4) * 4 + x % 4]
                let red = Int(buffer[offset]) + shift
                let green = Int(buffer[offset + 1]) + shift
                let blue = Int(buffer[offset + 2]) + shift
                pixels[y * width + x] = palette.min { a, b in
                    distance(a, red, green, blue) < distance(b, red, green, blue)
                }
            }
        }
        let image = PixelImage.make(width: width, height: height, pixels: pixels)
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func distance(_ color: UInt32, _ red: Int, _ green: Int, _ blue: Int) -> Int {
        let dr = Int((color >> 16) & 0xFF) - red
        let dg = Int((color >> 8) & 0xFF) - green
        let db = Int(color & 0xFF) - blue
        return dr * dr * 2 + dg * dg * 4 + db * db * 3
    }
}
