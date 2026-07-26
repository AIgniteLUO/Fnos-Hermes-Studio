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
