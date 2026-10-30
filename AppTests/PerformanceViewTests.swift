import Foundation
import Testing
import KlarschiffCore
@testable import Klarschiff

@Test func processCountTextUsesSingularAndPlural() {
    #expect(ActivityList.processCountText(1) == "1 Prozess")
    #expect(ActivityList.processCountText(3) == "3 Prozesse")
    #expect(ActivityList.processCountText(0) == "0 Prozesse")
}

@Test func cpuTextHasOneDecimalWithGermanComma() {
    #expect(ActivityList.cpuText(12.34) == "12,3 %")
    #expect(ActivityList.cpuText(0) == "0,0 %")
    #expect(ActivityList.cpuText(1234.56) == "1234,6 %")
    #expect(ActivityList.cpuText(-1) == "0,0 %")
}

@Test func quitTitleNamesTheApp() {
    #expect(ActivityList.quitTitle("Xcode") == "Xcode beenden?")
}

@Test func cpuTileShowsDashBeforeFirstDelta() {
    #expect(PerformanceTabView.cpuValueText(load: 0, hasValue: false) == "–")
    #expect(PerformanceTabView.cpuValueText(load: 0.304, hasValue: true) == "30 %")
    #expect(PerformanceTabView.cpuValueText(load: 1.2, hasValue: true) == "100 %")
}

@Test func cpuTileWordMatchesDisplayedRoundedValue() {
    // 0,296 wird als „30 %“ angezeigt – das Wort muss dazu passen.
    #expect(PerformanceTabView.cpuValueText(load: 0.296, hasValue: true) == "30 %")
    #expect(PerformanceTabView.cpuWord(load: 0.296, hasValue: true) == "beschäftigt")
    #expect(PerformanceTabView.cpuWord(load: 0.294, hasValue: true) == "kühl")
    #expect(PerformanceTabView.cpuWord(load: 0.696, hasValue: true) == "unter Last")
    #expect(PerformanceTabView.cpuWord(load: 0.5, hasValue: false) == " ")
}

@Test func spotlightExplanationMentionsExistingExclusions() {
    #expect(SpotlightCard.explanation.contains("schon ausgeschlossen"))
}

@Test func memoryAndSwapTilesUseBinaryUnitsAndWords() {
    let total: UInt64 = 17_179_869_184
    let m = PerformanceTabView.memoryTexts(used: 8_589_934_592, total: total, pressure: 2)
    #expect(m.value == ByteFormat.memoryString(8_589_934_592))
    #expect(m.footnote == "von \(ByteFormat.memoryString(Int64(total))) · angespannt")
    #expect(PerformanceTabView.memoryTexts(used: 0, total: 0, pressure: 1).value == "–")
    #expect(PerformanceTabView.swapTexts(0, measured: true).footnote == "nichts")
    #expect(PerformanceTabView.swapTexts(5, measured: false).value == "–")
}

@Test func spotlightPathIsAbbreviatedWithTilde() {
    let home = "/Users/frank"
    #expect(SpotlightCard.abbreviatedPath(URL(filePath: "/Users/frank/Dev/x/node_modules"), home: home) == "~/Dev/x/node_modules")
    #expect(SpotlightCard.abbreviatedPath(URL(filePath: "/Users/frankie/x"), home: home) == "/Users/frankie/x")
    #expect(SpotlightCard.abbreviatedPath(URL(filePath: "/Users/frank/a"), home: "/Users/frank/") == "~/a")
}

@Test func sparklinePointsScaleAndGrow() {
    let size = CGSize(width: 100, height: 23)
    #expect(Sparkline.points([0.5], maxValue: 1, size: size).isEmpty)
    let p = Sparkline.points([0, 1], maxValue: 1, size: size)
    #expect(p.map(\.x) == [0, 100])
    #expect(p[0].y > p[1].y)
    // Werte über maxValue erweitern die Skala: der größte Wert liegt oben.
    let q = Sparkline.points([50, 200], maxValue: 100, size: size)
    #expect(q[1].y == p[1].y)
}

@Test func rowSelectionTogglesByID() {
    #expect(ActivityList.toggledSelection(nil, tapped: "a") == "a")
    #expect(ActivityList.toggledSelection("a", tapped: "b") == "b")
    #expect(ActivityList.toggledSelection("a", tapped: "a") == nil)
}
