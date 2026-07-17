import Foundation
import Darwin
import os

final class DynamicMihomoCoreBridge: @unchecked Sendable, MihomoCoreBridge {
    private typealias StartFn = @convention(c) (_ configPath: UnsafePointer<CChar>, _ workingDirectory: UnsafePointer<CChar>) -> Int32
    private typealias ReloadFn = @convention(c) (_ configPath: UnsafePointer<CChar>) -> Int32
    private typealias StopFn = @convention(c) () -> Int32
    private typealias IsRunningFn = @convention(c) () -> Int32
    private typealias LastErrorFn = @convention(c) () -> UnsafeMutablePointer<CChar>?

    private struct ResolvedSymbols {
        let start: StartFn
        let reload: ReloadFn
        let stop: StopFn
        let isRunning: IsRunningFn?
        let lastError: LastErrorFn?
    }

    private let lock = NSLock()
    private var resolved: ResolvedSymbols?
    private var loadedHandles: [UnsafeMutableRawPointer] = []
    private var fallbackRunningState = false
    private let logger = Logger(subsystem: "com.github.iappapp.xShadowsocks", category: "MihomoBridge")

    private let symbolStartCandidates = ["mihomo_start_with_config", "mihomo_start"]
    private let symbolReloadCandidates = ["mihomo_reload_config", "mihomo_reload"]
    private let symbolStopCandidates = ["mihomo_stop"]
    private let symbolIsRunningCandidates = ["mihomo_is_running"]
    private let symbolLastErrorCandidates = ["mihomo_get_last_error"]

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }

        do {
            let symbols = try ensureResolvedSymbolsLocked()
            if let isRunning = symbols.isRunning {
                return isRunning() != 0
            }
            return fallbackRunningState
        } catch {
            return fallbackRunningState
        }
    }

    func start(configPath: String, workingDirectory: String) throws {
        lock.lock()
        defer { lock.unlock() }

        logger.info("start config=\(configPath, privacy: .public) workdir=\(workingDirectory, privacy: .public)")
        logLocalFileState(configPath: configPath, workingDirectory: workingDirectory)

        let symbols = try ensureResolvedSymbolsLocked()
        let code = configPath.withCString { configCString in
            workingDirectory.withCString { workingDirCString in
                symbols.start(configCString, workingDirCString)
            }
        }

        if code != 0 {
            let detail = readLastErrorLocked(from: symbols) ?? "code \(code)"
            let logTail = readBridgeLogTail(workingDirectory: workingDirectory)
            logger.error("start failed: \(detail, privacy: .public)")
            if !logTail.isEmpty {
                logger.error("bridge log tail:\n\(logTail, privacy: .public)")
            }
            throw makeOperationError(operation: "start", code: code, detail: detail, logTail: logTail)
        }

        logger.info("start success")
        fallbackRunningState = true
    }

    func reload(configPath: String) throws {
        lock.lock()
        defer { lock.unlock() }

        logger.info("reload config=\(configPath, privacy: .public)")
        let symbols = try ensureResolvedSymbolsLocked()
        let code = configPath.withCString { configCString in
            symbols.reload(configCString)
        }

        if code != 0 {
            let detail = readLastErrorLocked(from: symbols) ?? "code \(code)"
            logger.error("reload failed: \(detail, privacy: .public)")
            throw makeOperationError(operation: "reload", code: code, detail: detail, logTail: "")
        }

        logger.info("reload success")
        fallbackRunningState = true
    }

    func stop() throws {
        lock.lock()
        defer { lock.unlock() }

        logger.info("stop begin")
        let symbols = try ensureResolvedSymbolsLocked()
        let code = symbols.stop()
        if code != 0 {
            let detail = readLastErrorLocked(from: symbols) ?? "code \(code)"
            logger.error("stop failed: \(detail, privacy: .public)")
            throw makeOperationError(operation: "stop", code: code, detail: detail, logTail: "")
        }

        logger.info("stop success")
        fallbackRunningState = false
    }

    private func ensureResolvedSymbolsLocked() throws -> ResolvedSymbols {
        if let resolved {
            return resolved
        }

        var handles: [UnsafeMutableRawPointer] = []

        if let mainHandle = dlopen(nil, RTLD_NOW) {
            handles.append(mainHandle)
        }

        let frameworkCandidates = frameworkPaths()
        for path in frameworkCandidates {
            if let handle = dlopen(path, RTLD_NOW) {
                logger.debug("dlopen ok: \(path, privacy: .public)")
                handles.append(handle)
            } else {
                let err = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
                logger.warning("dlopen failed: \(path, privacy: .public) err=\(err, privacy: .public)")
            }
        }

        guard !handles.isEmpty else {
            throw makeBridgeNotReadyError(
                reason: "无法加载 MihomoCore 动态库",
                frameworkCandidates: frameworkCandidates,
                missingSymbols: []
            )
        }

        guard let start = resolveSymbol(candidates: symbolStartCandidates, handles: handles, as: StartFn.self),
              let reload = resolveSymbol(candidates: symbolReloadCandidates, handles: handles, as: ReloadFn.self),
              let stop = resolveSymbol(candidates: symbolStopCandidates, handles: handles, as: StopFn.self) else {
            throw makeBridgeNotReadyError(
                reason: "MihomoCore 已加载但未找到必要桥接符号",
                frameworkCandidates: frameworkCandidates,
                missingSymbols: [
                    symbolStartCandidates.joined(separator: "|"),
                    symbolReloadCandidates.joined(separator: "|"),
                    symbolStopCandidates.joined(separator: "|")
                ]
            )
        }

        let isRunning = resolveSymbol(candidates: symbolIsRunningCandidates, handles: handles, as: IsRunningFn.self)
        let lastError = resolveSymbol(candidates: symbolLastErrorCandidates, handles: handles, as: LastErrorFn.self)
        if lastError == nil {
            logger.warning("mihomo_get_last_error symbol not found; detail errors unavailable")
        }

        let result = ResolvedSymbols(
            start: start,
            reload: reload,
            stop: stop,
            isRunning: isRunning,
            lastError: lastError
        )
        self.resolved = result
        self.loadedHandles = handles
        logger.info("MihomoCore symbols resolved")
        return result
    }

    private func readLastErrorLocked(from symbols: ResolvedSymbols) -> String? {
        guard let lastError = symbols.lastError else { return nil }
        guard let ptr = lastError() else { return nil }
        defer { free(ptr) }
        let message = String(cString: ptr)
        return message.isEmpty ? nil : message
    }

    private func logLocalFileState(configPath: String, workingDirectory: String) {
        let fm = FileManager.default
        let configExists = fm.fileExists(atPath: configPath)
        let mmdbPath = (workingDirectory as NSString).appendingPathComponent("Country.mmdb")
        let mmdbExists = fm.fileExists(atPath: mmdbPath)
        var sizeText = "n/a"
        if let attrs = try? fm.attributesOfItem(atPath: configPath),
           let size = attrs[.size] as? NSNumber {
            sizeText = "\(size.intValue)"
        }
        logger.info("fs configExists=\(configExists) size=\(sizeText, privacy: .public) mmdbExists=\(mmdbExists)")
    }

    private func readBridgeLogTail(workingDirectory: String, maxBytes: Int = 4_096) -> String {
        let logURL = URL(fileURLWithPath: workingDirectory).appendingPathComponent("mihomo-bridge.log")
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return "" }
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    private func makeOperationError(operation: String, code: Int32, detail: String, logTail: String) -> NSError {
        var message = "Mihomo \(operation) failed (\(code)): \(detail)"
        if !logTail.isEmpty {
            let clipped = logTail.split(separator: "\n").suffix(8).joined(separator: "\n")
            message += "\n—— bridge log ——\n\(clipped)"
        }
        return NSError(
            domain: "DynamicMihomoCoreBridge",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func makeBridgeNotReadyError(reason: String, frameworkCandidates: [String], missingSymbols: [String]) -> NSError {
        var message = "\(reason)。请确认已将 MihomoCore.xcframework 设为 Embed & Sign。"
        if !missingSymbols.isEmpty {
            message += " 需要导出符号: \(missingSymbols.joined(separator: ", "))。"
        }
        if !frameworkCandidates.isEmpty {
            message += " 已尝试路径: \(frameworkCandidates.joined(separator: ", "))。"
        }

        logger.error("\(message, privacy: .public)")
        return NSError(
            domain: "DynamicMihomoCoreBridge",
            code: -10001,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func frameworkPaths() -> [String] {
        var candidates: [String] = []

        if let privateFrameworks = Bundle.main.privateFrameworksPath {
            candidates.append((privateFrameworks as NSString).appendingPathComponent("MihomoCore.framework/MihomoCore"))
        }

        let frameworksURL = Bundle.main.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        candidates.append(frameworksURL.appendingPathComponent("MihomoCore.framework/MihomoCore").path)

        return candidates
    }

    private func resolveSymbol<T>(candidates: [String], handles: [UnsafeMutableRawPointer], as type: T.Type) -> T? {
        for symbol in candidates {
            for handle in handles {
                if let rawSymbol = dlsym(handle, symbol) {
                    return unsafeBitCast(rawSymbol, to: T.self)
                }
            }
        }
        return nil
    }
}
