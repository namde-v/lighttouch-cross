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
        return kLTNotFound
    }
    out.pointee = ltCopyCString(value).map { UnsafePointer($0) }
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
    // Help.txt ships beside the library (copied from upstream at build time;
    // upstream itself is pristine). Fall back to empty if absent.
    let candidates = [
        AppCore.shared?.directories.resourceDir.appendingPathComponent("Help.txt"),
        URL(fileURLWithPath: "Help.txt"),
    ].compactMap { $0 }
    let text = candidates.lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first ?? ""
    let topics = HelpTopic.topics(text).map { ["title": $0.title, "body": $0.body] }
    guard let json = ltEncodeJSON(topics) else { return kLTFailed }
    out.pointee = ltCopyCString(json).map { UnsafePointer($0) }
    return kLTOk
}

// MARK: - Diagnostics

@_cdecl("lt_diagnostics_export")
public func lt_diagnostics_export(_ out: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> LTResult {
    guard let out else { return kLTBadArgument }
    guard let core = appCore() else { return kLTFailed }
    Task { @MainActor in
        do {
            let url = try await core.exportDiagnostics()
            out.pointee = ltCopyCString(url.path).map { UnsafePointer($0) }
            EventPump.shared.post(kind: kLTEventToast) { e in
                e.u.toast.title = ltCopyCString("Diagnostics exported")
                e.u.toast.body = ltCopyCString(url.path)
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
    // The path is delivered via the out pointer synchronously? No — the export
    // is async. Per ABI.md it's "synchronous enough to be a command with
    // immediate path return", but the real DiagnosticsExport is async. We post
    // the path via kLTEventToast and return kLTOk; Qt reads the path from the
    // toast. (Documented deviation; the header's `out` is filled when ready.)
    return kLTOk
}

// MARK: - Debug

/// §2.4 diagnostics counter: events dropped by the pump.
@_cdecl("lt_debug_dropped_events")
public func lt_debug_dropped_events() -> UInt64 {
    EventPump.shared.droppedCount
}

// MARK: - ABI version

@_cdecl("lt_abi_version")
public func lt_abi_version() -> UInt32 {
    UInt32(kLTAbiVersion)
}

// MARK: - Last error

@_cdecl("lt_last_error")
public func lt_last_error() -> UnsafePointer<CChar>? {
    LTLastError.cString()
}
