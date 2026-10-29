import Foundation
import Testing
@testable import KlarschiffCore

@Suite struct SystemAreaCatalogTests {
    private func all() -> [SystemAreaDefinition] {
        SystemAreaCatalog.definitions().flatMap { [$0] + $0.children }
    }

    @Test func catalogHasSpecIDs() {
        let ids = all().map(\.id)
        for id in ["var.folders.caches", "var.folders.temp", "var.vm", "var.db.diagnostics",
                   "library.caches", "library.logs", "assets", "developer", "opt", "usrlocal"] {
            #expect(ids.contains(id), "fehlt: \(id)")
        }
    }

    @Test func idsAreUniqueAndVerdictsMatchSpec() {
        let defs = all()
        #expect(Set(defs.map(\.id)).count == defs.count)
        let byID = Dictionary(uniqueKeysWithValues: defs.map { ($0.id, $0) })
        #expect(byID["var.folders.caches"]?.verdict == .keep)
        #expect(byID["var.folders.temp"]?.verdict == .cleanable)
        #expect(byID["var.vm"]?.verdict == .keep)
        #expect(byID["var.db.diagnostics"]?.verdict == .cleanable)
        #expect(byID["library.caches"]?.verdict == .cleanable)
        #expect(byID["library.logs"]?.verdict == .cleanable)
        #expect(byID["developer"]?.verdict == .seeFinding(scannerID: "xcode.libraryDeveloper", tab: .developer))
    }

    @Test func seeFindingScannerIDsExistInCatalog() {
        let known = Set(Catalog.allScanners().map(\.id))
        let verdicts = all().map(\.verdict) + AssetNameMap.allKnownVerdicts
        for v in verdicts {
            if case .seeFinding(let id, _) = v { #expect(known.contains(id), "unbekannt: \(id)") }
        }
    }

    @Test func assetNames() {
        #expect(AssetNameMap.entry(forAssetDirectory: "com_apple_MobileAsset_iOSSimulatorRuntime").verdict == .seeFinding(scannerID: "sim.runtimes", tab: .developer))
        #expect(AssetNameMap.entry(forAssetDirectory: "com_apple_MobileAsset_MacSoftwareUpdate").title == "Heruntergeladenes macOS-Update")
        #expect(AssetNameMap.entry(forAssetDirectory: "com_apple_MobileAsset_FooBar").title == "FooBar")
        #expect(AssetNameMap.entry(forAssetDirectory: "com_apple_MobileAsset_FooBar").verdict == .keep)
        #expect(AssetNameMap.entry(forAssetDirectory: "com_apple_MobileAsset_UAF_Siri_TextToSpeech").title == "Siri-Sprachdaten")
        #expect(AssetNameMap.entry(forAssetDirectory: "com_apple_MobileAsset_Font8").title == "Schriften")
        #expect(AssetNameMap.entry(forAssetDirectory: "downloadDir").title == "downloadDir")
    }

    @Test func everyDefinitionHasGermanText() {
        for d in all() {
            #expect(!d.title.isEmpty && !d.summary.isEmpty)
            #expect(!d.summary.contains("#") && !d.title.contains("#"))
        }
        for e in AssetNameMap.allKnownTexts {
            #expect(!e.isEmpty && !e.contains("#"))
        }
    }

    @Test func developerIsNestedUnderLibraryAndSeeFindingTabsAreDeveloper() {
        let top = SystemAreaCatalog.definitions()
        #expect(!top.contains { $0.id == "developer" })
        #expect(top.first { $0.id == "library" }?.children.contains { $0.id == "developer" } == true)
        for d in all() {
            if case .seeFinding(_, let tab) = d.verdict { #expect(tab == .developer) }
        }
        #expect(all().first { $0.id == "var.db.diagnostics" }?.extraPaths == ["/private/var/db/uuidtext"])
    }

    @Test func updateHintAndRuleOrder() {
        #expect(AssetNameMap.explanation(forAssetDirectory: "MacSoftwareUpdate").contains("macOS räumt die Datei selbst weg"))
        #expect(AssetNameMap.entry(forAssetDirectory: "UAF_LinguisticData").title == "Sprachdaten")
        #expect(AssetNameMap.entry(forAssetDirectory: "LinguisticDataAuto").title == "Sprachdaten")
        #expect(AssetNameMap.entry(forAssetDirectory: "UAF_Siri_Understanding").title == "Siri-Sprachdaten")
        #expect(AssetNameMap.entry(forAssetDirectory: "UAF_FM_Visual").title == "Apple-Intelligence-Modelle")
    }

    @Test func realAssetsAllMapWithoutCrash() throws {
        for raw in ["analytics", "Font7", "UAF_FM_GenerativeModels", "VoiceServices_GryphonVoice", "MetalToolchain", "xrOSSimulatorRuntime"] {
            let e = AssetNameMap.entry(forAssetDirectory: "com_apple_MobileAsset_" + raw)
            #expect(!e.title.isEmpty)
            #expect(!AssetNameMap.explanation(forAssetDirectory: raw).isEmpty)
        }
    }
}
