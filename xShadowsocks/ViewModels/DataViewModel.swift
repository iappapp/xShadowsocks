import Foundation
import NetworkExtension

@MainActor
final class DataViewModel: ObservableObject {
    @Published var uploadToday: Double = 0
    @Published var downloadToday: Double = 0
    @Published var liveUpload: Double = 0
    @Published var liveDownload: Double = 0
    @Published var isConnected = false

    private let isPreviewMode: Bool
    private let store = AppGroupStore.shared
    private var refreshTimer: Timer?

    init(isPreviewMode: Bool = false) {
        self.isPreviewMode = isPreviewMode
    }

    var totalToday: Double {
        uploadToday + downloadToday
    }

    deinit {
        refreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func onAppear() {
        guard !isPreviewMode else { return }
        refresh()
        startTimerIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statusChanged),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }

    func onDisappear() {
        guard !isPreviewMode else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
        NotificationCenter.default.removeObserver(self, name: .NEVPNStatusDidChange, object: nil)
    }

    func reset() {
        store.resetTodayTrafficBytes()
        refresh()
    }

    @objc private func statusChanged() {
        Task { @MainActor in await syncLiveState() }
    }

    private func startTimerIfNeeded() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refresh()
                await self.syncLiveState()
            }
        }
    }

    /// Today's counters come from the store, whichever process wrote them.
    private func refresh() {
        guard !isPreviewMode else { return }
        let today = store.loadTodayTrafficBytes()
        uploadToday = bytesToMB(today.upload)
        downloadToday = bytesToMB(today.download)
    }

    /// Per-session totals for the running core. In loopback mode the app owns the core,
    /// so it reads them directly; in tunnel mode it asks the extension over
    /// `sendProviderMessage`.
    private func syncLiveState() async {
        guard !isPreviewMode else { return }

        let loopbackRunning = LocalProxyHost.shared.isRunning
        let tunnelConnected = loopbackRunning ? false : await TunnelManager.shared.isConnected()
        isConnected = loopbackRunning || tunnelConnected
        guard isConnected else {
            liveUpload = 0
            liveDownload = 0
            return
        }

        let totals: (upload: Double, download: Double)
        if loopbackRunning {
            await MihomoCoreHost.shared.pollTraffic()
            totals = MihomoCoreHost.shared.currentSessionTotals()
        } else {
            guard let reply = try? await TunnelManager.shared.send(.trafficSnapshot),
                  let payload = reply.snapshot else {
                return
            }
            totals = (payload.uploadTotal, payload.downloadTotal)
        }

        liveUpload = bytesToMB(totals.upload)
        liveDownload = bytesToMB(totals.download)
        // Both paths flush before answering, so the daily counters moved too.
        refresh()
    }

    private func bytesToMB(_ value: Double) -> Double {
        value / (1024 * 1024)
    }
}

extension DataViewModel {
    static func previewMock() -> DataViewModel {
        let viewModel = DataViewModel(isPreviewMode: true)
        viewModel.uploadToday = 128.4
        viewModel.downloadToday = 512.7
        viewModel.liveUpload = 132.1
        viewModel.liveDownload = 540.9
        viewModel.isConnected = true
        return viewModel
    }
}
