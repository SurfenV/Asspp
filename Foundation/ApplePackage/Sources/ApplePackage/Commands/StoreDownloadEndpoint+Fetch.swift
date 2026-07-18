//
//  StoreDownloadEndpoint+Fetch.swift
//  ApplePackage
//
//  Created on 2026/6/12.
//

import AsyncHTTPClient
import Foundation

extension StoreDownloadEndpoint {
    /// Fetches the product info from the volumeStore endpoint, transparently
    /// retrying via the redownload endpoint when Apple rejects the request
    /// with failureType 5002.
    static func fetchProductWithFallback(
        client: HTTPClient,
        account: inout Account,
        app: Software,
        deviceIdentifier: String,
        externalVersionID: String
    ) async throws -> [String: Any] {
        var dict = try await StoreDownloadEndpoint.volumeStore.fetchProduct(
            client: client,
            account: &account,
            app: app,
            deviceIdentifier: deviceIdentifier,
            externalVersionID: externalVersionID
        )

        if dict["failureType"] as? String == retryableFailureType {
            APLogger.debug("store: volumeStore rejected with 5002, retrying via redownload endpoint")
            dict = try await StoreDownloadEndpoint.redownload.fetchProduct(
                client: client,
                account: &account,
                app: app,
                deviceIdentifier: deviceIdentifier,
                externalVersionID: externalVersionID
            )
        }

        return dict
    }

    /// Runs the product request against this endpoint, following pod redirects,
    /// and returns the parsed plist response.
    func fetchProduct(
        client: HTTPClient,
        account: inout Account,
        app: Software,
        deviceIdentifier: String,
        externalVersionID: String
    ) async throws -> [String: Any] {
        var currentURL = try url(pod: account.pod, deviceIdentifier: deviceIdentifier)
        var redirectAttempt = 0
        var finalResponse: HTTPClient.Response?
        let maxRedirects = 3

        while redirectAttempt <= maxRedirects {
            let request = try makeRequest(
                account: account,
                app: app,
                url: currentURL,
                guid: deviceIdentifier,
                externalVersionID: externalVersionID
            )
            let response = try await client.execute(request: request).get()
            defer { finalResponse = response }

            APLogger.logResponse(
                status: response.status.code,
                headers: response.headers.map { ($0.name, $0.value) },
                bodySize: response.body?.readableBytes
            )

            account.cookie.mergeCookies(response.cookies)
            updatePod(account: &account, response: response)

            if response.status == .found {
                guard let location = response.headers.first(name: "location"),
                      let newURL = URL(string: location)
                else {
                    try ensureFailed(Strings.failedToRetrieveRedirect)
                }
                currentURL = newURL
                redirectAttempt += 1
                continue
            }
            break
        }

        guard let finalResponse else { try ensureFailed(Strings.noResponseReceived) }

        try ensure(finalResponse.status == .ok, Strings.requestFailed(status: finalResponse.status.code))

        guard var body = finalResponse.body,
              let data = body.readData(length: body.readableBytes)
        else {
            try ensureFailed(Strings.responseBodyEmpty)
        }

        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
        guard let dict = plist else { try ensureFailed(Strings.invalidResponse) }

        return dict
    }

    /// Older Asspp builds persisted accounts before ApplePackage stored their
    /// pod. Learn it from the first store response/redirect so existing users
    /// do not have to remove and add every account again after upgrading.
    private func updatePod(account: inout Account, response: HTTPClient.Response) {
        if let header = response.headers.first(name: "pod"),
           let pod = normalizedPod(header)
        {
            account.pod = pod
            return
        }

        guard let location = response.headers.first(name: "location"),
              let host = URL(string: location)?.host,
              let pod = podFromStoreHost(host)
        else {
            return
        }
        account.pod = pod
    }

    private func normalizedPod(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("p") ? String(trimmed.dropFirst()) : trimmed
        guard !withoutPrefix.isEmpty,
              withoutPrefix.allSatisfy(\.isNumber)
        else {
            return nil
        }
        return withoutPrefix
    }

    private func podFromStoreHost(_ host: String) -> String? {
        guard host.hasPrefix("p"),
              let separator = host.firstIndex(of: "-")
        else {
            return nil
        }
        return normalizedPod(String(host[host.startIndex ..< separator]))
    }

    private func makeRequest(
        account: Account,
        app: Software,
        url: URL,
        guid: String,
        externalVersionID: String
    ) throws -> HTTPClient.Request {
        var payload: [String: Any] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": app.id,
        ]

        if !externalVersionID.isEmpty {
            payload[externalVersionIDKey] = externalVersionID
        }

        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

        var headers: [(String, String)] = [
            ("Content-Type", "application/x-apple-plist"),
            ("User-Agent", Configuration.userAgent),
            ("iCloud-DSID", account.directoryServicesIdentifier),
            ("X-Dsid", account.directoryServicesIdentifier),
        ]

        for item in account.cookie.buildCookieHeader(url) {
            headers.append(item)
        }

        APLogger.logRequest(method: "POST", url: url.absoluteString, headers: headers)

        return try .init(
            url: url,
            method: .POST,
            headers: .init(headers),
            body: .data(data)
        )
    }
}
