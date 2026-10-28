import AppKit
import AVFoundation
import Speech

/// The microphone and speech recognition. macOS asks the person itself the first time (the app carries the
/// reasons it shows); after a refusal it never asks again, so the app leads them to System Settings.
enum Permissions {
    enum Kind: String {
        case microphone = "Privacy_Microphone"
        case speechRecognition = "Privacy_SpeechRecognition"

        var name: String { self == .microphone ? "Microphone" : "Speech Recognition" }
    }

    static func microphone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func speechRecognition() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    static func openSettings(for kind: Kind) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
