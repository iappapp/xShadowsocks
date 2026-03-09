import SwiftUI

struct HomeTabView: View {
    @StateObject private var viewModel: HomeViewModel
    @State private var isPresentingImportSheet = false
    @State private var isPresentingBrowser = false
    @State private var showRouteModeHint = false
    @State private var expandedSourceIDs: Set<UUID> = []
    @State private var importURLText = ""
    @State private var importConfigName = ""
    @State private var infoSource: ProxyConfigSource? = nil
    @State private var infoNode: ServerNode? = nil
    @State private var showSourceInfoSheet = false
    @State private var showNodeInfoSheet = false

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
            .sheet(isPresented: $isPresentingImportSheet) { importSheetContent }
            .sheet(isPresented: $showSourceInfoSheet) {
                    sourceInfoSheet
                    .presentationDetents([.medium, .large]) // 推荐使用中等高度
            }
            .sheet(isPresented: $showNodeInfoSheet) {
                    nodeInfoSheet
                    .presentationDetents([.medium, .large])
            }
            .navigationDestination(isPresented: $isPresentingBrowser) {
                ProxyBrowserView()
                    .navigationBarTitleDisplayMode(.inline)
            }
            .onChange(of: viewModel.isProxyEnabled) { _, newValue in
                viewModel.setProxyEnabled(newValue)
            }
            .onChange(of: viewModel.selectedSourceID) { _, newValue in
                guard let newValue else { return }
                expandedSourceIDs.insert(newValue)
            }
            .alert("全局路由", isPresented: $showRouteModeHint) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("全局路由模式已迁移到“设置”页面中修改。")
            }
            .alert("代理操作失败", isPresented: $viewModel.showProxyError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(viewModel.proxyErrorMessage)
            }
            .alert("导入失败", isPresented: $viewModel.showImportError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(viewModel.importErrorMessage)
            }
    }

    private var mainContent: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            List {
                Section {
                    topStatusCard
                        .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 0, trailing: 14))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if viewModel.isLocalDevelopmentMode {
                    Section {
                        localDevelopmentStatus
                            .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }

                Section {
                    if viewModel.configSources.isEmpty {
                        Text("暂无配置，点击右上角 + 导入")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 20, trailing: 14))
                            .listRowBackground(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        sourceListContent
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var localDevelopmentStatus: some View {
        Text("\(viewModel.proxyEngineTitle)：\(viewModel.localProxyStatusText)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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

        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                isPresentingImportSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .disabled(viewModel.isImportingNodes)
        }
    }

    private var importSheetContent: some View {
        NavigationStack {
            Form {
                Section("下载链接") {
                    TextField("", text: $importURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("配置名称（可选）") {
                    TextField("", text: $importConfigName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Button {
                        Task {
                            let success = await viewModel.importNodes(from: importURLText, configName: importConfigName)
                            if success {
                                importURLText = ""
                                importConfigName = ""
                                isPresentingImportSheet = false
                            }
                        }
                    } label: {
                        HStack {
                            Text("下载并导入")
                            Spacer()
                            if viewModel.isImportingNodes {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(importURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isImportingNodes)
                }
            }
            .navigationTitle("导入配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        isPresentingImportSheet = false
                    }
                }
            }
        }
    }

    private var topStatusCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: connectionIcon)
                    .foregroundStyle(.blue)

                Text(connectionText)
                    .font(.headline)

                Spacer()

                Toggle("", isOn: $viewModel.isProxyEnabled)
                    .labelsHidden()
                    .disabled(viewModel.isApplyingProxyState)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            Button {
                showRouteModeHint = true
            } label: {
                HStack {
                    Image(systemName: "gearshape.2")
                        .foregroundStyle(.blue)
                    Text("全局路由")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(viewModel.routeMode.rawValue)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            Divider()
            // 连通性测试菜单入口已移除
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var sourceListContent: some View {
        ForEach(viewModel.configSources) { source in
            sourceHeaderButton(source)
                .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                .listRowBackground(Color(.secondarySystemBackground))

            if expandedSourceIDs.contains(source.id) {
                ForEach(viewModel.nodes(for: source)) { node in
                    nodeRow(node, in: source)
                        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                        .listRowBackground(Color(.secondarySystemBackground))
                }
            }
        }
    }

    private func sourceHeaderButton(_ source: ProxyConfigSource) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    toggleSourceExpansion(source)
                } label: {
                    Image(systemName: expandedSourceIDs.contains(source.id) ? "chevron.down" : "chevron.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 24)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name)
                        .font(.title3)
                        .foregroundStyle(.primary)
                }

                Spacer()

                // 连通性测试按钮
                Button {
                    viewModel.runConnectivityTest()
                } label: {
                    Image(systemName: "speedometer")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isTesting)
                .padding(.trailing, 4)

                Button {
                    infoSource = source
                    showSourceInfoSheet = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
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

    private func nodeRow(_ node: ServerNode, in source: ProxyConfigSource) -> some View {
        HStack(spacing: 10) {
            Button {
                viewModel.selectSource(source)
                viewModel.selectNode(node)
            } label: {
                if isNodeSelected(node, in: source) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.blue)
                        .frame(width: 12, height: 12)
                } else {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 10, height: 10)
                }
            }

            Text(nodeBadgeFlag(node))
                .font(.title2)
                .frame(width: 34, height: 30)
                .background(Color(.tertiarySystemBackground))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(nodeDisplayName(node))
                    .font(.title3)
                    .foregroundStyle(.primary)

                Text(nodeProtocolSubtitle(node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(node.latencyText)
                .font(.title3)
                .foregroundStyle(.green)

            Button {
                infoNode = node
                showNodeInfoSheet = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 30, maxHeight: 50)
        .background(isNodeSelected(node, in: source) ? Color.blue.opacity(0.08) : Color.clear)
        .buttonStyle(.plain)
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

    private func toggleSourceExpansion(_ source: ProxyConfigSource) {
        viewModel.selectSource(source)
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

    private var connectionIcon: String {
        viewModel.isProxyEnabled ? "paperplane.circle.fill" : "paperplane.circle"
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

    private func isNodeSelected(_ node: ServerNode, in source: ProxyConfigSource) -> Bool {
        viewModel.selectedSourceID == source.id && viewModel.selectedNodeID == node.id
    }

    private var sourceInfoSheet: some View {
        NavigationStack {
            List {
                if let source = infoSource {
                    Section("基础信息") {
                        LabeledContent("配置名称", value: source.name)
                        LabeledContent("节点数量", value: "\(source.nodes.count)")
                        LabeledContent("更新时间", value: source.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Section("来源链接") {
                        Text(source.url ?? "手动添加").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("服务配置详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") { showSourceInfoSheet = false }
            }
        }
    }

    private var nodeInfoSheet: some View {
        NavigationStack {
            List {
                if let node = infoNode {
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
            }
            .navigationTitle("节点详细信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") { showNodeInfoSheet = false }
            }
        }
    }
}

#Preview {
    NavigationStack {
        HomeTabView(viewModel: .previewMock())
    }
}
