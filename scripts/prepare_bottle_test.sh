#!/bin/bash

# prepare_bottle_test.sh
# 打包前的两件事的离线回归：
#   1. conda 的占位前缀（info/has_prefix）要被换成安装后的绝对路径，text 与 binary 两种模式
#   2. 打完包必须复查：占位符不许留在被点名的文件里
#
# 为什么值得单独一条：这两件事以前是 conda 自己做的，我们不跑 conda。漏了的表现是
# `.pc` 的 prefix 指向构建机、`icu-config` 里的 default_prefix 不存在 —— 编译期与
# 运行期都会挂，而「装得上」这一步完全正常。
#
# 全程离线：直接调 prepare_bottle.py 里的函数，造一棵符合 conda 形状的假产物。

set -u

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${MACWAVE_PYTHON:-python3}"

FAILED=0
PASSED=0
pass() { echo -e "${GREEN}🌊 PASS: $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED_BOLD}🌊 FAIL: $1${RESET}"; FAILED=$((FAILED + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1（期望 $3，实际 $2）"; fi; }

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

PLACEHOLDER="/Users/builder/ci/_h_env_placehold_$(printf 'x%.0s' {1..210})"

mkdir -p "$WORK/art/lib/pkgconfig" "$WORK/art/bin" "$WORK/art/info"
printf 'prefix = %s\nexec_prefix = ${prefix}\n' "$PLACEHOLDER" > "$WORK/art/lib/pkgconfig/foo.pc"
printf '#!/bin/sh\ndefault_prefix="%s"\n' "$PLACEHOLDER" > "$WORK/art/bin/foo-config"
# 模拟 binary 模式：占位符嵌在二进制里，等着同长度替换 + NUL 补齐
{ printf '\xcf\xfa\xed\xfe'; printf 'HEAD%sTAIL' "$PLACEHOLDER"; printf '\x00%.0s' {1..16}; } > "$WORK/art/bin/footool"
cat > "$WORK/art/info/has_prefix" <<EOF
$PLACEHOLDER text lib/pkgconfig/foo.pc
$PLACEHOLDER text bin/foo-config
$PLACEHOLDER binary bin/footool
EOF

ORIG_BIN_SIZE="$(wc -c < "$WORK/art/bin/footool" | tr -d ' ')"

OUT="$("$PYTHON" - "$SCRIPT_DIR" "$WORK/art" <<'PYEOF'
import sys, importlib.util, pathlib
script_dir, target = sys.argv[1], pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("pb", f"{script_dir}/prepare_bottle.py")
pb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pb)

touched, leftovers = pb.apply_has_prefix(target, "/opt/macwave/Shore/foo/1.0")
print("touched:", touched)
print("leftovers:", leftovers)
print("pc:", [l for l in (target / "lib/pkgconfig/foo.pc").read_text().splitlines() if l.startswith("prefix")][0])
print("script:", [l for l in (target / "bin/foo-config").read_text().splitlines() if "default_prefix" in l][0])
data = (target / "bin/footool").read_bytes()
print("binary_size:", len(data))
print("binary_prefix:", b"HEAD/opt/macwave/Shore/foo/1.0" in data)
print("binary_placeholder_gone:", b"_h_env_placehold" not in data)
PYEOF
)"

check "改到了三处" "$(printf '%s\n' "$OUT" | grep '^touched:' | awk '{print $2}')" "3"
check "没有遗留" "$(printf '%s\n' "$OUT" | grep '^leftovers:' | awk '{print $2}')" "[]"
check "text 模式换成了安装后路径" "$(printf '%s\n' "$OUT" | grep '^pc:' | grep -c '/opt/macwave/Shore/foo/1.0')" "1"
check "wrapper 里的前缀也换了" "$(printf '%s\n' "$OUT" | grep '^script:' | grep -c '/opt/macwave/Shore/foo/1.0')" "1"
check "binary 模式保持文件长度" "$(printf '%s\n' "$OUT" | grep '^binary_size:' | awk '{print $2}')" "$ORIG_BIN_SIZE"
check "binary 模式写进了前缀" "$(printf '%s\n' "$OUT" | grep '^binary_prefix:' | awk '{print $2}')" "True"
check "binary 模式里占位符没了" "$(printf '%s\n' "$OUT" | grep '^binary_placeholder_gone:' | awk '{print $2}')" "True"

# ---- 载荷解包：.tgz / .zip / 单文件 .gz 必须真的解，不能原样拷进去 ----
#
# 漏了的后果不是「报错」，而是**整个压缩包被拷进产物**：重打出来的是个空壳，
# relocate 看不见里面的 Mach-O，闸门也不报错（cloudflared / gh / duckdb / ffmpeg 都踩过）。

mkdir -p "$WORK/pay/src/bin"
printf '#!/bin/sh\necho hi\n' > "$WORK/pay/src/bin/cf"
( cd "$WORK/pay/src" && tar czf "$WORK/pay/inner.tgz" bin )
( cd "$WORK/pay/src" && "$PYTHON" -c "import zipfile;z=zipfile.ZipFile('$WORK/pay/inner.zip','w');z.write('bin/cf');z.close()" )
printf 'raw\n' | gzip > "$WORK/pay/inner.gz"

OUT2="$("$PYTHON" - "$SCRIPT_DIR" "$WORK/pay" <<'PYEOF'
import sys, importlib.util, pathlib
script_dir, base = sys.argv[1], pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("pb", f"{script_dir}/prepare_bottle.py")
pb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pb)
for name in ("inner.tgz", "inner.zip", "inner.gz"):
    dest = base / ("out-" + name.replace(".", "-"))
    dest.mkdir()
    pb.extract(base / name, dest)
    print(name, "->", sorted(str(p.relative_to(dest)) for p in dest.rglob("*")))
PYEOF
)"

check "tgz 解包出 bin/cf" "$(printf '%s\n' "$OUT2" | grep '^inner.tgz' | grep -c 'bin/cf')" "1"
check "zip 解包出 bin/cf" "$(printf '%s\n' "$OUT2" | grep '^inner.zip' | grep -c 'bin/cf')" "1"
check "单文件 gz 解出原文件名" "$(printf '%s\n' "$OUT2" | grep '^inner.gz' | grep -c 'inner')" "1"

# ---- 源码 tarball 闸门：URL 指向上游源码时必须停手，不能把源码树当产物 ----
OUT3="$("$PYTHON" - "$SCRIPT_DIR" "$WORK" <<'PYEOF'
import sys, importlib.util, pathlib
script_dir, base = sys.argv[1], pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("pb", f"{script_dir}/prepare_bottle.py")
pb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pb)
src = base / "srctree"; (src / "src").mkdir(parents=True)
(src / "src" / "configure.ac").write_text("x")
(src / "src" / "a.c").write_text("x")
perl = base / "perlonly"; (perl / "p").mkdir(parents=True)
(perl / "p" / "cloc.pl").write_text("#!/usr/bin/perl\n")
print("source_is_source:", pb.looks_like_source(src / "src"))
print("script_is_source:", pb.looks_like_source(perl / "p"))
PYEOF
)"

check "源码树被认出来" "$(printf '%s\n' "$OUT3" | grep '^source_is_source:' | awk '{print $2}')" "True"
check "纯脚本包不误判" "$(printf '%s\n' "$OUT3" | grep '^script_is_source:' | awk '{print $2}')" "False"

echo ""
echo "=========================================="
echo "🌊 Passed: $PASSED"
echo -e "🌊 Failed: ${RED_BOLD}$FAILED${RESET}"
echo "=========================================="
[[ $FAILED -eq 0 ]] || exit 1
