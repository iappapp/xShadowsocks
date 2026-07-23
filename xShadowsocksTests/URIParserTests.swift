import Testing
@testable import xShadowsocks

struct URIParserTests {

    @Test func parseVLESSURI() {
        let input = """
        vless://11111111-1111-1111-1111-111111111111@hk.example.com:443?encryption=none&security=tls&sni=cdn.example.com&flow=xtls-rprx-vision&type=tcp&fp=chrome#香港%2001
        vless://22222222-2222-2222-2222-222222222222@jp.example.com:8443?security=reality&pbk=pubKey&sid=abcd&type=grpc&serviceName=tunnel#日本 01
        invalid://skip-me
        """

        let nodes = URIParser.parse(input)

        #expect(nodes.count == 2)

        #expect(nodes[0].name == "香港 01")
        #expect(nodes[0].host == "hk.example.com")
        #expect(nodes[0].port == 443)
        #expect(nodes[0].password == "11111111-1111-1111-1111-111111111111")
        #expect(nodes[0].nodeType == "vless")
        #expect(nodes[0].sni == "cdn.example.com")
        #expect(nodes[0].flow == "xtls-rprx-vision")
        #expect(nodes[0].encryption == "none")
        #expect(nodes[0].tls == true)
        #expect(nodes[0].network == "tcp")
        #expect(nodes[0].clientFingerprint == "chrome")

        #expect(nodes[1].name == "日本 01")
        #expect(nodes[1].host == "jp.example.com")
        #expect(nodes[1].port == 8443)
        #expect(nodes[1].publicKey == "pubKey")
        #expect(nodes[1].shortId == "abcd")
        #expect(nodes[1].network == "grpc")
        #expect(nodes[1].serviceName == "tunnel")
        #expect(nodes[1].tls == true)
    }

    @Test func parseAnyTLSURI() {
        let input = """
        anytls://secret@sg.example.com:443?type=tcp&insecure=0&fp=chrome&sni=sg.cdn.com#新加坡
        anytls://secret2@us.example.com:8443?allowInsecure=1&peer=us.cdn.com
        """

        let nodes = URIParser.parse(input)

        #expect(nodes.count == 2)
        #expect(nodes[0].name == "新加坡")
        #expect(nodes[0].nodeType == "anytls")
        #expect(nodes[0].password == "secret")
        #expect(nodes[0].sni == "sg.cdn.com")
        #expect(nodes[0].skipCertVerify == false)
        #expect(nodes[0].clientFingerprint == "chrome")
        #expect(nodes[0].tls == true)

        #expect(nodes[1].name == "us.example.com")
        #expect(nodes[1].sni == "us.cdn.com")
        #expect(nodes[1].skipCertVerify == true)
    }

    @Test func deduplicatesByNameHostPort() {
        let input = """
        vless://aaa@host.com:443?encryption=none#节点一
        vless://bbb@host.com:443?encryption=none#节点一
        vless://ccc@host.com:8443?encryption=none#节点一
        """

        let nodes = URIParser.parse(input)
        #expect(nodes.count == 2)
        #expect(nodes[0].password == "aaa")
        #expect(nodes[1].port == 8443)
    }
}
