import Foundation
import Darwin
import os

final class DynamicMihomoCoreBridge: @unchecked Sendable, MihomoCoreBridge {
    private typealias StartFn = @convention(c) (_ configPath: UnsafePointer<CChar>, _ workingDirectory: UnsafePointer<CChar>) -> Int32
    private typealias ReloadFn = @convention(c) (_ configPath: UnsafePointer<CChar>) -> Int32
    private typealias StopFn = @convention(c) () -> Int32
    private typealias IsRunningFn = @convention(c) () -> Int32

    private struct ResolvedSymbols {
        let start: StartFn
        let reload: ReloadFn
        let stop: StopFn
        let isRunning: IsRunningFn?
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

        let symbols = try ensureResolvedSymbolsLocked()
        let code = configPath.withCString { configCString in
            workingDirectory.withCString { workingDirCString in
                symbols.start(configCString, workingDirCString)
            }
        }

        if code != 0 {
            let detail = "code \(code)"
            logger.error("start failed: \(detail, privacy: .public)")
            throw NSError(
                domain: "DynamicMihomoCoreBridge",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Mihomo start failed (\(code)): \(detail)"]
            )
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
            let detail = "code \(code)"
            logger.error("reload failed: \(detail, privacy: .public)")
            throw NSError(
                domain: "DynamicMihomoCoreBridge",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Mihomo reload failed (\(code)): \(detail)"]
            )
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
            let detail = "code \(code)"
            logger.error("stop failed: \(detail, privacy: .public)")
            throw NSError(
                domain: "DynamicMihomoCoreBridge",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Mihomo stop failed (\(code)): \(detail)"]
            )
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

        let result = ResolvedSymbols(
            start: start,
            reload: reload,
            stop: stop,
            isRunning: isRunning
        )
        self.resolved = result
        self.loadedHandles = handles
        logger.info("MihomoCore symbols resolved")
        return result
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
