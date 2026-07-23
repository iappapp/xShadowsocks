import Testing
@testable import xShadowsocks

struct MihomoYAMLProxyInjectorTests {

    @Test func injectsProxiesAndProxyGroups() {
        let yaml = """
        mixed-port: 7890
        proxies:
          - name: old
            type: vless
            server: old.example.com
            port: 443
            uuid: old
        proxy-groups:
          - name: SELECT
            type: select
            proxies: [old, DIRECT]
        rules:
          - MATCH,SELECT
        """

        let nodes = [
            ServerNode(
                name: "香港 01",
                host: "hk.example.com",
                port: 443,
                password: "uuid-1",
                nodeType: "vless",
                sni: "cdn.example.com",
                latency: nil,
                flow: "xtls-rprx-vision",
                encryption: "none",
                tls: true,
                clientFingerprint: "chrome"
            ),
            ServerNode(
                name: "新加坡",
                host: "sg.example.com",
                port: 443,
                password: "pass-1",
                nodeType: "anytls",
                sni: "sg.cdn.com",
                latency: nil,
                skipCertVerify: false
            )
        ]

        let merged = MihomoYAMLProxyInjector.injecting(nodes, into: yaml)
        let parsed = MihomoYAMLConfigParser.parseProxies(from: merged)

        #expect(parsed.count == 2)
        #expect(parsed[0].name == "香港 01")
        #expect(parsed[0].nodeType == "vless")
        #expect(parsed[0].password == "uuid-1")
        #expect(parsed[1].name == "新加坡")
        #expect(parsed[1].nodeType == "anytls")

        #expect(merged.contains("proxy-groups:"))
        #expect(merged.contains("name: \"SELECT\""))
        #expect(merged.contains("\"香港 01\""))
        #expect(merged.contains("\"新加坡\""))
        #expect(merged.contains("DIRECT"))
        #expect(!merged.contains("old.example.com"))
    }

    @Test func emptyNodesLeavesYAMLUnchanged() {
        let yaml = "mixed-port: 7890\n"
        let merged = MihomoYAMLProxyInjector.injecting([], into: yaml)
        #expect(merged == yaml)
    }
}
