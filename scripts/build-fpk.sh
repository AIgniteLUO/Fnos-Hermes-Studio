#!/usr/bin/env bash
#
# 构建 hermes-studio 飞牛 fpk 安装包
#
# 用法：
#   bash scripts/build-fpk.sh            # 生成 hermes-studio.fpk（项目根目录）
#   bash scripts/build-fpk.sh dist       # 额外复制为 dist/fnos-hermes-studio_v<version>.fpk
#
# 构建方式（优先级）：
#   1. 官方 fnpack（推荐）：自动探测 fnpack / fnpack.exe（含仓库根目录的 fnpack.exe）。
#      由飞牛官方工具生成，格式 100% 合规，会做安装前文件/格式校验。
#   2. 纯 tar+gzip 兜底（无 fnpack 时）：复刻官方双层 tar.gz 格式，可复现，
#      在任意 Linux / macOS / Git Bash 均可运行，不依赖 fnpack。
#
set -e

APPNAME="hermes-studio"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT_DIR="${1:-.}"
mkdir -p "$OUT_DIR"

VERSION="$(grep '^version' manifest | awk -F'=' '{print $2}' | tr -d ' ')"
if [ -z "$VERSION" ]; then
    echo "无法从 manifest 读取 version" >&2
    exit 1
fi

# ── 准备 Hermes Agent 离线源码包（可选但强烈建议） ──
# 很多 NAS 无法稳定连接 GitHub，安装时 git clone 会失败，导致应用启动不了。
# 构建时把源码包嵌入 FPK，install_callback 会优先用它而跳过网络 clone。
# 该目录不入 git（见 .gitignore），每次构建时按需下载/复用。
ensure_hermes_agent_src() {
    local src_dir="$ROOT/app/hermes-agent-src"
    local marker="$src_dir/.offline-bundle"
    local tmp_tar="$ROOT/.hermes-agent.tar.gz"

    # 如果用户已手动放置源码包，直接复用
    if [ -d "$src_dir" ] && [ -f "$src_dir/pyproject.toml" ]; then
        if [ -f "$marker" ]; then
            echo "使用已缓存的 Hermes Agent 源码包: $src_dir"
        else
            echo "使用手动放置的 Hermes Agent 源码包: $src_dir"
        fi
        return 0
    fi

    echo "准备 Hermes Agent 离线源码包..."
    rm -rf "$src_dir" "$tmp_tar"
    mkdir -p "$src_dir"

    local url="https://api.github.com/repos/NousResearch/hermes-agent/tarball/main"
    local attempt=1
    local downloaded=false
    while [ $attempt -le 3 ]; do
        echo "  尝试 $attempt/3 下载 $url ..."
        if curl -fsSL --max-time 300 "$url" -o "$tmp_tar" 2>/dev/null; then
            downloaded=true
            break
        fi
        echo "  下载失败，重试..."
        attempt=$((attempt + 1))
        sleep 5
    done

    if [ "$downloaded" != "true" ]; then
        echo "WARNING: 无法下载 Hermes Agent 源码包（GitHub 网络问题）。"
        echo "  本次构建不会包含离线源码，NAS 安装时仍会尝试 git clone。"
        echo "  如需离线包，可手动把 hermes-agent 仓库放到 $src_dir 后再构建。"
        rm -rf "$src_dir" "$tmp_tar"
        return 0
    fi

    echo "  下载完成，解压中..."
    mkdir -p "$ROOT/.ha-extract"
    if ! tar -xzf "$tmp_tar" -C "$ROOT/.ha-extract" --strip-components=1 2>/dev/null; then
        echo "WARNING: 解压 Hermes Agent 源码包失败"
        rm -rf "$src_dir" "$tmp_tar" "$ROOT/.ha-extract"
        return 0
    fi

    # 移动到目标目录
    mv "$ROOT/.ha-extract"/* "$src_dir/" 2>/dev/null || true
    rm -rf "$ROOT/.ha-extract" "$tmp_tar"

    if [ ! -f "$src_dir/pyproject.toml" ]; then
        echo "WARNING: 源码包解压后未找到 pyproject.toml"
        rm -rf "$src_dir"
        return 0
    fi

    # 初始化为 git 仓库，让 install.sh 的离线模式识别
    (
        cd "$src_dir"
        git init -q 2>/dev/null || true
        git config user.email "build@local" 2>/dev/null || true
        git config user.name "FPK Builder" 2>/dev/null || true
        git add -A 2>/dev/null || true
        git commit -q -m "offline bundle" 2>/dev/null || true
    )

    touch "$marker"
    echo "Hermes Agent 离线源码包已准备: $src_dir"
}

ensure_hermes_agent_src

# ── 准备 bundled node（hermes-web-ui 预装 node_modules，含编译好的原生 node-pty） ──
# 根因：早期 FPK 未打进 app/node，install_callback 回退 npm install -g，而 fnOS 缺
# 少 gcc/g++ 无法编译 node-pty（原生模块），导致安装卡死/超时（UI 停在 ~55%）。
# 这里在 CI（Linux x64 + Node v24 + gcc/g++）上预装并编译，打包进 FPK，安装时
# install_callback 直接走 Path A（离线复制，几秒完成），彻底摆脱超时与网络依赖。
ensure_node_bundle() {
    local ver_file="$ROOT/config/bootstrap/hermes-studio-version.env"
    local ver="0.6.33"
    if [ -f "$ver_file" ]; then
        ver="$(grep -E '^HERMES_STUDIO_VERSION=' "$ver_file" | awk -F'=' '{print $2}' | tr -d ' ')"
        [ -z "$ver" ] && ver="0.6.33"
    fi

    local node_dir="$ROOT/app/node"
    local pkg_dir="$node_dir/lib/node_modules/hermes-web-ui"
    local bin_mjs="$pkg_dir/bin/hermes-web-ui.mjs"

    # 已存在则复用（本地增量构建 / 缓存）
    if [ -f "$bin_mjs" ] && [ -f "$pkg_dir/package.json" ]; then
        echo "使用已缓存的 bundled node: $node_dir (hermes-web-ui@$ver)"
    else
        echo "准备 bundled node（编译 hermes-web-ui@$ver 及其原生依赖）..."
        rm -rf "$node_dir"
        mkdir -p "$node_dir"

        # 必须存在 gcc/g++/make/python3，否则 node-pty 无法编译
        for t in gcc g++ make python3 node npm; do
            if ! command -v "$t" >/dev/null 2>&1; then
                echo "::error:: 构建 bundled node 缺少必需工具: $t" >&2
                exit 1
            fi
        done
        echo "node: $(node --version)  npm: $(npm --version)"

        # 关键：用 --prefix 把 hermes-web-ui 装成全局布局到 app/node，
        # 生成 app/node/bin/hermes-web-ui（软链）+ app/node/lib/node_modules/hermes-web-ui。
        # 若 Node v24 无预编译，npm 会回退 node-gyp 在此处（有 gcc）编译 node-pty。
        if ! npm install -g --no-audit --no-fund --prefix "$node_dir" "hermes-web-ui@${ver}"; then
            echo "::error:: npm install hermes-web-ui@${ver} 失败" >&2
            exit 1
        fi

        if [ ! -f "$bin_mjs" ]; then
            echo "::error:: bundled hermes-web-ui 入口缺失: $bin_mjs" >&2
            exit 1
        fi
    fi

    # 校验 node-pty 原生模块确实编译出来了（不是只下了 prebuilds/）
    local npty_dir="$pkg_dir/node_modules/node-pty"
    if [ -d "$npty_dir" ]; then
        local built
        built=$(ls "$npty_dir"/build/Release/*.node 2>/dev/null | head -1)
        if [ -z "$built" ]; then
            # 也许 node-pty 被 hoist 到更外层
            built=$(find "$node_dir/lib/node_modules" -path '*/node-pty/build/Release/*.node' 2>/dev/null | head -1)
        fi
        if [ -n "$built" ]; then
            echo "✅ node-pty 原生模块已编译: $built"
        else
            echo "::error:: 未找到 node-pty 编译产物（build/Release/*.node），bundled node 不完整，构建中止" >&2
            exit 1
        fi
    else
        echo "::error:: 未找到 node-pty 目录，bundled node 可能不完整，构建中止" >&2
        exit 1
    fi

    echo "bundled node 准备完成: $node_dir"
}

ensure_node_bundle

# ── 探测 fnpack ──
FNPACK=""
for cand in "$ROOT/fnpack.exe" "$ROOT/fnpack" fnpack fnpack.exe; do
    if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then
        FNPACK="$cand"
        break
    fi
done

if [ -n "$FNPACK" ]; then
    echo "使用官方 fnpack 构建：$FNPACK"
    "$FNPACK" build
    SRC_FPK="${APPNAME}.fpk"
    if [ ! -f "$SRC_FPK" ]; then
        echo "fnpack 未生成 $SRC_FPK" >&2
        exit 1
    fi

    # fnpack 某些版本/平台不会生成 manifest.checksum，但飞牛应用中心校验需要该文件。
    # 用 Python 跨平台地补充 manifest.checksum 并更新 manifest checksum 字段。
    if ! python3 -c "import tarfile, sys; sys.exit(0 if 'manifest.checksum' in [m.name for m in tarfile.open('${SRC_FPK}','r:gz').getmembers()] else 1)" 2>/dev/null; then
        echo "fnpack 未生成 manifest.checksum，手动补充..."
        python3 - "$SRC_FPK" <<'PY'
import tarfile, hashlib, io, os, sys, tempfile, shutil, gzip
src = sys.argv[1]
t = tarfile.open(src, 'r:gz')
app_data = t.extractfile('app.tgz').read()
sum_val = hashlib.md5(app_data).hexdigest()
tmp = tempfile.mkdtemp()
for m in t.getmembers():
    t.extract(m, tmp, filter='fully_trusted')
manifest_path = os.path.join(tmp, 'manifest')
with open(manifest_path, 'rb') as f:
    content = f.read().replace(b'\r\n', b'\n')
lines = content.decode('utf-8').splitlines(keepends=True)
with open(manifest_path, 'w', encoding='utf-8', newline='\n') as f:
    for line in lines:
        if line.startswith('checksum'):
            f.write(f'checksum              = {sum_val}\n')
        else:
            f.write(line)
with open(os.path.join(tmp, 'manifest.checksum'), 'w', encoding='utf-8', newline='\n') as f:
    f.write(sum_val + '\n')
out = io.BytesIO()
out_tar = tarfile.open(fileobj=out, mode='w')
members = t.getmembers()
name_to_member = {m.name: m for m in members}
order = ['manifest'] + [m.name for m in members if m.name not in ('manifest', 'manifest.checksum')]
order.insert(1, 'manifest.checksum')
for name in order:
    if name == 'manifest.checksum':
        out_tar.add(os.path.join(tmp, 'manifest.checksum'), arcname='manifest.checksum')
    else:
        full = os.path.join(tmp, name)
        if os.path.isdir(full):
            out_tar.addfile(name_to_member[name])
        else:
            out_tar.add(full, arcname=name)
out_tar.close()
with gzip.open(src, 'wb', compresslevel=9) as gz:
    gz.write(out.getvalue())
shutil.rmtree(tmp)
print(f'manifest.checksum added: {sum_val}')
PY
        echo "已补充 manifest.checksum"
    fi

    if [ "$OUT_DIR" != "." ]; then
        cp "$SRC_FPK" "${OUT_DIR}/fnos-${APPNAME}_v${VERSION}.fpk"
        echo "已生成: ${OUT_DIR}/fnos-${APPNAME}_v${VERSION}.fpk"
    fi
    # 取 checksum 供展示
    SUM="$(tar xzf "$SRC_FPK" -O manifest 2>/dev/null | grep '^checksum' | awk -F'= ' '{print $2}')"
    echo "checksum=${SUM}"
    exit 0
fi

echo "未找到 fnpack，回退到纯 tar+gzip 构建"

# ── 兜底：纯 tar+gzip 复刻官方双层 tar.gz 格式 ──
# 1. 内层 app.tgz（app/ 目录）
tar --owner=root --group=root --mtime='@0' -cf - app | gzip -n > app.tgz

# 2. checksum = app.tgz 的 MD5
if command -v md5sum >/dev/null 2>&1; then
    SUM="$(md5sum app.tgz | awk '{print $1}')"
elif command -v md5 >/dev/null 2>&1; then
    SUM="$(md5 -q app.tgz)"
else
    echo "缺少 md5sum / md5 工具" >&2
    exit 1
fi

# 3. 将 checksum 写回 manifest（整行替换，幂等，不叠加旧值）
sed "s/^checksum[[:space:]]*=.*/checksum              = ${SUM}/" manifest > manifest.tmp && mv manifest.tmp manifest

# 4. 生成 manifest.checksum 文件（飞牛应用中心会校验）
echo "$SUM" > manifest.checksum

# 5. 外层 tar.gz
tar --owner=root --group=root --mtime='@0' -cf - manifest manifest.checksum cmd config wizard ICON.PNG ICON_256.PNG app.tgz | gzip -n > "${OUT_DIR}/${APPNAME}.fpk"
rm -f manifest.checksum || true
rm -f app.tgz || true

# 5. 若指定了输出目录，重命名为带版本号的最终文件名
TARGET="${OUT_DIR}/${APPNAME}.fpk"
if [ "$OUT_DIR" != "." ]; then
    FINAL="${OUT_DIR}/fnos-${APPNAME}_v${VERSION}.fpk"
    mv "$TARGET" "$FINAL"
    echo "已生成: $FINAL (checksum=${SUM})"
else
    echo "已生成: $TARGET (checksum=${SUM})"
fi
