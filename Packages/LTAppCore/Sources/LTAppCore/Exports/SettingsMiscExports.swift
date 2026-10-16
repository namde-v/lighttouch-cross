// SettingsMiscExports.swift — ABI.md §3.11: settings & misc.
//
// lt_settings_* covers the narrow band of Swift-owned scalar prefs the Qt UI
// must read/write. Pure window-chrome state lives in QSettings on the C++ side.

import Foundation
import LTBridgeC
import LightTouchCore

// MARK: - Settings (string prefs)

/// Swift-owned string pref keys (documented in lt_bridge.h).
private enum SettingsKey {
    static let networkAnswer = "networkAccess.answer"
}

/// Portable settings store: uses the file-backed defaults (gap 5).
private enum LTAppSettings {
    static func string(forKey key: String) -> String? {
        ltPrefs()?.string(forKey: key)
    }
    static func set(_ value: String, forKey key: String) {
        ltPrefs()?.set(value, forKey: key)
    }
}

@_cdecl("lt_settings_get_string")
public func lt_settings_get_string(
    _ key: UnsafePointer<CChar>?,
    _ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> LTResult {
    guard let key, let out else { return kLTBadArgument }
    let k = String(cString: key)
    let value: String?
    switch k {
    case SettingsKey.networkAnswer:
        value = LTAppSettings.string(forKey: k)
    default:
        // Unknown keys read from the shared defaults (additive behavior).
        value = LTAppSettings.string(forKey: k)
    }
    guard let value else {
        LTLastError.set("lt_settings_get_string: no value for '\(k)'")
        return kLTFailed
    }
    out.pointee = ltCopyCString(value)
    return kLTOk
}

@_cdecl("lt_settings_set_string")
public func lt_settings_set_string(
    _ key: UnsafePointer<CChar>?,
    _ value: UnsafePointer<CChar>?
) -> LTResult {
    guard let key, let value else { return kLTBadArgument }
    LTAppSettings.set(String(cString: value), forKey: String(cString: key))
    return kLTOk
}

// MARK: - Help

@_cdecl("lt_help_topics")
public func lt_help_topics(_ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> LTResult {
    guard let out else { return kLTBadArgument }
    // Help.txt ships beside the package (copied from upstream at port time;
    // upstream itself is pristine). Fall back to empty if absent.
    let candidates = [
        AppCore.shared?.directories.resourceDir.appendingPathComponent("Help.txt"),
        URL(fileURLWithPath: "Help/Help.txt"),
        URL(fileURLWithPath: "../Help/Help.txt"),
    ].compactMap { $0 }
    let text = candidates.lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first ?? ""
    let topics = HelpTopic.topics(text).map { ["title": $0.title, "body": $0.body] }
    guard let json = ltEncodeJSON(topics) else { return kLTFailed }
    out.pointee = ltCopyCString(json)
    return kLTOk
}

// MARK: - Diagnostics

@_cdecl("lt_diagnostics_export")
public func lt_diagnostics_export(_ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> LTResult {
    guard let out else { return kLTBadArgument }
    guard let core = appCore() else { return kLTFailed }
    // The export is async; the path is delivered via kLTEventToast when done
    // (documented in ADDITIONS.md). Fill `out` with the *destination* path up
    // front so the caller knows where to look.
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("LightTouch-diagnostics-\(UUID().uuidString).zip")
    out.pointee = ltCopyCString(destination.path)
    let logDir = core.directories.logDir
    let logs = (try? FileManager.default.contentsOfDirectory(
        at: logDir, includingPropertiesForKeys: nil
    ))?.filter { $0.pathExtension == "log" } ?? []
    Task { @MainActor in
        do {
            try await DiagnosticsExport.write(
                to: destination,
                logs: logs,
                info: DiagnosticsExport.systemSummary()
            )
            EventPump.shared.post(kind: kLTEventToast) { e in
                e.u.toast.title = ltCopyCString("Diagnostics exported")
                e.u.toast.body = ltCopyCString(destination.path)
                e.u.toast.category = ltCopyCString("diagnostics")
            }
        } catch {
            LTLastError.set("lt_diagnostics_export: \(error.localizedDescription)")
            EventPump.shared.post(kind: kLTEventToast) { e in
                e.u.toast.title = ltCopyCString("Diagnostics export failed")
                e.u.toast.body = ltCopyCString(error.localizedDescription)
                e.u.toast.category = ltCopyCString("diagnostics")
            }
        }
    }
    return kLTOk
}

// MARK: - Debug

/// §2.4 diagnostics counter: events dropped by the pump.
@_cdecl("lt_debug_dropped_events")
public func lt_debug_dropped_events() -> UInt64 {
    EventPump.shared.droppedEvents()
}

// MARK: - ABI version (defined in LifecycleExports.swift)

// MARK: - Last error

@_cdecl("lt_last_error")
public func lt_last_error() -> UnsafePointer<CChar>? {
    LTLastError.copyCString()
}
