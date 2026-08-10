# fnOS Hermes Studio (FPK)

将 [EKKOLearnAI/hermes-studio](https://github.com/EKKOLearnAI/hermes-studio) 打包为飞牛 fnOS 可安装的 **FPK** 应用，保持原版 Web UI 模样，**不使用 Docker**，采用 **官方预构建产物 + bundled node_modules（npm 兜底）** 方式安装。

- 应用本体：`hermes-web-ui`（版本记录于 `config/bootstrap/hermes-studio-version.env`，CI 自动与官方 GitHub Release（[EKKOLearnAI/hermes-studio](https://github.com/EKKOLearnAI/hermes-studio)）对齐，取其预构建产物，比 npm 更及时）。FPK **默认包含** bundled 运行时 `app/node/`（含编译好的原生 node-pty），由 CI 下载官方预构建包解包生成；安装时 `install_callback` 直接离线复制到数据目录（几秒完成），**不再依赖 fnOS 联网编译**（fnOS 缺 gcc，此前正是安装卡死的根因）。
- 同时打包 **Hermes Agent 的 browser tools + TUI 依赖** 为 `app/hermes-agent-node/`，安装时直接复制到 Agent 目录并跳过后台 `npm install`，**首启不再长时间等待**。
- 包版本（迭代号）：记录于 `manifest`，并随每次上游更新发布到 GitHub Releases（如 `0.6.40-2`）。
- 平台：`x86_64`（bundled 原生模块绑定 Linux x64 / Node 24 ABI）
- 运行时依赖：`install_dep_apps=nodejs_v24`，由 fnOS 自动安装 Node.js v24
- 默认监听端口：`8648`（绑定 `0.0.0.0`，NAS 所在局域网可直接访问）

## 安装行为

1. `install_init`：清理残留进程。
2. `install_callback`：
   - 使用飞牛应用中心 Node.js v24 运行时（`manifest install_dep_apps=nodejs_v24` 自动安装）。
   - 优先把 FPK 内 bundled 的 `app/node/`（含原生 node-pty）复制到数据目录，无需联网，安装只需几秒。
   - 若 bundled node 缺失才回退 `npm install`（仅开发/测试场景，fnOS 缺 gcc 会失败）。
   - 若 FPK 内嵌 `app/hermes-agent-src/`，直接用它离线安装 Hermes Agent 后端，**跳过 git clone**（解决 NAS 无法连接 GitHub 导致启动不了的问题）。
   - **v0.6.33-21 起：安装前自动环境检查**——检测 Node.js、检查 `8648` 端口占用、杀掉占用进程及所有 Hermes 残留进程（`hermes-web-ui` / `hermes gateway` / `bridge` / `monitor` / `dashboard` / MCP 等）、清理 IPC socket / PID 文件、修复数据目录属主，避免旧版本残留导致 EACCES / EADDRINUSE 安装/启动失败。
   - **v0.6.33-25 起：Agent 的 browser tools + TUI 依赖预装进 FPK（`app/hermes-agent-node/`）且路径正确**。v0.6.33-24 虽打进了该目录，但打包脚本误把 CI 构建机绝对路径（`/home/runner/work/.../.agent-node-work`）一并带进包，致 `hermes-agent-node/node_modules` 根目录不存在、install_callback 静默回退到 `npm install`，等于没生效。v0.6.33-25 改用尾斜杠复制 + `realpath --relative-to` 计算相对路径并增加防御性拦截，CI 校验也改为硬性失败。安装时直接复制并跳过后台 `npm install`（官方 installer 默认 `NODE_DEPS_TIMEOUT=600s`，慢网会卡很久），首启大幅提速。
   - **v0.6.33-23 起：彻底修复"设置目录权限失败"安装报错**——FPK 后处理脚本会移除 `app.tgz` 内所有 npm 生成的软链（这些软链在打包后变成自引用/损坏，是 fnOS 解压时权限设置失败的直接原因），并重置所有条目 uid/gid 为 root、权限正规化为 755/644。install_callback 改为直接检测真实的 `.mjs` 入口，安装时自行重建 `bin/` 软链。`node_modules/` 内的有效软链（npm workspace / .bin 链接）保留，以保证 Agent 的 `@hermes/shared` 等依赖可解析。
   - **v0.6.33-22 起：修复"设置目录权限失败"安装报错（初步）**——打包前规范化 `app/` 权限/属主，install_callback 移除 `set -e` 并把 `chmod/chown` 全部改为最佳 effort。
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
│   ├── bootstrap/hermes-studio-version.env   # 安装的 hermes-web-ui 版本（0.6.40，跟踪官方 GitHub Release，auto-update 自动对齐）
│   └── bootstrap/hermes-agent-version.env    # 内嵌 Hermes Agent 的 release 标签（v2026.7.20，auto-update 自动对齐）
├── app/
│   ├── bin/hermes-web-ui            # 包装脚本（设置 Node/HERMES_WEB_UI_HOME 后调用官方 CLI）
│   ├── node/                        # bundled hermes-web-ui node_modules（安装时复制到 data/node）
│   ├── hermes-agent-src/            # Hermes Agent Python 后端源码（构建时下载，离线安装用）
│   └── ui/
│       ├── config                   # 桌面 .url 入口（端口 8648）
│       └── images/icon_{64,256}.png
├── wizard/
│   ├── install                      # 安装向导（含微信 DM 策略安全确认开关）
│   └── uninstall                    # 卸载时是否删除数据
├── preview/                         # 应用中心预览图
├── scripts/build-fpk.sh             # 本地纯 tar+gzip 构建（无需 fnpack）
└── .github/workflows/build.yml      # CI：push 到 main 自动构建并发布滚动 latest 预发布版本
```

## 仓库说明（与构建相关）

- `app/node/`（bundled 的 hermes-web-ui node_modules，含编译好的原生 node-pty）**不纳入 git**（见 `.gitignore`），因为体积大且 GitHub 拒绝 >100MB 文件。CI 在构建时由 `scripts/build-fpk.sh` 的 `ensure_node_bundle` 用 Node v24 + gcc/g++ npm install 并编译生成，FPK 安装时走离线复制，彻底摆脱 fnOS 缺 gcc 导致的安装卡死。
- `app/hermes-agent-src/`（Hermes Agent Python 后端源码）**不纳入 git**。`scripts/build-fpk.sh` 构建时会按 `config/bootstrap/hermes-agent-version.env` 记录的 **release 标签**从 GitHub 下载对应版本（不再拉 `main` 分支，保证构建可复现、与上游发版对齐；标签下载失败才回退 `main`）；CI 在 GitHub 内网下载并嵌入 FPK，使 NAS 安装时跳过 `git clone`（避免 GnuTLS recv error 等网络问题导致应用启动不了）。
- `dist/*.fpk`、根目录 `hermes-studio.fpk`、`fnpack.exe` 等构建产物同样不入库；正式发布包由 `.github/workflows/build.yml` 的 CI 自动产出。
- `scripts/` 下部分本地部署/调试脚本含 NAS 真实凭据，已被 `.gitignore` 排除，**请勿手动加入**。

## 自动构建（CI）

- **触发**：每次 `push` 到 `main`（也可手动 `workflow_dispatch` 并覆盖版本号）。
- **产物**：
  - 固定文件名 `fnos-hermes-studio.fpk`（始终为最新）→ 发布到滚动预发布 **Release `latest`**，每次 push 覆盖更新。
  - 带版本号 `fnos-hermes-studio_v<version>.fpk` → 留档，版本不同则累加。
- 下载：仓库 **Releases** 页 → `latest` 即可拿到最新 fpk（或按版本号取历史附件）。

## 自动更新上游版本

`.github/workflows/auto-update.yml` 会**每天自动检查上游版本**，有更新就自动发版，无需手动干预：

- **跟踪对象**：
  - `hermes-web-ui`（官方 GitHub Release：EKKOLearnAI/hermes-studio，0.6.x 线）：取最新版本标签，构建用其预构建产物 `hermes-web-ui-<ver>.tar.gz`。
  - `hermes-agent`（GitHub release：NousResearch/hermes-agent，日期版如 `v2026.8.3`）：取最新 release 标签。
- **动作**：任一与 `config/bootstrap/*.env` 中记录不一致时，更新 env 文件与 `manifest` 版本号，`commit` 并 `push` 到 `main` → 触发 `build.yml` 重新构建并发布新 FPK（自动发版）。
- **版本号规则**：web-ui 主版本变化则重置 build 计数为 1，否则 build+1（如 `0.6.33-25` → web-ui 升 `0.6.35` 得 `0.6.35-1`）。
- **手动触发**：在 GitHub Actions 页面手动运行 `Auto-update upstream versions` workflow（`workflow_dispatch`）可立即检查。
- **关闭自动更新**：删除/停用 `auto-update.yml` 即可恢复纯手动发版。

> 自动更新只改版本号与 env 文件，不动业务代码；构建仍在 `build.yml` 完成，发布前仍经过 Verify 校验。

## 本地构建 FPK

格式以飞牛官方文档为准：[developer.fnnas.com/docs/cli/fnpack](https://developer.fnnas.com/docs/cli/fnpack/)。`fnpack build` 会在生成 `.fpk` 前做文件与基础格式校验（manifest 必要字段、config JSON 合法、ICON 存在、`app/ cmd/ wizard/ app/{desktop_uidir}/` 存在）。

> 本地构建时 `scripts/build-fpk.sh` 优先从官方 GitHub Release 下载预构建的 `hermes-web-ui-<VER>.tar.gz` 解包进 `app/node/`（含已编译的 node-pty，无需本机编译）；下载失败时回退 `npm install -g hermes-web-ui@<HERMES_STUDIO_VERSION> --prefix app/node`（需本机有 Node v24 + gcc/g++ 以编译 node-pty）。两种方式皆会在打包前校验 `app/node/lib/node_modules/hermes-web-ui/bin/hermes-web-ui.mjs` 与 node-pty 编译产物，缺失则构建脚本报错中止（避免产出缺 bundled node 的残包）。

### 方式一：官方 fnpack（推荐，100% 合规）

从官方文档下载对应系统的 `fnpack`（Windows 用 `fnpack-1.2.3-windows-amd64`，放到仓库根目录或加入 PATH），然后：

```bash
cd fnos-hermes-studio
fnpack build                      # 生成 hermes-studio.fpk（项目根）
bash scripts/build-fpk.sh dist    # 自动探测并用 fnpack 构建，同时复制为 dist/fnos-hermes-studio_v0.6.35-2.fpk
```

`scripts/build-fpk.sh` 会优先调用 `fnpack` / `fnpack.exe`（含仓库根的 `fnpack.exe`），由官方工具产出；未找到 fnpack 时回退到方式二。

### 方式二：纯 tar+gzip 兜底（无 fnpack 时）

```bash
cd fnos-hermes-studio
bash scripts/build-fpk.sh dist    # 无 fnpack 时复刻官方双层 tar.gz 格式
# 产物：dist/fnos-hermes-studio_v0.6.35-2.fpk
```

脚本复刻官方 fnpack 的双层 tar.gz 格式：内层 `app.tgz`（app/ 目录）的 MD5 写入 `manifest.checksum`，外层再打包 `manifest / cmd / config / wizard / ICON / app.tgz`。经真实 `.fpk` 样本验证，结构与官方 `fnpack` 输出一致。

## 安装到飞牛 NAS

1. 飞牛桌面打开「应用中心」→ 右上角「设置」→「手动安装应用」。
2. 选择生成的 `fnos-hermes-studio_v0.6.35-2.fpk`，确认安装。
3. 安装向导会出现「微信渠道访问控制」步骤：
   - **默认关闭**：微信 DM 保持白名单模式（`WEIXIN_DM_POLICY=allowlist`），只有 Web UI「设置-渠道-微信」里手动添加的用户才能发消息。
   - **勾选开关**：允许所有微信用户发送消息，安装脚本会自动写入 `WEIXIN_DM_POLICY=open` 与 `WEIXIN_ALLOW_ALL_USERS=true` 到 `~/.hermes/.env`，无需再手动改配置。
4. 安装完成后桌面出现「Hermes Studio」图标，点击在浏览器打开。
