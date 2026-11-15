import CommonCrypto
import CryptoKit
import Foundation

/// Password protection for notebooks: AES-256-GCM (authenticated, so tampering is detected) with a
/// key derived by PBKDF2-HMAC-SHA256. Layout: salt(16) ‖ nonce(12) ‖ ciphertext ‖ tag(16).
/// The password itself is never stored anywhere.
enum NotebookCrypto {
    static let iterations: UInt32 = 200_000
    static let saltSize = 16

    enum CryptoError: LocalizedError, Equatable {
        case wrongPassword
        case corrupt
        case keyDerivation

        var errorDescription: String? {
            switch self {
            case .wrongPassword: return "That password isn’t right."
            case .corrupt: return "The locked notebook is damaged."
            case .keyDerivation: return "The password couldn’t be processed."
            }
        }
    }

    // Deriving a key is deliberately slow (~0.1 s). Saves reuse the notebook's salt and the key derived
    // for it, so autosave stays instant; each save still uses a fresh random nonce.
    private static var cache: [String: (salt: Data, key: SymmetricKey)] = [:]
    private static let lock = NSLock()

    static func deriveKey(_ password: String, salt: Data) throws -> SymmetricKey {
        let pw = Array(password.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                 s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &out, out.count)
        }
        guard status == kCCSuccess else { throw CryptoError.keyDerivation }
        return SymmetricKey(data: out)
    }

    private static func cacheKey(_ password: String) -> String {
        SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func seal(_ data: Data, password: String) throws -> Data {
        let ck = cacheKey(password)
        lock.lock()
        let cached = cache[ck]
        lock.unlock()
        let salt: Data, key: SymmetricKey
        if let cached {
            (salt, key) = cached
        } else {
            var bytes = [UInt8](repeating: 0, count: saltSize)
            guard SecRandomCopyBytes(kSecRandomDefault, saltSize, &bytes) == errSecSuccess else { throw CryptoError.keyDerivation }
            salt = Data(bytes)
            key = try deriveKey(password, salt: salt)
            lock.lock(); cache[ck] = (salt, key); lock.unlock()
        }
        let box = try AES.GCM.seal(data, using: key)
        guard let combined = box.combined else { throw CryptoError.corrupt }
        return salt + combined
    }

    static func open(_ data: Data, password: String) throws -> Data {
        guard data.count > saltSize + 12 + 16 else { throw CryptoError.corrupt }
        let salt = Data(data.prefix(saltSize))
        let ck = cacheKey(password)
        lock.lock()
        let cached = cache[ck]
        lock.unlock()
        let key: SymmetricKey
        if let cached, cached.salt == salt { key = cached.key } else { key = try deriveKey(password, salt: salt) }
        guard let box = try? AES.GCM.SealedBox(combined: data.suffix(from: data.startIndex + saltSize)) else { throw CryptoError.corrupt }
        // GCM authentication fails for a wrong key and for tampered data alike; with an intact
        // checksum outside the encryption, a failure here almost always means the wrong password.
        guard let plain = try? AES.GCM.open(box, using: key) else { throw CryptoError.wrongPassword }
        lock.lock(); cache[ck] = (salt, key); lock.unlock() // later saves reuse this salt + key
        return plain
    }

    /// Forgets derived keys (e.g. after removing a password).
    static func forget(_ password: String) {
        lock.lock(); cache[cacheKey(password)] = nil; lock.unlock()
    }
}
