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

# ── 规范化 app/ 目录权限与属主 ──
# 根因：CI runner（uid=1001）打包时会把 runner 的 uid/gid 写入 app.tgz。
# fnOS 解压后若尝试 chown 到应用用户，某些只读/特殊权限文件可能失败，
# 导致应用中心报"设置目录权限失败"。这里在打包前统一规范化：
#   - 所有文件对所有人可读，目录可进入
#   - 保留原有可执行位（bin/ 脚本、.node 等）
#   - 去掉 setuid/setgid/sticky 等特殊位
#   - 尽量把属主归到 root（CI 若没 root 则忽略失败）
normalize_app_permissions() {
    echo "规范 app/ 目录权限，避免带入构建机属主..."
    # 先尝试把属主改成 root:root；CI 普通用户会失败，不影响后续
    chown -R root:root app/ 2>/dev/null || true
    # 去掉特殊权限位（setuid/setgid/sticky），保留普通 rwx
    find app/ -type f -exec chmod a-s {} + 2>/dev/null || true
    find app/ -type d -exec chmod a-s {} + 2>/dev/null || true
    # 目录统一 755
    find app/ -type d -exec chmod 755 {} + 2>/dev/null || true
    # 普通文件统一 644
    find app/ -type f -exec chmod 644 {} + 2>/dev/null || true
    # 恢复真正需要可执行的文件：shebang 脚本、.mjs CLI、二进制、.so/.node
    find app/ -type f \( -name '*.sh' -o -name '*.mjs' -o -name '*.js' -o -name '*.cjs' \
        -o -name '*.node' -o -name '*.so' -o -name '*.so.*' -o -name 'hermes' \
        -o -name 'python3*' -o -name 'uv' -o -name 'uvx' \) \
        -exec chmod 755 {} + 2>/dev/null || true
    # 对 node_modules/.bin 下的 wrapper 也加可执行
    if [ -d app/node/lib/node_modules/.bin ]; then
        chmod -R 755 app/node/lib/node_modules/.bin/* 2>/dev/null || true
    fi
    if [ -d app/node/bin ]; then
        chmod -R 755 app/node/bin/* 2>/dev/null || true
    fi
    echo "app/ 权限规范化完成"
}

normalize_app_permissions

# ── FPK 后处理：移除软链、统一属主为 root、正规化权限 ──
# 根因：CI runner 以 uid=1001 构建，npm install -g 会生成 bin/ 软链；fnpack 把这些
# 原样打进 app.tgz。飞牛应用中心解压后再设置权限时，遇到：
#   1) 属主为 1001 的文件（非 root），某些 chown 场景下失败；
#   2) 软链自引用或指向不存在目标（Windows/Git Bash 下 npm 软链易损坏），
#      chmod/chown 递归处理时直接报错"设置目录权限失败"。
# 因此构建完成后必须对 FPK 做一次后处理：把 app.tgz 里所有软链/硬链去掉，
# 所有条目 uid/gid 重置为 0，权限正规化，再重新计算 checksum 打包。
postprocess_fpk() {
    local src="$1" dst="$2"
    echo "后处理 FPK：移除软链、重置属主、正规化权限 ..."
    python3 - "$src" "$dst" <<'PY'
import tarfile, hashlib, io, os, tempfile, shutil, gzip, sys

def sanitize_app_tgz(data):
    in_buf = io.BytesIO(data)
    in_tar = tarfile.open(fileobj=in_buf, mode='r:gz')
    out_buf = io.BytesIO()
    out_tar = tarfile.open(fileobj=out_buf, mode='w:gz', compresslevel=9)
    removed = 0
    kept = 0
    for m in in_tar.getmembers():
        # 跳过所有软链/硬链：install_callback 会自己重建 bin/ 软链
        if m.issym() or m.islnk():
            removed += 1
            continue
        # 统一属主为 root
        m.uid = 0
        m.gid = 0
        m.uname = 'root'
        m.gname = 'root'
        # 正规化权限
        if m.isdir():
            m.mode = 0o755
        else:
            # 任何可执行位 => 755，否则 644
            m.mode = 0o755 if (m.mode & 0o111) else 0o644
        m.mode &= ~0o7000  # 去掉 setuid/setgid/sticky
        try:
            f = in_tar.extractfile(m)
        except Exception as e:
            print(f"WARN: extract {m.name} failed: {e}", file=sys.stderr)
            continue
        out_tar.addfile(m, f)
        kept += 1
    out_tar.close()
    print(f"  app.tgz: removed {removed} symlinks/hardlinks, kept {kept} regular members")
    return out_buf.getvalue()

src, dst = sys.argv[1], sys.argv[2]
tmp = tempfile.mkdtemp()
try:
    # 解外层 FPK
    outer = tarfile.open(src, 'r:gz')
    app_data = outer.extractfile('app.tgz').read()
    for m in outer.getmembers():
        if m.name == 'app.tgz':
            continue
        outer.extract(m, tmp)
    outer.close()

    # 清洗 app.tgz
    new_app = sanitize_app_tgz(app_data)
    checksum = hashlib.md5(new_app).hexdigest()

    # 更新 manifest
    manifest_path = os.path.join(tmp, 'manifest')
    with open(manifest_path, 'rb') as f:
        content = f.read().replace(b'\r\n', b'\n')
    lines = content.decode('utf-8').splitlines(keepends=True)
    with open(manifest_path, 'w', encoding='utf-8', newline='\n') as f:
        for line in lines:
            if line.startswith('checksum'):
                f.write(f'checksum              = {checksum}\n')
            else:
                f.write(line)

    # manifest.checksum
    with open(os.path.join(tmp, 'manifest.checksum'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(checksum + '\n')

    # 重打外层 FPK：manifest -> manifest.checksum -> 其他 -> app.tgz
    out = io.BytesIO()
    out_tar = tarfile.open(fileobj=out, mode='w')
    order = ['manifest', 'manifest.checksum']
    other = sorted([m.name for m in tarfile.open(src, 'r:gz').getmembers()
                    if m.name not in ('manifest', 'manifest.checksum', 'app.tgz')])
    order.extend(other)
    order.append('app.tgz')

    for name in order:
        if name == 'app.tgz':
            info = tarfile.TarInfo(name='app.tgz')
            info.size = len(new_app)
            info.mode = 0o644
            info.uid = 0
            info.gid = 0
            out_tar.addfile(info, io.BytesIO(new_app))
        else:
            full = os.path.join(tmp, name)
            if os.path.isdir(full):
                info = tarfile.TarInfo(name=name)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                info.uid = 0
                info.gid = 0
                out_tar.addfile(info)
            else:
                out_tar.add(full, arcname=name)
    out_tar.close()

    with gzip.open(dst, 'wb', compresslevel=9) as gz:
        gz.write(out.getvalue())
    print(f"  postprocess OK: {dst}")
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PY
}

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

    # 后处理：移除软链、重置属主、正规化权限（避免 fnOS 报"设置目录权限失败"）
    postprocess_fpk "$SRC_FPK" "$SRC_FPK"

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

# 6. 后处理：移除软链、重置属主、正规化权限
TARGET="${OUT_DIR}/${APPNAME}.fpk"
postprocess_fpk "$TARGET" "$TARGET"

# 7. 若指定了输出目录，重命名为带版本号的最终文件名
if [ "$OUT_DIR" != "." ]; then
    FINAL="${OUT_DIR}/fnos-${APPNAME}_v${VERSION}.fpk"
    mv "$TARGET" "$FINAL"
    echo "已生成: $FINAL (checksum=${SUM})"
else
    echo "已生成: $TARGET (checksum=${SUM})"
fi
