//
//  LogManager.swift
//  Asspp
//
//  Persistent, privacy-filtered diagnostic logging.
//

import Foundation
import Logging

final class LogManager: @unchecked Sendable {
    static let shared = LogManager()

    private let queue = DispatchQueue(label: "wiki.qaq.asspp.diagnostic-log")
    private let fileURL: URL
    private var messages: [String]

    private static let maximumMessages = 2000

    private init() {
        let baseURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Asspp", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        fileURL = baseURL.appendingPathComponent("asspp-diagnostic.log")

        if let data = try? Data(contentsOf: fileURL),
           let content = String(data: data, encoding: .utf8)
        {
            messages = Array(content
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                .suffix(Self.maximumMessages))
        } else {
            messages = []
        }
    }

    func write(_ content: String) {
        // Diagnostics must survive a main-thread hang followed by force quit.
        // Write synchronously and ask the filesystem to flush every record.
        queue.sync { [self] in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let flattened = sanitize(content.replacingOccurrences(of: "\n", with: " | "))
            let entry = "\(timestamp) \(flattened)"
            messages.append(entry)
            if messages.count > Self.maximumMessages {
                messages.removeFirst(messages.count - Self.maximumMessages)
                persistAndSynchronize()
            } else {
                appendAndSynchronize(entry)
            }
        }
    }

    func text() -> String {
        queue.sync { messages.joined(separator: "\n") }
    }

    func clear() {
        queue.sync {
            messages.removeAll()
            persistAndSynchronize()
        }
    }

    func exportURL() -> URL {
        queue.sync {
            synchronizeFile()
            return fileURL
        }
    }

    private func appendAndSynchronize(_ entry: String) {
        guard let data = "\(entry)\n".data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            handle.seekToEndOfFile()
            handle.write(data)
            handle.synchronizeFile()
            handle.closeFile()
        } catch {
            persistAndSynchronize()
        }
    }

    private func persistAndSynchronize() {
        let content = messages.joined(separator: "\n") + (messages.isEmpty ? "" : "\n")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        synchronizeFile()
    }

    private func synchronizeFile() {
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        handle.synchronizeFile()
        handle.closeFile()
    }

    private func sanitize(_ content: String) -> String {
        let patterns = [
            #"(?i)((?:guid|dsid|token|password|cookie|authorization)[^=:\s]*\s*[=:]\s*)([^\s|&,]+)"#,
            #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        ]
        return patterns.enumerated().reduce(content) { result, item in
            guard let expression = try? NSRegularExpression(pattern: item.element) else {
                return result
            }
            let range = NSRange(result.startIndex..., in: result)
            let replacement = item.offset == 0 ? "$1<redacted>" : "<account-redacted>"
            return expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
    }
}

struct LogManagerHandler: LogHandler {
    let label: String
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .debug

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata explicitMetadata: Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        guard level >= logLevel else { return }
        var mergedMetadata = metadata
        if let explicitMetadata {
            mergedMetadata.merge(explicitMetadata) { _, new in new }
        }
        let metadataText = mergedMetadata.isEmpty
            ? ""
            : " " + mergedMetadata.map { "\($0)=\($1)" }.sorted().joined(separator: " ")
        let entry = "[\(level)] [\(label)] \(message)\(metadataText)"
        print(entry)
        LogManager.shared.write(entry)
    }
}
