import Foundation

struct CheckEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let result: CheckResult
}

enum CheckResult {
    case clear
    case faceTouch
    case mouthCovered
    case noFaceDetected
    case error(String)

    var isAlert: Bool {
        switch self {
        case .faceTouch, .mouthCovered: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .clear: return "Clear"
        case .faceTouch: return "Face touch!"
        case .mouthCovered: return "Mouth covered!"
        case .noFaceDetected: return "No face detected"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var symbol: String {
        switch self {
        case .clear: return "checkmark.circle"
        case .faceTouch: return "exclamationmark.triangle.fill"
        case .mouthCovered: return "exclamationmark.triangle.fill"
        case .noFaceDetected: return "eye.slash"
        case .error: return "xmark.circle"
        }
    }
}

class CheckHistory: ObservableObject {
    static let shared = CheckHistory()
    @Published var entries: [CheckEntry] = []

    func add(_ result: CheckResult) {
        let entry = CheckEntry(timestamp: Date(), result: result)
        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            // Keep last 100
            if self.entries.count > 100 {
                self.entries = Array(self.entries.prefix(100))
            }
        }
    }
}
