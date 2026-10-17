// The web proxy's per-device certificate authority (the app trusts its public
// certificate in the guest; the helper's WebProxy signs a leaf per HTTPS host
// with it).
//
// (Linux redesign; macOS used Security.framework.)
// RSA-2048 keys and SHA-1 signatures (iOS 3's TLS 1.0 stack needs SHA-1) come
// from swift-crypto's _CryptoExtras; certificates are encoded here in the same
// hand-rolled DER as before, byte-compatible with CAs the macOS build wrote.
//
// Files beside the routing CONFIG, as the old itwebproxy --init-ca wrote them,
// so a device keeps the CA its guest already trusts: CONFIG.ca.pem (PKCS#8
// private key then the certificate, mode 0600, owner only), CONFIG.ca.der
// (the public certificate), CONFIG.ca.lock (creation lock).
//
// The old build wrapped the leaf in a SecIdentity via the private
// SecIdentityCreate SPI (the public PKCS#12 route needed macOS 15). There is
// no keychain here; instead `identity(for:key:)` returns the DER certificate
// plus the private key, which is what a TLS stack needs: the future
// TLS-terminating proxy feeds `certificateDER` as the server certificate and
// `privateKey` (PKCS#8 via `pkcs8DERRepresentation`, or PEM) as the server key.

#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif
import Crypto
import _CryptoExtras
import Foundation

/// What the TLS-terminating proxy needs to serve one host: the leaf
/// certificate (DER) and its private key.
public struct WebProxyLeafIdentity: Sendable {
    public var certificateDER: Data
    public var privateKey: _RSA.Signing.PrivateKey
    public init(certificateDER: Data, privateKey: _RSA.Signing.PrivateKey) {
        self.certificateDER = certificateDER
        self.privateKey = privateKey
    }
}

nonisolated public struct WebProxyCA: @unchecked Sendable {
    public let key: _RSA.Signing.PrivateKey
    /// The CA certificate, DER-encoded (what SecCertificateCopyData produced before).
    public let certificateDER: Data
    /// The certificate's subject, as encoded: every leaf's issuer.
    public let subject: Data

    enum Failure: Error {
        case unreadable(String)
        case keyGeneration, signing
    }

    /// Loads CONFIG.ca.pem, creating it on first use; (re)writes CONFIG.ca.der.
    public static func prepare(config: URL) throws -> WebProxyCA {
        #if os(Windows)
        // No flock(2) or O_NOFOLLOW on Windows: an exclusive LockFileEx on the
        // CRT descriptor's HANDLE (see StorageLease), refusing reparse points
        // (symlinks, junctions) as O_NOFOLLOW does on POSIX.
        // DIAG: temporary crash diagnostics (stderr, unbuffered).
        func diag(_ s: String) { fputs("webproxyca-diag: \(s)\n", stderr) }
        diag("enter prepare")
        let lockPath = config.path + ".ca.lock"
        diag("lockPath=\(lockPath)")
        if isReparsePoint(lockPath) { throw Failure.unreadable("lock") }
        diag("isReparsePoint ok")
        let lock = open(lockPath, O_RDWR | O_CREAT | _O_NOINHERIT, 0o600)
        diag("open -> \(lock)")
        guard lock >= 0, lockExclusive(lock) else {
            if lock >= 0 { _ = WinSDK.close(lock) }
            throw Failure.unreadable("lock")
        }
        diag("lockExclusive ok")
        defer {
            unlock(lock)
            _ = WinSDK.close(lock)
        }
        #else
        let lock = open(config.path + ".ca.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX) == 0 else { throw Failure.unreadable("lock") }
        defer { close(lock) }
        #endif
        let pem = URL(fileURLWithPath: config.path + ".ca.pem")
        let ca: WebProxyCA
        if FileManager.default.fileExists(atPath: pem.path) {
            ca = try load(config: config)
        } else {
            #if os(Windows)
            diag("generating key")
            #endif
            let key = try newKey()
            #if os(Windows)
            diag("key ok")
            #endif
            let name = DER.name("Light Touch Device Proxy")
            let der = try certificate(key: key, issuerKey: key, issuer: name, subject: name, days: 3650, host: nil)
            #if os(Windows)
            diag("certificate ok")
            #endif
            let text =
                "-----BEGIN PRIVATE KEY-----\n"
                + key.pkcs8DERRepresentation.base64EncodedString(options: .lineLength64Characters)
                + "\n-----END PRIVATE KEY-----\n-----BEGIN CERTIFICATE-----\n"
                + der.base64EncodedString(options: .lineLength64Characters)
                + "\n-----END CERTIFICATE-----\n"
            try save(Data(text.utf8), to: pem, mode: 0o600)
            #if os(Windows)
            diag("save pem ok")
            #endif
            ca = try load(config: config)
            #if os(Windows)
            diag("load ok")
            #endif
        }
        try save(ca.certificateDER, to: URL(fileURLWithPath: config.path + ".ca.der"), mode: 0o644)
        return ca
    }

    /// CONFIG.ca.pem, refused unless it is a regular file of this user's that nobody else can read.
    public static func load(config: URL) throws -> WebProxyCA {
        let path = config.path + ".ca.pem"
        #if os(Windows)
        fputs("webproxyca-diag: load enter\n", stderr)
        // No POSIX ownership/mode bits on Windows: refuse reparse points and
        // require a regular file. A file the app creates in its own state
        // directory is owner-only by default ACL, which is the property the
        // POSIX checks below are after.
        guard !isReparsePoint(path), isRegularFile(path) else { throw Failure.unreadable(path) }
        fputs("webproxyca-diag: load checks ok\n", stderr)
        let fd = _open(path, O_RDONLY | _O_NOINHERIT)
        fputs("webproxyca-diag: load open -> \(fd)\n", stderr)
        guard fd >= 0 else { throw Failure.unreadable(path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        fputs("webproxyca-diag: load FileHandle ok\n", stderr)
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8),
            let pkcs8 = pemBlock(text, "PRIVATE KEY"),
            let certDER = pemBlock(text, "CERTIFICATE"),
            let key = try? _RSA.Signing.PrivateKey(derRepresentation: pkcs8),
            let tbs = DER.children(certDER)?.first?.whole,
            let fields = DER.children(tbs), fields.count > 6,
            // The certificate really is this key's: its subjectPublicKeyInfo
            // matches the key (what the SecKey external-representation
            // comparison did before).
            fields[6].whole == key.publicKey.derRepresentation
        else { throw Failure.unreadable(path) }
        #else
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.unreadable(path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0, st.st_mode & S_IFMT == S_IFREG,
            let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8),
            let pkcs8 = pemBlock(text, "PRIVATE KEY"),
            let certDER = pemBlock(text, "CERTIFICATE"),
            let key = try? _RSA.Signing.PrivateKey(derRepresentation: pkcs8),
            let tbs = DER.children(certDER)?.first?.whole,
            let fields = DER.children(tbs), fields.count > 6,
            // The certificate really is this key's: its subjectPublicKeyInfo
            // matches the key (what the SecKey external-representation
            // comparison did before).
            fields[6].whole == key.publicKey.derRepresentation
        else { throw Failure.unreadable(path) }
        #endif
        return WebProxyCA(key: key, certificateDER: certDER, subject: fields[5].whole)
    }

    /// A TLS server identity for `host` (a DNS name or an IP literal), valid for a week, under this CA:
    /// the DER certificate plus its key, for the proxy's TLS stack.
    public func identity(for host: String, key leafKey: _RSA.Signing.PrivateKey) throws -> WebProxyLeafIdentity {
        #if os(Windows)
        fputs("webproxyca-diag: identity for \(host)\n", stderr)
        #endif
        let der = try Self.certificate(
            key: leafKey,
            issuerKey: key,
            issuer: subject,
            subject: DER.name(host.utf8.count <= 64 ? host : "Light Touch Device Proxy"),
            days: 7,
            host: host
        )
        return WebProxyLeafIdentity(certificateDER: der, privateKey: leafKey)
    }

    public static func newKey() throws -> _RSA.Signing.PrivateKey {
        do {
            return try _RSA.Signing.PrivateKey(keySize: .bits2048)
        } catch {
            throw Failure.keyGeneration
        }
    }

    // MARK: - Certificates

    private static func certificate(
        key: _RSA.Signing.PrivateKey,
        issuerKey: _RSA.Signing.PrivateKey,
        issuer: Data,
        subject: Data,
        days: Int,
        host: String?
    ) throws -> Data {
        var serial = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        serial[0] &= 0x7f
        let now = Date()
        // Valid from 2000, not from today: a dated device (a developer beta pinned inside its release window,
        // recipe rtc_epoch) checks notBefore against its own 2012-2013 clock.
        let validFrom = Date(timeIntervalSince1970: 946_684_800)
        let rsa = DER.seq(DER.oid("1.2.840.113549.1.1.1"), DER.null)
        let spki = DER.seq(rsa, DER.bitString(try rsaPublicKeyBytes(key.publicKey.derRepresentation)))
        var extensions: [Data]
        if let host {
            #if os(Windows)
            fputs("webproxyca-diag: certificate host branch for \(host)\n", stderr)
            #endif
            let ip = [AF_INET, AF_INET6].lazy.compactMap { family -> Data? in
                var bytes = [UInt8](repeating: 0, count: 16)
                return inet_pton(family, host, &bytes) == 1 ? Data(bytes.prefix(family == AF_INET ? 4 : 16)) : nil
            }.first
            #if os(Windows)
            fputs("webproxyca-diag: inet_pton done\n", stderr)
            #endif
            guard host.utf8.count <= 253, !host.isEmpty,
                host.unicodeScalars.allSatisfy({
                    $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-:".unicodeScalars.contains($0))
                })
            else { throw Failure.signing }
            extensions = [
                DER.extension("2.5.29.19", critical: true, DER.seq()),  // CA:FALSE
                // digitalSignature, keyEncipherment
                DER.extension("2.5.29.15", critical: true, Data([0x03, 0x02, 0x05, 0xa0])),
                DER.extension(
                    "2.5.29.17",
                    critical: false,
                    DER.seq(ip.map { DER.tlv(0x87, $0) } ?? DER.tlv(0x82, Data(host.utf8)))
                ),
                DER.extension("2.5.29.37", critical: false, DER.seq(DER.oid("1.3.6.1.5.5.7.3.1"))),
            ]  // serverAuth
        } else {
            extensions = [
                DER.extension(
                    "2.5.29.19",
                    critical: true,
                    DER.seq(DER.tlv(0x01, Data([0xff])), DER.integer(Data([0])))
                ),  // CA, pathlen 0
                DER.extension("2.5.29.15", critical: true, Data([0x03, 0x02, 0x01, 0x06])),
            ]  // keyCertSign, cRLSign
        }
        let sha1RSA = DER.seq(DER.oid("1.2.840.113549.1.1.5"), DER.null)
        let tbs = DER.seq(
            DER.tlv(0xa0, DER.integer(Data([2]))),
            DER.integer(serial),
            sha1RSA,
            issuer,
            DER.seq(DER.time(validFrom), DER.time(now + Double(days) * 86400)),
            subject,
            spki,
            DER.tlv(0xa3, DER.seq(extensions.reduce(Data(), +)))
        )
        // iOS 3's TLS 1.0 stack: RSA PKCS#1 v1.5 over SHA-1.
        let signature: _RSA.Signing.RSASignature
        do {
            signature = try issuerKey.signature(for: Insecure.SHA1.hash(data: tbs), padding: .insecurePKCS1v1_5)
        } catch {
            throw Failure.signing
        }
        return DER.seq(tbs, sha1RSA, DER.bitString(Data(signature.rawRepresentation)))
    }

    /// The PKCS#1 RSAPublicKey bytes inside a SubjectPublicKeyInfo (what the old
    /// SecKeyCopyExternalRepresentation returned for the BIT STRING).
    private static func rsaPublicKeyBytes(_ spki: Data) throws -> Data {
        guard let parts = DER.children(spki), parts.count == 2,
            parts[1].content.first == 0
        else { throw Failure.keyGeneration }
        return parts[1].content.dropFirst()
    }

    private static func pemBlock(_ text: String, _ label: String) -> Data? {        guard let start = text.range(of: "-----BEGIN \(label)-----"),
            let end = text.range(of: "-----END \(label)-----", range: start.upperBound..<text.endIndex)
        else { return nil }
        return Data(base64Encoded: String(text[start.upperBound..<end.lowerBound]), options: .ignoreUnknownCharacters)
    }

    private static func save(_ data: Data, to url: URL, mode: Int32) throws {
        #if os(Windows)
        // Uniqueness via UUID (no getpid on Windows); no O_NOFOLLOW: the temp
        // name is random per call, and the parent directory is the app's own.
        // _O_BINARY: the UCRT defaults to text mode (CRLF translation), which
        // corrupts both the PEM text and the DER binary.
        let temporary = url.path + ".\(Foundation.UUID().uuidString).tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | _O_NOINHERIT | _O_BINARY, mode)
        #else
        let temporary = url.path + ".\(getpid()).tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode_t(mode))
        #endif
        guard fd >= 0 else { throw Failure.unreadable(temporary) }
        let ok = data.withUnsafeBytes {
            guard let base = $0.baseAddress else { return data.isEmpty }
            #if os(Windows)
            // UCRT write takes a UInt32 count.
            return $0.count <= Int(Int32.max) && write(fd, base, UInt32($0.count)) == Int32($0.count)
            #else
            return write(fd, base, $0.count) == $0.count
            #endif
        }
        guard close(fd) == 0, ok, rename(temporary, url.path) == 0 else {
            unlink(temporary)
            throw Failure.unreadable(url.path)
        }
    }

    #if os(Windows)
    /// No flock(2) on Windows: an exclusive byte-range lock via LockFileEx on
    /// the CRT descriptor's HANDLE (same pattern as StorageLease).
    private static func lockExclusive(_ fd: Int32) -> Bool {
        guard let handle = lockHandle(fd) else { return false }
        var overlapped = OVERLAPPED()
        // LockFileEx returns BOOL (Swift Bool); the flag #defines import as
        // Int32 and need a DWORD conversion for the DWORD parameters.
        return LockFileEx(handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK), 0, 1, 0, &overlapped)
    }

    private static func unlock(_ fd: Int32) {
        guard let handle = lockHandle(fd) else { return }
        var overlapped = OVERLAPPED()
        UnlockFileEx(handle, 0, 1, 0, &overlapped)
    }

    private static func lockHandle(_ fd: Int32) -> UnsafeMutableRawPointer? {
        let raw = _get_osfhandle(fd)
        guard raw != -1 else { return nil }
        return UnsafeMutableRawPointer(bitPattern: raw)
    }

    /// The O_NOFOLLOW equivalent: refuse to open through a reparse point
    /// (symlink, junction).
    private static func isReparsePoint(_ path: String) -> Bool {
        var wide = Array(path.utf16)
        wide.append(0)
        return wide.withUnsafeBufferPointer { buffer in
            guard let wpath = buffer.baseAddress else { return false }
            let attrs = GetFileAttributesW(wpath)
            return attrs != INVALID_FILE_ATTRIBUTES && attrs & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0
        }
    }

    /// A regular file (not a directory, reparse point, or missing).
    private static func isRegularFile(_ path: String) -> Bool {
        var wide = Array(path.utf16)
        wide.append(0)
        return wide.withUnsafeBufferPointer { buffer in
            guard let wpath = buffer.baseAddress else { return false }
            let attrs = GetFileAttributesW(wpath)
            return attrs != INVALID_FILE_ATTRIBUTES
                && attrs & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
                && attrs & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
        }
    }
    #endif
}

/// Just enough DER for the certificates above and for reading them back.
public nonisolated enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var length = Data()
        if content.count < 0x80 {
            length.append(UInt8(content.count))
        } else {
            var n = content.count
            var bytes: [UInt8] = []
            while n > 0 {
                bytes.insert(UInt8(n & 0xff), at: 0)
                n >>= 8
            }
            length = Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        return Data([tag]) + length + content
    }
    static func seq(_ parts: Data...) -> Data { tlv(0x30, parts.reduce(Data(), +)) }
    static let null = Data([0x05, 0x00])
    static func integer(_ bytes: Data) -> Data {
        var value = bytes.drop { $0 == 0 }
        if value.first.map({ $0 & 0x80 != 0 }) ?? true { value.insert(0, at: value.startIndex) }
        return tlv(0x02, Data(value))
    }
    static func bitString(_ bytes: Data) -> Data { tlv(0x03, Data([0]) + bytes) }
    static func oid(_ dotted: String) -> Data {
        let arcs = dotted.split(separator: ".").map { arc in
            guard let value = UInt(arc) else { preconditionFailure("OIDs here are constants: \(dotted)") }
            return value
        }
        var out = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for var arc in arcs.dropFirst(2) {
            var chunk = [UInt8(arc & 0x7f)]
            arc >>= 7
            while arc > 0 {
                chunk.insert(UInt8(arc & 0x7f) | 0x80, at: 0)
                arc >>= 7
            }
            out.append(contentsOf: chunk)
        }
        return tlv(0x06, out)
    }
    /// CN=`commonName`, a UTF8String.
    static func name(_ commonName: String) -> Data {
        seq(tlv(0x31, seq(oid("2.5.4.3"), tlv(0x0c, Data(commonName.utf8)))))
    }
    static func `extension`(_ id: String, critical: Bool, _ value: Data) -> Data {
        seq(oid(id), critical ? tlv(0x01, Data([0xff])) : Data(), tlv(0x04, value))
    }
    /// UTCTime through 2049, GeneralizedTime after (RFC 5280 4.1.2.5).
    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy"
        let generalized = Int(formatter.string(from: date)) ?? 0 >= 2050
        formatter.dateFormat = generalized ? "yyyyMMddHHmmss'Z'" : "yyMMddHHmmss'Z'"
        return tlv(generalized ? 0x18 : 0x17, Data(formatter.string(from: date).utf8))
    }
    /// PrivateKeyInfo around a PKCS#1 RSAPrivateKey (what OpenSSL's PEM_write_PrivateKey wrote).
    static func pkcs8(_ rsa: Data) -> Data {
        seq(integer(Data([0])), seq(oid("1.2.840.113549.1.1.1"), null), tlv(0x04, rsa))
    }
    /// The elements inside one constructed element: each one whole and its content.
    public static func children(_ data: Data) -> [(whole: Data, content: Data)]? {
        let bytes = [UInt8](data)
        func element(at i: Int) -> (end: Int, contentStart: Int)? {
            guard i + 1 < bytes.count else { return nil }
            var length = Int(bytes[i + 1])
            var start = i + 2
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count > 0, count <= 4, start + count <= bytes.count else { return nil }
                length = bytes[start..<start + count].reduce(0) { $0 << 8 | Int($1) }
                start += count
            }
            guard start + length <= bytes.count else { return nil }
            return (start + length, start)
        }
        guard let outer = element(at: 0) else { return nil }
        var result: [(Data, Data)] = []
        var i = outer.contentStart
        while i < outer.end {
            guard let inner = element(at: i), inner.end <= outer.end else { return nil }
            result.append((Data(bytes[i..<inner.end]), Data(bytes[inner.contentStart..<inner.end])))
            i = inner.end
        }
        return result
    }
}
