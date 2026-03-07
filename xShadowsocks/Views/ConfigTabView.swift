import SwiftUI

struct ConfigTabView: View {
    @StateObject private var viewModel: ConfigViewModel
    @State private var isShowingImportSheet = false
    @State private var importURL = ""
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
                        actionRow(icon: "icloud.and.arrow.down", title: "导入...") {
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
            }
        }
        .sheet(isPresented: $isShowingImportSheet) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        TextField("https://example.com/default.conf", text: $importURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)
                        if !importURL.isEmpty {
                            Button {
                                importURL = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        Spacer()
                        Button("重置输入") {
                            importURL = ""
                        }
                        .font(.footnote)
                        Spacer()
                    }

                    if let importError = viewModel.importErrorMessage {
                        Text(importError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Spacer()
                }
                .padding()
                .navigationTitle("导入配置")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            isShowingImportSheet = false
                            importURL = ""
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task {
                                let success = await viewModel.importConfigFile(from: importURL)
                                if success {
                                    isShowingImportSheet = false
                                    importURL = ""
                                }
                            }
                        } label: {
                            if viewModel.isImportingConfigFile {
                                ProgressView()
                            } else {
                                Text("导入")
                            }
                        }
                        .disabled(viewModel.isImportingConfigFile)
                    }
                }
            }
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
