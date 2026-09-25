# 上游更新指南（Rebase 流程）

两边都用 rebase，不用 merge。**自己的 commit 很少**：主仓库 20 个（Cyril 的 4 个 Smart 补丁 + 我们自己的
CI／发布／测试／群组支持），内核子模块 4 个（chen 的适配补丁 + 我们 3 个 Smart fix）。
其余全部来自上游，因此更新基本是机械操作。

最近一次实测：**2026-10-03**。上游 ref：`chen08209/FlClash` main `4b59eca`、`vernesong/Alpha` `baef5ee5`、
`chen/Clash.Meta` `8597778c`。注意 vernesong 在 2026-10-01 的 `9150980a` 把 `component/smart/` 整个重写了：
`common.go` 与 `cachefile.go` 被删除，`memory.go` 改名 `cache.go`，新增 `store.go` / `target.go` / `exit.go`
（exit 探测 + 可疑出口判定）。所以内核那 3 个老冲突文件会变，Smart 侧的补丁要按新 API 解。

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

**内核分支 = `vernesong/Alpha` + chen 的适配补丁（cherry-pick，保留作者）+ 我们 3 个 Smart fix。**

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
git cherry-pick $(git rev-parse $BACKUP~2) $(git rev-parse $BACKUP~1) $(git rev-parse $BACKUP)  # 我们 3 个 Smart fix
```

### 内核已知冲突（2026-10-03 实测，chen 的适配补丁仍然只与这 3 个文件冲突）

| 文件 | 冲突原因 | 处理 |
|------|---------|------|
| `component/updater/update_geo.go` | chen 加 `sendGeoUpdateStatus`/`Chtimes`；vernesong 用 `geodata.VerifyGeodataBytes` 取代 `geoLoader` | 保留 chen 的状态通知 + **保留 vernesong 的 `VerifyGeodataBytes`**；不要恢复 `geodata.GetGeoDataLoader("standard")` |
| `tunnel/statistic/manager.go` | chen 加 6 个 `proxy*` 计数器；vernesong 加 `smartTarget` | **并集**（两者都留） |
| `tunnel/statistic/tracker.go` | chen 把变量改名 `tt` 并加 `Push*` 调用；vernesong 加 `trackerUUID`/`metadata.UUID` | 保留 UUID 行 + 用 `tt` 命名 |

我们那 3 个 Smart fix 里只有一个会冲突：`fix(smart): log LightGBM fallback reasons and model feature count`
在 `component/smart/lightgbm/lightgbm.go`。上游已经改了这套 API，**以上游为准**，只保留我们的日志：

- `transforms.IsCompatibleWith(getDefaultFeatureOrder())` → 上游变成 `transforms.IsCompatible()`（`getDefaultFeatureOrder` 已不存在）。
- `atomicRecord.Get("success").(int64)` 之类的字符串取值 → 上游用类型化访问器 `atomicRecord.Success()` / `.LossRate()`，用上游的。
- 我们加的 `log.Warnln("[Smart] LightGBM skipped: feature order incompatible, ...")` 和模型加载日志要留下。

处理原则：**保留 Smart 内核能力（LightGBM/leaves/smartTarget）+ 贴近 chen 的适配逻辑，适配新的 mihomo API。**
解决后 `gofmt`，并确认 `git grep -c '^<<<<<<<'` 为 0。

## 二、主仓库更新

```bash
git tag -f app-backup-$(date +%F) HEAD
git fetch upstream main
git rebase upstream/main
```

主仓库 20 个 commit，按性质分组（2026-10-03 实测的冲突面）：

| 类 | Commit | 内容 | 冲突 |
|------|--------|------|---------|
| Smart | `feat: Smart Core integration` | Model.bin + sha256、`core/hub.go` 的 MODEL 资源、controller、config 字段、`GeoResource.MODEL`、子模块指针、`core/go.mod\|go.sum` | 中：子模块指针、`core/go.mod|go.sum`、`lib/common/constant.dart` |
| Smart | `feat(groups): support smart proxy groups` | `GroupType.Smart`、DB 列、解析 | 低 |
| Smart | `feat(overwrite): keep smart group options through the editors` | 编辑器保留 6 个 smart 选项、编辑器行 | **高**：DB schema 与上游 `strategy` 撞车（见下表） |
| Smart | `chore(core): pick up the LightGBM updater temp dir fix` | 子模块指针 | 低（指针取新内核） |
| 包名 | `chore: rename package from com.follow.clash to com.flsmart.clash` | Android 包名、Gradle、平台配置 | **高**：upstream 重构过 Android 进程架构，import 列表全撞 |
| 文档 | `docs: update to rebase workflow guide` | REBASE_UPSTREAM.md（新）、READMEs、CLAUDE.md | 中：CLAUDE.md 上游已删 |
| 发布 | `chore: bump version …` / `chore(release): v0.8.100` | 版本号、Model.bin.sha256、CHANGELOG | 中：均为生成物 |
| CI/测试 | `ci:*`、`test(android)`、`test(views)`、`chore(codegen)` | 发布 job、dart 检查、包名测试、资源页行数 | 低～中：生成物 + 行数断言 |

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
| `lib/database/{groups,database}.dart` + `lib/models/clash_config.dart` | **并集**：上游的 `strategy`（v7 加的）与我们 5 个 smart 列（新的 v11：`policy_priority`、`use_light_g_b_m`、`collect_data`、`sample_rate`、`prefer_a_s_n`；`tolerance` 属于上游）。`schemaVersion` 取 **11**，smart 列的 `_addColumnIfMissing` 放进 `if (from < 11)`（幂等，能从我们 fork 旧的 v4 库直接升上来） |
| `test/database/generated_contract_test.dart` | 列数 24 → **29**（+5 列） |
| `test/database/migration_v1_to_v2_test.dart` | 版本断言 10 → 11；新增 `_downgradeToV10`（DROP 那 5 列，并让 `_downgradeToV9` 先调它）与 v11 升级测试 |
| `lib/**/generated/*.g.dart`、`*.freezed.dart` | **生成物**：取上游版本，rebase 结束后用 `dart run build_runner build --delete-conflicting-outputs` 重生成（见下） |
| `README.md` / `README_zh_CN.md` / `CHANGELOG.md` / `changelog.json` | 上游整篇重写／本身就是生成物：取上游；fork 的发布说明由 `tool/changelog.dart` 在发布时重生成 |
| `CLAUDE.md` | 上游已删除（内容并入 `AGENTS.md`）：删掉，把 fork 本地 CI 说明搬进本文件（见下） |
| `android/service/.../SuspendModule.kt` | 上游删掉了 Doze 挂起：跟随上游删除，`core.cpp` 的 `Core_suspended` 与 Kotlin 的 `suspended` 一起删 |
| `android/core/.../InvokeInterface.kt` | `onResult` 用上游的 `ByteArray?`（`Core.kt` 内已 `decodeToString()`），我们旧的 `String?` 不要 |
| `android/**` 其余 import 冲突 | 上游新增的 `Build`/`ContextCompat` 等保留，其余用 `com.flsmart.*` |

### fork 本地 CI 分歧（`build.yaml` 是上游文件，rebase 会重放上游版本，必须保留这几处）

- `upload` job 用 `if: false` 关掉。上游那个 job 会通过他们 runner 上的本地 bot API（`localhost:8081`）
  往 `@FlClash` 频道播报，然后删掉并重新发布 tag 的 release；本 fork 唯一的发布者是 `release-android-arm64.yml`。
- `Setup Android Signing` 只在对应 secret 存在时才写 `google-services.json` / `keystore.jks`。没有这个 guard 时，
  缺 `SERVICE_JSON` 会把空字符串解码到已签入的 stub 上，gradle 在 `processReleaseGoogleServices` 报
  `Malformed root json`，于是每个 tag 构建都挂而分支构建正常。
- `tool/check_dart.sh` 跑整个 dart job；`tool/check_submodules.sh` 会 fetch 每个子模块指针，避免子模块 commit
  还没推就推了指针（否则 CI checkout 报 `did not contain <sha>`）。它只格式化 `lib test tool setup.dart`，绝不碰 vendored 的 `plugins/`。

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
ls core/Clash.Meta/component/smart/*.go | wc -l                            # 7（重写后：cache/exit/response/stats/store/target/weight）
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
- [ ] **已知缺口（不是回归）**：群组编辑器 `lib/views/profiles/overwrite/custom/groups.dart` 没有 smart 选项行——
  6 个 smart 字段只存在于 DB 层与 `lib/models/clash_config.dart`。编辑器只改它自己那几行，其余字段由
  `ProxyGroup` 对象原地 `copyWith` 保留（由 `test/database/proxy_group_options_test.dart` 守护）。
  要“有开关”得自己加行，不要让 rebase 去追一个不存在的功能。
- [ ] CI 文件有 `ref: smart` 和 `com.flsmart.clash`
- [ ] 内核有 `case "smart"`、`component/smart/`、`component/updater/patch.go` 的 `GeoUpdateHook`
- [ ] 内核有 chen 适配的 `dns/patch.go`、`component/resolver/patch.go`、`tunnel/patch.go` 的 `*Snapshot`
- [ ] `core/` 与 `core/Clash.Meta/` 两个模块 `go build ./...` 通过
- [ ] arm64 APK 构建通过，`lib/arm64-v8a/{libclash.so,libcore.so,librust_api.so}` 均为 aarch64
