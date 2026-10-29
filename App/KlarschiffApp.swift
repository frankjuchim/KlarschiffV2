import SwiftUI
import KlarschiffCore

@main
struct KlarschiffApp: App {
    var body: some Scene {
        Window("Klarschiff", id: "main") {
            Text("Klarschiff")
                .font(.largeTitle)
                .frame(minWidth: 600, minHeight: 400)
        }
    }
}
