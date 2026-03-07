//
//  xShadowsocksTests.swift
//  xShadowsocksTests
//
//  Created by mac on 2026/3/2.
//

import Testing
@testable import xShadowsocks

struct xShadowsocksTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func testTrojanURIParser() async throws {
        let input = """
        trojan://password1@host1.com:443?sni=example.com#节点一
        trojan://password2@host2.com:443?peer=peer.com#节点二
        trojan://password1@host1.com:443?sni=example.com#节点一
        trojan://password3@host3.com:443#节点三
        invalid://not-a-trojan
        
        """
        let nodes = TrojanURIParser.parse(input)
        #expect(nodes.count == 3)
        #expect(nodes[0].name == "节点一")
        #expect(nodes[0].host == "host1.com")
        #expect(nodes[0].port == 443)
        #expect(nodes[0].password == "password1")
        #expect(nodes[0].sni == "example.com")
        #expect(nodes[1].name == "节点二")
        #expect(nodes[1].host == "host2.com")
        #expect(nodes[1].sni == "peer.com")
        #expect(nodes[2].name == "节点三")
        #expect(nodes[2].host == "host3.com")
    }

}
