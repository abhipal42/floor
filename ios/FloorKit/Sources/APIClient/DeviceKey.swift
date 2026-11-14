import Foundation
import Security

/// The phone's identity for alerts: 32 random bytes, made on this phone the first time it registers
/// and kept in its own defaults. Floor has no accounts; this key is the only thing that lets a phone
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

    /// The key kept in `defaults`, made and saved on first use.
    public static func stored(in defaults: UserDefaults = .standard) -> DeviceKey {
        let storageKey = "floor.deviceKey.v1"
        if let saved = defaults.string(forKey: storageKey).flatMap(DeviceKey.init(value:)) { return saved }
        let fresh = generate()
        defaults.set(fresh.value, forKey: storageKey)
        return fresh
    }
}
