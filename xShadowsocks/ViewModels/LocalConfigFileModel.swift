//
//  LocalConfigFileModel.swift
//  xShadowsocks
//
//  Created by apple on 2026/7/21.
//
import Foundation

struct LocalConfigFileModel: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let modifiedAt: Date
    let sizeInBytes: Int64

    var modifiedText: String {
        Self.dateFormatter.string(from: modifiedAt)
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
