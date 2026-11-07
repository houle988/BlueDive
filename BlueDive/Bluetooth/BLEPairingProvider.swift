import Foundation
import Security
import Observation
import DiveComputerKit

/// The Bluetooth access codes Pelagic dive computers (Aqualung i330R, Apeks DSX) issue
/// after a PIN pairing, in the Keychain: one item per device, keyed by its advertised name
/// (model code + serial digits). Not synchronized to iCloud: the code belongs to the
/// pairing between this phone/Mac and the device.
nonisolated enum BLEAccessCodeKeychain {
    private static let service = "app.bluedive.divecomputer.accesscode"

    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: name]
    }

    static func read(forAdvertisedName name: String) -> Data? {
        var query = query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ code: Data, forAdvertisedName name: String) {
        let query = query(name)
        let attributes: [String: Any] = [kSecValueData as String: code,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func delete(forAdvertisedName name: String) {
        SecItemDelete(query(name) as CFDictionary)
    }
}

/// The PIN prompt the scanner shows while a Pelagic device pairs. The download thread
/// waits for the answer; the prompt itself runs on the main actor.
@MainActor @Observable
final class BLEPairingPrompt {
    static let shared = BLEPairingPrompt()

    /// The device name being paired while a PIN is requested, else nil.
    private(set) var pendingDeviceName: String?
    @ObservationIgnored private var completion: ((String?) -> Void)?
    /// The request the pending prompt belongs to.
    @ObservationIgnored private var pendingToken: UUID?
    /// Advanced by every cancelled download: a request from a session started before it is
    /// refused at once, even when it arrives after the cancel (the request is posted from
    /// the download thread, so it can lose the race with the cancel).
    @ObservationIgnored private(set) var generation = 0

    func ask(deviceName: String, generation: Int, token: UUID, completion: @escaping (String?) -> Void) {
        guard generation == self.generation else {
            completion(nil)
            return
        }
        self.completion?(nil)
        self.completion = completion
        pendingToken = token
        pendingDeviceName = deviceName
    }

    /// The trimmed PIN, or nil to cancel the pairing (and the download).
    func answer(_ pin: String?) {
        let reply = pin?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingDeviceName = nil
        pendingToken = nil
        let completion = self.completion
        self.completion = nil
        completion?(reply?.isEmpty == true ? nil : reply)
    }

    /// Gives up the request `token`, if it is still the pending one (the wait timed out).
    func expire(_ token: UUID) {
        guard pendingToken == token else { return }
        answer(nil)
    }

    /// The download is being cancelled: answers a pending prompt and refuses any request
    /// of that download still on its way.
    func cancelPending() {
        generation += 1
        if pendingDeviceName != nil { answer(nil) }
    }
}

/// Supplies Pelagic PINs (asked from the user) and access codes (Keychain) to DiveComputerKit.
nonisolated struct BLEPairingProvider: BLEAuthorizationProvider {
    /// Shown in the prompt (the model name when known).
    let deviceName: String
    /// `BLEPairingPrompt.generation` when the download started.
    let generation: Int

    /// Longest wait for the user's PIN before the pairing is given up.
    static let answerTimeout: DispatchTimeInterval = .seconds(300)

    func pinCode(for request: AuthorizationRequest) -> String? {
        // Called on the download thread, which may block; the prompt runs on the main actor.
        let semaphore = DispatchSemaphore(value: 0)
        let answer = Answer()
        let name = deviceName
        let generation = generation
        let token = UUID()
        Task { @MainActor in
            BLEPairingPrompt.shared.ask(deviceName: name, generation: generation, token: token) { pin in
                answer.value = pin
                semaphore.signal()
            }
        }
        // Answered by the prompt's buttons or by a cancelled download; the timeout is only a
        // backstop so the download thread can never wait forever.
        if semaphore.wait(timeout: .now() + Self.answerTimeout) == .timedOut {
            Task { @MainActor in BLEPairingPrompt.shared.expire(token) }
            return nil
        }
        return answer.value
    }

    func accessCode(for request: AuthorizationRequest) -> Data? {
        BLEAccessCodeKeychain.read(forAdvertisedName: request.advertisedName)
    }

    func storeAccessCode(_ code: Data, for request: AuthorizationRequest) {
        BLEAccessCodeKeychain.save(code, forAdvertisedName: request.advertisedName)
    }

    /// Carries the PIN from the main actor to the waiting download thread (the semaphore
    /// orders the write before the read).
    private final class Answer: @unchecked Sendable {
        var value: String?
    }
}
