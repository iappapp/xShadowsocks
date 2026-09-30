# xShadowsocks

一个基于 SwiftUI + NetworkExtension 的 iOS 代理客户端，代理内核为 mihomo。

支持两种运行方式，**免费 Apple Developer 账号也能编译运行**：

| 方式 | 内核运行在 | 代理范围 | 账号要求 |
|---|---|---|---|
| **本地端口**（默认） | App 进程内 | 指向本机端口的 App（含内置浏览器） | 无，免费账号即可 |
| **系统 VPN** | Packet Tunnel 扩展 | 全部系统流量 | 付费账号（Network Extension 权限） |

默认走「本地端口」，因为 Network Extension 权限只有付费账号能签名。扩展代码保持完整、
可编译，切换到付费账号后按下面「启用系统 VPN」几步接上即可。

## 架构

```
本地端口模式（免费账号）
┌── xShadowsocks.app ────────────────────────────────────┐
│  SwiftUI 界面 / ViewModels                             │
│  LocalProxyHost ──▶ MihomoCoreHost ──▶ MihomoCore      │
│                     （同进程，监听 127.0.0.1）          │
└────────────────────────────────────────────────────────┘

系统 VPN 模式（付费账号）
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

两种模式共用 `MihomoCoreHost`（生成运行配置、启停内核、采集流量）。区别只在
`HostMode`：`.loopback` 不启用 tun，`.tunnel(fd)` 把扩展的 utun 描述符交给内核。

**Swift 不参与数据面。** 系统 VPN 模式下扩展把 `NEPacketTunnelProvider` 创建的 utun
文件描述符通过 `tun.file-descriptor` 交给 mihomo，由内核自己的 `system` 栈收发数据包；
Swift 只负责接口配置、生成运行配置、写回流量统计。这与 sing-box / wireguard-apple 在
iOS 上的做法一致。

> `MihomoCore.xcframework` 构建时未包含 `with_gvisor`（二进制里能看到
> `ErrGVisorNotIncluded`），因此只能用 `system` 栈。

### 运行配置的生成

`MihomoRuntimeConfigBuilder` 保留订阅 YAML 中除以下键之外的全部内容
（proxies / proxy-groups / rules / rule-providers / DNS 服务器 / sniffer 等）：

| 覆盖的键 | 原因 |
|---|---|
| `tun` | 由宿主模式决定：扩展模式必须带运行时 `file-descriptor`；本地模式显式关闭 |
| `mixed-port` / `socks-port` / `bind-address` / `allow-lan` | 只监听回环，端口来自设置 |
| `mode` / `log-level` / `ipv6` | 由 App 的全局路由设置与网络偏好决定 |
| `external-controller` / `secret` | 供宿主读取流量统计；仅绑定 127.0.0.1 |
| `dns.enable`（仅此一键，且仅扩展模式） | 隧道内 DNS 必须开启；本地模式保留用户设置 |

扩展模式下 tun 配置为 `stack: system`、`auto-route: false`、
`auto-detect-interface: false`：接口地址 `dns.fake-ip-range` 的地址（`/30` 宽化，默认
`198.18.0.1`）、MTU 1500 由扩展通过 `NEPacketTunnelNetworkSettings` 设置，内核不得再自行配置。

### 数据存放

- 有 App Group 时（付费账号）：`/…/group.com.github.iappapp.xShadowsocks/mihomo/`，
  订阅 YAML、`Country.mmdb`、运行配置都在这里，App 与扩展共用。
- 无 App Group 时（免费账号）：退化为 App 私有 Application Support，功能不受影响，
  因为此时内核就跑在 App 进程里，不需要跨进程共享。
- 订阅列表、设置项、当日流量计数同理：有 App Group 用共享 defaults，否则用
  `UserDefaults.standard`。见 `AppGroupStore`。

## 只编译、不签名

签名是消耗免费账号 App ID 的唯一动作。改代码时用脚本编译即可，全程不碰
provisioning profile、不连开发者后台：

```bash
./build-unsigned.sh          # 全部：App + 单元测试 + 扩展
./build-unsigned.sh app      # 只编译 App
./build-unsigned.sh extension # 只编译 Packet Tunnel 扩展
./build-unsigned.sh all Release
```

它等价于给 `xcodebuild` 传 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS=""`。产物是未签名的 `.app`／`.appex`，
**不能安装到设备**（安装必须走 Xcode 的签名流程）。

扩展之所以在脚本里用 `-target` 而不是 `-scheme`：它不在 App 的构建里，这是不签名也能
把它整个编译一遍的唯一途径——所以扩展代码不会在迭代中悄悄腐烂。

## 免费账号：直接运行

免费账号没有通配符 App ID，每个 bundle id 都要占一个专属 App ID，额度是每 7 天 10 个。
所以工程把默认流程收到了最少两个（这两个都已经在 keychain 里有 profile，不会新建）：

- `com.github.iappapp.xShadowsocks` — 主 App，entitlements 为空
- `com.github.iappapp.xShadowsocksTests` — 单元测试，无 entitlements

被移出默认流程的另外两个，才不会反复吃额度：

- **UI 测试 target 已删除**（`xShadowsocksUITests/` 文件夹还在磁盘上但不再编译）。
- **扩展 target 的 `DEVELOPMENT_TEAM` 留空**，自动签名不会碰它；它是独立的
  `xPacketTunnel` scheme，只在付费账号下手动构建。

因此默认流程是：

1. 打开 `xShadowsocks.xcodeproj`，选择 `xShadowsocks` scheme，选真机运行，直接签名。
2. 「配置」页导入订阅，回首页打开开关。状态栏会显示「已连接（本地 7890）」。
3. 首页右上角 safari 图标打开内置浏览器验证连通性——它会自动走本地代理端口。
4. 单元测试（`xShadowsocksTests`）用 `Cmd+U` 跑，不额外占额度。

其他 App 需要手动把 HTTP/SOCKS 代理指向 `127.0.0.1:7890`；打开「允许局域网访问」可让
同网段设备使用。

### 如果额度已经用尽

Xcode 仍报 App ID 上限时，删掉不再需要的 profile 就能释放对应的专属 App ID：

```
rm ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/6d24d0d4-aeee-4b3a-8227-0cfd77a857b9.mobileprovision
rm ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/308b5460-3d98-4528-bc39-5f44ae6dc279.mobileprovision
```

- `6d24d0d4-…` 是 `…xShadowsocks.xPacketTunnel`——扩展在免费 Team 下没有任何能力，
  这个 App ID 没有用处（付费账号会重新生成，能力也才对得上）。
- `308b5460-…` 属于已删除的 UI 测试 target。

删掉后重启 Xcode 再签名。

## 付费账号：启用系统 VPN

1. 在开发者后台为 App 与扩展的 App ID 开启 **Network Extensions** 与 **App Groups**。
2. 恢复 entitlements（文件里已用注释写好，取消注释即可）：
   - `xShadowsocks/xShadowsocks.entitlements`：App Group + `com.apple.developer.networking.networkextension`
   - `xPacketTunnel/xPacketTunnel.entitlements`：同上，且 App Group 必须一致
3. `AppGroupStore.appGroupID` 改成你自己的 App Group（三个地方保持一致）。
4. 给主 target 加回 **Embed App Extensions** 阶段：
   - Build Phases → + → New Copy Files Phase → Destination 选 *PlugIns*
   - 把 `xPacketTunnel.appex` 加进去（Code Sign On Copy）
   - 同时加一个 target dependency（app 依赖 xPacketTunnel）
   - `project.pbxproj` 里 App target 上方有对应注释说明这一段
5. 两个 target 用同一个付费 Team，扩展 bundle id 需与
   `TunnelManager.extensionBundleIdentifier` 一致。
6. 运行后到「设置 → 代理方式」选「系统 VPN」。首次会弹系统 VPN 授权。

## 目录结构

- `Shared/` — App 与扩展共同编译：App Group、路径、运行配置生成、内核桥接与宿主、
  utun 描述符解析、Clash API 客户端、隧道消息协议
- `xShadowsocks/` — 主 App：UI、ViewModels、订阅导入解析、本地代理宿主、隧道管理
- `xPacketTunnel/` — Packet Tunnel 扩展（付费账号启用）
- `MihomoCore.xcframework/` — mihomo 动态库
- `xShadowsocksTests/` — 单元测试（解析器、运行配置生成，含两种模式的差异）

## 已知限制

- 本地端口模式不接管系统流量，这是免费账号的固有限制，不是实现缺陷。
- 订阅的自动更新尚未接入后台任务，「设置」页只保留手动导入入口。
- 节点连通性测试是 App 进程发起的 TCP 握手，用于开启代理前的可用性筛选；
  隧道运行中的真实延迟应通过核心的 `/proxies/{name}/delay` 获取。
- 路由模式（配置/代理/直连）映射到 mihomo 的 `rule`/`global`/`direct`，
  修改后会重新生成运行配置并热重载。
