import Testing
@testable import xShadowsocks

struct MihomoYAMLPreflightTests {

    @Test func rejectsEmptyAndAcceptsBasicConfig() {
        #expect(!MihomoYAMLPreflight.check("").isOK)
        #expect(!MihomoYAMLPreflight.check("   \n").isOK)

        let ok = """
        mixed-port: 7890
        proxies:
          - name: "HK"
            type: vless
            server: hk.example.com
            port: 443
            uuid: abc
        rules:
          - MATCH,DIRECT
        """
        #expect(MihomoYAMLPreflight.check(ok).isOK)
    }

    @Test func flagsSpecialCharactersAndTabs() {
        let dirty = "proxies:\n\t- name: \u{201C}HK\u{201D}\n\u{3000}type: vless\n"
        let report = MihomoYAMLPreflight.check(dirty)
        #expect(!report.isOK)
        #expect(report.issues.contains(where: { $0.message.contains("Tab") }))
        #expect(report.issues.contains(where: { $0.message.contains("全角") || $0.message.contains("弯引号") }))
    }

    @Test func normalizedCheckAutoCleansSpecialCharacters() {
        let dirty = """
        proxies:
        \u{3000}- name: "HK"
          type: vless
          server: hk.example.com
          port: 443
          uuid: abc
        """
        let (_, report) = MihomoYAMLPreflight.checkNormalized(dirty)
        // After normalize, indent special spaces are cleaned → should not error.
        #expect(report.isOK)
        #expect(report.warnings.contains(where: { $0.message.contains("特殊字符") || $0.message.contains("自动清理") }))
    }
}
