import SwiftUI

struct ConfigTabView: View {
    @StateObject private var viewModel: ConfigViewModel
    @State private var isShowingImportSheet = false
    @State private var contentSource: ConfigSourceModel? = nil
    @State private var importURL = ""
    @State private var importConfigName = ""

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
                        actionRow(icon: "icloud.and.arrow.down", title: "导入订阅...") {
                            isShowingImportSheet = true
                        }
                    }
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Text("配置文件")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)

                    if viewModel.configSources.isEmpty {
                        Text("未找到配置文件")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(viewModel.configSources) { source in
                                configFileRow(source)
                                if source.id != viewModel.configSources.last?.id {
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if let error = viewModel.importErrorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
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
        .sheet(isPresented: $isShowingImportSheet) {
            importSheet
        }
        .sheet(item: $contentSource) { source in
            contentSheet(for: source)
        }
    }

    /// Config file row: filename + node count + update time come from `ConfigSourceModel`.
    private func configFileRow(_ source: ConfigSourceModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(.blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.fileName ?? source.name)
                    .font(.headline)
                Text("\(source.name) · \(source.nodes.count) 个节点 · \(source.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                contentSource = source
            } label: {
                Image(systemName: "eye")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

    private func contentSheet(for source: ConfigSourceModel) -> some View {
        let text = source.yamlConfig ?? MihomoConfigFileStore.loadText() ?? ""
        return NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "（配置文件为空）" : text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
            .navigationTitle(source.fileName ?? source.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { contentSource = nil }
                }
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
