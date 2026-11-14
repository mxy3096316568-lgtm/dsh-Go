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
