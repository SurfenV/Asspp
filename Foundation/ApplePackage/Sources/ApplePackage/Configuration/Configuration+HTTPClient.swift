//
//  Configuration+HTTPClient.swift
//  ApplePackage
//
//  Created on 2026/6/12.
//

import AsyncHTTPClient
import Foundation

extension Configuration {
    /// App-lifetime client for Store API requests. AsyncHTTPClient is designed
    /// to be shared across requests; retaining this client also avoids a
    /// back-deployed iOS 15 runtime stall while destroying a per-request
    /// client after its shutdown callback has completed.
    static let sharedStoreHTTPClient = HTTPClient(
        eventLoopGroupProvider: .singleton,
        configuration: .init(
            tlsConfiguration: tlsConfiguration,
            redirectConfiguration: .disallow,
            timeout: .init(
                connect: .seconds(timeoutConnect),
                read: .seconds(timeoutRead)
            )
        ).then { $0.httpVersion = .http1Only }
    )

    /// Shared HTTP/1.1-only client used by all store requests.
    /// Callers own the returned client and must shut it down.
    static func makeHTTPClient(
        redirectConfiguration: HTTPClient.Configuration.RedirectConfiguration
    ) -> HTTPClient {
        HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: .init(
                tlsConfiguration: tlsConfiguration,
                redirectConfiguration: redirectConfiguration,
                timeout: .init(
                    connect: .seconds(timeoutConnect),
                    read: .seconds(timeoutRead)
                )
            ).then { $0.httpVersion = .http1Only }
        )
    }
}
