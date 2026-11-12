import Foundation
import SwiftUI
import Testing
@testable import TokenVoyage

@Suite struct NotchMetricsTests {
    private let screen = CGRect(x: -1728, y: 120, width: 1728, height: 1117)

    @Test func bodyCoversTheNativeGapOnAnOffsetScreen() {
        let metrics = NotchMetrics(notchSize: CGSize(width: 185, height: 37), menuBarHeight: 24,
                                   leftChipWidth: 98, notchCenterOffsetX: 25)
        let body = metrics.bodyFrame(screenFrame: screen)
        #expect(body == CGRect(x: screen.midX + 25 - 92.5, y: screen.maxY - 37, width: 185, height: 37))
        let collapsed = metrics.frame(screenFrame: screen, expanded: false)
        #expect(collapsed.minX + metrics.bodyRect.minX == body.minX)
        #expect(collapsed.maxY - metrics.bodyRect.maxY == body.minY)
        #expect(metrics.leftChipRect.midY == 12)
        #expect(metrics.leftChipRect.height == 24)
    }

    @Test(arguments: [CGSize(width: 180, height: 37), CGSize(width: 210, height: 35)])
    func notchlessScreenUsesTheReferenceSizeAtItsTopCenter(reference: CGSize) {
        let metrics = NotchMetrics(notchSize: reference, menuBarHeight: 24)
        let body = metrics.bodyFrame(screenFrame: screen)
        #expect(body.size == reference)
        #expect(body.midX == screen.midX && body.maxY == screen.maxY)
        #expect(body.minY < screen.maxY - metrics.menuBarHeight)
        #expect(metrics.frame(screenFrame: screen, expanded: false).height == reference.height)
    }

    @Test func notchlessScreenHasNamedWidthAndHeightFallbacks() {
        let metrics = NotchMetrics(menuBarHeight: 24)
        #expect(metrics.notchSize == CGSize(width: 185, height: 32))
        #expect(metrics.notchSize == NotchMetrics.fallbackNotchSize)
    }

    @Test(arguments: [CGFloat(82), 98, 138], [CGFloat(0), 32])
    func collapsedBoundsIncludeOnlyChipsGapsAndBody(leftWidth: CGFloat, rightWidth: CGFloat) {
        let metrics = NotchMetrics(menuBarHeight: 24, leftChipWidth: leftWidth, rightChipWidth: rightWidth)
        #expect(metrics.collapsedSize == CGSize(width: leftWidth + 6 + 185 + (rightWidth > 0 ? 6 + rightWidth : 0), height: 32))
        #expect(metrics.bodyRect.minX - metrics.leftChipRect.maxX == NotchMetrics.chipGap)
        if rightWidth > 0 {
            #expect(metrics.rightChipRect.minX - metrics.bodyRect.maxX == NotchMetrics.chipGap)
            #expect(metrics.rightChipRect.maxX == metrics.collapsedSize.width)
            #expect(metrics.rightChipRect.midY == metrics.leftChipRect.midY)
        } else {
            #expect(metrics.bodyRect.maxX == metrics.collapsedSize.width)
        }
    }

    @Test func collapsedHeightIsTheVisibleUnionRatherThanTheWholeMenuBar() {
        let metrics = NotchMetrics(menuBarHeight: 44)
        #expect(metrics.leftChipRect.midY == 22)
        #expect(metrics.collapsedSize.height == 34)
        #expect(metrics.collapsedSize.height == metrics.bodyRect.union(metrics.leftChipRect).height)
    }

    @Test func unreadChipDoesNotMoveTheBodyOrExpandedPanel() {
        var metrics = NotchMetrics(menuBarHeight: 24, notchCenterOffsetX: 25)
        let withoutMail = metrics.frame(screenFrame: screen, expanded: false)
        let body = metrics.bodyFrame(screenFrame: screen)
        let expanded = metrics.frame(screenFrame: screen, expanded: true)
        metrics.rightChipWidth = NotchMetrics.mailChipWidth
        let withMail = metrics.frame(screenFrame: screen, expanded: false)
        #expect(withMail.minX == withoutMail.minX)
        #expect(withMail.width - withoutMail.width == NotchMetrics.chipGap + NotchMetrics.mailChipWidth)
        #expect(metrics.bodyFrame(screenFrame: screen) == body)
        #expect(metrics.frame(screenFrame: screen, expanded: true) == expanded)
        #expect(expanded.midX == body.midX && expanded.maxY == screen.maxY)
    }

    @Test func animationBoundsCoverBothStatesEvenWithAWideChip() {
        let metrics = NotchMetrics(menuBarHeight: 24, leftChipWidth: 300, rightChipWidth: 32)
        let canvas = metrics.animationFrame(screenFrame: screen)
        #expect(canvas.contains(metrics.frame(screenFrame: screen, expanded: false)))
        #expect(canvas.contains(metrics.frame(screenFrame: screen, expanded: true)))
        #expect(canvas.maxY == screen.maxY)
    }

    @Test func shellPathBoundsMatchBothEndpoints() {
        let body = CGRect(x: 13, y: 7, width: 185, height: 32)
        let panel = CGRect(x: -50, y: 10, width: 665, height: 264)
        #expect(NotchShell(size: body.size).path(in: body).boundingRect == body)
        let expanded = NotchShell(size: panel.size, topRadius: NotchShell.panelTopRadius,
                                  bottomRadius: NotchShell.panelBottomRadius)
        #expect(expanded.path(in: panel).boundingRect == panel)
        // The top flares extend to the panel bounds, but the sides below them are inset.
        #expect(!expanded.path(in: panel).contains(CGPoint(x: panel.minX + 1, y: panel.minY + 20)))
        #expect(expanded.path(in: panel).contains(CGPoint(x: panel.midX, y: panel.midY)))
    }

    @Test func shellSpringOvershootStaysInsideItsCanvas() {
        let panel = CGRect(x: 0, y: 0, width: 665, height: 264)
        let shell = NotchShell(size: CGSize(width: 680, height: 280), topRadius: 8, bottomRadius: 22)
        #expect(shell.path(in: panel).boundingRect == panel)
    }
}

@Suite @MainActor struct NotchPresentationTests {
    @Test func snapshotTransitionsAlwaysReachTheirFinalFrame() {
        let screen = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
        let metrics = NotchMetrics(menuBarHeight: 24)
        let presentation = NotchPresentation(metrics: metrics, screenFrame: screen, animationsEnabled: false)
        var frames: [CGRect] = []
        presentation.onFrameChange = { frames.append($0) }
        for expanded in [true, false, true, false, true] {
            presentation.setExpanded(expanded)
            #expect(presentation.shellExpanded == expanded)
            #expect(presentation.contentVisible == expanded)
            #expect(presentation.chipsVisible != expanded)
            #expect(!presentation.transitioning)
            #expect(presentation.canvasFrame == metrics.frame(screenFrame: screen, expanded: expanded))
        }
        #expect(frames.count == 5)
        var unreadMetrics = metrics
        unreadMetrics.rightChipWidth = NotchMetrics.mailChipWidth
        presentation.updateMetrics(unreadMetrics)
        presentation.setExpanded(false)
        #expect(presentation.mailVisible)
        #expect(presentation.canvasFrame == unreadMetrics.frame(screenFrame: screen, expanded: false))
        presentation.updateMetrics(metrics)
        #expect(!presentation.mailVisible)
        #expect(presentation.canvasFrame == metrics.frame(screenFrame: screen, expanded: false))
    }

    @Test func changingReduceMotionCancelsSupersededTransitions() async throws {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let metrics = NotchMetrics(menuBarHeight: 24)
        let presentation = NotchPresentation(metrics: metrics, screenFrame: screen, animationsEnabled: true)
        defer { presentation.cancel() }
        presentation.setExpanded(true)
        presentation.setExpanded(false)
        presentation.setExpanded(true)
        presentation.setReduceMotion(true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(presentation.expanded && presentation.shellExpanded && presentation.contentVisible)
        #expect(!presentation.transitioning && !presentation.chipsVisible)
        #expect(presentation.canvasFrame == metrics.frame(screenFrame: screen, expanded: true))
        presentation.setExpanded(false)
        presentation.setReduceMotion(false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!presentation.expanded && !presentation.shellExpanded && !presentation.contentVisible)
        #expect(!presentation.transitioning && presentation.chipsVisible)
        #expect(presentation.canvasFrame == metrics.frame(screenFrame: screen, expanded: false))
    }

    @Test func reentryCancelsTheExistingHoverOutDelay() async throws {
        let metrics = NotchMetrics(menuBarHeight: 24)
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let presentation = NotchPresentation(metrics: metrics, screenFrame: screen, animationsEnabled: false)
        defer { presentation.cancel() }
        presentation.hover(true)
        presentation.hover(false)
        #expect(presentation.expanded)
        presentation.hover(true)
        try await Task.sleep(for: .milliseconds(280))
        #expect(presentation.expanded && presentation.contentVisible)
        presentation.hover(false)
        // Native rendering in other suites can occupy the main actor before the child task starts.
        for _ in 0..<100 where presentation.expanded {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!presentation.expanded && presentation.chipsVisible)
        #expect(presentation.canvasFrame == metrics.frame(screenFrame: screen, expanded: false))
    }
}
