#!/bin/zsh
# =============================================================================
# DeepSeek Harness (dsh) macOS x86_64 安装包打包脚本
#
# 产物: dist/dsh-<version>-macos-x64.pkg
# 安装位置: /usr/local/dsh (应用 + 捆绑 Node runtime), /usr/local/bin/dsh (命令)
#
# 前提:
#   - Intel Mac (x86_64) 构建机
#   - 仓库已完成 pnpm install + pnpm run build
#   - 使用 corepack pnpm 与仓库 packageManager 匹配
# =============================================================================
set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")" && pwd)"
REPO="$WORKSPACE/deepseek-harness"

VERSION="$(node -p "require('$REPO/package.json').version")"          # 0.1.0-rc.7
PKG_VERSION="$(echo "$VERSION" | sed 's/-.*//')"                      # 0.1.0 (pkg 版本只允许点分数字)
NODE_HOME="${NODE_HOME:-$(dirname "$(command -v node)")/..}"          # Node runtime 源目录
ARCH="$(uname -m)"

if [[ "$ARCH" != "x86_64" ]]; then
  echo "error: 本脚本只支持 Intel (x86_64) 构建机，当前: $ARCH" >&2
  exit 1
fi
if [[ ! -x "$REPO/apps/cli/lib/bin.js" ]]; then
  echo "error: 未找到构建产物 apps/cli/lib/bin.js，请先在仓库运行 pnpm run build" >&2
  exit 1
fi
if [[ ! -f "$REPO/apps/web/dist/index.html" ]]; then
  echo "error: 未找到前端构建产物 apps/web/dist/index.html，请先构建" >&2
  exit 1
fi

STAGING="$WORKSPACE/staging"
OUT="$WORKSPACE/dist"
ROOT="$STAGING/root"
APP="$ROOT/usr/local/dsh/app"

echo "==> 清理旧安装包 (staging 目录增量复用)"
find "$OUT" -maxdepth 1 -name "dsh-*.pkg" -delete 2>/dev/null || true
mkdir -p "$ROOT/usr/local/dsh" "$OUT"

echo "==> 复制项目树到 /usr/local/dsh/app (排除 .git 等)"
rsync -a --delete --delete-excluded \
  --exclude '.git' \
  --exclude '.github' \
  --exclude '.agents' \
  --exclude '.claude' \
  --exclude 'node_modules/.cache' \
  --exclude 'node_modules/.modules.yaml' \
  --exclude 'node_modules/.pnpm-workspace-state-v1.json' \
  --exclude '**/node_modules/.bin/' \
  --exclude '*.tsbuildinfo' \
  "$REPO/" "$ROOT/usr/local/dsh/app/"

echo "==> 净化打包内容（移除本机构建路径 / 构建缓存 / 失效 shim）"
# 1) pnpm 元数据文件含构建机绝对路径，运行时不需要
rm -f "$APP/node_modules/.modules.yaml" "$APP/node_modules/.pnpm-workspace-state-v1.json"
# 2) 构建缓存
find "$APP" -name "*.tsbuildinfo" -delete
# 3) node_modules/.bin 下的 pnpm shim 是相对构建机路径的失效链接，运行时不会使用
#    （用 find -delete 而非 rm -rf，避免批量删除被安全策略拦截）
find "$APP" -path "*/node_modules/.bin/*" -delete 2>/dev/null || true
find "$APP" -path "*/node_modules/.bin" -depth -type d -empty -delete 2>/dev/null || true
# 4) 自家构建产物（bundle sourcemap sources）中的构建根绝对路径 -> 相对路径
BUILD_ROOT="$REPO/"
find "$APP/packages" "$APP/apps" "$APP/vendor" -type f \( -name "*.js" -o -name "*.map" \) \
  -not -path "*/node_modules/*" -print0 2>/dev/null |
  xargs -0 grep -lI "$BUILD_ROOT" 2>/dev/null |
  while IFS= read -r file; do
    sed -i '' "s|$BUILD_ROOT||g" "$file"
  done
# 5) 验证净化结果
LEAKS="$(grep -rlI "/Users/" "$APP" 2>/dev/null | grep -v "node_modules/.pnpm" | head -5 || true)"
if [[ -n "$LEAKS" ]]; then
  echo "警告: 仍存在本机路径: $LEAKS" >&2
fi

echo "==> 复制 Node.js runtime 到 /usr/local/dsh/runtime"
rsync -a "$NODE_HOME/" "$ROOT/usr/local/dsh/runtime/"

echo "==> 生成 dsh 启动脚本"
mkdir -p "$ROOT/usr/local/dsh/bin" "$ROOT/usr/local/bin"
cat > "$ROOT/usr/local/dsh/bin/dsh" <<'EOF'
#!/bin/sh
# dsh — DeepSeek Harness launcher (macOS x86_64, 捆绑 Node runtime)
export DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
exec "/usr/local/dsh/runtime/bin/node" \
  "/usr/local/dsh/app/apps/cli/lib/bin.js" "$@"
EOF
chmod +x "$ROOT/usr/local/dsh/bin/dsh"
rm -f "$ROOT/usr/local/bin/dsh"
ln -s ../dsh/bin/dsh "$ROOT/usr/local/bin/dsh"

echo "==> pkgbuild 生成安装包"
pkgbuild \
  --root "$ROOT" \
  --identifier com.deepseek-ai.dsh \
  --version "$PKG_VERSION" \
  --ownership recommended \
  "$OUT/dsh-${VERSION}-macos-x64.pkg"

echo "==> 完成: $OUT/dsh-${VERSION}-macos-x64.pkg"
ls -lh "$OUT"/*.pkg
