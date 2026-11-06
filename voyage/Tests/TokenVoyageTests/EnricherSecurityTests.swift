import AppKit
import Foundation
import ImageIO
import Testing
import VoyageCore
@testable import TokenVoyage

@Test(arguments: ["file:///etc/passwd", "javascript:alert(1)", "http://example.com", "voyage://example.com",
                  "https:///", "https:/", "https://", "https://?query", "", "//example.com"])
func unsafeExternalLinksAreRejected(value: String) {
    #expect(SafeLink.url(value) == nil)
}

@Test func externalLinksRequireAHostAndRespectTheLengthLimit() {
    #expect(SafeLink.url("https://example.com/path?q=1#section") != nil)
    #expect(SafeLink.url("HTTPS://EXAMPLE.COM/path") != nil)
    let prefix = "https://example.com/"
    let longest = prefix + String(repeating: "a", count: 2_048 - prefix.count)
    #expect(SafeLink.url(longest) != nil)
    #expect(SafeLink.url(longest + "a") == nil)
}

@Test(arguments: ["https://open-meteo.com/path", "https://api.open-meteo.com/path", "https://wikipedia.org/path",
                  "https://en.wikipedia.org/path", "https://www.wikidata.org/path", "https://upload.wikimedia.org/path",
                  "https://sub.upload.wikimedia.org/path", "https://ZH.WIKIPEDIA.ORG/path"])
func enrichmentRedirectsAllowOnlyTrustedHTTPSDomains(value: String) throws {
    #expect(Enricher.allowsRedirect(to: try #require(URL(string: value))))
}

@Test(arguments: ["http://en.wikipedia.org/path", "file:///tmp/photo", "https://example.com/path",
                  "https://evilwikipedia.org/path", "https://wikipedia.org.evil.test/path", "https://wikimedia.org/path",
                  "https://upload.wikimedia.org.evil.test/path", "https://en.wikipedia.org@evil.test/path"])
func enrichmentRedirectsRejectOtherDestinations(value: String) throws {
    #expect(!Enricher.allowsRedirect(to: try #require(URL(string: value))))
}

@Test func enrichmentSessionKeepsNoDiskCacheOrCookies() {
    let configuration = Enricher.sessionConfiguration()
    #expect(configuration.urlCache == nil)
    #expect(configuration.httpCookieStorage == nil)
    #expect(!configuration.httpShouldSetCookies)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
}

private actor SecuritySummaryProbe {
    let summary: Data
    private(set) var calls: [URL] = []
    init(page: String = "https://en.wikipedia.org/wiki/Shanghai", thumbnail: String? = nil) throws {
        var json: [String: Any] = ["title": "Shanghai", "extract": String(repeating: "Summary. ", count: 50),
                                   "content_urls": ["desktop": ["page": page]]]
        if let thumbnail { json["thumbnail"] = ["source": thumbnail] }
        summary = try JSONSerialization.data(withJSONObject: json)
    }
    func request(_ url: URL, language: String?) -> Data {
        calls.append(url)
        return url.host == "en.wikipedia.org" ? summary : Data([1, 2, 3])
    }
}

private func securityEnrichmentQuery() -> Enricher.Query {
    let city = localizationCatalog.city("shanghai")
    return Enricher.Query(city: city, coordinate: city.coordinate, language: .en,
                          includeWeather: false, includePhoto: true, includePlace: true)
}

@Test(arguments: ["file:///tmp/photo.png", "http://upload.wikimedia.org/photo.png", "https://evil.test/photo.png",
                  "https://evilupload.wikimedia.org/photo.png", "https://upload.wikimedia.org.evil.test/photo.png",
                  "https://sub.upload.wikimedia.org/photo.png"])
func untrustedThumbnailsAreNeverRequested(source: String) async throws {
    let probe = try SecuritySummaryProbe(thumbnail: source)
    let result = await Enricher.fetch(securityEnrichmentQuery(), request: { await probe.request($0, language: $1) }, cache: Enricher.PlaceCache())
    #expect(await probe.calls.count == 1)
    #expect(result.photoData == nil)
    #expect(result.place["en"]?.summary.count == 180)
}

@Test func wikimediaThumbnailAndWikipediaPageRemainUsable() async throws {
    let probe = try SecuritySummaryProbe(thumbnail: "https://upload.wikimedia.org/photo.png")
    let result = await Enricher.fetch(securityEnrichmentQuery(), request: { await probe.request($0, language: $1) }, cache: Enricher.PlaceCache())
    #expect(await probe.calls.count == 2)
    #expect(result.photoData == Data([1, 2, 3]))
    #expect(result.place["en"]?.url == "https://en.wikipedia.org/wiki/Shanghai")
}

@Test(arguments: ["file:///etc/passwd", "http://en.wikipedia.org/wiki/Test", "https://evilwikipedia.org/wiki/Test",
                  "https://wikipedia.org.evil.test/wiki/Test", "https://evil.test/wiki/Test"])
func parsedWikipediaPagesDiscardUntrustedLinks(page: String) async throws {
    let probe = try SecuritySummaryProbe(page: page)
    let result = await Enricher.fetch(securityEnrichmentQuery(), request: { await probe.request($0, language: $1) }, cache: Enricher.PlaceCache())
    #expect(result.place["en"]?.url == nil)
    #expect(result.place["en"]?.summary.isEmpty == false)
}

private final class StreamProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let count: Int
    private var consumed = 0
    private var cancelled = false
    init(count: Int) { self.count = count }
    func next() -> UInt8? {
        lock.withLock {
            guard consumed < count else { return nil }
            consumed += 1
            return 32
        }
    }
    func cancel() { lock.withLock { cancelled = true } }
    var state: (consumed: Int, cancelled: Bool) { lock.withLock { (consumed, cancelled) } }
}

private struct CountingBody: AsyncSequence, AsyncIteratorProtocol {
    typealias Element = UInt8
    let progress: StreamProgress
    func makeAsyncIterator() -> CountingBody { self }
    mutating func next() async -> UInt8? { progress.next() }
}

@Test(arguments: ["api.open-meteo.com", "upload.wikimedia.org"])
func streamedResponsesStopAtTheByteLimitWithoutReadingTheRest(host: String) async throws {
    let url = try #require(URL(string: "https://\(host)/fixture"))
    let limit = (host == "upload.wikimedia.org" ? 5 : 2) * 1_024 * 1_024
    let progress = StreamProgress(count: limit + 100)
    let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    do {
        _ = try await Enricher.networkRequest(url) { _ in (CountingBody(progress: progress), response, { progress.cancel() }) }
        Issue.record("An oversized response must fail")
    } catch {
        #expect((error as? URLError)?.code == .dataLengthExceedsMaximum)
    }
    #expect(progress.state.consumed == limit + 1)
    #expect(progress.state.cancelled)
}

@Test(arguments: ["api.open-meteo.com", "upload.wikimedia.org"])
func streamedResponsesAtTheLimitRemainUsable(host: String) async throws {
    let url = try #require(URL(string: "https://\(host)/fixture"))
    let limit = (host == "upload.wikimedia.org" ? 5 : 2) * 1_024 * 1_024
    let progress = StreamProgress(count: limit)
    let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    let data = try await Enricher.networkRequest(url) { _ in (CountingBody(progress: progress), response, { progress.cancel() }) }
    #expect(data.count == limit)
    #expect(progress.state.consumed == limit && progress.state.cancelled)
}

@Test func declaredOversizedResponsesAreCancelledBeforeReading() async throws {
    let url = try #require(URL(string: "https://en.wikipedia.org/fixture"))
    let progress = StreamProgress(count: 10)
    let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                               headerFields: ["Content-Length": String(Enricher.maximumJSONBytes + 1)]))
    do {
        _ = try await Enricher.networkRequest(url) { _ in (CountingBody(progress: progress), response, { progress.cancel() }) }
        Issue.record("An oversized Content-Length must fail")
    } catch {
        #expect((error as? URLError)?.code == .dataLengthExceedsMaximum)
    }
    #expect(progress.state.consumed == 0 && progress.state.cancelled)
}

@Test func boundedResponsesKeepHeadersAndContents() async throws {
    let url = try #require(URL(string: "https://en.wikipedia.org/fixture"))
    let progress = StreamProgress(count: 3)
    let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    let data = try await Enricher.networkRequest(url, language: "en") { request in
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("TokenVoyage/") == true)
        return (CountingBody(progress: progress), response, { progress.cancel() })
    }
    #expect(data == Data(repeating: 32, count: 3))
    #expect(progress.state.consumed == 3 && progress.state.cancelled)
}

@Test func injectedOversizedJSONAndPhotosAreDiscarded() async throws {
    let summary = try SecuritySummaryProbe(thumbnail: "https://upload.wikimedia.org/photo.png")
    let result = await Enricher.fetch(securityEnrichmentQuery(), request: { url, language in
        if url.host == "upload.wikimedia.org" { return Data(repeating: 0, count: Enricher.maximumPhotoBytes + 1) }
        return await summary.request(url, language: language)
    }, cache: Enricher.PlaceCache())
    #expect(result.photoData == nil && result.place["en"] != nil)
    let tooLarge = await Enricher.fetch(securityEnrichmentQuery(), request: { _, _ in
        var data = summary.summary
        data.append(Data(repeating: 32, count: Enricher.maximumJSONBytes))
        return data
    }, cache: Enricher.PlaceCache())
    #expect(tooLarge.place.isEmpty && tooLarge.photoData == nil)
}

@Test func imageDecodingProducesSmallPixelsAndRejectsInvalidData() throws {
    #expect(Enricher.pixelate(Data("invalid image".utf8), palette: [0, 0xFFFFFF]) == nil)
    #expect(Enricher.pixelate(Data(repeating: 0, count: Enricher.maximumPhotoBytes + 1), palette: [0]) == nil)
    let context = try #require(CGContext(data: nil, width: 1_024, height: 512, bitsPerComponent: 8,
                                        bytesPerRow: 4_096, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try #require(context.makeImage())
    let input = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    let png = try #require(Enricher.pixelate(input, palette: [0, 0xFFFFFF]))
    let output = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 96)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 48)
}
