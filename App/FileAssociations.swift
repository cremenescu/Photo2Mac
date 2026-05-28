// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import Foundation
import AppKit
import UniformTypeIdentifiers

/// Thin wrapper around LaunchServices for the "make Photo2Mac the default
/// editor for this file type" feature in Settings.
///
/// Even though `LSCopyDefaultRoleHandlerForContentType` and friends are
/// marked deprecated, they are still the only way to change the default
/// handler programmatically on current macOS (the suggested replacement
/// `NSWorkspace.URLForApplicationToOpenContentType` is read-only). This is
/// also what `defaults write com.apple.LaunchServices` and `duti` do under
/// the hood. Behaviour is identical to System Settings > Default Apps.
enum FileAssociations {

    /// One row in Settings.
    struct ImageType: Identifiable, Hashable {
        let id: String           // UTI, e.g. "public.jpeg"
        let label: String        // user-facing name, e.g. "JPEG"
        let extensions: String   // e.g. ".jpg, .jpeg"
    }

    /// The image types Photo2Mac is willing to own. Must stay in sync with
    /// `CFBundleDocumentTypes` in project.yml — otherwise LaunchServices
    /// will silently refuse to register Photo2Mac as a candidate.
    static let supportedTypes: [ImageType] = [
        .init(id: "public.jpeg", label: "JPEG", extensions: ".jpg, .jpeg"),
        .init(id: "public.png",  label: "PNG",  extensions: ".png"),
        .init(id: "public.heic", label: "HEIC", extensions: ".heic"),
        .init(id: "public.heif", label: "HEIF", extensions: ".heif"),
        .init(id: "public.tiff", label: "TIFF", extensions: ".tif, .tiff"),
    ]

    /// Photo2Mac's bundle id. We avoid hardcoding it so the function still
    /// works if the build is renamed/relocated; fall back only if the
    /// runtime value is missing (shouldn't happen).
    static var ourBundleID: String {
        Bundle.main.bundleIdentifier ?? "ro.cremenescu.Photo2Mac"
    }

    /// Bundle id of the current default editor for `uti`, or nil if none.
    static func currentDefaultHandler(for uti: String) -> String? {
        guard let cf = LSCopyDefaultRoleHandlerForContentType(
            uti as CFString, .editor
        )?.takeRetainedValue() as String? else {
            return nil
        }
        return cf.isEmpty ? nil : cf
    }

    /// Display name of the app with `bundleID`, e.g. "Preview". Falls back
    /// to the bundle id itself.
    static func displayName(forBundleID bundleID: String) -> String {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleID),
            let bundle = Bundle(url: url),
            let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"]
                        ?? bundle.localizedInfoDictionary?["CFBundleName"]
                        ?? bundle.infoDictionary?["CFBundleDisplayName"]
                        ?? bundle.infoDictionary?["CFBundleName"]) as? String
        else {
            return bundleID
        }
        return name
    }

    /// True when Photo2Mac is registered as the default editor for `uti`.
    static func isOurDefault(for uti: String) -> Bool {
        currentDefaultHandler(for: uti)?.lowercased()
            == ourBundleID.lowercased()
    }

    /// Set Photo2Mac as the default editor for `uti`. Returns true on
    /// success. macOS may prompt the user the first time.
    @discardableResult
    static func makeUsDefault(for uti: String) -> Bool {
        let status = LSSetDefaultRoleHandlerForContentType(
            uti as CFString, .editor, ourBundleID as CFString)
        return status == noErr
    }

    /// Hand the default back to `bundleID`. Use the system Preview as a
    /// safe revert target if the caller doesn't know what was there before.
    @discardableResult
    static func setDefault(_ bundleID: String, for uti: String) -> Bool {
        let status = LSSetDefaultRoleHandlerForContentType(
            uti as CFString, .editor, bundleID as CFString)
        return status == noErr
    }

    /// Best guess of the system default to revert to (Preview on macOS).
    static let fallbackBundleID = "com.apple.Preview"
}
