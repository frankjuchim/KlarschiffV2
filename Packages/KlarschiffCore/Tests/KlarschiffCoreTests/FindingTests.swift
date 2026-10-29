import Testing
import Foundation
@testable import KlarschiffCore

@Test func preselectedOnlyWhenSafeNotKeptNotBlockedNotSuggested() {
  let base = Finding.sample(risk: .safe)
  #expect(base.isPreselected(isKept: false))
  #expect(!base.isPreselected(isKept: true))
  #expect(!Finding.sample(risk: .review).isPreselected(isKept: false))
  #expect(!Finding.sample(risk: .hintOnly).isPreselected(isKept: false))
  #expect(!Finding.sample(risk: .safe, keepSuggested: true).isPreselected(isKept: false))
  #expect(!Finding.sample(risk: .safe, blockingApps: [AppRef(bundleID: "com.apple.dt.Xcode", processName: nil, displayName: "Xcode")]).isPreselected(isKept: false))
}
@Test func categoriesMapToTabs() {
  #expect(Category.xcode.tab == .developer)
  #expect(Category.aiLeftovers.tab == .storage)
  #expect(Category.aiLeftovers.title == "KI-Reste")
}
@Test func toolCommandDisplayQuotesAndHasNoHash() {
  let c = ToolCommand(tool: "xcrun", arguments: ["simctl", "runtime", "delete", "ABC-123"], timeout: .seconds(600))
  #expect(c.display == "xcrun simctl runtime delete ABC-123")
  #expect(ToolCommand(tool: "brew", arguments: ["uninstall", "--cask", "my app"], timeout: .seconds(120)).display == "brew uninstall --cask 'my app'")
}
@Test func shellQuoteEscapesSingleQuotes() {
  #expect(ShellQuote.quote("it's") == "'it'\\''s'")
  #expect(ShellQuote.quote("a/b-c.d") == "a/b-c.d")
  #expect(ShellQuote.quote("") == "''")
}
@Test func riskLabelsAndTabs() {
  #expect(Risk.safe.label == "Sicher")
  #expect(Risk.review.label == "Prüfen")
  #expect(Risk.hintOnly.label == "Nur Hinweis")
  #expect(AppTab.services.title == "Hintergrunddienste")
  #expect(AppTab.storage.symbol == "internaldrive")
  #expect(Finding.sample(category: .simulators).tab == .developer)
}

@Test func systemDataCategory() {
  #expect(Category.systemData.tab == .systemData)
  #expect(Category.systemData.title == "Systemdaten")
  #expect(Category.systemData.symbol == "chart.pie")
}

@Test func servicesCategory() {
  #expect(Category.services.tab == .services)
  #expect(Category.services.title == "Hintergrunddienste")
  #expect(Category.services.symbol == "gearshape.2")
  #expect(Category.allCases.last == .services)
  #expect(Category.forScannerID("services.orphaned") == .services)
}
