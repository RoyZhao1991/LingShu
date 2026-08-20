import AppKit
import XCTest
@testable import LingShuMac

@MainActor
final class AutonomousWindowControllerTests: XCTestCase {
    func testAutonomousWindowRestoresNativeTitlebarAndTrafficLights() {
        let window = makeStandardWindow()
        defer { close(window) }
        let original = Baseline(window)

        LingShuAutonomousWindowMode.setActive(true, on: window, animate: false)

        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertNil(window.standardWindowButton(.closeButton))
        XCTAssertNil(window.standardWindowButton(.miniaturizeButton))
        XCTAssertNil(window.standardWindowButton(.zoomButton))
        XCTAssertFalse(window.isOpaque)
        XCTAssertFalse(window.hasShadow)
        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(window.minSize, NSSize(width: 150, height: 210))

        LingShuAutonomousWindowMode.setActive(false, on: window, animate: false)

        assertRestored(window, to: original)
        XCTAssertGreaterThan(window.frame.height - window.contentLayoutRect.height, 0)
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
        XCTAssertNotNil(window.standardWindowButton(.zoomButton))
    }

    func testFreshCoordinatorCanRestoreSnapshotCapturedBeforeIdentityRebuild() {
        let window = makeStandardWindow()
        defer { close(window) }
        let original = Baseline(window)

        LingShuAutonomousWindowMode.setActive(true, on: window, animate: false)
        let replacementCoordinator = LingShuAutonomousWindowController.Coordinator()
        replacementCoordinator.update(active: false, window: window)

        assertRestored(window, to: original)
    }

    func testRapidAndRepeatedTransitionsAreIdempotent() {
        let window = makeStandardWindow()
        defer { close(window) }
        let original = Baseline(window)

        LingShuAutonomousWindowMode.setActive(true, on: window, animate: false)
        LingShuAutonomousWindowMode.setActive(true, on: window, animate: false)
        LingShuAutonomousWindowMode.setActive(false, on: window, animate: false)
        LingShuAutonomousWindowMode.setActive(false, on: window, animate: false)
        assertRestored(window, to: original)

        for _ in 0..<10 {
            LingShuAutonomousWindowMode.setActive(true, on: window, animate: false)
            LingShuAutonomousWindowMode.setActive(false, on: window, animate: false)
            assertRestored(window, to: original)
        }
    }

    func testExitRestoresTheActualPreAutonomyMinimalWindowAttributes() {
        let window = makeStandardWindow()
        defer { close(window) }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.level = .floating
        window.minSize = NSSize(width: 320, height: 480)
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        let original = Baseline(window)

        LingShuAutonomousWindowMode.setActive(true, on: window, animate: false)
        LingShuAutonomousWindowMode.setActive(false, on: window, animate: false)

        assertRestored(window, to: original)
        XCTAssertTrue(window.standardWindowButton(.closeButton)?.isHidden == true)
    }

    private func makeStandardWindow() -> NSWindow {
        // Keep the fixture fully inside the runner's virtual display. A fixed
        // 1240 x 820 content rect is larger than the visible frame exposed by
        // some GitHub macOS runners, so AppKit legitimately constrains it when
        // the titled style is restored and makes an exact snapshot comparison
        // impossible. The production window still uses its real captured frame.
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let contentSize = NSSize(
            width: min(900, visibleFrame.width * 0.7),
            height: min(600, visibleFrame.height * 0.6)
        )
        let contentRect = NSRect(
            x: visibleFrame.midX - contentSize.width / 2,
            y: visibleFrame.midY - contentSize.height / 2,
            width: contentSize.width,
            height: contentSize.height
        )
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "灵枢"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = true
        window.level = .normal
        window.minSize = contentSize
        window.isMovableByWindowBackground = false
        XCTAssertTrue(
            visibleFrame.contains(window.frame),
            "Autonomous-window test fixture must begin inside the visible screen"
        )
        return window
    }

    private func close(_ window: NSWindow) {
        LingShuAutonomousWindowMode.setActive(false, on: window, animate: false)
        window.orderOut(nil)
        window.close()
    }

    private func assertRestored(_ window: NSWindow, to baseline: Baseline, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(window.styleMask, baseline.styleMask, file: file, line: line)
        XCTAssertEqual(window.frame, baseline.frame, file: file, line: line)
        XCTAssertEqual(window.isOpaque, baseline.isOpaque, file: file, line: line)
        XCTAssertEqual(window.backgroundColor, baseline.backgroundColor, file: file, line: line)
        XCTAssertEqual(window.hasShadow, baseline.hasShadow, file: file, line: line)
        XCTAssertEqual(window.isMovableByWindowBackground, baseline.isMovableByWindowBackground, file: file, line: line)
        XCTAssertEqual(window.level, baseline.level, file: file, line: line)
        XCTAssertEqual(window.minSize, baseline.minSize, file: file, line: line)
        XCTAssertEqual(window.titleVisibility, baseline.titleVisibility, file: file, line: line)
        XCTAssertEqual(window.titlebarAppearsTransparent, baseline.titlebarAppearsTransparent, file: file, line: line)
        XCTAssertEqual(window.titlebarSeparatorStyle, baseline.titlebarSeparatorStyle, file: file, line: line)
        XCTAssertEqual(window.collectionBehavior, baseline.collectionBehavior, file: file, line: line)
        XCTAssertTrue(window.styleMask.contains(.titled), file: file, line: line)
        XCTAssertTrue(window.styleMask.contains(.closable), file: file, line: line)
        XCTAssertTrue(window.styleMask.contains(.miniaturizable), file: file, line: line)
        XCTAssertTrue(window.styleMask.contains(.resizable), file: file, line: line)
    }

    @MainActor
    private struct Baseline {
        let frame: NSRect
        let isOpaque: Bool
        let backgroundColor: NSColor?
        let hasShadow: Bool
        let styleMask: NSWindow.StyleMask
        let isMovableByWindowBackground: Bool
        let level: NSWindow.Level
        let minSize: NSSize
        let titleVisibility: NSWindow.TitleVisibility
        let titlebarAppearsTransparent: Bool
        let titlebarSeparatorStyle: NSTitlebarSeparatorStyle
        let collectionBehavior: NSWindow.CollectionBehavior

        init(_ window: NSWindow) {
            frame = window.frame
            isOpaque = window.isOpaque
            backgroundColor = window.backgroundColor
            hasShadow = window.hasShadow
            styleMask = window.styleMask
            isMovableByWindowBackground = window.isMovableByWindowBackground
            level = window.level
            minSize = window.minSize
            titleVisibility = window.titleVisibility
            titlebarAppearsTransparent = window.titlebarAppearsTransparent
            titlebarSeparatorStyle = window.titlebarSeparatorStyle
            collectionBehavior = window.collectionBehavior
        }
    }
}
