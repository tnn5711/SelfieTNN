import CryptoKit
import Foundation
import Security
import SwiftUI

/// Keeps a salted SHA-256 hash of the 4-digit passcode in the Keychain (never the passcode itself).
enum PasscodeStore {
    static let defaultPasscode = "0612"
    private static let service = "com.apptnn.SelfieTNN"
    private static let account = "passcode"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func ensureDefault() {
        if load() == nil { set(defaultPasscode) }
    }

    static func set(_ passcode: String) {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let blob = salt + hash(passcode, salt: salt)
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = blob
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func verify(_ passcode: String) -> Bool {
        guard let blob = load(), blob.count == 48 else { return false }
        let salt = blob.prefix(16)
        let stored = blob.suffix(32)
        // Constant-time comparison.
        return zip(hash(passcode, salt: Data(salt)), stored).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static var isDefault: Bool { verify(defaultPasscode) }

    private static func hash(_ passcode: String, salt: Data) -> Data {
        Data(SHA256.hash(data: salt + Data(passcode.utf8)))
    }

    private static func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}

/// App-wide lock state. Locks at launch and whenever the app goes to the background.
final class AppLock: ObservableObject {
    static let shared = AppLock()

    @Published private(set) var isLocked = true
    @Published private(set) var isCovered = false   // true while the app is not active (hides app-switcher snapshot)
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let failedKey = "lock.failedAttempts"
    private let untilKey = "lock.lockoutUntil"
    private let maxFreeAttempts = 5

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: isCovered = false
        case .inactive: isCovered = true
        case .background:
            isCovered = true
            isLocked = true
        @unknown default: break
        }
    }

    func remainingLockout(at date: Date = Date()) -> Int {
        let until = defaults.double(forKey: untilKey)
        return max(0, Int(ceil(until - date.timeIntervalSince1970)))
    }

    /// Verifies a passcode with attempt throttling; used for unlocking and for changing the passcode.
    func check(_ passcode: String) -> Bool {
        guard remainingLockout() == 0 else { return false }
        if PasscodeStore.verify(passcode) {
            defaults.set(0, forKey: failedKey)
            return true
        }
        let failed = defaults.integer(forKey: failedKey) + 1
        defaults.set(failed, forKey: failedKey)
        if failed >= maxFreeAttempts {
            let seconds = min(30 * (failed - maxFreeAttempts + 1), 600)
            defaults.set(Date().timeIntervalSince1970 + Double(seconds), forKey: untilKey)
        }
        return false
    }

    func attemptUnlock(_ passcode: String) {
        if check(passcode) {
            errorMessage = nil
            isLocked = false
        } else {
            errorMessage = remainingLockout() > 0 ? nil : "Incorrect passcode"
        }
    }
}
