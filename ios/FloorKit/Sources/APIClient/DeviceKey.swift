import Foundation
import Security

/// The phone's identity for alerts: 32 random bytes, made on this phone the first time it registers
/// and kept in its Keychain (``stored(in:legacy:)``). Floor has no accounts; this key is the only thing that lets a phone
/// change its own registration, and the API keeps only its SHA-256.
///
/// It is sent as `Authorization: Device <key>` and never put in a URL, a log line, or the App Group
/// (the widget has no use for it). Deleting the app forgets it; the next install registers afresh.
public struct DeviceKey: Sendable, Hashable {
    /// base64url without padding: 43 characters.
    public let value: String

    public init?(value: String) {
        guard value.count == 43, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        self.value = value
    }

    /// A fresh key from the system's secure random generator.
    public static func generate() -> DeviceKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Never reached on a working system; SystemRandomNumberGenerator is also cryptographic.
            var rng = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        }
        return DeviceKey(value: base64url(Data(bytes)))!
    }

    public var authorization: String { "Device \(value)" }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static let legacyKey = "floor.deviceKey.v1"

    /// The phone's key: from the Keychain (`AfterFirstUnlockThisDeviceOnly`, so a backup restored
    /// to another phone does not carry it and two phones never share a registration); else moved
    /// there from the app's defaults, where v0.2.30's first draft kept it; else made and saved. If
    /// the Keychain refuses, the defaults keep it, so registration still works.
    public static func stored(in keychain: any DeviceKeyStore = KeychainDeviceKeyStore(), legacy defaults: UserDefaults = .standard) -> DeviceKey {
        if let saved = keychain.read().flatMap(DeviceKey.init(value:)) {
            defaults.removeObject(forKey: legacyKey)
            return saved
        }
        let key = defaults.string(forKey: legacyKey).flatMap(DeviceKey.init(value:)) ?? generate()
        if keychain.write(key.value) {
            defaults.removeObject(forKey: legacyKey)
        } else {
            defaults.set(key.value, forKey: legacyKey)
        }
        return key
    }
}

/// Where the device key lives.
public protocol DeviceKeyStore: Sendable {
    func read() -> String?
    /// True once saved.
    func write(_ value: String) -> Bool
}

/// A generic password in the app's Keychain, readable after the first unlock (pushes register in
/// the background) and never migrated to another device.
public struct KeychainDeviceKeyStore: DeviceKeyStore {
    let service: String

    public init(service: String = "floor.deviceKey") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "device"]
    }

    public func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}
