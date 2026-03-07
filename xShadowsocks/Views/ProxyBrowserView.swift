import SwiftUI

#if !targetEnvironment(simulator)
import WebKit
import Network
#endif

// MARK: - Proxy Browser View

struct ProxyBrowserView: View {
    #if targetEnvironment(simulator)
    var body: some View {
        ContentUnavailableView(
            "浏览器在模拟器中不可用",
            systemImage: "safari",
            description: Text("请在真机上使用内置浏览器")
        )
        .navigationTitle("内置浏览器")
        .navigationBarTitleDisplayMode(.inline)
    }
    #else
    @State private var urlString: String = "https://www.google.com"
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var loadTrigger = UUID()
    @State private var proxyPort: Int = ProxyBrowserView.loadConfiguredProxyPort()
    let proxyHost: String = "127.0.0.1"

    var body: some View {
        VStack(spacing: 0) {
            // Address Bar
            HStack {
                TextField("URL", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { go() }

                Button("Go") { go() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading)
            }
            .padding()

            // Content Area
            ZStack {
                ProxyWebView(
                    urlString: $urlString,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage,
                    loadTrigger: loadTrigger,
                    proxyHost: proxyHost,
                    proxyPort: proxyPort
                )
                .edgesIgnoringSafeArea(.bottom)

                if let error = errorMessage, !isLoading {
                    Color(.systemBackground)
                    ContentUnavailableView(
                        "Connection Failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                }

                if isLoading {
                    VStack {
                        Spacer()
                        ProgressView()
                            .tint(.blue)
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        Spacer().frame(height: 20)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            proxyPort = Self.loadConfiguredProxyPort()
        }
    }

    private static func loadConfiguredProxyPort() -> Int {
        let rawValue = AppGroupStore.shared.loadInt(forKey: AppGroupStore.shared.proxyPortKey, default: 7890)
        return min(max(rawValue, 2000), 9000)
    }

    private func go() {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let lowered = trimmed.lowercased()
        if !lowered.hasPrefix("http://") && !lowered.hasPrefix("https://") {
            if trimmed.contains(".") && !trimmed.contains(" ") {
                urlString = "https://\(trimmed)"
            } else {
                errorMessage = "Invalid URL"
                return
            }
        } else {
            urlString = trimmed
        }

        errorMessage = nil
        loadTrigger = UUID()
    }
    #endif
}

// MARK: - WKWebView with Native Proxy Configuration (iOS 17+)

#if !targetEnvironment(simulator)
/// Uses `WKWebsiteDataStore.proxyConfigurations` to route all WKWebView
/// traffic through a local HTTP CONNECT proxy — no URL rewriting,
/// no custom scheme handlers, no JS monkey-patching needed.
struct ProxyWebView: UIViewRepresentable {
    @Binding var urlString: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let loadTrigger: UUID
    let proxyHost: String
    let proxyPort: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: ProxyWebView
        var lastTrigger: UUID?

        init(_ parent: ProxyWebView) {
            self.parent = parent
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.errorMessage = nil
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let url = webView.url?.absoluteString {
                DispatchQueue.main.async {
                    self.parent.urlString = url
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.errorMessage = nil
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.errorMessage = error.localizedDescription
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.errorMessage = error.localizedDescription
            }
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            if let url = webView.url?.absoluteString {
                DispatchQueue.main.async {
                    self.parent.urlString = url
                }
            }
        }

        // MARK: - WKUIDelegate

        // Handle target="_blank" links
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == false {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        // Set up HTTP CONNECT proxy via native API
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(proxyPort)) else {
            context.coordinator.parent.errorMessage = "代理端口无效：\(proxyPort)"
            return WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        }

        let proxyEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxyHost),
            port: nwPort
        )
        let proxyConfig = ProxyConfiguration(httpCONNECTProxy: proxyEndpoint)

        let dataStore = WKWebsiteDataStore.nonPersistent()
        dataStore.proxyConfigurations = [proxyConfig]

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Initial load
        if let url = URL(string: context.coordinator.parent.urlString) {
            context.coordinator.lastTrigger = loadTrigger
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self

        // Only load on explicit Go trigger
        if context.coordinator.lastTrigger != loadTrigger {
            context.coordinator.lastTrigger = loadTrigger
            if let url = URL(string: urlString) {
                uiView.load(URLRequest(url: url))
            }
        }
    }
}
#endif

