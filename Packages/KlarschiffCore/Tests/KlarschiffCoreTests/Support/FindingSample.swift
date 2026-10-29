import Foundation
@testable import KlarschiffCore

extension Finding {
    static func sample(
        risk: Risk = .safe,
        category: KlarschiffCore.Category = .appCaches,
        method: RemovalMethod = .trash,
        size: Int64? = 1_000,
        blockingApps: [AppRef] = [],
        keepSuggested: Bool = false
    ) -> Finding {
        Finding(
            id: FindingID(scannerID: "sample", key: "sample-key"),
            category: category,
            title: "Beispiel",
            summary: "Ein Beispielfund",
            risk: risk,
            method: method,
            items: [],
            size: size,
            blockingApps: blockingApps,
            keepSuggested: keepSuggested,
            commandPreview: [],
            needsFullDiskAccess: false
        )
    }
}
