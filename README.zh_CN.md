# discourse-indexnow

[English](README.md) | [中文](README.zh_CN.md)

[![Discourse Plugin CI](https://github.com/imlotso/discourse-indexnow/actions/workflows/discourse-plugin.yml/badge.svg)](https://github.com/imlotso/discourse-indexnow/actions/workflows/discourse-plugin.yml)

自动把 Discourse 话题 URL 提交给 [IndexNow](https://www.indexnow.org/) 协议，让 Bing、Yandex 以及其他兼容搜索引擎更快发现公开内容。

## 功能特性

- 新公开话题和会改变话题属性的编辑会自动提交。
- 产生新回复时自动提交对应的分页 URL（支持防刷新的单 URL 冷却时间配置）。
- 话题删除时提交话题 URL，让支持 IndexNow 的搜索引擎更快复查并下架内容。
- 在 Discourse Content Localization 及其爬虫 locale 参数启用时，自动包含本地化话题 URL。
- 翻译创建时提交本地化 URL，包括首次提交话题后才完成的翻译。
- 把主 URL 和实际存在的本地化内容合并为一次 IndexNow `urlList` 批量提交。
- 历史帖子补量复用同一套批量引擎，并自动按 10,000 条上限分片。
- 支持基于滑动窗口 (Sliding window) 的每小时和每日提交上限，并识别 IndexNow 的 `Retry-After` 响应。
- 支持密钥轮换，生成新密钥后旧密钥立即失效。
- 管理后台可以检查 `/<key>.txt` 是否公网可访问。
- 话题移动、分类可见性变化和标签更新时，自动重新提交或同步排除。
- 日志记录批次 ID、locale、近 7 天成功率趋势和失败原因分类。
- 后台支持按分类和日期范围预览、提交历史帖子。
- 后台支持手动提交 URL，每行一个链接。
- 全部提交异步执行，并保持隐私过滤。
- 管理界面提供英文和简体中文。

## 环境要求

- Discourse latest stable 或 tests-passed 分支。
- 不需要额外 Ruby gems，也不需要修改主题。
- 本地化 URL 提交需要可选的 Content Localization 功能。

## 安装步骤

1. 在 Discourse 容器中安装插件：
   ```sh
   cd /var/discourse
   ./launcher enter app
   bash -c "cd plugins && git clone https://github.com/imlotso/discourse-indexnow.git"
   exit
   ```
2. 重建容器：
   ```sh
   cd /var/discourse
   ./launcher rebuild app
   ```
3. 打开 **Admin > Plugins > discourse-indexnow**。
4. 生成密钥，或填入已有的 32 位十六进制密钥。
5. 启用插件。
6. 验证公网密钥地址：
   ```text
   https://你的论坛域名/<key>.txt
   ```
   正常应返回密钥本身和 HTTP 200。管理后台也会显示带缓存的可达性检查结果。

## 配置项

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `indexnow_enabled` | `false` | 插件总开关。 |
| `indexnow_api_key` | `""` | 当前 32 位十六进制密钥。 |
| `indexnow_submit_on_create` | `true` | 新话题发布时提交。 |
| `indexnow_submit_on_edit` | `true` | 首帖或话题属性变化后重新提交。 |
| `indexnow_submit_on_reply` | `false` | 产生新回复时自动提交对应的分页 URL。 |
| `indexnow_url_cooldown_minutes` | `1` | 单个 URL 的防刷新冷却时间（分钟）。 |
| `indexnow_excluded_category_ids` | `""` | 额外排除的分类。 |
| `indexnow_excluded_tag_names` | `""` | 额外排除的标签。 |
| `indexnow_hourly_limit` | `200` | 每小时最多提交的 URL 数。 |
| `indexnow_daily_limit` | `10000` | 每天最多提交的 URL 数。 |

站点开启 `login_required` 时无法启用插件；如果之后开启该设置，插件会自动禁用。

`submit on create` 和 `submit on edit` 设置只负责新话题和已编辑话题的自动提交。历史补量和手动提交是两个独立的后台操作：

- **历史帖子补量提交：** 按分类和日期范围筛选话题，先预览匹配结果，再批量提交符合条件的历史话题。
- **手动提交：** 每行粘贴一个本站 URL，立即提交指定链接。外部 URL 和不符合条件的话题 URL 会自动过滤。

## 多语言 URL

当 Discourse Content Localization 启用且爬虫 locale URL 可用时，插件会生成主 URL，并为话题中真实存在的每个本地化内容生成一个变体 URL。URL 使用 Discourse 实际配置的 locale 查询参数，通常是 `?tl=es`，不会硬编码参数名。

所有符合条件的 URL 在日志中共享同一个批次 ID。因此主 URL 和各 locale URL 仍然可以单独检索，同时也能看出它们属于同一次提交。如果话题是私密、受限、已删除、被排除或其他不符合条件的内容，所有本地化变体都会同步排除。

## 批量提交与节流

插件会尽可能使用一次 IndexNow 请求发送 `urlList` 数组。超过 10,000 条的逻辑批次会自动拆分，并用批次索引记录每个分片。

Redis 计数器负责每小时和每日限额。收到 IndexNow 429 时，如果响应包含 `Retry-After`，插件会按该值设置全局节流截止时间；否则使用递增的退避间隔。被限流的提交会记录为失败，错误信息为 `rate_limit_exceeded`。

## 管理后台

**Admin > Plugins > discourse-indexnow** 提供以下能力：

- 插件和密钥状态。
- `/<key>.txt` 的带缓存公网可达性检查。
- 今日成功和失败数量。
- 实时配额进度条，精确显示额度恢复倒计时。
- 近 7 天成功与失败趋势。
- 限流、密钥错误、域名不匹配和其他错误的分类统计。
- 按分类和日期范围预览、提交历史帖子。
- 手动提交 URL，每行一个链接。
- 带批次信息的日志，可按 URL、locale、状态、触发原因、响应码和错误信息过滤。
- 分页和一键生成密钥。

该页面在 Ember 内部跳转、直接输入 URL 和硬刷新时都能正常渲染。

## 隐私与安全

提交会在入队前和任务执行时双重过滤。以下内容不会被提交：

- 需要登录的站点。
- 私信。
- 设置 `read_restricted` 的分类。
- 未列出话题，以及删除通知事件之外的已删除话题。
- 位于 `indexnow_excluded_category_ids` 中的分类。
- 带有 `indexnow_excluded_tag_names` 中任意标签的话题。

密钥路由按协议要求公开，未知密钥返回 404，并限制每个 IP 每分钟最多 100 次请求。生成新密钥后，旧密钥立即失效。

## 已知限制

- Google 未参与 IndexNow 协议。
- 只有 Content Localization 爬虫 locale URL 启用且本地化内容存在时，才会提交本地化 URL。

## 开发测试

在 Discourse 开发环境中执行：

```sh
bundle exec rspec plugins/discourse-indexnow/spec
```

每次推送和 Pull Request 都会运行 Discourse 官方插件 CI 工作流。

## 许可证

MIT
