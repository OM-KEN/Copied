# Copied 发布流程

项目已启用 **sparse-checkout**（`Copied-mac` only），日常提交直接 `git pull --rebase && git push`，无需 `/tmp` clone。

## 创建 Release

```bash
# 1. 构建 DMG
cd Copied-mac
bash build.sh
hdiutil create -volname Copied \
  -srcfolder .build/Copied.app \
  -ov -format UDZO Copied.dmg

# 2. 创建 Release（DMG 不上传 git）
gh release create vX.Y.Z \
  --title "Copied vX.Y.Z (macOS)" \
  --notes "Release 描述" \
  Copied.dmg
```

## Release Notes 规范

1. **禁止使用 @ 符号**（GitHub 会误解析为 mention）
2. 结构：新功能 → 修复 → 系统要求
3. 中英文混排，关键术语优先用中文

## 注意事项

- DMG 不上传 git（已在 .gitignore）
- Release tag 格式 `vX.Y.Z`（如 v1.2.0）
- 日常提交不走 `/tmp` clone，sparse-checkout 已隔离 Copied-win
