import Foundation
@testable import KlarschiffCore

extension CommandResult {
    /// Aufgezeichnete Werkzeug-Ausgabe aus `Tests/KlarschiffCoreTests/Fixtures/` als stdout.
    static func fixture(_ name: String, exitCode: Int32 = 0) -> CommandResult {
        let url = Bundle.module.resourceURL!.appending(path: "Fixtures").appending(path: name)
        let text = try! String(contentsOf: url, encoding: .utf8)
        return CommandResult(exitCode: exitCode, stdout: text, stderr: "")
    }
}
