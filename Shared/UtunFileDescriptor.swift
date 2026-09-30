import Foundation
import Darwin

/// Resolves the kernel utun socket that `NEPacketTunnelProvider` created for us.
///
/// mihomo's tun inbound accepts a `file-descriptor` instead of opening its own
/// utun, which is the only way to run it inside a Network Extension. Handing it
/// the extension's own socket means the kernel does the packet plumbing and no
/// packets have to be shuffled through Swift.
///
/// Two independent strategies, in order of preference:
///
///   1. `packetFlow.value(forKeyPath: "socket.fileDescriptor")` — undocumented
///      KVC, but it names the socket directly and is what sing-box uses.
///   2. Scan the descriptor table for a socket whose peer address reports the
///      `com.apple.net.utun_control` kernel-control id — what wireguard-apple and
///      sing-box's Go side fall back to.
///
/// Both are validated the same way, by reading the interface name back with
/// `UTUN_OPT_IFNAME`, so a wrong descriptor is rejected rather than handed to the
/// core (which would then fail deep inside Go with a confusing error).
public enum UtunFileDescriptor {
    // `sys/kern_control.h` and `net/if_utun.h` are not part of the iOS SDK, so the
    // control structs and constants they define are reproduced here.
    private static let afSystem: Int32 = 32               // AF_SYSTEM
    private static let sysprotoControl: Int32 = 2         // SYSPROTO_CONTROL
    private static let utunOptIfName: Int32 = 2           // UTUN_OPT_IFNAME
    private static let ctliocginfo: UInt = 0xC064_4E03    // _IOWR('N', 3, struct ctl_info)
    private static let utunControlName = "com.apple.net.utun_control"
    private static let maxScannedDescriptor: Int32 = 1024

    /// `struct ctl_info` — a kernel-control id plus its name.
    private struct CtlInfo {
        var ctlID: UInt32 = 0
        var ctlName: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                      CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                      CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                      CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                      CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                      CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                      CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                      CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                      CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                      CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                      CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                      CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

        mutating func setName(_ name: String) {
            withUnsafeMutableBytes(of: &ctlName) { raw in
                let destination = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                _ = name.withCString { source in
                    strncpy(destination, source, raw.count - 1)
                }
            }
        }
    }

    /// `struct sockaddr_ctl` — the peer address of a kernel-control socket.
    private struct SockaddrCtl {
        var scLen: UInt8 = 0
        var scFamily: UInt8 = 0
        var ssSysaddr: UInt16 = 0
        var scID: UInt32 = 0
        var scUnit: UInt32 = 0
        var scReserved: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    }

    /// Returns the utun descriptor for the running tunnel, or nil if none was found.
    public static func resolve(packetFlow: AnyObject?) -> Int32? {
        if let descriptor = descriptorViaKVC(packetFlow: packetFlow),
           interfaceName(forDescriptor: descriptor) != nil {
            return descriptor
        }

        if let descriptor = scanDescriptorTable(),
           interfaceName(forDescriptor: descriptor) != nil {
            return descriptor
        }

        return nil
    }

    /// Interface name behind a descriptor, e.g. `utun4`. Nil when the descriptor
    /// is not a utun control socket.
    public static func interfaceName(forDescriptor descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var length = socklen_t(buffer.count)
        let result = buffer.withUnsafeMutableBytes { raw -> Int32 in
            getsockopt(descriptor, sysprotoControl, utunOptIfName, raw.baseAddress, &length)
        }
        guard result == 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    // MARK: - Strategy 1

    private static func descriptorViaKVC(packetFlow: AnyObject?) -> Int32? {
        guard let packetFlow else { return nil }
        // The tunnel exposes its socket only through KVC; there is no public API.
        guard let value = packetFlow.value(forKeyPath: "socket.fileDescriptor") else { return nil }
        if let descriptor = value as? Int32 { return descriptor }
        if let number = value as? NSNumber { return number.int32Value }
        return nil
    }

    // MARK: - Strategy 2

    private static func scanDescriptorTable() -> Int32? {
        var info = CtlInfo()
        info.setName(utunControlName)

        for descriptor in Int32(0)..<maxScannedDescriptor {
            var peer = SockaddrCtl()
            var length = socklen_t(MemoryLayout<SockaddrCtl>.size)
            let peerResult = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    getpeername(descriptor, sockaddrPointer, &length)
                }
            }
            guard peerResult == 0,
                  length >= socklen_t(MemoryLayout<SockaddrCtl>.size),
                  peer.scFamily == UInt8(afSystem) else {
                continue
            }

            // Resolve the kernel-control id lazily: the first control socket we see
            // gives us the id for `com.apple.net.utun_control`.
            if info.ctlID == 0 {
                guard ioctl(descriptor, ctliocginfo, &info) == 0 else { continue }
            }

            if peer.scID == info.ctlID {
                return descriptor
            }
        }

        return nil
    }
}
