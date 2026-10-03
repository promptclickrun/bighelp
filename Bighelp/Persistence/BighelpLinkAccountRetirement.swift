import Foundation
import Security

/// The bighelp account and Link pairing are gone. Phones that once signed in
/// still hold the account's keys and paired-host choices; remove them once.
enum BighelpLinkAccountRetirement {
    static let defaultsKey = "loopdy.migrations.link-account-retirement-v1"

    private static let keychainServices = ["app.loopdy.mobile.link", "app.loopdy.mobile.direct.v1"]
    private static let exactDefaultsKeys = [
        "loopdy.link.selected-host-id",
        "loopdy.link.primary-host-id",
        "loopdy.link.push-registration-revision",
        "loopdy.link.workspace-admission.v1",
    ]
    private static let defaultsKeyPrefixes = ["loopdy.link.socket.v1."]

    static func run(
        defaults: UserDefaults = .standard,
        deleteKeychainService: (String) -> OSStatus = { service in
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }
    ) {
        guard !defaults.bool(forKey: defaultsKey) else { return }
        for key in defaults.dictionaryRepresentation().keys
        where exactDefaultsKeys.contains(key) || defaultsKeyPrefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
        for service in keychainServices {
            let status = deleteKeychainService(service)
            // A locked phone keeps them; try again next launch.
            guard status == errSecSuccess || status == errSecItemNotFound else { return }
        }
        defaults.set(true, forKey: defaultsKey)
    }
}
