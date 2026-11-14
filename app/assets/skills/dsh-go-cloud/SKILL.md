---
# dsh-go:managed — 删除这一行后，DSH App 不再覆盖本文件
name: dsh-go-cloud
description: 用户提到云盘、网盘、坚果云、Nextcloud、NAS、备份文件、上传到云、从云上下载时使用。账号在 App 里，工具直接读写用户的 WebDAV 空间。
---

# 用云盘（WebDAV）

用户在 App 的 设置 → 帮助与关于 → 能力控制 → 云盘 里填过地址、账号和密码。
密码存在系统钥匙串里，你看不到，也不需要知道；工具会替你带上。

| 工具 | 用途 |
|---|---|
| `webdav_ls` | 列一个目录（目录在前，带 name/path/dir/size/modified） |
| `webdav_upload` | 把手机上的文件传上去 |
| `webdav_download` | 把云上的文件下到 下载/DSH-Go/webdav |
| `webdav_search` | 按名字搜索（三层、最多 400 条） |

## 怎么用

1. 不确定去哪，先 `webdav_ls`（默认根目录），看清目录结构再动手。
2. 路径一律用云盘路径：`/` 是账号根目录，`/备份/2026/` 这样往下走。
3. 传文件：`webdav_upload(local="/sdcard/Download/report.pdf", remote="/备份/")`。
   `remote` 以 `/` 结尾表示目录（文件名沿用原名），否则当成完整文件路径。
4. 下文件：`webdav_download(remote="/备份/report.pdf")`，返回手机上的路径。
5. 找东西：`webdav_search(query="发票")`，拿到的 `path` 可直接给上面几个工具用。

## 分寸

- 浏览、搜索：直接做，不用问。
- 上传：文件离开手机，先跟用户说一句要传什么、传到哪；用户同意再传。
- 下载：会往手机上写文件，先说一句存到哪。
- 删除、覆盖：工具里没有删除；覆盖同名文件也要先说。
- 账号没设置时工具会返回 `denied`：把「去 设置 → 能力控制 → 云盘 填一下」告诉用户，不要自己猜地址或密码。

## 常见服务地址

| 服务 | 地址写法 |
|---|---|
| 坚果云 | `https://dav.jianguoyun.com/dav/`（密码要用「应用密码」） |
| Nextcloud | `https://你的域名/remote.php/dav/files/用户名/` |
| 群晖 NAS | `https://你的地址:5006/` 或 WebDAV Server 给出的地址 |

## 规矩

- 单文件上传上限 200MB，下载上限 2GB；超了就直接告诉用户。
- 路径里带中文没问题，但别自己拼特殊字符；用 `webdav_ls` 返回的 `path` 最稳。
- 连不上（`timeout`/`unsupported`）先别重试三次以上：让用户检查网络或代理。
