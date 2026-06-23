# 上游更新指南（Rebase 流程）

两边都用 rebase，不用 merge。重构后（2026-09-26）**自己的 commit 只剩 6 个**：
主仓库 4 个、内核子模块 2 个。其余全部来自上游，因此更新基本是机械操作。

## 项目结构

```
主仓库（Flutter + Go 桥接）
├── origin:   你的 fork（如 leiyangyou/FlClashSmart）
├── upstream: chen08209/FlClash              ← 主仓库上游
├── satar07:  Satar07/FlClashSmart           ← 来源 fork（可选，用于对比）
│
├── lib/ … android/ …                      ← chen08209/FlClash + 4 个 Smart commit
│
└── core/Clash.Meta（子模块）= 内核
    ├── origin:    你的内核 fork（如 leiyangyou/FlClashCore，分支 FlClash-smart-rebase）
    ├── vernesong: vernesong/mihomo Alpha    ← Smart 内核上游（LightGBM/leaves）
    └── chen:      chen08209/Clash.Meta      ← FlClash 适配补丁来源
```

**内核分支 = `vernesong/Alpha` + chen 的适配补丁（cherry-pick，保留作者）+ 我们 2 个 Smart fix。**

关键点：**不再维护自己的适配补丁副本**。以前内核里有一个第三方（Cyril）的适配补丁，与 chen 的补丁平行演进，
导致 chen 的适配改进进不来、每次更新都要手工重解。现在 chen 的适配补丁整块 cherry-pick 进来，
冲突只发生在 vernesong 与 chen 都改过的少数文件（见下表，实测 3 个）。

## 前置

三个内核 remote 用 https（部分网络下 SSH 会被拦截）：

```bash
cd core/Clash.Meta
git remote set-url origin     https://github.com/<你>/FlClashCore.git
git remote set-url vernesong  https://github.com/vernesong/mihomo.git
git remote set-url chen       https://github.com/chen08209/Clash.Meta.git
```

## 一、内核子模块更新

先打备份 tag（回滚用），再按情况选 A 或 B。

```bash
cd core/Clash.Meta
git tag -f kernel-backup-$(date +%F) HEAD
git fetch vernesong Alpha
git fetch chen FlClash
```

**情况 A：只有 vernesong 前进，chen 未变**

```bash
# 把「chen 适配 + 我们的 fix」整体搬到新的 vernesong/Alpha 上
git rebase --onto vernesong/Alpha $(git rev-parse chen/FlClash) FlClash-smart-rebase
```

**情况 B：chen 也更新了**（chen 的适配 commit 是 force-rebase 的单 commit，SHA 会变）

```bash
BACKUP=kernel-backup-$(date +%F)
git checkout -B FlClash-smart-rebase vernesong/Alpha
git cherry-pick -x $(git rev-parse chen/FlClash)          # chen 的最新适配补丁
git cherry-pick $(git rev-parse $BACKUP~1) $(git rev-parse $BACKUP)   # 我们 2 个 Smart fix
```

### 内核已知冲突（2026-09-26 实测，只有这 3 个文件）

| 文件 | 冲突原因 | 处理 |
|------|---------|------|
| `component/updater/update_geo.go` | chen 加 `sendGeoUpdateStatus`/`Chtimes`；vernesong 用 `geodata.VerifyGeodataBytes` 取代 `geoLoader` | 保留 chen 的状态通知 + **保留 vernesong 的 `VerifyGeodataBytes`**；不要恢复 `geodata.GetGeoDataLoader("standard")` |
| `tunnel/statistic/manager.go` | chen 加 6 个 `proxy*` 计数器；vernesong 加 `smartTarget` | **并集**（两者都留） |
| `tunnel/statistic/tracker.go` | chen 把变量改名 `tt` 并加 `Push*` 调用；vernesong 加 `trackerUUID`/`metadata.UUID` | 保留 UUID 行 + 用 `tt` 命名 |

处理原则：**保留 Smart 内核能力（LightGBM/leaves/smartTarget）+ 贴近 chen 的适配逻辑，适配新的 mihomo API。**
解决后 `gofmt`，并确认 `git grep -c '^<<<<<<<'` 为 0。

## 二、主仓库更新

```bash
git tag -f app-backup-$(date +%F) HEAD
git fetch upstream main
git rebase upstream/main
```

| 顺序 | Commit | 内容 | 冲突风险 |
|------|--------|------|---------|
| 1 | `feat: Smart Core integration` | Model.bin、hub.go、controller、config 字段、`GeoResource.MODEL`、子模块指针、`core/go.mod|go.sum` | 低 |
| 2 | `chore: rename package from com.follow.clash to com.flsmart.clash` | Android 包名、Gradle、平台配置 | 高（upstream 重构 Android 进程架构时大冲突） |
| 3 | `docs: update to rebase workflow guide` | CLAUDE.md、REBASE_UPSTREAM.md | 低 |
| 4 | `chore: bump version …` | 版本号、Model.bin.sha256 | 低 |

### 主仓库已知冲突

| 文件 | 策略 |
|------|------|
| `pubspec.yaml` | 版本号用上游 +1（如上游 `0.8.98+2026091401` → `0.8.99+2026091402`）；依赖用上游 |
| `.github/workflows/build.yaml` | 保留 Smart 的 CI（`ref: smart`）；上游已删除 changelog 自动生成 job 与 `.github/scripts/generate_release_notes*.sh`，跟随上游 |
| `android/*/build.gradle.kts` | 保留 `com.flsmart.clash` 的 `namespace`/`applicationId` |
| `android/core/build.gradle.kts` | 跟随上游（`copyNativeLibs` 已废弃，改用 setup hook + native task guard） |
| `core/Clash.Meta` | 保留新的内核指针（rebase 后指向重构后的内核 HEAD） |
| 所有 `com.follow.clash` | 仅限上一个 commit 触及的文件；`plugins/wifi_ssid` 与部分 `test/` 保留原包名 |
| `lib/enum/enum.dart` | 保留 `GeoResource.MODEL`（`@JsonValue('model')`） |
| `lib/models/clash_config.dart` | `defaultGeoXUrl` 保留 `GeoResource.MODEL` |
| `lib/state.dart` | 上游已把对话框迁到 `lib/common/dialog.dart`，Smart 侧多出的 `showMessage` 为死代码，删除 |

### Rebase 后（必做）

```bash
# 1. 同步 Go 依赖（两个模块都要）
cd core/Clash.Meta && go mod tidy && cd ../..
cd core && go mod tidy && cd ..

# 2. 把新内核指针 + tidy 结果折进「Smart Core integration」commit
git add core/Clash.Meta core/go.mod core/go.sum
git commit --fixup=$(git log --format=%h --grep='Smart Core integration' -1)
GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash upstream/main
```

## 三、验证

```bash
# Go 两个模块
cd core/Clash.Meta && go build ./... && go test ./dns/ -count=1 && cd ../..
cd core && go build ./... && cd ..

# Smart / 适配标记
grep -c 'case "smart"' core/Clash.Meta/adapter/outboundgroup/parser.go     # 1
ls core/Clash.Meta/component/smart/*.go | wc -l                            # 6
ls core/Clash.Meta/dns/patch.go core/Clash.Meta/component/resolver/patch.go # chen 的适配
grep -c 'GeoUpdateHook' core/Clash.Meta/component/updater/patch.go         # 3
grep -c 'smartTarget' core/Clash.Meta/tunnel/statistic/manager.go          # 4

# Android APK（只编 arm64）
export PATH=$HOME/.local/rustshim:$PATH
export JAVA_HOME=/Users/leiyang/Library/Java/JavaVirtualMachines/azul-17.0.3/Contents/Home
export ANDROID_HOME=/opt/adt-bundle-mac-x86_64/sdk
mise exec flutter@3.47.1 -- flutter build apk --debug --target-platform android-arm64
```

本机环境备注（否则 native assets hook 会失败）：

- Flutter 用 CI 的 pin 版本（见 `.github/workflows/build.yaml` 的 `FLUTTER_VERSION`；当前 3.47.1）。
  mise 里若只有旧版本会因 `riverpod_generator` 需要 Dart ≥3.12 而 `pub get` 失败。
- NDK 用 `android/gradle/libs.versions.toml` 的 `ndkVersion`（当前 `28.2.13676358`），
  `sdkmanager --sdk_root=$ANDROID_HOME "ndk;28.2.13676358"`。
- `~/.local/rustshim/rustc` 是一个指向 rust-toolchain.toml 所 pin 的 1.95.0 的包装脚本：
  Homebrew 的 rustc（1.98.1）在 PATH 上更靠前，而 hook 会过滤掉 `RUSTC` 环境变量，所以只能从 PATH 入手。
  脚本内容：`exec "$HOME/.rustup/toolchains/1.95.0-aarch64-apple-darwin/bin/rustc" "$@"`
- `File modified during build. Build must be rerun.` 是已知现象：Go core hook 在构建期间写
  `android/core/src/main/jniLibs`，Flutter 会自动重跑一次 gradle。

## 四、Smart 功能验证清单

- [ ] `assets/data/Model.bin` 存在，且与 `assets/data/Model.bin.sha256` 一致（30 特征模型：文件头 `max_feature_idx=29`）
- [ ] `lib/common/constant.dart` 有 `MODEL`、`modelAssetHashFile`
- [ ] `lib/enum/enum.dart` 的 `GeoResource` 含 `MODEL`
- [ ] `lib/models/clash_config.dart` 的 `defaultGeoXUrl` 含 `GeoResource.MODEL`
- [ ] `lib/views/resources.dart` 处理 `GeoResource.MODEL`
- [ ] CI 文件有 `ref: smart` 和 `com.flsmart.clash`
- [ ] 内核有 `case "smart"`、`component/smart/`、`component/updater/patch.go` 的 `GeoUpdateHook`
- [ ] 内核有 chen 适配的 `dns/patch.go`、`component/resolver/patch.go`、`tunnel/patch.go` 的 `*Snapshot`
- [ ] `core/` 与 `core/Clash.Meta/` 两个模块 `go build ./...` 通过
- [ ] arm64 APK 构建通过，`lib/arm64-v8a/{libclash.so,libcore.so,librust_api.so}` 均为 aarch64
