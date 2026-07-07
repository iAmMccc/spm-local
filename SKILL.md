---
name: spm-local
description: |
  当用户要求管理 SPM 本地依赖、添加新的三方库、更新依赖版本、
  或遇到 Xcode SPM 网络问题时使用。
  通过终端下载三方库到本地，绕过 Xcode 的网络限制。
---

# SPM 本地依赖管理

通过终端将三方库下载到本地 `Packages/Caches/` 目录，Xcode 以 Add Local 方式引入。

## 目录结构

```
.
├── spm                        # 项目内命令入口
└── Packages/
    ├── packages.json          # 依赖清单（URL + 版本）
    ├── scripts/
    │   └── fetch-packages.sh  # 底层下载/更新脚本
    └── Caches/                # 下载的三方库
```

## 依赖清单格式

```json
[
  { "url": "https://github.com/iAmMccc/SmartCodable", "version": "7.0.0" },
  { "url": "https://github.com/SnapKit/SnapKit" }
]
```

- `url`：仓库地址（必填）
- `version`：tag 版本号（可选，不填则拉取默认分支最新）
- 库名自动从 URL 解析

## 关于仓库地址

`url` 必须由用户提供，不要凭记忆猜测。即使是 SmartCodable、SnapKit 等知名库，不同组织、fork、改名都可能导致地址不同，猜错会让 clone 直接失败。

当用户只给出库名（如「添加 SnapKit」）而未提供 url 时，先向用户索取完整仓库地址，确认后再写入 `packages.json`。

## 执行流程

### 新增依赖

1. 向用户确认依赖的仓库 url（及可选的 version）
2. 编辑 `Packages/packages.json`，添加一条记录
3. 执行 `./spm install`
4. Xcode → File → Add Package Dependencies → Add Local → 选择 `Packages/Caches/` 下对应文件夹

### 更新版本

1. 修改 `Packages/packages.json` 中对应条目的 `version`
2. 执行 `./spm install`
3. Xcode → File → Packages → Resolve Package Versions

### 更新到最新

当用户要把未写明确 `version` 的依赖更新到远端默认分支最新时，不需要修改 `packages.json`：

```bash
./spm update
./spm update <库名>
```

- `update`：刷新清单中的所有依赖
- `update <库名>`：只刷新指定依赖，库名来自 URL 末尾（例如 SnapKit）
- 已写 `version` 的依赖会同步到清单指定 tag
- 未写 `version` 的依赖会更新到远端默认分支最新
- 更新时把 `Packages/Caches/` 下对应库当作可再生成缓存，不检查 dirty 状态，直接覆盖本地未提交改动

## 脚本逻辑

1. 读取 `packages.json`，逐条处理
2. 从 URL 解析库名
3. 判断 `Caches/` 下是否已存在该库：
   - **不存在** → clone（指定版本则完整 clone + checkout，否则浅克隆）
   - **存在但为空目录** → 删除后重新 clone
   - **存在且有内容** → 指定了版本则 fetch + checkout；未指定版本默认 skip，执行 `update` 时 fetch 远端默认分支并强制覆盖本地缓存
4. 完成后输出汇总
