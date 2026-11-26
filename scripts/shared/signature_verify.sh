# 自更新数据的签名校验（共享块正本）。
#
# 为什么是「必须逐字节一致」的共享块：lib/install.sh（全新安装）与
# lib/selfupdate.sh（升级）都被 curl 下来直接执行，没法 source 同一份文件，只能各带
# 一份副本。而这段是**安全闸门** —— 副本一旦漂移，表现就是「一条路径上验签被悄悄
# 跳过了」，最难发现、后果最重。所以正文只写在这里，两边逐字节同步，
# scripts/check_shared_blocks.py 会比对。
#
# 依赖宿主文件提供的东西只有两个：MW_RSA_PUB_PEM（内置公钥，由
# scripts/embed_rsa_pub.py 维护）与颜色变量 RED_BOLD / RESET。输出走下面这个
# mw_sig_say，不去调宿主的输出函数 —— 那两边长得不一样。

# >>> SHARED: signature-verify
mw_sig_say() {
    # mw_sig_say "<English>" "<中文>"：install.sh 有中英双语，selfupdate.sh 只有英文。
    # 按 MW_LANG 自己判，不依赖宿主的输出函数。
    if [[ "${MW_LANG:-en}" == "zh" ]]; then
        printf '%b\n' "$2" >&2
    else
        printf '%b\n' "$1" >&2
    fi
}

mw_trusted_pub() {
    # 输出一个**可读的 PEM 路径**，调用方拿它喂 openssl。两个来源：
    #   1. MACWAVE_RSA_PUB（运维/测试自己指定）
    #   2. 脚本内置的那一份
    # 不去读安装树里的 Keys/macwave-rsa.pub.pem：那份和 latest.toml 走同一个
    # 下载通道，能换数据的人也能换公钥，拿它验等于自证。脚本内置的这份随脚本
    # 一起装进来，是「上一次可信安装」留下的锚点。
    # 两个都没有就输出空串，调用方据此整段跳过（4.4 之前的行为）。
    if [[ -n "${MACWAVE_RSA_PUB:-}" ]]; then
        printf '%s' "$MACWAVE_RSA_PUB"
        return 0
    fi
    if [[ -z "$MW_RSA_PUB_TMP" ]]; then
        MW_RSA_PUB_TMP="$(mktemp -d 2>/dev/null)" || return 0
        printf '%s\n' "$MW_RSA_PUB_PEM" > "$MW_RSA_PUB_TMP/macwave-rsa.pub.pem"
        chmod 700 "$MW_RSA_PUB_TMP"
        chmod 600 "$MW_RSA_PUB_TMP/macwave-rsa.pub.pem"
    fi
    printf '%s' "$MW_RSA_PUB_TMP/macwave-rsa.pub.pem"
}

mw_verify_latest_signature() {
    # mw_verify_latest_signature <latest.toml 的内容> <它的 URL>
    #
    # **强制**：验不过就不继续，缺失与不匹配一视同仁。latest.toml 决定「装哪个版本、
    # 从哪个分支取代码」，是整条安装链唯一可信的起点 —— 它若能换掉，后面每个文件按
    # 清单校 sha256 全都白搭（连清单一起换就行）。所以这里的取舍是「宁可装不上」。
    #
    # MACWAVE_ALLOW_UNSIGNED=1 是唯一的例外，只给两种场合：镜像刚上线、签名还没跟上；
    # 以及测试里的赝品镜像。正常安装不要设，文档里也不推荐。
    local data="$1" url="$2"
    local timeout="${METADATA_TIMEOUT:-30}" allow="${MACWAVE_ALLOW_UNSIGNED:-}"
    local pub
    pub="$(mw_trusted_pub)"
    if [[ -z "$pub" ]]; then
        # 连锚点都拿不到（临时目录建不出来）：无从验起，也解释不清，放行。
        # 这不是「验过了」，是这个脚本本来就没有验签能力（4.4 之前的版本）。
        return 0
    fi

    local tmp sig status=0
    tmp="$(mktemp)"
    sig="$(mktemp)"
    printf '%s\n' "$data" > "$tmp"
    curl -fsSL --max-time "$timeout" ${CURL_CACERT:+--cacert "$CURL_CACERT"} \
        -o "$sig" "$url.sig" 2>/dev/null || status=$?
    if [[ "$status" -ne 0 ]]; then
        rm -f "$tmp" "$sig"
        if [[ "$allow" == "1" ]]; then
            mw_sig_say "🌊 Warning: the self-update data has no signature (MACWAVE_ALLOW_UNSIGNED=1, continuing)." \
                "🌊 警告：自更新数据没有签名（MACWAVE_ALLOW_UNSIGNED=1，继续）。"
            return 0
        fi
        echo -e "${RED_BOLD}🌊 Error: the self-update data has no signature ($url.sig).${RESET}" >&2
        mw_sig_say "🌊 Refusing to continue: without a signature, the version and the branch we install are whatever the mirror says." \
            "🌊 拒绝继续：没有签名时，「装哪个版本、取哪个分支」就等于由镜像说了算。"
        mw_sig_say "🌊 Nothing was changed. If you run a mirror, publish latest.toml.sig with it (see docs/MIRROR-SETUP.md)." \
            "🌊 什么都没改。自己跑镜像的话，请把 latest.toml.sig 一起发出去（见 docs/MIRROR-SETUP.md）。"
        exit 1
    fi

    if openssl dgst -sha256 -verify "$pub" -signature "$sig" "$tmp" > /dev/null 2>&1; then
        mw_sig_say "🌊 Self-update data: signature OK." "🌊 自更新数据：签名校验通过。"
        rm -f "$tmp" "$sig"
        return 0
    fi
    rm -f "$tmp" "$sig"
    if [[ "$allow" == "1" ]]; then
        mw_sig_say "🌊 Warning: the self-update data is not signed by the trusted key (MACWAVE_ALLOW_UNSIGNED=1, continuing)." \
            "🌊 警告：自更新数据的签名不对（MACWAVE_ALLOW_UNSIGNED=1，继续）。"
        return 0
    fi
    echo -e "${RED_BOLD}🌊 Error: the self-update data is not signed by the trusted key.${RESET}" >&2
    mw_sig_say "🌊 Refusing to continue: the data may have been altered after it was signed." \
        "🌊 拒绝继续：这份数据可能在签名之后被改过。"
    mw_sig_say "🌊 Nothing was changed. Install again once the mirror is fixed." \
        "🌊 什么都没改。镜像修好之后再装。"
    exit 1
}
# <<< SHARED
