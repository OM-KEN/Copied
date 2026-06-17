# GitHub 发布流程

## 1. 克隆最新仓库

```powershell
git clone https://github.com/OM-KEN/Copied.git D:/O.A/Copied-repo
# 如果已存在则 git pull
```

## 2. 替换 Copied-win

```powershell
# 清空旧文件（保留目录结构）
rm -r -force D:/O.A/Copied-repo/Copied-win/*

# 构建最新 exe
cd D:/O.A/Copied/Copied
dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -o ../publish

# 复制源码到仓库（排除 bin/obj/publish）
Get-ChildItem D:/O.A/Copied/Copied -Exclude bin,obj | Copy-Item -Recurse -Destination D:/O.A/Copied-repo/Copied-win/
```

## 3. 提交推送

```powershell
cd D:/O.A/Copied-repo
git add -A
git commit -m "Copied-win vX.Y.Z: 简述"
git push
```

## 4. 创建 Release

- 每个 Release 必须带两个 asset：`Copied.exe` + `Copied.dmg`
- macOS 无变更时从上一 Release 下载 dmg：`gh release download v上一版本 --pattern "Copied.dmg" --dir ...`
- 大文件分开上传，避免超时：

```powershell
gh release create vX.Y.Z --repo OM-KEN/Copied --title "Copied vX.Y.Z" --notes "..." --draft
gh release upload vX.Y.Z "path/to/Copied.dmg" --repo OM-KEN/Copied
gh release upload vX.Y.Z "path/to/Copied.exe" --repo OM-KEN/Copied    # 68MB，需较长时间
gh release edit vX.Y.Z --repo OM-KEN/Copied --draft=false
```

## 踩坑

- **Bash 下禁止用 `@'...'@`**（PowerShell here-string），会导致内容被 `@` 包裹，GitHub 显示异常。多行字符串用双引号直接写。
