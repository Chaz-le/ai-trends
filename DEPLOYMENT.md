# GitHub AI 榜单网站部署说明

这份说明用于把当前本地页面发布成一个朋友可以直接访问的网址。

## 1. 最快上线：GitHub Pages

1. 登录 GitHub。
2. 新建公开仓库，建议仓库名使用 `ai-trends`。
3. 进入新仓库，点击 `Add file` -> `Upload files`。
4. 上传本文件夹里的所有文件和文件夹。
5. 点击 `Commit changes`。
6. 打开仓库的 `Settings` -> `Pages`。
7. 在 `Build and deployment` 中选择：
   - Source: `Deploy from a branch`
   - Branch: `main`
   - Folder: `/root`
8. 点击 `Save`，等待几分钟。
9. 发布成功后，访问地址通常是：

```text
https://你的GitHub用户名.github.io/ai-trends/
```

如果你的仓库名不是 `ai-trends`，网址最后一段会变成你的仓库名。

## 2. 每日自动更新

项目已经内置 GitHub Actions 自动更新文件：

```text
.github/workflows/update-trends.yml
```

上传到 GitHub 后，它会：

- 每天北京时间 08:10 自动抓取 GitHub Trending 和仓库数据。
- 更新 `data/trends.json` 和 `data/history.json`。
- 重新生成 `index.html`、`ai-trends-standalone.html`、`ai-trends-redesign-v2.html`。
- 自动提交更新，GitHub Pages 会随之刷新。

你也可以在 GitHub 仓库的 `Actions` 页面手动点击 `Update AI trends` -> `Run workflow` 立即更新一次。

## 3. 重要提醒

- 当前网站是公开静态站，不包含打赏解锁模块。
- `index.html` 是网站首页，朋友访问网址时默认看到这个页面。
- 新出现的项目如果没有人工补充中文说明，页面会显示待补充提示；已有项目的中文说明会尽量保留。
- 如果你只上传 `index.html`，页面也能打开，但每日自动更新不会完整工作。

## 4. 以后可以继续升级

上线后可以继续做这些优化：

- 绑定自己的域名。
- 增加项目详情页、搜索、筛选和分类。
- 改成更像资讯站或榜单站的首页。
- 重新加入打赏/会员解锁模块。
