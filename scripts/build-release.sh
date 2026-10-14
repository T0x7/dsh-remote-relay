#!/usr/bin/env bash
# D-114：出正式 release 包并发布到 GitHub Releases。
#
# 用法：scripts/build-release.sh [版本号]
#   版本号可省，默认取 app/pubspec.yaml 的 version: 字段（唯一权威源）。
#
# 为什么单独一个脚本：
# 1. **签名密钥必须在仓库外**。密钥路径与口令只从环境变量进来，脚本负责在
#    缺失时**明确失败**，而不是让 build.gradle 悄悄退回 debug 签名——那样你会
#    拿到一个没有稳定签名身份的"正式包"。
# 2. `--split-per-abi`：debug 包 213MB，release + 分架构能压到 40–60MB。
#    用户从更新提示里点下载时，体积就是体验。
# 3. **更新检查读的是 GitHub Releases**，所以"打 tag → 建 release → 上传 apk"
#    必须是同一个动作，否则会出现「提示有新版但点开 404」。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/app"
KS_DIR="${DSH_SIGNING_DIR:-$HOME/.config/dsh-remote/signing}"
KEYSTORE="${DSH_RELEASE_KEYSTORE:-$KS_DIR/dsh-remote-release.jks}"
REPO_SLUG="${DSH_RELEASE_REPO:-T0x7/dsh-remote-relay}"
OUT_DIR="$ROOT/dist/release"

say() { printf '\033[36m[release]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[release] %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 1. 版本：pubspec 是唯一权威 --------------------------------------------
VERSION="${1:-$(sed -n 's/^version:[[:space:]]*\([0-9][^ ]*\).*/\1/p' "$APP/pubspec.yaml" | head -1)}"
[ -n "$VERSION" ] || die "读不到版本号（app/pubspec.yaml 的 version:）"
SEMVER="${VERSION%%+*}"
say "版本：$VERSION（pubspec.yaml）"

# ---- 2. 三处版本必须一致，否则更新检查会指向一个不存在的版本 ---------------
grep -q "^## \[$SEMVER\]" "$APP/CHANGELOG.md" \
  || die "CHANGELOG.md 缺 ## [$SEMVER] 段 —— 先写变更说明再发版"
grep -q "kAppVersion = '$SEMVER'" "$APP/lib/settings/about_info.dart" \
  || die "about_info.dart 的 kAppVersion 与 pubspec 不一致（它决定「关于」页显示的版本）"

# ---- 3. 签名密钥必须在仓库外 ----------------------------------------------
case "$KEYSTORE" in
  "$ROOT"/*) die "密钥不能放在仓库里：$KEYSTORE" ;;
esac
[ -f "$KEYSTORE" ] || die "找不到密钥：$KEYSTORE
  生成一把并放到仓库外（口令不要进仓库）：
    mkdir -p '$KS_DIR' && chmod 700 '$KS_DIR'
    keytool -genkeypair -v -keystore '$KS_DIR/dsh-remote-release.jks' \\
      -storetype JKS -keyalg RSA -keysize 4096 -validity 10000 -alias dsh-remote
  之后每次构建前导出：
    DSH_RELEASE_KEYSTORE='$KEYSTORE'
    DSH_RELEASE_STORE_PASSWORD=… DSH_RELEASE_KEY_PASSWORD=… DSH_RELEASE_KEY_ALIAS=dsh-remote"
[ -n "${DSH_RELEASE_STORE_PASSWORD:-}" ] || die "DSH_RELEASE_STORE_PASSWORD 未设置"
[ -n "${DSH_RELEASE_KEY_PASSWORD:-}" ]   || die "DSH_RELEASE_KEY_PASSWORD 未设置"

# ---- 4. 构建 -------------------------------------------------------------
mkdir -p "$OUT_DIR"
# flutter build 没有 --output，产物固定落在 build/app/outputs/…，构建完再收集。
APK_SRC="$APP/build/app/outputs/flutter-apk"
AAB_SRC="$APP/build/app/outputs/bundle/release"
say "构建 release（分架构）…"
( cd "$APP" && DSH_RELEASE_KEYSTORE="$KEYSTORE" \
  flutter build apk --release --split-per-abi )
( cd "$APP" && DSH_RELEASE_KEYSTORE="$KEYSTORE" \
  flutter build appbundle --release )

rm -f "$OUT_DIR"/*.apk "$OUT_DIR"/*.aab
# **只收 release**：`$APK_SRC` 里长期躺着早先 debug 构建的 app-debug.apk，
# 一次 `cp *.apk` 会把 242MB 的调试包一起捞进发布产物——那正是「检查更新」点下去
# 会下载到的东西。
shopt -s nullglob
found=0
for f in "$APK_SRC"/*-release.apk; do cp "$f" "$OUT_DIR"/; found=1; done
[ "$found" = 1 ] || die "没产出 release apk，看 $APK_SRC"
cp "$AAB_SRC"/app-release.aab "$OUT_DIR"/ 2>/dev/null || die "没产出 aab，看 $AAB_SRC"
cp "$AAB_SRC"/app-release.aab "$OUT_DIR"/ 2>/dev/null || die "没产出 aab，看 $AAB_SRC"

APKS=("$OUT_DIR"/*.apk)
AAB="$OUT_DIR/app-release.aab"
[ -f "$AAB" ] || die "没产出 aab：$AAB"
printf '\n'
ls -lh "${APKS[@]}" "$AAB" | awk '{printf "  %-52s %s\n", $9, $5}'
printf '  %-52s %s\n' "$AAB" "$(du -h "$AAB" | cut -f1)"

# ---- 5. 发布（显式确认，不自动推） ----------------------------------------
say "产物就绪：$OUT_DIR"
if [ "${DSH_RELEASE_PUBLISH:-}" != "1" ]; then
  say "未发布（DSH_RELEASE_PUBLISH=1 才继续）"
  say "发布步骤："
  say "  1) git tag -a v$SEMVER -m 'v$SEMVER' && git push origin v$SEMVER"
  say "  2) gh release create v$SEMVER ${APKS[*]} $AAB --repo $REPO_SLUG \\"
  say "       --title 'v$SEMVER' --notes-file <(git log v$SEMVER -1 --pretty=%B)"
  exit 0
fi

command -v gh >/dev/null || die "需要 gh CLI（brew install gh）"
( cd "$ROOT" && git tag -a "v$SEMVER" -m "v$SEMVER" && git push origin "v$SEMVER" )
gh release create "v$SEMVER" "${APKS[@]}" "$AAB" --repo "$REPO_SLUG" \
  --title "v$SEMVER" --generate-notes
say "已发布 v$SEMVER —— App 的「检查更新」下一次就能看到它"