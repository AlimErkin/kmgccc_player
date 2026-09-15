#!/usr/bin/env bash
set -euo pipefail

# 本机装这个 fork:出 Release 包 → 用你自己的证书重签 → 备份旧的 → 装进 /Applications
#
# 为什么不直接 xcodebuild 带签名参数:工程里的 DEVELOPMENT_TEAM 是上游作者的
# (TYU73KR9WW),本机没有那个证书,一开签名就报「No signing certificate」。
# 所以照 build_app.sh 原样出**无签名**包(它会跑 bundle 完整性检查),再自己重签。
#
# 用法:
#   ./scripts/install-local.sh                      # 自动挑第一个 Apple Development 证书
#   ./scripts/install-local.sh "Apple Development: 你 (XXXX)"
#   SKIP_INSTALL=1 ./scripts/install-local.sh       # 只出包和 dmg,不动 /Applications

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="kmgccc_player"
OUT_DIR="${OUT_DIR:-$HOME/Desktop/kmgccc_player-在线版}"
STAGE="$OUT_DIR/$APP_NAME.app"
ENTS="$REPO_ROOT/$APP_NAME/$APP_NAME.release.entitlements"

# bootstrap 认死 Node 22(本机默认可能是 23),keg-only 的那份补进 PATH
if [[ -d /opt/homebrew/opt/node@22/bin ]]; then
  export PATH="/opt/homebrew/opt/node@22/bin:$PATH"
fi

IDENT="${1:-}"
if [[ -z "$IDENT" ]]; then
  IDENT="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)".*/\1/')"
fi
[[ -n "$IDENT" ]] || { echo "error: 找不到可用的签名证书,把证书名当参数传进来" >&2; exit 1; }
if [[ -z "${1:-}" ]]; then
  # 自动挑的是**列表里第一个**,机器上有多个开发者证书时未必是你想要的那个。
  # 把候选都打出来,挑错了一眼能看见。
  echo "==> 自动挑了第一个证书。机器上的候选:"
  security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | sed 's/^/    /'
fi
echo "==> 签名身份:$IDENT"

echo "==> 出 Release 包(无签名)"
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
SYM_DIR="$(mktemp -d)"
CRASH_SYMBOL_ARCHIVE_DIR="$SYM_DIR/archive" \
CRASH_SYMBOL_BACKUP_DIR="$SYM_DIR/backup" \
OUTPUT_DIR="$OUT_DIR" \
  "$SCRIPT_DIR/build_app.sh" Release
[[ -d "$STAGE" ]] || { echo "error: 没出包:$STAGE" >&2; exit 1; }

echo "==> 重签(由内到外)"
# --deep 官方不推荐:嵌套项的 entitlements 会被吞掉。自己走一遍,主程序最后签。
find "$STAGE/Contents" \( -name '*.framework' -o -name '*.bundle' -o -name '*.xpc' -o -name '*.app' \) -depth 2>/dev/null \
| while read -r item; do
  codesign --force --timestamp=none --options runtime --sign "$IDENT" "$item" 2>/dev/null \
    || codesign --force --timestamp=none --sign "$IDENT" "$item"
done
find "$STAGE/Contents" -type f -perm +111 2>/dev/null | while read -r f; do
  case "$f" in *.framework/*|*.bundle/*|*.xpc/*|*.app/*) continue;; esac
  [[ "$f" == "$STAGE/Contents/MacOS/$APP_NAME" ]] && continue
  file -b "$f" | grep -q "Mach-O" || continue
  codesign --force --timestamp=none --options runtime --sign "$IDENT" "$f" 2>/dev/null \
    || codesign --force --timestamp=none --sign "$IDENT" "$f"
done
codesign --force --timestamp=none --options runtime --entitlements "$ENTS" --sign "$IDENT" "$STAGE"
codesign --verify --strict --verbose=2 "$STAGE"

VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$STAGE/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$STAGE/Contents/Info.plist")"
echo "==> 版本 $VER ($BUILD)"

echo "==> 打 dmg"
DMG="$OUT_DIR/$APP_NAME-$VER-$BUILD.dmg"
DMG_STAGE="$(mktemp -d)"
COPYFILE_DISABLE=1 /usr/bin/ditto "$STAGE" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "$APP_NAME $VER" -srcfolder "$DMG_STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$DMG_STAGE" "$SYM_DIR"
echo "    $DMG"

if [[ "${SKIP_INSTALL:-0}" == "1" ]]; then
  echo "==> SKIP_INSTALL=1,不动 /Applications"
  exit 0
fi

TARGET="/Applications/$APP_NAME.app"
if [[ -e "$TARGET" ]]; then
  # 覆盖前必须留一份 —— 装在 /Applications 里那个可能是官网下的正式版。
  #
  # ⚠️ 这一段 2026-09-15 真出过事:备份失败了,但脚本照样往下走把旧的删了。
  #    两个原因,都修在这儿:
  #    ① PlistBuddy 的「File Doesn't Exist」是打到 **stdout** 的,2>/dev/null
  #       挡不住,于是错误文本被 $(...) 抓进了变量,文件名里带换行;
  #    ② 备份和读版本都写成了 `cmd || fallback` / 放在 `[[ ]] ||` 后面,
  #       set -e 对这种形式不生效 —— 失败了也不会停。
  #    现在:备份自己判断成败,没成功就**直接退出**,绝不往下删。
  OLD_PLIST="$TARGET/Contents/Info.plist"
  if [[ -f "$OLD_PLIST" ]]; then
    OLD_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$OLD_PLIST" 2>/dev/null | tr -d '\n' || true)"
  else
    OLD_BUILD=""
  fi
  [[ -n "$OLD_BUILD" ]] || OLD_BUILD="unknown"

  BACKUP="$HOME/Desktop/$APP_NAME-备份-build$OLD_BUILD.app"
  if [[ ! -d "$BACKUP" ]]; then
    echo "==> 备份原来那个(build $OLD_BUILD)→ $BACKUP"
    if ! COPYFILE_DISABLE=1 /usr/bin/ditto "$TARGET" "$BACKUP"; then
      echo "error: 备份失败,已停下 —— 不会删 $TARGET。" >&2
      echo "       先弄清楚它是什么状态,或者 SKIP_INSTALL=1 只出包。" >&2
      exit 1
    fi
    [[ -f "$BACKUP/Contents/Info.plist" ]] || {
      echo "error: 备份出来是空壳(没有 Info.plist),已停下,不会删 $TARGET。" >&2
      exit 1
    }
  else
    echo "==> 已有备份,跳过:$BACKUP"
  fi

  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1
  rm -rf "$TARGET"
fi

echo "==> 装进 /Applications"
COPYFILE_DISABLE=1 /usr/bin/ditto "$STAGE" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
echo "装好了:$TARGET  ($VER build $BUILD)"
