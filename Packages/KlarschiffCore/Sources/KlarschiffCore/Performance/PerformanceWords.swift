import Foundation

public enum PerformanceMath {
    /// Auslastung 0…1 aus zwei Tick-Ständen; 0 ohne Fortschritt.
    public static func cpuLoad(_ a: CPUTicks, _ b: CPUTicks) -> Double {
        let user = delta(a.user, b.user)
        let system = delta(a.system, b.system)
        let nice = delta(a.nice, b.nice)
        let idle = delta(a.idle, b.idle)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return 0 }
        return min(1, Double(busy) / Double(total))
    }

    /// Differenz zweier 32-Bit-Zähler; Überlauf nur nahe dem Zählerende, sonst 0.
    private static func delta(_ a: UInt64, _ b: UInt64) -> UInt64 {
        if b >= a { return b - a }
        let limit = UInt64(UInt32.max)
        guard a > limit / 2, a <= limit else { return 0 }
        return b + (limit - a) + 1
    }
}

public enum PerformanceWords {
    public static func cpu(_ load: Double) -> String {
        if load < 0.30 { return "kühl" }
        if load < 0.70 { return "beschäftigt" }
        return "unter Last"
    }

    public static func memory(pressure: Int) -> String {
        if pressure >= 4 { return "knapp" }
        if pressure >= 2 { return "angespannt" }
        return "entspannt"
    }

    public static func swap(_ bytes: UInt64) -> String {
        if bytes == 0 { return "nichts" }
        if bytes < 2_000_000_000 { return "wenig" }
        return "viel"
    }

    public static func uptime(since: Date, now: Date) -> (value: String, word: String) {
        let seconds = max(0, now.timeIntervalSince(since))
        let days = Int(seconds / 86_400)
        let word: String
        if seconds < 7 * 86_400 {
            word = "frisch genug"
        } else if seconds < 21 * 86_400 {
            word = "läuft schon eine Weile"
        } else {
            word = "Neustart würde guttun"
        }
        let value: String
        if days >= 1 {
            value = days == 1 ? "1 Tag" : "\(days) Tage"
        } else {
            let hours = Int(seconds / 3600)
            if hours >= 1 {
                value = hours == 1 ? "1 Stunde" : "\(hours) Stunden"
            } else {
                let minutes = Int(seconds / 60)
                value = minutes == 1 ? "1 Minute" : "\(minutes) Minuten"
            }
        }
        return (value, word)
    }
}
