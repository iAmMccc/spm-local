#!/bin/bash
# SPM 本地依赖下载脚本
# 读取 packages.json，将三方库 clone 到 Packages/Caches/
# 用法:
#   ./Packages/scripts/fetch-packages.sh
#   ./Packages/scripts/fetch-packages.sh update all
#   ./Packages/scripts/fetch-packages.sh update <库名>
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGES_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$PACKAGES_ROOT/Caches"
JSON_FILE="$PACKAGES_ROOT/packages.json"

MODE="sync"
TARGET_NAME=""

usage() {
  echo "用法:"
  echo "  ./Packages/scripts/fetch-packages.sh"
  echo "  ./Packages/scripts/fetch-packages.sh update all"
  echo "  ./Packages/scripts/fetch-packages.sh update <库名>"
  echo ""
  echo "说明:"
  echo "  无参数：下载缺失依赖；已写 version 的依赖会同步到指定 tag；未写 version 的已有依赖会跳过。"
  echo "  update：不修改 packages.json。已写 version 的依赖同步到指定 tag；未写 version 的依赖更新到远端默认分支最新。"
  echo "  update 会覆盖 Packages/Caches/ 下对应库的本地未提交改动。"
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    update)
      if [ "$#" -ne 2 ]; then
        usage
        exit 1
      fi
      MODE="update"
      TARGET_NAME="$2"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
fi

# 显示当前安装的 spm-local 版本，便于确认是否为最新
VERSION=$(cat "$PACKAGES_ROOT/.spm-local-version" 2>/dev/null | head -n1 | tr -d '[:space:]')
[ -n "$VERSION" ] && echo "spm-local v${VERSION}"

# 检查 packages.json
if [ ! -f "$JSON_FILE" ]; then
  echo "错误: 未找到 $JSON_FILE"
  echo "请先创建 packages.json，参考 packages.json.example"
  exit 1
fi

# 检查 python3（用于解析 JSON）
if ! command -v python3 &>/dev/null; then
  echo "错误: 需要 python3 来解析 packages.json"
  exit 1
fi

mkdir -p "$CACHE_DIR"
cd "$CACHE_DIR"

# 代理：git 通过 libcurl 自动读取环境里的 http_proxy / https_proxy / all_proxy，
# 脚本继承父 shell 的这些变量即可，无需在此额外设置。
# 如需访问 GitHub，请先在终端 export 好代理再执行本脚本。

# 解析远端实际的 tag 名（兼容 1.2.3 与 v1.2.3 两种写法）
# 成功则输出真实 tag 名并返回 0，找不到返回非 0
resolve_remote_tag() {
  local url="$1" version="$2" refs
  refs=$(git ls-remote --tags "$url" 2>/dev/null) || return 1
  if printf '%s\n' "$refs" | grep -qE "refs/tags/${version}(\^\{\})?$"; then
    printf '%s' "$version"; return 0
  fi
  if printf '%s\n' "$refs" | grep -qE "refs/tags/v${version}(\^\{\})?$"; then
    printf '%s' "v${version}"; return 0
  fi
  return 1
}

# 解析远端默认分支（通常是 main 或 master）
resolve_default_branch() {
  local url="$1" branch fallback
  branch=$(git ls-remote --symref "$url" HEAD 2>/dev/null | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }')
  if [ -n "$branch" ]; then
    printf '%s' "$branch"
    return 0
  fi

  for fallback in main master; do
    if git ls-remote --heads "$url" "$fallback" 2>/dev/null | grep -q .; then
      printf '%s' "$fallback"
      return 0
    fi
  done

  return 1
}

# 更新缓存目录时把它当作可再生成的缓存处理：不检查 dirty 状态，直接覆盖本地改动。
discard_local_changes() {
  git reset --hard -q && git clean -fd -q
}

ensure_origin_url() {
  local url="$1"
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$url"
  else
    git remote add origin "$url"
  fi
}

checkout_tag() {
  local dir="$1" url="$2" tag="$3"
  (
    cd "$dir" &&
    ensure_origin_url "$url" &&
    discard_local_changes &&
    git fetch --depth 1 --force origin "+refs/tags/${tag}:refs/tags/${tag}" &&
    git -c advice.detachedHead=false checkout -q --force "$tag" &&
    git reset --hard -q "$tag" &&
    git clean -fd -q
  )
}

checkout_branch_latest() {
  local dir="$1" url="$2" branch="$3"
  (
    cd "$dir" &&
    ensure_origin_url "$url" &&
    discard_local_changes &&
    git fetch --depth 1 --force origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" &&
    git checkout -q -B "$branch" "refs/remotes/origin/${branch}" &&
    git reset --hard -q "refs/remotes/origin/${branch}" &&
    git clean -fd -q
  )
}

# 执行 git clone，显示 git 原生实时进度（Receiving objects: NN% | KiB/s）
# -c advice.detachedHead=false 关闭切到 tag 时的 detached HEAD 提示
# 用法: clone_quiet <url> <dir> [额外 clone 参数...]
clone_quiet() {
  local url="$1" dir="$2"; shift 2
  git -c advice.detachedHead=false clone --progress "$@" "$url" "$dir"
}

# 解析 packages.json
ENTRIES=$(JSON_FILE="$JSON_FILE" python3 <<'PY'
import json
import os

with open(os.environ['JSON_FILE']) as f:
    pkgs = json.load(f)
for p in pkgs:
    url = p['url']
    version = p.get('version', '')
    # 从 URL 解析库名
    name = url.rstrip('/').split('/')[-1]
    if name.endswith('.git'):
        name = name[:-4]
    print(f'{name}\t{url}\t{version}')
PY
)

clone_count=0
skip_count=0
update_count=0
fail_count=0
matched_target=false

while IFS=$'\t' read -r name url version; do
  # 跳过空行（packages.json 为空数组时会读到空行）
  [ -z "$name" ] && [ -z "$url" ] && continue

  if [ "$MODE" = "update" ] && [ "$TARGET_NAME" != "all" ] && [ "$name" != "$TARGET_NAME" ]; then
    continue
  fi
  if [ "$MODE" = "update" ] && [ "$TARGET_NAME" != "all" ]; then
    matched_target=true
  fi

  dir="$CACHE_DIR/$name"

  # 情况 1：目录存在但为空 → 删除后重新 clone
  if [ -d "$dir" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    echo "[清理] $name"
    rm -rf "$dir"
  fi

  # 情况 2：目录存在且有内容
  if [ -d "$dir" ]; then
    if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
      echo "[失败] $name 目录已存在，但不是 git 仓库：$dir"
      fail_count=$((fail_count + 1))
      continue
    fi

    if [ -n "$version" ]; then
      # 检查当前是否已在目标版本
      # 注意：git describe 在没有匹配 tag 时返回非 0，配合 set -e 会让整个脚本静默退出
      # 用 || true 兜底，让 current_tag 为空时走下方"更新"分支自动 fetch tags
      current_tag=$(cd "$dir" && git describe --tags --exact-match 2>/dev/null || true)
      if [ "$MODE" != "update" ] && { [ "$current_tag" = "$version" ] || [ "$current_tag" = "v${version}" ]; }; then
        echo "[跳过] $name $version"
        skip_count=$((skip_count + 1))
      else
        echo "[更新] $name $version"
        tag=$(resolve_remote_tag "$url" "$version" || true)
        if [ -z "$tag" ]; then
          echo "  ⚠ 远端找不到版本 $version（已尝试 $version 与 v$version）"
          fail_count=$((fail_count + 1))
          continue
        fi
        # 只浅取目标 tag，再切过去，不拉全量历史
        # -c advice.detachedHead=false 关闭切到 tag 时的 detached HEAD 提示
        if checkout_tag "$dir" "$url" "$tag"; then
          update_count=$((update_count + 1))
        else
          echo "  ⚠ checkout $tag 失败"
          fail_count=$((fail_count + 1))
        fi
      fi
    else
      if [ "$MODE" = "update" ]; then
        branch=$(resolve_default_branch "$url" || true)
        if [ -z "$branch" ]; then
          echo "[失败] $name 无法解析远端默认分支"
          fail_count=$((fail_count + 1))
          continue
        fi

        echo "[更新] $name latest ($branch)"
        if checkout_branch_latest "$dir" "$url" "$branch"; then
          update_count=$((update_count + 1))
        else
          echo "  ⚠ 更新 $branch 失败"
          fail_count=$((fail_count + 1))
        fi
      else
        echo "[跳过] $name"
        skip_count=$((skip_count + 1))
      fi
    fi
    continue
  fi

  # 情况 3：目录不存在 → clone（单行进度，不刷屏）
  label="$version"
  [ -z "$label" ] && label="latest"
  echo "[下载] $name $label"
  if [ -n "$version" ]; then
    # 先解析远端真实 tag 名，再用浅克隆只拉该 tag，不拖全量历史
    tag=$(resolve_remote_tag "$url" "$version" || true)
    if [ -z "$tag" ]; then
      echo "  ⚠ 远端找不到版本 $version（已尝试 $version 与 v$version）"
      fail_count=$((fail_count + 1))
      continue
    fi
    if clone_quiet "$url" "$name" --depth 1 --branch "$tag"; then
      clone_count=$((clone_count + 1))
    else
      echo "  ⚠ clone 失败，请检查网络或 URL"
      fail_count=$((fail_count + 1))
    fi
  else
    if clone_quiet "$url" "$name" --depth 1; then
      clone_count=$((clone_count + 1))
    else
      echo "  ⚠ clone 失败，请检查网络或 URL"
      fail_count=$((fail_count + 1))
    fi
  fi

done <<< "$ENTRIES"

if [ "$MODE" = "update" ] && [ "$TARGET_NAME" != "all" ] && [ "$matched_target" != "true" ]; then
  echo ""
  echo "错误: packages.json 中找不到依赖 $TARGET_NAME"
  exit 1
fi

echo ""
echo "完成。下载: $clone_count / 更新: $update_count / 跳过: $skip_count / 失败: $fail_count"
echo "缓存目录: $CACHE_DIR"
