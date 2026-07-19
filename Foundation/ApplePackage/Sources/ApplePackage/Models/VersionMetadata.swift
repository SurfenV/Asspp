//
//  VersionMetadata.swift
//  ApplePackage
//
//  Created by qaq on 9/15/25.
//

import Foundation

public struct VersionMetadata: Codable, Equatable, Hashable, Sendable {
    public var displayVersion: String
    public var releaseDate: Date
    public var minimumOsVersion: String?

    public init(
        displayVersion: String,
        releaseDate: Date,
        minimumOsVersion: String? = nil
    ) {
        self.displayVersion = displayVersion
        self.releaseDate = releaseDate
        self.minimumOsVersion = minimumOsVersion
    }
}
