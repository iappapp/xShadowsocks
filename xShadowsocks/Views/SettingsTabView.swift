import SwiftUI

struct SettingsTabView: View {
    @StateObject private var viewModel: SettingsViewModel

    @MainActor init(viewModel: SettingsViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? SettingsViewModel())
    }

    var body: some View {
        Form {
            Section("订阅") {
                TextField("订阅 URL", text: $viewModel.subscriptionURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Toggle("打开时更新", isOn: $viewModel.updateOnLaunch)
                Toggle("后台自动更新", isOn: $viewModel.backgroundUpdate)

                Picker("更新间隔", selection: $viewModel.updateInterval) {
                    ForEach(UpdateInterval.allCases) { interval in
                        Text(interval.title).tag(interval.rawValue)
                    }
                }
                .disabled(!viewModel.backgroundUpdate)

                if viewModel.lastUpdateTimestamp > 0 {
                    LabeledContent(
                        "上次更新",
                        value: Date(timeIntervalSince1970: viewModel.lastUpdateTimestamp)
                            .formatted(date: .abbreviated, time: .shortened)
                    )
                }

                Button {
                    viewModel.updateSubscriptionNow()
                } label: {
                    HStack {
                        Text("立即更新订阅")
                        Spacer()
                        if viewModel.isUpdatingSubscription {
                            ProgressView()
                        }
                    }
                }
                .disabled(!viewModel.canUpdateSubscription)
            }

            Section("网络") {
                Toggle("允许蜂窝网络", isOn: $viewModel.allowCellular)
                Toggle("允许局域网访问", isOn: $viewModel.allowLANAccess)
                Toggle("优先 IPv6", isOn: $viewModel.preferIPv6)
            }

            Section("全局路由") {
                Picker("模式", selection: $viewModel.routeMode) {
                    ForEach(RouteMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            }

            Section {
                Picker("代理引擎", selection: $viewModel.proxyEngine) {
                    ForEach(ProxyEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
            } header: {
                Text("代理引擎")
            } footer: {
                Text(viewModel.proxyEngine.subtitle)
            }

            Section("代理端口") {
                HStack {
                    Text("端口")
                    TextField("7890", text: $viewModel.proxyPortText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                if let validationMessage = viewModel.proxyPortValidationMessage {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("数据管理") {
                Button("清除保存的节点配置") {
                    viewModel.clearSavedNodeConfig()
                }

                Button("恢复默认设置", role: .destructive) {
                    viewModel.showResetAlert = true
                }
            }

            if let updateMessage = viewModel.updateMessage {
                Section("状态") {
                    Text(updateMessage)
                        .foregroundStyle(updateMessage.contains("成功") ? .green : .red)
                }
            }
        }
        .onAppear {
            viewModel.onAppear()
        }
        .onChange(of: viewModel.subscriptionURL) { _, _ in viewModel.persist() }
        .onChange(of: viewModel.updateOnLaunch) { _, _ in viewModel.persist() }
        .onChange(of: viewModel.backgroundUpdate) { _, _ in viewModel.persist() }
        .onChange(of: viewModel.updateInterval) { _, _ in viewModel.persist() }
        .onChange(of: viewModel.allowCellular) { _, _ in viewModel.persist() }
        .onChange(of: viewModel.allowLANAccess) { _, _ in viewModel.persist() }
        .onChange(of: viewModel.preferIPv6) { _, _ in viewModel.persist() }
        .onChange(of: viewModel.routeMode) { _, _ in viewModel.persist() }
        .onChange(of: viewModel.proxyEngine) { _, _ in viewModel.persist() }
        .onChange(of: viewModel.proxyPortText) { _, newValue in
            viewModel.handleProxyPortInputChange(newValue)
            viewModel.persist()
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert("恢复默认设置", isPresented: $viewModel.showResetAlert) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .destructive) {
                viewModel.resetSettings()
            }
        } message: {
            Text("这将清除订阅与网络设置，并恢复默认值。")
        }
    }
}

#Preview {
    NavigationStack {
        SettingsTabView(viewModel: .previewMock())
    }
}
