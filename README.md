# OpenCopyLive

OpenCopyLive 是一套面向 Windows 的直播辅助与弹幕展示项目，仓库同时包含 Flutter 桌面客户端、FastAPI 授权服务端和 React 管理后台。

> 当前客户端内部仍保留部分 `kmxzs` / `KMXZS_*` 兼容标识，修改这些标识会影响配置、升级和服务端通信，请不要仅为改名而直接替换。

## 主要功能

- 解析抖音、快手、哔哩哔哩、斗鱼、虎牙、TikTok、小红书和 YouTube 等直播地址。
- 通过 OBS WebSocket 自动创建或更新直播媒体源，并启动虚拟摄像机。
- 获取并展示抖音、快手和哔哩哔哩文字弹幕。
- 支持抖音直播间随机轮播、OBS 顶层叠加和播放状态监测。
- 支持直播伴侣启动、断流检测及自动关播辅助。
- 提供卡密授权、设备绑定、版本发布、渠道和代理管理。

## 仓库结构

| 目录 | 内容 |
| --- | --- |
| `lib/` | Flutter Windows 客户端及直播、弹幕、OBS 逻辑 |
| `windows/` | Windows Runner 与原生集成 |
| `server/` | FastAPI、SQLAlchemy、Alembic、Caddy 与 Docker 部署配置 |
| `admin-web/` | React、TypeScript、Vite、Ant Design 管理后台 |
| `installer/` | Windows Release 与 Inno Setup 安装包脚本 |
| `test/` | Flutter/Dart 自动化测试 |
| `tool/` | 断流测试、直播诊断和视频相似度实验工具 |

## 环境要求

### Windows 客户端

- Flutter stable 与 Dart 3.3 或更高版本
- Visual Studio 2022，安装“使用 C++ 的桌面开发”组件
- OBS Studio 28 或更高版本，并启用 OBS WebSocket
- 需要快手网页登录时，系统应安装 Microsoft Edge WebView2 Runtime

### 服务端与管理后台

- Docker 与 Docker Compose，或 Python 3.12
- Node.js 20（构建 `admin-web` 时需要）

## 快速开始

### 运行客户端

```powershell
git clone https://github.com/OpenPromise/OpenCopyLive.git
cd OpenCopyLive
flutter pub get
flutter test
flutter run -d windows
```

OBS WebSocket 默认地址为 `ws://127.0.0.1:4455`，可在客户端高级设置中调整。

### 启动本地服务端

```powershell
cd server
docker compose -f docker-compose.dev.yml up -d --build
```

开发服务默认监听 `http://127.0.0.1:18088`。Ubuntu 生产部署、HTTPS、自签证书、数据库迁移和密钥配置请参阅 [`server/README.md`](server/README.md)。

### 启动管理后台

```powershell
cd admin-web
npm ci
npm run dev
```

开发页面默认位于 `http://localhost:5173/panel/`，API 请求代理到本地 FastAPI 服务。

## 构建 Windows 安装包

1. 将 `installer/secrets.ps1.example` 复制为 `installer/secrets.ps1`。
2. 在本地填写 API 地址、API 密钥、证书指纹、更新公钥和版本号。
3. 安装 Inno Setup 6 后执行：

```powershell
powershell -ExecutionPolicy Bypass -File installer/build_installer.ps1
```

`installer/secrets.ps1`、服务器 `.env`、证书私钥、构建目录和安装包目录均不应提交到 Git。

## 测试

```powershell
flutter analyze --no-fatal-infos
flutter test

cd server
python -m pytest tests -q

cd ../admin-web
npm ci
npm run build
```

GitHub Actions 会根据改动目录分别执行客户端检查、服务端测试和管理后台构建。

## 安全与使用说明

- 不要将生产密钥、Cookie、账号信息、证书私钥或真实 `.env` 提交到仓库。
- 直播平台页面和接口可能随时变化，相关功能需要持续维护。
- 使用直播解析、弹幕和自动化功能时，请遵守当地法律、直播平台规则及内容授权要求。
- 本仓库暂未附带开源许可证；使用、修改或分发前请先确认授权范围。
