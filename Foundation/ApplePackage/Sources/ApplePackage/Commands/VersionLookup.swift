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
        let client = Configuration.makeHTTPClient(redirectConfiguration: .disallow)
        defer {
            APLogger.info("versions: metadata client shutdown begin versionID=\(versionID)")
            let shutdownFuture = client.shutdown()
            APLogger.info("versions: metadata client shutdown scheduled versionID=\(versionID)")
            shutdownFuture.whenComplete { result in
                switch result {
                case .success:
                    APLogger.info("versions: metadata client shutdown completed versionID=\(versionID)")
                case let .failure(error):
                    APLogger.error("versions: metadata client shutdown failed versionID=\(versionID) type=\(String(reflecting: type(of: error))) error=\(error.localizedDescription)")
                }
            }
        }

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

        guard let releaseDateString = metadata["releaseDate"] as? String,
              let releaseDate = ISO8601DateFormatter().date(from: releaseDateString)
        else {
            try ensureFailed(Strings.missingOrInvalidReleaseDate)
        }

        APLogger.info("versions: metadata parsed versionID=\(versionID) displayVersion=\(bundleShortVersionString) elapsed=\(elapsed(since: startedAt))s")
        return (VersionMetadata(displayVersion: bundleShortVersionString, releaseDate: releaseDate), account)
    }

    private static func elapsed(since date: Date) -> String {
        String(format: "%.2f", Date().timeIntervalSince(date))
    }
}
