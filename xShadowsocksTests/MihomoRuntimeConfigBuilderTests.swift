import Testing
@testable import xShadowsocks

struct MihomoRuntimeConfigBuilderTests {

    private let subscriptionYAML = """
    mixed-port: 7890
    allow-lan: true
    mode: rule
    log-level: info
    external-controller: 127.0.0.1:9999
    secret: "from-subscription"

    dns:
      enable: true
      enhanced-mode: fake-ip
      fake-ip-range: 198.18.0.1/16
      nameserver:
        - https://1.1.1.1/dns-query
      fallback:
        - tls://8.8.8.8:853

    tun:
      enable: true
      stack: gvisor
      auto-route: true

    proxies:
      - name: "香港 01"
        type: vless
        server: hk.example.com
        port: 443
        uuid: 11111111-1111-1111-1111-111111111111

    proxy-groups:
      - name: Proxy
        type: select
        proxies: ["香港 01", DIRECT]

    rules:
      - GEOIP,CN,DIRECT
      - MATCH,Proxy
    """

    private func build(_ yaml: String, mode: MihomoRuntimeConfigBuilder.HostMode = .tunnel(fileDescriptor: 42)) -> String {
        MihomoRuntimeConfigBuilder.runtimeConfig(
            userYAML: yaml,
            mode: mode,
            mixedPort: 7890,
            allowLan: false,
            ipv6Enabled: false,
            routingMode: .rule,
            externalControllerPort: 9090,
            externalControllerSecret: "test-secret"
        )
    }

    @Test func replacesOwnedKeysAndKeepsSubscriptionContent() {
        let output = build(subscriptionYAML)

        // Owned keys are written from the tunnel's own parameters.
        #expect(output.contains("mixed-port: 7890"))
        #expect(output.contains("allow-lan: false"))
        #expect(output.contains("external-controller: 127.0.0.1:9090"))
        #expect(output.contains("secret: \"test-secret\""))
        #expect(!output.contains("from-subscription"))
        #expect(!output.contains("9999"))
        #expect(!output.contains("gvisor"))
        #expect(!output.contains("auto-route: true"))

        // Subscription content survives untouched.
        #expect(output.contains("hk.example.com"))
        #expect(output.contains("GEOIP,CN,DIRECT"))
        #expect(output.contains("- MATCH,Proxy"))
        #expect(output.contains("https://1.1.1.1/dns-query"))
        #expect(output.contains("tls://8.8.8.8:853"))
        #expect(output.contains("name: \"香港 01\""))
    }

    @Test func tunSectionDescribesThePassedDescriptor() {
        let output = build(subscriptionYAML, mode: .tunnel(fileDescriptor: 7))
        let tun = tunBlock(of: output)

        #expect(tun == [
            "tun:",
            "  enable: true",
            "  file-descriptor: 7",
            "  stack: system",
            "  auto-route: false",
            "  auto-detect-interface: false",
            "  mtu: \(MihomoRuntimeConfigBuilder.interfaceMTU)",
            "  recvmsgx: true",
            "  dns-hijack:",
            "    - any:53"
        ])
        // The subscription's own tun block is gone, not merged.
        #expect(!output.contains("gvisor"))
        #expect(!output.contains("auto-route: true"))
    }

    @Test func existingDNSSectionKeepsServersButForcesEnable() {
        let disabled = """
        dns:
          enable: false
          nameserver:
            - 223.5.5.5
        rules:
          - MATCH,DIRECT
        """
        let output = build(disabled, mode: .tunnel(fileDescriptor: 9))
        let dns = dnsBlock(of: output)

        #expect(dns.contains("  enable: true"))
        #expect(!dns.contains("enable: false"))
        #expect(dns.contains("223.5.5.5"))
    }

    @Test func missingDNSSectionIsAdded() {
        let withoutDNS = """
        proxies: []
        rules:
          - MATCH,DIRECT
        """
        let output = build(withoutDNS, mode: .tunnel(fileDescriptor: 11))
        let dns = dnsBlock(of: output)

        #expect(dns.contains("  enable: true"))
        #expect(dns.contains("  enhanced-mode: fake-ip"))
        #expect(dns.contains("  fake-ip-range: 198.18.0.1/16"))
        #expect(output.contains("proxies: []"))
    }

    @Test func blankLinesBetweenSectionsSurvive() {
        let output = build(subscriptionYAML)
        // The proxies section must not be glued to whatever preceded it, or the YAML
        // would stop parsing.
        #expect(output.contains("\nproxies:"))
    }

    // MARK: - Tunnel settings

    @Test func derivesTunAddressFromFakeIPRange() {
        let settings = MihomoRuntimeConfigBuilder.tunnelSettings(fromUserYAML: subscriptionYAML)

        // mihomo uses `dns.fake-ip-range`'s address verbatim as the tun address (the
        // prefix is widened to /30) and reserves the following address for its own
        // hijacked DNS listener.
        #expect(settings.interfaceAddress == "198.18.0.1")
        #expect(settings.prefixLength == 30)
        #expect(settings.subnetMask == "255.255.255.252")
        #expect(settings.dnsServers == ["198.18.0.2", "198.18.0.3"])
        #expect(settings.interfaceCIDR == "198.18.0.1/30")
    }

    @Test func fallsBackToMihomoDefaultRange() {
        let settings = MihomoRuntimeConfigBuilder.tunnelSettings(fromUserYAML: "proxies: []")
        #expect(settings.interfaceAddress == "198.18.0.1")
        #expect(settings.mtu == MihomoRuntimeConfigBuilder.interfaceMTU)
    }

    @Test func honoursCustomFakeIPRange() {
        let custom = """
        dns:
          enhanced-mode: fake-ip
          fake-ip-range: 10.0.0.1/16
        """
        let settings = MihomoRuntimeConfigBuilder.tunnelSettings(fromUserYAML: custom)
        #expect(settings.interfaceAddress == "10.0.0.1")
        #expect(settings.dnsServers == ["10.0.0.2", "10.0.0.3"])
    }

    @Test func incrementsIPv4WithCarry() {
        #expect(MihomoRuntimeConfigBuilder.incrementIPv4("198.18.0.255") == "198.18.1.0")
        #expect(MihomoRuntimeConfigBuilder.incrementIPv4("10.0.0.1") == "10.0.0.2")
    }

    // MARK: - Loopback mode

    @Test func loopbackModeDisablesTunAndKeepsUserDNS() {
        let dnsDisabled = """
        dns:
          enable: true
          nameserver:
            - 223.5.5.5
        rules:
          - MATCH,DIRECT
        """
        let output = build(dnsDisabled, mode: .loopback)

        // The tun inbound must be off: creating a utun would need the entitlement this
        // mode exists to avoid.
        #expect(tunBlock(of: output) == ["tun:", "  enable: false"])
        #expect(!output.contains("file-descriptor"))
        #expect(!output.contains("dns-hijack"))

        // The user's DNS block is left alone, unlike in tunnel mode.
        #expect(output.contains("nameserver:"))
        #expect(output.contains("223.5.5.5"))
    }

    @Test func loopbackModeKeepsDNSDisabledWhenTheUserDisabledIt() {
        // The device's own resolver is still available outside a tunnel, so a config
        // that turns mihomo's DNS off must stay that way.
        let dnsDisabled = """
        dns:
          enable: false
          nameserver:
            - 223.5.5.5
        rules:
          - MATCH,DIRECT
        """
        let output = build(dnsDisabled, mode: .loopback)
        #expect(dnsBlock(of: output).contains("  enable: false"))
        #expect(!dnsBlock(of: output).contains("  enable: true"))
    }

    @Test func tunnelModeForcesDNSOn() {
        let dnsDisabled = """
        dns:
          enable: false
          nameserver:
            - 223.5.5.5
        rules:
          - MATCH,DIRECT
        """
        let output = build(dnsDisabled, mode: .tunnel(fileDescriptor: 5))
        #expect(dnsBlock(of: output).contains("  enable: true"))
        #expect(output.contains("223.5.5.5"))
    }

    /// The `tun:` block as a list of lines, for precise assertions on a key that also
    /// appears inside `dns:`.
    private func tunBlock(of yaml: String) -> [String] {
        block(named: "tun", of: yaml)
    }

    private func dnsBlock(of yaml: String) -> String {
        block(named: "dns", of: yaml).joined(separator: "\n")
    }

    private func block(named name: String, of yaml: String) -> [String] {
        var result: [String] = []
        var inBlock = false
        for line in yaml.components(separatedBy: "\n") {
            if line.hasPrefix("\(name):") {
                inBlock = true
                result.append(line)
                continue
            }
            guard inBlock else { continue }
            if line.isEmpty || line.hasPrefix(" ") {
                if !line.isEmpty { result.append(line) }
                continue
            }
            break
        }
        return result
    }

    @Test func loopbackModeAddsNoDNSSection() {
        let withoutDNS = """
        proxies: []
        rules:
          - MATCH,DIRECT
        """
        let output = build(withoutDNS, mode: .loopback)
        #expect(!output.contains("dns:"))
        #expect(output.contains("proxies: []"))
    }

    @Test func bothModesForceTheOwnedKeys() {
        for mode in [MihomoRuntimeConfigBuilder.HostMode.tunnel(fileDescriptor: 3), .loopback] {
            let output = build(subscriptionYAML, mode: mode)
            #expect(output.contains("mixed-port: 7890"))
            #expect(output.contains("allow-lan: false"))
            #expect(output.contains("bind-address: 127.0.0.1"))
            #expect(output.contains("external-controller: 127.0.0.1:9090"))
            #expect(!output.contains("from-subscription"))
            #expect(!output.contains("9999"))
            #expect(output.contains("hk.example.com"))
        }
    }
}
