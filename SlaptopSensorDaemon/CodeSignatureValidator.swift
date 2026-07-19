// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation
import Security

enum CodeSignatureValidator {
    private static let expectedClientIdentifier = "guru.am.slaptop"

    /// A code signing requirement matching the Slaptop app signed by the same
    /// team as this daemon. XPC evaluates it against the connecting process's
    /// audit token on every message, which is immune to PID reuse. Returns nil
    /// for ad-hoc (team-less) builds; callers must fail closed in that case.
    static func trustedClientRequirement() -> String? {
        guard let team = signingInformationForCurrentProcess()?.teamIdentifier else {
            return nil
        }
        return "anchor apple generic"
            + " and identifier \"\(expectedClientIdentifier)\""
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    private struct SigningInformation {
        let teamIdentifier: String?
    }

    private static func signingInformationForCurrentProcess() -> SigningInformation? {
        var ownCode: SecCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode else { return nil }
        return signingInformation(for: ownCode)
    }

    private static func signingInformation(for code: SecCode) -> SigningInformation? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else {
            return nil
        }

        return SigningInformation(
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        )
    }
}
