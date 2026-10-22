//
//  BackupEncryption.swift
//  TravelLog
//
//  The optional password envelope of a `.travellogbackup` file. The gzip
//  document is sealed in fixed-size segments with AES-GCM, so neither side
//  ever holds the whole file in memory, under a key stretched from the
//  password with PBKDF2-HMAC-SHA256. The password itself is never stored,
//  logged or written anywhere: only the key derived from it lives, in
//  memory, for one export or one import.
//
//  Layout (integers big-endian):
//
//      offset size
//           0    8  magic "TLBKENC\0"
//           8    1  envelope version (1)
//           9    1  key derivation (1: PBKDF2-HMAC-SHA256)
//          10    4  PBKDF2 iterations
//          14    4  segment size: plaintext bytes per segment
//          18   16  salt
//          34   12  base nonce
//          46   16  password check (HKDF of the stretched key)
//          62       segments: ciphertext + 16-byte GCM tag each
//
//  Segment `i` is sealed under the base nonce with `i` XORed into its last
//  eight bytes, authenticating the whole header and a final-segment flag.
//  Every segment but the last holds exactly `segment size` bytes; the last
//  holds the rest (possibly none) and carries the flag, so a file cut at a
//  segment boundary, reordered or spliced fails authentication.
//

import Foundation
import CryptoKit
import CommonCrypto
import Security
import zlib

nonisolated enum BackupEncryption {
    static let magic = Data("TLBKENC".utf8) + Data([0])
    static let version: UInt8 = 1
    static let pbkdf2SHA256: UInt8 = 1
    static let saltLength = 16
    static let nonceLength = 12
    static let checkLength = 16
    static let tagLength = 16
    static let headerLength = 8 + 1 + 1 + 4 + 4 + 16 + 12 + 16

    /// Plaintext bytes per segment this build writes.
    static let segmentSize = 1 << 20
    /// What a header may ask for. A tampered header can neither demand
    /// billions of iterations nor a huge segment buffer; everything this
    /// build writes is well inside both.
    static let acceptedIterations: ClosedRange<UInt32> = 100_000...10_000_000
    static let acceptedSegmentSizes: ClosedRange<UInt32> = 4_096...(4 << 20)
    /// The export calibrates to about 0.4 s of PBKDF2 on the device that
    /// writes, within these bounds (the floor is the current OWASP figure).
    static let exportIterations: ClosedRange<UInt32> = 600_000...5_000_000
    static let calibrationMilliseconds: UInt32 = 400
    /// The longest password taken, in UTF-8 bytes.
    static let maxPasswordBytes = 1_024

    /// True when `prefix` (a file's first bytes) opens an envelope.
    static func isEnvelope(_ prefix: Data) -> Bool {
        prefix.count >= magic.count && prefix.prefix(magic.count).elementsEqual(magic)
    }

    /// True when the file at `url` is a protected backup.
    static func isProtectedFile(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return isEnvelope(try handle.read(upToCount: magic.count) ?? Data())
    }

    // MARK: Header

    struct Header: Sendable, Equatable {
        var iterations: UInt32
        var segmentSize: UInt32
        var salt: Data
        var nonce: Data
        var check: Data

        /// The header's own bytes, authenticated by every segment.
        var bytes: Data {
            var data = BackupEncryption.magic
            data.append(BackupEncryption.version)
            data.append(BackupEncryption.pbkdf2SHA256)
            data.append(bigEndian: iterations)
            data.append(bigEndian: segmentSize)
            data.append(salt)
            data.append(nonce)
            data.append(check)
            return data
        }

        /// Reads and bounds-checks a header. A version or key derivation
        /// this build does not know is a newer file; anything else out of
        /// bounds is a damaged one.
        init(parsing data: Data) throws {
            let bytes = [UInt8](data.prefix(BackupEncryption.headerLength))
            guard bytes.count == BackupEncryption.headerLength,
                  BackupEncryption.isEnvelope(Data(bytes)) else {
                throw TripDataImportError.protectedBackupDamaged
            }
            guard bytes[8] == BackupEncryption.version, bytes[9] == BackupEncryption.pbkdf2SHA256 else {
                throw TripDataImportError.protectedBackupNewer
            }
            func word(at offset: Int) -> UInt32 {
                bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
            }
            iterations = word(at: 10)
            segmentSize = word(at: 14)
            guard BackupEncryption.acceptedIterations.contains(iterations),
                  BackupEncryption.acceptedSegmentSizes.contains(segmentSize) else {
                throw TripDataImportError.protectedBackupDamaged
            }
            salt = Data(bytes[18..<34])
            nonce = Data(bytes[34..<46])
            check = Data(bytes[46..<62])
        }

        init(iterations: UInt32, segmentSize: UInt32, salt: Data, nonce: Data, check: Data) {
            self.iterations = iterations
            self.segmentSize = segmentSize
            self.salt = salt
            self.nonce = nonce
            self.check = check
        }
    }

    // MARK: Keys

    struct Keys: Sendable {
        let encryption: SymmetricKey
        let check: Data
    }

    /// The password's bytes: NFC-normalized UTF-8, so the same password
    /// typed on another keyboard or device derives the same key.
    static func passwordBytes(_ password: String) -> [UInt8] {
        Array(password.precomposedStringWithCanonicalMapping.utf8)
    }

    /// PBKDF2-HMAC-SHA256 stretches the password; HKDF splits the result into
    /// the AES key and the password check, so the check reveals nothing about
    /// the key.
    static func deriveKeys(password: String, salt: Data, iterations: UInt32) throws -> Keys {
        let passwordBytes = passwordBytes(password)
        guard !passwordBytes.isEmpty, passwordBytes.count <= maxPasswordBytes else {
            throw TripDataImportError.wrongPassword
        }
        var stretched = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                    passwordBuffer.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress, saltBuffer.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                    &stretched, stretched.count)
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw BackupWriteError() }
        let master = SymmetricKey(data: stretched)
        stretched.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        let encryption = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master, salt: salt,
            info: Data("TravelLog backup v1 encryption".utf8), outputByteCount: 32)
        let check = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master, salt: salt,
            info: Data("TravelLog backup v1 password check".utf8), outputByteCount: checkLength)
        return Keys(encryption: encryption, check: check.withUnsafeBytes { Data($0) })
    }

    /// Iterations taking about `calibrationMilliseconds` on this device.
    static func calibratedIterations(for password: String) -> UInt32 {
        let rounds = CCCalibratePBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), max(1, passwordBytes(password).count), saltLength,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 32, calibrationMilliseconds)
        return min(max(rounds, exportIterations.lowerBound), exportIterations.upperBound)
    }

    /// Constant-time equality, so the check does not leak how much matched.
    static func matches(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func segmentNonce(base: Data, index: UInt64) throws -> AES.GCM.Nonce {
        var bytes = [UInt8](base)
        for offset in 0..<8 {
            bytes[bytes.count - 1 - offset] ^= UInt8(truncatingIfNeeded: index >> (8 * UInt64(offset)))
        }
        return try AES.GCM.Nonce(data: bytes)
    }

    static func authenticatedData(header: Data, isFinal: Bool) -> Data {
        header + Data([isFinal ? 1 : 0])
    }

    // MARK: Sealing (export)

    /// Everything one export needs to seal: the header and the key. Made
    /// once per export, before its gate unit, with a fresh salt and nonce.
    struct Sealing: Sendable {
        let header: Header
        let key: SymmetricKey

        /// Derives the key from `password`; `iterations` overrides the
        /// calibration and `segmentSize` the segment length (tests).
        init(
            password: String, iterations: UInt32? = nil,
            segmentSize: Int = BackupEncryption.segmentSize
        ) throws {
            let iterations = iterations ?? BackupEncryption.calibratedIterations(for: password)
            let salt = try BackupEncryption.randomBytes(BackupEncryption.saltLength)
            let nonce = try BackupEncryption.randomBytes(BackupEncryption.nonceLength)
            let keys = try BackupEncryption.deriveKeys(password: password, salt: salt, iterations: iterations)
            header = Header(
                iterations: iterations, segmentSize: UInt32(segmentSize),
                salt: salt, nonce: nonce, check: keys.check)
            key = keys.encryption
        }
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw BackupWriteError()
        }
        return Data(bytes)
    }

    // MARK: Opening (import)

    /// Reads the envelope at `url` with `password`, handing each decrypted
    /// segment (the gzip document, in order) to `body`. Throws
    /// `wrongPassword` before decrypting anything when the check differs,
    /// and `protectedBackupDamaged` for a cut-off, reordered or altered file.
    static func open(
        _ url: URL, password: String, _ body: (Data) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileLength = try handle.seekToEnd()
        guard fileLength <= UInt64(BackupLimits.maxDocumentBytes) else {
            throw TripDataImportError.tooLarge
        }
        try handle.seek(toOffset: 0)
        let header = try Header(parsing: try handle.read(upToCount: headerLength) ?? Data())
        let keys = try deriveKeys(password: password, salt: header.salt, iterations: header.iterations)
        guard matches(keys.check, header.check) else { throw TripDataImportError.wrongPassword }

        let headerBytes = header.bytes
        let record = UInt64(header.segmentSize) + UInt64(tagLength)
        guard fileLength >= UInt64(headerLength + tagLength) else {
            throw TripDataImportError.protectedBackupDamaged
        }
        let bodyLength = fileLength - UInt64(headerLength)
        let segments = (bodyLength + record - 1) / record
        let lastLength = bodyLength - (segments - 1) * record
        guard lastLength >= UInt64(tagLength) else { throw TripDataImportError.protectedBackupDamaged }
        for index in 0..<segments {
            let isFinal = index == segments - 1
            let length = Int(isFinal ? lastLength : record)
            let sealed = try readExactly(length, from: handle)
            let plaintext: Data
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: try segmentNonce(base: header.nonce, index: index),
                    ciphertext: sealed.prefix(length - tagLength),
                    tag: sealed.suffix(tagLength))
                plaintext = try AES.GCM.open(
                    box, using: keys.encryption,
                    authenticating: authenticatedData(header: headerBytes, isFinal: isFinal))
            } catch {
                throw TripDataImportError.protectedBackupDamaged
            }
            try body(plaintext)
        }
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw TripDataImportError.protectedBackupDamaged
            }
            data.append(chunk)
        }
        return data
    }
}

/// Streams the document through gzip, then seals it segment by segment into
/// a file: the protected export's sink. The plaintext never touches disk.
nonisolated final class BackupEncryptedFileSink: BackupSink {
    private let output: FileHandle
    private let sealing: BackupEncryption.Sealing
    private let headerBytes: Data
    private var stream = z_stream()
    private var deflating = false
    private var pending = Data()
    private var segmentIndex: UInt64 = 0
    private var closed = false
    private let scratch: UnsafeMutablePointer<Bytef>
    private static let scratchSize = 1 << 17

    init(path: String, sealing: BackupEncryption.Sealing) throws {
        guard let output = FileHandle(forWritingAtPath: path) else { throw BackupWriteError() }
        self.output = output
        self.sealing = sealing
        headerBytes = sealing.header.bytes
        scratch = .allocate(capacity: Self.scratchSize)
        // windowBits 15 + 16: a gzip wrapper, the same bytes `gzopen` writes.
        guard deflateInit2_(
            &stream, 6, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
            zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw BackupWriteError()
        }
        deflating = true
        try output.write(contentsOf: headerBytes)
    }

    func write(_ data: Data) throws {
        try deflate(data, flush: Z_NO_FLUSH)
        // A segment is sealed only once more bytes follow it, so the last
        // one is always the one `close()` marks final.
        let size = Int(sealing.header.segmentSize)
        while pending.count > size {
            try seal(pending.prefix(size), isFinal: false)
            pending.removeFirst(size)
        }
    }

    func close() throws {
        guard deflating else { return }
        try deflate(Data(), flush: Z_FINISH)
        deflateEnd(&stream)
        deflating = false
        let size = Int(sealing.header.segmentSize)
        while pending.count > size {
            try seal(pending.prefix(size), isFinal: false)
            pending.removeFirst(size)
        }
        try seal(pending, isFinal: true)
        pending.removeAll()
        try output.synchronize()
        closed = true
        try output.close()
    }

    private func deflate(_ data: Data, flush: Int32) throws {
        try data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(
                mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            defer { stream.next_in = nil }
            while true {
                stream.next_out = scratch
                stream.avail_out = uInt(Self.scratchSize)
                let status = zlib.deflate(&stream, flush)
                pending.append(scratch, count: Self.scratchSize - Int(stream.avail_out))
                switch status {
                case Z_STREAM_END:
                    return
                case Z_OK, Z_BUF_ERROR:
                    // More output waits while the buffer filled; otherwise
                    // the input is consumed (or, finishing, more is owed).
                    if stream.avail_out == 0 { continue }
                    if flush == Z_FINISH, status == Z_OK { continue }
                    guard flush != Z_FINISH else { throw BackupWriteError() }
                    return
                default:
                    throw BackupWriteError()
                }
            }
        }
    }

    private func seal(_ plaintext: Data, isFinal: Bool) throws {
        let box = try AES.GCM.seal(
            plaintext, using: sealing.key,
            nonce: try BackupEncryption.segmentNonce(base: sealing.header.nonce, index: segmentIndex),
            authenticating: BackupEncryption.authenticatedData(header: headerBytes, isFinal: isFinal))
        try output.write(contentsOf: box.ciphertext)
        try output.write(contentsOf: box.tag)
        segmentIndex += 1
    }

    deinit {
        if deflating { deflateEnd(&stream) }
        scratch.deallocate()
        if !closed { try? output.close() }
    }
}

private extension Data {
    nonisolated mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
