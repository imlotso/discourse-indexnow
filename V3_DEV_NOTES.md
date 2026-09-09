# discourse-indexnow V3 开发须知

> 本文档记录 v1 到 v2 的最终实现状态、生产环境验证结论、踩坑根因和后续开发注意事项，供 V3 开发（人或 AI）接手时参考。
> 核心教训只有一句话：**Discourse 3.5+ 的 admin 插件路由有新旧两套模式，迁移到
> `use_new_show_route` 时必须四处同步（plugin.rb、route map、nav initializer、
> admin 前端文件路径），漏掉任何一处都会导致插件管理页报 "Unable to configure
> link to 'IndexNow'" 并无法进入配置页。**

## 0. V3 交接总览

### 项目定位与当前状态

`discourse-indexnow` 是一个 Discourse 插件，用于把公开话题 URL 及其真实存在的
Content Localization 变体提交给 IndexNow 协议，让 Bing、Yandex 等兼容搜索引擎
更快发现内容。V1 已在 `https://www.sitetalk.net` 生产环境验证过真实提交链路，
拿到 IndexNow HTTP `202`。V2 已完成多语言批量提交、历史补量、手动提交、
限流节流、key 管理、事件扩展、可观测性和发布收尾。

截至 V2 收尾：

- 最新提交：`e7868ef Fix backfill throttling and simplify key rotation`
- 本地插件测试：82 examples / 0 failures
- GitHub Actions：官方 Discourse plugin workflow 的 linting、check_for_tests、
  backend_tests、annotations_tests 全部通过
- 生产站点曾用约 700 条 URL 的历史补量验证规模路径；发现过 pending 卡住问题，
  修复后用户确认问题已消失

### 技术栈与整体架构

没有额外 Ruby gem，也不需要修改主题。核心依赖是 Discourse 插件机制、
Rails/ActiveRecord、Sidekiq jobs、Redis、Ember/GJS admin 前端和 `Excon` HTTP 客户端。

主要职责划分：

| 位置 | 职责 |
| --- | --- |
| `plugin.rb` | 插件入口、admin route 注册、事件监听、类加载 |
| `config/routes.rb` | `key.txt`、admin HTML shell、admin JSON API 路由 |
| `app/controllers/discourse_index_now/admin_controller.rb` | 渲染 admin HTML shell |
| `app/controllers/discourse_index_now/admin_logs_controller.rb` | Logs/统计/key 生成/历史补量/手动提交 API |
| `app/controllers/discourse_index_now/key_controller.rb` | 公开返回当前 `key.txt` |
| `app/models/discourse_index_now/submission_log.rb` | 每条 URL 一条提交审计日志 |
| `app/jobs/discourse_index_now/submit_batch.rb` | 查询 pending/failed 批次并调用 IndexNow |
| `app/jobs/scheduled/discourse_index_now/recover_stalled_logs.rb` | 兜底重派超过 30 分钟仍 pending 的批次 |
| `lib/discourse_index_now/client.rb` | Excon POST、`urlList` payload、429 处理 |
| `lib/discourse_index_now/url_builder.rb` | 生成主 URL 和真实存在的 locale URL |
| `lib/discourse_index_now/eligibility.rb` | 隐私、可见性、分类黑名单过滤 |
| `lib/discourse_index_now/submission_service.rb` | 事件入口、debounce、日志创建、job 派发 |
| `lib/discourse_index_now/throttle.rb` | Redis 小时/日限额、全局节流状态 |
| `lib/discourse_index_now/key_accessibility.rb` | `key.txt` 公网可达性检查，结果缓存 5 分钟 |

数据链路是：Discourse 事件 → `SubmissionService` 资格过滤和 debounce →
`SubmissionLog` 逐 URL 落库 → `SubmitBatch` job → `Client.submit_batch` →
IndexNow 响应 → 更新每条日志。逻辑批次通过 `batch_id` 关联，超过
10,000 条时用 `batch_index` 区分协议分片；同一个 HTTP 请求内每条 URL 仍可
单独检索。`SubmitUrl` 是 V1 名称，V2 的正式 job 是 `SubmitBatch`。

### V1/V2 关键坑与最终结论

1. **admin 路由不能注册双重 JSON 路径。** 无后缀的
   `/admin/plugins/discourse-indexnow/logs` 由 `AdminController#index` 渲染 HTML
   shell；数据接口只注册 `/logs.json`。不要在无后缀路由上使用
   `defaults: { format: :json }`，否则硬刷新会直接吐 JSON。
2. **FinalDestination 不适合这里的 POST。** Discourse 的 FinalDestination
   主要面向 URL 解析/防 SSRF 场景，不支持本插件需要的 IndexNow JSON POST。
   最终正确做法是用 `Excon.post`，并显式设置 body、headers、connect/read timeout
   和 `expects: [200, 202]`。
3. **429 不一定是“全局限流”。** 本地 `localhost` URL 被 IndexNow 拒绝时也可能返回
   429；本地拿到 429 只能证明完整链路已跑到 HTTP 层，不代表生产站点被限流。
   生产排查时必须同时看响应体、`Retry-After`、Redis 限额计数和日志状态。
4. **locale 参数不能硬编码 `locale`。** Discourse 核心常量是
   `Discourse::LOCALE_PARAM`，当前实际值为 `tl`。多语言 URL 应生成
   `?tl=es` 这类核心配置认可的参数；早期独立脚本里的 `?locale=es` 不是插件标准。
5. **`topic.localizations` 是合法的动态关联。** 它不是在 Topic 模型里静态写出的
   `has_many`，而是通过 `Localizable` concern 注入。不要因为静态 grep 不到
   `has_many :localizations` 就改成 `TopicLocalization.where(topic_id:...)`；
   两种都能查到数据，但当前插件使用 `topic.localizations`，且核心代码也有同类用法。
6. **历史补量 pending 的真实根因。** 旧逻辑要求整个 chunk 都满足
   `can_submit?(urls.size)`。当 700 条 backfill 遇到默认 200/h 限额时，任务永远
   无法通过检查，只是反复重派，日志全部停在 pending。正确做法是计算
   `available_capacity`，先提交当前容量内的 URL，成功后记录 Redis 计数，再把剩余
   pending 日志 `enqueue_in` 到下一个窗口；容量为 0 时不更新日志，只重派任务。
7. **兜底任务要避免重复派发。** `RecoverStalledLogs` 每 5 分钟扫描创建超过
   30 分钟仍 pending 的批次，但先用 `Jobs.scheduled_for` 和 Sidekiq RetrySet/default
   queue 检查同参数 job 是否仍活跃。这样限流等待中的批次不会被误判为丢失。
8. **key 轮换过渡期已被否决。** V2 曾实现 7 天 previous key 兼容；生产收尾时简化为
   只认 `SiteSetting.indexnow_api_key`。生成新 key 后旧 key 立即 404，不写
   PluginStore，也不保存过期时间。

### 生产运行状态与验证事实

- key 路由：`GET /<current_key>.txt`，只匹配 32 位十六进制 key；返回 HTTP 200
  且 body 等于当前 key。未知或旧 key 返回 404，每 IP 每分钟限 100 次。
- `Client.payload` 始终使用当前 key 和 `Discourse.base_url`，`host` 使用
  `Discourse.current_hostname`，`urlList` 单次最多 10,000 条。
- 默认节流阈值：`indexnow_hourly_limit = 200`，`indexnow_daily_limit = 10000`。
  这两个是插件自己的 Redis 计数，不等于 IndexNow 服务端限额。
- IndexNow 成功状态以 HTTP 200/202 为准；V1 生产环境已真实拿到过 202。
- `KeyAccessibility.check` 只读取缓存；冷缓存时用 Redis 锁去重并排队
  `CheckKeyAccessibility`。Sidekiq job 用 `Excon.get` 访问
  `Discourse.base_url/<key>.txt`，要求 body 精确匹配 key，结果按 key hash 缓存
  5 分钟，因此管理页面请求不等待网络自检。
- 历史补量和手动提交都复用 `SubmissionService.enqueue_batch`，入口不同但不会绕过
  topic eligibility、本站域名校验或 10,000 条协议上限。

### 已讨论但明确否决，V3 不要重复提出

以下方案不是未知项，而是已经评估后认为当前阶段没有实际需求：

- **沙盒模式**：不做。当前已有生产验证、测试 mock 和明确的 API 语义，沙盒
  会增加状态复杂度但不解决真实问题。
- **日志自动清理定时任务**：不做。现阶段日志量可控，而且审计价值高于清理收益。
  等表规模或存储压力出现真实约束，再基于生产数据设计保留策略。
- **静默失败告警定时任务**：不做。`RecoverStalledLogs` 已处理丢 job/pending 悬空，
  Logs 页面已有失败原因统计；单独告警 job 会带来新的通知配置和噪音问题。

不要仅因为“看起来更完善”把这三项重新加入 V3 scope。若未来有明确运营需求，
先补充真实数据和使用场景，再重新评估。

## 1. admin 插件路由：`use_new_show_route` 迁移必须四处同步

### 现象

插件管理页（`/admin/plugins`）出现红色提示：

> Unable to configure link to 'IndexNow'. Ensure ad-blockers are disabled and try reloading the page.

侧栏的 IndexNow 链接也无法跳转。

### 根因（Discourse 核心机制）

**后端** — `lib/plugin/instance.rb` `add_admin_route`（第 131-154 行）：

- 旧模式：`full_location = "adminPlugins.discourse-indexnow"`
- 新模式（`use_new_show_route: true`）：`full_location = "adminPlugins.show"`，
  侧栏链接指向 `/admin/plugins/discourse-indexnow`

**前端校验** — `frontend/discourse/app/lib/admin-utilities.js`：

```js
export function adminRouteValid(router, adminRoute) {
  try {
    if (adminRoute.use_new_show_route) {
      router.urlFor(adminRoute.full_location, adminRoute.location);
    } else {
      router.urlFor(adminRoute.full_location);
    }
    return true;
  } catch {
    return false;
  }
}
```

`admin-plugins.js` 控制器的 `brokenAdminRoutes` getter 会对所有已启用且有
`adminRoute` 的插件调用 `adminRouteValid()`。如果 `router.urlFor()` 抛异常
（即 Ember 路由表中找不到对应路由），该插件就被标记为 broken，页面显示
"Unable to configure link"。

**关键**：`use_new_show_route: true` 时，校验调用的是
`router.urlFor("adminPlugins.show", "discourse-indexnow")`。这要求 Ember
路由表中 `adminPlugins.show` 下存在能匹配 `"discourse-indexnow"` 这个
动态段值的子路由。如果 route map 没有正确注册子路由，`urlFor` 就会抛异常。

### 正确做法（四处同步）

1. **`plugin.rb`** — 加 `use_new_show_route: true`
2. **route map** — `assets/javascripts/discourse/admin-indexnow-route-map.js`，
   注册子路由并显式指定 `path`
3. **nav initializer** —
   `assets/javascripts/initializers/indexnow-admin-plugin-configuration-nav.js`
4. **admin 前端文件路径** — controller / route / template 必须放在
   `admin/assets/javascripts/discourse/` 下

### AI 容易犯的错

- 只改了 `plugin.rb` 加 `use_new_show_route: true`，但没有同步 route map
  和 nav initializer，导致 `urlFor` 找不到路由 → "Unable to configure link"
- 以为 route map 是可选的，实际上它是 Ember 路由注册的必要文件

## 2. route map 的 `path` 不能省

### 现象

route map 写成 `this.route("discourse-indexnow")`（不带 `path`），导致
实际 URL 变成 `/admin/plugins/discourse-indexnow/discourse-indexnow`
（双重嵌套），与侧栏链接 `/admin/plugins/discourse-indexnow` 不匹配。

### 根因

Ember Router 默认用路由名作为 URL path segment。在 `adminPlugins.show`
（path 为 `/plugins/:plugin_id`）下注册子路由时，如果不显式指定 `path`，
Ember 会生成 `/plugins/:plugin_id/discourse-indexnow`，而不是
`/plugins/:plugin_id`。

侧栏链接指向 `/admin/plugins/discourse-indexnow`（即 `show` 路由本身），
所以子路由必须挂在一个子路径上（如 `logs`）。

### 正确做法

```js
this.route("discourse-indexnow", { path: "logs" });
// 生成的 URL: /admin/plugins/discourse-indexnow/logs
```

参考 Discourse 核心插件 gamification 的 route map：所有子路由都显式指定
`path`（如 `{ path: "leaderboards" }`）。

### AI 容易犯的错

- 照搬旧模式的 `this.route("discourse-indexnow")`（旧模式下路由名即路径，
  新模式下必须显式指定子路径）
- 忽略 Discourse 核心的 `admin-route-map.js`（第 434-443 行）已经定义了
  `adminPlugins.show` 下的 `settings` 子路由，插件 route map 是往这个
  嵌套结构里追加子路由

## 3. admin 前端文件路径：`admin/` vs `assets/javascripts/`

### 现象

controller / route / template 放错目录，Discourse 的 admin asset 管道
找不到文件，页面空白或报找不到模块。

### 正确做法

`use_new_show_route` 模式下，admin 专用的 controller / route / template
放在 **`admin/assets/javascripts/discourse/`** 下：

```text
admin/assets/javascripts/discourse/
  controllers/admin-plugins/show/discourse-indexnow.js
  routes/admin-plugins/show/discourse-indexnow.js
  templates/admin-plugins/show/discourse-indexnow.gjs
```

而 route map 和 initializers 放在 **`assets/javascripts/discourse/`** 下
（不加 `admin/` 前缀）：

```text
assets/javascripts/discourse/
  admin-indexnow-route-map.js
  initializers/indexnow-admin-plugin-configuration-nav.js
```

命名约定遵循 `admin-plugins/show/{plugin-id}`，对应 Ember 路由
`adminPlugins.show.{plugin-id}`。

### v1 的旧结构（已废弃）

```text
assets/javascripts/discourse/
  controllers/admin-plugins-discourse-indexnow-index.js
  routes/admin-plugins-discourse-indexnow-index.js
  templates/admin/plugins-discourse-indexnow-index.gjs
```

### AI 容易犯的错

- 在新路由模式下仍把 admin 文件放在 `assets/javascripts/discourse/` 下
- 文件命名不符合 `admin-plugins/show/{plugin-id}` 约定，导致 Ember
  解析不到对应的 controller / route / template

## 4. nav initializer 是必须的

### 现象

配置页的 tab 标签显示为原始键名 `[en.discourse_index_now.admin.logs]`，
或者根本没有 tab。

### 根因

`use_new_show_route` 模式下，Discourse 用
`api.addAdminPluginConfigurationNav(pluginId, links)` 来注册配置页的 tab。
如果没有这个 initializer，配置页就没有导航 tab。

`addAdminPluginConfigurationNav` 定义在
`frontend/discourse/app/lib/plugin-api.gjs` 第 3506 行。

### 正确做法

```js
import { withPluginApi } from "discourse/lib/plugin-api";

const PLUGIN_ID = "discourse-indexnow";

export default {
  name: "indexnow-admin-plugin-configuration-nav",
  initialize(container) {
    const currentUser = container.lookup("service:current-user");
    if (!currentUser?.admin) {
      return;
    }
    withPluginApi((api) => {
      api.addAdminPluginConfigurationNav(PLUGIN_ID, [
        {
          label: "discourse_index_now.admin.logs",
          route: "adminPlugins.show.discourse-indexnow",
        },
      ]);
    });
  },
};
```

### 注意事项

- `route` 必须是完整的 Ember 路由名：`adminPlugins.show.{child-route-name}`，
  与 route map 中注册的路由名一致
- `label` 必须有对应的 YAML 翻译键
- 参考所有官方插件的同名 initializer，模式一致

### AI 容易犯的错

- 不知道 `use_new_show_route` 模式需要 nav initializer（旧模式不需要）
- `route` 写成 `adminPlugins.discourse-indexnow`（少了 `.show`）
- 忘记检查 `currentUser?.admin`

## 5. YAML 翻译键的三个陷阱

### 5.1 `yes` / `no` 键被解析为布尔值

YAML 1.1 会把裸键 `yes:` / `no:` 解析为布尔 `true` / `false`，而不是字符串键。
这会导致 `i18n "discourse_index_now.admin.yes"` 返回原始键名。

**正确做法**：给键加引号：

```yaml
"yes": "Yes"
"no": "No"
```

### 5.2 nav initializer 引用的 label 键必须存在

v1 曾缺少 `logs` 翻译键。每次在 nav initializer 或模板里引用一个新的
`i18n` 键，必须同时在 `client.en.yml` 和 `client.zh_CN.yml` 中添加。

### 5.3 client vs server locale

admin 前端文案放在 `config/locales/client.{en,zh_CN}.yml` 的
`js.discourse_index_now.admin` 下。site setting 文案放在
`config/locales/server.{en,zh_CN}.yml`。不要混放。

### AI 容易犯的错

- 忘记给 `yes` / `no` 加引号（YAML 1.1 布尔陷阱）
- 在 initializer / 模板里引用了新键但忘记在 YAML 里添加
- 只改了英文 YAML 忘记改中文

## 6. 弃用的 `boundDate` helper

### 现象

admin 页面顶部出现 Discourse 弃用警告："One of your themes or plugins
contains code which needs updating"。

### 根因

`boundDate`（来自 `discourse/helpers/bound-date`）自 Discourse 3.5.0
起弃用，弃用 ID 为 `discourse.bound-date`。

### 正确做法

用 `dAgeWithTooltip`（来自 `discourse/ui-kit/helpers/d-age-with-tooltip`）替代，
API 相同：

```gjs
import dAgeWithTooltip from "discourse/ui-kit/helpers/d-age-with-tooltip";
// ...
<td>{{dAgeWithTooltip log.created_at}}</td>
```

### AI 容易犯的错

- 从旧 Discourse 文档或旧插件代码里复制 `boundDate`，不知道已弃用
- 没有检查目标 Discourse 版本对应的弃用列表

## 7. 本地测试的限制

### IndexNow API 拒绝 localhost URL

本地开发环境中 `topic.url` 返回 `http://localhost:3000/t/...`，
IndexNow API 会返回 HTTP 429（拒绝）。

**这不是 bug**：429 响应证明完整管线工作正常：
事件监听 → 资格检查 → debounce → Sidekiq job → HTTP POST → 日志记录。

要验证成功提交（200），需要真实公网域名和有效的 key。

### Chrome ad-blocker 干扰

Chrome 扩展（ad-blocker）可能间歇性拦截 `127.0.0.1` 的 admin URL，
报 `ERR_BLOCKED_BY_CLIENT`。这与插件的 broken route 错误无关，是浏览器
层面的干扰。调试时建议在无扩展的隐身窗口中测试。

## 8. 开发环境操作速查

### 环境

- Discourse 源码：`/home/bobo/Documents/Codex/2026-08-21/ni-h/work/discourse/`
- 插件目录：`work/discourse/plugins/discourse-indexnow/`
- Docker 容器：`discourse_dev`，运行在 `http://127.0.0.1:3000`
- GitHub：`imlotso/discourse-indexnow`，分支 `main`

### 运行 RSpec

```sh
sudo docker exec -u discourse:discourse -w /src \
  -e CI -e RAILS_ENV -e NO_EMBER_CLI -e QUNIT_RAILS_ENV \
  discourse_dev bin/rspec plugins/discourse-indexnow/spec
```

v1 结果：37 examples, 0 failures。

### 修改 YAML / JS 后重启 Pitchfork

改 locale 文件或 JS initializer 后需要重启 Rails 服务器：

```sh
sudo docker exec discourse_dev bash -lc "pkill -USR2 -f 'ruby /src/bin/pitchfork'"
```

等待约 8 秒让 worker 重新生成。

### CI

`.github/workflows/discourse-plugin.yml` 使用 Discourse 官方插件 CI：

```yaml
uses: discourse/.github/.github/workflows/discourse-plugin.yml@v1
```

每次 push 到 `main` 和 pull request 时运行。

## 9. v2 开发前的检查清单

在动任何 admin 前端代码之前，先确认以下文件存在且内容正确：

1. `plugin.rb` 中 `add_admin_route` 带了 `use_new_show_route: true`
2. `assets/javascripts/discourse/{plugin-id}-route-map.js` 存在，`resource`
   为 `"admin.adminPlugins.show"`，`path` 为 `"/plugins"`，子路由有显式 `path`
3. `assets/javascripts/initializers/{plugin-id}-admin-plugin-configuration-nav.js`
   存在，调用了 `api.addAdminPluginConfigurationNav`
4. `admin/assets/javascripts/discourse/{controllers,routes,templates}/admin-plugins/show/{plugin-id}.{js,gjs}`
   存在且命名正确
5. 所有 `i18n` 引用的键在 `client.en.yml` 和 `client.zh_CN.yml` 中都有对应条目
6. `yes` / `no` 等 YAML 保留词键已加引号
7. 没有使用 `boundDate`，改用 `dAgeWithTooltip`
8. 运行 RSpec 全部通过
9. 在浏览器（隐身窗口）中打开 `/admin/plugins`，确认无 "Unable to configure
   link" 提示，且能进入插件配置页

## 10. 参考文件

### 本插件

| 文件 | 作用 |
| --- | --- |
| `plugin.rb` | 插件入口，`add_admin_route` 在此声明 |
| `assets/javascripts/discourse/admin-indexnow-route-map.js` | Ember 路由注册 |
| `assets/javascripts/initializers/indexnow-admin-plugin-configuration-nav.js` | 配置页 tab 注册 |
| `admin/assets/javascripts/discourse/controllers/admin-plugins/show/discourse-indexnow.js` | admin 控制器 |
| `admin/assets/javascripts/discourse/routes/admin-plugins/show/discourse-indexnow.js` | admin 路由 |
| `admin/assets/javascripts/discourse/templates/admin-plugins/show/discourse-indexnow.gjs` | admin 模板 |
| `config/locales/client.en.yml` / `client.zh_CN.yml` | 前端文案 |
| `config/routes.rb` | Rails 路由（admin API + key 验证） |
| `config/settings.yml` | site settings 定义 |
| `app/controllers/discourse_index_now/admin_logs_controller.rb` | 日志 API |
| `app/controllers/discourse_index_now/key_controller.rb` | key 验证端点 |
| `app/jobs/discourse_index_now/submit_batch.rb` | Sidekiq 批量提交任务 |
| `lib/discourse_index_now/client.rb` | IndexNow HTTP 客户端 |
| `lib/discourse_index_now/eligibility.rb` | 资格检查 |
| `lib/discourse_index_now/submission_service.rb` | 提交服务（事件入口） |

### Discourse 核心（用于理解机制）

| 文件 | 关键行 | 作用 |
| --- | --- | --- |
| `lib/plugin/instance.rb` | 131-154 | `add_admin_route` + `full_admin_route` 生成 |
| `frontend/discourse/app/lib/admin-utilities.js` | 1-12 | `adminRouteValid` 路由校验 |
| `frontend/discourse/admin/controllers/admin-plugins.js` | 9-26 | `brokenAdminRoutes` getter |
| `frontend/discourse/admin/routes/admin-route-map.js` | 434-443 | `adminPlugins.show` 核心路由定义 |
| `frontend/discourse/app/lib/plugin-api.gjs` | 3506-3514 | `addAdminPluginConfigurationNav` API |

### 参考插件（同类实现）

- `plugins/discourse-gamification/` — route map + nav initializer 的标准范例
- `plugins/discourse-ai/` — 多子路由的复杂范例
- `plugins/automation/` — 简单单路由范例

## 11. V2 生产环境补充事项

- Key 轮换策略：生成新 key 后旧 key 立即失效，`key.txt` 只接受当前
  `SiteSetting.indexnow_api_key`，不再使用 PluginStore 保存过渡期状态。
- 限流策略：`SubmitBatch` 会按当前 Redis 计数器的剩余容量提交一批 URL；
  如果 backfill 的逻辑批次超过当前容量，先提交能容纳的部分，剩余 pending
  记录由同一个 job 在下一个限额窗口继续处理。
- 兜底任务：`Jobs::DiscourseIndexNow::RecoverStalledLogs` 每 5 分钟运行，
  重新派发创建超过 30 分钟仍 pending 且具有 batch_id 的日志批次，避免
  Sidekiq 丢 job 时记录永久悬空。
