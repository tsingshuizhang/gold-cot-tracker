import XCTest

@MainActor
final class GoldCotTrackerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        app = nil
        super.tearDown()
    }

    func testDashboardPeriodSwitching() {
        let picker = app.segmentedControls["dashboard.periodPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 30), "持仓页时间维度选择器未出现")

        for title in ["月", "季", "年", "周"] {
            let segment = picker.buttons[title]
            XCTAssertTrue(segment.waitForExistence(timeout: 5), "缺少周期按钮：\(title)")
            segment.tap()
            XCTAssertTrue(waitUntil({ segment.isSelected || (segment.value as? String) == "1" }),
                          "周期按钮未进入选中状态：\(title)")
            capture(name: "dashboard-\(title)")
        }
    }

    func testRealtimeRangeZoomAndReset() {
        let realtimeTab = app.tabBars.buttons["实时行情"]
        XCTAssertTrue(realtimeTab.waitForExistence(timeout: 10))
        realtimeTab.tap()

        let slider = app.otherElements["realtime.rangeSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 30), "实时行情时间轴滑块未出现")
        if !slider.isHittable {
            let mainScroll = app.scrollViews["realtime.mainScroll"]
            XCTAssertTrue(mainScroll.exists, "未找到实时页主滚动区")
            let initialY = slider.frame.minY
            // 从右侧空白边缘受控上滑；swipeUp 的快速轻扫在图表区域不会滚动页面。
            let start = mainScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.78))
            let end = mainScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.22))
            start.press(forDuration: 0.1, thenDragTo: end)
            XCTAssertTrue(waitUntil({ slider.frame.minY < initialY - 20 }),
                          "主滚动区未移动，滑块 frame=\(slider.frame)")
        }
        XCTAssertTrue(waitUntil({ slider.isHittable }),
                      "实时行情时间轴滑块滚动后仍不可点击，frame=\(slider.frame)")
        capture(name: "realtime-initial")
        let windowLabel = app.staticTexts["realtime.rangeSlider.label"]
        XCTAssertTrue(windowLabel.exists, "实时行情时间区间文字未出现")
        let fullRangeLabel = windowLabel.label

        drag(slider, fromX: 0.05, toX: 0.35)
        XCTAssertTrue(waitUntil({ windowLabel.label != fullRangeLabel }),
                      "拖动左滑块后时间区间没有变化")
        capture(name: "realtime-left-zoom")

        slider.doubleTap()
        XCTAssertTrue(waitUntil({ windowLabel.label == fullRangeLabel }),
                      "双击后未恢复完整时间区间")

        drag(slider, fromX: 0.95, toX: 0.65)
        XCTAssertTrue(waitUntil({ windowLabel.label != fullRangeLabel }),
                      "拖动右滑块后时间区间没有变化")
        capture(name: "realtime-right-zoom")

        slider.doubleTap()
        XCTAssertTrue(waitUntil({ windowLabel.label == fullRangeLabel }),
                      "右侧缩放后双击未复位")
    }

    private func drag(_ element: XCUIElement, fromX: Double, toX: Double) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: 0.5))
        let end = element.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: end)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func capture(name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
