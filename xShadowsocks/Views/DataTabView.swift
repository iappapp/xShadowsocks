import SwiftUI

struct DataTabView: View {
    @StateObject private var viewModel: DataViewModel

    @MainActor init(viewModel: DataViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? DataViewModel())
    }

    var body: some View {
        Form {
            Section("今日流量") {
                LabeledContent("上传", value: "\(viewModel.uploadToday.formatted(.number.precision(.fractionLength(1)))) MB")
                LabeledContent("下载", value: "\(viewModel.downloadToday.formatted(.number.precision(.fractionLength(1)))) MB")
                LabeledContent("总计", value: "\(viewModel.totalToday.formatted(.number.precision(.fractionLength(1)))) MB")
            }

            Section {
                Button("重置统计") {
                    viewModel.reset()
                }
                .foregroundStyle(.red)
            }
        }
        .navigationTitle("数据")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.onAppear()
        }
        .onDisappear {
            viewModel.onDisappear()
        }
    }
}

#Preview {
    NavigationStack {
        DataTabView(viewModel: .previewMock())
    }
}
