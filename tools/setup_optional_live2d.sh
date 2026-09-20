#!/usr/bin/env bash
#
# DeskPet 可选 Live2D 资源安装工具（离线）
#
# 公开仓库不随源码分发 Bongo Live2D 资源（Live2D Cubism Core 受专有许可约束，
# 模型/纹理/键帽素材的授权也不允许以 GPL 兼容方式随仓库再分发，详见
# docs/OPTIONAL_LIVE2D_SETUP.md）。本脚本把你已经从官方渠道取得、并自行确认
# 授权的资源目录，复制或软链接到仓库内被 .gitignore 忽略的
# deskpet/BongoResources/ 目录。
#
# 用法：
#   tools/setup_optional_live2d.sh --copy <资源目录> [--project-root <仓库根目录>]
#   tools/setup_optional_live2d.sh --link <资源目录> [--project-root <仓库根目录>]
#
# 行为约束：
#   - 完全离线：不联网、不下载任何文件
#   - 不代你接受任何许可条款；资源的取得渠道与授权合规由你自行负责
#   - 先完整校验，全部通过才安装；校验失败不落盘、列出缺失清单并以非零码退出
#   - 目标已存在时拒绝执行（避免覆盖），请先按提示自行移除
#
# 退出码：0 成功；1 校验/安装失败；2 参数错误

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
  cat <<'EOF'
用法：
  tools/setup_optional_live2d.sh --copy <资源目录> [--project-root <仓库根目录>]
  tools/setup_optional_live2d.sh --link <资源目录> [--project-root <仓库根目录>]

参数：
  --copy                将资源目录内容复制为 deskpet/BongoResources/（独立副本）
  --link                创建符号链接 deskpet/BongoResources -> <资源目录>（不占额外空间）
  <资源目录>            你已取得并确认授权的 Bongo 资源目录（含 index.html 等）
  --project-root <path> 仓库根目录；缺省按脚本位置自动推断（脚本位于 <根>/tools/）

示例：
  tools/setup_optional_live2d.sh --link ~/Downloads/BongoResources
  tools/setup_optional_live2d.sh --copy /Volumes/Res/BongoResources --project-root ~/src/DeskPet
EOF
}

die() {
  echo "$SCRIPT_NAME: 错误：$1" >&2
  exit "${2:-1}"
}

MODE=""
SRC=""
ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --copy|--link)
      [ -z "$MODE" ] || die "只能指定一次 --copy/--link" 2
      MODE="${1#--}"; shift ;;
    --project-root)
      [ $# -ge 2 ] || die "--project-root 需要一个路径参数" 2
      ROOT="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --*)
      die "未知参数：$1（用 -h 查看用法）" 2 ;;
    *)
      [ -z "$SRC" ] || die "多余的位置参数：$1（用 -h 查看用法）" 2
      SRC="$1"; shift ;;
  esac
done

[ -n "$MODE" ] || { usage >&2; die "必须指定 --copy 或 --link" 2; }
[ -n "$SRC" ] || { usage >&2; die "必须提供 <资源目录>" 2; }

# 仓库根目录：显式参数优先，否则按脚本位置推断（脚本位于 <根>/tools/）
if [ -z "$ROOT" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ROOT="$(dirname "$SCRIPT_DIR")"
fi
if [ ! -d "$ROOT/deskpet" ] || [ ! -f "$ROOT/deskpet.xcodeproj/project.pbxproj" ]; then
  die "未在 $ROOT 找到 DeskPet 仓库结构（deskpet/ 与 deskpet.xcodeproj）；请用 --project-root 指定仓库根目录" 2
fi

SRC="$(cd "$SRC" 2>/dev/null && pwd)" || die "资源目录不存在或不可读：$1" 2
DEST="$ROOT/deskpet/BongoResources"

# ---- 必需文件清单（与 index.html、cat.model3.json 的实际引用保持一致）----
REQUIRED_FILES=(
  "index.html"
  "bongo-companion.js"
  "easy-live2d.bundle.js"
  "keyboard-overlay.js"
  "live2dcubismcore.min.js"
  "pixi-v8.js"
  "model/cat.model3.json"
  "model/demomodel.moc3"
  "model/demomodel.1024/texture_00.png"
  "model/demomodel.1024/texture_01.png"
  "model/demomodel.1024/texture_02.png"
  "keyboard/background.png"
  "keyboard/cover.png"
  "LICENSE-BongoCat-MIT.txt"
  "THIRD_PARTY_NOTICES.md"
)
LEFT_KEYS=(Alt AltGr BackQuote Backspace CapsLock Control ControlLeft ControlRight
           Delete Escape Fn Meta Return Shift ShiftLeft ShiftRight Slash Space Tab)
for c in {A..Z}; do LEFT_KEYS+=("Key$c"); done
for n in {0..9}; do LEFT_KEYS+=("Num$n"); done

# validate <目录>：缺失项逐行打印到 stdout，全部存在返回 0
validate() {
  local dir="$1" missing=0 f k
  for f in "${REQUIRED_FILES[@]}"; do
    [ -f "$dir/$f" ] || { echo "  缺失：$f"; missing=1; }
  done
  for k in "${LEFT_KEYS[@]}"; do
    [ -f "$dir/keyboard/left-keys/$k.png" ] || { echo "  缺失：keyboard/left-keys/$k.png"; missing=1; }
  done
  return "$missing"
}

echo "== 校验资源目录：$SRC"
if validate "$SRC"; then
  echo "   必需文件全部存在（${#REQUIRED_FILES[@]} 个核心文件 + ${#LEFT_KEYS[@]} 个键帽图）"
else
  echo "$SCRIPT_NAME: 校验失败，未安装任何文件。请从完整的官方发布包取得资源后重试。" >&2
  exit 1
fi

if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  echo "$SCRIPT_NAME: 目标已存在：$DEST" >&2
  echo "  copy 模式请先移除：rm -rf \"$DEST\"" >&2
  echo "  link 模式请先移除：unlink \"$DEST\"（只删链接，不动源目录）" >&2
  exit 1
fi

echo "== 安装（模式：${MODE}）"
case "$MODE" in
  copy)
    mkdir -p "$DEST"
    cp -R "$SRC/." "$DEST/"
    ;;
  link)
    ln -s "$SRC" "$DEST"
    ;;
esac

echo "== 安装后复检：$DEST"
if ! validate "$DEST"; then
  echo "$SCRIPT_NAME: 安装后复检失败（源目录校验曾通过，请把以上缺失清单反馈给项目）。" >&2
  exit 1
fi

COUNT="$(find -H "$DEST" -type f | wc -l | tr -d ' ')"
cat <<EOF

== 完成（模式：${MODE}）
   安装位置：$DEST
   文件总数：${COUNT}（该目录已被 .gitignore 忽略，不会进入版本库）

下一步：
  1) Xcode 调试运行：Product > Scheme > Edit Scheme… > Run > Arguments，
     添加环境变量  BONGO_RESOURCES_DIR = $DEST
  2) 运行 Release 构建产物：
       BONGO_RESOURCES_DIR="$DEST" ./deskpet.app/Contents/MacOS/deskpet
  3) 在 DeskPet 设置中开启 Bongo。

移除：
  copy 模式：rm -rf "$DEST"
  link 模式：unlink "$DEST"（只删链接，不动你的源目录）

提醒：本脚本不联网、不代你接受任何许可条款；资源的取得与授权合规由你自行
负责，详见 docs/OPTIONAL_LIVE2D_SETUP.md。
EOF
