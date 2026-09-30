# xShadowsocks

一个基于 SwiftUI + NetworkExtension 的 iOS 代理客户端，代理内核为 mihomo（以
`MihomoCore.xcframework` 动态库形式嵌入）。

支持两种运行方式：

| 方式 | 内核运行在 | 代理范围 | 前置条件 |
|---|---|---|---|
| **本地端口**（默认） | App 进程内 | 指向本机端口的 App（含内置浏览器） | 无，免费账号即可 |
| **系统 VPN** | Packet Tunnel 扩展 | 全部系统流量 | 扩展被嵌入且签名（Network Extension 权限） |

App 用 `TunnelManager.isExtensionEmbedded` 判断当前构建里是否真的存在
`xPacketTunnel.appex`（`HomeViewModel.swift:52`）：不存在时，代理方式强制回到「本地端口」，
设置页里的「系统 VPN」选项也会禁用。所以同一份代码在免费账号下能跑，在配好签名与嵌入的
构建里就走全系统流量。

## 架构

```
本地端口模式
┌── xShadowsocks.app ────────────────────────────────────┐
│  SwiftUI 界面 / ViewModels                             │
│  LocalProxyHost ──▶ MihomoCoreHost ──▶ MihomoCore      │
│                     （同进程，监听 127.0.0.1）          │
└────────────────────────────────────────────────────────┘

系统 VPN 模式
┌── xShadowsocks.app ──────────┐   ┌── xPacketTunnel.appex ─────────────┐
│  TunnelManager               │   │  NEPacketTunnelProvider            │
│  (NETunnelProviderManager)   │──▶│  1. 配置 utun 接口与路由           │
│  MihomoConfigFileStore       │App│  2. MihomoCoreHost 启动内核        │
│  GeoDataStore                │Grp│  3. 轮询 Clash API 写回流量统计    │
└──────────────────────────────┘   └──────────────┬─────────────────────┘
                                                  │ file-descriptor
                                   ┌──────────────▼─────────────────────┐
                                   │  MihomoCore.xcframework (mihomo)   │
                                   │  tun inbound + system stack        │
                                   └────────────────────────────────────┘
```

两种模式共用 `MihomoCoreHost`（写运行配置、启停内核、采集流量）。区别只在 `HostMode`：
`.loopback` 显式关闭 tun，`.tunnel(fd)` 把扩展的 utun 描述符交给内核。

**Swift 不参与数据面。** 系统 VPN 模式下扩展把 `NEPacketTunnelProvider` 创建的 utun
文件描述符通过 `tun.file-descriptor` 交给 mihomo，由内核自己的 `system` 栈收发数据包；
Swift 只负责接口配置、生成运行配置、写回流量统计。描述符的取得方式见
`Shared/UtunFileDescriptor.swift`（优先 KVC 拿 `socket.fileDescriptor`，失败再扫 fd 表用
`UTUN_OPT_IFNAME` 认领）。

> `MihomoCore.xcframework` 构建时未包含 `with_gvisor`（二进制里能看到
> `ErrGVisorNotIncluded`），因此只能用 `system` 栈。桥接层只有 4 个 C 入口：
> `mihomo_start_with_config` / `mihomo_reload_config` / `mihomo_stop` / `mihomo_is_running`，
> 由 `MihomoCoreBridge` 用一条串行队列统一转发（内核有全局状态）。

### 运行配置的生成

订阅/导入的 YAML 与内核真正启动用的配置不是同一个文件。`MihomoRuntimeConfigBuilder`
保留原文件中除下列键之外的全部内容（proxies / proxy-groups / rules / rule-providers /
DNS 服务器 / sniffer 等），再补上宿主必须掌握的键：

| 覆盖的键 | 原因 |
|---|---|
| `tun` | 由宿主模式决定：扩展模式必须带运行时 `file-descriptor`；本地模式显式关闭 |
| `mixed-port` / `socks-port` / `bind-address` / `allow-lan` | 端口来自设置，`socks-port = mixed-port + 1` |
| `mode` / `log-level` / `ipv6` | 由 App 的全局路由设置与网络偏好决定 |
| `external-controller` / `secret` | 供宿主读取流量统计；只绑 127.0.0.1，端口 9090，密钥是 `MihomoCoreHost` 单例进程内生成的一次性随机 UUID |
| `dns.enable`（仅此一键，且仅扩展模式） | 隧道内 DNS 必须开启；本地模式保留用户设置 |

扩展模式下 tun 配置为 `stack: system`、`auto-route: false`、`auto-detect-interface: false`：
接口地址取 `dns.fake-ip-range` 的地址（`/30` 宽化，默认 `198.18.0.1`）、MTU 1500，由扩展通过
`NEPacketTunnelNetworkSettings` 下发，内核不得再自行配置；下发给系统的两个 DNS 是紧接接口地址
的后面两个地址（内核在这两个地址上劫持 53）。产物落盘为 `runtime.yaml`（本地模式为
`runtime-local.yaml`）。

## 订阅导入与解析

```
输入链接 + 配置名
  └─ SubscriptionNodeImportService.importNodes
       ├─ 请求 1：ClashX User-Agent → 期望拿到完整 mihomo/Clash YAML
       │    └─ SubscriptionContentParser.parse → rawYAML（拿不到 YAML 直接报错，不做拼接）
       ├─ 请求 2：通用 User-Agent → 期望拿到 Base64 的 URI 列表，仅用于「首页节点列表」显示
       │    └─ 失败或解析不到节点时，回退用请求 1 的 YAML 里解析出的节点
       └─ ConfigViewModel：MihomoConfigFileStore.save(rawYAML, as: "<配置名>.yaml")
```

要点：**下载到的配置原样落盘**，App 不再把解析出的节点回写进 YAML（该拼接逻辑已移除）。
节点列表只是展示与测速用的元数据，真正生效的一直是磁盘上的那份 YAML。

解析层的分工：

| 类型 | 职责 | 边界 |
|---|---|---|
| `SubscriptionContentParser` | 三路分发：载荷本身像 YAML / Base64 解码后是 URI 列表 / 兜底再当 YAML 试一次 | 只做判别，不做字段解析 |
| `URIParser` | `vless://`、`anytls://` 两种 URI | 其余 scheme（ss/trojan/…）不支持 |
| `MihomoYAMLConfigParser` | 行级扫描顶层 `proxies:` 段，支持块式与流式 `- {…}` 写法，嵌套对象展平成 `父.子` 键 | 只读展示字段（name/server/port/密码族/type/sni/flow/tls/reality 的 pbk·sid/grpc·ws path/fingerprint 等）；不解析 `proxy-providers`、块式嵌套映射、分组与规则 |
| `MihomoConfigFileStore` | App Group 工作目录里的 `<名>.yaml` 增删与 `activeFileName` | `normalizeForMihomoYAML` 只做 CRLF、BOM、Tab 缩进 → 空格 |
| `MihomoYAMLPreflight` | 保存前体检：空文本、`\0`、BOM、零宽/NBSP/全角空格、弯引号、U+2028、Tab 缩进、缺 `proxies:`/`proxy-providers:` | 目前**只有单元测试在用**，App 的保存/启动路径没有调用它 |

启动时 `HomeViewModel` 会把内存里选中的那份配置重新写回磁盘再拉起内核
（`HomeViewModel.swift:181`），避免刚导入还没落盘的状态和列表不一致。

## 数据存放

- 有 App Group 时：`/…/group.com.github.iappapp.xShadowsocks/mihomo/`，订阅 YAML、
  `Country.mmdb`、`runtime*.yaml` 都在这（`MihomoSharedPaths`），App 与扩展共用。
  App Group id 常量在 `Shared/AppGroupStore.swift:17`。
- 无 App Group 时：退化为 App 私有 Application Support，功能不受影响，因为此时内核就跑在
  App 进程里，不需要跨进程共享。
- 订阅列表（`config_sources`）、设置项（`settings.*`）、当日流量计数同理：有 App Group 用共享
  defaults，否则用 `UserDefaults.standard`。见 `AppGroupStore`。
- `Country.mmdb`（GeoIP）由 `GeoDataStore` 在启停内核前从 bundle 拷进工作目录。

> 注意当前签名状态：`xPacketTunnel.entitlements` 已声明 App Group，但
> `xShadowsocks.entitlements` 是空的（为了免费账号可签名）。也就是说，**只有把 App Group
> 加进主 App 的 entitlements，App 与扩展才会读写同一个目录**；否则扩展会去看共享目录、
> 而 App 把自己的文件写在私有沙盒里。

## 代码地图

- `Shared/` — App 与扩展共同编译：`AppGroupStore`（跨进程 defaults + 流量计数）、
  `MihomoSharedPaths`（工作目录与各类文件名）、`MihomoRuntimeConfigBuilder`（运行配置生成 +
  隧道接口参数推导）、`MihomoCoreHost`（启停内核、流量轮询）、`MihomoCoreBridge`（C 入口包装）、
  `MihomoAPIClient`（`GET /connections` 取累计上下行）、`TunnelMessaging`（App↔扩展消息）、
  `GeoDataStore`、`UtunFileDescriptor`
- `xShadowsocks/Views/` — 四个 Tab：首页（开关、选源、节点列表、测速、内置浏览器）、
  配置（订阅导入、文件列表、YAML 预览）、数据（今日/本次流量）、设置
- `xShadowsocks/ViewModels/` — `HomeViewModel`（两种模式的启停与选择态）、`ConfigViewModel`
  （导入与配置源管理）、`SettingsViewModel`、`DataViewModel`
- `xShadowsocks/Services/` — 订阅导入与各解析器（见上表）、`LocalProxyHost`（loopback 宿主）、
  `ProxyControl`（唯一的 reload 分发点：本地就地重载，隧道发 `reloadConfig` 消息）、
  `TunnelManager`（`NETunnelProviderManager` 安装与消息）、`NodeLatencyProbe`
  （`NWConnection` TCP 握手 RTT，4s 超时记为 -1，首页并发 ≤8）
- `xShadowsocks/Services/mihomo/` — `MihomoRuntimeManager` + `MihomoRuntimeModels` +
  `CountryMMDBStore`：**当前没有任何调用方**，是保留的另一套 App 内宿主实现（走
  `MihomoConfigFileStore.activeFileName`，同样原样使用配置文件）。它参与编译但不参与运行，
  接线或删除前请先确认意图
- `xPacketTunnel/` — Packet Tunnel 扩展：`startTunnel` 读配置名 → 推导接口参数 → 下发
  `NEPacketTunnelNetworkSettings`（默认路由，私网 10/172.16/192.168 走直连）→ 取 utun fd →
  启动内核 → 每 2s 轮询流量写回 App Group；`stopTunnel` 停表并停内核
- `MihomoCore.xcframework/` — mihomo 动态库（`ios-arm64` 与 `ios-arm64_x86_64-simulator` 两个
  slice），App target 用 Copy Files→Frameworks 嵌入
- `xShadowsocksTests/` — 单元测试

## 编译与测试

只编译、不签名（签名才是消耗免费账号 App ID 的动作，改代码时用这个循环）：

```bash
./build-unsigned.sh            # 全部：App + 单元测试 + 扩展
./build-unsigned.sh app        # 只编译 App
./build-unsigned.sh tests      # App + build-for-testing（模拟器）
./build-unsigned.sh extension  # 只编译 Packet Tunnel 扩展
./build-unsigned.sh all Release
```

它等价于给 `xcodebuild` 传 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS=""`。产物是未签名的 `.app`/`.appex`，
**不能安装到设备**（安装必须走 Xcode 的签名流程）。

扩展之所以在脚本里用 `-target` 而不是 `-scheme`：它不在 App 的构建里，这是不签名也能把它
整个编译一遍的唯一途径——所以扩展代码不会在迭代中悄悄腐烂。

单元测试全部使用 Swift Testing（`import Testing`，无 XCTest），共 29 个 `@Test`，覆盖运行配置
生成的两种模式差异与 DNS 强制、fake-ip 地址推导、IPv4 进位，YAML/URI/订阅载荷解析，Base64
归一化，以及 preflight。在 Xcode 里 `Cmd+U`（scheme `xShadowsocks`，测试计划只挂
`xShadowsocksTests`），或命令行：

```bash
xcodebuild -project xShadowsocks.xcodeproj -scheme xShadowsocks \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO test
```

已知一处失败：`MihomoYAMLPreflightTests.normalizedCheckAutoCleansSpecialCharacters`。
`normalizeForMihomoYAML` 只把 Tab 缩进换成空格，不处理全角空格/NBSP 缩进，所以
`checkNormalized` 归一化之后仍会报 error，而该测试预期它已被自动清理。

工程事实：最低系统 iOS 17.6，`SWIFT_VERSION = 5.0`，三个 target 均为 Automatic 签名，
`xShadowsocksUITests/` 的源码仍在磁盘但已不是 target 成员，App 开启
`NSAllowsArbitraryLoads`（需要连任意订阅服务器）。

## 免费账号：直接运行

免费账号没有通配符 App ID，每个 bundle id 都要占一个专属 App ID，且每 7 天只能建 10 个。
工程因此把默认构建流程收窄：只有主 App 与单测会被顺带签名，UI 测试已不再是 target 成员
（源码仍在 `xShadowsocksUITests/`），扩展是独立 target / 独立 scheme，只有手动构建它才占用它
那个 App ID。

1. 打开 `xShadowsocks.xcodeproj`，选择 `xShadowsocks` scheme，真机运行。默认流程只签主 App
   与单测两个 bundle id；扩展是独立 target，自动签名不会顺带碰它。
2. 「配置」页导入订阅，回首页打开开关。状态栏显示「已连接（本地 7890）」。
3. 首页右上角 safari 图标打开内置浏览器验证连通性：本地端口模式下它通过
   `WKWebsiteDataStore.proxyConfigurations` 把流量指向 `127.0.0.1:端口`（系统 VPN 模式不需要，
   默认路由已经带走本机流量）。浏览器只在真机可用，模拟器里显示占位提示。
4. 其他 App 需要手动把 HTTP/SOCKS 代理指向 `127.0.0.1:7890`。
   注意：运行配置里 `bind-address` 固定为 `127.0.0.1`，所以「允许局域网访问」目前**不会**
   真的把端口暴露到同网段（见「已知限制」）。

## 付费账号：启用系统 VPN

1. 在开发者后台为 App 与扩展的 App ID 开启 **Network Extensions** 与 **App Groups**，
   三个 target 的 Team 设成同一个付费 Team。
2. 恢复 entitlements（文件里已用注释写好，取消注释即可）：
   - `xShadowsocks/xShadowsocks.entitlements`：App Group + `…networkextension`
   - `xPacketTunnel/xPacketTunnel.entitlements`：App Group 已有，只差 networkextension
   - 两边 App Group 必须一致，且与 `AppGroupStore.appGroupID` 相同
3. 给主 target 加回 **Embed App Extensions**：
   - Build Phases → + → New Copy Files Phase → Destination 选 *PlugIns*
   - 把 `xPacketTunnel.appex` 加进去（Code Sign On Copy）
   - 同时加 target dependency（App 依赖 xPacketTunnel）
   - 没有这一步 `isExtensionEmbedded` 恒为 false，界面永远是「本地端口」
4. 扩展 bundle id 需与 `TunnelManager.extensionBundleIdentifier` 一致。
5. 运行后到「设置 → 代理方式」选「系统 VPN」。首次会弹系统 VPN 授权。

## 已知限制

- 本地端口模式不接管系统流量，这是平台限制，不是实现缺陷。
- `bind-address` 被固定为 `127.0.0.1`，因此「允许局域网访问」当前无效；要支持局域网需要把
  运行配置里的这一项随设置改为 `*`（或监听地址列表）。
- 首页的节点选择不影响内核实际使用哪条代理：选择只更新界面与测速目标，`MihomoAPIClient`
  只实现了 `GET /connections`，还没有 `PUT /proxies/{name}`；真正的分组切换仍由配置里的
  `proxy-groups` 与 `mode` 决定。
- 测速是 App 进程发起的 TCP 握手，用于开启代理前的可用性筛选；隧道运行中的真实延迟应改走
  核心的 `/proxies/{name}/delay`（尚未实现）。
- 订阅的自动更新尚未接入后台任务，设置页的「更新间隔 / 启动时更新」目前没有消费方，只保留
  手动导入入口。
- 路由模式的「场景」在首页隐藏，落到 mihomo 时按 `rule` 处理；「配置/代理/直连」对应
  `rule`/`global`/`direct`，修改后重新生成运行配置并热重载。
- `config_sources` 里仍然带着整份 `yamlConfig` 文本存进 UserDefaults，而
  `ConfigSourceYAMLMigration.migrateYAMLToDiskIfNeeded`（把 YAML 挪到磁盘、清空该字段）没有任何
  调用方。首页启动内核前又恰好会用这份内存里的 YAML 覆写磁盘文件
  （`HomeViewModel.swift:181`），也就是该迁移注释里警告过的「被截断的配置覆盖好的文件」路径。
- `xShadowsocks/Services/mihomo/` 三个文件与主链路重复且未接线。
