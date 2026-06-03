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
SKILL_NAME="spm-local"

# Skill 文件清单（安装到 AI 工具的 skills 目录）
FILES="SKILL.md packages.json.example scripts/fetch-packages.sh"

echo "正在安装 ${SKILL_NAME}..."

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
      if [[ "$file" == *.sh ]]; then
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

# 在项目根目录初始化 Packages/ 目录
if [ ! -d "Packages" ]; then
  mkdir -p Packages/Caches Packages/scripts
  # 取第一个安装目录作为来源拷贝工作文件
  SRC_DIR=$(echo $SKILL_DIRS | awk '{print $1}')
  cp "${SRC_DIR}/packages.json.example" Packages/packages.json
  cp "${SRC_DIR}/scripts/fetch-packages.sh" Packages/scripts/fetch-packages.sh
  chmod +x Packages/scripts/fetch-packages.sh

  if [ -f ".gitignore" ]; then
    if ! grep -q "Packages/Caches" .gitignore 2>/dev/null; then
      echo "" >> .gitignore
      echo "# SPM 本地缓存（三方库源码不提交）" >> .gitignore
      echo "Packages/Caches/" >> .gitignore
    fi
  else
    echo "# SPM 本地缓存（三方库源码不提交）" > .gitignore
    echo "Packages/Caches/" >> .gitignore
  fi

  echo ""
  echo "已初始化 Packages/ 目录："
  echo "  Packages/packages.json              ← 在这里配置依赖"
  echo "  Packages/scripts/fetch-packages.sh  ← 执行下载"
  echo "  Packages/Caches/                    ← 三方库下载目录"
  echo ""
  echo "说明："
  echo "  通过终端将 SPM 三方库下载到本地，在 Xcode 中以 Add Local 方式引入。"
  echo "  Packages/Caches/ 已自动添加到 .gitignore，三方库源码不会被提交。"
  echo ""
  echo "下一步："
  echo "  1. 编辑 Packages/packages.json，添加你的依赖"
  echo "  2. 执行 ./Packages/scripts/fetch-packages.sh"
  echo "  3. 在 Xcode 中 Add Local 添加 Packages/Caches/ 下的库"
else
  echo ""
  echo "Packages/ 目录已存在，跳过初始化。"
fi
