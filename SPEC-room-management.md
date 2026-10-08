# 任务 spec：房间管理（新建/删除 room）+ 工具调用开关按 room 隔离 + 打包 APK 发 Release

仓库：`jacobaraujo7/remote_pi` 的 fork（`fenlyin0420/remote_pi`）。
git remote：`origin` = 自己的 fork（唯一 push 目标）；`upstream` = 原作者仓库（只读，**不要 push、不要发 PR**）。
分支：`main` = 上游纯镜像（不写定制代码），`dev` = 定制主线。

**新建分支 `feat/room-management` 做所有改动，完成后 merge 回 `dev` 并 push 到 `origin`（自己的 fork）。**

---

## 功能 1：手机 App 新建 room（daemon + App）

### Daemon 侧（`pi-remote/`）

1. `src/protocol/types.ts`：
   - `ClientMessage` 增加两个成员：
     - `{ type: "room_create"; id: string; path: string; create_if_missing?: boolean }`
     - `{ type: "room_delete"; id: string; path: string }`
   - `ActionName` 联合类型追加 `"room_create" | "room_delete"`。
2. `src/index.ts`：在 client message 的 action switch（`model_set`/`thinking_set` 所在的
   switch，见 `case "model_set"` 附近）加两个 case：
   - **room_create**：
     a. 归一化 path：trim、`~`/`~/x` 展开为 `$HOME`、相对路径按 `process.cwd()` resolve
        （参照 `daemon/registry.ts` 的 `normalizeCwd` 逻辑，但不要直接调用它——它会
        `realpathSync` 对不存在路径抛错；自己先做字符串归一化）。
     b. `fs.existsSync(normalized)` 为 false 且 `create_if_missing` 非 true →
        `action_error`，error 字段**必须**是精确字符串 `directory_missing`（App 侧靠它
        触发二次确认对话框，不要带其他文字）。
     c. 目录不存在且 `create_if_missing === true` → `fs.mkdirSync(p, { recursive: true })`。
     d. `await callSupervisor({ op: "register", cwd: normalized })`
        （import 自 `./daemon/client.js`），再 `await callSupervisor({ op: "start", id })`
        让新 daemon 立即拉起。
     e. 成功发 `action_ok`；抛错（含 `SupervisorOfflineError`）发 `action_error`
        （error 用异常 message）。
   - **room_delete**：
     a. 同样归一化 path。
     b. `const id = daemonIdForCwd(normalized)`（import 自 `./daemon/id.js`）。
     c. `await callSupervisor({ op: "unregister", id })` —— supervisor 的
        `_opUnregister` 会先 `child.stop()` 杀掉进程再从注册表移除，满足「从监控列表
        去除 + 结束进程」。
     d. 成功 `action_ok`（即使该 id 本就不在注册表，`removed:false` 也算 ok）；
        异常发 `action_error`。
   - 注意：这两个 handler 与 session 无关，不依赖 `_pi`/ctx；但 index.ts 是
     单例模块，直接加函数即可。错误处理要 catch-all，绝不让异常冒泡到 WS
     回调（参考同文件 model_set 的 try/catch 风格）。
3. 跑 `cd pi-remote && npx vitest run`（或 package.json 里的 test script，需要时先
   `npm install`）确认全绿；再跑 `npx tsc --noEmit`（typecheck script）。
   可以顺手为两个新 handler 补少量单测（看现有 extension.test.ts 风格，非强制）。

### App 侧（`app/`，Flutter）

UI 全部走现有的 relay WS：App 与 relay 是单条长连接，出站帧外层信封带 `room` 字段
（见 `lib/data/transport/connection_manager.dart` 的 `switchRoom` /
`_propagateActiveRoom`）。所以从 Home 页发起 room_create 的流程是：

1. `lib/protocol/protocol.dart`：
   - `ActionName`（或等价的 Dart 枚举，见 `sessionCompact('session_compact')` 附近）
     加 `roomCreate('room_create')`、`roomDelete('room_delete')`。
   - 加两个 message 类（参照 `ModelSet` 的 toJson 风格）：
     `RoomCreate { id, path, createIfMissing }`、`RoomDelete { id, path }`，
     接入 decode（`'action_ok' => ActionOk.fromJson(json)` 那个 switch 的入站侧
     不需要新类；但 ClientMessage 的构造/编码路径要能送出这两类帧）。
2. `lib/data/actions/actions_repository.dart`（或等价的 actions 通道）：
   确认现有 `sendAction` 能透传新 ActionName（应该是按字符串透传的，读一下确认）。
3. **新建 room 按钮**：
   - Home 页（`lib/ui/home/home_page.dart`）顶部/角落加「新建房间」按钮（icon:
     `Icons.add_home_outlined` 或类似，风格跟随现有 UI）。
   - 点击 → `showDialog` 文本输入框，placeholder：`目录路径，如 ~/projects/foo`，
     标题「新建房间」。
   - 选定目标 room：用 `ConnectionManager.roomsFor(epk)` 找该 peer 下第一个
     **live**（在 `_liveRoomIds` 里）的 room；没有任何 live room 时 toast
     「请先打开任意一个房间」。
   - `conn.switchRoom(liveRoomId)` → 发 `RoomCreate(path)` → 等
     `action_ok`/`action_error`（带超时，如 15s，参照现有 actions 通道）→
     **无论成败把 active room 切回原来的**（switchRoom 回原值）。
   - `action_error` 且 `error == 'directory_missing'` → 弹确认对话框
     「目录不存在，是否创建？」→ 用户确认则重发 `RoomCreate(path, createIfMissing: true)`
     （同样流程）；取消则什么都不做。
   - `action_ok` → toast「房间已创建」。新 room 由 daemon 侧自动上报 relay，
     Home 的 `roomsStream` 会自动刷新出新 tile（不需要 App 手动插数据）。
   - 其他 error → toast 错误信息。
   - 新建按钮放在哪个 peer 上：多 peer 时取「当前 selected peer」
     （`Preferences.selectedPeerEpk`），没有就取第一个有 live room 的 peer。
4. **删除 room**：
   - Home 的 room tile（`session_tile.dart` 等）加长按菜单或图标按钮「删除房间」
     （删除图标 `Icons.delete_outline`），带确认对话框「删除房间 X？该目录的 agent
     进程会被终止」。
   - 确认后：同 3 的 room 选择逻辑（找同 peer 的一个 live room）→ 发
     `RoomDelete(path: room.cwd)`（`RoomInfo.cwd` 已有该字段）→ 等待回复 → 切回。
   - `action_ok` 后：把该 room 从 App 本地缓存里移除，使 Home 不再显示这个 tile
     （查 `ConnectionManager` 的 `_roomsByPeer` / 持久化缓存怎么写的，找到把
     cached room 清掉的方法；若没有现成方法，在 ConnectionManager 加一个
     `forgetRoom(epk, roomId)`：从 `_roomsByPeer`、持久化存储移除，并 notify
     `roomsStream`）。
   - 注意删除的是**该 room 自己**（用它的 cwd），不是发令的 room。

## 功能 2：工具调用显示开关改为 room 级

现状：全局开关 `hideToolCalls`（`lib/data/preferences/preferences.dart`，
key `prefs.hide_tool_calls`），UI 在 `lib/ui/settings/settings_page.dart:342`。

改法：
1. `Preferences` 加 per-room 存储：一个 JSON blob
   （key 如 `prefs.hide_tool_calls_rooms`），结构
   `{"<epk>:<roomId>": true/false}`，提供
   `bool hideToolCallsFor(String epk, String roomId)`（无记录时 false）和
   `setHideToolCallsFor(epk, roomId, bool)`。保留旧的全局字段做兼容（迁移不必要）。
2. 从 `settings_page.dart` **移除**该开关。
3. 在 chat 的 Quick Actions sheet（`lib/ui/chat/quick_actions/quick_actions_sheet.dart`，
   那里已有 thinking level 等 room 级控件）加一个「隐藏工具调用」switch，
   用当前 room 的 (epk, roomId) 读写 per-room 值。
4. chat 里决定 ToolEvent 行显示/隐藏的地方（grep `hideToolCalls` 找所有消费点）
   全部改为读 per-room 值。
5. `flutter analyze` 必须干净；`flutter test` 全绿（如有相关测试要同步改）。

## 打包 APK + 发布 Release

1. Flutter SDK 在 `/opt/flutter`（装好后先跑 `/opt/flutter/bin/flutter --version`
   完成初始化；`export PATH=/opt/flutter/bin:$PATH`）。
2. Android SDK：若没有，装 cmdline-tools（
   `https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip`
   或从 `https://dl.google.com/android/repository/repository2-3.json` 查最新版），
   解压到 `~/Android/Sdk`，`export ANDROID_HOME=$HOME/Android/Sdk`，
   `sdkmanager --licenses` 全部接受（`yes |`），再
   `flutter doctor --android-licenses`。
3. `cd app && flutter pub get` → `flutter build apk --debug`
   （产物 `build/app/outputs/flutter-apk/app-debug.apk`）。
   不要动 build 配置；若编译报错就修最小问题（可能是 SDK 版本/依赖版本，
   必要时 `flutter pub upgrade --major-versions` 慎用，先最小改动）。
4. push：`git push origin feat/room-management`（**只 push 到自己的 fork，
   绝不 push 到 upstream，绝不给作者发 PR**）。
5. 在 fork 上发 Release：
   `gh release create "v2.x-room-management" --target feat/room-management \
     app-debug.apk`（名字自定，标题说明这是带房间管理功能的构建；
   `gh` 已登录 fenlyin0420 且 `repo set-default` 钉到 fork——
   仍要确认 `gh` 认的是 fork：`gh repo view --json nameWithOwner`；
   `gh` 默认会挑名为 `upstream` 的 remote，不钉死就打到原作者仓库）。

## 验收标准

- `pi-remote` typecheck + 全部测试绿。
- `flutter analyze` 干净 + `flutter test` 绿。
- 分支已推到自己的 fork；Release 已创建且带 APK 附件。
- 改动风格贴合仓库现有代码（注释密度、命名、错误处理），不要引入新依赖
  （App 侧不加新 pub 包；daemon 侧不加新 npm 依赖）。

## 环境备注

- Node 在 PATH（v25.9.0）。pi-remote 若没 node_modules，先 `npm install`。
- 网络直连可用（GitHub、Google 存储均可达）。
- 这是 fork 仓库，`origin` remote 是自己的 fork——push/gh 操作一律用 `origin`。
