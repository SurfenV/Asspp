//
//  VersionFinder.swift
//  ApplePackage
//
//  Created by qaq on 9/14/25.
//

import AsyncHTTPClient
import Foundation

public enum VersionFinder {
    public static func list(
        account: inout Account,
        bundleIdentifier: String,
        entityType: EntityType? = nil,
        externalVersionID: String? = nil
    ) async throws -> [String] {
        let output = try await listReturningAccount(
            account: account,
            bundleIdentifier: bundleIdentifier,
            entityType: entityType,
            externalVersionID: externalVersionID
        )
        account = output.account
        return output.versions
    }

    /// Value-based entry point used on iOS 15 so no exclusive `inout` access
    /// spans an async HTTP request.
    public static func listReturningAccount(
        account initialAccount: Account,
        bundleIdentifier: String,
        knownApp: Software? = nil,
        entityType: EntityType? = nil,
        externalVersionID: String? = nil
    ) async throws -> (versions: [String], account: Account) {
        let startedAt = Date()
        var account = initialAccount
        APLogger.info("versions: list start bundle=\(bundleIdentifier) store=\(account.store) pod=\(account.pod ?? "missing")")
        guard let countryCode = Configuration.countryCode(for: account.store) else {
            try ensureFailed(Strings.unsupportedStoreIdentifier(account.store))
        }
        let app: Software
        if let knownApp,
           knownApp.bundleID.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        {
            app = knownApp
            APLogger.info("versions: using known appID=\(app.id) country=\(countryCode) elapsed=\(elapsed(since: startedAt))s")
        } else {
            app = try await Lookup.lookup(
                bundleID: bundleIdentifier,
                countryCode: countryCode,
                entityType: entityType
            )
            APLogger.info("versions: lookup resolved appID=\(app.id) country=\(countryCode) elapsed=\(elapsed(since: startedAt))s")
        }
        let resolvedExternalVersionID: String
        if let externalVersionID {
            resolvedExternalVersionID = externalVersionID
        } else if let entityType {
            let metadata = try await PlatformVersionLookup.lookup(
                appID: app.id,
                countryCode: countryCode,
                entityType: entityType
            )
            resolvedExternalVersionID = metadata.externalVersionID
        } else {
            resolvedExternalVersionID = ""
        }

        let client = Configuration.sharedStoreHTTPClient
        APLogger.info("versions: shared store client acquired")

        let fetchResult = try await StoreDownloadEndpoint.fetchProductReturningAccount(
            client: client,
            account: account,
            app: app,
            deviceIdentifier: Configuration.deviceIdentifier,
            externalVersionID: resolvedExternalVersionID
        )
        account = fetchResult.account
        let dict = fetchResult.dictionary

        guard let items = dict["songList"] as? [[String: Any]], !items.isEmpty else {
            if let failureType = dict["failureType"] as? String {
                let customerMessage = dict["customerMessage"] as? String
                switch failureType {
                case "2034", "2042":
                    try ensureFailed(Strings.passwordTokenExpired)
                case "9610":
                    throw ApplePackageError.licenseRequired
                default:
                    if customerMessage == Strings.passwordChanged {
                        try ensureFailed(Strings.passwordTokenExpired)
                    }
                    if let customerMessage = customerMessage {
                        try ensureFailed(customerMessage)
                    }
                    try ensureFailed(Strings.noItemsInResponse)
                }
            } else {
                try ensureFailed(Strings.noItemsInResponse)
            }
        }

        let item = items[0]
        guard let metadata = item["metadata"] as? [String: Any],
              let identifiers = metadata["softwareVersionExternalIdentifiers"] as? [Any]
        else {
            try ensureFailed(Strings.missingVersionIdentifiers)
        }

        let result = identifiers.map { "\($0)" }
        try ensure(!result.isEmpty, Strings.noVersionsFound)

        APLogger.info("versions: list parsed count=\(result.count) updatedPod=\(account.pod ?? "missing") elapsed=\(elapsed(since: startedAt))s")
        APLogger.info("versions: returning list through app-lifetime client")
        return (result, account)
    }

    private static func elapsed(since date: Date) -> String {
        String(format: "%.2f", Date().timeIntervalSince(date))
    }
}
