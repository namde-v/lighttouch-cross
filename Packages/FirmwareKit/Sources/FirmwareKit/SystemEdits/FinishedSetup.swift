// FinishedSetup: Setup Assistant's finished state, seeded into the data volume's /private/var skeleton (recipe option
// skip_setup, firmwarekit create --skip-setup), so a fresh iOS 5-7 device starts at the Home screen.
//
// The keys are the ones Setup itself writes on a walk that picks English, the region, Location Services off, no Wi-Fi,
// a new device, no Apple ID or passcode, the terms and Don't Send: the data volume of each base diffed before and
// after the sessions harness's walk (n81ap/k48ap 9B206, n90ap 10B329, n90ap 11D257). What the boot's other parts
// write anyway (lockdown's zone and clock, it_prefs, caches) is left to them. The language and region are
// seedLanguage's, which every prepared device gets.

import Foundation

extension SystemEdits {
    /// One plist under /private/var and the keys it gets.
    typealias Seed = (path: String, keys: [String: Any])

    static let purpleBuddy = "mobile/Library/Preferences/com.apple.purplebuddy.plist"
    static let purpleBuddyLocal = "mobile/Library/Preferences/com.apple.purplebuddy.notbackedup.plist"
    static let locationd = "mobile/Library/Preferences/com.apple.locationd.plist"
    static let locationdLocal = "mobile/Library/Preferences/com.apple.locationd.notbackedup.plist"
    static let globalPreferences = "mobile/Library/Preferences/.GlobalPreferences.plist"
    static let dataArk = "root/Library/Lockdown/data_ark.plist"

    /// What Setup leaves on iOS `major` (5, 6, 7) after a walk in `language` and `locale` ("en", "en_AU"), finished at
    /// `now`; empty before 5 (iTunes activated those, no Setup Assistant).
    static func finishedSetup(major: Int, language: String, locale: String, now: Date = Date()) -> [Seed] {
        guard major >= 5 else { return [] }
        var buddy: [String: Any] = [
            "SetupDone": true, "SetupFinishedAllSteps": true, "RestoreChoice": true, "PBTCPresented": true,
            "PBDiagnosticsPresented": true, "WiFiPresented": true, "Language": language, "Locale": locale,
        ]
        let off: [String: Any]
        var buddyLocal: [String: Any]
        var ark: [String: Any]
        var extra: [Seed] = []
        switch major {
        case 5, 6:
            buddy[major == 5 ? "AppleIDPresented" : "AppleIDPB3Presented"] = true
            if major == 6 { buddy["SetupVersion"] = 3 }
            buddyLocal = ["LocationServicesPresented": true]
            off = ["LocationServicesEnabled": 0]
            ark = [
                "com.apple.purplebuddy-SetupState": "SetupUsingAssistant",
                "com.apple.mobile.user_preferences-UserSetLanguage": true,
                "com.apple.mobile.user_preferences-UserSetLocale": true,
            ]
        default:
            buddy.merge(
                [
                    "AppleIDPB5Presented": true, "PasscodePresented": true, "SetupVersion": 5,
                    "SetupState": "SetupUsingAssistant", "AppleIDForceUpgrade": false,
                ]
            ) { $1 }
            buddyLocal = ["LocationServices2Presented": true, "CloudConfigPresented": true]
            off = ["LocationServicesEnabledIn7.0": 0]
            ark = [
                "-ActivationStateAcknowledged": true, "com.apple.mobile.chaperone-NotSoFresh": true,
                "-FirstPurpleBuddyCompletion": Int(now.timeIntervalSince1970),
            ]
            // Setup's cloud configuration step, through ManagedConfiguration: without the record, 7.x's
            // PSSetupAssistantNeedsToRun brings Setup back for it (Wi-Fi, then Welcome) on every boot.
            extra = [
                (
                    "mobile/Library/ConfigurationProfiles/CloudConfigurationDetails.plist",
                    [
                        "AllowPairing": true, "CloudConfigurationUIComplete": true, "IsSupervised": false,
                        "PostSetupProfileWasInstalled": false,
                    ]
                ),
                (
                    "mobile/Library/Preferences/com.apple.mobile.user_preferences.plist",
                    ["UserSetLanguage": true, "UserSetLocale": true]
                ),
            ]
        }
        return [
            (purpleBuddy, buddy), (purpleBuddyLocal, buddyLocal), (locationd, off), (locationdLocal, off),
            (dataArk, ark),
        ] + extra
    }

    #if os(Linux)
        /// corelibs-foundation's `Bundle.preferredLocalizations(from:forPreferences:)` always returns
        /// `["en"]`. This is Apple's matching, via BCP 47 likely-subtags maximization: each tag becomes
        /// (language, script, region); an exact maximized match wins, else the same language+script (most
        /// specific tag), else the same language. So "en-US" maximizes to en_Latn_US like "en", while "en-AU"
        /// (en_Latn_AU) falls back to "en-GB"; "zh-HK" maximizes with Hant and finds "zh-Hant"; "no" maps to nb.
        private static func preferredLocalizations(
            from supported: [String],
            forPreferences preferred: [String]
        ) -> [String] {
            struct Maximized: Equatable { var language: String; var script: String; var region: String }
            // (script, region) likely subtags for the firmware languages; enough for the matching above.
            let likely: [String: (script: String, region: String)] = [
                "en": ("Latn", "US"), "fr": ("Latn", "FR"), "de": ("Latn", "DE"), "ja": ("Jpan", "JP"),
                "nl": ("Latn", "NL"), "it": ("Latn", "IT"), "es": ("Latn", "ES"), "da": ("Latn", "DK"),
                "fi": ("Latn", "FI"), "nb": ("Latn", "NO"), "sv": ("Latn", "SE"), "ko": ("Kore", "KR"),
                "ru": ("Cyrl", "RU"), "pl": ("Latn", "PL"), "pt": ("Latn", "BR"), "tr": ("Latn", "TR"),
                "uk": ("Cyrl", "UA"), "ar": ("Arab", "EG"), "hr": ("Latn", "HR"), "cs": ("Latn", "CZ"),
                "el": ("Grek", "GR"), "he": ("Hebr", "IL"), "ro": ("Latn", "RO"), "sk": ("Latn", "SK"),
                "th": ("Thai", "TH"), "id": ("Latn", "ID"), "ms": ("Latn", "MY"), "hu": ("Latn", "HU"),
                "ca": ("Latn", "ES"), "vi": ("Latn", "VN"), "hi": ("Deva", "IN"),
                "zh": ("Hans", "CN"),
            ]
            func maximize(_ tag: String) -> Maximized {
                var language = "", script = "", region = ""
                for part in tag.replacingOccurrences(of: "_", with: "-").split(separator: "-") {
                    if part.count == 4, part.first?.isUppercase == true, script.isEmpty {
                        script = String(part)
                    } else if (part.count == 2 || part.count == 3),
                        part.allSatisfy({ $0.isUppercase || $0.isNumber }), region.isEmpty
                    {
                        region = String(part)
                    } else if language.isEmpty {
                        language = String(part).lowercased()
                    }
                }
                if language == "no" { language = "nb" }  // macrolanguage Norwegian -> Bokmal
                if language == "zh", script.isEmpty {
                    // Likely script for Chinese by region.
                    script = ["HK", "TW", "MO"].contains(region) ? "Hant" : "Hans"
                }
                let def = likely[language] ?? ("Latn", "US")
                return Maximized(
                    language: language, script: script.isEmpty ? def.script : script,
                    region: region.isEmpty ? def.region : region)
            }
            let sup = supported.map { ($0, maximize($0)) }
            var out: [String] = []
            var seen = Set<String>()
            for p in preferred {
                let mp = maximize(p)
                if let m = sup.first(where: { $0.1 == mp && !seen.contains($0.0) }) {
                    out.append(m.0); seen.insert(m.0); continue
                }
                let sameScript = sup.filter {
                    $0.1.language == mp.language && $0.1.script == mp.script && !seen.contains($0.0)
                }
                let sameLanguage = sup.filter { $0.1.language == mp.language && !seen.contains($0.0) }
                if let best = (sameScript.isEmpty ? sameLanguage : sameScript).max(by: { $0.0.count < $1.0.count })
                {
                    out.append(best.0); seen.insert(best.0)
                }
            }
            return out
        }
    #endif

    /// The device's language: the first of `preferred` (BCP 47 tags) that `supported`, the firmware's own
    /// AppleLanguages, has, matched as a bundle picks its localization ("zh-Hans-CN" to "zh-Hans", "pt-BR" to "pt",
    /// "en-AU" to "en-GB" where the firmware has it), else English; with `region`, its AppleLocale ("fr_FR").
    static func deviceLanguage(
        supported: [String],
        preferred: [String],
        region: String?
    ) -> (language: String, locale: String) {
        #if os(Linux)
            let language = preferredLocalizations(from: supported, forPreferences: preferred).first ?? "en"
        #else
            let language = Bundle.preferredLocalizations(from: supported, forPreferences: preferred).first ?? "en"
        #endif
        let code = Locale(identifier: language).language.languageCode?.identifier ?? "en"
        return (language, region.map { "\(code)_\($0)" } ?? code)
    }

    /// Sets the device's language and region (`deviceLanguage`, from `tag`, else the Mac's) in each user's
    /// .GlobalPreferences under `skeleton` (/private/var) that lists the firmware's languages: the language moved
    /// first, AppleLocale set; with `catalog`, the firmware's keyboards, AppleKeyboards (KeyboardCatalog.keyboards)
    /// for the language and `keyboards`, Mac input source IDs, else the Mac's enabled ones. Nil where the firmware
    /// has no such list.
    @discardableResult
    static func seedLanguage(
        _ skeleton: URL,
        tag: String?,
        keyboards: [String]? = nil,
        catalog: KeyboardCatalog? = nil
    ) throws -> (language: String, locale: String, keyboards: [String])? {
        let preferred = tag.map { [$0] } ?? Locale.preferredLanguages
        let region = tag.flatMap { Locale(identifier: $0).region?.identifier } ?? Locale.current.region?.identifier
        let mac = catalog == nil ? [] : macKeyboards(keyboards)
        var chosen: (language: String, locale: String, keyboards: [String])?
        for path in [globalPreferences, "root/Library/Preferences/.GlobalPreferences.plist"] {
            let url = skeleton.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try rewritePlist(url) { d in
                guard var list = d["AppleLanguages"] as? [String] else { return }
                let pick = deviceLanguage(supported: list, preferred: preferred, region: region)
                list.removeAll { $0 == pick.language }
                d["AppleLanguages"] = [pick.language] + list
                d["AppleLocale"] = pick.locale
                let kb = catalog?.keyboards(language: pick.language, locale: pick.locale, mac: mac) ?? []
                if !kb.isEmpty { d["AppleKeyboards"] = kb }
                chosen = chosen ?? (pick.language, pick.locale, kb)
            }
        }
        return chosen
    }

    /// Seeds `finishedSetup` into `skeleton` (/private/var), merged into the plists already there, as Setup's walk in
    /// `language` and `locale` (seedLanguage's) leaves it.
    static func seedFinishedSetup(_ skeleton: URL, major: Int, language: String, locale: String) throws {
        for (path, keys) in finishedSetup(major: major, language: language, locale: locale) {
            try seedPlist(skeleton.appendingPathComponent(path)) { $0.addEntries(from: keys) }
        }
    }
}
