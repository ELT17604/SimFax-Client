<p align="center"><img src="Brand/logo.png" width="128" alt="SimuFax logo"></p>

# SimuFax for macOS

原生 SwiftUI 传真投递客户端。支持 macOS 14+；macOS 26+ 使用系统 Liquid Glass，旧版回退系统材质。无第三方运行依赖。

## 下载与使用

编译产物集中放在 `release/`：

- `SimuFax.app`：可复制到“应用程序”后启动。
- `SimuFax-macOS-arm64.zip`：Apple Silicon 版本的应用压缩包。

在设置中保存管理员提供的 Bearer Key；密钥仅保存到 macOS 钥匙串。选择或拖入文件、填写信息并确认提交。任务历史展示等待、打印、完成及失败状态。发送可能触发实际打印。

## 悬浮网络控制台

点击工具栏“控制台”、侧边栏“请求与响应”，或按 **⌘⇧D**。窗口浮在应用上方，可调整大小和关闭后再次召唤。

| 标签 | 内容 |
| --- | --- |
| 命令 | 等价 cURL 命令，便于理解请求；应用实际通过 URLSession 执行 HTTP，不调用 Shell |
| 请求 RAW | 请求方法、地址、已配置的报头、实际 multipart 文本字段和边界；文件二进制用字节数占位 |
| 返回值 RAW | HTTP 状态、返回报头和正文；关闭“格式化 JSON”可查看未排版正文 |

可以切换历史记录、复制当前内容、格式化 JSON、清空记录。认证报头、密钥和 Cookie 会隐藏。命令中的文件路径是占位路径，需要手动替换。诊断不是抓包：不包括系统自动补充的所有传输层报头，也不是完整二进制流。正文以 UTF-8 展示，单条响应最多显示 256 KiB；最多在内存保留 100 条记录，退出后不保存。正文可能含投递信息，复制后请自行选择分享范围。

## 构建

需要 macOS 和包含 SwiftUI / Liquid Glass SDK 的 Xcode 26+ 或相应 Command Line Tools。

```sh
./scripts/build.sh
./scripts/test.sh
```

脚本在项目 `.build/` 中保存缓存，在 `release/` 生成 App 并进行本地 ad-hoc 签名。默认编译当前 CPU 架构；`ARCH=x86_64 ./scripts/build.sh` 可构建 Intel 版本（本交付只验证 arm64）。可使用 Xcode 打开 `SimuFax.xcodeproj`，选择 SimuFax / My Mac 后运行。

本地签名不是 Developer ID 签名，当前发布包未公证。公开分发前请使用自己的开发者身份完成签名和公证。

## 接口支持范围

严格依据 `Docs/` 内用户提供的两份原始文档：

- `POST /api/v1/fax`：multipart 文件、发件人、收件人、主题、附言、SHA-256、幂等 ID、上传进度。
- `GET /api/v1/fax/{id}`：按编号查询；运行期间每 15 秒轮询 pending/printing 任务。
- `GET /api/v1/health`：无需密钥的健康检查，由用户手动触发。

API 地址为 `https://fax.verstappen.uk`。使用默认 TLS 校验并禁止自动跟随 HTTP 重定向。没有远程取消、删除、文件下载、全站历史或打印机选择接口。收件人是自由文本。HTTP 200/202 表示接收，不等于打印完成。

## 重试与本地数据

超时或连接失败后保留当前幂等 ID，不会自动重新提交文件。重试时保持文件、密钥及字段不变；重新选文件会产生新 ID。草稿和 ID 不跨重启保存，结果不明时请先复制 ID 并向管理员确认。429 的整数秒 Retry-After 会阻止提前重试，其他错误展示 HTTP 状态和服务器错误。

本地历史在 `~/Library/Application Support/SimuFax/history.json`，包含编号、文件名、主题和状态，不含文件内容或密钥。查询旧任务需要原密钥。上传体在内存构建，大文件会占用较多内存。PDF 页数只在本地展示，不向服务端声明页数；服务器配置决定大小及页数上限。

## 项目结构

```text
Sources/                  SwiftUI 界面、API 客户端、Keychain、诊断控制台
SimuFax.xcodeproj/         Xcode 工程
Package.swift             Swift Package 清单
Tests/                    诊断记录的离线检查
scripts/                  构建、测试脚本
Docs/                     原始 API 文档
release/                  已编译 App 和 App 压缩包
.github/workflows/        macOS 构建检查
```

验证结果见 `VALIDATION.md`。本项目尚未配置 App Sandbox。

## Logo 与应用图标

`Brand/` 包含透明 PNG、macOS `.icns`、多尺寸 `.ico` 和 iconset。工程与构建脚本已绑定图标。内置 imagegen 生成，完整提示词见 `Brand/DESIGN.md`。
