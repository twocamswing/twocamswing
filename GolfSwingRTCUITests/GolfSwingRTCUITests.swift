//
//  GolfSwingRTCUITests.swift
//  GolfSwingRTCUITests
//
//  Created by user on 24/09/2025.
//

import XCTest

final class GolfSwingRTCUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Basic Flow Tests

    func testStartSenderFlow() {
        app.launch()

        let senderButton = app.buttons["senderButton"]
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
        app.launch()

        let receiverButton = app.buttons["receiverButton"]
        XCTAssertTrue(receiverButton.waitForExistence(timeout: 5), "Receiver button is not visible")
        receiverButton.tap()

        // Allow the receiver UI to settle so the stream can subscribe.
        sleep(5)

        XCTAssertFalse(receiverButton.exists, "Receiver button still visible after tap")

        // Hold the viewer on screen briefly so you can confirm frames arrive.
        sleep(5)
    }

    // MARK: - Library Tests

    func testOpenVideoLibrary() {
        app.launch()

        // Start receiver to access menu
        let receiverButton = app.buttons["receiverButton"]
        XCTAssertTrue(receiverButton.waitForExistence(timeout: 5), "Receiver button not found")
        receiverButton.tap()
        sleep(2)

        // Open burger menu
        let menuButton = app.buttons["menuButton"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 5), "Menu button not found")
        menuButton.tap()
        sleep(1)

        // Tap library button
        let libraryButton = app.buttons["libraryButton"]
        XCTAssertTrue(libraryButton.waitForExistence(timeout: 5), "Library button not found")
        libraryButton.tap()
        sleep(1)

        // Verify library is showing
        let collectionView = app.collectionViews["swingLibraryCollection"]
        XCTAssertTrue(collectionView.waitForExistence(timeout: 5), "Library collection not found")
    }

    func testLibraryEditModeToggle() {
        app.launch()

        // Navigate to library
        navigateToLibrary()

        // Tap Edit button
        let editButton = app.buttons["editButton"]
        if editButton.exists && editButton.isHittable {
            editButton.tap()
            sleep(1)

            // Verify bulk action buttons appear
            let selectAllButton = app.buttons["selectAllButton"]
            let deleteSelectedButton = app.buttons["deleteSelectedButton"]
            XCTAssertTrue(selectAllButton.waitForExistence(timeout: 2), "Select All button should appear in edit mode")
            XCTAssertTrue(deleteSelectedButton.exists, "Delete Selected button should appear in edit mode")

            // Toggle back to normal mode
            editButton.tap()
            sleep(1)

            // Buttons should be hidden
            XCTAssertFalse(selectAllButton.isHittable, "Select All button should be hidden after exiting edit mode")
        }
    }

    func testBulkSelectAll() {
        app.launch()

        // Navigate to library
        navigateToLibrary()

        let collectionView = app.collectionViews["swingLibraryCollection"]
        guard collectionView.exists else {
            XCTFail("Library collection not found")
            return
        }

        // Check if there are cells to select
        let cells = collectionView.cells
        guard cells.count > 0 else {
            // No swings to test with - this is expected on fresh install
            return
        }

        // Enter edit mode
        let editButton = app.buttons["editButton"]
        editButton.tap()
        sleep(1)

        // Tap Select All
        let selectAllButton = app.buttons["selectAllButton"]
        XCTAssertTrue(selectAllButton.waitForExistence(timeout: 2), "Select All button not found")
        selectAllButton.tap()
        sleep(1)

        // Verify delete button shows count
        let deleteButton = app.buttons["deleteSelectedButton"]
        XCTAssertTrue(deleteButton.exists, "Delete button not found")
        // The button title should show "Delete (N)" where N is the cell count
    }

    func testBulkDeleteFlow() {
        app.launch()

        // Navigate to library
        navigateToLibrary()

        let collectionView = app.collectionViews["swingLibraryCollection"]
        guard collectionView.exists else {
            XCTFail("Library collection not found")
            return
        }

        let initialCount = collectionView.cells.count
        guard initialCount > 0 else {
            // No swings to delete - skip test
            return
        }

        // Enter edit mode
        let editButton = app.buttons["editButton"]
        editButton.tap()
        sleep(1)

        // Select first cell
        let firstCell = collectionView.cells["swingCell_0"]
        if firstCell.exists {
            firstCell.tap()
            sleep(1)
        }

        // Tap Delete Selected
        let deleteButton = app.buttons["deleteSelectedButton"]
        deleteButton.tap()
        sleep(1)

        // Confirm delete in alert
        let deleteAlertButton = app.alerts.buttons["Delete"]
        if deleteAlertButton.waitForExistence(timeout: 2) {
            deleteAlertButton.tap()
            sleep(1)
        }

        // Verify count decreased
        let newCount = collectionView.cells.count
        XCTAssertEqual(newCount, initialCount - 1, "Cell count should decrease by 1 after deletion")
    }

    // MARK: - Capture Tests

    /// Test that captures multiple swings for library testing.
    /// NOTE: Requires sender device to be streaming for real captures.
    /// Run with: xcodebuild test -only-testing:GolfSwingRTCUITests/testCaptureMultipleSwings
    func testCaptureMultipleSwings() {
        app.launch()

        // Start receiver
        let receiverButton = app.buttons["receiverButton"]
        XCTAssertTrue(receiverButton.waitForExistence(timeout: 5), "Receiver button not found")
        receiverButton.tap()

        // Wait for UI to settle and connection to establish
        sleep(5)

        // Find replay button
        let replayButton = app.buttons["replayButton"]
        guard replayButton.waitForExistence(timeout: 10) else {
            XCTFail("Replay button not found - may need sender streaming")
            return
        }

        // Capture 3 swings
        for i in 1...3 {
            print("Capturing swing \(i)...")
            if replayButton.isEnabled && replayButton.isHittable {
                replayButton.tap()
                // Wait for replay to complete (slow-mo takes ~5-8 seconds)
                sleep(10)
            }
        }

        // Verify captures by checking library
        navigateToLibraryFromReceiver()

        let collectionView = app.collectionViews["swingLibraryCollection"]
        XCTAssertTrue(collectionView.waitForExistence(timeout: 5), "Library not found")
        XCTAssertGreaterThanOrEqual(collectionView.cells.count, 3, "Should have at least 3 captured swings")
    }

    /// End-to-end test: Capture swings, then bulk delete them
    func testCaptureAndBulkDelete() {
        app.launch()

        // Start receiver
        let receiverButton = app.buttons["receiverButton"]
        XCTAssertTrue(receiverButton.waitForExistence(timeout: 5), "Receiver button not found")
        receiverButton.tap()
        sleep(5)

        // Capture 2 swings
        let replayButton = app.buttons["replayButton"]
        if replayButton.waitForExistence(timeout: 10) && replayButton.isHittable {
            for _ in 1...2 {
                if replayButton.isEnabled {
                    replayButton.tap()
                    sleep(10)
                }
            }
        }

        // Navigate to library
        navigateToLibraryFromReceiver()

        let collectionView = app.collectionViews["swingLibraryCollection"]
        guard collectionView.waitForExistence(timeout: 5) else {
            XCTFail("Library collection not found")
            return
        }

        let initialCount = collectionView.cells.count
        guard initialCount >= 2 else {
            print("Not enough swings to test bulk delete (have \(initialCount))")
            return
        }

        // Enter edit mode and select all
        let editButton = app.buttons["editButton"]
        editButton.tap()
        sleep(1)

        let selectAllButton = app.buttons["selectAllButton"]
        selectAllButton.tap()
        sleep(1)

        // Delete all
        let deleteButton = app.buttons["deleteSelectedButton"]
        deleteButton.tap()
        sleep(1)

        // Confirm delete
        let confirmDelete = app.alerts.buttons["Delete"]
        if confirmDelete.waitForExistence(timeout: 2) {
            confirmDelete.tap()
            sleep(2)
        }

        // Verify all deleted
        let finalCount = collectionView.cells.count
        XCTAssertEqual(finalCount, 0, "All swings should be deleted")
    }

    // MARK: - Helpers

    private func navigateToLibrary() {
        // Start receiver to access menu
        let receiverButton = app.buttons["receiverButton"]
        if receiverButton.waitForExistence(timeout: 5) {
            receiverButton.tap()
            sleep(2)
        }

        navigateToLibraryFromReceiver()
    }

    private func navigateToLibraryFromReceiver() {
        // Open burger menu
        let menuButton = app.buttons["menuButton"]
        if menuButton.waitForExistence(timeout: 5) {
            menuButton.tap()
            sleep(1)
        }

        // Tap library button
        let libraryButton = app.buttons["libraryButton"]
        if libraryButton.waitForExistence(timeout: 5) {
            libraryButton.tap()
            sleep(1)
        }
    }
}
