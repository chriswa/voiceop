import XCTest
@testable import VoiceOperator

final class PermissionHookTests: XCTestCase {
    private let cmd = "'/Users/x/Library/Application Support/VoiceOperator/hooks/permission-hook.sh'"

    func testAddThenDetectHook() {
        let base: [String: Any] = ["model": "opus", "permissions": ["allow": ["Bash"]]]
        XCTAssertFalse(PermissionHook.hasHook(in: base))
        let withHook = PermissionHook.addHook(to: base, command: cmd)
        XCTAssertTrue(PermissionHook.hasHook(in: withHook))
        // Existing keys are preserved.
        XCTAssertEqual(withHook["model"] as? String, "opus")
        XCTAssertNotNil(withHook["permissions"])
    }

    func testAddHookCoexistsWithForeignPermissionRequestHook() {
        let foreign: [String: Any] = ["hooks": ["PermissionRequest": [
            ["hooks": [["type": "command", "command": "/opt/other/thing.sh", "timeout": 3]]],
        ]]]
        let merged = PermissionHook.addHook(to: foreign, command: cmd)
        XCTAssertTrue(PermissionHook.hasHook(in: merged))
        // The foreign hook must remain.
        let hooks = merged["hooks"] as? [String: Any]
        let groups = hooks?["PermissionRequest"] as? [[String: Any]]
        XCTAssertEqual(groups?.count, 2)
    }

    func testRemoveHookLeavesForeignHooksIntact() {
        var settings: [String: Any] = ["hooks": ["PermissionRequest": [
            ["hooks": [["type": "command", "command": "/opt/other/thing.sh", "timeout": 3]]],
        ]]]
        settings = PermissionHook.addHook(to: settings, command: cmd)
        XCTAssertTrue(PermissionHook.hasHook(in: settings))
        let pruned = PermissionHook.removeHook(from: settings)
        XCTAssertFalse(PermissionHook.hasHook(in: pruned), "our hook must be gone")
        let groups = (pruned["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]
        XCTAssertEqual(groups?.count, 1, "the foreign hook must survive removal")
    }

    func testRemoveOnlyHookClearsEmptyContainers() {
        let settings = PermissionHook.addHook(to: ["model": "opus"], command: cmd)
        let pruned = PermissionHook.removeHook(from: settings)
        // With nothing else under hooks, the empty PermissionRequest / hooks keys
        // are cleared rather than left as dangling empties.
        XCTAssertNil(pruned["hooks"])
        XCTAssertEqual(pruned["model"] as? String, "opus")
    }

    func testAddIsCallerIdempotentViaHasHookGuard() {
        // install() guards on hasHook, so adding twice would only happen if the
        // guard were bypassed; assert the detector catches our own command.
        let once = PermissionHook.addHook(to: [:], command: PermissionHook.hookCommand)
        XCTAssertTrue(PermissionHook.hasHook(in: once))
    }
}
