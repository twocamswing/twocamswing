//
//  GolfSwingRTCUITests.swift
//  GolfSwingRTCUITests
//
//  Created by user on 24/09/2025.
//

import XCTest

final class GolfSwingRTCUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testStartSenderFlow() {
        let app = XCUIApplication()
        app.launch()

        let senderButton = app.buttons["Start as Sender (Camera)"]
        XCTAssertTrue(senderButton.waitForExistence(timeout: 5), "Sender button is not visible")
        senderButton.tap()

        // Give the sender view time to finish presenting so the camera spins up.
        sleep(5)

        // Verify we navigated away from the root menu.
        XCTAssertFalse(senderButton.exists, "Sender button still visible after tap")

        // Hold a bit longer so manual observers can confirm the feed is live before the test ends.
        sleep(5)
    }

    func testStartReceiverFlow() {
        let app = XCUIApplication()
        app.launch()

        let receiverButton = app.buttons["Start as Receiver (Viewer)"]
        XCTAssertTrue(receiverButton.waitForExistence(timeout: 5), "Receiver button is not visible")
        receiverButton.tap()

        // Allow the receiver UI to settle so the stream can subscribe.
        sleep(5)

        XCTAssertFalse(receiverButton.exists, "Receiver button still visible after tap")

        // Hold the viewer on screen briefly so you can confirm frames arrive.
        sleep(5)
    }
}
