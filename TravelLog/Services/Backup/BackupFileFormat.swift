//
//  BackupFileFormat.swift
//  TravelLog
//
//  The v15 backup container: one JSON document, gzip-compressed on export.
//  It is written member by member and read in place, so neither side ever
//  holds the ping history (hundreds of thousands of rows) in memory at once.
//

import Foundation
import zlib

// MARK: - Coding

/// The coding rules every v15 record shares. Dates are their exact
/// `timeIntervalSinceReferenceDate` (`.deferredToDate`), so every date
/// travels bit-exact; Doubles use the shortest round-trip form; a non-finite
/// value travels as a string instead of failing the export.
nonisolated enum BackupCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.dataEncodingStrategy = .base64
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        decoder.dataDecodingStrategy = .base64
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return decoder
    }
}

/// One array element decoded on its own: an element that does not decode is
/// nil, so a damaged entry is counted and dropped instead of failing the file.
nonisolated struct BackupLossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - Writing

/// Where a `BackupJSONWriter` sends its bytes.
nonisolated protocol BackupSink: AnyObject {
    func write(_ data: Data) throws
    func close() throws
}

/// Collects the document in memory (tests, small diagnostics).
nonisolated final class BackupDataSink: BackupSink {
    private(set) var data = Data()
    func write(_ data: Data) throws { self.data.append(data) }
    func close() throws {}
}

nonisolated struct BackupWriteError: Error {}

/// Streams the document through gzip into a file.
nonisolated final class BackupGzipFileSink: BackupSink {
    private var file: gzFile?

    init(path: String) throws {
        guard let file = gzopen(path, "wb6") else { throw BackupWriteError() }
        gzbuffer(file, 1 << 17)
        self.file = file
    }

    func write(_ data: Data) throws {
        guard let file else { throw BackupWriteError() }
        let written = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress, raw.count > 0 else { return 0 }
            return gzwrite(file, base, UInt32(raw.count))
        }
        guard Int(written) == data.count else { throw BackupWriteError() }
    }

    /// Flushes the compressor and writes the gzip trailer; a failure here
    /// means the file is incomplete.
    func close() throws {
        guard let file else { return }
        self.file = nil
        guard gzclose(file) == Z_OK else { throw BackupWriteError() }
    }

    deinit {
        if let file { gzclose(file) }
    }
}

/// Writes the root object member by member. Each record is encoded on its
/// own, so a streamed section costs one page of rows at a time.
nonisolated final class BackupJSONWriter {
    private let sink: any BackupSink
    private let encoder = BackupCoding.makeEncoder()
    private var buffer = Data()
    private var wroteMember = false
    private var wroteElement = false
    private var inArray = false

    init(sink: any BackupSink) {
        self.sink = sink
        buffer.append(UInt8(ascii: "{"))
    }

    /// One member holding one encoded value. Keys are plain ASCII names.
    func member(_ key: String, _ value: some Encodable) throws {
        precondition(!inArray)
        writeKey(key)
        buffer.append(try encoder.encode(value))
        try flushIfNeeded()
    }

    /// One member holding an array of records, encoded one by one.
    func array<Element: Encodable>(_ key: String, _ elements: some Sequence<Element>) throws {
        try beginArray(key)
        for element in elements { try append(element) }
        try endArray()
    }

    func beginArray(_ key: String) throws {
        precondition(!inArray)
        writeKey(key)
        buffer.append(UInt8(ascii: "["))
        inArray = true
        wroteElement = false
    }

    func append(_ element: some Encodable) throws {
        precondition(inArray)
        if wroteElement { buffer.append(UInt8(ascii: ",")) }
        wroteElement = true
        buffer.append(try encoder.encode(element))
        try flushIfNeeded()
    }

    func endArray() throws {
        precondition(inArray)
        buffer.append(UInt8(ascii: "]"))
        inArray = false
        try flushIfNeeded()
    }

    /// Closes the root object and the sink.
    func finish() throws {
        precondition(!inArray)
        buffer.append(UInt8(ascii: "}"))
        try sink.write(buffer)
        buffer.removeAll()
        try sink.close()
    }

    private func writeKey(_ key: String) {
        if wroteMember { buffer.append(UInt8(ascii: ",")) }
        wroteMember = true
        buffer.append(UInt8(ascii: "\""))
        buffer.append(contentsOf: Array(key.utf8))
        buffer.append(contentsOf: Array("\":".utf8))
    }

    private func flushIfNeeded() throws {
        guard buffer.count >= 1 << 16 else { return }
        try sink.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

// MARK: - Reading

/// Finds member values and array elements by their byte ranges without
/// building the document, so a large section is decoded a chunk at a time
/// from the memory-mapped file. It checks structure only; each range is
/// validated by the decoder that reads it.
nonisolated enum BackupJSONScanner {
    struct Malformed: Error {}

    /// The byte range (offsets from `data.startIndex`) of each member value
    /// of the root object. A repeated name keeps its last value.
    static func members(of data: Data) throws -> [String: Range<Int>] {
        try data.withUnsafeBytes { raw -> [String: Range<Int>] in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = skipWhitespace(bytes, from: 0)
            guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { throw Malformed() }
            index += 1
            var members: [String: Range<Int>] = [:]
            index = skipWhitespace(bytes, from: index)
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
            } else {
                while true {
                    index = skipWhitespace(bytes, from: index)
                    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Malformed() }
                    let keyEnd = try endOfString(bytes, from: index)
                    let key = try decodeKey(UnsafeBufferPointer(rebasing: bytes[index..<keyEnd]))
                    index = skipWhitespace(bytes, from: keyEnd)
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw Malformed() }
                    index = skipWhitespace(bytes, from: index + 1)
                    let valueEnd = try endOfValue(bytes, from: index)
                    members[key] = index..<valueEnd
                    index = skipWhitespace(bytes, from: valueEnd)
                    guard index < bytes.count else { throw Malformed() }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    guard bytes[index] == UInt8(ascii: "}") else { throw Malformed() }
                    index += 1
                    break
                }
            }
            guard skipWhitespace(bytes, from: index) == bytes.count else { throw Malformed() }
            return members
        }
    }

    /// Calls `body` with each run of up to `chunkSize` consecutive elements
    /// of the array at `range`, as a standalone JSON array, and the number of
    /// elements the run spans. An element longer than `maxElementBytes` is
    /// counted but left out of the array, so it is never decoded. A value
    /// that is not an array throws.
    static func forEachChunk(
        ofArrayAt range: Range<Int>, in data: Data, chunkSize: Int,
        maxElementBytes: Int = .max,
        _ body: (Data, Int) throws -> Void
    ) throws {
        precondition(chunkSize > 0)
        // Element ranges are collected under the buffer pointer, then copied
        // out and handed to `body` outside it, so the closure may throw or
        // decode freely.
        var elements: [Range<Int>] = []
        var cursor: Int?
        var finished = false
        while !finished {
            elements.removeAll(keepingCapacity: true)
            var spanned = 0
            finished = try data.withUnsafeBytes { raw -> Bool in
                let bytes = raw.bindMemory(to: UInt8.self)
                var index: Int
                if let cursor {
                    index = cursor
                } else {
                    index = skipWhitespace(bytes, from: range.lowerBound)
                    guard index < range.upperBound, bytes[index] == UInt8(ascii: "[") else { throw Malformed() }
                    index = skipWhitespace(bytes, from: index + 1)
                    if index < range.upperBound, bytes[index] == UInt8(ascii: "]") { return true }
                }
                while spanned < chunkSize {
                    index = skipWhitespace(bytes, from: index)
                    let start = index
                    let end = try endOfValue(bytes, from: start)
                    guard end <= range.upperBound else { throw Malformed() }
                    spanned += 1
                    if end - start <= maxElementBytes { elements.append(start..<end) }
                    index = skipWhitespace(bytes, from: end)
                    guard index < range.upperBound else { throw Malformed() }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    guard bytes[index] == UInt8(ascii: "]") else { throw Malformed() }
                    return true
                }
                cursor = index
                return false
            }
            guard spanned > 0 else { continue }
            var chunk = Data(capacity: elements.reduce(2) { $0 + $1.count + 1 })
            chunk.append(UInt8(ascii: "["))
            for (offset, element) in elements.enumerated() {
                if offset > 0 { chunk.append(UInt8(ascii: ",")) }
                chunk.append(data[(data.startIndex + element.lowerBound)..<(data.startIndex + element.upperBound)])
            }
            chunk.append(UInt8(ascii: "]"))
            try body(chunk, spanned)
        }
    }

    private static func skipWhitespace(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return index
            }
        }
        return index
    }

    /// The index just past the closing quote of the string opening at `start`.
    private static func endOfString(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) throws -> Int {
        var index = start + 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"): index += 2
            case UInt8(ascii: "\""): return index + 1
            default: index += 1
            }
        }
        throw Malformed()
    }

    /// The index just past the value starting at `start`.
    private static func endOfValue(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) throws -> Int {
        guard start < bytes.count else { throw Malformed() }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            return try endOfString(bytes, from: start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var index = start
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    index = try endOfString(bytes, from: index)
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return index + 1 }
                default:
                    break
                }
                index += 1
            }
            throw Malformed()
        default:
            var index = start
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
                     0x20, 0x09, 0x0A, 0x0D:
                    guard index > start else { throw Malformed() }
                    return index
                default:
                    index += 1
                }
            }
            guard index > start else { throw Malformed() }
            return index
        }
    }

    private static func decodeKey(_ quoted: UnsafeBufferPointer<UInt8>) throws -> String {
        let inner = UnsafeBufferPointer(rebasing: quoted[1..<(quoted.count - 1)])
        guard inner.contains(UInt8(ascii: "\\")) else {
            return String(decoding: inner, as: UTF8.self)
        }
        guard let key = try? JSONSerialization.jsonObject(
            with: Data(quoted), options: .fragmentsAllowed) as? String else {
            throw Malformed()
        }
        return key
    }
}

// MARK: - Files

/// A picked or opened backup is password-protected: its private copy waits
/// at `lockedCopy` until the password is entered (`BackupFile.unlockedContents`).
nonisolated struct ProtectedBackupFound: Error {
    let lockedCopy: URL
}

nonisolated enum BackupFile {
    /// Copies a picked backup into a private staging file, decompressing a
    /// gzip file (a plain JSON one is copied as it is, a protected one is
    /// decrypted with `password` first), and returns it memory-mapped. The
    /// staging file is unlinked at once: the mapping keeps its pages until
    /// the data is released, and a kill leaves nothing behind but a name
    /// `removeStagedExports` also clears. The copy stops at
    /// `BackupLimits.maxDocumentBytes`, and a gzip stream that expands past
    /// `maxCompressionRatio` stops as soon as it does: a decompression bomb
    /// fails fast with `tooLarge`, never filling the disk.
    static func stagedContents(of url: URL, password: String? = nil) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
        let staging = directory.appendingPathComponent(
            "\(TripDataExporter.restoreStagingPrefix)\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: staging) }
        // Readable while the app runs after the first unlock, so a locked
        // screen never pulls a mapped page out from under the import.
        guard FileManager.default.createFile(
            atPath: staging.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        else { throw TripDataImportError.notJSON }
        let output = try FileHandle(forWritingTo: staging)
        defer { try? output.close() }
        let writer = BackupDocumentWriter(output: output)

        let prefix: Data
        do {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            prefix = try input.read(upToCount: BackupEncryption.magic.count) ?? Data()
        } catch {
            throw TripDataImportError.notJSON
        }
        if BackupEncryption.isEnvelope(prefix) {
            guard let password else { throw TripDataImportError.wrongPassword }
            let inflater = try BackupInflater(writer: writer)
            try BackupEncryption.open(url, password: password) { try inflater.feed($0) }
            try inflater.finish()
        } else {
            let input: FileHandle
            do {
                input = try FileHandle(forReadingFrom: url)
            } catch {
                throw TripDataImportError.notJSON
            }
            defer { try? input.close() }
            if prefix.starts(with: [0x1f, 0x8b]) {
                let inflater = try BackupInflater(writer: writer)
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try inflater.feed(chunk)
                }
                try inflater.finish()
            } else {
                // The same document uncompressed.
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try writer.write(chunk)
                }
            }
        }
        try output.close()
        return try Data(contentsOf: staging, options: .alwaysMapped)
    }

    /// `stagedContents` of a picked or opened backup, inside its security
    /// scope and a coordinated read. The system's Inbox copy of an opened
    /// one is removed once read; the staging copy is all the import needs.
    /// A protected backup throws `ProtectedBackupFound` with a private copy
    /// of its sealed bytes, so the password can be asked for, and asked
    /// again, after the original is gone.
    static func openedContents(of url: URL) throws -> Data {
        defer { OpenedFile.removeInboxCopy(url) }
        return try OpenedFile.read(url) { readable in
            if (try? BackupEncryption.isProtectedFile(readable)) == true {
                throw ProtectedBackupFound(lockedCopy: try lockedCopy(of: readable))
            }
            return try stagedContents(of: readable)
        }
    }

    /// The document of a protected backup's private copy. A wrong password
    /// throws `wrongPassword` and leaves the copy for another try.
    static func unlockedContents(ofLockedCopy url: URL, password: String) throws -> Data {
        try stagedContents(of: url, password: password)
    }

    /// The sealed file copied as it is (it holds nothing readable without
    /// the password), within the document bound.
    static func lockedCopy(of url: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(TripDataExporter.restoreStagingPrefix)\(UUID().uuidString).\(TripDataExporter.lockedCopyExtension)")
        guard FileManager.default.createFile(
            atPath: copy.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        else { throw TripDataImportError.notJSON }
        do {
            let output = try FileHandle(forWritingTo: copy)
            defer { try? output.close() }
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            var copied: Int64 = 0
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                copied += Int64(chunk.count)
                guard copied <= BackupLimits.maxDocumentBytes else { throw TripDataImportError.tooLarge }
                try output.write(contentsOf: chunk)
            }
            try output.close()
        } catch {
            try? FileManager.default.removeItem(at: copy)
            throw error is TripDataImportError ? error : TripDataImportError.notJSON
        }
        return copy
    }
}

/// Writes the staged document, refusing to grow past the document bound.
nonisolated final class BackupDocumentWriter {
    private let output: FileHandle
    private(set) var written: Int64 = 0

    init(output: FileHandle) {
        self.output = output
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        guard !bytes.isEmpty else { return }
        written += Int64(bytes.count)
        guard written <= BackupLimits.maxDocumentBytes else { throw TripDataImportError.tooLarge }
        try output.write(contentsOf: bytes)
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { try write($0) }
    }
}

/// Streams gzip members into a `BackupDocumentWriter`, as `gzread` does:
/// members follow one another, and bytes after the last that open no member
/// are ignored. A stream cut off mid-member or damaged throws `notJSON`; one
/// that expands past `BackupLimits.maxCompressionRatio` throws `tooLarge`.
nonisolated final class BackupInflater {
    private let writer: BackupDocumentWriter
    private var stream = z_stream()
    private var consumed: Int64 = 0
    /// Between members: the next byte must open another, or the rest is ignored.
    private var betweenMembers = false
    private var ignoringRest = false
    private var sawMember = false
    private let scratch: UnsafeMutableRawPointer
    private static let scratchSize = 1 << 20

    init(writer: BackupDocumentWriter) throws {
        self.writer = writer
        scratch = .allocate(byteCount: Self.scratchSize, alignment: 16)
        guard inflateInit2_(&stream, 15 + 16, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            scratch.deallocate()
            throw TripDataImportError.notJSON
        }
    }

    func feed(_ data: Data) throws {
        guard !ignoringRest, !data.isEmpty else { return }
        try data.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Bytef.self)
            var offset = 0
            while offset < input.count {
                if betweenMembers {
                    guard input[offset] == 0x1f else {
                        ignoringRest = true
                        return
                    }
                    guard inflateReset(&stream) == Z_OK else { throw TripDataImportError.notJSON }
                    betweenMembers = false
                }
                stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress! + offset)
                stream.avail_in = uInt(input.count - offset)
                defer { stream.next_in = nil }
                while true {
                    stream.next_out = scratch.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(Self.scratchSize)
                    let before = Int(stream.avail_in)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    let used = before - Int(stream.avail_in)
                    offset += used
                    consumed += Int64(used)
                    let produced = Self.scratchSize - Int(stream.avail_out)
                    try writer.write(UnsafeRawBufferPointer(start: scratch, count: produced))
                    if writer.written > BackupLimits.ratioFloorBytes,
                       writer.written > consumed * BackupLimits.maxCompressionRatio {
                        throw TripDataImportError.tooLarge
                    }
                    switch status {
                    case Z_STREAM_END:
                        sawMember = true
                        betweenMembers = true
                    case Z_OK, Z_BUF_ERROR:
                        // A full buffer has more to give; otherwise the input
                        // is used up and the member continues in the next feed.
                        if stream.avail_out == 0 { continue }
                        guard used > 0 || produced > 0 || stream.avail_in == 0 else {
                            throw TripDataImportError.notJSON
                        }
                    default:
                        throw TripDataImportError.notJSON
                    }
                    break
                }
            }
        }
    }

    /// The input ended: it must have closed at least one whole member, and
    /// nothing after the last but ignored bytes.
    func finish() throws {
        guard sawMember, betweenMembers || ignoringRest else { throw TripDataImportError.notJSON }
    }

    deinit {
        inflateEnd(&stream)
        scratch.deallocate()
    }
}
