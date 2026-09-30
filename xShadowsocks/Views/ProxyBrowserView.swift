import SwiftUI

#if !targetEnvironment(simulator)
import WebKit
#endif

// MARK: - Proxy browser

/// A web view used to sanity-check local proxy mode.
///
/// In loopback mode the core listens on this device, so the web view is pointed at that
/// port through `WKWebsiteDataStore.proxyConfigurations` — no URL rewriting or JS
/// patching, and the traffic demonstrably goes through mihomo. In tunnel mode the
/// default route already carries this app's traffic, so no proxy configuration is
/// needed (and pointing at the port would be wrong: that listener belongs to the
/// extension process).
struct ProxyBrowserView: View {
    #if targetEnvironment(simulator)
    var body: some View {
        ContentUnavailableView(
            "浏览器在模拟器中不可用",
            systemImage: "safari",
            description: Text("请在真机上使用")
        )
        .navigationTitle("内置浏览器")
        .navigationBarTitleDisplayMode(.inline)
    }
    #else
    @State private var urlString: String = "https://www.google.com"
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var loadToken = UUID()
    @State private var proxyEndpoint: LocalProxyEndpoint = .direct

    var body: some View {
        VStack(spacing: 0) {
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

            ZStack {
                ProxyWebView(
                    urlString: $urlString,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage,
                    loadToken: loadToken,
                    proxyEndpoint: proxyEndpoint
                )
                // The proxy is a property of the web view's data store, so switching
                // modes rebuilds the view rather than reusing it.
                .id(proxyEndpoint)
                .edgesIgnoringSafeArea(.bottom)

                if let error = errorMessage, !isLoading {
                    Color(.systemBackground)
                    ContentUnavailableView(
                        "加载失败",
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

            Text(proxyEndpoint.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            proxyEndpoint = LocalProxyEndpoint.current()
        }
    }

    private func go() {
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let lowered = trimmed.lowercased()
        if !lowered.hasPrefix("http://") && !lowered.hasPrefix("https://") {
            guard trimmed.contains("."), !trimmed.contains(" ") else {
                errorMessage = "无效的网址"
                return
            }
            trimmed = "https://\(trimmed)"
        }

        urlString = trimmed
        errorMessage = nil
        // Bumping the token is what actually triggers the load in the representable.
        loadToken = UUID()
    }
    #endif
}

/// Where the in-app browser should send its traffic.
enum LocalProxyEndpoint: Hashable {
    /// No proxy configuration: the system routes the request, through the tunnel when
    /// one is active.
    case direct
    /// Talk to the core running in this process.
    case httpConnect(host: String, port: Int)

    @MainActor
    static func current() -> LocalProxyEndpoint {
        guard LocalProxyHost.shared.isRunning else { return .direct }
        return .httpConnect(host: "127.0.0.1", port: LocalProxyHost.shared.proxyPort)
    }

    var description: String {
        switch self {
        case .direct:
            return "未启用本地代理，流量由系统路由"
        case .httpConnect(let host, let port):
            return "经本地代理 \(host):\(port)"
        }
    }
}

#if !targetEnvironment(simulator)
struct ProxyWebView: UIViewRepresentable {
    @Binding var urlString: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?

    let loadToken: UUID
    let proxyEndpoint: LocalProxyEndpoint

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: ProxyWebView
        var lastLoadedToken: UUID?

        init(_ parent: ProxyWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            parent.errorMessage = nil
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let url = webView.url?.absoluteString {
                parent.urlString = url
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.errorMessage = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(
            _ webView: WKWebView,
            didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
        ) {
            if let url = webView.url?.absoluteString {
                parent.urlString = url
            }
        }

        // Open target="_blank" links in the same web view.
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

        private func report(_ error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            parent.isLoading = false
            parent.errorMessage = error.localizedDescription
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.lastLoadedToken = loadToken
        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastLoadedToken != loadToken else { return }
        context.coordinator.lastLoadedToken = loadToken
        if let url = URL(string: urlString) {
            uiView.load(URLRequest(url: url))
        }
    }

    /// The data store is rebuilt per web view because `proxyConfigurations` is a
    /// property of the data store, not of a request — the proxy cannot be swapped on an
    /// existing view. `updateUIView` therefore compares the endpoint and lets SwiftUI
    /// recreate the view when it changes (the endpoint is part of the view's identity
    /// through `id`).
    private func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        let dataStore = WKWebsiteDataStore.nonPersistent()
        if case .httpConnect(let host, let port) = proxyEndpoint,
           let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) {
            dataStore.proxyConfigurations = [
                ProxyConfiguration(
                    httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(host), port: nwPort)
                )
            ]
        }
        configuration.websiteDataStore = dataStore
        return configuration
    }
}
#endif
