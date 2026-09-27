# 并行工作区

手机 App ↔ Pi 的远程通道之一（tile 名 = 本目录名）。全局指令（`~/AGENTS.md`）依然适用，
本文件只补充本工作区特有上下文。

- 面向手机屏幕：回复简洁，避免大段日志/diff；内容长时先落盘再给路径。
- 本目录只服务这个工作单元，产物放这里，别散进 `$HOME`。
- 主控是 `~/remote`（agent 名 `Jarvis`）：需要跨工作区协调时找它。

## 仓库与分支（fork 规范）

| remote | 仓库 | 权限 |
|---|---|---|
| `origin` | `fenlyin0420/remote_pi`（自己的 fork） | **唯一 push 目标**（已设 `remote.pushDefault=origin`，裸 `git push` 也只到这里） |
| `upstream` | `jacobaraujo7/remote_pi`（原作者） | 只读：**绝不 push、绝不发 PR** |

| 分支 | 用途 |
|---|---|
| `main` | 上游纯镜像，**禁止写任何自定义代码**（定制文件如本文件都不在 main 上） |
| `dev` | 所有定制工作的长期主线——日常在这里合并、发布 |
| `feat/...` `fix/...` | 从 `dev` 切，做完 merge 回 `dev` 并删分支 |

同步上游：`git fetch upstream` → 先看 `git log dev..upstream/main` / `git diff dev upstream/main`
→ 满意了再 `git switch dev && git merge upstream/main`（**别在 main 上做定制**）。
`gh` 已 `repo set-default` 到 fork（`gh` 默认会挑名为 `upstream` 的 remote，不钉死会打到原作者仓库）。

## 交付方式（固定流程）

> 细节与踩坑全在 `~/.agents/memory/remote-pi-in-app-update.md`（发版步骤 / 版号规则 / 签名 /
> ZIP 与 JDK 坑）与 `remote-pi-beta-channel.md`（双通道）。**发版前先读它们。**

**两个通道，两种节奏**：改动先打**测试版**（`-beta.N` 版号 + `beta` flavor，装得上、和正式版共存）
只推测试通道，用户测完确认后，再打**正式版**（干净版号 + `prod` flavor）推正式通道 + GitHub Release。
**不要跳过测试直接发正式版**（2026-09-27 发 1.5.11 时越过，用户明确要求改正）。

1. 从 `dev` 切 `feat/...`/`fix/...` 做，全部测试 + analyze/typecheck 绿后 merge 回 `dev`。
2. 打 APK。环境：`export PATH=$HOME/flutter/flutter/bin:$HOME/jdk-21.0.12.1+1/bin:$PATH`、
   `JAVA_HOME=$HOME/jdk-21.0.12.1+1`、`ANDROID_HOME=$HOME/Android/Sdk`
   （系统 `/usr/lib/jvm` 那几个是 JRE，没 javac），在 `app/` 下（**必须带 `--flavor`**，
   不带会把两个 flavor 都编一遍且 beta 会用 pubspec 的版号）：
   ```bash
   # 测试版（只推测试通道，不发 GitHub release）
   REMOTE_PI_HOSTS=1.15.13.177 flutter build apk --release --flavor beta \
     --target-platform android-arm64 --build-name=1.5.12-beta.1 --build-number=32 \
     --dart-define=UPDATE_MANIFEST_URL=http://1.15.13.177:3210/downloads/app-beta/latest.json
   # 正式版
   REMOTE_PI_HOSTS=1.15.13.177 flutter build apk --release --flavor prod \
     --target-platform android-arm64 \
     --dart-define=UPDATE_MANIFEST_URL=http://1.15.13.177:3210/downloads/app/latest.json
   ```
   产物：`build/app/outputs/flutter-apk/app-{beta,prod}-release.apk`。
   两个输入缺一个，装上去的 App 就**没有更新通道**（卡片永远说“已是最新”）、也没有明文例外。
3. **推下载站**（用户手机的更新提示只看这里；两个通道各自的 `latest.json` 的 `version`
   必须等于该 APK 的 versionName、且大于已装版本）：scp APK + manifest 到 cloud177，
   `sudo install` 到 `/var/lib/remote-pi-downloads/{app,app-beta}/{RemotePi.apk,RemotePiBeta.apk,latest.json}`。
4. **三条都要核**：①APK 里 `strings lib/arm64-v8a/libapp.so` 能搜到该通道的 manifest URL；
   ②`aapt dump badging` 的 versionName/applicationId 对（beta = `…remotepi.beta`）；
   ③`curl -o /tmp/s.apk .../<channel>/<apk>` 下来 sha256 与本地一致。
5. 测完确认后发正式版：push 到 `origin`（自己的 fork），发 Release
   （`--target <分支>`），标题/正文用英文，APK 命名 `remote-pi-<版本>-arm64-signed.apk`；
   发完 `gh release view --json` 自查 + 回下载对 sha256。**绝不 push 到 `upstream`（原作者），不发 PR。**
6. Pi 侧（pi-extension）改动要同时给用户可用：`npm pack` 出 tgz，挂到同一个 Release，
   然后 `cd ~/.pi/agent/npm && npm install ./remote-pi-<版本>.tgz`。
   **supervisor 重启会杀掉所有房里正在跑的 turn（包括本会话）——只提醒用户自己执行；
   本机是 system unit 且 sudo 需密码，可用 `kill -TERM <supervisord pid>` 让 systemd
   （`Restart=always`）自己拉起，但一定先让回复发出去。见 `remote-pi-extension-load-path`。**

## 当前状态

- **房间管理（`SPEC-room-management.md`）已交付**（已并入 `dev` 并随 1.5.x 系列发过
  Release；给原作者的 PR #199 还开着，head 分支 `pr/room-management` 别删），任务书保留作
  参考，不用重做。
- **手机命令通道已交付**（已并入 `dev`；0.8.0 / App 1.5.11+31），
  Release `v1.5.11-commands-arm64`（APK + `remote-pi-0.8.0.tgz`），1.5.11 已推正式通道并校验，
  supervisor 已重启（`op:"rpc"` 生效）。
  手机 composer 支持 `/slash`（daemon 房走 RPC 通道跑扩展命令/技能/模板，其余内置
  自己映射）和 `!shell`（本机 shell，出 bash 卡片，`!!` 不进模型上下文）。
  设计文档：`PROTOCOL.md` 的 “Canal de comandos” + `pi-extension/README.md`；
  实现要点记在 `~/.agents/memory/remote-pi-command-channel.md`。
- **测试通道（`beta` flavor + 下载站 `app-beta`）已建好**：首个测试包 `1.5.12-beta.1`(+32)
  已推测试通道（appId `work.jacobmoura.remotepi.beta`，与正式版共存）。改动：
  `app/android/app/build.gradle.kts`（flavor + `@string/app_name`）、
  `rp-s3/selfhost/download_server.py`（`app-beta` 通道），已并入 `dev`。

不用 `agent_send` 向 Jarvis 汇报，进展直接在本会话回复用户。
