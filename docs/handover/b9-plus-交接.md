# b9 收尾出包：1.12-b9-plus 交接（2026-11-15 01:50）

## 包

| 项 | 值 |
|---|---|
| 文件 | `/sdcard/Download/DSH-Go/DSH-Go-1.12-b9-plus-arm64.apk` |
| 大小 | 427,576,224 字节（约 408 MiB） |
| sha256 | `66325a0183db9cc570df356afbea5e3d65f6d51ffabb24f1a65684514c4a567c` |
| 提交 | `15040784`（main） |
| 标签 | `apk-b9-plus` |
| 构建 | GitHub Actions run `15040784`，run id 43617232191，arm64，19 分钟 |

校验过：`zip test` 正常；`libapp.so` 含 `host.req` / `pluginFiles` / `sessionText` / `mcp__phone__` / 中文新文案（UTF-16）；
rootfs（`assets/runtime/rootfs-arm64-v8a.tar.xz`）里 `opt/dsh-go/dsh-go-bridge/` 是 **0.5.0**，含 `lib/native/host-runtime.js`
和新的 `lib/native/routes.js`；`AssetManifest.bin` 在。

## CI 结论（这一提交）

- `Flutter 0` 的 analyze：**No issues found!**（日志第 598 行）
- `Android JVM`：**success**
- 仍是红的（既有问题，动工前就这样，不是这次引入）：
  - `Python tooling`：上一个提交同样失败
  - `Runtime and bridge`：`native-cancel-rejection.test.mjs` 的 12 个警告计数断言，在基线代码上本地复现同样失败
  - `Flutter 0` 整个 job 因既有 golden 测试失败而红，与 analyze 无关

## 这次改了什么

### 线一：8 个 bug

| # | 改动 | 怎么验 |
|---|---|---|
| P1-2 | 订阅/粘贴两条路径统一 `sanitizeClashConfig`：按行解析顶层键，受管键整段丢弃后在最前面写一份，CRLF 也处理；失败时日志带生成配置前 15 行 | 用一个带 `mode: global`、`log-level: info`、`mixed-port` 的订阅：能起，内核日志无 duplicate key |
| P1-3 | 启动前 `bind` 探测端口（reuseAddress，TIME_WAIT 不算占用）；20 秒超时后再探一次：被占 → `port_in_use` + 「请换端口」；停止后等端口释放 | 先占住 7890 再开：文案准确；换端口能起；停止后端口释放 |
| P2-4 | 开关点了立刻「启动中…」并禁用；失败保留「启动失败：原因」，不回滚成「已停止」；内核缺失时也可点（给原因） | 1 秒内出现启动中；失败原因留在页面上 |
| P1-1 | 上传后 200ms×10 轮询**本次 ref** 的 `input.files`，页面换输入框也算成功；返回 `files` 数 | 传 PDF 到有 file input 的页面：回 `ok:true, files:1` |
| P2-5 | `kb_import` 先判扩展名：不支持直接 `unsupported_type`，**不复制**；文案列出支持的格式 | 导入 PDF：失败且知识库目录不变 |
| P3-8 | 空命中分两种：没文档 → 引导放文件；有文档没命中 → 「没有找到包含「词」的文档（当前 N 文档 M 块）」 | 有 1 篇文档时搜不存在的词 |
| P2-6 | 切标签失败保留原标签并回 `switch_failed`（含 tabs）；不可加载的地址先拒绝 | 切到非法地址：标签列表不变 |
| P3-7 | `finalUrl` 取当前 WebView 的 `currentUrl()`，不是共享的旧值 | `open` 后 `finalUrl` 与 `location.href` 一致 |

顺带（测试报告里剩下没修的）：`kb_import` 按 sha1 去重（`duplicate`）；爬虫 URL 规范化（`https://host` 与 `https://host/`、结尾斜杠视为同一页，
老 `web.json` 读入时迁移 key）；爬虫整轮抓完后统一写盘（中止不留半套），`pages` 里也记 skipped 的 URL；
WebDAV 搜索路径相对账号根（与 `ls` 一致）且只按名字匹配；截图按规范化 URL 找 WebView，找不到画面报 `browser_not_visible`；
关标签不等整页加载（不再超时）；snapshot 到 40 条上限会带 `truncated` 和提示。

### 线二：插件 v1.4 宿主能力

8 项：`sessionText` `selection` `send` `notify` `phone` `tools` `schedule` `pluginFiles`（不叫 `files`，那个是 v1.3 选文件）。

- 桥接：`lib/native/host-runtime.js`（`host.req`/`host.res` 往返、超时、断流清理、`tools` 走引擎执行器、`phone` 只许 `mcp__phone__*`、
  `pluginFiles` 路径沙箱）；`routes.js` 用 `AsyncLocalStorage` 把点按的流/会话交给 `ctx.dshGo.capability()`；协议文档 §13；桥接 0.5.0
- App：`native_host_api.dart`（按插件授权 `plugin:<包>:<能力>`、`phone`/`tools` 每次确认、插件权限总闸、会话文字截断、通知、填输入框、建定时任务）、
  `NativeSelectionStore`（消息「选择文字」写入）、能力发现把声明的能力放进 `features`、授权记录页显示「插件能力」、`插件权限` 从「尚未接入」变为真开关
- 测试：桥接 `runtime/tests/native-host-capabilities.test.mjs` 12 个用例全过；`dsh_client` analyze + 测试全过；
  `app/test/plugins/native/native_host_api_test.dart`；本地 `dart analyze` → No issues found

插件作者用法（文档 §13.2）：

```js
const { text } = await ctx.dshGo.capability('sessionText', { limit: 8000 });
await ctx.dshGo.capability('send', { text: '草稿' });      // 只填框
await ctx.dshGo.capability('tools', { tool: 'web_search', args: { queries: ['x'] } });
```

## 真机要测的（按优先级）

1. 内置代理：导入带 `mode`/`log-level` 的订阅 → 能起；换端口；端口被占时的文案；开关反馈
2. 上传：PDF/图片到有文件框的页面 → 一次成功，不重试
3. 知识库：导入 PDF 失败不落盘；同一文件导两次提示已有；同一网页抓两次不生成副本；抓取中途超时不留半成品
4. 云盘：搜索结果路径能直接给 `ls`/`download`；单字母搜索只命中名字
5. 浏览器：`open("https://example.com")` 后截图；关标签；40+ 元素页面的 snapshot
6. 插件能力（需要示例插件）：`sessionText` 填框、通知、`selection`、`phone` 每次确认、`tools` 每次确认、`pluginFiles` 读写

## 没做/边界

- `tools` 依赖引擎 `tools.execute`；没有执行器的主机回 `unsupported`
- `schedule` 走引擎 `schedule/create`；老主机没有这个 Remote 时回 `failed`
- relay 中转主机不提供 `/dsh-go/*`，这些能力不可用
- 手机操控的每个工具调用仍受现有无障碍/权限与 App 内确认约束
- 授权记录里的插件授权在关掉「插件权限」时自动失效

## 复测第二轮（2026-11-15 07:20 报告）修了什么

| # | 现象 | 根因 | 改法 |
|---|---|---|---|
| 1 | 点代理开关永远不显示「开」，日志 `duplicate key "mode"` | 开关走 `start()`，直接启动内核，**不重写磁盘上旧版本写下的配置**；只有「导入并启动」会 sanitize | Kotlin 加 `readConfig`；每次 `start` 前读回配置、过同一个 sanitize、不一致就写回（幂等）。老配置点一次开关就修好；仍失败时文案直说「重复的 mode/log-level，点导入并启动」 |
| 2 | 上传对真实 input 返回 `files:0`，注入的 input 也失败 | 页面常在 change 处理器里把 File 读走并**当场清空** `input.files`；只在事后轮询就永远看到 0 | 填完立即同步回读：`assigned`（赋值后）与 `cleared`（赋值→清空）都算页面已接收；轮询也认「文件被移到页面上另一个 file input」；失败结果带 `assigned/visible/url` 供下次定位 |
| 3 | 云盘 search 单字母命中中文目录 | `Uri.path` 保留 percent 编码，取末段得到 `%E8%A7%84…`，`a` 命中编码里的十六进制 | 先 `Uri.decodeFull(path)` 再取名字/路径；回归用例：名字不含 a、编码含 a |
| 4 | 打不开的站点返回 `ok:true`、`loading` 一直 true | `open` 等 10 秒没完成就照样返回 finalUrl | 记录 `lastLoadTimedOut`，完成挂起的 loading，`/open` 返回 `load_timeout` 并说明「可能还是空白页」 |
| 5 | 点「百度一下」后立刻读 state 还是旧页 | `click` 返回时导航尚未开始 | `click` 后最多等 1.2 秒看 url/loading 变化，再返回 `url/loading/tabs` |
| 6 | `kb_read` 文档不存在说「没有这个块」 | 文案没区分文档与块 | 先查文档是否存在：不存在说「知识库里没有这个文档」，存在才是块序号问题 |
| 7 | `web_crawl` 传 `ftp://` 仍 `ok:true` | 路由固定 `ok:true` | `ok: fetched > 0`；一页没抓到就是失败 |

另外同一批：

- 插件技能文档补「宿主能力（v1.4）」并 `sync-skill.mjs` 同步
- 修两个既有红 CI：`test_input_store.py` 写死 `proot-v5.1.107.98.zip`（已升到 `.102`）→ 按 `PROOT_VERSION` 取键；
  `native-cancel-rejection` 的假 `inject` 无条件执行导致 5 条启动告警 → 改为依赖存在才执行，12 例全过
