#!/bin/zsh
# =============================================================================
# DeepSeek Harness (dsh) — Tauri 2 macOS x86_64 桌面外壳打包脚本
#
# 产出:
#   - src-tauri/resources/{app.tar.gz,runtime}  (归档运行时切片 + 捆绑 Node)
#   - 经由 `tauri build` 生成
#       target/release/bundle/macos/DeepSeek Harness.app
#       target/release/bundle/dmg/DeepSeek Harness-x.y.z-x64.dmg
#
# 设计要点 (不改动核心 Harness 架构):
#   - 仅把"已构建"的 deepseek-harness 仓库 (apps/cli/lib + apps/web/dist + node_modules)
#     作为资源打进 .app，Rust 端在启动时拉起 `node apps/cli/lib/bin.js web`，
#     Tauri WebView 加载 http://127.0.0.1:<port>。
#   - 依赖裁剪 (pnpm deploy) 与 bundle size / 启动优化见下方 --trim / --optimize 开关。
#
# 前提:
#   - x86_64 macOS 构建机 (本机已是)
#   - Rust 工具链 + @tauri-apps/cli (见仓库 README / 安装说明)
#   - 核心仓库已完成 pnpm install + pnpm run build (默认复用已有构建产物)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_REPO="${CORE_REPO:-/Users/suxin/Suxin/code/DSH/deepseek-harness}"
STAGING="$ROOT/staging"
RESOURCES="$ROOT/src-tauri/resources"
RUNTIME_DIR="$RESOURCES/runtime"
APP_DIR="$RESOURCES/app"
NODE_STAGING="$STAGING/node"
TAURI_BIN="$ROOT/node_modules/.bin/tauri"

# 默认行为: 复用已有构建产物 (不重建)；--rebuild 才跑 pnpm install + build
REBUILD=0
TRIM=0          # --trim: 用 pnpm deploy 生成仅 web 闭包的可移植 node_modules
DEBUG=0
NODE_VERSION="" # 留空=抓取最新 v22

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD=1 ;;
    --trim)    TRIM=1 ;;
    --debug)   DEBUG=1 ;;
    --core)    CORE_REPO="$2"; shift ;;
    --node-version) NODE_VERSION="$2"; shift ;;
    -h|--help)
      echo "用法: $0 [--rebuild] [--trim] [--debug] [--core <path>] [--node-version <v22.x.x>]"
      exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
  shift
done

if [[ ! -d "$CORE_REPO" ]]; then
  echo "error: 核心仓库不存在: $CORE_REPO" >&2
  exit 1
fi

echo "==> 工作目录: $ROOT"
echo "==> 核心仓库: $CORE_REPO"

# ---------------------------------------------------------------------------
# 1) 准备可移植 Node runtime (官方 macOS x64 构建，可再分发)
# ---------------------------------------------------------------------------
ensure_node() {
  if [[ -x "$NODE_STAGING/bin/node" ]]; then
    local have
    have="$($NODE_STAGING/bin/node -p 'process.arch + "-" + process.platform')"
    if [[ "$have" == "x64-darwin" ]]; then
      echo "==> 复用已缓存的 Node runtime: $NODE_STAGING"
      return 0
    fi
    echo "==> 已有 Node 架构不符 ($have)，重新下载 x64"
  fi

  mkdir -p "$NODE_STAGING"
  if [[ -z "$NODE_VERSION" ]]; then
    echo "==> 查询最新 Node v22 ..."
    NODE_VERSION="$(curl -s https://nodejs.org/dist/index.json \
      | python3 -c 'import sys,json; print([x["version"] for x in json.load(sys.stdin) if x["version"].startswith("v22")][0])')"
  fi
  local tarball="node-$NODE_VERSION-darwin-x64.tar.gz"
  local url="https://nodejs.org/dist/$NODE_VERSION/$tarball"
  echo "==> 下载 $url"
  curl -fL --retry 3 -o "$STAGING/$tarball" "$url"
  tar -xzf "$STAGING/$tarball" -C "$STAGING"
  rm -rf "$NODE_STAGING"
  mv "$STAGING/node-$NODE_VERSION-darwin-x64" "$NODE_STAGING"
  rm -f "$STAGING/$tarball"
  echo "==> Node $NODE_VERSION 就绪: $($NODE_STAGING/bin/node -v)"
}

# ---------------------------------------------------------------------------
# 2) 准备 app 运行时切片
# ---------------------------------------------------------------------------
prepare_app() {
  echo "==> 清理旧 resources"
  rm -rf "$RESOURCES"
  mkdir -p "$APP_DIR" "$RUNTIME_DIR/bin"

  if [[ "$REBUILD" -eq 1 ]]; then
    echo "==> 重建核心仓库 (pnpm install + build)"
    ( cd "$CORE_REPO" && pnpm install --frozen-lockfile && pnpm run build )
  fi

  # 当前 workspace 的 peer/override 依赖不能由 pnpm deploy 完整推导。
  # --trim 仍走可重定位的 workspace 复制路径，但额外删除已确认非运行期内容；
  # 不产出未经 headless 启动验证的“伪裁剪”树。
  prepare_app_full
  if [[ "$TRIM" -eq 1 ]]; then
    prune_workspace_runtime
  fi

  # 净化: 移除本机构建绝对路径 / 缓存 / 失效 shim
  sanitize_app

  echo "==> 封装 app.tar.gz（避免 Tauri 递归扫描 pnpm 符号链接）"
  rm -f "$RESOURCES/app.tar.gz"
  ( cd "$RESOURCES" && tar -czf app.tar.gz app )
  rm -rf "$APP_DIR"
  echo "==> app.tar.gz 大小: $(du -sh "$RESOURCES/app.tar.gz" | awk '{print $1}')"
}

# 完整拷贝 (与现有 .pkg 脚本同路，已验证可运行；体积大，后续优化)
# 说明: pnpm 的 workspace 链接均为相对路径，整树拷贝即保持可重定位；
#       node_modules 内文件是 store 的硬链接，rsync 不带 -H 拷贝为真实文件。
prepare_app_full() {
  echo "==> 拷贝核心仓库到 resources/app (含 node_modules; 排除非运行期目录)"
  rsync -a --delete \
    --exclude '.git' \
    --exclude '.github' \
    --exclude '.agents' \
    --exclude '.claude' \
    --exclude 'dist-exe' \
    --exclude 'node_modules/.cache' \
    --exclude 'node_modules/.modules.yaml' \
    --exclude 'node_modules/.pnpm-workspace-state-v1.json' \
    --exclude '*.tsbuildinfo' \
    --exclude 'python' \
    --exclude 'docs' \
    --exclude 'website' \
    --exclude 'examples' \
    --exclude '/assets' \
    "$CORE_REPO/" "$APP_DIR/"
  # native/landlock-run 是 web profile 初始化时需要的运行时依赖，保留其布局。
}

# 保守裁剪: 维持 pnpm workspace 相对链接，只删除已确认非运行期目录。
# 这是当前版本的安全裁剪模式；真正的包级闭包需要核心仓库显式声明 runtime peers。
prune_workspace_runtime() {
  echo "==> 保守裁剪 workspace 运行时（保留相对链接与 native landlock）"
  rm -rf "$APP_DIR/python" "$APP_DIR/docs" "$APP_DIR/website" \
         "$APP_DIR/examples" "$APP_DIR/dist-exe" \
         "$APP_DIR/.git" "$APP_DIR/.github" \
         "$APP_DIR/.agents" "$APP_DIR/.claude"
  find "$APP_DIR" -name '*.tsbuildinfo' -delete 2>/dev/null || true
  find "$APP_DIR" -type d \( -name '.cache' -o -name '.vite' \) -prune -exec rm -rf {} + 2>/dev/null || true
  rm -rf "$APP_DIR/native/landlock-run/docs" \
         "$APP_DIR/native/landlock-run/node_modules" \
         "$APP_DIR/native/landlock-run/.git" \
         "$APP_DIR/native/landlock-run/test" 2>/dev/null || true
}

sanitize_app() {
  echo "==> 净化本机绝对路径 (构建根 -> 相对)"
  local build_root="$CORE_REPO/"
  find "$APP_DIR/apps" "$APP_DIR/packages" "$APP_DIR/vendor" -type f \
    \( -name '*.js' -o -name '*.map' \) -not -path '*/node_modules/*' -print0 2>/dev/null \
    | xargs -0 grep -lI "$build_root" 2>/dev/null \
    | while IFS= read -r f; do sed -i '' "s|$build_root||g" "$f"; done || true
  # 移除 pnpm 失效 bin (运行期用 node 直接拉起，不依赖 pnpm shim)
  find "$APP_DIR" -path '*/node_modules/.bin/*' -delete 2>/dev/null || true
  find "$APP_DIR" -path '*/node_modules/.bin' -depth -type d -empty -delete 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 3) 拷贝并精简 Node runtime
# ---------------------------------------------------------------------------
bundle_node() {
  echo "==> 拷贝 Node runtime -> resources/runtime"
  cp -a "$NODE_STAGING/." "$RUNTIME_DIR/" 2>/dev/null || cp -a "$NODE_STAGING"/. "$RUNTIME_DIR/"
  chmod +x "$RUNTIME_DIR/bin/node"
  # 精简: 删除 npm/npx 与头文件/文档，仅保留 node 二进制 + 运行所需 lib
  rm -rf "$RUNTIME_DIR/lib/node_modules/npm" \
         "$RUNTIME_DIR/lib/node_modules/npx" \
         "$RUNTIME_DIR/bin/npm" \
         "$RUNTIME_DIR/bin/npx" \
         "$RUNTIME_DIR/include" \
         "$RUNTIME_DIR/share" 2>/dev/null || true
  echo "==> Node runtime 大小: $(du -sh "$RUNTIME_DIR" | awk '{print $1}')"
}

# ---------------------------------------------------------------------------
# 4) tauri build
# ---------------------------------------------------------------------------
run_build() {
  if [[ ! -x "$TAURI_BIN" ]]; then
    echo "error: 未找到 @tauri-apps/cli ($TAURI_BIN)。请先 `npm install`。" >&2
    exit 1
  fi
  echo "==> tauri build (target x86_64-apple-darwin)"
  local out
  if [[ "$DEBUG" -eq 1 ]]; then
    "$TAURI_BIN" build --debug --target x86_64-apple-darwin
  else
    "$TAURI_BIN" build --target x86_64-apple-darwin
  fi
  echo "==> 构建产物:"
  find "$ROOT/src-tauri/target/release/bundle" -maxdepth 2 \( -name '*.app' -o -name '*.dmg' \) -exec du -sh {} \; 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
ensure_node
prepare_app
bundle_node
run_build
echo "==> 完成。"
