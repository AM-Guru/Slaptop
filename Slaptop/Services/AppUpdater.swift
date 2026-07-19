// Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
// This source code is licensed under the MIT License. See LICENSE for details.

import AppKit
import Foundation
import Security

enum UpdateCheckFrequency: String, CaseIterable {
    case daily
    case weekly
    case manual

    static let key = "update.checkFrequency"

    var label: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .manual: return "Manually"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .daily: return 86_400
        case .weekly: return 604_800
        case .manual: return nil
        }
    }
}

enum AppUpdateError: LocalizedError {
    case checkFailed(String)
    case downloadFailed(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case let .checkFailed(detail): return "Update check failed: \(detail)"
        case let .downloadFailed(detail): return "Update download failed: \(detail)"
        case let .installFailed(detail): return "Update installation failed: \(detail)"
        }
    }
}

enum ApplicationInstallationOutcome: Equatable {
    case installed
    case existingInstallation
}

enum ApplicationInstallationError: LocalizedError {
    case invalidSource
    case existingApplicationIsNotSlaptop
    case copyFailed(String)
    case copiedApplicationFailedValidation
    case relaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "This copy of Slaptop could not be validated."
        case .existingApplicationIsNotSlaptop:
            return "A different or damaged Slaptop.app already exists in Applications."
        case let .copyFailed(detail):
            return "Slaptop could not be copied to Applications: \(detail)"
        case .copiedApplicationFailedValidation:
            return "The copy in Applications did not pass code-signature validation."
        case let .relaunchFailed(detail):
            return "Slaptop was installed, but could not be reopened: \(detail)"
        }
    }
}

/// Safely installs the currently running bundle without replacing an existing
/// application. The copy is staged on the destination volume and must match
/// the source bundle's identifier, build, and designated code requirement
/// before it is atomically moved into place.
enum AppInstallationManager {
    static let installedApplicationURL = URL(
        fileURLWithPath: MissionControlController.installedApplicationPath,
        isDirectory: true
    )

    static func installCurrentApplication(
        from sourceURL: URL = Bundle.main.bundleURL,
        to destinationURL: URL = installedApplicationURL
    ) throws -> ApplicationInstallationOutcome {
        let fileManager = FileManager.default
        let standardizedSource = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let standardizedDestination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()

        if standardizedSource == standardizedDestination {
            return .existingInstallation
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            guard application(at: destinationURL, matchesSignerOf: sourceURL, requireSameBuild: false) else {
                throw ApplicationInstallationError.existingApplicationIsNotSlaptop
            }
            return .existingInstallation
        }

        guard application(at: sourceURL, matchesSignerOf: sourceURL, requireSameBuild: true) else {
            throw ApplicationInstallationError.invalidSource
        }

        let stagingURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".Slaptop-installing-\(UUID().uuidString).app", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingURL) }

        try runDitto(from: sourceURL, to: stagingURL)
        guard application(at: stagingURL, matchesSignerOf: sourceURL, requireSameBuild: true) else {
            throw ApplicationInstallationError.copiedApplicationFailedValidation
        }

        do {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        } catch {
            throw ApplicationInstallationError.copyFailed(error.localizedDescription)
        }

        guard application(at: destinationURL, matchesSignerOf: sourceURL, requireSameBuild: true) else {
            // This destination was created by this installation attempt, so
            // removing an invalid result cannot destroy a pre-existing app.
            try? fileManager.removeItem(at: destinationURL)
            throw ApplicationInstallationError.copiedApplicationFailedValidation
        }
        return .installed
    }

    @MainActor
    static func relaunchInstalledApplication() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 1; /usr/bin/open \"\(MissionControlController.installedApplicationPath)\"",
        ]
        do {
            try process.run()
        } catch {
            throw ApplicationInstallationError.relaunchFailed(error.localizedDescription)
        }
        NSApplication.shared.terminate(nil)
    }

    private static func runDitto(from sourceURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [sourceURL.path, destinationURL.path]
        let standardError = Pipe()
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw ApplicationInstallationError.copyFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ApplicationInstallationError.copyFailed(
                detail?.isEmpty == false ? detail! : "exit status \(process.terminationStatus)"
            )
        }
    }

    private static func application(
        at candidateURL: URL,
        matchesSignerOf sourceURL: URL,
        requireSameBuild: Bool
    ) -> Bool {
        guard
            let sourceBundle = Bundle(url: sourceURL),
            let candidateBundle = Bundle(url: candidateURL),
            sourceBundle.bundleIdentifier == "guru.am.slaptop",
            candidateBundle.bundleIdentifier == sourceBundle.bundleIdentifier,
            !requireSameBuild
                || candidateBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                    == sourceBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { return false }

        var sourceCode: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(sourceURL as CFURL, [], &sourceCode) == errSecSuccess,
            let sourceCode
        else { return false }

        var requirement: SecRequirement?
        guard
            SecCodeCopyDesignatedRequirement(sourceCode, [], &requirement) == errSecSuccess,
            let requirement
        else { return false }

        var candidateCode: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(candidateURL as CFURL, [], &candidateCode) == errSecSuccess,
            let candidateCode
        else { return false }

        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
                | kSecCSStrictValidate
                | kSecCSRestrictSymlinks
                | kSecCSRestrictToAppLike
        )
        return SecStaticCodeCheckValidity(candidateCode, flags, requirement) == errSecSuccess
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case availableButNotInstallable(tag: String)
        case downloading(tag: String)
        case installing(tag: String)
        case failed(String)
    }

    struct Release {
        let tag: String
        let buildNumber: Int
        let dmgURL: URL
    }

    nonisolated static let repository = "AM-Guru/Slaptop"
    private static let lastCheckedKey = "update.lastCheckedAt"
    /// Automatic checks are evaluated hourly against the chosen frequency, so
    /// a due check runs soon after wake or launch rather than exactly on the
    /// daily/weekly boundary.
    private static let automaticEvaluationInterval: TimeInterval = 3_600
    private static let launchEvaluationDelay: TimeInterval = 15

    @Published var frequency: UpdateCheckFrequency {
        didSet { defaults.set(frequency.rawValue, forKey: UpdateCheckFrequency.key) }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheckedAt: Date?

    private let defaults: UserDefaults
    private var automaticCheckTimer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        frequency = UpdateCheckFrequency(
            rawValue: defaults.string(forKey: UpdateCheckFrequency.key) ?? ""
        ) ?? .daily
        lastCheckedAt = defaults.object(forKey: Self.lastCheckedKey) as? Date
    }

    var statusDescription: String {
        switch phase {
        case .idle:
            guard let lastCheckedAt else { return "Updates have not been checked yet." }
            return "Last checked \(Self.relativeDescription(of: lastCheckedAt))."
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            return "Slaptop is up to date (build \(Self.currentBuildNumber))."
        case let .availableButNotInstallable(tag):
            return "Update \(tag) is available. Install Slaptop in /Applications to update automatically."
        case let .downloading(tag):
            return "Downloading Slaptop \(tag)…"
        case let .installing(tag):
            return "Installing Slaptop \(tag)… Slaptop will relaunch."
        case let .failed(message):
            return message
        }
    }

    func startAutomaticChecks() {
        automaticCheckTimer?.invalidate()
        let timer = Timer(
            timeInterval: Self.automaticEvaluationInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdatesIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        automaticCheckTimer = timer

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchEvaluationDelay) { [weak self] in
            self?.checkForUpdatesIfDue()
        }
    }

    func checkForUpdatesIfDue() {
        guard Self.isAutomaticCheckDue(
            frequency: frequency,
            lastCheckedAt: lastCheckedAt,
            now: Date()
        ) else { return }
        checkForUpdates()
    }

    /// Manual and automatic entry point: checks the latest GitHub release and,
    /// when it is newer and Slaptop runs from /Applications, downloads,
    /// verifies, installs, and relaunches.
    func checkForUpdates() {
        switch phase {
        case .checking, .downloading, .installing: return
        default: break
        }
        phase = .checking
        Task { await performCheckAndInstall() }
    }

    nonisolated static func isAutomaticCheckDue(
        frequency: UpdateCheckFrequency,
        lastCheckedAt: Date?,
        now: Date
    ) -> Bool {
        guard let interval = frequency.interval else { return false }
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= interval
    }

    /// Release tags are produced by CI as "v<version>-build.<run number>", so
    /// the trailing run number is the monotonic comparison key.
    nonisolated static func buildNumber(fromTag tag: String) -> Int? {
        guard let range = tag.range(of: "build.", options: .backwards) else { return nil }
        let digits = tag[range.upperBound...]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    nonisolated static var currentBuildNumber: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    private func performCheckAndInstall() async {
        defer {
            lastCheckedAt = Date()
            defaults.set(lastCheckedAt, forKey: Self.lastCheckedKey)
        }

        do {
            let release = try await Self.fetchLatestRelease()
            let installedBuildNumber = Self.currentBuildNumber
            guard release.buildNumber > installedBuildNumber else {
                phase = .upToDate
                return
            }
            guard MissionControlController.isInstalledApplication else {
                phase = .availableButNotInstallable(tag: release.tag)
                return
            }

            phase = .downloading(tag: release.tag)
            let dmgURL = try await Self.download(release.dmgURL)
            phase = .installing(tag: release.tag)
            try await Task.detached(priority: .userInitiated) {
                try AppUpdateInstaller.install(
                    dmgAt: dmgURL,
                    expectedBuildNumber: release.buildNumber,
                    replacingBuildNumber: installedBuildNumber
                )
            }.value
            Self.relaunchInstalledApplication()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private nonisolated static func fetchLatestRelease() async throws -> Release {
        guard let url = URL(
            string: "https://api.github.com/repos/\(repository)/releases/latest"
        ) else {
            throw AppUpdateError.checkFailed("invalid release endpoint")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateError.checkFailed("unexpected response type")
        }
        guard httpResponse.statusCode == 200 else {
            throw AppUpdateError.checkFailed("GitHub replied with status \(httpResponse.statusCode)")
        }

        struct ReleaseDocument: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadURL: String

                enum CodingKeys: String, CodingKey {
                    case name
                    case browserDownloadURL = "browser_download_url"
                }
            }

            let tagName: String
            let assets: [Asset]

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case assets
            }
        }

        let document = try JSONDecoder().decode(ReleaseDocument.self, from: data)
        guard let buildNumber = buildNumber(fromTag: document.tagName) else {
            throw AppUpdateError.checkFailed("unrecognized release tag \(document.tagName)")
        }
        guard
            let asset = document.assets.first(where: { $0.name == "Slaptop.dmg" }),
            let dmgURL = URL(string: asset.browserDownloadURL),
            dmgURL.scheme == "https"
        else {
            throw AppUpdateError.checkFailed("release \(document.tagName) has no Slaptop.dmg asset")
        }
        return Release(tag: document.tagName, buildNumber: buildNumber, dmgURL: dmgURL)
    }

    private nonisolated static func download(_ url: URL) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppUpdateError.downloadFailed("unexpected server response")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Slaptop-update-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private static func relaunchInstalledApplication() {
        // The reopen must outlive this process, so it is delegated to a
        // detached shell that waits for the current instance to exit.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 1; /usr/bin/open \"\(MissionControlController.installedApplicationPath)\"",
        ]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    private nonisolated static func relativeDescription(of date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Filesystem side of an update: authenticate the disk image before mounting,
/// verify the replacement app, swap it into /Applications, validate the copy,
/// and clean up.
enum AppUpdateInstaller {
    /// Apple's Developer ID Application certificate requirements from TN3127,
    /// pinned to Slaptop's identifier and team.
    private static let applicationSignatureRequirement = "anchor apple generic"
        + " and identifier \"guru.am.slaptop\""
        + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        + " and certificate leaf[subject.OU] = \"59A594LZGR\""

    /// The release workflow signs Slaptop.dmg with the same Developer ID
    /// Application identity. Checking this before hdiutil keeps unauthenticated
    /// filesystem data away from the disk-image parser.
    private static let diskImageSignatureRequirement = "anchor apple generic"
        + " and identifier \"Slaptop\""
        + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        + " and certificate leaf[subject.OU] = \"59A594LZGR\""

    static func install(
        dmgAt dmgURL: URL,
        expectedBuildNumber: Int,
        replacingBuildNumber: Int
    ) throws {
        guard expectedBuildNumber > replacingBuildNumber else {
            throw AppUpdateError.installFailed(
                "build \(expectedBuildNumber) is not newer than installed build \(replacingBuildNumber)"
            )
        }

        let fileManager = FileManager.default
        let mountPoint = fileManager.temporaryDirectory
            .appendingPathComponent("Slaptop-update-mount-\(UUID().uuidString)")
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        // Always remove the downloaded image, including when authentication
        // fails before it is mounted.
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"]) {
                AppUpdateError.installFailed($0)
            }
            try? fileManager.removeItem(at: mountPoint)
            try? fileManager.removeItem(at: dmgURL)
        }

        try validateDiskImage(dmgURL)
        try run(
            "/usr/bin/hdiutil",
            ["attach", dmgURL.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, "-quiet"],
            failure: { AppUpdateError.installFailed("could not open the update image: \($0)") }
        )

        let replacementApp = mountPoint.appendingPathComponent("Slaptop.app")
        guard fileManager.fileExists(atPath: replacementApp.path) else {
            throw AppUpdateError.installFailed("the update image does not contain Slaptop.app")
        }
        try validateApplication(replacementApp, expectedBuildNumber: expectedBuildNumber)

        let installedURL = URL(fileURLWithPath: MissionControlController.installedApplicationPath)
        let previousURL = fileManager.temporaryDirectory
            .appendingPathComponent("Slaptop-previous-\(UUID().uuidString).app")
        try fileManager.moveItem(at: installedURL, to: previousURL)
        do {
            try run(
                "/usr/bin/ditto",
                [replacementApp.path, installedURL.path],
                failure: { AppUpdateError.installFailed("could not copy the new version: \($0)") }
            )
            // Validate the bytes at their final path. This catches a failed or
            // altered copy before the known-good application is discarded.
            try validateApplication(installedURL, expectedBuildNumber: expectedBuildNumber)
        } catch {
            // Roll the previous version back so the user is never left
            // without an installed app.
            try? fileManager.removeItem(at: installedURL)
            try? fileManager.moveItem(at: previousURL, to: installedURL)
            throw error
        }
        try? fileManager.removeItem(at: previousURL)
    }

    private static func validateDiskImage(_ dmgURL: URL) throws {
        try validateSignature(
            of: dmgURL,
            requirementText: diskImageSignatureRequirement,
            flags: SecCSFlags(rawValue: kSecCSStrictValidate),
            rejectionMessage: "the update image is not signed with Slaptop's Developer ID Application certificate"
        )
        try assessWithGatekeeper(
            dmgURL,
            arguments: ["-a", "-t", "open", "--context", "context:primary-signature"],
            rejectionMessage: "the update image is not notarized for distribution"
        )
    }

    static func validateApplication(_ applicationURL: URL, expectedBuildNumber: Int) throws {
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
                | kSecCSStrictValidate
                | kSecCSRestrictSymlinks
                | kSecCSRestrictToAppLike
        )
        try validateSignature(
            of: applicationURL,
            requirementText: applicationSignatureRequirement,
            flags: flags,
            rejectionMessage: "the downloaded app is not a Developer ID build of Slaptop signed by AM Guru, LLC"
        )

        let bundleBuildNumber = try buildNumber(of: applicationURL)
        guard bundleBuildNumber == expectedBuildNumber else {
            throw AppUpdateError.installFailed(
                "release build \(expectedBuildNumber) contains app build \(bundleBuildNumber)"
            )
        }

        try assessWithGatekeeper(
            applicationURL,
            arguments: ["-a", "-t", "exec"],
            rejectionMessage: "the downloaded app is not accepted as a notarized application"
        )
    }

    static func buildNumber(of applicationURL: URL) throws -> Int {
        let infoPlistURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: infoPlistURL, options: .mappedIfSafe)
        } catch {
            throw AppUpdateError.installFailed("the downloaded app has no readable Info.plist")
        }

        guard
            let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = propertyList as? [String: Any],
            let version = dictionary["CFBundleVersion"] as? String,
            !version.isEmpty,
            version.allSatisfy(\.isNumber),
            let buildNumber = Int(version),
            version == String(buildNumber)
        else {
            throw AppUpdateError.installFailed("the downloaded app has an invalid CFBundleVersion")
        }
        return buildNumber
    }

    private static func validateSignature(
        of url: URL,
        requirementText: String,
        flags: SecCSFlags,
        rejectionMessage: String
    ) throws {
        var staticCode: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode
        else {
            throw AppUpdateError.installFailed("the downloaded update could not be inspected")
        }

        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else {
            throw AppUpdateError.installFailed("the update signature requirement is invalid")
        }

        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw AppUpdateError.installFailed(rejectionMessage)
        }
    }

    private static func assessWithGatekeeper(
        _ url: URL,
        arguments: [String],
        rejectionMessage: String
    ) throws {
        let rawAssessment = try run(
            "/usr/sbin/spctl",
            arguments + ["--raw", url.path],
            failure: { detail in
                AppUpdateError.installFailed("\(rejectionMessage): \(detail)")
            }
        )
        guard isNotarizedGatekeeperAssessment(Data(rawAssessment.utf8)) else {
            throw AppUpdateError.installFailed(
                "\(rejectionMessage): Gatekeeper did not report Notarized Developer ID"
            )
        }
    }

    static func isNotarizedGatekeeperAssessment(_ data: Data) -> Bool {
        guard
            let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = propertyList as? [String: Any],
            dictionary["assessment:verdict"] as? Bool == true,
            let authority = dictionary["assessment:authority"] as? [String: Any],
            authority["assessment:authority:source"] as? String == "Notarized Developer ID"
        else {
            return false
        }
        return true
    }

    @discardableResult
    private static func run(
        _ executable: String,
        _ arguments: [String],
        failure: (String) -> Error
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let standardError = Pipe()
        process.standardError = standardError
        let standardOutput = Pipe()
        process.standardOutput = standardOutput

        do {
            try process.run()
        } catch {
            throw failure(error.localizedDescription)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure(detail?.isEmpty == false ? detail! : "exit status \(process.terminationStatus)")
        }
        return String(
            data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }
}
