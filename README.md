# xShadowsocks

一个基于 SwiftUI + NetworkExtension 的 iOS 代理客户端示例工程，包含：
- 主应用（配置、节点管理、连通性测试、流量统计）
- Packet Tunnel 扩展（系统 VPN 通道）
- 本地调试代理（Trojan HTTP CONNECT）
- Mihomo Core 运行时桥接（动态加载 `MihomoCore.xcframework`）

## 功能概览

- **首页（Home）**
  - 代理开关、路由模式切换
  - 节点选择与并发连通性测试
  - 订阅节点导入（YAML）
  - 内置浏览器访问测试（默认 Google）
- **配置（Config）**
  - 手动编辑 Shadowsocks/Trojan 关键参数
  - 配置源导入（YAML / trojan URI / Base64）
  - 配置保存到 App Group
- **数据（Data）**
  - 今日上传/下载/总流量统计
  - 一键重置统计
- **设置（Settings）**
  - 订阅与网络偏好项
  - 本地设置持久化

## 技术架构

### 1) 主应用（`xShadowsocks/`）

- UI 层：SwiftUI（`ContentView` + 四个 Tab）
- 状态层：`ViewModels/*`
- 服务层：
  - `AppGroupStore`：跨 App/Extension 数据共享
  - `MihomoRuntimeManager`：生成配置、拉取 `Country.mmdb`、启动/重载/停止 Mihomo
  - `DynamicMihomoCoreBridge`：运行时解析 `mihomo_*` 符号
  - `LocalTrojanProxyService`：本地调试代理（监听 7890）

### 2) Tunnel 扩展（`xPacketTunnel/`）

- `PacketTunnelProvider` 负责：
  - 加载共享配置并设置 `NEPacketTunnelNetworkSettings`
  - 启动代理引擎（Trojan HTTP Proxy 或 LocalProxyEngine）
  - 路由决策查询（支持 app message）
  - 流量统计写回 App Group
- `RoutePolicy` / `MMDBGeoIPResolver`：规则匹配与 GeoIP 判定

### 3) 内置浏览器代理测试

`ProxyBrowserView` 使用 iOS 原生 `WKWebsiteDataStore.proxyConfigurations`（HTTP CONNECT 代理）将 WebView 流量指向 `127.0.0.1:7890`，避免 HTML 重写导致的复杂站点兼容问题。

## 运行要求

- Xcode 16+
- iOS 18.0+（工程当前 deployment target 为 18.x）
- Apple Developer 签名能力（Network Extension + App Group）

## 快速开始

1. 打开工程：
   - `xShadowsocks.xcodeproj`
2. 在 Xcode 中设置签名：
   - 主 App 与 `xPacketTunnel` 使用同一 Team
   - 确保 App Group 一致：`group.com.github.iappapp.xShadowsocks`
3. 检查 `MihomoCore.xcframework`：
   - 已添加到主 App target
   - `Frameworks, Libraries, and Embedded Content` 为 **Embed & Sign**
4. 选择真机（推荐）并运行主 App。

## 当前运行模式说明

`HomeViewModel` 里默认 `localDevelopmentMode = true`，表示：
- 主要用于本地调试，不主动走系统 VPN 授权流程
- 代理开关优先尝试 Mihomo Runtime；失败时回退到本地 Trojan 代理
- 浏览器测试会访问本地代理端口 `7890`

如果要切换到系统 VPN 通道，请按项目设计调整该开关逻辑并确保扩展签名与权限正确。

## 数据与存储

通过 App Group `UserDefaults` 共享：
- `ss_config`：隧道启动配置
- `imported_nodes` / `config_sources`：导入节点与配置源
- `traffic_*`：按日统计流量

## 常见问题

### 1) Mihomo 启动失败 / 提示桥接符号缺失

检查：
- `MihomoCore.xcframework` 是否正确嵌入主 App（Embed & Sign）
- 动态库是否导出所需符号：`mihomo_start*`、`mihomo_reload*`、`mihomo_stop`

### 2) 浏览器测试页打不开

检查：
- 首页代理是否已启动
- 本地端口 `7890` 是否被占用
- 目标节点是否可连通（先做“连通性测试”）

### 3) 节点导入成功但不可用

- 目前核心链路以 `trojan` 节点为主，其他类型可能被忽略或受限
- 先在“配置”页面确认服务器、端口、密码、SNI 等字段完整

## 目录结构（精简）

- `xShadowsocks/`：主应用
- `xPacketTunnel/`：Packet Tunnel 扩展
- `MihomoCore.xcframework/`：Mihomo 动态库
- `xShadowsocksTests/`、`xShadowsocksUITests/`：测试目标

## 后续建议

- 增加 iOS 低版本（< iOS 17）浏览器代理降级方案
- 将订阅更新从模拟逻辑替换为真实拉取/解析链路
- 为关键服务（配置生成、路由匹配）补充单元测试
