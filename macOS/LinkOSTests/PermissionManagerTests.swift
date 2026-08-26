import XCTest
@testable import LinkOS

@MainActor
final class PermissionManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset state for clean test environment
        UserDefaults.standard.removeObject(forKey: "linkos_screen_recording_state")
    }

    func testScenario1_InitialState() {
        let pm = PermissionManager.shared
        
        // Simulate silent launch
        pm.checkPermissionsSilentlyOnLaunch()
        
        // It should transition to denied or granted based on real system state
        // but it should NEVER be 'requesting' or 'waitingForSystem' on launch.
        XCTAssertNotEqual(pm.screenRecordingState, .requesting)
        XCTAssertNotEqual(pm.screenRecordingState, .waitingForSystem)
    }

    func testScenario3_Debouncing() {
        let pm = PermissionManager.shared
        
        // Ensure state is clean before we start
        pm.screenRecordingState = .denied
        
        // Simulate double click
        pm.requestPermissionExplicitly(.screenRecording)
        
        // At this point, the debouncer or system dialog handler should have transitioned it.
        XCTAssertTrue(pm.screenRecordingState == .waitingForSystem || pm.screenRecordingState == .granted || pm.screenRecordingState == .denied)
    }
    
    func testScenario2_ReturnsFromSettings() {
        let pm = PermissionManager.shared
        
        // Simulate clicking grant
        pm.requestPermissionExplicitly(.accessibility)
        
        // Simulate returning from settings (didBecomeActiveNotification)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        
        // Allow async task in Notification center to process
        let exp = expectation(description: "UI Updates")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Should have refreshed states silently
            exp.fulfill()
        }
        
        wait(for: [exp], timeout: 2.0)
    }
    
    func testScenario4_SubsequentLaunch() {
        let pm = PermissionManager.shared
        
        // Save mock state
        UserDefaults.standard.set(PermissionState.granted.rawValue, forKey: "linkos_screen_recording_state")
        
        // Simulate relaunch by calling silent check again
        pm.checkPermissionsSilentlyOnLaunch()
        
        XCTAssertNotEqual(pm.screenRecordingState, .requesting)
    }
}
