import Foundation
import SwiftUI
import Testing
@testable import TokenVoyage

@MainActor private func width(_ view: some View, available: CGFloat = 56) throws -> CGFloat {
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(width: available, height: 37)
    return try #require(renderer.nsImage).size.width
}

@MainActor @Suite struct NotchCollapsedContentTests {
    @Test func aNextStopThatFitsIsShownInFull() throws {
        let text = "→ 杭州"
        let content = NotchCollapsedProgress(destination: text, progress: 0)
        #expect(try width(content, available: 160) == width(Text(text).font(Theme.pixel()).fixedSize(), available: 160))
        #expect(try NotchCollapsedProgress.width(destination: text) == width(content, available: NotchCollapsedProgress.maximumNextStopWidth))
    }

    @Test func aLongNextStopFallsBackToSixBlocks() throws {
        let content = NotchCollapsedProgress(destination: String(repeating: "wide ", count: 40), progress: 0.5)
        #expect(try width(content) == width(BlockProgress(progress: 0.5, blocks: 6, size: 5)))
        #expect(try width(content) == 40)
        #expect(NotchCollapsedProgress.width(destination: String(repeating: "wide ", count: 40)) == 40)
    }
}
