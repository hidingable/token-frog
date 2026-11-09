import Foundation
import SwiftUI
import Testing
@testable import TokenVoyage

/// Compares the chosen layout rather than pixels, which differ between renders under parallel test load.
@MainActor private func width(_ view: some View) throws -> CGFloat {
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(width: 96, height: 37)
    return try #require(renderer.nsImage).size.width
}

@MainActor @Suite struct NotchShoulderStatusTests {
    private let tooLong = String(repeating: "wide ", count: 40)

    @Test func aLabelThatFitsIsShownInFull() throws {
        let full = try width(NotchShoulderStatus(label: "A longer label", distance: "23 km", unread: 0))
        let distance = try width(NotchShoulderStatus(label: "23 km", distance: "23 km", unread: 0))
        #expect(full > distance)
    }

    @Test(arguments: [0, 5])
    func aLabelThatDoesNotFitFallsBackToTheDistance(unread: Int) throws {
        let actual = try width(NotchShoulderStatus(label: tooLong, distance: "23 km", unread: unread))
        let distance = try width(NotchShoulderStatus(label: "23 km", distance: "23 km", unread: unread))
        #expect(actual == distance)
    }

    @Test func theMailBadgeStaysWhenNoTextFitsBesideIt() throws {
        let actual = try width(NotchShoulderStatus(label: tooLong, distance: tooLong, unread: 5))
        #expect(actual == (try width(MailBadge(count: 5))))
    }
}
