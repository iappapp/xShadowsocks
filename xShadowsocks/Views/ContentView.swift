//
//  ContentView.swift
//  xShadowsocks
//
//  Created by mac on 2026/3/2.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack {
                HomeTabView()
            }
                .tabItem {
                    Label("首页", systemImage: "house")
                }

            NavigationStack {
                ConfigTabView()
            }
                .tabItem {
                    Label("配置", systemImage: "slider.horizontal.3")
                }

            NavigationStack {
                DataTabView()
            }
                .tabItem {
                    Label("数据", systemImage: "chart.bar")
                }

            NavigationStack {
                SettingsTabView()
            }
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    ContentView()
}
