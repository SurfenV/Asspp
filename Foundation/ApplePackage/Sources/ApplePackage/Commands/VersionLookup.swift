//
//  VersionLookup.swift
//  ApplePackage
//
//  Created by qaq on 9/15/25.
//

import AsyncHTTPClient
import Foundation

public enum VersionLookup {
    public static func getVersionMetadata(
        account: inout Account,
        app: Software,
        versionID: String
    ) async throws -> VersionMetadata {
        let output = try await getVersionMetadataReturningAccount(
            account: account,
            app: app,
            versionID: versionID
        )
        account = output.account
        return output.metadata
    }

    /// Value-based entry point matching `VersionFinder.listReturningAccount`.
    public static func getVersionMetadataReturningAccount(
        account initialAccount: Account,
        app: Software,
        versionID: String
    ) async throws -> (metadata: VersionMetadata, account: Account) {
        let startedAt = Date()
        var account = initialAccount
        APLogger.info("versions: metadata start appID=\(app.id) versionID=\(versionID) pod=\(account.pod ?? "missing")")
        let client = Configuration.sharedStoreHTTPClient
        APLogger.info("versions: shared metadata client acquired versionID=\(versionID)")

        let fetchResult = try await StoreDownloadEndpoint.fetchProductReturningAccount(
            client: client,
            account: account,
            app: app,
            deviceIdentifier: Configuration.deviceIdentifier,
            externalVersionID: versionID
        )
        account = fetchResult.account
        let dict = fetchResult.dictionary

        guard let items = dict["songList"] as? [[String: Any]], !items.isEmpty else {
            try ensureFailed(Strings.noItemsInResponse)
        }

        let item = items[0]
        guard let metadata = item["metadata"] as? [String: Any] else {
            try ensureFailed(Strings.missingMetadata)
        }

        guard let bundleShortVersionString = metadata["bundleShortVersionString"] as? String else {
            try ensureFailed(Strings.missingBundleShortVersionString)
        }

        var minimumOsVersion = findMinimumOsVersion(in: item)
        var packageDate: Date?
        if let packageURLString = item["URL"] as? String,
           let packageURL = URL(string: packageURLString)
        {
            APLogger.info("versions: remote package inspection start versionID=\(versionID)")
            do {
                let inspection = try await RemotePackageMetadata.inspect(packageURL)
                if minimumOsVersion == nil {
                    minimumOsVersion = inspection.minimumOsVersion
                }
                packageDate = inspection.packageDate
                APLogger.info("versions: remote package inspection completed versionID=\(versionID) minimumOS=\(minimumOsVersion ?? "unknown") packageDate=\(packageDate?.description ?? "unknown")")
            } catch {
                APLogger.info("versions: remote package inspection failed versionID=\(versionID) error=\(error.localizedDescription)")
            }
        }
        if minimumOsVersion == nil {
            let itemKeys = item.keys.sorted().joined(separator: ",")
            let metadataKeys = metadata.keys.sorted().joined(separator: ",")
            APLogger.info("versions: minimum OS unavailable versionID=\(versionID) itemKeys=[\(itemKeys)] metadataKeys=[\(metadataKeys)]")
        }

        APLogger.info("versions: metadata parsed versionID=\(versionID) displayVersion=\(bundleShortVersionString) minimumOS=\(minimumOsVersion ?? "unknown") packageDate=\(packageDate?.description ?? "unknown") elapsed=\(elapsed(since: startedAt))s")
        APLogger.info("versions: returning metadata through app-lifetime client versionID=\(versionID)")
        return (
            VersionMetadata(
                displayVersion: bundleShortVersionString,
                releaseDate: packageDate,
                minimumOsVersion: minimumOsVersion
            ),
            account
        )
    }

    /// Apple has used several spellings and nesting locations for this value
    /// across Store responses. Search the complete product item so older
    /// responses can still expose their deployment target when present.
    private static func findMinimumOsVersion(in value: Any, depth: Int = 0) -> String? {
        guard depth <= 6 else { return nil }

        if let dictionary = value as? [String: Any] {
            let preferredKeys = [
                "minimumOsVersion",
                "minimumOSVersion",
                "MinimumOSVersion",
                "minOsVersion",
                "minOSVersion",
                "softwareMinimumOsVersion",
                "softwareMinimumOSVersion",
            ]
            for key in preferredKeys {
                if let version = versionString(from: dictionary[key]) {
                    return version
                }
            }

            for (key, nestedValue) in dictionary {
                let normalizedKey = key.lowercased()
                if normalizedKey.contains("minimum"),
                   normalizedKey.contains("os"),
                   let version = versionString(from: nestedValue)
                {
                    return version
                }
            }

            for nestedValue in dictionary.values {
                if let version = findMinimumOsVersion(in: nestedValue, depth: depth + 1) {
                    return version
                }
            }
        } else if let array = value as? [Any] {
            for nestedValue in array {
                if let version = findMinimumOsVersion(in: nestedValue, depth: depth + 1) {
                    return version
                }
            }
        }
        return nil
    }

    private static func versionString(from value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func elapsed(since date: Date) -> String {
        String(format: "%.2f", Date().timeIntervalSince(date))
    }
}
