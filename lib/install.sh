#!/bin/bash

# bash 3.2 (macOS)
# 本文件最近一次更新于：2026-11-26

# MacWave 🌊 Official Installer
# This script downloads wave.py, installs dependencies, and configures PATH.
# Usage: /bin/bash -c "$(curl -fsSL https://github.com/SummerwaveOrg/Summerwave/releases/latest/download/install.sh)"
# Unattended (CI): /bin/bash -c "$(curl -fsSL https://github.com/SummerwaveOrg/Summerwave/releases/latest/download/install.sh)" -- --ci

# 退出码要有语义
# 0 = 成功
# 1 = 用法错误
# 2 = 环境不满足（如 bash 太旧）
# 3 = 网络/下载失败

set -eE
set -u
set -o pipefail

# ==========================================
# --raw：无 🌊、无颜色、井号进度条
# ==========================================
#
# 与 `wave install --raw` 同一条规则：输出可以直接进日志、进 grep、进 diff。
#
#   * 不带行首的 🌊
#   * 不带任何 ANSI 颜色（调色板在下面定义后立刻清空）
#   * 下载进度用井号刻度，而不是光标重绘出来的东西
#
# 为什么在文件描述符（stdout/stderr）这一层做、而不是改每个调用点：这个脚本有
# 180 多处 🌊 字符串，散在 echo、mw_say、mw_say_err 三种写法里，逐个改必然漏
# 一处 —— 而漏一处就是「--raw 的输出里还有 emoji」。把 1、2 号文件描述符接到
# 一个过滤器上，是唯一能保证「一律」的地方（与 cli/silent.py 里 raw_output()
# 的做法同一条理由）。
#
# 顺带说明：这里说的是**文件描述符**，不是 `fd` 这个命令 —— 安装器只用 bash 内建
# 与 curl / tar / sed 这类 macOS 自带工具，不需要用户预先装任何东西。
#
# **装在第一条输出之前**：参数解析本身不打字，解析完立刻装过滤器，之后的测试根
# 提示、横幅、错误提示就都在过滤范围内。之前这里要先扫一遍参数才能做到「一律」，
# 那正是「版本号请求夹在解析中间」逼出来的结构 —— 现在解析在前、取版本在后，
# 一遍扫描就够。
# 注意：这里**只定义**过滤器，不安装它。参数还没解析，此刻还不知道有没有 --raw；
# 真正把它接到 1、2 号文件描述符上，是在参数解析之后（见“装上 --raw 的过滤器”）。
CLI_RAW=false

mw_raw() { [[ "${CLI_RAW:-false}" == "true" ]]; }

mw_raw_filter() {
    # 逐行读 stdin，去掉行首的 🌊 与紧跟的一个空格。
    # 🌊 用 printf 的字节写：$'\U0001F30A' 这种写法 bash 3.2 不支持。
    local line item
    item="$(printf '\xf0\x9f\x8c\x8a')"
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$item "*) line="${line#"$item "}" ;;
            "$item"*) line="${line#"$item"}" ;;
        esac
        printf '%s\n' "$line"
    done
}


# ==========================================
# 颜色定义
# ==========================================

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'
SKY_BLUE='\033[38;5;74m'
RED='\033[1;31m'


# ==========================================
# 语言
# ==========================================
# 不做 gettext、不依赖外部工具 —— 这个脚本要在裸 macOS 上跑，多一个依赖就多一处
# 装不上。文案直接写两份，由 mw_say() 按 MW_LANG 选。
#
# 默认英文，但**自动认**中文用户：手上这个终端/这台机器如果本来就是中文环境，
# 就没有理由先用英文糊一脸、再让人自己去加 --zh。
mw_lang_of_tag() {
    # mw_lang_of_tag <locale 或语言标签>：认得出就 echo zh / en，认不出（空串）返回 1。
    local tag="$1" lang charset=""
    [[ -n "$tag" ]] || return 1
    lang="${tag%%.*}"
    [[ "$tag" == *.* ]] && charset="${tag#*.}"
    case "$lang" in
        [Zz][Hh]|[Zz][Hh]_*|[Zz][Hh]-*) ;;
        *) echo en; return 0 ;;
    esac
    # 非 UTF-8 的中文 locale（zh_CN.eucCN、zh_TW.Big5）下，我们的 UTF-8 文案会糊成
    # 一片问号，那还不如给英文。
    case "$charset" in
        ""|*[Uu][Tt][Ff][-_]8*|*[Uu][Tt][Ff]8*) echo zh; return 0 ;;
        *) echo en; return 0 ;;
    esac
}

mw_detect_lang() {
    # 判定顺序（先到先算）：
    #   1. MACWAVE_LANG —— 调用方（CI、用户自己）显式给的；
    #   2. LC_ALL / LC_MESSAGES / LANG —— POSIX 惯例，终端与 ssh 都认这几项；
    #   3. macOS 的系统首选语言（`defaults read -g AppleLanguages` 的第一项）。
    #
    # 第 2 步一旦有值就以它为准，**不再看系统语言**：系统设成中文、LANG 却特意留在
    # en_US.UTF-8 的人（日志、CI、工具链要英文）通常是真不想要中文，反着猜只会更烦。
    local tag chosen
    for tag in "${MACWAVE_LANG:-}" "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
        if chosen="$(mw_lang_of_tag "$tag")"; then
            echo "$chosen"
            return 0
        fi
    done
    # `defaults read` 打出来是一个 plist 数组，第一项就是用户排在最前面的语言。
    # 取不到（容器里没有 defaults、被沙箱挡掉）就当没设过。
    if command -v defaults >/dev/null 2>&1; then
        tag="$(defaults read -g AppleLanguages 2>/dev/null | grep -m1 -o '"[^"]*"' | tr -d '"' || true)"
        if chosen="$(mw_lang_of_tag "$tag")"; then
            echo "$chosen"
            return 0
        fi
    fi
    echo en
}

MW_LANG="$(mw_detect_lang)"

# 输出函数一律带 mw_ 前缀。macOS 自带 /usr/bin/say（把参数念出来的朗读命令），
# 一个裸名 say 的函数被粘进终端时不会 command not found，只会把参数念给整个
# 房间听；叫 mw_say 最坏也只是 command not found，安静且无副作用。

mw_mktemp() {
    # mw_mktemp <名字前缀>：可移植的临时文件。
    #
    # macOS 的 `mktemp -t 前缀` 会自动补随机后缀，GNU mktemp 则要求模板里
    # **至少三个 X** —— 同一句 `mktemp -t foo` 在 Linux 上直接报
    # "too few X's in template"。统一写成「完整路径 + 六个 X」，两边都认。
    mktemp "${TMPDIR:-/tmp}/$1.XXXXXX"
}

mw_say() {
    # mw_say "<English>" "<中文>"
    #
    # 只给一句时两种语言都用它（`${2-$1}`）—— 空行、纯符号行、以及中英同文的
    # 命令行都属于这种。注意是 `-` 不是 `:-`：显式传了空串（英文有下半句、中文
    # 已经说完了）必须打空行，不能回退到英文。
    # 不给默认值时，`set -u` 下中文模式会以 "$2: unbound variable" 崩掉 —— 而那只
    # 发生在 --zh，属于「本地英文一切正常、用户用中文就炸」的典型。
    if [[ "$MW_LANG" == "zh" ]]; then
        printf '%b\n' "${2-$1}"
    else
        printf '%b\n' "$1"
    fi
}

mw_say_err() {
    if [[ "$MW_LANG" == "zh" ]]; then
        printf '%b\n' "$2" >&2
    else
        printf '%b\n' "$1" >&2
    fi
}

# 中途失败的收尾三句：什么都没删、半成品在哪、重跑是安全的。
# ERR trap 走这里；那些自己打了更具体原因的失败（比如下载失败）也要在退出前
# 调一次 —— 否则用户只看到「cannot download xxx」，既不知道有没有被删东西，
# 也不知道重跑会不会把现场搅得更糟。
install_failure_notice() {
    local code="${1:-1}"
    echo "" >&2
    echo -e "${RED_BOLD}🌊 Installation did not finish (exit $code).${RESET}" >&2
    mw_say_err "🌊 Nothing was removed. Files already downloaded may be left in:" "🌊 没有删除任何内容。已下载的文件可能留在："
    echo "     ${BASE_DIR:-<not chosen yet>}" >&2
    mw_say_err "🌊 Fix the cause (network, permissions, disk space) and run the installer again;" "🌊 请排除原因（网络、权限、磁盘空间）后重新运行安装程序；"
    mw_say_err "🌊 a repeated install overwrites what it downloaded and is safe to rerun." "🌊 重复安装会覆盖已下载的内容，可以安全重跑。"
}

# ==========================================
# 试运行（--dry-run）
# ==========================================
#
# 走完整条流程、把每一步会做什么打出来，但不下载、不提权、不建目录、不写文件。
# 用来看安装时终端会输出什么 —— 确认语、校验、PATH 提示都在，唯独没有副作用。
#
# 定义必须放在版本读取之前：默认源取不到版本号时，试运行要靠它继续往下走，
# 否则在断网的机器上永远只能看到第一行报错。
CLI_DRY_RUN=false

mw_dry_run() {
    [[ "${CLI_DRY_RUN:-false}" == "true" ]]
}

mw_plan() {
    # mw_plan <English> <中文>：试运行时把「本来会发生什么」打出来。
    # 不在试运行时一个字都不输出，调用点因此不必套 if。
    mw_dry_run || return 0
    if [[ "$MW_LANG" == "zh" ]]; then
        printf '%b\n' "$2"
    else
        printf '%b\n' "$1"
    fi
}



# ==========================================
# 域名（4.0：每个对外地址都能用环境变量换掉）
# ==========================================
#
# 与 lib/domains.py 是同一张表，一份给 Python、一份给 shell：install.sh 是
# `curl | bash` 直接执行的，没有本地文件可以 source，只能在这里重复一遍。
# 默认值仍是 3.x 在用的地址，一个变量都不设时行为与 3.x 完全一致。
#
# 这一段必须与 lib/selfupdate.sh 逐字一致 —— scripts/domains_test.sh 有断言。

mw_domain() {
    # mw_domain <变量名> <值>：校验协议、去掉末尾斜杠，然后打印规范化后的值
    local name="$1"
    local value="$2"

    while [[ "$value" == */ ]]; do
        value="${value%/}"
    done

    case "$value" in
        https://?*|file://?*) printf '%s\n' "$value"; return 0 ;;
        # 明文 http 只给本机镜像（离线测试、本机代理）
        http://127.0.0.1:?*|http://localhost:?*) printf '%s\n' "$value"; return 0 ;;
    esac

    echo -e "${RED_BOLD}🌊 Error: $name must be an https:// (or file://) address, got: $value${RESET}" >&2
    exit 1
}

mw_redact() {
    # mw_redact <url>：把 URL 里的口令换成 ***，日志与报错里不能出现明文。
    # 只在 host 段找 @ —— path 里的 @ 是合法文件名（jq@1.7.1.arm64）。
    local url="$1"
    local scheme rest authority path userinfo host user

    case "$url" in
        *://*) ;;
        *) printf '%s\n' "$url"; return 0 ;;
    esac

    scheme="${url%%://*}"
    rest="${url#*://}"
    authority="${rest%%/*}"
    if [[ "$rest" == */* ]]; then path="/${rest#*/}"; else path=""; fi

    case "$authority" in
        *@*) ;;
        *) printf '%s\n' "$url"; return 0 ;;
    esac

    userinfo="${authority%@*}"
    host="${authority##*@}"
    user="${userinfo%%:*}"
    if [[ "$userinfo" == *:* ]]; then
        printf '%s://%s:***@%s%s\n' "$scheme" "$user" "$host" "$path"
    else
        printf '%s://***@%s%s\n' "$scheme" "$host" "$path"
    fi
}

# pip 依赖（requests / packaging / rich）不在我们自己的存储里，仍走 PyPI。
# 国内直连 pypi.org 常超时，所以留一个可覆盖的索引地址：默认官方，设了就换。
#
# 与上面六个变量的差别：它不参与「MacWave 从哪取文件」的判断，只影响 pip 一次调用，
# 所以校验规则更松（允许 https 与 http 回环，与 mw_domain 同）。
PIP_INDEX_URL="$(mw_domain MACWAVE_PIP_INDEX "${MACWAVE_PIP_INDEX:-https://pypi.org/simple}")"

# MacWave 自身文件（后面再拼 /<tag>/<路径>）。0.1.0 起按 **tag** 取，不按分支：
# 清单已经内嵌在脚本里、哈希属于某个确定的版本，分支一动哈希就对不上。
CORE_URL="$(mw_domain SUMMERWAVE_CORE_DOMAIN "${SUMMERWAVE_CORE_DOMAIN:-https://raw.githubusercontent.com/SummerwaveOrg/Summerwave}")"
# 自带 CPython 的清单
# 解释器单独一个仓库（体积与发布节奏都和自更新数据不同）
# 便携 Python 不在这里定地址：版本、文件名、sha256 与 Release asset id 全部由
# scripts/build_installer.py 注入（数据来自 config/portable_python.toml），
# 运行时只有一次 api.github.com 请求。见 portable_python_asset / ensure_portable_python。

# 用户协议所在页面。4.7 起安装器只在开头把地址念一遍（不记录同意、结尾也不问），
# 所以它纯粹是给人看的一个链接。站点在 summerwave.org。
AGREEMENT_URL="${MACWAVE_AGREEMENT_URL:-https://summerwave.org}"

# ==========================================
# 额外根证书（MACWAVE_CACERT）
# ==========================================
#
# 企业网络里 TLS 会被中间设备重签，自建镜像也可能用私有 CA。把根证书交给我们就
# 够了，不必让人为了连上而关掉校验（本脚本没有 --skip-ssl）。
#
# 设了就必须可用：静默忽略的后果是用户以为自己已经信任了那家 CA，实际还在失败，
# 于是他会去怀疑镜像、怀疑网络，唯独不会想到是路径写错了。
#
# 用 ${CURL_CACERT:+--cacert "$CURL_CACERT"} 展开，而不是把它拼进一段无引号的
# 参数串 —— 路径里带空格是常事（"~/Library/Application Support/..."）。
CURL_CACERT=""
if [[ -n "${MACWAVE_CACERT:-}" ]]; then
    _cacert="${MACWAVE_CACERT/#\~/$HOME}"
    if [[ ! -f "$_cacert" || ! -r "$_cacert" ]]; then
        echo -e "${RED_BOLD}🌊 Error: MACWAVE_CACERT is not a readable file: ${_cacert}${RESET}" >&2
        echo -e "${RED_BOLD}🌊 Next      point it at the CA's root certificate in PEM form, e.g. export MACWAVE_CACERT=/etc/ssl/corp-root.pem${RESET}" >&2
        echo -e "${RED_BOLD}🌊           unset it to go back to the system trust store${RESET}" >&2
        exit 1
    fi
    CURL_CACERT="$_cacert"
fi


# -------------------- 签名校验（0.1.0 起的位置变了） --------------------
#
# 0.1.0 不再有「带签名的版本数据」：版本号与逐文件清单都在这个脚本里，清单又逐条钉住
# 每个文件的 sha256。所以可信起点变成了**这份脚本本身**：
#
#   * `wave selfupdate` 在 bash 它之前，先验同 tag 的 `install.sh.sig`（不通过不执行）；
#   * 手工安装用文档里那条「下载脚本 + 下载 .sig → 验签 → 再运行」的两步命令；
#     `curl … | bash` 省掉了这一步，只在能确认来源时才用。
#
# 下面的 mw_trusted_pub / mw_verify_* 仍然保留：它们是「验一份字节是否由我们签的」
# 的唯一实现（scripts/shared/signature_verify.sh 与它逐字一致，check_shared_blocks.py
# 盯着），手工验签与后续把「执行前校验」搬进来都用它。
#
# 公钥从哪来：mw_trusted_pub() 见下面 —— 优先 MACWAVE_RSA_PUB（一个 PEM 路径），
# 否则用脚本里内嵌的那把钥（scripts/embed_rsa_pub.py 维护）。

mw_sha256() {
    # 用 openssl：macOS 自带，不必依赖 shasum 的 perl
    openssl dgst -sha256 -r "$1" 2>/dev/null | awk '{print $1}'
}

mw_signature_note() {
    # mw_signature_note <一行英文> <一行中文>
    echo -e "${YELLOW}$1${RESET}" >&2
    echo -e "${YELLOW}$2${RESET}" >&2
}

mw_check_integrity() {
    # mw_check_integrity <说明> <文件> <期望 sha256>
    # 空期望值 = 这一版没带哈希（实验期的常态），直接放行。
    local what="$1" file="$2" expect="$3" got
    [[ -n "$expect" ]] || return 0
    got="$(mw_sha256 "$file")"
    [[ "$got" == "$expect" ]] && return 0
    if [[ "${MACWAVE_STRICT_HASHES:-}" == "1" ]]; then
        echo -e "${RED_BOLD}🌊 Error: $what does not match the signed data.${RESET}" >&2
        echo -e "${RED_BOLD}🌊   expected $expect${RESET}" >&2
        echo -e "${RED_BOLD}🌊   got      ${got:-<unreadable>}${RESET}" >&2
        exit 1
    fi
    mw_signature_note "🌊 Warning: $what does not match the signed data (continuing)" \
        "🌊 警告：$what 与已签名数据不符（继续）"
    echo -e "${YELLOW}🌊   expected $expect${RESET}" >&2
    echo -e "${YELLOW}🌊   got      ${got:-<unreadable>}${RESET}" >&2
    return 0
}

# >>> RSA public key (managed by scripts/embed_rsa_pub.py) >>>
MW_RSA_PUB_PEM='-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAjU1mGJPPTAhFrjXYtE65
xfDZtAaK8OM+uWJSTnXkLJuFWXMZsFtqVU78Hab/qYWGFbb4csY/9nDe3gChVWNe
z6gz+pevUmMBI53IaUlj/ifqHbMzINyTcVrass2D60+dzyFxwd0n58IFWsKEBq2m
tTO9o2aQWmJPHjK4mOmItXDpbjM8qcDnf6tOHBoPBJni07zE/v1b3eRuJt3m++J0
F1zKJN4PWdgyuwSQWxXHP3/zeT0oTFC25zR/4jdCI10MY9fYZk7R1u6bf65nW0dd
W/Bixk2Gn5rI1ddGn+FpLgilggVPRyF+PoLtsEDqGT2pWieEU+TrpHNWzPbYNTfj
CThk8UNi6xGfnYsok3MkS1QRG4F1JZ0hkoI2ChgefKam9xYIRcdnJ3i65/2ZUpAx
nIybx6s0ysMUITaqQOUCNBo009W9ivRuwD8Iae9t0Hwpv7Ou87fkBWvysYYRwF9l
yrQUrEHrNKHvFDhzyAHAFrSBjLATEQrNLZhwnkSjV447AgMBAAE=
-----END PUBLIC KEY-----'
# <<< RSA public key <<<

# 验签的函数不在这里了：0.1.0 换轨之后自更新是「取目标 tag 的 install.sh 与它的
# .sig、验签、执行」，那件事在 lib/selfupdate.py 里用 openssl 做（与这里原先的
# mw_verify_latest_signature 同一条命令、同一把公钥）。上面内嵌的 MW_RSA_PUB_PEM
# 必须留着 —— Python 侧就是从这一份里抠出锚点，用安装树里的 Keys/ 那份等于自证。

# <<< signature helpers <<<


# ==========================================
# 辅助函数：将路径中的 $HOME 替换为 ~
# ==========================================

home_to_tilde() {
    local path="$1"
    if [[ "$path" == "$HOME"* ]]; then
        echo "~${path#$HOME}"
    else
        echo "$path"
    fi
}

# 同上，但结果会**原样交给用户复制执行**，所以要照顾 shell 的展开规则：
#   - `~` 只在引号外展开，`"~/a b/x"` 展开不了；含空格的片段写成 `~/"a b"/x`，
#     bash、zsh 与 csh 都实测可用。
#   - 路径不在家目录下且含空格时，整段加引号。
home_to_tilde_arg() {
    local path="$1"
    local prefix="" rest="$path"
    if [[ "$path" == "$HOME" || "$path" == "$HOME"/* ]]; then
        prefix="~"
        rest="${path#"$HOME"}"
        rest="${rest#/}"
        [[ -z "$rest" ]] && { printf '~'; return; }
    fi
    if [[ "$rest" == *" "* || "$rest" == *'"'* ]]; then
        rest="${rest//\"/\\\"}"
        printf '%s"%s"' "${prefix:+$prefix/}" "$rest"
    else
        printf '%s%s' "${prefix:+$prefix/}" "$rest"
    fi
}

# 必须让 shell 自己展开的场合（grep 的匹配模式、csh 的双引号里）改用 $HOME/…：
# 它在双引号内也会展开，而 ~ 不会。
home_to_homevar() {
    local path="$1"
    if [[ "$path" == "$HOME" || "$path" == "$HOME"/* ]]; then
        local rest="${path#"$HOME"}"
        rest="${rest#/}"
        [[ -z "$rest" ]] && { printf '$HOME'; return; }
        printf '$HOME/%s' "$rest"
    else
        printf '%s' "$path"
    fi
}

# ==========================================
# 安装位置
# ==========================================
#
# 位置是写死的，按平台各一处：macOS 是 /opt/macwave，Linux 是
# /home/linuxwave/.linuxwave（唯一来源是 config/platforminfo.py 的
# DEFAULT_BASE_DIR）。这里不提供菜单、候选目录或自定义目录 —— 一台机器一棵树，
# 路径一变，排查问题时日志里的路径就对不上。
#
# 为什么是 /opt（而不是 ~/.local 之类）：
#   - 依赖只有一份：Shore/ 动辄几百 MB，多个用户各装一份 ~/.local 就是 N 份；
#   - 与 Homebrew（/opt/homebrew）同一套心智；
#   - 不受 HOME 影响：搬机、改用户名、用 sudo 跑脚本都不会打偏；
#   - 权限模型干净：root:<管理员组> 775（目录 setgid），管理员组成员装包不用
#     sudo，其他用户只读，任何本地用户都不能替换 bin/ 里的链接。
# 代价：安装要一次管理员密码；树是共享状态（同机多个管理员时才会互相影响）。

ARCH=$(uname -m)

# ==========================================
# 下载（--raw 时带井号刻度）
# ==========================================

mw_download() {
    # mw_download <url> <out> <max-time>
    #
    # 非 --raw 时就是原来那句 `curl -fsSL … -o <out>` —— 行为、返回值完全不变。
    # --raw 时多打一行井号刻度：**总长已知就每 10% 一个 #**（与 Python 侧
    # _RawProgress 同一条规则），未知就每 MiB 一个。不换行重绘、不带颜色，
    # 所以落进日志是一行完整的进度，而不是一串控制字符。
    local url="$1" out="$2" cap="$3" total pid rc=0 size shown=0 step
    shift 3
    # 多出来的参数按「每个都是 header 值」处理 —— api.github.com 的 Release 资产接口
    # 要 Accept: application/octet-stream 才会 302 到 CDN。
    local header_args=()
    while [[ $# -gt 0 ]]; do header_args+=(-H "$1"); shift; done
    if ! mw_raw; then
        curl -fsSL --max-time "$cap" ${CURL_CACERT:+--cacert "$CURL_CACERT"} \
            ${header_args[@]+"${header_args[@]}"} -o "$out" "$url"
        return $?
    fi

    # 先问一次长度。HEAD 失败不算错：拿不到就按 MiB 打刻度。
    total="$(curl -fsSI --max-time "$cap" ${CURL_CACERT:+--cacert "$CURL_CACERT"} \
        ${header_args[@]+"${header_args[@]}"} "$url" 2>/dev/null \
        | tr -d '\r' | tr 'A-Z' 'a-z' | awk -F': *' '$1=="content-length"{print $2}' | tail -n 1)"
    case "$total" in
        ''|*[!0-9]*) total=0 ;;
    esac
    if (( total > 0 )); then
        step=$(( total / 10 ))
        (( step > 0 )) || step=1
    else
        step=1048576
    fi

    rm -f "$out" 2>/dev/null || true
    curl -fsSL --max-time "$cap" ${CURL_CACERT:+--cacert "$CURL_CACERT"} \
        ${header_args[@]+"${header_args[@]}"} -o "$out" "$url" & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        size=$(wc -c < "$out" 2>/dev/null | tr -d ' ')
        size=${size:-0}
        while (( (shown + 1) * step <= size )); do
            printf '#'
            shown=$(( shown + 1 ))
        done
        sleep 0.2
    done
    wait "$pid" || rc=$?

    if (( rc == 0 )); then
        # 小文件可能一格都没打；补满十个 #，让每一行下载都是同一个形状
        while (( shown < 10 )); do
            printf '#'
            shown=$(( shown + 1 ))
        done
        printf '  %s\n' "$(wc -c < "$out" 2>/dev/null | tr -d ' ')"
    else
        printf '\n'
    fi
    return $rc
}

# ==========================================
# 命令行参数（批量 / 脚本化安装）
# ==========================================

CLI_CI=false
# --skip-probe：不真写那个探针文件，提权判定只用 test -w 的静态结论。
# 见「是否需要 sudo」那一节里 mw_can_write 的说明。
CLI_SKIP_PROBE=false
# --help：打用法后**停**在这里；--print-usage：打用法后继续安装（或继续试运行）。
CLI_HELP=false
CLI_PRINT_USAGE=false
# 默认从我们自己的 Python 仓库取解释器；这个开关让它回上游取
INSTALL_PYTHON_FROM_SOURCE=""

usage() {
    # 用法一律走 mw_say —— 语言由它挑（--zh），呈现规则与其它输出一致：
    # --raw 时调色板已清空、🌊 也会被输出过滤器剥掉，所以这里不必再判断一次。
    #
    # 每一项是**一段**（段内用 \n 分行），而不是一行一次调用：中英两种语言的
    # 折行位置本来就不同，逐行成对会逼着一边凑行数，凑出来的空行在中文里就是
    # 多出来的空白。按段落给，各自折各自的。
    mw_say "Summerwave installer" "Summerwave 安装程序"
    mw_say ""
    mw_say "Usage:" "用法："
    mw_say "  install.sh [options]" "  install.sh [选项]"
    mw_say ""
    mw_say "Options:" "选项："
    mw_say "      --ci, --CI          No interaction at all: no confirmation, no questions.\n\
                          Installs into the fixed location, so it needs\n\
                          passwordless sudo or root." \
           "      --ci, --CI          完全不交互：不确认、不提问。装到固定位置，\n\
                          因此需要免密 sudo 或以 root 运行。"
    mw_say "      --dry-run           Print what the installer would do and change\n\
                          nothing: no download, no sudo, no directory\n\
                          created, no file written. When the latest version\n\
                          cannot be fetched it continues with a placeholder,\n\
                          so the output can be reviewed offline." \
           "      --dry-run           只打印安装器会做什么，不做任何改动：不下载、不提权、\n\
                          不建目录、不写文件。取不到最新版本号时用占位值继续，\n\
                          因此在断网的机器上也能看完整个输出。"
    mw_say "      --raw               Plain output for logs and scripts: no emoji, no\n\
                          colours, ASCII progress bars. Interaction is\n\
                          unchanged; combine with --ci for unattended runs." \
           "      --raw               给日志和脚本用的输出：不带 🌊、不带颜色、进度条用\n\
                          井号刻度。交互不变；无人值守请再配 --ci。"
    mw_say "      --skip-probe        Do not create the temporary probe file used to decide\n\
                          whether privilege is needed; rely on the permission\n\
                          bits alone. Use it when the target must stay\n\
                          untouched -- a wrong guess only moves the failure to\n\
                          the first real write." \
           "      --skip-probe        判定是否需要提权时不在目标里建那个临时探针文件，只用\n\
                          权限位判断。适合「目标必须一点痕迹都不留」的场合 ——\n\
                          判断错了只是把失败推迟到第一次真正写入。"
    mw_say "        --install-python-from-source\n\
                            Download the bundled CPython from its upstream URL\n\
                            (recorded in pythondata/<version>/python_url.toml)\n\
                            instead of from MacWave's own Python repository." \
           "        --install-python-from-source\n\
                            自带 CPython 改从上游 URL 下载（记录在\n\
                            pythondata/<version>/python_url.toml），\n\
                            而不是从 MacWave 自己的 Python 仓库取。"
    mw_say "      --zh                Print in Chinese. Auto-detected from the locale or\n\
                          the macOS preferred language; --zh forces it." \
           "      --zh                用中文输出。语言本来就会按 locale 与系统首选语言\n\
                          自动识别，--zh 是强制指定。"
    mw_say "      --en                Print in English (overrides auto-detection)." \
           "      --en                用英文输出（压过自动识别）。"
    mw_say "  -h, --help              Show this help and stop. May only be combined with\n\
                          --dry-run (print the usage, then walk the install)." \
           "  -h, --help              显示本帮助后停止。只能单独用，或与 --dry-run 连用\n\
                          （先打用法，再走一遍流程）。"
    mw_say "      --print-usage       Show this help, then continue (install or dry run)." \
           "      --print-usage       显示本帮助后继续（真的安装，或继续试运行）。"
    mw_say ""
    # 这里不能用安装根变量（BASE_DIR）：用法在参数解析阶段就打，那时它还没算出来。
    mw_say "Install target: fixed per platform — /opt/macwave on macOS,\n\
                          /home/linuxwave/.linuxwave on Linux." \
           "安装位置：按平台写死 —— macOS 是 /opt/macwave，\n\
                           Linux 是 /home/linuxwave/.linuxwave。"
    mw_say ""
    mw_say "Examples:" "示例："
    mw_say "  install.sh --ci" "  install.sh --ci"
    mw_say "  install.sh --CI --raw" "  install.sh --CI --raw"
    mw_say ""
    mw_say "Running it straight from the repository (options go after '--'):" \
           "直接从仓库运行（选项放在 '--' 之后）："
    mw_say '  /bin/bash -c "$(curl -fsSL <url>)" -- --ci' \
           '  /bin/bash -c "$(curl -fsSL <url>)" -- --ci'
}

# 参数在这里**一次**解析完。以前要扫两遍：一遍为了让 --raw 赶在第一条输出之前
# 生效，一遍为了让 --zh/--dry-run 赶在「读版本号」之前生效 —— 那是因为取版本号的
# 网络请求被放在了解析之前。现在取版本在后面，扫一遍就够。
#
# 留一份原始参数：下面的 while 会一路 shift 把 "$@" 掏空，而 --help 的连用规则
# 要在解析之后回头检查「用户到底还给了什么」。
CLI_ARGV=("$@")
PARSE_ERROR_OPT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ci|--CI)
            CLI_CI=true
            ;;
        --dry-run|--DRY-RUN)
            CLI_DRY_RUN=true
            ;;
        --raw|--RAW)
            CLI_RAW=true
            ;;
        --skip-probe|--SKIP-PROBE)
            CLI_SKIP_PROBE=true
            ;;
        --install-python-from-source)
            INSTALL_PYTHON_FROM_SOURCE=1
            ;;
        --zh|--ZH)
            MW_LANG="zh"
            ;;
        --en|--EN)
            MW_LANG="en"
            ;;
        -h|--help)
            CLI_HELP=true
            ;;
        --print-usage|--PRINT-USAGE)
            CLI_PRINT_USAGE=true
            ;;
        *)
            # 不在这里打印：此刻还没有装上 --raw 的过滤器、也没定语言。
            # 记下来，等输出环境就绪再报（见下面「报告解析错误」）。
            PARSE_ERROR_OPT="$1"
            break
            ;;
    esac
    shift
done

# ==========================================
# 装上 --raw 的过滤器，并确定语言
# ==========================================
#
# 到这里参数已经解析完：--raw / --zh 都有结论了，而**还没有输出过任何东西**。
# 所以过滤器只需要装一次、也只需要扫一遍参数 —— 解析在前、取版本在后，正是为此。
#
# 但解析可能在第一处未知选项就停下（那时 --raw 还没被读到）。所以这里从**原始
# 参数**再认一次呈现类旗标，保证「未知选项 + --raw」报出来的错也是干净的。
_PRESENTATION_APPLIED=false
mw_apply_presentation() {
    [[ "$_PRESENTATION_APPLIED" == "true" ]] && return 0
    local arg
    for arg in ${CLI_ARGV[@]+"${CLI_ARGV[@]}"}; do
        case "$arg" in
            --raw|--RAW) CLI_RAW=true ;;
            --zh|--ZH) MW_LANG="zh" ;;
            --en|--EN) MW_LANG="en" ;;
        esac
    done
    if mw_raw; then
        RED_BOLD=""; RED=""; GREEN=""; YELLOW=""; SKY_BLUE=""; RESET=""
        exec > >(mw_raw_filter) 2>&1
    fi
    _PRESENTATION_APPLIED=true
}
mw_apply_presentation

# 参数没认出来：现在才报（语言与 --raw 都已就绪）。
if [[ -n "$PARSE_ERROR_OPT" ]]; then
    mw_say_err "${RED_BOLD}🌊 Error: unknown option '$PARSE_ERROR_OPT'. Try --help.${RESET}" \
        "${RED_BOLD}🌊 错误：未知选项 '$PARSE_ERROR_OPT'。可试 --help。${RESET}"
    exit 1
fi

# ==========================================
# --help 的连用规则
# ==========================================
#
# --help 只回答「怎么用」，不安装。所以它只允许两种出现方式：
#
#   install.sh --help                 打用法，停
#   install.sh --help --dry-run       打用法，然后照 --dry-run 走一遍流程（不安装）
#
# 与其它安装参数连用一律报错：`--help --ci` 读起来像是「按这些参数装」，
# 实际却只打帮助 —— 把它拦下来，比让用户以为装过了强。
# --zh / --raw 例外：它们只改呈现（语言、输出格式），不是安装参数。
#
# --print-usage 才是「打用法然后继续安装」的那个开关。
if [[ "$CLI_HELP" == "true" ]]; then
    _bad=""
    for _arg in ${CLI_ARGV[@]+"${CLI_ARGV[@]}"}; do
        case "$_arg" in
            -h|--help|--dry-run|--DRY-RUN|--zh|--ZH|--en|--EN|--raw|--RAW) ;;
            *) _bad="$_arg"; break ;;
        esac
    done
    if [[ -n "$_bad" ]]; then
        mw_say_err "${RED_BOLD}🌊 Error: --help cannot be combined with '$_bad'.${RESET}" \
            "${RED_BOLD}🌊 错误：--help 不能和 '$_bad' 连用。${RESET}"
        mw_say_err "🌊 --help only prints the usage and stops. Two ways to go further:" \
            "🌊 --help 只打用法、不安装。想再往下走有两条路："
        mw_say_err "🌊   install.sh --help --dry-run    print the usage, then walk the install" \
            "🌊   install.sh --help --dry-run    先打用法，再走一遍流程（不安装）"
        mw_say_err "🌊   install.sh --print-usage       print the usage, then install for real" \
            "🌊   install.sh --print-usage       先打用法，再真的安装"
        exit 1
    fi
fi

if [[ "$CLI_PRINT_USAGE" == "true" ]]; then
    usage
fi

if [[ "$CLI_HELP" == "true" ]]; then
    usage
    # 与 --dry-run 连用时继续往下走；单独出现时到此为止。
    [[ "$CLI_DRY_RUN" == "true" ]] || exit 0
fi

# 通过管道安装时，选项很容易被当成脚本名传进来：
#   bash -c "$(curl ...)" --ci         ← --ci 变成 $0，被静默丢掉
# 这里明确提示，避免「静默模式没生效、脚本却卡在交互上」。
case "$0" in
    --) ;;              # 正确写法：`--` 之后的参数才轮到脚本
    -*)
        echo -e "${YELLOW}🌊 Warning: '$0' was treated as the script name, not as an option.${RESET}" >&2
        echo -e "${YELLOW}🌊 Put installer options after '--', which ends bash's own options.${RESET}" >&2
        echo "🌊   /bin/bash -c \"\$(curl -fsSL <url>)\" -- $0" >&2
        ;;
esac

# -------------------- 平台守卫：只装 macOS 与 Linux --------------------
#
# 两个平台的运行时布局完全一致（Shore/<名>/<版本>/），所以同一份安装器都管；
# 不同的只有安装根（见上面「安装位置」）与各自的权限模型。
#
# 客户端**不需要** otool / install_name_tool / codesign / patchelf：Mach-O 与 ELF
# 的路径改写全在打包时做完（scripts/relocate_rpath.py），客户端只下载 + 解包。
#
# 只认内核：Darwin 是 macOS，Linux 是 Linux，其它照 uname -s 的原值报出来。
# 越狱的 iPhone、Android 上的 Termux、ChromeOS 的容器**一概不单独识别** ——
# 这些设备上装不装得成，由用户自己保证，见 config/platforminfo.py 的文件头。
#
# MACWAVE_TEST 下不判：那是在「把某个目录当作 /」的沙箱里跑同一份脚本。
mw_platform() {
    # macos / linux / unknown
    local kernel
    kernel="$(uname -s 2>/dev/null || true)"
    case "$kernel" in
        Darwin) echo macos ;;
        Linux)  echo linux ;;
        *)      echo unknown ;;
    esac
}

# 支持范围（对外承诺）：Apple Silicon 要 Sequoia 15，Intel 要 Monterey 12。
#
# 与 config/platforminfo.py 的 MIN_SUPPORTED_OS 是同一张表 —— 那边给客户端与构建侧读，
# 这边给「还没装任何东西」的安装脚本读（这时树都还不存在，导入不了 python 常量）。
# scripts/install_flags_test.sh 会核对两边是不是同一组值。
#
# 为什么按架构分而不是全库一个值：任何 Apple Silicon Mac 都跑得动 15，所以这个地板
# 排除不了任何硬件，只排除「能升但不升」的人；Intel 侧由构建机的 SDK 决定（一台
# Monterey 12 的机器），天然就是 12，白捡了停更老 Intel Mac 的兼容面。
MW_MIN_MACOS_ARM64="15.0"
MW_MIN_MACOS_X86_64="12.0"

# 读不到版本号时不判：宁可放行，也不要在读不出信息时把一台正常机器挡在门外。
MACWAVE_OLD_MACOS=""

mw_min_macos_for_arch() {
    case "${ARCH:-$(uname -m)}" in
        arm64|aarch64) echo "$MW_MIN_MACOS_ARM64" ;;
        *)             echo "$MW_MIN_MACOS_X86_64" ;;
    esac
}

mw_version_ge() {
    # $1 >= $2，按点分数字比较。不用 sort -V：老的 BSD sort 没有它，
    # 而这条判断要在一台「可能很老」的机器上跑。
    #
    # 注意 `local IFS=.` 不会影响同一行里的 `x=($1)` —— 展开先于赋值，
    # 那样 14.6.1 会被当成一个整体、去掉点后变成 1461 去跟 150 比。
    # 必须用 read -a 在 IFS 生效之后切。
    local IFS=.
    local -a left right
    read -r -a left <<< "$1"
    read -r -a right <<< "$2"
    local index a b
    for index in 0 1 2; do
        a="${left[index]:-0}"; b="${right[index]:-0}"
        a="${a//[^0-9]/}"; b="${b//[^0-9]/}"
        ((10#${a:-0} > 10#${b:-0})) && return 0
        ((10#${a:-0} < 10#${b:-0})) && return 1
    done
    return 0
}

mw_macos_version_ok() {
    local raw floor
    raw="$("${MACWAVE_SW_VERS:-/usr/bin/sw_vers}" -productVersion 2>/dev/null || true)"
    if [[ -z "$raw" ]]; then
        return 0
    fi
    [[ "$raw" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 0
    floor="$(mw_min_macos_for_arch)"
    if mw_version_ge "$raw" "$floor"; then
        return 0
    fi
    MACWAVE_OLD_MACOS="$raw"
    return 1
}

mw_require_supported_platform() {
    if [[ -n "${MACWAVE_TEST:-}" ]]; then
        return 0
    fi
    local platform
    platform="$(mw_platform)"
    case "$platform" in
        macos)
            # 版本地板只在 macOS 有意义（Linux 那边看的是 glibc，交给发行版自己保证）。
            if ! mw_macos_version_ok; then
                mw_say "🌊 macOS ${MACWAVE_OLD_MACOS} on ${ARCH} is too old — Apple Silicon needs macOS ${MW_MIN_MACOS_ARM64} (Sequoia), Intel needs macOS ${MW_MIN_MACOS_X86_64} (Monterey)." \
                       "🌊 ${ARCH} 上的 macOS ${MACWAVE_OLD_MACOS} 版本过低 —— Apple Silicon 需要 macOS ${MW_MIN_MACOS_ARM64}（Sequoia），Intel 需要 macOS ${MW_MIN_MACOS_X86_64}（Monterey）或更高。"
                mw_say "🌊 Nothing was changed. Upgrade macOS, then run this installer again." \
                       "🌊 什么都没改。升级 macOS 之后再跑一次这个安装脚本。"
                exit 2
            fi
            return 0
            ;;
        linux)
            return 0
            ;;
    esac

    mw_say "🌊 Summerwave runs on macOS and Linux; this platform was not recognised." \
           "🌊 Summerwave 只装 macOS 与 Linux —— 认不出这个平台。"
    mw_say "🌊 uname -s says: $(uname -s 2>/dev/null || echo unknown)" \
           "🌊 uname -s 报的是：$(uname -s 2>/dev/null || echo unknown)"
    mw_say "🌊 Nothing was changed on this machine; this is an environment mismatch, not a half-install." \
           "🌊 这台机器上什么都没改 —— 这是环境不对，不是装了一半。"
    mw_say "🌊 Set MACWAVE_TEST=<dir> if you meant to run this in a sandbox." \
           "🌊 如果是想在沙箱里跑，设置 MACWAVE_TEST=<目录>。"
    # 2 = 环境不满足，见文件头的退出码说明
    exit 2
}

mw_require_supported_platform

# -------------------- 测试根（隔离） --------------------
# MACWAVE_TEST 指向一个目录时，把它当作 /：HOME 和所有系统路径都挂到它下面，
# 整条链路都落在那个目录里，完全不碰真实系统。
# 没设置时 SYS_ROOT 为空，下面 "$SYS_ROOT/opt/..." 就还是 "/opt/..."，行为不变。
SYS_ROOT=""
if [[ -n "${MACWAVE_TEST:-}" ]]; then
    _mw_root="$MACWAVE_TEST"
    if [[ "$_mw_root" == "~"* ]]; then
        _mw_root="${HOME}${_mw_root#\~}"
    fi
    mkdir -p "$_mw_root"
    # 物理路径：macOS 上 /var 是指向 /private/var 的符号链接，这里若用逻辑路径，
    # 与下面比较用的 HOME（configpaths 已经 resolve 过）对不上，前缀判断就会失效。
    SYS_ROOT="$(cd "$_mw_root" && pwd -P)"
    # 幂等：config/configpaths.py 也会把 HOME 搬进测试根。从 wave.py 一路调用下来时
    # HOME 已经被改过一次，这里再套一层就会变成 "<根><根>/Users/<你>"，配置目录于是
    # 永远找不到。两边都取物理路径再比较，才不会被 /var 与 /private/var 骗过去。
    _mw_home_real="$(cd "$HOME" 2>/dev/null && pwd -P)" || _mw_home_real="$HOME"
    case "$_mw_home_real" in
        "$SYS_ROOT"|"$SYS_ROOT"/*) ;;
        *) export HOME="$SYS_ROOT${HOME}" ;;
    esac
    mkdir -p "$HOME"
    # 用 mw_say：现在它已经定义好了（参数解析更早），并行输出也走同一个闸门。
    # 这行带 🌊，--raw 时会被过滤器剥掉。
    mw_say "🌊 Test root: $SYS_ROOT" "🌊 测试根：$SYS_ROOT"
fi

# ==========================================
# 升级模式（selfupdate 调起来的那一次）
# ==========================================
#
# `wave selfupdate` 不再自己维护一套「下载 + 迁移 + 写凭据 + 建 venv」的流程：
# 它取目标版本的 lib/install.sh，带着下面这组变量执行本文件。于是「怎么装」只有
# 一份实现 —— 全新安装与升级跑的是同一个脚本，区别只在几个开关。
#
# 为什么不是「下载一段代码去 bash」：本文件就是**目标 tag 的发布资产**，版本号与
# 逐文件清单都内嵌在它自己头部，审计时读这一个文件就够；调用方（`wave selfupdate`）
# 会先验它的 `.sig` 再执行。
#
# 变量契约（全部可选；缺哪个就退回默认值）：
#
#   MACWAVE_SELFUPDATE=1        我在升级一棵已有的树（装哪棵树不传 —— 位置写死）
#   MACWAVE_NEED_SUDO=1|0       提权结论沿用调用方的，不重新探测
SELFUPDATE_MODE=false
if [[ "${MACWAVE_SELFUPDATE:-}" == "1" ]]; then
    SELFUPDATE_MODE=true
fi

# ==========================================
# 安装根：写死的一处（见上面「安装位置」）
# ==========================================
#
# 升级模式与全新安装走同一条路：都装到 /opt/macwave。调用方（wave selfupdate）
# 传不传 MACWAVE_INSTALL_DIR 都一样 —— 位置不是参数。

case "$(mw_platform)" in
    linux) DEFAULT_BASE_DIR="$SYS_ROOT/home/linuxwave/.linuxwave" ;;
    *)     DEFAULT_BASE_DIR="$SYS_ROOT/opt/macwave" ;;
esac

if [[ "$SELFUPDATE_MODE" == "true" ]]; then
    if [[ -n "${MACWAVE_INSTALL_DIR:-}" && "${MACWAVE_INSTALL_DIR}" != "$DEFAULT_BASE_DIR" ]]; then
        echo -e "${RED_BOLD}🌊 Error: MACWAVE_INSTALL_DIR='${MACWAVE_INSTALL_DIR}' is not supported: the install directory is fixed at $DEFAULT_BASE_DIR.${RESET}" >&2
        exit 1
    fi
    BASE_DIR="$DEFAULT_BASE_DIR"
    mw_say "🌊 Updating the installation at $BASE_DIR" "🌊 正在更新 ${BASE_DIR} 这棵安装树"
elif [[ "$CLI_CI" == "true" ]]; then
    BASE_DIR="$DEFAULT_BASE_DIR"
    mw_say "🌊 --ci: installing into $DEFAULT_BASE_DIR (needs passwordless sudo or root)." \
        "🌊 --ci：装到 ${DEFAULT_BASE_DIR}（需要免密 sudo 或以 root 运行）。"
else
    BASE_DIR="$DEFAULT_BASE_DIR"
fi

DISPLAY_DIR=$(home_to_tilde "$BASE_DIR")

# ==========================================
# 不检测旧的安装
# ==========================================
#
# Summerwave 是一个新软件，不是 MacWave / LinuxWave 的升级版：它不猜旧版本装在
# 哪里，不迁移旧目录，也不为旧版本留兼容分支。装到写死的位置，用新布局重来。
#
# 曾经这里有一段「发现 2.x/3.x/4.x 就拒绝安装」的判定。删掉的理由：4.6 允许
# `--dir-option=N=DIR` 装到任意目录，写死几个候选位置永远扫不全，而扫不到的后果
# 就是「以为拦住了、其实两套并行」。既然没有存量用户，这一整类问题不值得维护。

# ==========================================
# 动手之前确认：装到这个位置，继续吗？
# ==========================================
#
# 为什么把确认放在这里、而不是结尾：此刻磁盘上一个字节都还没改，用户说不装就是
# 干净退出，不需要回滚；而回滚要删安装树、删配置、清 rc 里的 PATH —— 升级场景还
# 可能把用户原来那棵能用的树一起毁掉。问一句便宜得多。
#
# 谁该被打断：
#   - 升级（SELFUPDATE_MODE）：调用方是 `wave selfupdate`，人已经做了选择；
#   - --ci：无人值守，不确认也不提问，按写死的位置装；
#   - --dry-run：只打印、什么都不改，没什么可确认的；
#   - MACWAVE_TEST 或拿不到 /dev/tty（curl | bash 的 stdin 是脚本本身）：不问，
#     按写死的位置继续 —— 安装不破坏已有数据，在这里卡死反而更需要 `--ci` 的形状。
if [[ "$SELFUPDATE_MODE" == "true" ]]; then
    :
elif [[ "$CLI_CI" == "true" ]]; then
    mw_say "🌊 --ci: the user agreement is accepted automatically (${AGREEMENT_URL})." \
           "🌊 --ci：自动接受用户协议（${AGREEMENT_URL}）。"
elif mw_dry_run; then
    mw_plan "🌊 Dry run: the install target and the agreement are not asked about." \
        "🌊 试运行：不会询问安装位置，也不会询问用户协议。"
elif [[ -z "${MACWAVE_TEST:-}" ]] && [[ -r /dev/tty ]]; then
    # 安装位置与用户协议**合成一次**确认：两件事都必须在动手之前说清，
    # 分成两次提问只会让人以为「后面还有一轮」。
    echo ""
    mw_say "🌊 Summerwave will be installed to ${DISPLAY_DIR}" \
           "🌊 Summerwave 将会安装到 ${DISPLAY_DIR}"
    mw_say "🌊   This asks for an administrator password once." \
           "🌊   过程中需要一次管理员密码。"
    echo ""
    mw_say "🌊 Using Summerwave means you accept the user agreement:" \
           "🌊 使用 Summerwave 即表示你接受用户协议："
    mw_say "🌊   ${AGREEMENT_URL}" "🌊   ${AGREEMENT_URL}"
    echo ""
    mw_say "🌊 Continue? [Y/n]" "🌊 继续吗？[Y/n]"
    _answer=""
    # 没人应答（EOF）按同意处理：能走到这里说明有终端，回车就是默认值。
    read -r _answer < /dev/tty || _answer=""
    _answer="$(printf '%s' "$_answer" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    case "$_answer" in
        ""|y|yes) ;;
        n|no)
            mw_say "🌊 You did not accept the agreement — nothing was changed." \
                   "🌊 你未接受用户协议 —— 什么都没有改动。"
            exit 0
            ;;
        *)
            mw_say "🌊 Unrecognised answer, so nothing was changed." \
                   "🌊 无法识别的回答，什么都没有改动。"
            exit 0
            ;;
    esac
fi

# ==========================================
# 版本号（来自脚本自己）
# ==========================================
#
# 0.1.0 起**没有自更新数据仓库**：这个脚本是某个 tag 的发布产物，版本号与逐文件清单
# 都内嵌在它自己的头部（见 scripts/build_installer.py）。所以这里不联网、不读 TOML，
# 只做两件事：确认「我确实是发布产物」，以及把 tag 拆成渠道与构建号。
#
# 拿模板（lib/install.sh）直接跑会在这一步退出 —— 模板里没有 MACWAVE_MANIFEST_VERSION，
# 那意味着它不知道这一版该装哪些文件，硬跑只会装出一棵半成品。

# 是不是模板（仓库里那份 lib/install.sh）？模板没有清单，只能在「真的要装」时拒绝，
# 不能在这里就退出 —— --print-usage、平台守卫、--dry-run 这些路径根本不下载文件，
# 却都要先跑这段。
MW_IS_TEMPLATE=false
[[ -n "${MACWAVE_MANIFEST_VERSION:-}" ]] || MW_IS_TEMPLATE=true
if [[ -z "${MACWAVE_VERSION:-}" ]]; then
    if mw_dry_run; then
        MACWAVE_VERSION="unknown"
    else
        MW_IS_TEMPLATE=true
    fi
fi

# 渠道与构建号都从 tag 里来：`<版本>[-rc.N|-beta.N][@YYYY-MM-DDTHH:MMZ]`。
# tag 协议的唯一解释口是 lib/taginfo.py；这里是它在 bash 里的最小镜像（只有发布号
# 与渠道两件事），改动时必须两边一起动 —— scripts/taginfo_test.sh 盯着。
MW_CHANNEL="stable"
case "$MACWAVE_VERSION" in
    *-rc.*|*-beta.*)
        MW_CHANNEL="preview" ;;
esac
BUILD_NUMBER=""
case "$MACWAVE_VERSION" in
    *@*) BUILD_NUMBER="${MACWAVE_VERSION##*@}" ;;
esac

# 取件用的 ref 与「版本号」不是同一个东西，不能互相顶替：
#   * 版本号是给人看、给比较用的 —— 0.1.0；
#   * ref 是发布 tag 名 —— v0.1.0（lib/taginfo.py 要求 v 前缀，而 git 的 tag
#     名里又不许出现 `:`，所以带构建时刻的那种写法根本打不成 tag）。
# 构建时由 scripts/build_installer.py 注入 MACWAVE_CORE_REF；模板直接跑时回落到
# 版本号，保持「没注入就按版本号取」的老行为。
MW_CORE_REF="${MACWAVE_CORE_REF:-$MACWAVE_VERSION}"

BASE_URL="$CORE_URL/$MW_CORE_REF"

# 整包地址。codeload.github.com 一次给出整棵 tag 的 tar.gz（约 1–2 MB），
# 内嵌清单里的 90 条 sha256 照样逐条校验，所以「一次拿全部」不降低安全性。
#
# 为什么不是 raw.githubusercontent.com 逐文件：那条链路在校园网与家宽上十次有
# 三次连不上，而安装要发 90 次请求 —— 一次失败整装就失败。codeload 一直通。
CORE_ARCHIVE_URL="https://codeload.github.com/SummerwaveOrg/Summerwave/tar.gz/$MW_CORE_REF"

# ==========================================
# 显示欢迎信息
# ==========================================
# WAVE 艺术字。与语言无关，两种语言都打 —— 它只是装饰，不值得为它写两份。
#
# --raw 时整段跳过：那是给日志和 grep 看的输出，六行全是块字符，只会把真正的
# 内容顶出屏幕、把日志撑满。装饰不参与「装得成不成」这件事，去掉它不影响任何断言。
if ! mw_raw; then
    echo ""
    echo -e "${SKY_BLUE}██╗    ██╗ █████╗ ██╗   ██╗███████╗${RESET}"
    echo -e "${SKY_BLUE}██║    ██║██╔══██╗██║   ██║██╔════╝${RESET}"
    echo -e "${SKY_BLUE}██║ █╗ ██║███████║██║   ██║█████╗  ${RESET}"
    echo -e "${SKY_BLUE}██║███╗██║██╔══██║╚██╗ ██╔╝██╔══╝  ${RESET}"
    echo -e "${SKY_BLUE}╚███╔███╔╝██║  ██║ ╚████╔╝ ███████╗${RESET}"
    echo -e "${SKY_BLUE} ╚══╝╚══╝ ╚═╝  ╚═╝  ╚═══╝  ╚══════╝${RESET}"
    echo ""
fi
mw_say "🌊 Welcome to Summerwave $MACWAVE_VERSION!" "🌊 欢迎使用 Summerwave ${MACWAVE_VERSION}！"

if mw_dry_run; then
    echo ""
    mw_say "${YELLOW}🌊 Dry run: the whole install is walked through, nothing is changed.${RESET}" \
        "${YELLOW}🌊 试运行：完整走一遍安装流程，但不做任何改动。${RESET}"
fi

if [[ "$CORE_URL" != "https://raw.githubusercontent.com/SummerwaveOrg/Summerwave" ]]; then
    mw_say "🌊 Install from mirror: $(mw_redact "$CORE_URL")" "🌊 从镜像安装：$(mw_redact "$CORE_URL")"
fi

echo ""

mw_say "🌊 Detected architecture: $ARCH" "🌊 检测到架构：$ARCH"

# ==========================================
# 判断是否需要 sudo
# ==========================================

CURRENT_USER=$(whoami)

# ==========================================
# 系统级安装的所有权
# ==========================================
#
# 为什么不是 chown -R 给当前用户：那会把 /opt/macwave 变成「第一个安装者私有」的，
# 同一台机器上别的管理员 `wave install` 会 Permission denied —— 而 /opt 这类目录的
# 本意恰恰是共享安装。
#
# 为什么不是 chmod -R 777：任何本地用户都能替换 /opt/macwave/bin/jq，而它可能
# 被别的用户、脚本甚至 root 执行 —— 那是教科书式的本地提权路径。
#
# 采用的模型：root:<管理员组> 775，目录带 setgid。把写权限收窄到「管理员」这一层，
# 与「谁能 sudo」是同一个人群 —— 组可写并不会让权限变大（管理员本来就能 sudo 成
# root），却换掉了一整类日常摩擦：
#
#   所有人              可读、可执行（能运行已装的包）
#   管理员组（admin）   可写（wave install / 升级**不需要 sudo**）
#   其他人              只读
#
# 4.3.0 / 4.3.1 用的是 755（只有 root 可写），代价是每次装包都要 `sudo wave
# install`。那条路要求用户亲手提权，而且 `sudo` 有自己的 PATH、HOME 也变成
# /var/root；对一个「系统级共享安装」来说，摩擦与收益不成比例。
#
# setgid 必须加在目录上：否则组员（管理员）新建的文件会落回他自己的主组，
# 下一个管理员就写不进去了 —— 与 LinuxWave 的共享安装同一条理由。
# -------------------- Linux：共享安装账户 --------------------
#
# Linux 的安装根是 /home/linuxwave/.linuxwave —— 路径里就有个账户名，所以那棵树
# 必须属于它，否则「家目录」只是个普通目录，而 root 拥有一个别人的家目录会让
# ssh、scp、备份工具全部困惑。
#
# 做法沿用 LinuxWave 4.x（那份实现是踩过坑的，改动前先读这里的注释）：
#
#   1. 建 linuxwave 账户与同名组（useradd -m -d /home/linuxwave）；
#   2. 树交给 linuxwave:linuxwave，打开组写位，目录加 setgid；
#   3. 把调用者加进 linuxwave 组 —— 于是 `wave install` 不需要 sudo。
#
# 与 macOS 的 root:<管理员组> 是同一个心智（「谁能写这棵树」= 一个组），只是
# macOS 那侧没人为这个组命名，Linux 这侧正好有个现成的账户名。
linux_shared_user() {
    echo "linuxwave"
}

prepare_linux_shared_account() {
    [[ "$(mw_platform)" == "linux" ]] || return 0
    local user home
    user="$(linux_shared_user)"
    home="/home/$user"

    if mw_dry_run; then
        mw_plan "🌊 Dry run: would create the '$user' account (if missing) and open $home to all users." \
            "🌊 试运行：将创建 '$user' 账户（如果不存在），并把 ${home} 开放给所有用户。"
        return 0
    fi

    if id "$user" >/dev/null 2>&1; then
        mw_say "🌊 Account '$user' already exists." "🌊 账户 '$user' 已存在。"
    else
        mw_say "🌊 Creating the '$user' account..." "🌊 正在创建账户 '$user'……"
        if command -v useradd >/dev/null 2>&1; then
            as_privileged useradd -m -d "$home" -s /bin/bash "$user" || return 1
        else
            # Alpine 这类只有 BusyBox 的 adduser，没有 useradd
            as_privileged adduser -D -h "$home" -s /bin/sh "$user" || return 1
        fi
    fi

    # useradd -m 建出的家目录默认 750，别的用户连进都进不去
    as_privileged chmod 755 "$home" || return 1
    return 0
}

hand_over_linux_install() {
    # Linux 的最终属主：linuxwave:linuxwave，775（目录 setgid）。
    local dir="$1" user gid
    user="$(linux_shared_user)"

    if mw_dry_run; then
        mw_plan "🌊 Dry run: would hand $dir over to $user:$user with mode 775 (directory setgid), and add $CURRENT_USER to the '$user' group." \
            "🌊 试运行：将把 ${dir} 交给 ${user}:${user}，权限 775（目录带 setgid），并把 ${CURRENT_USER} 加进 '$user' 组。"
        return 0
    fi
    [[ -d "$dir" ]] || return 0

    as_privileged chown -R "$user:$user" "$dir" || return 1
    as_privileged chmod -R u+rwX,g+rwX,o+rX,o-w "$dir" || return 1
    # setgid 只给目录：文件上的 setgid 是强制锁，含义完全不同。
    as_privileged find "$dir" -type d -exec chmod g+s {} + || return 1

    # 组共享。三个坑（都是 LinuxWave 实测过的）：
    #   * `groupadd -f` 幂等 —— useradd -m 通常已经建了同名组，但装到已有账户的
    #     机器上时组可能不在；
    #   * 拿 gid 用 getent，非 glibc（Alpine/musl）没有它，所以必须 `|| true`，
    #     否则在 `set -eE` 下会把「查不到组」报成「安装失败」；
    #   * `id -G <用户名>` 查的是 /etc 数据库（要不要 usermod），不带参数的 `id -G`
    #     读的是**当前会话**的进程组（要不要重新登录）—— 两者混用会把「已写进
    #     /etc/group、但这个 shell 还没有该组」谎报成已生效。
    as_privileged groupadd -f "$user" || true
    gid="$(getent group "$user" 2>/dev/null | cut -d: -f3 || true)"

    if [[ "$CURRENT_USER" != "$user" ]]; then
        if [[ -n "$gid" ]] && id -G "$CURRENT_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$gid"; then
            : # 已经在组里，什么都不用做
        else
            # usermod 失败不该让整个安装失败：树已经装好、也仍然可用，用户只是
            # 还得按提示用 sudo 装包。说清楚，不吞掉。
            if as_privileged usermod -aG "$user" "$CURRENT_USER" 2>/dev/null; then
                :
            else
                mw_say "${YELLOW}🌊 Could not add '$CURRENT_USER' to '$user' automatically.${RESET}" \
                       "${YELLOW}🌊 没能自动把 '$CURRENT_USER' 加进 '$user' 组。${RESET}"
                mw_say "🌊 Run it by hand: sudo usermod -aG $user $CURRENT_USER" \
                       "🌊 请手工执行：sudo usermod -aG ${user} ${CURRENT_USER}"
                return 0
            fi
        fi
        # 权限位立即生效，只有「个人的组身份」要等新的登录会话
        if ! id -G 2>/dev/null | tr ' ' '\n' | grep -qx "$gid"; then
            mw_say "${YELLOW}🌊 Group '$user' is set up; re-login (or run 'newgrp $user') so that" \
                   "${YELLOW}🌊 installing packages no longer needs sudo.${RESET}" \
                   "${YELLOW}🌊 '$user' 组已配置好；重新登录（或执行 newgrp ${user}）之后装包就不再需要 sudo。${RESET}"
        fi
    fi
    return 0
}

admin_group() {
    # 只在「当前用户确实是这个组的成员」时才用它。
    #
    # 走到这里说明安装已经成功 sudo 过（写 /opt、/usr/local 都要密码），所以当前
    # 用户是管理员这一点无需怀疑；把组设成管理员组，等于把「谁能改这个安装树」
    # 定义为「所有管理员」，而不是「当初装它的那个人」。
    #
    # 但仍要验证成员资格：有些环境（root 直接跑、容器里的非标准用户）不在这几个
    # 组里，那时退回当前用户的主组，免得 chown 到一个自己都不属于的组。
    local candidate
    for candidate in admin sudo wheel; do
        if ! id -Gn "$CURRENT_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$candidate"; then
            continue
        fi
        if dscl . -read "/Groups/$candidate" >/dev/null 2>&1 \
           || grep -qE "^${candidate}:" /etc/group 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    id -gn "$CURRENT_USER"
}

lend_tree_to_user() {
    # 安装期间把树**暂时**交给调用者。**这不是最终属主**：装完由
    # hand_over_system_install 收回去，变成 root:<管理员组> 775（目录带 setgid）。
    #
    # 为什么需要它：自带 Python 与私有 venv 都是以**普通用户**身份写的
    # （ensure_portable_python 里的 mkdir/curl/tar、以及 `python -m venv`），
    # 树若已经是 root 所有，这些步骤会全部失败 —— 而且失败得很安静：自带
    # Python 只打一句「可能是网络」，venv 只打一句警告，最后依赖被 pip --user
    # 装进安装者自己的 site-packages，别的用户就用不了这套安装。
    #
    # 4.3.0 之前这两处是 `chown -R "$CURRENT_USER"`，语义正确；改成本函数之前
    # 请确认「还有没有以用户身份写树的步骤」，否则会重演上面那次退化。
    local dir="$1"
    [[ "$NEED_SUDO" == "true" ]] || return 0
    [[ -n "$dir" ]] || return 0
    if mw_dry_run; then
        mw_plan "🌊 Dry run: would lend $dir to $CURRENT_USER while the bundled Python and the venv are written." \
            "🌊 试运行：写自带 Python 与 venv 期间，将把 ${dir} 暂时交给 ${CURRENT_USER}。"
        return 0
    fi
    [[ -d "$dir" ]] || return 0
    sudo chown -R "$CURRENT_USER": "$dir" || return 1
    return 0
}

hand_over_system_install() {
    # 系统级安装（$BASE_DIR 不在家目录下）才需要动手；用户级本来就是自己的。
    #
    # mode：u+rwX,g+rwX,o+rX,o-w = 目录 2775（含 setgid）、普通文件 664、
    # 原有的可执行文件 775。o-w 不能省 —— 少了它就回到「任何本地用户都能替换
    # bin/ 里的链接」。
    local dir="$1" group
    [[ -n "$dir" ]] || return 0

    # Linux 走自己的那一套：属主是 linuxwave 账户，不是 root。
    if [[ "$(mw_platform)" == "linux" ]]; then
        hand_over_linux_install "$dir"
        return $?
    fi

    if mw_dry_run; then
        # 目录此刻还不存在（试运行不建），所以判断要放在 -d 检查之前。
        mw_plan "🌊 Dry run: would hand $dir over to root:$(admin_group) with mode 775 (directory setgid)." \
            "🌊 试运行：将把 ${dir} 交给 root:$(admin_group)，权限 775（目录带 setgid）。"
        return 0
    fi
    [[ -d "$dir" ]] || return 0
    group="$(admin_group)"
    # 调用方（NEED_HANDOVER）已经确保「要么需要提权、要么本来就是 root」。
    as_privileged chown -R "root:$group" "$dir" || return 1
    as_privileged chmod -R u+rwX,g+rwX,o+rX,o-w "$dir" || return 1
    # 只给目录加 setgid：文件上的 setgid 是另一种含义（强制锁），不该乱设。
    as_privileged find "$dir" -type d -exec chmod g+s {} + || return 1
    return 0
}

# 状态文件的权限：管理员组要能写。
#
# 安装会把树交给 root:<管理员组> 775，管理员组成员因此不用 sudo 就能装包；
# 而自更新写的是树内 <base>/var/config.sh，同一个组要是写不进去，每次升级都会
# 退回去要密码（2026-11-24 在 /opt 上实测）。让管理员组写状态文件不扩大权限面 ——
# 他们本来就能改整棵树。
state_file_mode() {
    echo 664
}

mw_can_write() {
    # 能写这个路径吗？返回 0 可写 / 1 需要提权 / 2 写不进去但不是权限问题。
    #
    # 两步，先「猜」再「问」：
    #   1. `test -w` —— 权限位与 ACL 的静态判断，够快，也够挡住「/opt 属于 root」
    #      这类绝大多数情形；
    #   2. 真写一个空文件再删掉 —— `test -w` 只是读权限位，遇到目录上带 uchg 之类的
    #      标志、或者 ACL 与位掩码不一致时，它说能写而实际写不进去。既然安装的第一件
    #      事就是往里写，那就先写一次试试：探针失败与真安装失败是同一件事，只是早了几步。
    #
    # 探针失败要分两类，不能一律当成「需要提权」：
    #   Permission denied   → 提权能解决，返回 1；
    #   其它（只读文件系统、磁盘满、路径太深…）→ 提权也没用，返回 2 并留下原因，
    #   由调用方当场报出来。否则用户会先被要一次密码，然后在同一条路上再失败一次。
    #
    # 不存在的路径沿祖先往上找第一个存在的目录 —— 直接对不存在的路径 test -w 恒为假，
    # 会让每一次新装都判定成需要提权。
    local path="$1" probe errfile reason
    MW_WRITE_ERROR=""
    MW_WRITE_ERROR_PATH=""
    [[ -n "$path" ]] || return 1
    while [[ ! -e "$path" && "$path" != "/" ]]; do
        path="$(dirname "$path")"
    done
    [[ -d "$path" ]] || return 1
    [[ -w "$path" ]] || return 1

    # --dry-run 的承诺是「不写文件」，所以试运行只用上面那步静态判断；
    # --skip-probe 是用户显式要求跳过这次写探针（例如目标目录在别人的地盘上，
    # 不想留下任何痕迹，宁可事后由真正的写入报错）。
    if mw_dry_run || [[ "${CLI_SKIP_PROBE:-false}" == "true" ]]; then
        return 0
    fi

    errfile="$(mw_mktemp macwave-write-probe)"
    if probe="$(mktemp "$path/.macwave-write-probe.XXXXXX" 2>"$errfile")"; then
        rm -f "$probe" "$errfile"
        return 0
    fi
    reason="$(cat "$errfile" 2>/dev/null)"
    rm -f "$errfile"
    case "$reason" in
        *"Permission denied"*) return 1 ;;
    esac
    MW_WRITE_ERROR="$reason"
    MW_WRITE_ERROR_PATH="$path"
    return 2
}

mw_write_state() {
    # 两个目标都要能写；任何一处返回 2 都直接报错退出（提权解决不了）。
    local status=0
    mw_can_write "$1" || status=$?
    if [[ "$status" -eq 2 ]]; then
        mw_say_err "${RED_BOLD}🌊 Error: cannot create files in '$MW_WRITE_ERROR_PATH'.${RESET}" \
            "${RED_BOLD}🌊 错误：无法在 '$MW_WRITE_ERROR_PATH' 里创建文件。${RESET}"
        mw_say_err "🌊 ${MW_WRITE_ERROR}" "🌊 ${MW_WRITE_ERROR}"
        mw_say_err "🌊 This is not a privilege problem: sudo would fail the same way." \
            "🌊 这不是权限问题：提权也会一样失败。"
        mw_say_err "🌊 Fix the filesystem (read-only mount, full disk, …) or choose another directory." \
            "🌊 请处理文件系统本身（只读挂载、磁盘已满等），或者换一个目录。"
        exit 1
    fi
    return "$status"
}

# 升级模式下用调用方的结论：`wave selfupdate` 已经做过写探测（它自己那次就是
# 判据），这里再探测一遍只会在「组可写的共享安装」上问一次多余的密码。
if [[ "$SELFUPDATE_MODE" == "true" && -n "${MACWAVE_NEED_SUDO:-}" ]]; then
    if [[ "$MACWAVE_NEED_SUDO" == "1" ]]; then
        NEED_SUDO=true
    else
        NEED_SUDO=false
    fi
    mw_say "🌊 Privilege: $([ "$NEED_SUDO" = "true" ] && echo "administrator access (from selfupdate)" || echo "none needed (from selfupdate)")" \
           "🌊 提权：$([ "$NEED_SUDO" = "true" ] && echo "需要管理员权限（沿用自更新判定）" || echo "不需要（沿用自更新判定）")"
else
# `|| var=$?` 而不是直接取 $?：set -e 下裸调一个返回非零的函数会当场退出。
base_state=0
mw_write_state "$BASE_DIR" || base_state=$?
if [[ "$base_state" -eq 0 ]]; then
    NEED_SUDO=false
else
    NEED_SUDO=true
fi
fi

# 以 root 身份跑（`sudo bash install.sh`、容器里的 `--ci`）时 NEED_SUDO 为假 ——
# 但系统级安装仍要把属主/权限收尾成 root:<管理员组> 775，否则别的管理员就不能
# `wave install` 了（那正是 4.3.2 起采用的共享安装模型）。
IS_ROOT=false
[[ "$(id -u)" == "0" ]] && IS_ROOT=true

# /opt/macwave 永远是共享安装：收了尾（root:<管理员组> 775）别的管理员才能装包。
NEED_HANDOVER=false
if [[ "$NEED_SUDO" == "true" ]] || [[ "$IS_ROOT" == "true" ]]; then
    NEED_HANDOVER=true
fi

# 需要动属主/权限时用它：普通用户走 sudo，本来就以 root 跑就直接执行
# （容器里未必装了 sudo）。**不要**在别处硬写 sudo —— 那会让 root 场景也依赖它。
as_privileged() {
    if [[ "$NEED_SUDO" == "true" ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

run_cmd() {
    # 试运行只把命令打出来：建目录、写配置、删旧文件都经由这里。
    if mw_dry_run; then
        if [[ "$NEED_SUDO" == "true" ]]; then
            echo -e "${YELLOW}    sudo $*${RESET}"
        else
            echo -e "${YELLOW}    $*${RESET}"
        fi
        return 0
    fi
    if [[ "$NEED_SUDO" == "true" ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

if [[ "$NEED_SUDO" == "true" ]]; then
    if mw_dry_run; then
        mw_plan "${YELLOW}🌊 Dry run: installing to $BASE_DIR needs administrator access; no password is asked now.${RESET}" \
            "${YELLOW}🌊 试运行：装到 ${BASE_DIR} 需要管理员权限，现在不会索取密码。${RESET}"
    elif [[ "$CLI_CI" == "true" ]]; then
        # --ci 不能停下来等密码：要么已经是 root，要么已有免密 sudo
        if ! sudo -n true 2> /dev/null; then
            echo -e "${RED_BOLD}🌊 Error: this install needs privilege, but --ci cannot ask for a password.${RESET}" >&2
            echo -e "${RED_BOLD}🌊 Run as root, or configure passwordless sudo for the install user.${RESET}" >&2
            exit 1
        fi
    else
        mw_say "${YELLOW}🌊 Granting temporary administrator access for installation...${RESET}" "${YELLOW}🌊 正在申请临时管理员权限以完成安装……${RESET}"
        sudo -v
    fi
fi

# ==========================================
# 文件清单（内嵌在脚本头部）
# ==========================================
#
# 这一版的安装树该长什么样，只写在脚本开头那一段 heredoc 里：每行
#
#     <仓库内路径> <0|1 是否 +x> <sha256>
#
# 为什么跟着脚本走而不是再下一个清单文件：装什么由**一份被签名的文件**说了算，
# 读一个脚本就能完整审计；顺带少一次网络往返。清单与「怎么装」因此永远是同一个
# 版本的 —— 以前它们分居两处，漂移只会在某一条路径上出错。
#
# 清单的生成在服务端（scripts/build_installer.py），它同时把版本号写进脚本。
# 这里只负责把它落到临时文件，好让下面的 sync_tree 用同一套 `while read` 逻辑。

read_toml_string() {
    # read_toml_string <文本> <键> —— 取平铺的字符串值，去掉引号与行尾注释。
    # 只剩 Python 引导那一步在用（pythondata/latest.toml），见文件末尾。
    printf '%s\n' "$1" \
        | sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        | head -n 1
}

MANIFEST_TMP=""

cleanup_manifest() {
    if [[ -n "$MANIFEST_TMP" ]]; then
        rm -f "$MANIFEST_TMP"
    fi
}
trap cleanup_manifest EXIT

prepare_manifest() {
    # 把内嵌清单写进临时文件。校验只有一件事：格式对不对（路径 + 0/1 + 64 位哈希）。
    # 内容不需要额外校验 —— 它就在正在被执行的这个脚本里。

    if [[ "$MW_IS_TEMPLATE" == "true" ]]; then
        echo -e "${RED_BOLD}🌊 Error: this install.sh carries no file list.${RESET}" >&2
        echo -e "${YELLOW}🌊 It is a template, not a release artifact. Download the installer from:${RESET}" >&2
        echo -e "${YELLOW}🌊   https://github.com/SummerwaveOrg/Summerwave/releases/latest/download/install.sh${RESET}" >&2
        echo -e "${YELLOW}🌊 Nothing was installed.${RESET}" >&2
        exit 1
    fi
    if ! printf '%s\n' "$MANIFEST" | grep -qE '^[^ ]+ [01] [0-9a-f]{64}$'; then
        echo -e "${RED_BOLD}🌊 Error: the embedded file list is malformed.${RESET}" >&2
        echo -e "${RED_BOLD}🌊 Nothing was installed. Please report this to the administrator.${RESET}" >&2
        exit 1
    fi

    MANIFEST_TMP="$(mktemp)"
    printf '%s\n' "$MANIFEST" > "$MANIFEST_TMP"
}

# -------------------- 新轨（4.7 起）--------------------

CORE_TREE=""

stage_core_tree() {
    # 一次性把整棵 tag 取回来。成功则 CORE_TREE 指向解开的树，sync_tree 里逐个文件
    # 从它拷贝；失败（或压根不该走这条路）就留空，退回逐文件下载。
    #
    # 什么时候不走整包：BASE_URL 与 $CORE_URL/$MACWAVE_VERSION 不等，说明有人已经
    # 指定了另一处逐文件的树 —— 沙箱（file:// 镜像）与自建镜像都是这种形态。
    CORE_TREE=""
    if mw_dry_run; then
        mw_plan "🌊 Dry run: would fetch the whole $MACWAVE_VERSION tree as one archive." \
            "🌊 试运行：会把 ${MACWAVE_VERSION} 的整棵代码树当一个压缩包取回。"
        return 0
    fi
    [[ "$BASE_URL" == "$CORE_URL/$MW_CORE_REF" ]] || return 0

    local work archive
    work="$(mktemp -d)"
    archive="$work/core.tar.gz"
    mw_say "🌊 Fetching the $MACWAVE_VERSION tree (one archive, not 90 requests)..." \
           "🌊 正在取 ${MACWAVE_VERSION} 的整棵代码树（一个压缩包，不是 90 次请求）……"
    if mw_download "$CORE_ARCHIVE_URL" "$archive" 300 \
       && mkdir -p "$work/tree" \
       && tar -xzf "$archive" -C "$work/tree" --strip-components=1 2>/dev/null; then
        rm -f "$archive"
        CORE_TREE="$work/tree"
        return 0
    fi
    rm -rf "$work"
    mw_say "${YELLOW}🌊 Could not fetch the archive; falling back to per-file download.${RESET}" \
           "${YELLOW}🌊 整包取不到，退回逐文件下载。${RESET}"
    return 0
}

sync_tree() {
    # 按清单把安装树拉齐。**只下不一致的那些** —— 本地已有且 sha256 对得上的直接跳过，
    # 这就是「增量更新」：以前靠生成两张差异表（full / delta），现在靠比对。
    #
    # 每一条都必须是「下到了、校验过了、权限对了」才继续；任何一条失败就 exit，
    # 因为清单不齐的树会让 wave 起不来，而版本凭据还没写（写在那之后）。
    local path exec_flag expect_sha destination url digest
    local downloaded=0 kept=0 total=0
    # CORE_TREE 非空 = 整包已经解开，逐个文件从本地拷，不再发 90 次 HTTP。

    stage_core_tree

    while read -r path exec_flag expect_sha; do
        [[ -n "$path" ]] || continue
        total=$((total + 1))
        # 清单里的空格是 \  转义的（格式先定死，现无这种路径）
        path="${path//\\ / }"
        destination="$BASE_DIR/$path"
        # BASE_URL 就是「这一版的代码在哪」（= CORE_URL/${版本 tag}）。用它而不是
        # 自己拼：sandbox_test 只改 BASE_URL 这一行来指向离线镜像。
        url="$BASE_URL/$path"

        if [[ -f "$destination" && "$expect_sha" != "-" ]]; then
            digest="$(mw_sha256 "$destination")"
            if [[ "$digest" == "$expect_sha" ]]; then
                kept=$((kept + 1))
                # 已存在的文件也要确认权限：上一版可能把它当成数据文件发下来的
                if [[ "$exec_flag" == "1" && ! -x "$destination" ]]; then
                    run_cmd chmod +x "$destination"
                fi
                continue
            fi
        fi

        if mw_dry_run; then
            mw_plan "🌊   would download $path" "🌊   将下载 $path"
            continue
        fi

        mkdir -p "$(dirname -- "$destination")"
        if [[ -n "$CORE_TREE" && -f "$CORE_TREE/$path" ]]; then
            # 整包那条路上不打 90 行「Downloading x」—— 没有信息量，只是噪音。
            cp "$CORE_TREE/$path" "$destination"
        else
            mw_say "🌊 Downloading $path..." "🌊 正在下载 ${path}……"
            if ! mw_download "$url" "$destination" 60; then
            echo -e "${RED_BOLD}🌊 Error: cannot download $path.${RESET}" >&2
            echo -e "${RED_BOLD}🌊   $(mw_redact "$url")${RESET}" >&2
            echo -e "${RED_BOLD}🌊 If every file fails like this, the mirror has not synced $MACWAVE_VERSION yet.${RESET}" >&2
            echo -e "${RED_BOLD}🌊 Run scripts/mirror-sync/mirror-sync.sh on the mirror (see docs/MIRROR-SETUP.md).${RESET}" >&2
            install_failure_notice 1
            exit 1
        fi

        fi

        if [[ "$expect_sha" != "-" ]]; then
            digest="$(mw_sha256 "$destination")"
            if [[ "$digest" != "$expect_sha" ]]; then
                echo -e "${RED_BOLD}🌊 Error: $path does not match the published file list.${RESET}" >&2
                echo -e "${RED_BOLD}🌊   expected $expect_sha${RESET}" >&2
                echo -e "${RED_BOLD}🌊   got      ${digest:-<unreadable>}${RESET}" >&2
                echo -e "${RED_BOLD}🌊 The mirror copy is probably stale; re-run the mirror sync.${RESET}" >&2
                install_failure_notice 1
                exit 1
            fi
        fi

        if [[ "$exec_flag" == "1" ]]; then
            run_cmd chmod +x "$destination"
        fi
        downloaded=$((downloaded + 1))
    done < "$MANIFEST_TMP"

    if [[ "$kept" -gt 0 || "$downloaded" -gt 0 ]]; then
        mw_say "🌊 $downloaded file(s) downloaded, $kept already up to date (of $total)." \
               "🌊 已下载 ${downloaded} 个文件，${kept} 个已是最新（共 ${total} 个）。"
    fi

    prune_tree
}

# 清单管理的目录：只有这些目录里的文件会被 prune 删掉。
#
# 为什么要一张**写死在脚本里**的名单，而不是从清单里推：改名（lib/ → core/）之后
# 旧目录已经不在新清单里了，从清单推就永远推不到它 —— 而那正是必须删掉的东西。
# 加一个组件/资源目录时这里要跟着加一行；scripts/structure_test.sh 会盯着。
MANAGED_ROOTS="cli config lib net pkg surfboard man info Keys"

prune_tree() {
    # 声明式收敛：清单里没有的、但躺在清单管理目录里的文件，删掉。
    #
    # 为什么必须有这一步：`sync_tree` 只会覆盖与新增，从不删除。升级到文件集合
    # **变小**的版本（改名的模块、拆分的文件、换了目录）时，旧文件会留在原地。
    # 旧模块留在 lib/ 里就是「同一份代码有两个副本」，sys.path 一变就会跑到旧代码
    # 上 —— 这类故障看起来像「升级没生效」，实际是两份都在。
    #
    # 边界（宁可漏删，不可越界）：
    #   * 只碰上面 MANAGED_ROOTS 里的目录；Shore/（已装包）、var/（状态）、
    #     venv/、python/、downloads/ 一律不动。
    #   * 只删**不在清单里**的普通文件与符号链接；目录留着（空的也没关系）。
    #   * 清单里有的路径一律不删，哪怕哈希对不上（那是下面下载阶段的事）。
    local root keep line rest removed=0 file relative
    [[ -f "$MANIFEST_TMP" ]] || return 0

    keep="$(mktemp)"
    # 清单每行是 `<路径> <0|1> <sha 或 ->`。路径里若含空格，在清单里写成 `\ `，
    # 所以不能按空格切三段 —— 从**右边**剥两个字段，剩下的整体就是路径。
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        line="${line% }"
        line="${line% *}"          # 去掉 sha
        rest="${line% *}"          # 去掉 exec 标志
        [[ -n "$rest" ]] || continue
        printf '%s\n' "${rest//\\ / }"
    done < "$MANIFEST_TMP" | sort -u > "$keep"

    for root in $MANAGED_ROOTS; do
        [[ -d "$BASE_DIR/$root" ]] || continue
        while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            relative="${file#"$BASE_DIR"/}"
            if grep -qxF -- "$relative" "$keep"; then
                continue
            fi
            if mw_dry_run; then
                mw_plan "🌊   would remove $relative (no longer shipped)" \
                        "🌊   将删除 ${relative}（新版本已不再提供）"
                removed=$((removed + 1))
                continue
            fi
            if rm -f -- "$file"; then
                removed=$((removed + 1))
            else
                rm -f "$keep"
                echo -e "${RED_BOLD}🌊 Error: cannot remove $relative, which this version no longer ships.${RESET}" >&2
                echo -e "${RED_BOLD}🌊 Leaving it would let the old copy shadow the new one.${RESET}" >&2
                install_failure_notice 1
                exit 1
            fi
        done < <(find "$BASE_DIR/$root" \( -type f -o -type l \) 2>/dev/null)
    done
    rm -f "$keep"

    if [[ "$removed" -gt 0 ]]; then
        mw_say "🌊 Removed $removed file(s) this version no longer ships (renamed or dropped)." \
               "🌊 已删除 ${removed} 个新版本不再提供的文件（改名或已移除）。"
    fi
    return 0
}

# 清单只有一条来源：脚本自带的那些行。落到临时文件，供下面 sync_tree 逐条比对。
if ! mw_dry_run; then
    prepare_manifest
else
    mw_plan "🌊 Dry run: would download only the files that differ from the embedded list." \
        "🌊 试运行：将只下载与内嵌清单不一致的文件。"
fi

# ==========================================
# 创建目录
# ==========================================

# 0.1.0 起：bin/ 只放无版本号的软链接（4.x 的 links/ 并进来了），
# 解开的包与依赖都在 Shore/<名>/<版本>/，靠 Note 区分。
INSTALL_DIR="$BASE_DIR/bin"
LINKS_DIR="$INSTALL_DIR"
SHORE_DIR="$BASE_DIR/Shore"
REPO_DIR="$BASE_DIR/pkg"
SURFBOARD_DIR="$BASE_DIR/surfboard"
LIB_DIR="$BASE_DIR/lib"
NET_DIR="$BASE_DIR/net"
CLI_DIR="$BASE_DIR/cli"
# 程序代码目录。与 <base>/var（状态）不是一回事，变量名必须能一眼分开。
CONFIG_CODE_DIR="$BASE_DIR/config"
# 文档资源：装进安装树，但不进 sys.path（见 scripts/assets.txt）
MAN_DIR="$BASE_DIR/man"
INFO_DIR="$BASE_DIR/info"
# 发布签名用的公钥。装进来之后 <base_dir>/Keys/*.asc 就是验签的信任根，
# 用户不必再去官网另找一份（那一步恰恰最容易被换掉）。
KEYS_DIR="$BASE_DIR/Keys"
DEPS_DIR="$SHORE_DIR"
DOWNLOAD_DIR="$BASE_DIR/downloads/tmp"

# 状态：一棵树一份，就在树里。<base>/var/config.sh 记版本号与构建号，
# 没有 config.json、没有外部配置目录（见 config/configpaths.py）。
STATE_DIR="$BASE_DIR/var"
STATE_FILE="$STATE_DIR/config.sh"
MW_OPTIONAL_RESULT=""

mw_try() {
    # mw_try <命令...>：跑一个「失败也无所谓」的命令，stdout 存进 MW_OPTIONAL_RESULT。
    # 失败时不惊动 ERR trap —— 否则用户会先看到「Installation did not finish」，
    # 几百行之后再看到「Installation complete!」，比不提示更糟。
    #
    # 旗标必须在**命令替换的整个生命周期内**保持设置：`set -E` 让 ERR trap 传进
    # 子 shell，而子 shell 退出时如果那条命令返回非零，trap 照样会响。所以赋值写进
    # 本函数内部，而不是让调用方写 `X="$(mw_try ...)"`。
    local output
    MW_FAILURE_HANDLED=1
    output="$("$@")" && MW_OPTIONAL_RESULT="$output" || MW_OPTIONAL_RESULT=""
    unset MW_FAILURE_HANDLED
    return 0
}

# 中途失败时给出明确指引。刻意**不自动删除**已下载的内容：升级安装时
# 删掉安装树会把用户原有的可用安装一起毁掉，重跑安装器才是安全的做法。
install_failed() {
    local code=$?

    # 有些失败是**预期之内**的：自带解释器取不到时会回落到系统 python3，
    # 安装照常完成。那些地方用 mw_optional 包着，会临时立这个旗标，
    # 于是这里不报「安装未完成」—— 否则用户看到的是「安装失败」接着
    # 「Installation complete!」，比没有提示更糟。
    if [[ -n "${MW_FAILURE_HANDLED:-}" ]]; then
        return 0
    fi

    install_failure_notice "$code"
}
trap install_failed ERR

# Linux 上先把 /home/linuxwave 准备好（建账户、开权限），再往里建树 ——
# 反过来的话 mkdir -p 会以 root 建出一个属主不对的家目录。
prepare_linux_shared_account

run_cmd mkdir -p "$INSTALL_DIR"
run_cmd mkdir -p "$LINKS_DIR"
run_cmd mkdir -p "$SHORE_DIR"
run_cmd mkdir -p "$REPO_DIR"
run_cmd mkdir -p "$SURFBOARD_DIR"
run_cmd mkdir -p "$LIB_DIR"
run_cmd mkdir -p "$NET_DIR"
run_cmd mkdir -p "$CLI_DIR"
run_cmd mkdir -p "$CONFIG_CODE_DIR"
run_cmd mkdir -p "$MAN_DIR/man1"
run_cmd mkdir -p "$INFO_DIR"
run_cmd mkdir -p "$KEYS_DIR"
run_cmd mkdir -p "$DEPS_DIR"
run_cmd mkdir -p "$DOWNLOAD_DIR"
run_cmd mkdir -p "$STATE_DIR"

# 状态文件（<base>/var/config.sh）不在这里写：它是「装好了」的凭据，必须等
# 文件真的下完才落盘 —— 见下面「写入版本凭据」一节。

# ==========================================
# ==========================================
# 同步文件
# ==========================================
#
# 按清单里逐条的 sha256 比对，只下不一致的那些 —— 这就是「增量更新」：以前靠生成
# 两张差异表（full / delta），现在靠比对。逻辑全在本文件里，没有「下载一段代码去
# 执行」这回事。

if mw_dry_run; then
    mw_plan "🌊 Dry run: would download the files that differ from the list." \
        "🌊 试运行：将下载与清单不一致的文件。"
else
    sync_tree
fi

# ==========================================
# 写入版本凭据（必须在文件全部到位之后）
# ==========================================
# 顺序不能反：这份文件是客户端判断「装没装好、要不要再修」的唯一依据。先写它、
# 后下载，中途失败就会留下「版本号前进、文件还是旧的」这种最难查的状态 ——
# `wave selfupdate` 比完版本号就说已是最新，永远不会再修。
#
# 一棵树只有这一份状态：<base>/var/config.sh。用 .sh 而不是 JSON 的理由见
# config/configpaths.py 里 STATE_FILE_NAME 那段注释：shell 写它是一行 heredoc。
# MACWAVE_INSTALLED_AT 只给人看（排查「这台机器什么时候装的」），代码不读它。
if ! mw_dry_run; then
    run_cmd tee "$STATE_FILE" > /dev/null << EOF
# Summerwave state file —— 由 install.sh / selfupdate.sh 生成，会被覆盖。
# 不要手工编辑：版本号在这里，升级用 wave selfupdate。
MACWAVE_VERSION='$MACWAVE_VERSION'
$( [[ -n "$BUILD_NUMBER" ]] && printf "MACWAVE_BUILD='%s'\n" "$BUILD_NUMBER" )
MACWAVE_CHANNEL='$MW_CHANNEL'
MACWAVE_INSTALLED_AT='$(date -u +%Y-%m-%dT%H:%M:%SZ)'
EOF
    run_cmd chmod "$(state_file_mode)" "$STATE_FILE"
    mw_say "🌊 Version saved to $STATE_FILE" "🌊 版本信息已保存到 $STATE_FILE"

    if [[ "$NEED_HANDOVER" == "true" ]]; then
        hand_over_system_install "$BASE_DIR"
    fi
fi

# ==========================================
# Python 运行环境（私有 venv + 启动器）
# ==========================================

# 为什么不用 PATH 上的 python3 直接当入口：
#   macOS 上 `python3` 可能指向 Homebrew 管理的版本，升级一次就换了路径，
#   而第三方依赖仍留在旧版本的 site-packages 里。入口写死 `#!/usr/bin/env python3`
#   就会在升级后全线报错（3.0.5 之前真实发生过）。
#
# 做法：
#   1. 在安装根目录建私有 venv，把 requests / packaging / rich 装进去；
#   2. lib/wave 变成一个 sh 启动器，按「venv → 安装时的解释器 → PATH」顺序挑选，
#      并且只有能真正 import 到三个依赖时才使用。
#
# 这样系统 Python 怎么升都不会影响已安装的 MacWave。

# 再交一次：上面那段更新脚本是带 sudo 跑的，可能又留下 root 属主的文件。
if [[ "$NEED_SUDO" == "true" ]]; then
    lend_tree_to_user "$BASE_DIR"
fi

# ==========================================
# 便携 Python（自带解释器）
# ==========================================
#
# 为什么自带：用户机器上的 python3 由 Homebrew / pyenv / 系统自带的版本轮流接管，
# 升级一次就可能换掉解释器，而第三方依赖仍留在旧版本里 —— 3.0.5 之前真实发生过
# 一次「系统 Python 从 3.14 升到 3.15，所有命令都报模块缺失」。
#
# 自带之后，「用哪个解释器」由 MacWave 自己决定，报错也就能稳定复现。
# 版本、文件名、sha256 与 asset id 都由 build_installer.py 注入（config/portable_python.toml）。
# 下载失败（网络问题）时回退到系统 python3，安装不会因此中断。

portable_python_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo "arm64" ;;
        x86_64|amd64)  echo "amd64" ;;
        *)             echo "" ;;
    esac
}

portable_python_binary() {
    # 不同构建产物的目录布局不同，这里按常见位置逐个试探。
    local root="$1" candidate
    for candidate in \
        "$root/install/bin/python3" \
        "$root/bin/python3" \
        "$root/python/install/bin/python3" \
        "$root/python/bin/python3"
    do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    candidate="$(find "$root" -maxdepth 4 -type f \( -name 'python3' -o -name 'python3.*' \) -perm -u+x 2>/dev/null | head -n 1)"
    if [[ -n "$candidate" ]]; then
        echo "$candidate"
        return 0
    fi
    return 1
}

normalize_portable_python() {
    # 把各种布局归一化成 <target>/bin/python3。
    #
    # 启动器只认 python/current/bin/python3，而上游 install_only 产物把解释器放在
    # python/install/bin/python3 —— 不归一化的话，自带解释器在启动器第 2 层永远命中不了，
    # 只有第 1 层的私有 venv 能救场；venv 一旦坏掉就等于没有自带解释器。
    local target="$1"
    local py="$2"
    local link="$target/bin/python3"
    local relative

    mkdir -p "$target/bin" 2>/dev/null || return 0
    if [[ "$py" == "$link" ]]; then
        return 0
    fi
    if [[ "$py" != "$target"/* ]]; then
        return 0
    fi

    # 用相对链接：整个 python/ 目录搬走以后仍然有效
    relative="../${py#"$target"/}"
    ln -sfn "$relative" "$link" 2>/dev/null || true
    return 0
}

portable_python_asset() {
    # 按 <os>-<arch> 输出「asset_id sha256 文件名」三件套。
    #
    # 三个值都是构建 install.sh 时注入的：scripts/build_installer.py 现查一次
    # GitHub Release 拿到 asset id（那个值不稳定，重建 Release 会换一批），再连同
    # sha256 与文件名写进脚本。运行时因此不解析 JSON、也不发第二次请求。
    # 数据来源是 config/portable_python.toml —— 便携解释器的唯一来源。
    case "$1" in
        macos-arm64) echo "${MACWAVE_PYTHON_MACOS_ARM64_ID:-} ${MACWAVE_PYTHON_MACOS_ARM64_SHA256:-} ${MACWAVE_PYTHON_MACOS_ARM64_NAME:-}" ;;
        macos-amd64) echo "${MACWAVE_PYTHON_MACOS_AMD64_ID:-} ${MACWAVE_PYTHON_MACOS_AMD64_SHA256:-} ${MACWAVE_PYTHON_MACOS_AMD64_NAME:-}" ;;
        linux-arm64) echo "${MACWAVE_PYTHON_LINUX_ARM64_ID:-} ${MACWAVE_PYTHON_LINUX_ARM64_SHA256:-} ${MACWAVE_PYTHON_LINUX_ARM64_NAME:-}" ;;
        linux-amd64) echo "${MACWAVE_PYTHON_LINUX_AMD64_ID:-} ${MACWAVE_PYTHON_LINUX_AMD64_SHA256:-} ${MACWAVE_PYTHON_LINUX_AMD64_NAME:-}" ;;
        *) return 1 ;;
    esac
}

ensure_portable_python() {
    # 成功时把解释器路径打到 stdout，失败返回 1（调用方回退系统 python3）。
    #
    # 只从 api.github.com 的 Release 资产取，不走 raw.githubusercontent.com ——
    # 那个域名在校园网与家宽上十次有三次连不上，而这里是 25–35 MB 的一次性下载，
    # 挂掉就等于整套依赖退回系统 site-packages。api 那条路会 302 到 CDN，
    # 实测 5 MB/s。
    local base_dir="$1"
    local arch="$2"
    local platform version id sha filename url target current archive actual py

    [[ -n "$arch" ]] || return 1
    version="${MACWAVE_PYTHON_VERSION:-}"
    # 模板（沙箱里跑的那份）没有注入，直接让调用方回退系统 python3
    [[ -n "$version" ]] || return 1

    platform="$(mw_platform)-$arch"
    read -r id sha filename <<<"$(portable_python_asset "$platform")" || return 1
    [[ -n "$id" && -n "$sha" && -n "$filename" ]] || return 1

    target="$base_dir/python/$version"
    current="$base_dir/python/current"

    # 已经有一份能跑的同版本解释器：一个字节都不下
    if py="$(portable_python_binary "$target" 2>/dev/null)" \
       && "$py" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
        echo "$py"
        return 0
    fi

    archive="$base_dir/downloads/tmp/portable-python-$version.tar.gz"
    mkdir -p "$base_dir/downloads/tmp" 2>/dev/null || true

    mw_say_err "🌊 Downloading the bundled Python $version (about 26 MB)..." \
        "🌊 正在下载自带 Python ${version}（约 26 MB）……"

    # 两种寻址，不能合并：GitHub 的资产接口只认 asset id（还要 octet-stream
    # 那个 header），而静态镜像只认文件名。设了 SUMMERWAVE_PYTHON_DOMAIN 就走
    # <域名>/<文件名>，镜像站把四个 tar.gz 摊平放好即可。
    python_domain="$(mw_domain SUMMERWAVE_PYTHON_DOMAIN "${SUMMERWAVE_PYTHON_DOMAIN:-}")"
    if [[ -n "$python_domain" ]]; then
        url="$python_domain/$filename"
        if ! mw_download "$url" "$archive" 900; then
            echo -e "${YELLOW}🌊 Could not download the bundled Python from $(mw_redact "$url")${RESET}" >&2
            return 1
        fi
    else
        url="https://api.github.com/repos/${MACWAVE_PYTHON_REPO:-SummerwaveOrg/Python}/releases/assets/$id"
        # Accept: application/octet-stream 是必须的：少了它 api 会返回 JSON 元数据
        if ! mw_download "$url" "$archive" 900 "Accept: application/octet-stream"; then
            echo -e "${YELLOW}🌊 Could not download the bundled Python from $(mw_redact "$url")${RESET}" >&2
            return 1
        fi
    fi

    actual="$(mw_sha256 "$archive")"
    if [[ "$actual" != "$sha" ]]; then
        rm -f "$archive"
        echo -e "${RED_BOLD}🌊 Error: the bundled Python download failed its checksum check.${RESET}" >&2
        return 1
    fi

    mkdir -p "$target" 2>/dev/null || true
    if ! tar -xzf "$archive" -C "$target" 2>/dev/null; then
        rm -f "$archive"
        return 1
    fi
    rm -f "$archive"

    py="$(portable_python_binary "$target" 2>/dev/null)" || return 1
    if ! "$py" -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
        return 1
    fi
    normalize_portable_python "$target" "$py"

    mkdir -p "$base_dir/python" 2>/dev/null || true
    ln -sfn "$version" "$current" 2>/dev/null || true
    echo "$py"
    return 0
}

VENV_DIR="$BASE_DIR/venv"
VENV_PY=""
PYTHON_BIN=""
PYTHON_SOURCE=""

if mw_dry_run; then
    # 试运行不联网：直接给出「本该由哪一份解释器来跑」，让输出与真实安装同形。
    PYTHON_BIN="<bundled python>"
    PYTHON_SOURCE="bundled"
    mw_plan "🌊 Dry run: would check the bundled Python and download it when missing (about 26 MB)." \
        "🌊 试运行：将检查自带 Python，缺失时下载（约 26 MB）。"
    mw_plan "🌊   Destination: $BASE_DIR/python/<version>/bin/python3" \
        "🌊   目标位置：${BASE_DIR}/python/<版本>/bin/python3"
else
    mw_try ensure_portable_python "$BASE_DIR" "$(portable_python_arch)"
    BUNDLED_PY="$MW_OPTIONAL_RESULT"
    if [[ -n "$BUNDLED_PY" ]]; then
        PYTHON_BIN="$BUNDLED_PY"
        PYTHON_SOURCE="bundled"
        mw_say "🌊 Using the bundled Python: ${BUNDLED_PY#"$BASE_DIR"/}" "🌊 使用自带的 Python：${BUNDLED_PY#"$BASE_DIR"/}"
    else
        PYTHON_BIN="$(command -v python3 || true)"
        PYTHON_SOURCE="system"
        if [[ -z "$PYTHON_BIN" ]]; then
            echo -e "${RED_BOLD}🌊 Error: no Python 3 interpreter is available.${RESET}"
            echo -e "${RED_BOLD}🌊 The bundled Python could not be downloaded and python3 is not in PATH.${RESET}"
            exit 1
        fi
        echo -e "${YELLOW}🌊 Warning: could not prepare the bundled Python; using $PYTHON_BIN instead.${RESET}"
        echo -e "${YELLOW}🌊 Re-run the installer when the network is available to make this installation self-contained.${RESET}"
    fi
fi

# 自带解释器拿不到时（离线安装、下载失败）会回退到系统 python3。**如果它本来就能
# import 三个依赖，就不该再建 venv 去 pip 一遍** —— 那一步只会因为没网而失败，而失败
# 之后我们仍然要用这个解释器：白白把一次能成的安装变成 exit 1（离线机器上必然如此）。
# 跳过 venv 之后，启动器会落到第二选择（安装时烘进去的解释器），行为一致。
SKIP_VENV=false
if [[ "$PYTHON_SOURCE" == "system" ]] \
    && "$PYTHON_BIN" -c 'import requests, packaging, rich' >/dev/null 2>&1; then
    SKIP_VENV=true
fi

if mw_dry_run; then
    mw_plan "🌊 Dry run: would create the private Python environment at $VENV_DIR." \
        "🌊 试运行：将在 ${VENV_DIR} 创建独立的 Python 环境。"
elif [[ "$SKIP_VENV" == "true" ]]; then
    mw_say "🌊 Using $PYTHON_BIN directly (it already has requests, packaging, rich)." \
        "🌊 直接使用 ${PYTHON_BIN}（它已自带 requests、packaging、rich）。"
    mw_say "🌊 No private environment is created; the bundled Python was not available." \
        "🌊 未创建独立环境：自带 Python 没能就位。"
else
    mw_say "🌊 Creating the private Python environment..." "🌊 正在创建独立的 Python 环境……"
    mkdir -p "$VENV_DIR" 2>/dev/null || true

    if "$PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null 2>&1; then
        VENV_PY="$VENV_DIR/bin/python3"
        [[ -x "$VENV_PY" ]] || VENV_PY="$VENV_DIR/bin/python"
        mw_say "🌊 Private Python environment ready: ${VENV_DIR#"$BASE_DIR"/}" "🌊 独立 Python 环境已就绪：${VENV_DIR#"$BASE_DIR"/}"
    else
        echo -e "${YELLOW}🌊 Warning: could not create a private virtualenv; using the ${PYTHON_SOURCE} interpreter directly.${RESET}"
    fi
fi

# pip 的公共参数。--index-url 指向 MACWAVE_PIP_INDEX（默认官方 PyPI）；
# 国内直连 pypi.org 常超时，用户可以把它换成本地镜像。
PIP_DEPS=(requests packaging urllib3 rich)
PIP_FLAGS=(--quiet --disable-pip-version-check --timeout 30 --retries 2
           --index-url "$PIP_INDEX_URL")

if mw_dry_run; then
    mw_plan "🌊 Dry run: would install ${PIP_DEPS[*]} into the private environment (index: $PIP_INDEX_URL)." \
        "🌊 试运行：将把 ${PIP_DEPS[*]} 装进独立环境（索引：${PIP_INDEX_URL}）。"
elif [[ "$SKIP_VENV" == "true" ]]; then
    # 依赖已经在用着的解释器里，pip 这一步没有意义（离线时还会失败）。
    mw_say "🌊 Python dependencies already available; nothing to install." \
        "🌊 Python 依赖已就绪，无需安装。"
elif [[ -n "$VENV_PY" && -x "$VENV_PY" ]]; then
    mw_say "🌊 Installing Python dependencies into the private environment..." "🌊 正在向独立环境安装 Python 依赖……"
    # pip 默认会无限等下去，网络不好时看上去就是卡死。给它超时与重试，
    # 并说明这一步可能要一会儿，免得用户以为程序挂了。
    mw_say "🌊 Installing Python dependencies into the private environment (this can take a minute)..." "🌊 正在向独立环境安装 Python 依赖（可能需要一分钟）……"
    "$VENV_PY" -m pip install "${PIP_FLAGS[@]}" --upgrade pip >/dev/null 2>&1 || true
    if ! "$VENV_PY" -m pip install "${PIP_FLAGS[@]}" "${PIP_DEPS[@]}"; then
        echo -e "${RED_BOLD}🌊 Error: failed to install the Python dependencies.${RESET}"
        echo -e "${RED_BOLD}🌊 Index used: $PIP_INDEX_URL${RESET}"
        echo -e "${RED_BOLD}🌊 Set MACWAVE_PIP_INDEX to a reachable mirror and try again,${RESET}"
        echo -e "${RED_BOLD}🌊 or install them manually into $VENV_PY.${RESET}"
        exit 1
    fi
else
    mw_say "🌊 Installing Python dependencies into $PYTHON_BIN..." "🌊 正在向 $PYTHON_BIN 安装 Python 依赖……"
    if ! "$PYTHON_BIN" -m pip install "${PIP_FLAGS[@]}" "${PIP_DEPS[@]}" 2>/dev/null; then
        if ! "$PYTHON_BIN" -m pip install "${PIP_FLAGS[@]}" --user --break-system-packages "${PIP_DEPS[@]}"; then
            echo -e "${RED_BOLD}🌊 Error: failed to install the Python dependencies.${RESET}"
            echo -e "${RED_BOLD}🌊 Index used: $PIP_INDEX_URL${RESET}"
            echo -e "${RED_BOLD}🌊 Set MACWAVE_PIP_INDEX to a reachable mirror and try again.${RESET}"
            exit 1
        fi
    fi
fi

# 生成入口启动器：把当前解释器路径烘进去，作为 venv 失效时的第二选择。
write_launcher() {
    local base_dir="$1"
    local recorded="$2"
    local target="$base_dir/lib/wave"
    local tmp

    if mw_dry_run; then
        mw_plan "🌊 Dry run: would write the launcher $target." \
            "🌊 试运行：将写入启动器 ${target}。"
        return 0
    fi

    tmp="$(mw_mktemp macwave-launcher)"

    cat > "$tmp" <<'LAUNCHER'
#!/bin/sh
# MacWave launcher
# 由 install.sh / selfupdate.sh 生成，会被覆盖，请不要手工编辑。
#
# 选择一个**真正能 import 到依赖**的解释器来运行 lib/wave.py：
#   1. 安装根目录下的私有 venv（与系统 Python 升级完全解耦）
#   2. 生成这个启动器时的解释器路径
#   3. PATH 上的 python3（最后兜底，wave.py 会给出缺少哪个依赖）

set -u

# 解析自身真实路径（可能经由 PATH 上的符号链接调用）
self="$0"
while [ -L "$self" ]; do
    link="$(readlink "$self")"
    case "$link" in
        /*) self="$link" ;;
        *)  self="$(dirname "$self")/$link" ;;
    esac
done
lib_dir="$(cd -- "$(dirname -- "$self")" && pwd)" || exit 1
root_dir="$(cd -- "$lib_dir/.." && pwd)" || exit 1
entry="$lib_dir/wave.py"

# `wave shellenv` 由 shell 直接回答，不启动 Python：这一行会被写进 ~/.zprofile，
# 每次开终端都要跑（走 Python 那条路实测 160ms，这里 2ms）。
# 输出必须与 lib/shellenv.py **逐字一致** —— scripts/shellenv_test.sh 会比对两份。
if [ "$#" -eq 1 ] && [ "$1" = "shellenv" ]; then
    printf 'case ":$PATH:" in\n  *":%s:"*) ;;\n  *) export PATH="%s:%s${PATH:+:$PATH}" ;;\nesac\n' \
        "$root_dir/lib" "$root_dir/bin" "$root_dir/lib"
    printf 'case ":${MANPATH:-}:" in\n  *":%s:"*) ;;\n  *) export MANPATH="%s${MANPATH:+:$MANPATH}" ;;\nesac\n' \
        "$root_dir/man" "$root_dir/man"
    exit 0
fi

# 双语错误输出。启动器里没有 install.sh 的 mw_say/mw_say_err，所以自带一个最小实现：
# 之前 install.sh 生成的启动器直接调用 mw_say_err，一旦真的落到这个分支就是
# 「mw_say_err: command not found」，真正的错误信息反而看不见。
mw_say_err() {
    printf '%s\n' "$1" >&2
    printf '%s\n' "$2" >&2
}

#__MACWAVE_PYTHON__

deps_ok() {
    [ -x "$1" ] || return 1
    "$1" -c 'import requests, packaging, rich' >/dev/null 2>&1
}

# 1. 私有 venv（正常情况下就是它；由自带 Python 创建）
if deps_ok "$root_dir/venv/bin/python3"; then
    exec "$root_dir/venv/bin/python3" "$entry" "$@"
fi
if deps_ok "$root_dir/venv/bin/python"; then
    exec "$root_dir/venv/bin/python" "$entry" "$@"
fi

# 2. 自带的便携 Python（venv 坏掉时的第一选择；它自己也可以带依赖）
if [ -x "$root_dir/python/current/bin/python3" ] && deps_ok "$root_dir/python/current/bin/python3"; then
    exec "$root_dir/python/current/bin/python3" "$entry" "$@"
fi

# 3. 安装时记录的系统解释器
if [ -n "${MACWAVE_PYTHON:-}" ] && deps_ok "$MACWAVE_PYTHON"; then
    exec "$MACWAVE_PYTHON" "$entry" "$@"
fi

# 4. 最后才用 PATH 上的 python3（wave.py 会明确指出缺哪个依赖）
if command -v python3 >/dev/null 2>&1; then
    exec python3 "$entry" "$@"
fi

mw_say_err "🌊 Error: no usable Python 3 interpreter was found." "🌊 错误：找不到可用的 Python 3 解释器。"
mw_say_err "🌊 Reinstall Summerwave with lib/install.sh." "🌊 请用 lib/install.sh 重新安装 Summerwave。"
exit 1
LAUNCHER

    local escaped rendered
    escaped="$(printf '%s' "$recorded" | sed 's/[\\"`$]/\\&/g')"

    # 内容先在普通权限下生成，只有落地那几步才可能需要提权。
    # 调用本函数时**不能**写 run_cmd write_launcher：sudo 无法执行 shell 函数，
    # 会遇到 "sudo: write_launcher: command not found"。
    rendered="$(mw_mktemp macwave-launcher-out)"
    sed "s|#__MACWAVE_PYTHON__|MACWAVE_PYTHON=\"$escaped\"|" "$tmp" > "$rendered"
    rm -f "$tmp"

    run_cmd mkdir -p "$(dirname "$target")"
    run_cmd cp "$rendered" "$target"
    run_cmd chmod 755 "$target"
    rm -f "$rendered"
}

write_launcher "$BASE_DIR" "$PYTHON_BIN"

# ==========================================
# 把所有权交还给用户（下载后再次确保）
# ==========================================

if [[ "$NEED_HANDOVER" == "true" ]]; then
    hand_over_system_install "$BASE_DIR"
fi

# ==========================================
# PATH：只给方法，不改用户的 shell 配置
# ==========================================
#
# 以前这里是直接把 PATH 行 append 进 rc 文件。改成「只打印、不动手」，理由：
#   - 卸载要把它摘掉，只能靠字符串匹配去猜，猜错就是删掉别人的行；
#   - 安装目录变了、版本升级了，用户文件里留的是旧路径，而安装器没法判断
#     那一行还是不是自己写的；
#   - Homebrew / MacPorts 都是「一行 eval 归用户自己管」，升级与卸载都不用碰
#     别人的文件。
#
# 推荐写 ~/.zprofile 而不是 ~/.zshrc：PATH 是**登录**级的东西。.zprofile 每个
# 登录 shell 跑一次（新开一个终端窗口就是一次），.zshrc 每个交互 shell 都跑
# 一次 —— 套一层 `zsh -l` 就会再 prepend 一遍，PATH 一路堆叠。而且 .zshrc 在
# 非交互 shell 里根本不读，所以只写 .zshrc 的 PATH 对 `ssh host cmd`、
# cron、部分编辑器/IDE 起的子进程是看不见的。
# bash 的对应文件是 ~/.bash_profile —— 注意**不是** ~/.bashrc：
# macOS 的 bash 登录 shell 从不读 .bashrc（旧版这里写的就是 .bashrc，等于没写）。

# 按**登录** shell 选择它真正会读的那个文件（macOS 终端默认起登录 shell）：
#
#   zsh             → ~/.zprofile
#   bash            → ~/.bash_profile
#   sh/dash/ksh     → ~/.profile
#   csh/tcsh        → ~/.login
#
# 这四条都在本机逐壳实测过（`<shell> -l -c true` 看它读了哪个文件）。
# csh 系绝不能落到 ~/.profile —— 它根本不读那个文件，写了等于没写。
SHELL_FAMILY=posix
case "${SHELL:-}" in
    *zsh*)  RC_FILE="$HOME/.zprofile" ;;
    *bash*) RC_FILE="$HOME/.bash_profile" ;;
    *csh*)
        # macOS 的 /bin/csh 其实是 tcsh，登录时读 ~/.tcshrc 再读 ~/.login
        RC_FILE="$HOME/.login"
        SHELL_FAMILY="csh"
        ;;
    *)      RC_FILE="$HOME/.profile" ;;
esac

# 旧版本写进 rc 的完整 PATH 行；现在只用于两件事：识别用户文件里是否已有旧写法，
# 以及回滚时把指向已删除目录的那一行摘掉。
PATH_LINE="export PATH=\"$INSTALL_DIR:$LINKS_DIR:$LIB_DIR:\$PATH\""

# 建议用户自己加进 rc 的那一行 —— 与 Homebrew 同形：
#
#   eval "$(/opt/homebrew/bin/brew shellenv)"
#
# 路径里没有空格时**不加内层引号**，与 Homebrew 逐字同形；含空格（自定义目录
# 允许空格）时才加，否则那一行会被拆成两条命令。
#
# 家目录写成 ~（安装到 $HOME/.local/macwave 时）。`$( )` 里是新的引号上下文，
# 所以 `eval "$(~/…/wave shellenv)"` 里的 ~ 会正常展开；写成 `"~/…"` 则不会。
#
# 去掉 4.3 之前的 `test -r ... &&` 守卫：代价是安装目录被删掉后每次登录报一次
# "no such file or directory"，Homebrew 一直如此，换来的是用户只需照抄一行。
#
# csh/tcsh 走另一条分支：它们没有 `$(...)`，也没有 POSIX 的 case…esac，
# `wave shellenv` 的输出它们吃不下（实测报 "Too many )'s"），所以给等价的
# csh 写法。守卫改成 `!~` 模式匹配，作用相同 —— 已在 csh 与 tcsh 上实测连跑
# 三次不堆叠。
#
# 这里的字符串会被用户原样复制，所以 ~ 后面含空格的片段要写成 ~/"a b"。
INSTALL_DIR_DISPLAY=$(home_to_tilde_arg "$INSTALL_DIR")
LINKS_DIR_DISPLAY=$(home_to_tilde_arg "$LINKS_DIR")
LIB_DIR_DISPLAY=$(home_to_tilde_arg "$LIB_DIR")
if [[ "$SHELL_FAMILY" == "csh" ]]; then
    # csh 的双引号里 ~ 不展开，而守卫模式又必须对展开后的 $PATH 生效，只能写 $HOME
    # （它在双引号内会展开）：输出里没有绝对家目录，只是用 $HOME 代替了 ~。
    SHELLENV_DISPLAY="if ( \"\$PATH\" !~ *\"$(home_to_homevar "$LIB_DIR")\"* ) setenv PATH \"$(home_to_homevar "$INSTALL_DIR"):$(home_to_homevar "$LIB_DIR"):\$PATH\""
else
    SHELLENV_DISPLAY="eval \"\$($LIB_DIR_DISPLAY/wave shellenv)\""
fi

# 从 rc 文件里摘掉**旧版本**写进去的 PATH 行（连同标记行）。
# 现在安装不再写 rc，这个函数只剩两个用途：升级时清理旧写法、回滚时清掉
# 指向已删除目录的那一行。
#
# 标记行必须**整行相等**才算：旧实现用 `grep -F "# MacWave"` 做子串匹配，
# 会把用户自己的 `# MacWave mirror` 注释行一起删掉 —— 那是读者的配置，不是我们的。
remove_lw_path_entries() {
    local rc="$1"
    [[ -f "$rc" ]] || return 0
    grep -qF -e "$PATH_LINE" -e "# MacWave" "$rc" 2>/dev/null || return 0
    grep -v -F -e "$PATH_LINE" "$rc" | grep -v -x -F -e "# MacWave" > "$rc.macwave.tmp" || true
    cat "$rc.macwave.tmp" > "$rc"
    rm -f "$rc.macwave.tmp"
    mw_say "🌊 Removed old PATH entries from $rc" "🌊 已从 $rc 移除旧版留下的 PATH 条目"
}

# 当前进程的 PATH 里是否已经有 MacWave。看运行环境而不是解析 rc 文件：
# rc 里的写法五花八门（手写 export、shellenv、别名），解析必然漏。
path_has_macwave() {
    case ":$PATH:" in
        *":$LIB_DIR:"*|*":$LINKS_DIR:"*) return 0 ;;
    esac
    return 1
}

# 用户自己的 shell 配置里是否还留着**旧版本**写进去的条目。
#
# 只认两行：整行等于 `# MacWave` 标记行，或整行等于旧写法的那条 export。
# 不能拿 `$LIB_DIR` 做子串匹配 —— 新的 `eval "$(... shellenv)"` 里也有这个路径，
# 那会把「已经迁移好的用户」误判成「还需要迁移」。
#
# 找到只用于**生成一条迁移命令**，安装器自己不动那个文件。
EXISTING_RC=""
for _rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zprofile" "$HOME/.profile"; do
    [[ -f "$_rc" ]] || continue
    if grep -qxF -e "# MacWave" -e "$PATH_LINE" "$_rc" 2>/dev/null; then
        EXISTING_RC="$_rc"
        break
    fi
done

# ==========================================
# 完成信息
# ==========================================

echo ""
if mw_dry_run; then
    mw_say "${GREEN}🌊 Dry run finished. Nothing was installed or changed.${RESET}" \
        "${GREEN}🌊 试运行结束。没有安装或修改任何内容。${RESET}"
    mw_say "🌊 Summerwave would be installed to: $DISPLAY_DIR" "🌊 Summerwave 将被安装到：$DISPLAY_DIR"
    # 装饰与艺术字同一条规矩：--raw 是给日志和 grep 看的，逐字去掉。
    if ! mw_raw; then
        echo ""
        echo -e "${SKY_BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${RESET}"
        echo ""
        echo -e "${SKY_BLUE}                  (DRY_RUN)The tide rises, the tide falls...                    ${RESET}"
        echo ""
        echo -e "${SKY_BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${RESET}"
    fi
elif [[ "$SELFUPDATE_MODE" == "true" ]]; then
    # 升级：不重复「安装完成」那套说明（PATH、其他用户、管理员权限都没变），
    # 只报一句结果。这些提示是第一次装的人要看的，升级时纯属噪音。
    mw_say "🌊 Summerwave updated to $MACWAVE_VERSION." "🌊 Summerwave 已更新到 ${MACWAVE_VERSION}。"
    mw_say "🌊 Installation directory: $DISPLAY_DIR" "🌊 安装目录：${DISPLAY_DIR}"
    exit 0
else
    mw_say "🌊 Installation complete!" "🌊 安装完成！"
    mw_say "🌊 Summerwave installed to: $DISPLAY_DIR" "🌊 Summerwave 已安装到：$DISPLAY_DIR"
    # 打印诗句（--raw 时同样跳过）
    if ! mw_raw; then
        echo -e "${SKY_BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${RESET}"
        echo ""
        echo -e "${SKY_BLUE}                       The tide rises, the tide falls...                        ${RESET}"
        echo ""
        echo -e "${SKY_BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${RESET}"
    fi
fi

echo
mw_say "🌊 Architecture: $ARCH" "🌊 架构：$ARCH"
echo ""
RC_DISPLAY=$(home_to_tilde_arg "$RC_FILE")
APPEND_CMD="echo '$SHELLENV_DISPLAY' >> $RC_DISPLAY"

# 有旧条目时，把「删旧」和「追加新行」拼成**一条**命令：用户复制一次就够。
#
# 删旧的判据与 remove_lw_path_entries 一致 —— 整行相等（-x -F），不是子串匹配；
# 旧实现用 `grep -F "# MacWave"` 做子串，会把用户自己写的 `# MacWave mirror`
# 注释一并删掉。
#
# 先写临时文件再 `cat >` 回写，而不是 `mv` 或 `sed -i`：~/.zshrc 常是指向
# dotfiles 仓库的符号链接，rename 会把它变成普通文件，链接就断了。
MIGRATE_CMD=""
if [[ -n "$EXISTING_RC" ]]; then
    EXISTING_DISPLAY=$(home_to_tilde_arg "$EXISTING_RC")
    # 这一条里的旧 PATH 行是 **grep 的匹配模式**，必须与 rc 文件里那行逐字相等，
    # 所以不能写 ~（引号内不展开），改用双引号包起来让 $HOME 自己展开。
    PATH_LINE_DISPLAY=$(printf 'export PATH=\\"%s:%s:%s:\\$PATH\\"' \
        "$(home_to_homevar "$INSTALL_DIR")" "$(home_to_homevar "$LINKS_DIR")" "$(home_to_homevar "$LIB_DIR")")
    MIGRATE_CMD="grep -vxF -e '# MacWave' -e \"$PATH_LINE_DISPLAY\" $EXISTING_DISPLAY > $EXISTING_DISPLAY.macwave && cat $EXISTING_DISPLAY.macwave > $EXISTING_DISPLAY && rm -f $EXISTING_DISPLAY.macwave && $APPEND_CMD"
fi

# ==========================================
# 下一步：PATH 由用户自己加
# ==========================================
# 安装器不写 rc 文件。这里只给一条命令，别的不说。

echo ""
mw_say "🌊 Run this once to add wave to your PATH:" \
    "🌊 执行下面这一行，把 wave 加进 PATH："
echo ""
if [[ -n "$MIGRATE_CMD" ]]; then
    # 一行做完两件事：删掉旧版写进去的两行，再追加新的 eval 行。
    echo -e "${YELLOW}    $MIGRATE_CMD${RESET}"
else
    echo -e "${YELLOW}    $APPEND_CMD${RESET}"
fi
echo ""

mw_say "🌊 If prompted 'Command not found', run the following command or open a new terminal window." \
    "🌊 如果提示「找不到命令」，执行下列命令或打开新的终端窗口。"
echo ""
# 必须 source **刚追加进去的那个文件**（${RC_FILE}），不是「碰巧存在的」那个：
# zsh 的行加在 ~/.zprofile，此时 source ~/.zshrc 并不会把它加载进来。
echo -e "${YELLOW}    source $RC_DISPLAY${RESET}"
echo ""

# /opt/macwave 是一棵共享的树：管理员（admin 组）直接管理，其他用户只能运行。
# PATH 那行现在由用户自己加 —— 别人不加就找不到 wave，只能靠绝对路径执行。
# 这里说清楚，否则「其他人可运行」只对了一半。
mw_say "🌊 Other users on this machine can run the installed packages," \
    "🌊 本机的其他用户可运行已装的软件包，"
mw_say "🌊 but each of them needs to run this once:" \
    "🌊 但每个用户需要执行："
echo -e "${YELLOW}    $SHELLENV_DISPLAY${RESET}"
mw_say "🌊 Administrators can install and remove packages without sudo:" \
    "🌊 管理员装包、卸包都不需要 sudo："
echo -e "${YELLOW}    wave install <package>${RESET}"
mw_say "🌊 A user who is not in the '$(admin_group)' group can still run the packages," \
    "🌊 不在 '$(admin_group)' 组里的用户仍然能运行已装的包，"
mw_say "🌊 but changing them needs the full path (sudo has its own PATH):" \
    "🌊 但改动它们要用全路径（sudo 用的是它自己的 PATH）："
echo -e "${YELLOW}    sudo $BASE_DIR/lib/wave install <package>${RESET}"
echo ""

if mw_dry_run; then
    mw_say "🌊 Drop --dry-run and run the installer again to install for real." \
        "🌊 去掉 --dry-run 再运行一次，才会真正安装。"
fi
