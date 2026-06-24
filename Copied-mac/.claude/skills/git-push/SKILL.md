---
name: git-push
description: Use when doing ANY git operation on the Copied project — commit, push, pull, or release. MUST load before git add/commit/push/pull/rebase.
---

# Copied Git 推送与发布

## 关键规则（硬性）

- **只改 Copied-mac，只传 Copied-mac** — 根 `README.md` 不归你管
- **Sparse-checkout** — `Copied-win/` 不可见不可改
- **DMG 不上传 git** — 已在 `.gitignore`
- **先 pull --rebase 再 push** — mac/win 不同文件夹，永不冲突

## 日常提交流程

```bash
cd /Users/om/Projects/Copied                    # 必须在 git 根目录
git add Copied-mac/<changed-files>               # 只 add Copied-mac/ 下文件
git commit -m "type: 简短描述"
git pull --rebase
git push
```

## 发布 Release 流程

每次推送重大功能后，必须走完整发布流程：

### 1. 构建 DMG

```bash
cd /Users/om/Projects/Copied/Copied-mac
./build.sh
hdiutil create -volname Copied \
  -srcfolder .build/Copied.app \
  -ov -format UDZO Copied.dmg
```

### 2. 创建 Release

```bash
gh release create vX.Y.Z \
  --title "Copied vX.Y.Z (macOS)" \
  --notes-file /tmp/release-notes.md \
  Copied.dmg
```

版本号：新功能 → Y+1（v1.3.0 → v1.4.0）；修复 → Z+1（v1.3.0 → v1.3.1）。

### 3. Release Notes 规范

写入 `/tmp/release-notes.md`，结构：

```
## 新功能
- 功能点（中文描述，不用 @ 符号）

## 修复
- 修复点

## 系统要求
- macOS 26+
```

禁止使用 `@` 符号（GitHub 会误解析为 mention）。禁止在 notes 中使用反引号（shell 转义问题），用纯文本描述。

## 常见错误

| 错误 | 正确做法 |
|------|---------|
| 在 `Copied-mac/` 目录下直接 `git add` | 必须 `cd` 到 git 根目录 `/Users/om/Projects/Copied` |
| 忘了 `pull --rebase` | 永远先 pull 再 push |
| 推完代码忘了创建 Release | 重大功能推送后必须走发布流程 |
| 改了根 `README.md` | 不归你管，不要改 |
| commit 了 `Copied-win/` 文件 | sparse-checkout 下不可见，不可能发生 |
