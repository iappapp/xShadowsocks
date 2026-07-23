import Testing
@testable import xShadowsocks

struct MihomoConfigNormalizeTests {

    @Test func normalizeReplacesTabsBOMAndCRLF() {
        let raw = "\u{feff}proxies:\r\n\t- name: HK\r\n\t  type: vless\r\n"
        let normalized = MihomoConfigFileStore.normalizeForMihomoYAML(raw)

        #expect(!normalized.hasPrefix("\u{feff}"))
        #expect(!normalized.contains("\r"))
        #expect(!normalized.contains("\t"))
        #expect(normalized.contains("  - name: HK"))
        #expect(normalized.contains("    type: vless"))
    }
}
