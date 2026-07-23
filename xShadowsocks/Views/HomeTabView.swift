import SwiftUI

struct HomeTabView: View {
    @StateObject private var viewModel: HomeViewModel
    @State private var isPresentingBrowser = false
    @State private var expandedSourceIDs: Set<UUID> = []
    @State private var infoSource: ConfigSourceModel? = nil
    @State private var infoNode: ServerNode? = nil

    @MainActor init(viewModel: HomeViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? HomeViewModel())
    }

    var body: some View {
        mainContent
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.blue, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear {
                viewModel.onAppear()
                if let selectedSourceID = viewModel.selectedSourceID {
                    expandedSourceIDs.insert(selectedSourceID)
                }
            }
            .toolbar { homeToolbar }
            .sheet(item: $infoSource) { source in
                sourceInfoSheet(for: source)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $infoNode) { node in
                nodeInfoSheet(for: node)
                    .presentationDetents([.medium, .large])
            }
            .navigationDestination(isPresented: $isPresentingBrowser) {
                ProxyBrowserView()
                    .navigationBarTitleDisplayMode(.inline)
            }
            .onChange(of: viewModel.isProxyEnabled) { _, newValue in
                viewModel.setProxyEnabled(newValue)
            }
            .onChange(of: viewModel.routeMode) { _, _ in
                viewModel.persistRouteMode()
            }
            .onChange(of: viewModel.selectedSourceID) { _, newValue in
                guard let newValue else { return }
                expandedSourceIDs.insert(newValue)
            }
            .alert("代理操作失败", isPresented: $viewModel.showProxyError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(viewModel.proxyErrorMessage)
            }
    }

    private var mainContent: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Circle()
                        .fill(connectionDotColor)
                        .frame(width: 8, height: 8)

                    Text(connectionText)
                        .font(.headline)

                    Spacer()

                    Toggle("", isOn: $viewModel.isProxyEnabled)
                        .labelsHidden()
                        .disabled(viewModel.isApplyingProxyState || !viewModel.canConnect)
                }

                Picker("全局路由", selection: $viewModel.routeMode) {
                    ForEach(homeRouteModes) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))

                if !viewModel.canConnect && viewModel.configSources.count > 1 {
                    Text("请选择一个配置，再开启连接")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                Text("Mihomo：\(viewModel.proxyStatusText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("我的配置") {
                if viewModel.configSources.isEmpty {
                    Text("暂无配置，请导入订阅")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                } else {
                    sourceListContent
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var homeRouteModes: [RouteMode] {
        [.configuration, .proxy, .direct]
    }

    @ToolbarContentBuilder
    private var homeToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                isPresentingBrowser = true
            } label: {
                Image(systemName: "safari")
            }
        }
    }

    @ViewBuilder
    private var sourceListContent: some View {
        ForEach(viewModel.configSources) { source in
            sourceHeaderButton(source)

            if expandedSourceIDs.contains(source.id) {
                ForEach(viewModel.nodes(for: source)) { node in
                    nodeRow(node, in: source)
                }
            }
        }
    }

    private func sourceHeaderButton(_ source: ConfigSourceModel) -> some View {
        let isSelected = viewModel.selectedSourceID == source.id
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(isSelected ? .blue : .secondary)
                .frame(width: 24)

            Button {
                toggleExpansion(source)
            } label: {
                Image(systemName: expandedSourceIDs.contains(source.id) ? "chevron.down" : "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            Text(source.name)
                .font(.body)
                .foregroundStyle(.primary)

            Spacer()

            Button {
                viewModel.runConnectivityTest()
            } label: {
                Image(systemName: "speedometer")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isTesting)

            Button {
                infoSource = source
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectSource(source)
            expandedSourceIDs.insert(source.id)
        }
        .listRowBackground(isSelected ? Color.blue.opacity(0.08) : Color(.secondarySystemGroupedBackground))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation {
                    expandedSourceIDs.remove(source.id)
                    viewModel.deleteSource(source)
                }
            } label: {
                Label("删除配置", systemImage: "trash")
            }
        }
    }

    private func nodeRow(_ node: ServerNode, in source: ConfigSourceModel) -> some View {
        HStack(spacing: 10) {
            if isNodeSelected(node, in: source) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
                    .frame(width: 32)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
                    .frame(width: 32)
            }

            Text(nodeBadgeFlag(node))
                .font(.title3)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(nodeDisplayName(node))
                    .font(.body)

                Text(nodeProtocolSubtitle(node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(node.latencyText)
                .font(.subheadline)
                .foregroundStyle(.green)

            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
                .onTapGesture {
                    infoNode = node
                }
        }
        .contentShape(Rectangle())
        .listRowBackground(
            isNodeSelected(node, in: source)
                ? Color.blue.opacity(0.08)
                : Color(.secondarySystemGroupedBackground)
        )
        .onTapGesture {
            viewModel.selectSource(source)
            viewModel.selectNode(node)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation {
                    viewModel.deleteNode(node, from: source)
                }
            } label: {
                Label("删除节点", systemImage: "trash")
            }
        }
    }

    private func toggleExpansion(_ source: ConfigSourceModel) {
        if expandedSourceIDs.contains(source.id) {
            expandedSourceIDs.remove(source.id)
        } else {
            expandedSourceIDs.insert(source.id)
        }
    }

    private var connectionText: String {
        if viewModel.isApplyingProxyState {
            return "连接中"
        }
        return viewModel.isProxyEnabled ? "已连接" : "未连接"
    }

    private var connectionDotColor: Color {
        if viewModel.isApplyingProxyState {
            return .orange
        }
        return viewModel.isProxyEnabled ? .green : .gray
    }

    private func nodeBadgeFlag(_ node: ServerNode) -> String {
        let trimmed = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "🌐" }
        return String(first)
    }

    private func nodeDisplayName(_ node: ServerNode) -> String {
        let trimmed = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2,
           let first = parts.first,
           first.unicodeScalars.allSatisfy({ $0.properties.isEmojiPresentation }) {
            return String(parts[1])
        }
        return trimmed
    }

    private func nodeProtocolSubtitle(_ node: ServerNode) -> String {
        let methodText = (node.method?.uppercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "NONE"
        return "\(node.nodeType.uppercased()) / \(methodText)"
    }

    private func isNodeSelected(_ node: ServerNode, in source: ConfigSourceModel) -> Bool {
        viewModel.selectedSourceID == source.id && viewModel.selectedNodeID == node.id
    }

    private func sourceInfoSheet(for source: ConfigSourceModel) -> some View {
        NavigationStack {
            List {
                Section("基础信息") {
                    LabeledContent("配置名称", value: source.name)
                    LabeledContent("节点数量", value: "\(source.nodes.count)")
                    LabeledContent("更新时间", value: source.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section("来源链接") {
                    Text(source.url)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("服务详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") { infoSource = nil }
            }
        }
    }

    private func nodeInfoSheet(for node: ServerNode) -> some View {
        NavigationStack {
            List {
                Section("节点属性") {
                    LabeledContent("名称", value: node.name)
                    LabeledContent("协议", value: node.nodeType.uppercased())
                    LabeledContent("加密", value: node.method ?? "None")
                }
                Section("网络配置") {
                    LabeledContent("服务器", value: node.host)
                    LabeledContent("端口", value: "\(node.port)")
                    LabeledContent("SNI", value: node.sni ?? "自动")
                }
                Section("安全凭据") {
                    SecureField("密码", text: .constant(node.password))
                        .disabled(true)
                }
            }
            .navigationTitle("节点信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") { infoNode = nil }
            }
        }
    }
}

#Preview {
    NavigationStack {
        HomeTabView(viewModel: .previewMock())
    }
}
