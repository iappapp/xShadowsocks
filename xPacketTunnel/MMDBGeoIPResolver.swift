import Foundation
import Network

final class MMDBGeoIPResolver: GeoIPResolving {
    private let db: MMDBDatabase?

    init(appGroupID: String?, explicitPath: String? = nil, fileManager: FileManager = .default) {
        let candidateURLs = Self.makeCandidateURLs(appGroupID: appGroupID, explicitPath: explicitPath, fileManager: fileManager)
        var loaded: MMDBDatabase?

        for url in candidateURLs where fileManager.fileExists(atPath: url.path) {
            if let db = try? MMDBDatabase(fileURL: url) {
                loaded = db
                break
            }
        }

        self.db = loaded
    }

    func countryCode(for ip: String) -> String? {
        guard let db else { return nil }
        return db.countryCode(for: ip)
    }

    private static func makeCandidateURLs(appGroupID: String?, explicitPath: String?, fileManager: FileManager) -> [URL] {
        var urls: [URL] = []

        if let explicitPath, !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            urls.append(URL(fileURLWithPath: explicitPath))
        }

        let fileNames = ["Country.mmdb", "country.mmdb", "GeoLite2-Country.mmdb"]

        func appendFileNames(base: URL?) {
            guard let base else { return }
            for fileName in fileNames {
                urls.append(base.appendingPathComponent(fileName))
            }
        }

        if let appGroupID,
           let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            appendFileNames(base: groupURL)
            appendFileNames(base: groupURL.appendingPathComponent("Library/Application Support", isDirectory: true))
            appendFileNames(base: groupURL.appendingPathComponent("Documents", isDirectory: true))
        }

        appendFileNames(base: fileManager.urls(for: .documentDirectory, in: .userDomainMask).first)
        appendFileNames(base: fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("Application Support", isDirectory: true))
        appendFileNames(base: fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first)

        return Array(Set(urls))
    }
}

private enum MMDBError: Error {
    case invalidFile
    case missingMetadata
    case unsupportedRecordSize
    case unsupportedDatabaseType
}

private struct MMDBMetadata {
    let nodeCount: Int
    let recordSize: Int
    let ipVersion: Int
}

private enum MMDBValue {
    case map([String: MMDBValue])
    case array([MMDBValue])
    case string(String)
    case uint(UInt64)
    case int(Int64)
    case bool(Bool)
    case double(Double)
    case float(Float)
    case bytes(Data)
    case null

    var mapValue: [String: MMDBValue]? {
        if case let .map(value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var uintValue: UInt64? {
        switch self {
        case let .uint(value):
            return value
        case let .int(value):
            return value >= 0 ? UInt64(value) : nil
        default:
            return nil
        }
    }
}

private final class MMDBDatabase {
    private let data: Data
    private let metadata: MMDBMetadata
    private let searchTreeSize: Int
    private let nodeByteSize: Int
    private let dataSectionStart: Int

    init(fileURL: URL) throws {
        self.data = try Data(contentsOf: fileURL)
        self.metadata = try MMDBDatabase.parseMetadata(from: data)

        guard [24, 28, 32].contains(metadata.recordSize) else {
            throw MMDBError.unsupportedRecordSize
        }

        self.nodeByteSize = (metadata.recordSize * 2) / 8
        self.searchTreeSize = metadata.nodeCount * nodeByteSize
        self.dataSectionStart = searchTreeSize + 16

        guard dataSectionStart < data.count else {
            throw MMDBError.invalidFile
        }
    }

    func countryCode(for ip: String) -> String? {
        let bits: [UInt8]
        let startNode: Int

        if let ipv4 = IPv4Address(ip) {
            bits = Self.bits(from: Array(ipv4.rawValue), bitCount: 32)
            startNode = metadata.ipVersion == 6 ? ipv4StartNode() : 0
        } else if let ipv6 = IPv6Address(ip) {
            bits = Self.bits(from: Array(ipv6.rawValue), bitCount: 128)
            startNode = 0
        } else {
            return nil
        }

        guard let pointer = lookupPointer(bits: bits, startNode: startNode),
              let value = decodeValue(atAbsoluteOffset: pointer).value,
              let map = value.mapValue else {
            return nil
        }

        if let code = map["country"]?.mapValue?["iso_code"]?.stringValue {
            return code
        }

        if let code = map["registered_country"]?.mapValue?["iso_code"]?.stringValue {
            return code
        }

        return map["represented_country"]?.mapValue?["iso_code"]?.stringValue
    }

    private func ipv4StartNode() -> Int {
        var node = 0
        for _ in 0..<96 {
            guard node < metadata.nodeCount else { break }
            node = readChild(node: node, bit: 0)
        }
        return node
    }

    private func lookupPointer(bits: [UInt8], startNode: Int) -> Int? {
        var node = startNode

        for bit in bits {
            guard node < metadata.nodeCount else { break }
            node = readChild(node: node, bit: Int(bit))
        }

        guard node > metadata.nodeCount else {
            return nil
        }

        let relative = node - metadata.nodeCount
        return dataSectionStart + relative
    }

    private func readChild(node: Int, bit: Int) -> Int {
        let offset = node * nodeByteSize
        switch metadata.recordSize {
        case 24:
            if bit == 0 {
                return readUInt24(at: offset)
            }
            return readUInt24(at: offset + 3)

        case 28:
            let b0 = Int(data[offset])
            let b1 = Int(data[offset + 1])
            let b2 = Int(data[offset + 2])
            let b3 = Int(data[offset + 3])
            let b4 = Int(data[offset + 4])
            let b5 = Int(data[offset + 5])
            let b6 = Int(data[offset + 6])

            if bit == 0 {
                return (b0 << 20) | (b1 << 12) | (b2 << 4) | (b3 >> 4)
            }
            return ((b3 & 0x0F) << 24) | (b4 << 16) | (b5 << 8) | b6

        default:
            if bit == 0 {
                return readUInt32(at: offset)
            }
            return readUInt32(at: offset + 4)
        }
    }

    private func readUInt24(at offset: Int) -> Int {
        (Int(data[offset]) << 16) | (Int(data[offset + 1]) << 8) | Int(data[offset + 2])
    }

    private func readUInt32(at offset: Int) -> Int {
        (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16) | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
    }

    private func decodeValue(atAbsoluteOffset offset: Int) -> (value: MMDBValue?, nextOffset: Int) {
        guard offset < data.count else { return (nil, offset) }

        let control = data[offset]
        var cursor = offset + 1

        var type = Int(control >> 5)
        let payload = Int(control & 0x1F)

        if type == 0 {
            guard cursor < data.count else { return (nil, cursor) }
            type = Int(data[cursor]) + 7
            cursor += 1
        }

        if type == 1 {
            guard let pointerResult = decodePointer(payload: payload, at: cursor) else {
                return (nil, cursor)
            }
            let absolute = dataSectionStart + pointerResult.pointer
            return decodeValue(atAbsoluteOffset: absolute)
        }

        let sizeResult = decodeSize(payload: payload, at: cursor)
        let size = sizeResult.size
        cursor = sizeResult.cursor

        guard cursor + size <= data.count else { return (nil, cursor) }

        switch type {
        case 2:
            let sub = data.subdata(in: cursor..<(cursor + size))
            let string = String(data: sub, encoding: .utf8) ?? ""
            return (.string(string), cursor + size)

        case 3:
            guard size == 8 else { return (nil, cursor + size) }
            let value = data.subdata(in: cursor..<(cursor + size)).withUnsafeBytes { raw -> Double in
                let bits = raw.load(as: UInt64.self).bigEndian
                return Double(bitPattern: bits)
            }
            return (.double(value), cursor + size)

        case 4:
            return (.bytes(data.subdata(in: cursor..<(cursor + size))), cursor + size)

        case 5, 6, 9, 10:
            var value: UInt64 = 0
            for i in 0..<size {
                value = (value << 8) | UInt64(data[cursor + i])
            }
            return (.uint(value), cursor + size)

        case 7:
            var map: [String: MMDBValue] = [:]
            var next = cursor
            for _ in 0..<size {
                let keyResult = decodeValue(atAbsoluteOffset: next)
                guard case let .string(key)? = keyResult.value else { return (nil, next) }
                next = keyResult.nextOffset

                let valueResult = decodeValue(atAbsoluteOffset: next)
                guard let value = valueResult.value else { return (nil, next) }
                map[key] = value
                next = valueResult.nextOffset
            }
            return (.map(map), next)

        case 8:
            var value: Int64 = 0
            for i in 0..<size {
                value = (value << 8) | Int64(data[cursor + i])
            }
            return (.int(value), cursor + size)

        case 11:
            var array: [MMDBValue] = []
            var next = cursor
            for _ in 0..<size {
                let item = decodeValue(atAbsoluteOffset: next)
                guard let value = item.value else { return (nil, next) }
                array.append(value)
                next = item.nextOffset
            }
            return (.array(array), next)

        case 14:
            return (.bool(payload != 0), cursor)

        case 15:
            guard size == 4 else { return (nil, cursor + size) }
            let value = data.subdata(in: cursor..<(cursor + size)).withUnsafeBytes { raw -> Float in
                let bits = raw.load(as: UInt32.self).bigEndian
                return Float(bitPattern: bits)
            }
            return (.float(value), cursor + size)

        default:
            return (.null, cursor + size)
        }
    }

    private func decodePointer(payload: Int, at cursor: Int) -> (pointer: Int, cursor: Int)? {
        let pointerSize = (payload >> 3) & 0x3
        let base = payload & 0x7

        switch pointerSize {
        case 0:
            guard cursor < data.count else { return nil }
            let value = (base << 8) | Int(data[cursor])
            return (value, cursor + 1)

        case 1:
            guard cursor + 1 < data.count else { return nil }
            let value = (base << 16) | (Int(data[cursor]) << 8) | Int(data[cursor + 1])
            return (value + 2048, cursor + 2)

        case 2:
            guard cursor + 2 < data.count else { return nil }
            let value = (base << 24) | (Int(data[cursor]) << 16) | (Int(data[cursor + 1]) << 8) | Int(data[cursor + 2])
            return (value + 526_336, cursor + 3)

        default:
            guard cursor + 3 < data.count else { return nil }
            let value = (Int(data[cursor]) << 24)
                | (Int(data[cursor + 1]) << 16)
                | (Int(data[cursor + 2]) << 8)
                | Int(data[cursor + 3])
            return (value, cursor + 4)
        }
    }

    private func decodeSize(payload: Int, at cursor: Int) -> (size: Int, cursor: Int) {
        if payload < 29 {
            return (payload, cursor)
        }

        if payload == 29 {
            let size = Int(data[cursor]) + 29
            return (size, cursor + 1)
        }

        if payload == 30 {
            let size = (Int(data[cursor]) << 8) | Int(data[cursor + 1])
            return (size + 285, cursor + 2)
        }

        let size = (Int(data[cursor]) << 16) | (Int(data[cursor + 1]) << 8) | Int(data[cursor + 2])
        return (size + 65_821, cursor + 3)
    }

    private static func parseMetadata(from data: Data) throws -> MMDBMetadata {
        let marker = Data([0xAB, 0xCD, 0xEF]) + "MaxMind.com".data(using: .utf8)!
        guard let range = data.lastRange(of: marker) else {
            throw MMDBError.missingMetadata
        }

        let start = range.upperBound
        let decoder = MMDBRawDecoder(data: data, dataSectionStart: 0)
        guard let value = decoder.decodeValue(atAbsoluteOffset: start).value,
              let map = value.mapValue else {
            throw MMDBError.missingMetadata
        }

        guard let nodeCount = map["node_count"]?.uintValue,
              let recordSize = map["record_size"]?.uintValue,
              let ipVersion = map["ip_version"]?.uintValue else {
            throw MMDBError.missingMetadata
        }

        return MMDBMetadata(nodeCount: Int(nodeCount), recordSize: Int(recordSize), ipVersion: Int(ipVersion))
    }

    private static func bits(from bytes: [UInt8], bitCount: Int) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bitCount)

        for index in 0..<bitCount {
            let byteIndex = index / 8
            let bitIndex = 7 - (index % 8)
            let bit = (bytes[byteIndex] >> bitIndex) & 0x01
            result.append(bit)
        }

        return result
    }
}

private struct MMDBRawDecoder {
    let data: Data
    let dataSectionStart: Int

    func decodeValue(atAbsoluteOffset offset: Int) -> (value: MMDBValue?, nextOffset: Int) {
        guard offset < data.count else { return (nil, offset) }

        let control = data[offset]
        var cursor = offset + 1

        var type = Int(control >> 5)
        let payload = Int(control & 0x1F)

        if type == 0 {
            guard cursor < data.count else { return (nil, cursor) }
            type = Int(data[cursor]) + 7
            cursor += 1
        }

        if type == 1 {
            guard let pointerResult = decodePointer(payload: payload, at: cursor) else {
                return (nil, cursor)
            }
            let absolute = dataSectionStart + pointerResult.pointer
            return decodeValue(atAbsoluteOffset: absolute)
        }

        let sizeResult = decodeSize(payload: payload, at: cursor)
        let size = sizeResult.size
        cursor = sizeResult.cursor
        guard cursor + size <= data.count else { return (nil, cursor) }

        switch type {
        case 2:
            let sub = data.subdata(in: cursor..<(cursor + size))
            return (.string(String(data: sub, encoding: .utf8) ?? ""), cursor + size)

        case 5, 6, 9, 10:
            var value: UInt64 = 0
            for i in 0..<size {
                value = (value << 8) | UInt64(data[cursor + i])
            }
            return (.uint(value), cursor + size)

        case 7:
            var map: [String: MMDBValue] = [:]
            var next = cursor
            for _ in 0..<size {
                let keyResult = decodeValue(atAbsoluteOffset: next)
                guard case let .string(key)? = keyResult.value else { return (nil, next) }
                next = keyResult.nextOffset

                let valueResult = decodeValue(atAbsoluteOffset: next)
                guard let value = valueResult.value else { return (nil, next) }
                map[key] = value
                next = valueResult.nextOffset
            }
            return (.map(map), next)

        default:
            return (.null, cursor + size)
        }
    }

    private func decodePointer(payload: Int, at cursor: Int) -> (pointer: Int, cursor: Int)? {
        let pointerSize = (payload >> 3) & 0x3
        let base = payload & 0x7

        switch pointerSize {
        case 0:
            guard cursor < data.count else { return nil }
            let value = (base << 8) | Int(data[cursor])
            return (value, cursor + 1)

        case 1:
            guard cursor + 1 < data.count else { return nil }
            let value = (base << 16) | (Int(data[cursor]) << 8) | Int(data[cursor + 1])
            return (value + 2048, cursor + 2)

        case 2:
            guard cursor + 2 < data.count else { return nil }
            let value = (base << 24) | (Int(data[cursor]) << 16) | (Int(data[cursor + 1]) << 8) | Int(data[cursor + 2])
            return (value + 526_336, cursor + 3)

        default:
            guard cursor + 3 < data.count else { return nil }
            let value = (Int(data[cursor]) << 24)
                | (Int(data[cursor + 1]) << 16)
                | (Int(data[cursor + 2]) << 8)
                | Int(data[cursor + 3])
            return (value, cursor + 4)
        }
    }

    private func decodeSize(payload: Int, at cursor: Int) -> (size: Int, cursor: Int) {
        if payload < 29 {
            return (payload, cursor)
        }

        if payload == 29 {
            return (Int(data[cursor]) + 29, cursor + 1)
        }

        if payload == 30 {
            let size = (Int(data[cursor]) << 8) | Int(data[cursor + 1])
            return (size + 285, cursor + 2)
        }

        let size = (Int(data[cursor]) << 16) | (Int(data[cursor + 1]) << 8) | Int(data[cursor + 2])
        return (size + 65_821, cursor + 3)
    }
}
