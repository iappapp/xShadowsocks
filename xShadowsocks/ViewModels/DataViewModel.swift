import Foundation

@MainActor
final class DataViewModel: ObservableObject {
    @Published var uploadToday: Double = 0
    @Published var downloadToday: Double = 0

    private let appGroupID = "group.com.github.iappapp.xShadowsocks"
    private let trafficDayStartKey = "traffic_day_start"
    private let trafficUploadBytesKey = "traffic_upload_bytes"
    private let trafficDownloadBytesKey = "traffic_download_bytes"
    private let isPreviewMode: Bool
    private var refreshTimer: Timer?

    init(isPreviewMode: Bool = false) {
        self.isPreviewMode = isPreviewMode
    }

    var totalToday: Double {
        uploadToday + downloadToday
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func onAppear() {
        guard !isPreviewMode else { return }
        refresh()
        startTimerIfNeeded()
    }

    func onDisappear() {
        guard !isPreviewMode else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func reset() {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(currentDayStartTimestamp(), forKey: trafficDayStartKey)
        defaults.set(0, forKey: trafficUploadBytesKey)
        defaults.set(0, forKey: trafficDownloadBytesKey)
        refresh()
    }

    private func startTimerIfNeeded() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refresh()
            }
        }
    }

    private func refresh() {
        guard !isPreviewMode else { return }
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            uploadToday = 0
            downloadToday = 0
            return
        }

        let todayStart = currentDayStartTimestamp()
        let storedDayStart = defaults.double(forKey: trafficDayStartKey)
        if storedDayStart != todayStart {
            defaults.set(todayStart, forKey: trafficDayStartKey)
            defaults.set(0, forKey: trafficUploadBytesKey)
            defaults.set(0, forKey: trafficDownloadBytesKey)
        }

        uploadToday = bytesToMB(defaults.double(forKey: trafficUploadBytesKey))
        downloadToday = bytesToMB(defaults.double(forKey: trafficDownloadBytesKey))
    }

    private func bytesToMB(_ value: Double) -> Double {
        value / (1024 * 1024)
    }

    private func currentDayStartTimestamp() -> TimeInterval {
        Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
    }
}

extension DataViewModel {
    static func previewMock() -> DataViewModel {
        let viewModel = DataViewModel(isPreviewMode: true)
        viewModel.uploadToday = 128.4
        viewModel.downloadToday = 512.7
        return viewModel
    }
}
