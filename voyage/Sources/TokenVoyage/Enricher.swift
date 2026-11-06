import AppKit
import Foundation
import VoyageCore

struct Enrichment: Sendable {
    var weatherCode: Int?
    var temperatureC: Int?
    var place: [String: Letter.Place] = [:]
    var photoData: Data?
}

/// Fetches the sourced parts of a letter. Requests carry only a place name or coordinate, never usage.
enum Enricher {
    private static let userAgent = "TokenVoyage/0.1 (personal desktop app)"

    static func fetch(city: City, coordinate: Coordinate) async -> Enrichment {
        guard !city.isPlaceholder else { return Enrichment() }
        async let weather = fetchWeather(coordinate)
        async let place = fetchPlace(city)
        let (conditions, placeResult) = await (weather, place)
        var result = Enrichment(weatherCode: conditions?.code, temperatureC: conditions?.temperature)
        if let (language, summary) = placeResult {
            if let extract = summary.extract {
                result.place[language] = Letter.Place(title: summary.title, summary: String(extract.prefix(180)), url: summary.content_urls?.desktop?.page)
            }
            if let source = summary.thumbnail?.source, let url = URL(string: source) {
                result.photoData = try? await request(url)
            }
        }
        return result
    }

    private static func request(_ url: URL, language: String? = nil) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let language { request.setValue(language, forHTTPHeaderField: "Accept-Language") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private struct WeatherResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
        }
        let current: Current
    }

    private static func fetchWeather(_ coordinate: Coordinate) async -> (code: Int, temperature: Int)? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", coordinate.lat)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", coordinate.lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
        ]
        guard let url = components?.url,
              let data = try? await request(url),
              let decoded = try? JSONDecoder().decode(WeatherResponse.self, from: data) else { return nil }
        return (decoded.current.weather_code, Int(decoded.current.temperature_2m.rounded()))
    }

    static func weatherName(_ code: Int) -> String {
        switch code {
        case 0: "晴"
        case 1, 2: "少云"
        case 3: "阴"
        case 45, 48: "雾"
        case 51...57: "毛毛雨"
        case 61...67, 80...82: "雨"
        case 71...77, 85, 86: "雪"
        case 95...99: "雷雨"
        default: "天气未知"
        }
    }

    private struct PageSummary: Decodable {
        struct Thumbnail: Decodable { let source: String }
        struct ContentURLs: Decodable {
            struct Desktop: Decodable { let page: String }
            let desktop: Desktop?
        }
        let title: String
        let extract: String?
        let thumbnail: Thumbnail?
        let content_urls: ContentURLs?
    }

    private static func fetchPlace(_ city: City) async -> (String, PageSummary)? {
        for (host, title, language) in [("zh", city.wikipedia["zh-Hans"], "zh-cn"), ("en", city.wikipedia["en"], "en")] {
            guard let title, !title.isEmpty,
                  let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))),
                  let url = URL(string: "https://\(host).wikipedia.org/api/rest_v1/page/summary/\(encoded)"),
                  let data = try? await request(url, language: language),
                  let summary = try? JSONDecoder().decode(PageSummary.self, from: data) else { continue }
            return (host == "zh" ? "zh-Hans" : "en", summary)
        }
        return nil
    }

    private static let photoPalette: [UInt32] = [
        0x1D1A39, 0x3A3560, 0x8E86B8, 0xC9C3DE, 0xF7EBD0, 0xF4B63F, 0xC9852B, 0xE5533D,
        0x993C2D, 0x8A5A3C, 0x5E3B2A, 0x3F7F5F, 0x7FB069, 0x2B6C8F, 0x5FA3C7, 0x7FD1C7,
    ]

    /// Downsamples to 96x48, then maps to a 16 colour palette with light ordered dithering.
    static func pixelate(_ data: Data) -> Data? {
        guard let source = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
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
                pixels[y * width + x] = photoPalette.min { a, b in
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
