---
name: git-push
description: Use when doing ANY git operation on the Copied project — commit, push, pull, or release. MUST load before git add/commit/push/pull/rebase.
---

# Copied Git 推送与发布

## 关键规则（硬性）

- **只改 Copied-mac，只传 Copied-mac** — 根 `README.md` 已设 `skip-worktree`，git 完全无视。
- **Sparse-checkout** — `Copied-win/` 不可见不可改
- **DMG 不上传 git** — 已在 `.gitignore`
- **先 pull --rebase 再 push** — mac/win 不同文件夹，永不冲突
- **commit 含 `feat:` 前缀 → 必须走 Release 流程**（不能跳过，不能"下次再说"）

## 提交流程（强制步骤，不可跳过任何一步）

### Step 1: 暂存

```bash
cd /Users/om/Projects/Copied                    # 必须在 git 根目录
git add Copied-mac/                              # 只 add Copied-mac/ 下文件
```

### Step 2: 确认暂存内容

```bash
git status --short
```

检查：**没有根 `README.md`**（已 `skip-worktree`，正常不会出现）、不能有 `.dmg` 文件。
**如果看到根 `README.md` 出现** → skip-worktree 意外失效，先执行 `git update-index --skip-worktree README.md` 再继续。

### Step 3: 提交

```bash
git commit -m "type: 简短描述"
```

Commit 类型：
| 前缀 | 含义 | 需要 Release？ |
|------|------|:---:|
| `feat:` | 新功能/重大变更 | **必须** |
| `fix:` | Bug 修复 | 可选 |
| `chore:` | 构建/工具/依赖 | 可选 |
| `docs:` | 文档 | 否 |
| `refactor:` | 重构（无功能变更） | 否 |

### Step 4: Pull rebase + Push

```bash
git pull --rebase
git push
```

如果 push 时有 unstaged changes（如根 README）：`git stash && git pull --rebase && git stash pop && git push`。

### Step 5: 决定是否发 Release（这一步不能跳过）

**判断规则**：

1. 如果 commit message 以 `feat:` 开头 → **必须**创建 Release，**不询问用户**，直接进入 Step 6
2. 如果是 `fix:` 且修复影响用户可见行为 → 建议创建 Release，用 AskUserQuestion 问用户
3. 如果是 `chore:`/`docs:`/`refactor:` → 跳过，告知用户"已跳过 Release（非功能变更）"

**仅对情况 2（`fix:`）**，用 AskUserQuestion 问用户：
- Header: "Release"
- Question: "是否创建 Release？"
- Options: "是，创建 Release (Recommended)" / "跳过"

**情况 1（`feat:`）绝不询问**——直接告知用户"feat: 提交，自动进入 Release 流程"，然后执行 Step 6。

## 发布 Release 流程

### Step 6: 确定版本号

```bash
gh release list --limit 1
```

版本号规则：
- **每段 ≤ 9**：每个版本段（major、minor、patch）不超过 9
- 1.9.0 → 2.0.0（不是 1.10.0），自然进位
- 只有用户明确要求时才能超过 9
- `feat:` → Y+1（v1.4.0 → v1.5.0，v1.9.0 → v2.0.0）
- `fix:` → Z+1（v1.4.0 → v1.4.1，v1.4.9 → v1.5.0）

### Step 7: 构建 DMG

```bash
cd /Users/om/Projects/Copied/Copied-mac
./build.sh
hdiutil create -volname Copied \
  -srcfolder .build/Copied.app \
  -ov -format UDZO Copied.dmg
```

### Step 8: 写 Release Notes

写入 `/tmp/release-notes.md`（用 `cat > /tmp/release-notes.md << 'EOF'` 避免文件不存在报错），结构：

```
## 新功能
- 功能点（中文描述，不用 @ 符号）

## 修复
- 修复点

## 系统要求
- macOS 26+
```

禁止：
- `@` 符号（GitHub 误解析为 mention）
- 反引号（shell 转义问题），用纯文本描述
- 英文标点在中文段落中混用

### Step 9: 创建 Release

```bash
gh release create vX.Y.Z \
  --title "Copied vX.Y.Z (macOS)" \
  --notes-file /tmp/release-notes.md \
  Copied.dmg
```

### Step 10: 清理 DMG

```bash
rm Copied.dmg
```

## 完整速查

```bash
# 1. stage
cd /Users/om/Projects/Copied && git add Copied-mac/

# 2. check
git status --short

# 3. commit
git commit -m "feat: 描述"

# 4. push
git pull --rebase && git push

# 5. release (如果是 feat:)
VER=$(gh release list --limit 1 --json tagName -q '.[0].tagName' | sed 's/v//')
MAJOR=$(echo $VER | cut -d. -f1)
MINOR=$(echo $VER | cut -d. -f2)
PATCH=$(echo $VER | cut -d. -f3)
NEW="v$MAJOR.$((MINOR+1)).0"  # feat → minor+1（注意 ≤9 规则：若 MINOR==9 则 NEW="v$((MAJOR+1)).0.0"）
cd Copied-mac && ./build.sh
hdiutil create -volname Copied -srcfolder .build/Copied.app -ov -format UDZO Copied.dmg
gh release create $NEW --title "Copied $NEW (macOS)" --notes-file /tmp/release-notes.md Copied.dmg
rm Copied.dmg
```

## 反合理化（Red Flags）

以下任何一条出现 → **停止**，回到 Step 5 执行 Release：

- "这次改动太小了，不需要 Release"
- "用户说可以跳过"
- "上次也没发 Release，这次也可以"
- "Release Notes 太难写，先跳过"
- "只是重构，虽然 commit 写了 feat:"

**原则**：commit 前缀决定行为，不由主观判断。`feat:` = Release，无例外。

| 借口 | 现实 |
|------|------|
| "改动太小" | `feat:` 前缀说明开发者自己认为这是功能变更。Release 版本号反映的是变更性质，不是代码量 |
| "用户没要求" | Release 是开发者责任，不是用户责任 |
| "赶时间" | Release 流程（构建 DMG + gh release create）< 2 分钟 |

## 常见错误

| 错误 | 正确做法 |
|------|---------|
| 在 `Copied-mac/` 目录下直接 `git add` | 必须 `cd` 到 git 根目录 `/Users/om/Projects/Copied` |
| 用了 `git add .` 或 `git add -A` | **严禁**！只用 `git add Copied-mac/` |
| 忘了 `pull --rebase` | 永远先 pull 再 push |
| 推完代码忘了创建 Release | **Step 5 强制执行**，`feat:` 前缀必须走 Release |
| 改了根 `README.md` | 已 `skip-worktree`，改不了 |
| commit 了 `Copied-win/` 文件 | sparse-checkout 下不可见，不可能发生 |
| Release Notes 用了 `@` 或反引号 | 纯文本中文描述，不用任何 markdown 格式符号 |
