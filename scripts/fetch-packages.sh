#!/bin/bash
# SPM 本地依赖下载脚本
# 读取 packages.json，将三方库 clone 到 Packages/Caches/
# 用法: ./Packages/scripts/fetch-packages.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGES_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$PACKAGES_ROOT/Caches"
JSON_FILE="$PACKAGES_ROOT/packages.json"

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

# 解析 packages.json
ENTRIES=$(python3 -c "
import json, sys
with open('$JSON_FILE') as f:
    pkgs = json.load(f)
for p in pkgs:
    url = p['url']
    version = p.get('version', '')
    # 从 URL 解析库名
    name = url.rstrip('/').split('/')[-1].removesuffix('.git')
    print(f'{name}\t{url}\t{version}')
")

clone_count=0
skip_count=0
update_count=0
fail_count=0

while IFS=$'\t' read -r name url version; do
  dir="$CACHE_DIR/$name"

  # 情况 1：目录存在但为空 → 删除后重新 clone
  if [ -d "$dir" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    echo "[清理] $name"
    rm -rf "$dir"
  fi

  # 情况 2：目录存在且有内容
  if [ -d "$dir" ]; then
    if [ -n "$version" ]; then
      # 检查当前是否已在目标版本
      # 注意：git describe 在没有匹配 tag 时返回非 0，配合 set -e 会让整个脚本静默退出
      # 用 || true 兜底，让 current_tag 为空时走下方"更新"分支自动 fetch tags
      current_tag=$(cd "$dir" && git describe --tags --exact-match 2>/dev/null || true)
      if [ "$current_tag" = "$version" ] || [ "$current_tag" = "v${version}" ]; then
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
        if (cd "$dir" && git fetch --depth 1 origin "refs/tags/${tag}:refs/tags/${tag}" && \
            git checkout -q "$tag"); then
          update_count=$((update_count + 1))
        else
          echo "  ⚠ checkout $tag 失败"
          fail_count=$((fail_count + 1))
        fi
      fi
    else
      echo "[跳过] $name"
      skip_count=$((skip_count + 1))
    fi
    continue
  fi

  # 情况 3：目录不存在 → clone（显示原生进度，避免看起来像卡死）
  echo "[下载] $name ${version:+$version}"
  if [ -n "$version" ]; then
    # 先解析远端真实 tag 名，再用浅克隆只拉该 tag，不拖全量历史
    tag=$(resolve_remote_tag "$url" "$version" || true)
    if [ -z "$tag" ]; then
      echo "  ⚠ 远端找不到版本 $version（已尝试 $version 与 v$version）"
      fail_count=$((fail_count + 1))
      continue
    fi
    if git clone --depth 1 --branch "$tag" "$url" "$name"; then
      clone_count=$((clone_count + 1))
    else
      echo "  ⚠ clone 失败，请检查网络或 URL"
      fail_count=$((fail_count + 1))
    fi
  else
    if git clone --depth 1 "$url" "$name"; then
      clone_count=$((clone_count + 1))
    else
      echo "  ⚠ clone 失败，请检查网络或 URL"
      fail_count=$((fail_count + 1))
    fi
  fi

done <<< "$ENTRIES"

echo ""
echo "完成。下载: $clone_count / 更新: $update_count / 跳过: $skip_count / 失败: $fail_count"
echo "缓存目录: $CACHE_DIR"
