import SwiftUI

struct ConfigTabView: View {
    @StateObject private var viewModel: ConfigViewModel
    @State private var isShowingImportSheet = false
    @State private var importURL = ""
    @State private var importConfigName = ""
    @State private var showRestoreConfirm = false
    @State private var showFileInfo = false

    @MainActor init(viewModel: ConfigViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? ConfigViewModel())
    }

    var body: some View {
        ZStack {
            Color(red: 242 / 255, green: 242 / 255, blue: 247 / 255)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 0) {
                        actionRow(icon: "arrow.uturn.backward", title: "恢复默认配置") {
                            showRestoreConfirm = true
                        }
                        Divider().padding(.leading, 44)
                        actionRow(icon: "icloud.and.arrow.down", title: "导入订阅...") {
                            isShowingImportSheet = true
                        }
                    }
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Text("本地文件")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)

                    VStack(spacing: 0) {
                        if let file = viewModel.localConfigFile {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 10, height: 10)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .font(.headline)
                                    Text("\(file.modifiedText) - \(file.sizeText)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.down")
                                    .font(.footnote)
                                    .foregroundStyle(.blue)

                                Button {
                                    showFileInfo = true
                                } label: {
                                    Image(systemName: "info.circle")
                                        .font(.title3)
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        } else {
                            Text("default.conf")
                                .font(.headline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                    }
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Text("圆点代表默认配置，复选标记代表正在使用的配置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let message = viewModel.configOperationMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }

                    if let error = viewModel.importErrorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if !viewModel.configSources.isEmpty {
                        Text("已导入配置")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)

                        VStack(spacing: 0) {
                            ForEach(viewModel.configSources) { source in
                                sourceRow(source)
                                if source.id != viewModel.configSources.last?.id {
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            viewModel.onAppear()
        }
        .navigationTitle("配置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.blue, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isShowingImportSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(viewModel.isImportingConfigFile)
            }
        }
        .sheet(isPresented: $isShowingImportSheet) {
            importSheet
        }
        .alert("恢复默认配置", isPresented: $showRestoreConfirm) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .destructive) {
                viewModel.restoreDefaultConfigFile()
            }
        } message: {
            Text("将使用默认 mihomo 模板覆盖当前 default.conf。")
        }
        .alert("文件信息", isPresented: $showFileInfo) {
            Button("知道了", role: .cancel) {}
        } message: {
            if let file = viewModel.localConfigFile {
                Text("名称：\(file.name)\n修改时间：\(file.modifiedText)\n大小：\(file.sizeText)")
            } else {
                Text("未找到本地配置文件")
            }
        }
    }

    private var importSheet: some View {
        NavigationStack {
            Form {
                Section("订阅链接") {
                    TextField("https://example.com/sub", text: $importURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section("配置名称") {
                    TextField("请输入配置名称", text: $importConfigName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let importError = viewModel.importErrorMessage {
                    Section {
                        Text(importError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            let success = await viewModel.importNodes(from: importURL, configName: importConfigName)
                            if success {
                                isShowingImportSheet = false
                                importURL = ""
                                importConfigName = ""
                            }
                        }
                    } label: {
                        HStack {
                            Text("下载并导入")
                            Spacer()
                            if viewModel.isImportingConfigFile {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                               || importConfigName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                               || viewModel.isImportingConfigFile)
                }
            }
            .navigationTitle("导入配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        isShowingImportSheet = false
                        importURL = ""
                        importConfigName = ""
                    }
                }
            }
        }
    }

    private func sourceRow(_ source: ProxyConfigSource) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(.blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.body)
                Text("\(source.nodes.count) 个节点 · \(source.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation {
                    viewModel.deleteSource(source)
                }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(.blue)
                    .frame(width: 20)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        ConfigTabView(viewModel: .previewMock())
    }
}
