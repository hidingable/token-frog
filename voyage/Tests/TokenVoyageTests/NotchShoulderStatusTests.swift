import Foundation
import SwiftUI
import Testing
@testable import TokenVoyage

@MainActor private func pixels(_ view: some View) throws -> Data {
    let renderer = ImageRenderer(content: view.frame(width: 96, height: 37))
    let image = try #require(renderer.cgImage)
    return try #require(image.dataProvider?.data) as Data
}

@MainActor @Suite struct NotchShoulderStatusTests {
    private let tooLong = String(repeating: "wide ", count: 40)

    @Test func aLabelThatFitsIsShownInFull() throws {
        let full = try pixels(NotchShoulderStatus(label: "Hi", distance: "23 km", unread: 5))
        let distance = try pixels(NotchShoulderStatus(label: "23 km", distance: "23 km", unread: 5))
        #expect(full != distance)
    }

    @Test(arguments: [0, 5])
    func aLabelThatDoesNotFitFallsBackToTheDistance(unread: Int) throws {
        let actual = try pixels(NotchShoulderStatus(label: tooLong, distance: "23 km", unread: unread))
        let distance = try pixels(NotchShoulderStatus(label: "23 km", distance: "23 km", unread: unread))
        #expect(actual == distance)
    }

    @Test func theMailBadgeStaysWhenNoTextFitsBesideIt() throws {
        let actual = try pixels(NotchShoulderStatus(label: tooLong, distance: tooLong, unread: 5))
        #expect(actual == (try pixels(MailBadge(count: 5))))
    }
}
