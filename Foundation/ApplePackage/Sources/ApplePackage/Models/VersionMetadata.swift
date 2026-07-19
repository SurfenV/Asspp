//
//  VersionMetadata.swift
//  ApplePackage
//
//  Created by qaq on 9/15/25.
//

import Foundation

public struct VersionMetadata: Codable, Equatable, Hashable, Sendable {
    public var displayVersion: String
    /// The timestamp stored on the app bundle inside the historical IPA.
    /// Apple does not expose a reliable per-version release date from the
    /// download endpoint, so this is an approximate package date.
    public var releaseDate: Date?
    public var minimumOsVersion: String?

    public init(
        displayVersion: String,
        releaseDate: Date? = nil,
        minimumOsVersion: String? = nil
    ) {
        self.displayVersion = displayVersion
        self.releaseDate = releaseDate
        self.minimumOsVersion = minimumOsVersion
    }
}
