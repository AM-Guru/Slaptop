// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import Foundation
import Security

enum CodeSignatureValidator {
    private static let expectedClientIdentifier = "guru.am.slaptop"

    /// A code signing requirement matching the Slaptop app signed by the same
    /// team as this daemon. XPC evaluates it against the connecting process's
    /// audit token on every message, which is immune to the PID-reuse race a
    /// manual PID lookup has. Returns nil for ad-hoc (team-less) builds.
    static func trustedClientRequirement() -> String? {
        guard let team = signingInformationForCurrentProcess()?.teamIdentifier else {
            return nil
        }
        return "anchor apple generic"
            + " and identifier \"\(expectedClientIdentifier)\""
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Fallback for Xcode's ad-hoc signed Debug builds only. Checks the
    /// on-disk signature of the process behind the connection's PID, which is
    /// best-effort: the PID can in principle be reused between the check and
    /// later messages.
    static func isTrustedSlaptopClient(_ connection: NSXPCConnection) -> Bool {
        guard
            let clientInfo = signingInformation(forPID: connection.processIdentifier),
            clientInfo.identifier == expectedClientIdentifier
        else {
            return false
        }

        if let ownTeam = signingInformationForCurrentProcess()?.teamIdentifier {
            return clientInfo.teamIdentifier == ownTeam
        }

        // Xcode's local Debug builds are ad-hoc signed and have no team ID.
        // A distributable Release must carry a real team ID.
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private struct SigningInformation {
        let identifier: String?
        let teamIdentifier: String?
    }

    private static func signingInformation(forPID pid: pid_t) -> SigningInformation? {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
              let guestCode else {
            return nil
        }
        return signingInformation(for: guestCode)
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
            identifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        )
    }
}
