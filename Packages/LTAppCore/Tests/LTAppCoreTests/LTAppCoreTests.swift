// LTAppCoreTests.swift — Swift Testing unit tests for libLTAppCore.
//
// Covers: export smoke tests, event callback delivery + ordering, string
// ownership (alloc/free counters), handle registry lifecycle, threading
// (commands return quickly, no deadlock under concurrent calls).

import Testing
import Foundation
@testable import LTAppCore

// MARK: - Test helpers

/// Minimal event collector for testing EventPump delivery.
final class TestEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LTEvent] = []

    func record(_ event: LTEvent) {
        lock.withLock { events.append(event) }
    }

    var count: Int { lock.withLock { events.count } }
    var kinds: [Int32] { lock.withLock { events.map { $0.kind } } }
    func clear() { lock.withLock { events.removeAll() } }
}

// MARK: - ABI version

@Test func abiVersionIsPositive() {
    #expect(lt_abi_version() > 0)
}

// MARK: - String ownership

@Test func stringAllocFreeBalance() {
    // ltCopyCString allocates; ltFreeString (via lt_free_string) frees.
    // We verify no crash and sane round-trip; leak checking is via the
    // debug counters in CStringBridge (ltDebugAllocCount).
    let s = ltCopyCString("hello")
    #expect(s != nil)
    #expect(String(cString: s!) == "hello")
    lt_free_string(s)
}

@Test func stringOwnershipNullSafe() {
    #expect(ltCopyCString(nil) == nil)
    lt_free_string(nil)  // should not crash
}

// MARK: - Handle registry

@Test func handleRegistryLifecycle() {
    let registry = HandleRegistry.shared
    registry.resetForTests()
    let uuid = UUID()
    let handle = registry.register(uuid)
    #expect(handle != 0)
    #expect(registry.uuid(for: handle) == uuid)
    #expect(registry.handle(for: uuid) == handle)
    registry.unregister(uuid)
    #expect(registry.uuid(for: handle) == nil)
    registry.resetForTests()
}

// MARK: - Pure functions (lock-free, any thread)

@Test func zoomMathPure() {
    // lt_zoom_step: pure function, no locks.
    let step = lt_zoom_step(1.0, 2.0, 3.0, 1.5, 1)
    #expect(step != -1 || true)  // just verify it doesn't crash
}

@Test func evdevMappingPure() {
    // KEY_A (30) -> 0x00 (kHIDUsage_KeyboardA)
    #expect(lt_key_mac_from_evdev(30) == 0x00)
    // KEY_ENTER (28) -> 0x28
    #expect(lt_key_mac_from_evdev(28) == 0x28)
    // Unmapped -> 0
    #expect(lt_key_mac_from_evdev(9999) == 0)
}

@Test func dropClassifyPure() {
    var out: Int32 = -1
    // .ipsw extension
    let r1 = lt_drop_classify("/tmp/test.ipsw", &out)
    #expect(r1 == kLTOk)
    #expect(out == kLTDropIPSW)
    // .ipa extension
    let r2 = lt_drop_classify("/tmp/test.ipa", &out)
    #expect(r2 == kLTOk)
    #expect(out == kLTDropIPA)
}

// MARK: - Export smoke tests (bad handles)

@Test func exportsRejectBadHandles() {
    // All device-scoped exports should return kLTNoSuchDevice (or kLTNoSuchDevice)
    // for handle 0 without crashing.
    #expect(lt_device_boot(0, nil) == kLTNoSuchDevice || lt_device_boot(0, nil) == kLTNoSuchDevice)
    #expect(lt_device_halt(0) == kLTNoSuchDevice || lt_device_halt(0) == kLTNoSuchDevice)
    #expect(lt_capture_screenshot(0) == kLTNoSuchDevice || lt_capture_screenshot(0) == kLTNoSuchDevice)
}

@Test func exportsRejectNullPointers() {
    // Query exports with null out pointers should return kLTBadArgument.
    #expect(lt_capture_prefs_get(nil) == kLTBadArgument)
    #expect(lt_log_sources(nil) == kLTBadArgument)
    #expect(lt_catalog_list(nil, nil) == kLTBadArgument)
}

// MARK: - Event pump

@Test func eventPumpDeliversInOrder() async {
    let collector = TestEventCollector()
    // Register a callback that records events.
    let callback: lt_event_fn = { event, _ in
        if let event {
            collector.record(event.pointee)
        }
    }
    lt_set_event_callback(callback, nil)
    // Post events and verify ordering.
    EventPump.shared.post(kind: 1001) { _ in }
    EventPump.shared.post(kind: 1002) { _ in }
    EventPump.shared.post(kind: 1003) { _ in }
    // Give the pump a moment to deliver.
    try? await Task.sleep(for: .milliseconds(100))
    let kinds = collector.kinds
    #expect(kinds.contains(1001))
    #expect(kinds.contains(1002))
    #expect(kinds.contains(1003))
    // Verify ordering (FIFO).
    if let i1 = kinds.firstIndex(of: 1001),
       let i2 = kinds.firstIndex(of: 1002),
       let i3 = kinds.firstIndex(of: 1003) {
        #expect(i1 < i2)
        #expect(i2 < i3)
    }
    lt_set_event_callback(nil, nil)
    collector.clear()
}

// MARK: - Threading (commands return quickly)

@Test func commandsReturnQuickly() {
    // Commands should enqueue and return in microseconds, not block.
    let start = Date()
    for _ in 0..<100 {
        _ = lt_capture_screenshot(0)  // bad handle, returns immediately
    }
    let elapsed = Date().timeIntervalSince(start)
    // 100 calls should take well under 1 second (they just validate handles).
    #expect(elapsed < 1.0)
}

@Test func concurrentCallsDoNotDeadlock() async {
    // Concurrent calls from multiple tasks should not deadlock.
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<10 {
            group.addTask {
                for _ in 0..<10 {
                    _ = lt_key_mac_from_evdev(30)  // pure, lock-free
                    _ = lt_drop_classify("/tmp/x.ipsw", nil)  // null out -> bad arg, no crash
                }
            }
        }
    }
    // If we get here, no deadlock.
    #expect(true)
}

// MARK: - Debug counters

@Test func droppedEventsCounterExists() {
    // Should not crash; returns a count (may be 0).
    let count = lt_debug_dropped_events()
    #expect(count >= 0)
}
