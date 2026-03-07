import SwiftUI

struct HomeTabView: View {
    @StateObject private var viewModel: HomeViewModel
    @State private var isPresentingImportSheet = false
    @State private var isPresentingBrowser = false
    @State private var showRouteModeHint = false
    @State private var expandedSourceIDs: Set<UUID> = []
    @State private var importURLText = ""
    @State private var importConfigName = ""

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

            Button {
                viewModel.runConnectivityTest()
            } label: {
                HStack {
                    Image(systemName: "speedometer")
                        .foregroundStyle(.blue)
                    Text("连通性测试")
                        .foregroundStyle(.primary)
                    Spacer()
                    if viewModel.isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isTesting)
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
        Button {
            toggleSourceExpansion(source)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: expandedSourceIDs.contains(source.id) ? "chevron.down" : "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name)
                        .font(.title3)
                        .foregroundStyle(.primary)
                }

                Spacer()

                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
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
        Button {
            viewModel.selectSource(source)
            viewModel.selectNode(node)
        } label: {
            HStack(spacing: 10) {
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

                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 30, maxHeight: 50)
            .background(isNodeSelected(node, in: source) ? Color.blue.opacity(0.08) : Color.clear)
        }
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
}

#Preview {
    NavigationStack {
        HomeTabView(viewModel: .previewMock())
    }
}
