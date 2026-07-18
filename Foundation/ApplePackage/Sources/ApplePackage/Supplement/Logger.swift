//
//  Logger.swift
//  ApplePackage
//
//  Created on 2026/2/20.
//

import Foundation
import Logging

public enum APLogger {
    public static var verbose: Bool = false

    private static var _logger: Logger = .init(label: "com.applepackage")

    public static var logger: Logger {
        get { _logger }
        set { _logger = newValue }
    }

    static func info(_ message: String) {
        _logger.info("\(message)")
    }

    static func debug(_ message: String) {
        guard verbose else { return }
        _logger.debug("\(message)")
    }

    static func error(_ message: String) {
        _logger.error("\(message)")
    }

    static func logRequest(method: String, url: String, headers: [(String, String)] = []) {
        guard verbose else { return }
        var msg = ">>> \(method) \(sanitizedURL(url))"
        for (name, value) in headers {
            msg += "\n    \(name): \(sanitizedHeaderValue(name: name, value: value))"
        }
        debug(msg)
    }

    static func logResponse(status: UInt, headers: [(String, String)] = [], bodySize: Int? = nil) {
        guard verbose else { return }
        var msg = "<<< \(status)"
        if let bodySize = bodySize {
            msg += " (\(bodySize) bytes)"
        }
        for (name, value) in headers {
            msg += "\n    \(name): \(sanitizedHeaderValue(name: name, value: value))"
        }
        debug(msg)
    }

    private static func sanitizedHeaderValue(name: String, value: String) -> String {
        let sensitiveNames = [
            "authorization", "cookie", "dsid", "guid", "password", "token",
        ]
        let loweredName = name.lowercased()
        if sensitiveNames.contains(where: loweredName.contains) {
            return "<redacted>"
        }
        if loweredName == "location" {
            return sanitizedURL(value)
        }
        return value
    }

    private static func sanitizedURL(_ value: String) -> String {
        guard var components = URLComponents(string: value),
              let queryItems = components.queryItems
        else {
            return value
        }
        let sensitiveNames = ["dsid", "guid", "password", "token"]
        components.queryItems = queryItems.map { item in
            let loweredName = item.name.lowercased()
            guard sensitiveNames.contains(where: loweredName.contains) else { return item }
            return URLQueryItem(name: item.name, value: "<redacted>")
        }
        return components.string ?? "<url-redacted>"
    }
}
