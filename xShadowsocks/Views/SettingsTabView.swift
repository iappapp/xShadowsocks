import SwiftUI

struct SettingsTabView: View {
    @StateObject private var viewModel: SettingsViewModel

    @MainActor init(viewModel: SettingsViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? SettingsViewModel())
    }

    var body: some View {
        Form {
            Section {
                Picker("代理方式", selection: $viewModel.proxyMode) {
                    ForEach(ProxyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .disabled(!viewModel.isTunnelAvailable)

                Text(viewModel.proxyMode.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !viewModel.isTunnelAvailable {
                    Text("系统 VPN 需要付费开发者账号签名扩展，当前构建未包含隧道扩展。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("代理方式")
            }

            Section("网络") {
                Toggle("允许蜂窝网络", isOn: $viewModel.allowCellular)
                Toggle("允许局域网访问", isOn: $viewModel.allowLANAccess)
                Toggle("优先 IPv6", isOn: $viewModel.preferIPv6)
            }

            Section {
                Picker("模式", selection: $viewModel.routeMode) {
                    ForEach(RouteMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            } header: {
                Text("全局路由")
            } footer: {
                Text("路由模式由配置文件中的规则决定，此处设置会写入运行配置。")
            }

            Section("本地端口") {
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

            Section {
                Toggle("启动时更新订阅", isOn: $viewModel.updateOnLaunch)
                Picker("更新间隔", selection: $viewModel.updateInterval) {
                    ForEach(UpdateInterval.allCases) { interval in
                        Text(interval.title).tag(interval.rawValue)
                    }
                }
                .disabled(!viewModel.updateOnLaunch)

                Text("订阅更新尚未接入后台任务，需在“配置”页手动重新导入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("订阅")
            }

            Section("数据管理") {
                Button("恢复默认设置", role: .destructive) {
                    viewModel.showResetAlert = true
                }
            }

            if let updateMessage = viewModel.updateMessage {
                Section("状态") {
                    Text(updateMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            viewModel.onAppear()
        }
        .onChange(of: viewModel.updateInterval) { _, _ in viewModel.persist() }
        .onChange(of: viewModel.updateOnLaunch) { _, _ in viewModel.persist() }
        .onChange(of: viewModel.allowCellular) { _, _ in viewModel.persist() }
        .onChange(of: viewModel.proxyMode) { _, _ in viewModel.persist() }
        .onChange(of: viewModel.allowLANAccess) { _, _ in
            viewModel.persist()
            Task { await ProxyControl.reload() }
        }
        .onChange(of: viewModel.preferIPv6) { _, _ in
            viewModel.persist()
            Task { await ProxyControl.reload() }
        }
        .onChange(of: viewModel.routeMode) { _, _ in
            viewModel.persist()
            Task { await ProxyControl.reload() }
        }
        .onChange(of: viewModel.proxyPortText) { _, newValue in
            viewModel.handleProxyPortInputChange(newValue)
            viewModel.persist()
            Task { await ProxyControl.reload() }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert("恢复默认设置", isPresented: $viewModel.showResetAlert) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .destructive) {
                viewModel.resetSettings()
            }
        } message: {
            Text("这将恢复网络与端口设置到默认值。")
        }
    }
}

#Preview {
    NavigationStack {
        SettingsTabView(viewModel: .previewMock())
    }
}
