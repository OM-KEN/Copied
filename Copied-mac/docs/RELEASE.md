# Copied GitHub 发布流程

每次发布新版本到 GitHub 时，严格按以下步骤执行。

## 1. 克隆最新仓库

```bash
cd /tmp && rm -rf Copied && gh repo clone OM-KEN/Copied
```

## 2. 替换目标平台文件

以 macOS 为例（只替换 Copied-mac，保留 Copied-win 及其他文件夹不变）：

```bash
# 清空目标文件夹
rm -rf /tmp/Copied/Copied-mac/*

# 复制当前项目所有源文件（排除 .build、.dmg 等构建产物）
cp /Users/om/Projects/Copied/Copied-mac/*.swift \
   /Users/om/Projects/Copied/Copied-mac/*.md \
   /Users/om/Projects/Copied/Copied-mac/*.sh \
   /Users/om/Projects/Copied/Copied-mac/*.plist \
   /tmp/Copied/Copied-mac/

# 根目录 README 如有变动也同步
cp /Users/om/Projects/Copied/README.md /tmp/Copied/README.md
```

## 3. 确认变更范围

```bash
cd /tmp/Copied && git status && git diff --stat
```

确保：
- Copied-mac 内只有预期变动的文件
- Copied-win 及其他文件夹未被修改
- 没有构建产物（.build、.dmg）被复制进去

## 4. 构建 DMG

```bash
cd /Users/om/Projects/Copied/Copied-mac
bash build.sh
hdiutil create -volname Copied \
  -srcfolder .build/Copied.app \
  -ov -format UDZO Copied.dmg
```

## 5. 提交并推送

Commit message 格式：`Copied vX.Y.Z (平台): 简短描述`

```bash
cd /tmp/Copied
git add -A
git commit -m "Copied vX.Y.Z (macOS): 变更简述"
git push origin main
```

## 6. 创建 GitHub Release

将 DMG 复制到临时目录并创建 release：

```bash
cp /Users/om/Projects/Copied/Copied-mac/Copied.dmg /tmp/Copied/Copied-vX.Y.Z.dmg

gh release create vX.Y.Z \
  --title "Copied vX.Y.Z (macOS)" \
  --notes "Release 描述" \
  /tmp/Copied/Copied-vX.Y.Z.dmg
```

## Release Notes 规范

1. **禁止使用 @ 符号**（GitHub 会误解析为 mention，导致无法正常显示）
2. 用 `[按钮名]` 代替 @按钮名，用 `路径/文件名` 代替 @路径
3. 结构：新功能 → 修复 → 系统要求
4. 中英文混排，关键术语优先用中文

## 注意事项

- 永远从最新仓库 clone，不要覆盖本地 git 仓库
- 推送前确认 Copied-win 等兄弟文件夹未被误删或修改
- DMG 作为 release asset 上传，不要提交到 git 仓库
- Release tag 格式统一为 `vX.Y.Z`（如 v1.1.0）
