# CLAUDE.md

This repository uses [AGENTS.md](AGENTS.md) as the canonical agent entry point.
Read that file first, then follow the `.agents/` references it routes to.

## Rebase Upstream

When updating from upstream, follow the rebase guide at `REBASE_UPSTREAM.md`.

Own commits are deliberately few: 17 in the app repo (the 4 Smart patches plus the CI, release, test and group-support work), 4 in the kernel submodule (chen's adaptation patch plus our 3 Smart fixes). Everything else is upstream.

- **Core submodule** (`core/Clash.Meta`) = `vernesong/Alpha` + chen's adaptation patch (`git cherry-pick -x $(git rev-parse chen/FlClash)`) + our 3 Smart fixes. Do NOT hand-maintain a parallel copy of chen's adaptation patch.
- **App repo** = `chen08209/FlClash` main + 4 Smart patches (`git rebase upstream/main`).
- Keep the submodule on branch `FlClash-smart-rebase` (origin = your own kernel fork).
- Known kernel conflicts when replaying chen's patch (measured 2026-09-26, exactly these three):
  - `component/updater/update_geo.go` — take chen's `sendGeoUpdateStatus`/`Chtimes`, keep vernesong's `geodata.VerifyGeodataBytes` (never restore `geoLoader`)
  - `tunnel/statistic/manager.go` — union: chen's `proxy*` counters **and** vernesong's `smartTarget`
  - `tunnel/statistic/tracker.go` — keep vernesong's `trackerUUID`/`metadata.UUID`, keep chen's `tt` naming
- Keep Smart kernel capability (LightGBM/leaves/smartTarget) and FlClash adaptation (`GeoUpdateHook`, `ProvidersSnapshot`/`RuleProvidersSnapshot`/`InvalidateAllProxies`, `StopGeoUpdater`).
- Keep own CI (`ref: smart`, package name `com.flsmart.clash`).
- **Fork-local `build.yaml` divergences to keep when rebasing** (that file is upstream's, so a rebase replays their version):
  - the `upload` job is disabled with `if: false`. Upstream's job announces to their `@FlClash` Telegram channel through a local bot API server on `localhost:8081` that only exists on their runners, and then deletes and republishes the tag's release with their multi-platform artifacts. `release-android-arm64.yml` is the only publisher here.
  - `Setup Android Signing` writes `google-services.json` and `keystore.jks` only when the matching secret is present. Without that guard an absent `SERVICE_JSON` decoded an empty string over the checked-in stub and gradle failed the release build with `Malformed root json` in `processReleaseGoogleServices`, which broke every tag build while branch builds passed.
  - `tool/check_dart.sh` runs the whole dart job, and `tool/check_submodules.sh` fetches every submodule pointer so a bump cannot be pushed before the submodule commit is (CI checkout dies with `did not contain <sha>` otherwise). It also formats only `lib test tool setup.dart`, never the vendored `plugins/` submodules.
- After rebasing: `go mod tidy` in BOTH `core/Clash.Meta/` and `core/`, then fold the new submodule pointer plus `core/go.mod|go.sum` into the `feat: Smart Core integration` commit with `--fixup` + `--autosquash`.
- Verify with `go build ./...` in both Go modules, `go test ./dns/`, and an arm64 APK build (`flutter build apk --debug --target-platform android-arm64`, Flutter pinned by CI, plus the `~/.local/rustshim/rustc` shim — see `REBASE_UPSTREAM.md`).
