import CryptoKit
import Foundation

enum BighelpLinkCryptoError: Error, Equatable {
    case invalidBase64URL
}

enum BighelpLinkBase64URL {
    /// A-Z, a-z, 0-9, - and _, checked byte by byte: Foundation's CharacterSet rejected valid
    /// text on a real iPhone (the build 77 avatar colors), and here that stopped notification
    /// setup at the saved key (#254).
    private static func isAllowed(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
            || byte == 0x2D || byte == 0x5F
    }

    static func encode(_ value: Data) -> String {
        value.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) throws -> Data {
        guard
            !value.isEmpty,
            value.utf8.allSatisfy(isAllowed),
            value.utf8.count % 4 != 1
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
