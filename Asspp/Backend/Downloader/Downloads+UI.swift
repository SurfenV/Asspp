//
//  Downloads+UI.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/13.
//

import ApplePackage
import CryptoKit
import Foundation
import SwiftUI
import ZIPFoundation

enum DownloadAction: Hashable {
    case suspend
    case resume
    case restart
    case delete
}

@MainActor
extension Downloads {
    func performDownloadAction(for request: PackageManifest, action: DownloadAction) {
        switch action {
        case .suspend:
            suspend(request: request)
        case .resume:
            resume(request: request)
        case .restart:
            restart(request: request)
        case .delete:
            delete(request: request)
        }
    }

    func getAvailableActions(for request: PackageManifest) -> [DownloadAction] {
        switch request.state.status {
        case .pending, .downloading:
            [.suspend, .delete]
        case .paused:
            [.resume, .delete]
        case .failed:
            [.restart, .delete]
        case .completed:
            [.delete]
        }
    }

    func getActionLabel(for action: DownloadAction) -> (title: String, systemImage: String, isDestructive: Bool) {
        switch action {
        case .suspend:
            (String(localized: "Pause"), "stop.fill", false)
        case .resume:
            (String(localized: "Resume"), "play.fill", false)
        case .restart:
            (String(localized: "Restart Download"), "arrow.clockwise", false)
        case .delete:
            (String(localized: "Delete"), "trash", true)
        }
    }
}

struct ExperimentalIPAResult: Sendable {
    let originalURL: URL
    let patchedURL: URL
    let reportURL: URL
    let displayVersion: String
    let originalMinimumOS: String?
    let patchedMinimumOS: String
    let originalSHA256: String
    let patchedSHA256: String
}

enum ExperimentalIPABuilder {
    static func build(
        account: inout Account,
        app: Software,
        versionID: String,
        displayVersion: String,
        minimumOS: String,
        endpointLabel: String,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> ExperimentalIPAResult {
        try validate(minimumOS: minimumOS)
        let fileManager = FileManager.default
        let operationID = String(UUID().uuidString.prefix(8))
        logger.info("[experimental-ipa:\(operationID)] begin endpoint=\(endpointLabel) bundle=\(app.bundleID) versionID=\(versionID) displayVersion=\(displayVersion) targetOS=\(minimumOS)")

        await progress("Requesting the \(endpointLabel) version download…")
        let downloadOutput = try await ApplePackage.Download.download(
            account: &account,
            app: app,
            externalVersionID: versionID
        )
        try Task.checkCancellation()
        guard let downloadURL = URL(string: downloadOutput.downloadURL) else {
            throw ExperimentalIPAError.invalidDownloadURL
        }

        await progress("Downloading version \(displayVersion)…")
        let (downloadedURL, response) = try await URLSession.shared.download(from: downloadURL)
        guard let response = response as? HTTPURLResponse,
              200 ... 299 ~= response.statusCode
        else {
            throw ExperimentalIPAError.downloadFailed
        }
        try Task.checkCancellation()

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ExperimentalIPA-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let assembledIPA = temporaryDirectory.appendingPathComponent("assembled.ipa")
        try fileManager.moveItem(at: downloadedURL, to: assembledIPA)

        await progress("Injecting App Store license data…")
        try await SignatureInjector.inject(
            sinfs: downloadOutput.sinfs,
            iTunesMetadata: downloadOutput.iTunesMetadata,
            into: assembledIPA.path
        )
        try Task.checkCancellation()

        let outputDirectory = documentsDirectory
            .appendingPathComponent("ExperimentalIPAs", isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let timestamp = outputTimestamp()
        let baseName = [
            safeFileComponent(app.bundleID),
            safeFileComponent(displayVersion),
            safeFileComponent(endpointLabel),
            "minOS\(safeFileComponent(minimumOS))",
            timestamp,
        ].joined(separator: "-")
        let originalURL = outputDirectory
            .appendingPathComponent("\(baseName)-original")
            .appendingPathExtension("ipa")
        let patchedURL = outputDirectory
            .appendingPathComponent("\(baseName)-patched")
            .appendingPathExtension("ipa")
        let reportURL = outputDirectory
            .appendingPathComponent("\(baseName)-report")
            .appendingPathExtension("txt")

        await progress("Saving an untouched assembled copy…")
        try fileManager.copyItem(at: assembledIPA, to: originalURL)

        let expandedDirectory = temporaryDirectory.appendingPathComponent("expanded", isDirectory: true)
        try fileManager.createDirectory(at: expandedDirectory, withIntermediateDirectories: true)
        await progress("Extracting IPA and locating the main app…")
        try fileManager.unzipItem(at: assembledIPA, to: expandedDirectory)
        try Task.checkCancellation()

        let infoPlistURL = try mainInfoPlist(in: expandedDirectory)
        let patchResult = try patchInfoPlist(at: infoPlistURL, minimumOS: minimumOS)
        logger.info("[experimental-ipa:\(operationID)] Info.plist patched path=\(patchResult.relativePath) originalOS=\(patchResult.originalMinimumOS ?? "missing") targetOS=\(minimumOS)")

        await progress("Repacking the experimental IPA…")
        try fileManager.zipItem(
            at: expandedDirectory,
            to: patchedURL,
            shouldKeepParent: false,
            compressionMethod: .deflate
        )
        try Task.checkCancellation()

        guard let archive = try? ZIPFoundation.Archive(
            url: patchedURL,
            accessMode: .read,
            pathEncoding: nil
        ),
              archive[patchResult.relativePath] != nil
        else {
            throw ExperimentalIPAError.invalidPatchedArchive
        }

        await progress("Calculating checksums and writing report…")
        let originalSHA256 = try sha256(of: originalURL)
        let patchedSHA256 = try sha256(of: patchedURL)
        let report = """
        Asspp Experimental IPA Report
        Endpoint: \(endpointLabel)
        Bundle ID: \(app.bundleID)
        External version ID: \(versionID)
        Display version: \(displayVersion)
        Main Info.plist: \(patchResult.relativePath)
        Original MinimumOSVersion: \(patchResult.originalMinimumOS ?? "missing")
        Patched MinimumOSVersion: \(minimumOS)
        Original IPA: \(originalURL.lastPathComponent)
        Original SHA-256: \(originalSHA256)
        Patched IPA: \(patchedURL.lastPathComponent)
        Patched SHA-256: \(patchedSHA256)

        Warning: This experiment only changes the main app Info.plist. It does not
        modify Mach-O deployment targets or backport unavailable system APIs.
        Install the patched IPA manually with TrollStore and keep the original copy.
        """
        try Data(report.utf8).write(to: reportURL, options: .atomic)
        logger.info("[experimental-ipa:\(operationID)] completed original=\(originalURL.lastPathComponent) patched=\(patchedURL.lastPathComponent) originalSHA256=\(originalSHA256) patchedSHA256=\(patchedSHA256)")

        return ExperimentalIPAResult(
            originalURL: originalURL,
            patchedURL: patchedURL,
            reportURL: reportURL,
            displayVersion: displayVersion,
            originalMinimumOS: patchResult.originalMinimumOS,
            patchedMinimumOS: minimumOS,
            originalSHA256: originalSHA256,
            patchedSHA256: patchedSHA256
        )
    }

    static func normalizedMinimumOS(_ input: String) -> String? {
        let components = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(components.count) else { return nil }
        let numbers = components.compactMap { Int($0) }
        guard numbers.count == components.count,
              numbers.allSatisfy({ 0 ... 99 ~= $0 }),
              let major = numbers.first,
              major > 0
        else {
            return nil
        }
        return numbers.map(String.init).joined(separator: ".")
    }

    private static func validate(minimumOS: String) throws {
        guard normalizedMinimumOS(minimumOS) == minimumOS else {
            throw ExperimentalIPAError.invalidMinimumOS
        }
    }

    private static func mainInfoPlist(in expandedDirectory: URL) throws -> URL {
        let payloadDirectory = expandedDirectory.appendingPathComponent("Payload", isDirectory: true)
        let appDirectories = try FileManager.default.contentsOfDirectory(
            at: payloadDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "app" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let appDirectory = appDirectories.first else {
            throw ExperimentalIPAError.mainAppMissing
        }
        let infoPlistURL = appDirectory.appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: infoPlistURL.path) else {
            throw ExperimentalIPAError.infoPlistMissing
        }
        return infoPlistURL
    }

    private static func patchInfoPlist(
        at infoPlistURL: URL,
        minimumOS: String
    ) throws -> (originalMinimumOS: String?, relativePath: String) {
        let data = try Data(contentsOf: infoPlistURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: &format
        ) as? [String: Any]
        else {
            throw ExperimentalIPAError.invalidInfoPlist
        }
        let originalMinimumOS = plist["MinimumOSVersion"] as? String
        plist["MinimumOSVersion"] = minimumOS
        let patchedData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: format,
            options: 0
        )
        try patchedData.write(to: infoPlistURL, options: .atomic)

        let components = infoPlistURL.pathComponents
        guard let payloadIndex = components.firstIndex(of: "Payload") else {
            throw ExperimentalIPAError.mainAppMissing
        }
        return (
            originalMinimumOS,
            components[payloadIndex...].joined(separator: "/")
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func safeFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }

    private static func outputTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private enum ExperimentalIPAError: LocalizedError {
    case invalidMinimumOS
    case invalidDownloadURL
    case downloadFailed
    case mainAppMissing
    case infoPlistMissing
    case invalidInfoPlist
    case invalidPatchedArchive

    var errorDescription: String? {
        switch self {
        case .invalidMinimumOS:
            return "Enter a valid minimum system version such as 15.0 or 15.8."
        case .invalidDownloadURL:
            return "The App Store returned an invalid package URL."
        case .downloadFailed:
            return "The historical IPA download failed."
        case .mainAppMissing:
            return "The IPA does not contain a main app bundle."
        case .infoPlistMissing:
            return "The main app has no Info.plist."
        case .invalidInfoPlist:
            return "The main app Info.plist could not be decoded."
        case .invalidPatchedArchive:
            return "The generated IPA failed its structure check."
        }
    }
}

extension Downloads {
    func startDownload(for package: AppStore.AppPackage, accountID: String) async throws {
        try await AppStore.this.withAccount(id: accountID) { account in
            let downloadOutput = try await ApplePackage.Download.download(
                account: &account.account,
                app: package.software,
                externalVersionID: package.externalVersionID
            )
            let request = Downloads.this.add(request: .init(
                account: account,
                package: package,
                downloadOutput: downloadOutput
            ))
            Downloads.this.resume(request: request)
        }
    }
}
