import Foundation
import Synchronization
@testable import KlarschiffCore

/// Test-Attrappe: eine App gilt als laufend, wenn Bundle-ID oder Prozessname in der Menge liegt.
final class FakeRunningApps: RunningApps {
    private let state: Mutex<Set<String>>

    init(running: Set<String> = []) { state = Mutex(running) }

    func setRunning(_ names: Set<String>) { state.withLock { $0 = names } }

    private func matches(_ ref: AppRef, in set: Set<String>) -> Bool {
        (ref.bundleID.map(set.contains) ?? false) || (ref.processName.map(set.contains) ?? false)
    }

    func running(_ refs: [AppRef]) -> [AppRef] {
        let set = state.withLock { $0 }
        return refs.filter { matches($0, in: set) }
    }

    func terminate(_ ref: AppRef) async -> Bool {
        state.withLock { set in
            if let b = ref.bundleID { set.remove(b) }
            if let p = ref.processName { set.remove(p) }
            return true
        }
    }
}
