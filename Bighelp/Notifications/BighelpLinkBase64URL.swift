import CryptoKit
import Foundation

enum BighelpLinkCryptoError: Error, Equatable {
    case invalidBase64URL
}

enum BighelpLinkBase64URL {
    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    static func encode(_ value: Data) -> String {
        value.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) throws -> Data {
        guard
            !value.isEmpty,
            value.unicodeScalars.allSatisfy(allowed.contains),
            value.count % 4 != 1
        else {
            throw BighelpLinkCryptoError.invalidBase64URL
        }
        let normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded) else {
            throw BighelpLinkCryptoError.invalidBase64URL
        }
        return decoded
    }
}

extension P256.Signing.PublicKey {
    /// The key as a base64url SubjectPublicKeyInfo, the form the notification
    /// service registers.
    var spkiBase64URL: String {
        // id-ecPublicKey + prime256v1 SubjectPublicKeyInfo prefix, followed by
        // CryptoKit's uncompressed SEC1/X9.63 public point.
        let prefix = Data([
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86,
            0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
            0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
            0x42, 0x00,
        ])
        return BighelpLinkBase64URL.encode(prefix + x963Representation)
    }
}
