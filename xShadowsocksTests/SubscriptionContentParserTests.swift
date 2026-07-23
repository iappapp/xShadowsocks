import Foundation
import Testing
@testable import xShadowsocks

struct SubscriptionContentParserTests {

    @Test func parseYAMLPayloadKeepsRawYAML() {
        let payload = """
        proxies:
          - name: HK
            type: vless
            server: hk.example.com
            port: 443
            uuid: abc
        rules:
          - MATCH,Proxy
        """

        let result = SubscriptionContentParser.parse(payload)

        #expect(result.nodes.count == 1)
        #expect(result.nodes[0].name == "HK")
        #expect(result.rawYAML == payload.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func parseBase64URIList() {
        let uris = """
        vless://11111111-1111-1111-1111-111111111111@hk.example.com:443?encryption=none&security=tls&sni=cdn.example.com#香港
        anytls://secret@sg.example.com:443?sni=sg.cdn.com#新加坡
        """
        let payload = Data(uris.utf8).base64EncodedString()

        let result = SubscriptionContentParser.parse(payload)

        #expect(result.nodes.count == 2)
        #expect(result.nodes[0].name == "香港")
        #expect(result.nodes[1].name == "新加坡")
        #expect(result.rawYAML == nil)
    }

    @Test func decodeBase64SupportsURLSafeAndPadding() {
        let text = "hello-world"
        let standard = Data(text.utf8).base64EncodedString()
        let urlSafe = standard
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        #expect(SubscriptionContentParser.decodeBase64(standard) == text)
        #expect(SubscriptionContentParser.decodeBase64(urlSafe) == text)
        #expect(SubscriptionContentParser.decodeBase64("not-base64!!!") == nil)
    }
}
