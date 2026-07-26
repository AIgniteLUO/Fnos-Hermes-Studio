# fnOS Hermes Studio (FPK)

将 [EKKOLearnAI/hermes-studio](https://github.com/EKKOLearnAI/hermes-studio) 打包为飞牛 fnOS 可安装的 **FPK** 应用，保持原版 Web UI 模样，**不使用 Docker**，采用 **npm 原生依赖 + bundled node_modules** 方式安装。

- 应用本体：`hermes-web-ui`（版本 `0.6.33`，已预装进 FPK 的 `app/node/`）
- 包版本（迭代号）：`0.6.33-17`
- 平台：`x86_64`（bundled 原生模块绑定 Linux x64 / Node 24 ABI）
- 运行时依赖：`install_dep_apps=nodejs_v24`，由 fnOS 自动安装 Node.js v24
- 参考打包格式：[iranee/fnos-hermes-agent](https://github.com/iranee/fnos-hermes-agent)
- 默认监听端口：`8648`（绑定 `0.0.0.0`，NAS 所在局域网可直接访问）

## 安装行为

1. `install_init`：清理残留进程。
2. `install_callback`：
   - 使用飞牛应用中心 Node.js v24 运行时（`manifest install_dep_apps=nodejs_v24` 自动安装）。
   - 优先把 FPK 内 bundled 的 `app/node/` 复制到数据目录，无需联网，安装只需几秒。
   - 若 bundled node 不存在，回退到 `npm install -g hermes-web-ui@0.6.33`。
   - 修复目录权限。
3. `cmd/main start`：调用 `hermes-web-ui start --port 8648`，由官方 CLI 自带的 daemon 机制后台运行，默认绑定 `0.0.0.0`。
4. 桌面图标通过 `app/ui/config` 的 `.url` 入口直接打开 `http://<NAS>:8648/`，即原版 Hermes Studio Web UI。
5. 首次登录：默认账号 `admin` / 密码 `123456`，随后在「设置」中配置模型 API Key。

所有用户数据（数据库、凭证、日志、上传、Node 运行时）保存在 `TRIM_PKGHOME/data`（即 `@apphome/hermes-studio/data`），升级时保留。

## 目录结构

```
fnos-hermes-studio/
├── manifest                         # 包元数据（version = 0.6.33-1，checksum 由构建脚本填充）
├── ICON.PNG / ICON_256.PNG          # 应用图标（hermes-studio 官方图标）
├── cmd/
│   ├── main                         # 生命周期：start / stop / status
│   ├── install_init / install_callback
│   ├── upgrade_init / upgrade_callback
│   ├── uninstall_init / uninstall_callback
│   └── config_init / config_callback
├── config/
│   ├── privilege                    # 以 package 身份运行（hermes-studio 用户）
│   ├── resource                     # 数据共享 + /usr/local/bin 链接
│   └── bootstrap/hermes-studio-version.env   # 安装的 npm 版本 0.6.33
├── app/
│   ├── bin/hermes-web-ui            # 包装脚本（设置 Node/HERMES_WEB_UI_HOME 后调用官方 CLI）
│   ├── node/                        # bundled hermes-web-ui node_modules（安装时复制到 data/node）
│   └── ui/
│       ├── config                   # 桌面 .url 入口（端口 8648）
│       └── images/icon_{64,256}.png
├── wizard/
│   ├── install                      # 安装向导说明
│   └── uninstall                    # 卸载时是否删除数据
├── preview/                         # 应用中心预览图
├── scripts/build-fpk.sh             # 本地纯 tar+gzip 构建（无需 fnpack）
└── .github/workflows/build.yml      # CI：push 到 main 自动构建并发布滚动 latest 预发布版本
```

## 仓库说明（与构建相关）

- `app/node/`（bundled 的 hermes-web-ui node_modules）**不纳入 git**（见 `.gitignore`），因为体积大且 GitHub 拒绝 >100MB 文件。CI 在构建前会按 `config/bootstrap/hermes-studio-version.env` 中的版本用 `npm install -g hermes-web-ui@<ver> --prefix app/node` 重新生成该目录，保证打出的 FPK 自带运行时、飞牛上离线安装。
- `dist/*.fpk`、根目录 `hermes-studio.fpk`、`fnpack.exe` 等构建产物同样不入库；正式发布包由 `.github/workflows/build.yml` 的 CI 自动产出。
- `scripts/` 下部分本地部署/调试脚本含 NAS 真实凭据，已被 `.gitignore` 排除，**请勿手动加入**。

## 自动构建（CI）

- **触发**：每次 `push` 到 `main`（也可手动 `workflow_dispatch` 并覆盖版本号）。
- **产物**：
  - 固定文件名 `fnos-hermes-studio.fpk`（始终为最新）→ 发布到滚动预发布 **Release `latest`**，每次 push 覆盖更新。
  - 带版本号 `fnos-hermes-studio_v<version>.fpk` → 留档，版本不同则累加。
- 下载：仓库 **Releases** 页 → `latest` 即可拿到最新 fpk（或按版本号取历史附件）。

## 本地构建 FPK

格式以飞牛官方文档为准：[developer.fnnas.com/docs/cli/fnpack](https://developer.fnnas.com/docs/cli/fnpack/)。`fnpack build` 会在生成 `.fpk` 前做文件与基础格式校验（manifest 必要字段、config JSON 合法、ICON 存在、`app/ cmd/ wizard/ app/{desktop_uidir}/` 存在）。

> 本地构建前需先准备 bundled 运行时（否则只能安装时联网 `npm install`）：
> ```bash
> npm install -g hermes-web-ui@0.6.33 --prefix app/node
> ```

### 方式一：官方 fnpack（推荐，100% 合规）

从官方文档下载对应系统的 `fnpack`（Windows 用 `fnpack-1.2.3-windows-amd64`，放到仓库根目录或加入 PATH），然后：

```bash
cd fnos-hermes-studio
fnpack build                      # 生成 hermes-studio.fpk（项目根）
bash scripts/build-fpk.sh dist    # 自动探测并用 fnpack 构建，同时复制为 dist/fnos-hermes-studio_v0.6.33-17.fpk
```

`scripts/build-fpk.sh` 会优先调用 `fnpack` / `fnpack.exe`（含仓库根的 `fnpack.exe`），由官方工具产出；未找到 fnpack 时回退到方式二。

### 方式二：纯 tar+gzip 兜底（无 fnpack 时）

```bash
cd fnos-hermes-studio
bash scripts/build-fpk.sh dist    # 无 fnpack 时复刻官方双层 tar.gz 格式
# 产物：dist/fnos-hermes-studio_v0.6.33-17.fpk
```

脚本复刻官方 fnpack 的双层 tar.gz 格式：内层 `app.tgz`（app/ 目录）的 MD5 写入 `manifest.checksum`，外层再打包 `manifest / cmd / config / wizard / ICON / app.tgz`。经真实 `.fpk` 样本验证，结构与官方 `fnpack` 输出一致。

## 安装到飞牛 NAS

1. 飞牛桌面打开「应用中心」→ 右上角「设置」→「手动安装应用」。
2. 选择生成的 `fnos-hermes-studio_v0.6.33-17.fpk`，确认安装。
3. 安装完成后桌面出现「Hermes Studio」图标，点击在浏览器打开。
