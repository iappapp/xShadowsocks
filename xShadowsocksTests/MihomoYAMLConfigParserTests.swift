import Testing
@testable import xShadowsocks

struct MihomoYAMLConfigParserTests {

    @Test func parseBlockAndInlineProxies() {
        let yaml = """
        mixed-port: 7890
        proxies:
          - name: "香港 01"
            type: vless
            server: hk.example.com
            port: 443
            uuid: 11111111-1111-1111-1111-111111111111
            tls: true
            servername: cdn.example.com
            flow: xtls-rprx-vision
            client-fingerprint: chrome
            reality-opts: {public-key: pubKey, short-id: abcd}
          - {name: "日本 01", type: anytls, server: jp.example.com, port: 8443, password: secret, sni: jp.cdn.com, skip-cert-verify: true}
          - name: "无效节点"
            type: vless
            # missing server should be skipped
            port: 443
        proxy-groups:
          - name: Proxy
            type: select
            proxies: ["香港 01", "日本 01"]
        """

        let nodes = MihomoYAMLConfigParser.parseProxies(from: yaml)

        #expect(nodes.count == 2)

        #expect(nodes[0].name == "香港 01")
        #expect(nodes[0].host == "hk.example.com")
        #expect(nodes[0].port == 443)
        #expect(nodes[0].password == "11111111-1111-1111-1111-111111111111")
        #expect(nodes[0].nodeType == "vless")
        #expect(nodes[0].sni == "cdn.example.com")
        #expect(nodes[0].flow == "xtls-rprx-vision")
        #expect(nodes[0].tls == true)
        #expect(nodes[0].publicKey == "pubKey")
        #expect(nodes[0].shortId == "abcd")
        #expect(nodes[0].clientFingerprint == "chrome")

        #expect(nodes[1].name == "日本 01")
        #expect(nodes[1].host == "jp.example.com")
        #expect(nodes[1].port == 8443)
        #expect(nodes[1].password == "secret")
        #expect(nodes[1].nodeType == "anytls")
        #expect(nodes[1].sni == "jp.cdn.com")
        #expect(nodes[1].skipCertVerify == true)
    }

    @Test func parseInlineObjectOnly() {
        let yaml = "{name: Solo, type: vless, server: solo.example.com, port: 443, uuid: abc-def}"
        let nodes = MihomoYAMLConfigParser.parseProxies(from: yaml)

        #expect(nodes.count == 1)
        #expect(nodes[0].name == "Solo")
        #expect(nodes[0].host == "solo.example.com")
        #expect(nodes[0].password == "abc-def")
        #expect(nodes[0].nodeType == "vless")
    }

    @Test func stripsQuotedCommentsAndDeduplicates() {
        let yaml = """
        proxies:
          - name: "节点#保留" # trailing comment
            type: vless
            server: a.example.com
            port: 443
            uuid: one
          - name: "节点#保留"
            type: vless
            server: a.example.com
            port: 443
            uuid: two
        """

        let nodes = MihomoYAMLConfigParser.parseProxies(from: yaml)
        #expect(nodes.count == 1)
        #expect(nodes[0].name == "节点#保留")
        #expect(nodes[0].password == "one")
    }

    @Test func ignoresContentOutsideProxiesSection() {
        let yaml = """
        dns:
          enable: true
        rules:
          - MATCH,DIRECT
        """

        let nodes = MihomoYAMLConfigParser.parseProxies(from: yaml)
        #expect(nodes.isEmpty)
    }
}
