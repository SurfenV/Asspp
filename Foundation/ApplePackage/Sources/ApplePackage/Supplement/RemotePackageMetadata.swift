//
//  RemotePackageMetadata.swift
//  ApplePackage
//
//  Reads a small part of a remote IPA to inspect its main Info.plist.
//

import Foundation
import ZIPFoundation

enum RemotePackageMetadata {
    private static let tailLength = 128 * 1024
    private static let maximumCentralDirectoryLength = 32 * 1024 * 1024
    private static let initialLocalEntryLength = 128 * 1024
    private static let maximumInfoPlistLength = 4 * 1024 * 1024

    struct Inspection: Sendable {
        let minimumOsVersion: String?
        let packageDate: Date?
    }

    static func inspect(_ packageURL: URL) async throws -> Inspection {
        let tail = try await fetch(
            packageURL,
            range: "bytes=-\(tailLength)",
            maximumLength: tailLength
        )
        let totalLength = try totalLength(from: tail.contentRange)
        let endRecordOffset = try endOfCentralDirectoryOffset(in: tail.data)
        let centralDirectoryLength = Int(try tail.data.zipUInt32(at: endRecordOffset + 12))
        let centralDirectoryOffset = Int64(try tail.data.zipUInt32(at: endRecordOffset + 16))

        guard centralDirectoryLength > 0,
              centralDirectoryLength <= maximumCentralDirectoryLength,
              centralDirectoryOffset >= 0,
              centralDirectoryOffset + Int64(centralDirectoryLength) <= totalLength
        else {
            throw RemotePackageMetadataError.invalidCentralDirectory
        }

        let centralDirectory = try await fetch(
            packageURL,
            range: byteRange(start: centralDirectoryOffset, length: centralDirectoryLength),
            maximumLength: centralDirectoryLength
        ).data
        let entry = try mainInfoPlistEntry(in: centralDirectory)

        guard entry.compressedSize <= maximumInfoPlistLength,
              entry.uncompressedSize <= maximumInfoPlistLength
        else {
            throw RemotePackageMetadataError.infoPlistTooLarge
        }

        let initialLength = min(
            initialLocalEntryLength,
            Int(totalLength - entry.localHeaderOffset)
        )
        guard initialLength >= 30 else {
            throw RemotePackageMetadataError.invalidLocalHeader
        }

        var localEntry = try await fetch(
            packageURL,
            range: byteRange(start: entry.localHeaderOffset, length: initialLength),
            maximumLength: initialLength
        ).data
        let localHeaderLength = try localHeaderLength(in: localEntry)
        let requiredLocalEntryLength = localHeaderLength + entry.compressedSize

        guard requiredLocalEntryLength <= maximumInfoPlistLength + 65_536,
              entry.localHeaderOffset + Int64(requiredLocalEntryLength) <= totalLength
        else {
            throw RemotePackageMetadataError.invalidLocalHeader
        }

        if localEntry.count < requiredLocalEntryLength {
            localEntry = try await fetch(
                packageURL,
                range: byteRange(
                    start: entry.localHeaderOffset,
                    length: requiredLocalEntryLength
                ),
                maximumLength: requiredLocalEntryLength
            ).data
        } else if localEntry.count > requiredLocalEntryLength {
            localEntry = Data(localEntry.prefix(requiredLocalEntryLength))
        }

        let archiveData = try makeSingleEntryArchive(
            localEntry: localEntry,
            centralEntry: entry
        )
        let archive = try Archive(data: archiveData, accessMode: .read)
        guard let infoEntry = archive[entry.path] else {
            throw RemotePackageMetadataError.infoPlistNotFound
        }

        var plistData = Data()
        _ = try archive.extract(infoEntry) { plistData.append($0) }
        guard let plist = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any]
        else {
            throw RemotePackageMetadataError.invalidInfoPlist
        }

        var minimumOsVersion: String?
        for key in ["MinimumOSVersion", "LSMinimumSystemVersion"] {
            if let value = plist[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    minimumOsVersion = trimmed
                    break
                }
            }
        }
        return Inspection(
            minimumOsVersion: minimumOsVersion,
            packageDate: entry.modificationDate
        )
    }

    private static func fetch(
        _ url: URL,
        range: String,
        maximumLength: Int
    ) async throws -> ByteRangeResult {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return try await ByteRangeLoader(maximumLength: maximumLength).load(request)
    }

    private static func byteRange(start: Int64, length: Int) -> String {
        "bytes=\(start)-\(start + Int64(length) - 1)"
    }

    private static func totalLength(from contentRange: String?) throws -> Int64 {
        guard let contentRange,
              let separator = contentRange.lastIndex(of: "/"),
              let length = Int64(contentRange[contentRange.index(after: separator)...]),
              length > 0
        else {
            throw RemotePackageMetadataError.invalidContentRange
        }
        return length
    }

    private static func endOfCentralDirectoryOffset(in data: Data) throws -> Int {
        guard data.count >= 22 else {
            throw RemotePackageMetadataError.endOfCentralDirectoryMissing
        }
        let lowerBound = max(0, data.count - 65_557)
        for offset in stride(from: data.count - 22, through: lowerBound, by: -1) {
            if try data.zipUInt32(at: offset) == 0x0605_4B50 {
                let commentLength = Int(try data.zipUInt16(at: offset + 20))
                if offset + 22 + commentLength == data.count {
                    return offset
                }
            }
        }
        throw RemotePackageMetadataError.endOfCentralDirectoryMissing
    }

    private static func mainInfoPlistEntry(in data: Data) throws -> CentralEntry {
        var offset = 0
        while offset + 46 <= data.count {
            guard try data.zipUInt32(at: offset) == 0x0201_4B50 else {
                throw RemotePackageMetadataError.invalidCentralDirectory
            }

            let fileNameLength = Int(try data.zipUInt16(at: offset + 28))
            let extraLength = Int(try data.zipUInt16(at: offset + 30))
            let commentLength = Int(try data.zipUInt16(at: offset + 32))
            let recordLength = 46 + fileNameLength + extraLength + commentLength
            guard offset + recordLength <= data.count else {
                throw RemotePackageMetadataError.invalidCentralDirectory
            }

            let nameStart = offset + 46
            let nameData = data.subdata(in: nameStart ..< nameStart + fileNameLength)
            if let path = String(data: nameData, encoding: .utf8),
               isMainInfoPlist(path)
            {
                let flags = try data.zipUInt16(at: offset + 8)
                guard flags & 0x0001 == 0 else {
                    throw RemotePackageMetadataError.encryptedEntry
                }

                let compressedSizeValue = try data.zipUInt32(at: offset + 20)
                let uncompressedSizeValue = try data.zipUInt32(at: offset + 24)
                let localHeaderOffsetValue = try data.zipUInt32(at: offset + 42)
                guard compressedSizeValue != UInt32.max,
                      uncompressedSizeValue != UInt32.max,
                      localHeaderOffsetValue != UInt32.max
                else {
                    throw RemotePackageMetadataError.zip64Unsupported
                }

                return CentralEntry(
                    path: path,
                    record: data.subdata(in: offset ..< offset + recordLength),
                    flags: flags,
                    compressionMethod: try data.zipUInt16(at: offset + 10),
                    checksum: try data.zipUInt32(at: offset + 16),
                    compressedSize: Int(compressedSizeValue),
                    uncompressedSize: Int(uncompressedSizeValue),
                    localHeaderOffset: Int64(localHeaderOffsetValue),
                    modificationDate: try zipDate(
                        time: data.zipUInt16(at: offset + 12),
                        date: data.zipUInt16(at: offset + 14)
                    )
                )
            }
            offset += recordLength
        }
        throw RemotePackageMetadataError.infoPlistNotFound
    }

    private static func isMainInfoPlist(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 3
            && components[0] == "Payload"
            && components[1].hasSuffix(".app")
            && components[2] == "Info.plist"
    }

    /// ZIP entries use a timezone-free MS-DOS timestamp. Treat it as UTC and
    /// use it only as an approximate package date, never as an exact App Store
    /// release timestamp.
    private static func zipDate(time: UInt16, date: UInt16) -> Date? {
        let year = 1980 + Int((date >> 9) & 0x7F)
        let month = Int((date >> 5) & 0x0F)
        let day = Int(date & 0x1F)
        guard year >= 2007,
              year <= Calendar.current.component(.year, from: Date()) + 1,
              (1 ... 12).contains(month),
              (1 ... 31).contains(day)
        else {
            return nil
        }

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = Int((time >> 11) & 0x1F)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int(time & 0x1F) * 2
        return components.date
    }

    private static func localHeaderLength(in data: Data) throws -> Int {
        guard data.count >= 30,
              try data.zipUInt32(at: 0) == 0x0403_4B50
        else {
            throw RemotePackageMetadataError.invalidLocalHeader
        }
        let fileNameLength = Int(try data.zipUInt16(at: 26))
        let extraLength = Int(try data.zipUInt16(at: 28))
        let length = 30 + fileNameLength + extraLength
        guard length <= data.count else {
            throw RemotePackageMetadataError.invalidLocalHeader
        }
        return length
    }

    private static func makeSingleEntryArchive(
        localEntry: Data,
        centralEntry: CentralEntry
    ) throws -> Data {
        var localEntry = localEntry
        guard try localEntry.zipUInt16(at: 8) == centralEntry.compressionMethod else {
            throw RemotePackageMetadataError.invalidLocalHeader
        }

        let sanitizedFlags = centralEntry.flags & ~UInt16(0x0008)
        try localEntry.setZipUInt16(sanitizedFlags, at: 6)
        try localEntry.setZipUInt32(centralEntry.checksum, at: 14)
        try localEntry.setZipUInt32(UInt32(centralEntry.compressedSize), at: 18)
        try localEntry.setZipUInt32(UInt32(centralEntry.uncompressedSize), at: 22)

        var centralRecord = centralEntry.record
        try centralRecord.setZipUInt16(sanitizedFlags, at: 8)
        try centralRecord.setZipUInt16(0, at: 34)
        try centralRecord.setZipUInt32(0, at: 42)

        var archive = Data()
        archive.append(localEntry)
        archive.append(centralRecord)
        archive.appendZipUInt32(0x0605_4B50)
        archive.appendZipUInt16(0)
        archive.appendZipUInt16(0)
        archive.appendZipUInt16(1)
        archive.appendZipUInt16(1)
        archive.appendZipUInt32(UInt32(centralRecord.count))
        archive.appendZipUInt32(UInt32(localEntry.count))
        archive.appendZipUInt16(0)
        return archive
    }
}

private struct CentralEntry: Sendable {
    let path: String
    let record: Data
    let flags: UInt16
    let compressionMethod: UInt16
    let checksum: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int64
    let modificationDate: Date?
}

private struct ByteRangeResult: Sendable {
    let data: Data
    let contentRange: String?
}

private final class ByteRangeLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumLength: Int
    private var continuation: CheckedContinuation<ByteRangeResult, Error>?
    private var session: URLSession?
    private var receivedData = Data()
    private var contentRange: String?
    private var acceptedResponse = false
    private var terminalError: Error?

    init(maximumLength: Int) {
        self.maximumLength = maximumLength
    }

    func load(_ request: URLRequest) async throws -> ByteRangeResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
            self.session = session
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 206
        else {
            terminalError = RemotePackageMetadataError.rangeRequestsUnsupported
            completionHandler(.cancel)
            return
        }

        guard response.expectedContentLength < 0
                || response.expectedContentLength <= Int64(maximumLength)
        else {
            terminalError = RemotePackageMetadataError.rangeResponseTooLarge
            completionHandler(.cancel)
            return
        }

        contentRange = response.value(forHTTPHeaderField: "Content-Range")
        acceptedResponse = true
        completionHandler(.allow)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard terminalError == nil else { return }
        guard receivedData.count <= maximumLength - data.count else {
            terminalError = RemotePackageMetadataError.rangeResponseTooLarge
            dataTask.cancel()
            return
        }
        receivedData.append(data)
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer {
            session?.invalidateAndCancel()
            session = nil
        }
        guard let continuation else { return }
        self.continuation = nil

        if let terminalError {
            continuation.resume(throwing: terminalError)
        } else if let error {
            continuation.resume(throwing: error)
        } else if acceptedResponse {
            continuation.resume(returning: ByteRangeResult(
                data: receivedData,
                contentRange: contentRange
            ))
        } else {
            continuation.resume(throwing: RemotePackageMetadataError.invalidRangeResponse)
        }
    }
}

private enum RemotePackageMetadataError: LocalizedError, Sendable {
    case rangeRequestsUnsupported
    case rangeResponseTooLarge
    case invalidRangeResponse
    case invalidContentRange
    case endOfCentralDirectoryMissing
    case invalidCentralDirectory
    case zip64Unsupported
    case encryptedEntry
    case infoPlistNotFound
    case infoPlistTooLarge
    case invalidLocalHeader
    case invalidInfoPlist
    case minimumOsVersionMissing

    var errorDescription: String? {
        switch self {
        case .rangeRequestsUnsupported:
            return "The package server does not support byte-range requests."
        case .rangeResponseTooLarge:
            return "The package server returned more data than requested."
        case .invalidRangeResponse:
            return "The package server returned an invalid byte range."
        case .invalidContentRange:
            return "The package size is unavailable."
        case .endOfCentralDirectoryMissing:
            return "The remote package has no ZIP end record."
        case .invalidCentralDirectory:
            return "The remote package has an invalid ZIP directory."
        case .zip64Unsupported:
            return "ZIP64 package inspection is not supported."
        case .encryptedEntry:
            return "The package Info.plist is encrypted."
        case .infoPlistNotFound:
            return "The package Info.plist was not found."
        case .infoPlistTooLarge:
            return "The package Info.plist is unexpectedly large."
        case .invalidLocalHeader:
            return "The package Info.plist has an invalid ZIP header."
        case .invalidInfoPlist:
            return "The package Info.plist could not be decoded."
        case .minimumOsVersionMissing:
            return "The package Info.plist has no minimum OS version."
        }
    }
}

private extension Data {
    func zipUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw RemotePackageMetadataError.invalidRangeResponse
        }
        return UInt16(self[index(startIndex, offsetBy: offset)])
            | UInt16(self[index(startIndex, offsetBy: offset + 1)]) << 8
    }

    func zipUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw RemotePackageMetadataError.invalidRangeResponse
        }
        return UInt32(self[index(startIndex, offsetBy: offset)])
            | UInt32(self[index(startIndex, offsetBy: offset + 1)]) << 8
            | UInt32(self[index(startIndex, offsetBy: offset + 2)]) << 16
            | UInt32(self[index(startIndex, offsetBy: offset + 3)]) << 24
    }

    mutating func setZipUInt16(_ value: UInt16, at offset: Int) throws {
        guard offset >= 0, offset + 2 <= count else {
            throw RemotePackageMetadataError.invalidRangeResponse
        }
        self[index(startIndex, offsetBy: offset)] = UInt8(truncatingIfNeeded: value)
        self[index(startIndex, offsetBy: offset + 1)] = UInt8(truncatingIfNeeded: value >> 8)
    }

    mutating func setZipUInt32(_ value: UInt32, at offset: Int) throws {
        guard offset >= 0, offset + 4 <= count else {
            throw RemotePackageMetadataError.invalidRangeResponse
        }
        self[index(startIndex, offsetBy: offset)] = UInt8(truncatingIfNeeded: value)
        self[index(startIndex, offsetBy: offset + 1)] = UInt8(truncatingIfNeeded: value >> 8)
        self[index(startIndex, offsetBy: offset + 2)] = UInt8(truncatingIfNeeded: value >> 16)
        self[index(startIndex, offsetBy: offset + 3)] = UInt8(truncatingIfNeeded: value >> 24)
    }

    mutating func appendZipUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendZipUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
