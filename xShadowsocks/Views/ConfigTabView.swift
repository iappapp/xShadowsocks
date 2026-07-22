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
        List {
            Section {
                Button {
                    isShowingImportSheet = true
                } label: {
                    actionRowContent(icon: "icloud.and.arrow.down", title: "导入订阅...")
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.white)
                .listRowSeparator(.hidden)
            }

            Section {
                if viewModel.configSources.isEmpty {
                    Text("请导入订阅")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.white)
                } else {
                    ForEach(viewModel.configSources) { source in
                        configFileRow(source)
                    }
                }
            } header: {
                Text("配置文件")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.white)

            if let error = viewModel.importErrorMessage {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(red: 242 / 255, green: 242 / 255, blue: 247 / 255))
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
                .font(.system(size: 26))
                .foregroundStyle(.red)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.fileName ?? source.name)
                    .font(.headline)
                Text("\(formatDate(source.updatedAt))")
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
        .padding(.horizontal, 12)
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
                    TextField("https://api.xfltd.net/import", text: $importURL)
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
            Group {
                if text.isEmpty {
                    ScrollView {
                        Text("配置文件为空")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                } else {
                    // UITextView lazy-renders only the visible region, so opening
                    // a multi-hundred-KB subscription YAML stays smooth. SwiftUI
                    // Text + ScrollView would layout the whole string up front.
                    ConfigTextView(text: text)
                }
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

    private func actionRowContent(icon: String, title: String) -> some View {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// Read-only monospaced text viewer backed by `UITextView`.
///
/// `UITextView` lazy-renders only the visible text region and owns its own
/// scroll view, so it stays smooth for very large subscription YAML payloads
/// (hundreds of KB / many proxy nodes). SwiftUI `Text` inside a `ScrollView`
/// would synchronously lay out the entire string up front and stall the sheet.
private struct ConfigTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.text = text
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }
}

#Preview {
    NavigationStack {
        ConfigTabView(viewModel: .previewMock())
    }
}
