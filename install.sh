#!/bin/bash

# spm-local 安装脚本
# 用法: curl -sL https://raw.githubusercontent.com/iAmMccc/spm-local/main/install.sh | bash
#
# 做两件事：
#   1. 把 SKILL.md 安装到 .claude/skills/spm-local/ 和/或 .cursor/skills/spm-local/
#   2. 在当前项目根目录初始化 Packages/ 目录结构

set -e

REPO="iAmMccc/spm-local"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
GIT_URL="https://github.com/${REPO}.git"
SKILL_NAME="spm-local"

# Skill 文件清单（安装到 AI 工具的 skills 目录）
FILES="SKILL.md packages.json.example scripts/fetch-packages.sh spm VERSION"

# 版本号以当前 main commit 上的 tag 为准；VERSION 文件只作为记录。
version_label() {
  case "$1" in
    v*) printf '%s' "$1" ;;
    *) printf 'v%s' "$1" ;;
  esac
}

resolve_tag_version() {
  local head_sha refs
  head_sha=$(git ls-remote --heads "$GIT_URL" "$BRANCH" 2>/dev/null | awk '{print $1; exit}') || return 1
  [ -n "$head_sha" ] || return 1

  refs=$(git ls-remote --tags "$GIT_URL" 2>/dev/null) || return 1
  printf '%s\n' "$refs" | awk -v head="$head_sha" '
    function clean_tag(ref) {
      sub("^refs/tags/", "", ref)
      sub("\\^\\{\\}$", "", ref)
      return ref
    }

    function semver_key(tag, parts, count, i, key, version) {
      version = tag
      sub("^v", "", version)
      count = split(version, parts, ".")
      key = ""

      for (i = 1; i <= 4; i++) {
        if (i <= count && parts[i] ~ /^[0-9]+$/) {
          key = key sprintf("%08d", parts[i])
        } else if (i <= count) {
          return ""
        } else {
          key = key sprintf("%08d", 0)
        }
      }

      return key
    }

    $1 == head {
      tag = clean_tag($2)
      key = semver_key(tag)
      if (key != "" && key >= best_key) {
        best_key = key
        best_tag = tag
      }
    }

    END {
      if (best_tag != "") {
        print best_tag
      }
    }
  '
}

if ! command -v git >/dev/null 2>&1; then
  echo "错误: 需要 git 来解析远端版本 tag"
  exit 1
fi

set +e
VERSION=$(resolve_tag_version)
RESOLVE_STATUS=$?
set -e

if [ "$RESOLVE_STATUS" -ne 0 ]; then
  echo "错误: 无法读取远端 ${REPO} 的 main 或 tags"
  echo "请检查网络、代理或仓库权限"
  exit 1
fi

if [ -z "$VERSION" ]; then
  echo "错误: 远端 ${BRANCH} 当前 commit 没有对应的版本 tag"
  echo "请先给 ${BRANCH} 当前 commit 打 tag 并推送，例如：git tag 1.1.1 && git push origin 1.1.1"
  exit 1
fi
VER_LABEL=$(version_label "$VERSION")

echo "正在安装 ${SKILL_NAME} ${VER_LABEL}..."

# 校验仓库可达
HTTP_CODE=$(curl -sL -o /dev/null -w "%{http_code}" "${BASE_URL}/SKILL.md")
if [ "$HTTP_CODE" != "200" ]; then
  echo "错误: 无法获取 SKILL.md，请检查网络或仓库地址"
  echo "  ${BASE_URL}/SKILL.md"
  exit 1
fi

# 检查两个目录是否指向同一位置（软链接或相同真实路径）
same_skills_dir() {
  local dir1="$1" dir2="$2"
  [ -d "$dir1" ] && [ -d "$dir2" ] || return 1
  local real1 real2
  real1=$(cd "$dir1" 2>/dev/null && pwd -P)
  real2=$(cd "$dir2" 2>/dev/null && pwd -P)
  [ "$real1" = "$real2" ]
}

# 根据已有目录决定安装到哪些 skills 目录（兼容 Claude Code 和 Cursor）
has_claude=false
has_cursor=false
[ -d ".claude" ] && has_claude=true
[ -d ".cursor" ] && has_cursor=true

if $has_claude && $has_cursor; then
  mkdir -p .claude/skills .cursor/skills 2>/dev/null
  if same_skills_dir ".claude/skills" ".cursor/skills"; then
    echo "检测到 .cursor/skills 与 .claude/skills 指向同一目录，只安装一份"
    SKILL_DIRS=".claude/skills/${SKILL_NAME}"
  else
    SKILL_DIRS=".claude/skills/${SKILL_NAME} .cursor/skills/${SKILL_NAME}"
  fi
elif $has_claude; then
  SKILL_DIRS=".claude/skills/${SKILL_NAME}"
elif $has_cursor; then
  SKILL_DIRS=".cursor/skills/${SKILL_NAME}"
else
  # 都没有，两个都装，兼容 Claude Code 和 Cursor
  SKILL_DIRS=".claude/skills/${SKILL_NAME} .cursor/skills/${SKILL_NAME}"
fi

# 下载 Skill 文件到所有目标目录
fail=0
for SKILL_DIR in $SKILL_DIRS; do
  for file in $FILES; do
    dir=$(dirname "$file")
    if [ "$dir" != "." ]; then
      mkdir -p "${SKILL_DIR}/${dir}"
    else
      mkdir -p "${SKILL_DIR}"
    fi

    curl -sL "${BASE_URL}/${file}" -o "${SKILL_DIR}/${file}"
    if [ $? -ne 0 ]; then
      echo "  下载失败: ${file}"
      fail=1
    else
      if [ "$file" = "VERSION" ] && [ -n "$VERSION" ]; then
        echo "$VERSION" > "${SKILL_DIR}/${file}"
      fi
      if [[ "$file" == *.sh ]] || [ "$file" = "spm" ]; then
        chmod +x "${SKILL_DIR}/${file}"
      fi
    fi
  done
done

if [ "$fail" -eq 0 ]; then
  file_count=$(echo "$FILES" | wc -w | tr -d ' ')
  for SKILL_DIR in $SKILL_DIRS; do
    if [ -f "${SKILL_DIR}/SKILL.md" ]; then
      echo "已安装到 ${SKILL_DIR}/（${file_count} 个文件）"
    fi
  done
else
  echo "安装失败，请检查网络连接"
  for SKILL_DIR in $SKILL_DIRS; do
    rm -rf "$SKILL_DIR"
  done
  exit 1
fi

# 取第一个安装目录作为来源拷贝工作文件
SRC_DIR=$(echo $SKILL_DIRS | awk '{print $1}')
VERSION_FILE="Packages/.spm-local-version"
FETCH_SCRIPT="Packages/scripts/fetch-packages.sh"
SPM_CLI="spm"

install_fetch_script() {
  mkdir -p Packages/scripts
  if [ -d "$FETCH_SCRIPT" ]; then
    echo "错误: $FETCH_SCRIPT 是目录，无法覆盖为脚本"
    exit 1
  fi
  rm -f "$FETCH_SCRIPT"
  cp -f "${SRC_DIR}/scripts/fetch-packages.sh" "$FETCH_SCRIPT"
  chmod +x "$FETCH_SCRIPT"
}

install_spm_cli() {
  if [ -d "$SPM_CLI" ]; then
    echo "错误: $SPM_CLI 是目录，无法覆盖为命令脚本"
    exit 1
  fi
  rm -f "$SPM_CLI"
  cp -f "${SRC_DIR}/spm" "$SPM_CLI"
  chmod +x "$SPM_CLI"
}

# 在项目根目录初始化 Packages/ 目录
if [ ! -d "Packages" ]; then
  mkdir -p Packages/Caches Packages/scripts
  cp "${SRC_DIR}/packages.json.example" Packages/packages.json
  install_fetch_script
  install_spm_cli
  echo "$VERSION" > "$VERSION_FILE"

  echo ""
  echo "已初始化 Packages/ 目录（${VER_LABEL}）："
  echo "  Packages/packages.json              ← 在这里配置依赖"
  echo "  spm                                  ← 项目内命令入口"
  echo "  Packages/scripts/fetch-packages.sh  ← 底层下载脚本"
  echo "  Packages/Caches/                    ← 三方库下载目录"
  echo ""
  echo "说明："
  echo "  通过终端将 SPM 三方库下载到本地，在 Xcode 中以 Add Local 方式引入。"
  echo "  是否提交 Packages/Caches/ 由业务方自行决定，安装脚本不会修改 .gitignore。"
  echo ""
  echo "下一步："
  echo "  1. 编辑 Packages/packages.json，添加你的依赖"
  echo "  2. 执行 ./spm install"
  echo "  3. 在 Xcode 中 Add Local 添加 Packages/Caches/ 下的库"
else
  # Packages/ 已存在：不动 packages.json，但强制覆盖命令入口和下载脚本到最新版
  OLD_VERSION=$(cat "$VERSION_FILE" 2>/dev/null | head -n1 | tr -d '[:space:]')
  [ -n "$OLD_VERSION" ] && OLD_LABEL="v${OLD_VERSION}" || OLD_LABEL="(未知)"

  install_fetch_script
  install_spm_cli
  echo "$VERSION" > "$VERSION_FILE"

  echo ""
  if [ "$OLD_VERSION" = "$VERSION" ]; then
    echo "Packages/ 已是最新（${VER_LABEL}），命令入口和下载脚本已确认为最新版。"
  else
    echo "Packages/ 已存在：保留你的 packages.json，命令入口和下载脚本已更新 ${OLD_LABEL} → ${VER_LABEL}。"
  fi
fi
