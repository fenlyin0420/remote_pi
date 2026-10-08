# 任务 spec：后台常驻连接 + 消息通知（像 QQ/微信那样）

仓库：`fenlyin0420/remote_pi`（fork）。基线分支 `feat/room-management`（含房间管理与 App 内更新），
新分支 **`feat/background-connection`**（已 push 到 fork）。**不改 relay / pi-remote 协议**，纯 app 侧。

> **状态：已实现，1.4.0+11 已构建（签名与 1.3.x 一致），616 个测试 + analyze 全绿。**
> 仅原生路径无仪器化测试 → 需真机验收（见文末）。

## 需求

手机 App 退到后台后仍保持与 relay 的 WS 长连接；Pi 侧 agent 干完一轮活，
手机收到系统通知（横幅/锁屏），点通知直接进对应 room 的聊天页。

## 硬约束（不可绕）

1. **Android 要求常驻进程必须显示一条通知**（前台服务）。所以会有"正在运行"的常驻通知，
   低优先级、静默。做不到"无感常驻"。
2. **国产 ROM 会杀后台服务**：需要用户在系统里把 App 设为"不限制后台/允许自启动"，
   spec 里给设置入口。系统级推送通道（小米/华为 push）不在此范围（要厂商账号 + 服务端）。
3. **从最近任务划掉 App** 会杀进程 → 连接与通知停止（除非手动"锁定"任务）。只在按 Home 键
   退到后台时保持。
4. 仅 Android。iOS 需要另一套机制（后台任务/BGAppRefresh），本期不做。

## 设计

### 1. 保活：前台服务（原生 Kotlin）

- `ConnectionKeeperService`：`foregroundServiceType="specialUse"`
  （**不用 `dataSync`**：Android 15 起 dataSync 前台服务有 6 小时/日的上限；`specialUse` 无超时，
  在 Manifest 里用 `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` 说明用途）。
- 作用：把进程钉在 foreground 优先级 → Flutter 主 isolate 继续跑 → `WsTransport` 的
  WebSocket、25s ping、15s watchdog、重连退避（上限 30s）都继续工作。Dart 侧无需搬 isolate。
- `START_STICKY`；引擎未附着时自停（避免"僵尸通知"）。
- 通知渠道 `connection`（IMPORTANCE_LOW、无声、ongoing）。

### 2. 通知：原生实现（不用 flutter_local_notifications）

理由：省一个 pub 依赖 + desugaring 配置 + 版本兼容风险；本项目已有"原生 MethodChannel"
先例（in-app update / identity transfer）。渠道 `messages`（IMPORTANCE_HIGH、有声）。

### 3. 触发：带 room 标记的事件流（关键改动）

事实：relay 转发 Pi→app 时把 `room` 改写成**发送方 daemon 的 room_id**，而 app 的
`WsTransport` 现在会 **直接丢弃 `room != 当前激活 room` 的帧**。也就是说后台时只有"当前房间"
的事件可见 —— 而用户有多个工作区，需要任何房间干完活都能通知。

改法：
- `WsTransport` 收到 envelope：**照旧**把"当前 room / 无 room（legacy）"的帧压进 DB 队列；
  同时**所有**帧（含其他 room）都投到新的 `roomFrames` 流（`RoomFrame{roomId, payload}`）。
- `PlainPeerChannel` / `ConnectionManager` 透出 `roomMessages`（`{epk, roomId, ServerMessage}`）。
- 语义不变：非当前 room 的帧依旧不写 DB（不会串房间）。

### 4. 触发与抑制（`RoomActivityNotifier`）

- 按 `agent_chunk` 在内存里按 room 累积本轮文本（上限 ~1KB，仅用于通知预览）。
- `agent_done`（= Pi-ext 的 `agent_end`，"这一轮干完了，轮到你"）→ 发通知。
- 抑制条件：`AppLifecycleState.resumed` **且** `VisibleChat`（新加的运行时状态，Chat 打开时置位、
  关闭时清除）就是该 (epk, room) → 不发（用户正看着）。
- 通知标题 = room 本地名 / room name / cwd 末段；副标题 = 设备名（nickname / sessionName）；
  正文 = 本轮最后一行的截断预览。
- 点击 → 原生 PendingIntent 带 `epk`/`room` → MainActivity 转给 Dart → App 切 room + push `/chat`。
- 同一 room 的通知 id 固定（新的替换旧的），点击后自动消失。

### 5. 开关与权限（设置页）

一个总开关「Background connection」：
- 打开 → 请求 `POST_NOTIFICATIONS` → 启动前台服务。
- 关闭 → 停服务（不再后台保活，也不再发通知）。
- 附一行状态：通知权限状态（被禁 → 一键跳系统设置）、电池优化状态（未白名单 → 一键申请）。
- 默认开；配对后自动生效；没有任何 peer 时自动停（省电）。

## 文件清单

原生：
- `app/android/app/src/main/kotlin/work/jacobmoura/remotepi/ConnectionKeeperService.kt`（新）
- `.../AppNotifications.kt`（新：渠道、发通知、点击 Intent）
- `.../MainActivity.kt`（加 `work.jacobmoura.remotepi/background` 频道）
- `AndroidManifest.xml`（POST_NOTIFICATIONS / FOREGROUND_SERVICE(_SPECIAL_USE) /
  REQUEST_IGNORE_BATTERY_OPTIMIZATIONS / service 声明）

Dart：
- `lib/domain/contracts/background_connection.dart`、`lib/domain/contracts/message_notifier.dart`（新）
- `lib/data/background/method_channel_background_connection.dart`、`.../method_channel_notifier.dart`（新）
- `lib/data/notify/room_activity_notifier.dart`（新，服务：触发/抑制/开关同步）
- `lib/data/transport/{channel,ws_transport,peer_channel,connection_manager}.dart`（room 事件流）
- `lib/routing/adaptive.dart`（`VisibleChat`）、`lib/routing/app_router.dart`（通知点击深链）
- `lib/data/preferences/preferences.dart`（`backgroundConnection` 开关）
- `lib/config/dependencies.dart`、`lib/main.dart`（装配与生命周期）
- `lib/ui/settings/*`（开关 + 权限行）、`lib/ui/chat/viewmodels/chat_viewmodel.dart`（VisibleChat 置位）

## 实现落点（与原计划的差异）

| 项 | 结论 |
| --- | --- |
| 前台服务类型 | `specialUse`（**不是** `dataSync`：Android 15 起 dataSync 有 6h/日上限） |
| 通知实现 | **原生 Kotlin**（`AppNotifications` + `.../notifications` 通道），不引 `flutter_local_notifications`：minSdk 34 够用，省一个依赖 + desugaring |
| 通知权限时机 | 首次「开启保活」时请求（= 有 peer 的启动，或刚配对完），每次进程只问一次 |
| 通知粒度 | `agent_done` 一次 + provider 错误（`error`）一次；工具/回显/同步不通知 |
| 正文 | 按 room 在内存累积 `agent_chunk`（上限 1KB），取最后一行、去 markdown、截 160 字 |
| 抑制 | 前台且 `VisibleSession` 就是该 (epk,room) → 不发；进入聊天会顺手清掉该 room 的横幅 |
| 设置页 | 一个总开关「Stay connected」+ Notifications / Battery / **Service（运行中/已停止，可 Restart）** 三行状态 |
| 命名统一 | 新增 `domain/value_objects/session_label.dart`，Home 列表 / 聊天标题 / 通知标题共用 |

## 验收

1. ✅ `flutter analyze` 零问题、`flutter test` 全绿（616，含新增 4 个测试文件）。
2. ✅ release APK 构建通过（`1.4.0+11`，release keystore，arm64）；manifest 内已含
   `POST_NOTIFICATIONS` / `FOREGROUND_SERVICE(_SPECIAL_USE)` / `specialUse` 服务声明。
3. ⏳ 真机验收（**只能用户做**）：
   - 打开开关 → 通知栏出现「Remote Pi」常驻通知；设置页 Service 行显示 Running。
   - 退到后台，让 Pi 侧 agent 跑完一轮 → 收到通知；点通知进对应 room。
   - 停在聊天页不退后台 → 不重复弹通知。
   - 多工作区（两个 room）→ 任一 room 干完都通知，标题区分 room。
   - 划掉最近任务 → 通知消失（预期行为）。

## 未覆盖 / 已知限制

- 原生路径无 instrumented test：`flutter test` 绿不等于真机行为正确（老教训）。
- iOS 无此功能（需另一套机制）；`MethodChannel*` 在非 Android 是 no-op。
- `specialUse` 若将来上架 Google Play 需在 Play Console 填用途说明。
- 划掉最近任务即断开（不自动复活）；国产 ROM 仍需电池白名单（设置页有入口）。
