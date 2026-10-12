#!/usr/bin/env bash
###############################################################################
#  P20 Pro (CLT-AL01 / Kirin 970 / 麒麟 970) + ReSukiSU 一键内核构建
###############################################################################
#  用法：
#     bash build_all.sh                    # 自动用脚本所在目录
#     bash build_all.sh <共享目录>          # 指定含内核 tar 包的目录
#     bash build_all.sh <内核tar包路径>      # 直接指定那个 .tar.gz
#     bash build_all.sh <共享目录> <输出目录> # 手动指定输出目录
#
#  环境要求：WSL (Ubuntu 20.04+) 或 Linux，能用 sudo 装包
#  核心设计：
#    · 自动安装缺失工具（宿主工具链 + aarch64 交叉编译器）
#    · 自动探测可用核心，全占用（可用 KSU_NPROC=N 覆盖）
#    · WSL 下输出目录强制走 $HOME（ext4），避开 /mnt/* 的跨文件系统瓶颈
#    · ReSukiSU 非 GKI → MANUAL_HOOK，注入 6 个 hook + extern 原型
#    · 严格按社区文档关闭 26 项检测，SELinux 保持 enforcing
#    · 用华为官方 mkbootimg 参数打包（CLT 机型专属 offset）
###############################################################################

SHARE_ARG="${1:-}"
DEST="${2:-$HOME/kirin970-final}"

# ---- 输出颜色 ----
if [ -t 1 ]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; C=""; N=""
fi
say() { echo "$@"; }
ok()  { echo "${G}✓${N} $*"; }
bad() { echo "${R}✗${N} $*"; }
info(){ echo "${C}·${N} $*"; }
step(){ echo ""; echo "══ $* ═════════════════════════════════════"; }

# ★★ WSL 性能关键：输出目录必须是 WSL 原生 ext4。
#   /mnt/* 是 9p/drvfs 跨文件系统，内核编译会产生几十万个小文件，
#   写在那儿慢 5-10 倍，.o 的 stat 也会成瓶颈。
if [ -z "${2:-}" ]; then
    case "$DEST" in
        /mnt/*|/media/*) DEST="$HOME/kirin970-final" ;;
    esac
fi

# ---- 定位共享目录 ----
# ★ 顺序：脚本自身目录（最可靠）→ WSL(/mnt/*) → /media/sf_*（VirtualBox）
KERTAR=""
SHARE="$SHARE_ARG"
if [ -z "$SHARE" ]; then
    SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
    for c in "$SELF_DIR" \
             /mnt/d/kirin970-resukisu-build /mnt/c/kirin970-resukisu-build \
             /mnt/hgfs/kirin970-resukisu-build \
             /media/sf_kbld /media/sf_kirin970-resukisu-build ; do
        [ -n "$c" ] && [ -d "$c" ] && [ "$(ls -A "$c" 2>/dev/null | wc -l)" -gt 0 ] \
            && SHARE="$c" && break
    done
fi

# ★ 参数校验：绝不把非法参数当路径用，否则后续全变成误导性的"找不到文件"。
if [ -n "$SHARE" ] && [ ! -e "$SHARE" ]; then
    echo "${R}✗ 传入的路径不存在:${N} $SHARE"
    echo ""
    echo "  正确用法："
    echo "    bash $0                 # 不传参，自动用脚本所在目录"
    echo "    bash $0 <共享目录>       # 含内核 tar 包的目录"
    echo "    bash $0 <内核tar包>      # 直接指定 .tar.gz"
    echo ""
    echo "  注意：不要把 cd / ls 之类当作参数传入。"
    exit 1
fi
if [ -z "$SHARE" ]; then
    echo "${R}✗ 找不到可用目录。请传参:${N}"
    echo "    bash $0 /mnt/d/kirin970-resukisu-build"
    exit 1
fi
if [ -f "$SHARE" ]; then
    KERTAR="$SHARE"
    SHARE="$(cd "$(dirname "$SHARE")" && pwd)"
fi

mkdir -p "$DEST" 2>/dev/null
DEST="$(cd "$DEST" && pwd)"
LOGS="$DEST/logs"
mkdir -p "$LOGS"

# =============================================================================
step "0/8  环境与工具链"
# =============================================================================
export ARCH=arm64
export KBUILD_BUILD_HOST=PC
export KBUILD_BUILD_USER=builder

# ---- sudo 权限获取：root / 免密 / 交互输密码 / 降级 ----
# ★ 注意：探测用`sudo -n`（本来就该静默），
#   但真正取凭证的 `sudo -v` 必须让密码提示可见，
#   否则用户看不到任何提示，只会觉得"脚本怎么不装"。
SUDO=""
SUDO_MODE=""
ask_sudo_password() { sudo -v; }

if [ "$(id -u)" = "0" ]; then
    SUDO=""; SUDO_MODE="root"
    ok "当前是 root，无需 sudo"
elif ! command -v sudo >/dev/null 2>&1; then
    SUDO_MODE="none"
    info "系统未安装 sudo"
else
    if sudo -n true 2>/dev/null; then
        SUDO="sudo -n"; SUDO_MODE="nopasswd"
        ok "sudo 免密可用"
    elif [ -t 0 ]; then
        say ""
        say "  需要 sudo 权限安装缺失的构建工具，请输入登录密码："
        say "  （输入时不会显示字符，属正常现象）"
        say ""
        if ask_sudo_password; then
            SUDO="sudo"; SUDO_MODE="interactive"
            ok "sudo 验证通过"
        else
            SUDO_MODE="manual"
            bad "sudo 验证失败（密码错误或未通过）"
        fi
        say ""
    else
        SUDO_MODE="manual"
        info "当前无交互终端（stdin 不是 tty），无法输入 sudo 密码"
    fi
fi

APT_UPDATED=""
APT_LOG="$LOGS/apt.log"
apt_install() {   # apt_install <包名...>
    [ -n "$SUDO" ] && [ "$1" ] || return 1
    mkdir -p "$LOGS" 2>/dev/null
    # sudo 凭证默认 15 分钟过期，长任务前主动续期
    if [ "$SUDO_MODE" = "interactive" ] && ! sudo -n true 2>/dev/null; then
        say ""
        say "  sudo 凭证已过期，请重新输入登录密码："
        ask_sudo_password || { bad "sudo 验证失败"; return 1; }
        ok "sudo 已续期"
    fi
    if [ -z "$APT_UPDATED" ]; then
        say "  更新软件源索引..."
        # ★ 不吞输出：失败原因（源不可达/锁占用/磁盘满）必须可见
        if ! $SUDO apt-get update -qq >"$APT_LOG" 2>&1; then
            bad "apt-get update 失败，最后 20 行："
            tail -20 "$APT_LOG" 2>/dev/null | sed 's/^/      /'
            return 1
        fi
        APT_UPDATED=1
    fi
    say "  安装: $*"
    # ★ apt/dpkg 锁冲突很常见（后台 unattended-upgrades），最多等 3 次
    _try=1
    while [ "$_try" -le 3 ]; do
        if $SUDO apt-get install -y "$@" >"$APT_LOG" 2>&1; then
            return 0
        fi
        if grep -qiE 'could not get lock|is held by another process|Unable to acquire' "$APT_LOG" 2>/dev/null; then
            say "  apt 被其他进程占用，等待 20 秒后重试（$_try/3）..."
            sleep 20
            _try=$(( _try + 1 ))
            continue
        fi
        break
    done
    bad "apt-get install 失败（$*），最后 25 行："
    tail -25 "$APT_LOG" 2>/dev/null | sed 's/^/      /'
    return 1
}

# ---- 宿主构建工具 ----
HOST_PKGS="build-essential bc flex bison libssl-dev libncurses-dev python3 git cpio"
MISSING_HOST=""
for t in make bc flex bison python3 git tar gzip cpio; do
    command -v "$t" >/dev/null 2>&1 || MISSING_HOST="$MISSING_HOST $t"
done

INSTALL_FAILED=""
if [ -n "$MISSING_HOST" ]; then
    info "缺失宿主工具:$MISSING_HOST"
    if apt_install $HOST_PKGS; then
        STILL=""
        for t in $MISSING_HOST; do
            command -v "$t" >/dev/null 2>&1 || STILL="$STILL $t"
        done
        if [ -z "$STILL" ]; then
            ok "已自动安装:$MISSING_HOST"
            MISSING_HOST=""
        else
            # apt 返回 0 但命令不可见：可能是 snap/flatpak 沙箱、PATH 缺 /usr/bin 等
            bad "apt 报告成功，但以下命令仍不可用:$STILL"
            for t in $STILL; do
                say "      $t → $(command -v "$t" 2>/dev/null || echo '不在 PATH')"
            done
            MISSING_HOST="$STILL"; INSTALL_FAILED="installed-but-missing"
        fi
    else
        INSTALL_FAILED="apt-failed"
    fi
fi

if [ -n "$MISSING_HOST" ]; then
    if [ "$INSTALL_FAILED" = "installed-but-missing" ]; then
        bad "以下构建工具不可用:$MISSING_HOST"
        say "    可能是 snap/flatpak 沙箱、PATH 缺 /usr/bin、或误装 32 位包。"
    elif [ "$INSTALL_FAILED" = "apt-failed" ]; then
        bad "自动安装失败（apt-get 报错见上方或 $APT_LOG）"
    else
        bad "无法自动安装以下工具:$MISSING_HOST"
    fi
    say ""
    [ -z "$SUDO" ] && say "  原因：非 root 且 sudo 需密码（无交互终端可验证）。"
    say ""
    say "  请手动执行："
    say "    sudo apt update"
    say "    sudo apt install -y build-essential make bc flex bison \\"
    say "        libssl-dev libncurses-dev python3 git cpio"
    exit 1
fi
ok "构建工具齐备（make $(make --version 2>/dev/null | head -1 | grep -o '[0-9.]*' | head -1)）"

# ---- 交叉工具链 ----
# ★ 先清掉外部可能污染的环境变量（~/.bashrc 里 export 过 CROSS_COMPILE 等），
#   否则内核 Makefile 会优先采用，拼出 aarch64-linux-gnugcc。
unset CROSS_COMPILE CROSS_COMPILE_ARM64 CC HOSTCC GCC 2>/dev/null

CC=""
for c in aarch64-linux-gnu-gcc-13 aarch64-linux-gnu-gcc-12 aarch64-linux-gnu-gcc-11 \
         aarch64-linux-gnu-gcc-10 aarch64-linux-gnu-gcc \
         aarch64-none-linux-gnu-gcc; do
    if which "$c" >/dev/null 2>&1 && [ -x "$(which "$c" 2>/dev/null)" ]; then
        CC="$c"; break
    fi
done
if [ -z "$CC" ]; then
    info "未找到 aarch64 交叉编译器，尝试自动安装..."
    if apt_install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu libc6-dev-arm64-cross; then
        for c in aarch64-linux-gnu-gcc aarch64-linux-gnu-gcc-11 \
                 aarch64-linux-gnu-gcc-10 aarch64-linux-gnu-gcc-12; do
            if which "$c" >/dev/null 2>&1 && [ -x "$(which "$c" 2>/dev/null)" ]; then
                CC="$c"; break
            fi
        done
        [ -n "$CC" ] && ok "已自动安装交叉编译器: $CC"
    fi
fi
if [ -z "$CC" ]; then
    bad "找不到 aarch64 交叉编译器，且自动安装失败。"
    say "    sudo apt update && sudo apt install -y \\"
    say "      gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu libc6-dev-arm64-cross"
    exit 1
fi

# ★★★ CROSS_COMPILE 必须从「去掉 -gcc 及版本后缀」的前缀重建并补尾部横线：
#     aarch64-linux-gnu-gcc-11 → aarch64-linux-gnu-
#   ${CC%-gcc} 是错的：对带版本号的完全不匹配；
#   ${CROSS_BASE%%-gcc*} 取到 aarch64-linux-gnu，再补 "-" 才对。
CROSS_BASE="${CC##*/}"
CROSS_COMPILE="${CROSS_BASE%%-gcc*}-"
export CROSS_COMPILE
CROSS_CC="${CROSS_COMPILE}gcc"
CROSS_LD="${CROSS_COMPILE}ld"
ok "CROSS_COMPILE=$CROSS_COMPILE (已导出)"
ok "目标         $("$CROSS_CC" -dumpmachine 2>/dev/null)"

# ★ 工具链必须放在工具链目录（Kbuild 拼 $(CROSS_COMPILE)+名字 去找），
#   所以要把带版本号的软链成无版本号的名字。
TOOLDIR="$DEST/toolchain"
mkdir -p "$TOOLDIR"

link_tool() {   # link_tool <无版本号名字> <候选名...>
    _link="$1"; shift
    _p="$(command -v "$_link" 2>/dev/null)"
    if [ -n "$_p" ] && [ -x "$_p" ]; then return 0; fi
    for _c in "$@"; do
        _p="$(command -v "$_c" 2>/dev/null)"
        if [ -n "$_p" ] && [ -x "$_p" ]; then
            ln -sf "$_p" "$TOOLDIR/$_link" 2>/dev/null && return 0
        fi
    done
    return 1
}

PREFIX="${CROSS_COMPILE%-}"
MISSING=""
for t in gcc ld as ar nm objcopy objdump readelf strip cpp; do
    link_tool "${PREFIX}-${t}" \
        "${PREFIX}-${t}" "${PREFIX}-${t}-13" "${PREFIX}-${t}-12" \
        "${PREFIX}-${t}-11" "${PREFIX}-${t}-10" || MISSING="$MISSING ${PREFIX}-${t}"
done
if [ -n "$MISSING" ]; then
    info "交叉工具链不完整，尝试补装:$MISSING"
    apt_install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu libc6-dev-arm64-cross
    MISSING=""
    for t in gcc ld as ar nm objcopy objdump readelf strip cpp; do
        link_tool "${PREFIX}-${t}" \
            "${PREFIX}-${t}" "${PREFIX}-${t}-13" "${PREFIX}-${t}-12" \
            "${PREFIX}-${t}-11" "${PREFIX}-${t}-10" || MISSING="$MISSING ${PREFIX}-${t}"
    done
fi
if [ -n "$MISSING" ]; then
    bad "交叉工具链缺失:$MISSING（自动安装后仍找不到）"
    say "    sudo apt install -y gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \\"
    say "                        libc6-dev-arm64-cross"
    exit 1
fi

# 私有目录前置到 PATH 最前
case ":$PATH:" in
    *":$TOOLDIR:"*) ;;
    *) export PATH="$TOOLDIR:$PATH" ;;
esac

# ★ arm64 编译自检（只用 gcc 分支确实存在的 flag，不加 clang 专属的
#   -mno-implicit-float）。失败只提示不阻断——真正的判定权交给 Kbuild。
TCFILE="$TOOLDIR/.probe"
printf 'int probe(void){return 0;}\n' > "$TCFILE.c"
PM="$("$CROSS_CC" -dumpmachine 2>/dev/null)"
case "$PM" in
    aarch64*)
        if "$CROSS_CC" -mgeneral-regs-only -fstack-protector-strong \
                -c "$TCFILE.c" -o "$TCFILE.o" 2>"$TOOLDIR/.probe.err"; then
            ok "arm64 交叉编译器确认可用: $PM"
        else
            info "arm64 目标编译探测未通过（不阻断，交由 Kbuild 判定）"
            head -3 "$TOOLDIR/.probe.err" 2>/dev/null | sed 's/^/      /'
        fi
        ;;
    *)
        bad "编译器目标架构异常: $PM"
        echo "  → CROSS_COMPILE 仍指向错误工具链"
        exit 1
        ;;
esac
rm -f "$TCFILE.c" "$TCFILE.o" "$TOOLDIR/.probe.err"

# ---- 华为 tzdriver 依赖 Android NDK 的 cpp ----
#   tzdriver/Makefile:34: aarch64-linux-android-cpp rule.in > rule.out
#   交叉工具链没有该命令 → Error 127 (command not found)。
#   ★ 不能靠关 CONFIG_TEE_CFC 绕过（Kconfig default y，TEE 完整性校验，
#     关了可能 BootROM 校验失败开不了机），必须提供等价 cpp。
#   rule.in 只做纯 token 拼接宏，GNU cpp 与 NDK cpp 语义等价。
#   ★ -P 必须加：GNU cpp 默认输出 '# 1 "rule.in"' 行标记，
#     而 cfc_rule_parser.parseLine() 只认含 ':=' 或 '=' 的行，遇行标记抛异常。
if ! command -v aarch64-linux-android-cpp >/dev/null 2>&1; then
    cat > "$TOOLDIR/aarch64-linux-android-cpp" <<NDKCPP
#!/bin/sh
# 华为 tzdriver 用 NDK cpp 预处理 rule.in；这里用 GNU 交叉 cpp 替代。
# -P 抑制 linemarker，否则 cfc_rule_parser 解析失败。
exec "${CROSS_COMPILE}cpp" -P "\$@"
NDKCPP
    chmod +x "$TOOLDIR/aarch64-linux-android-cpp"
    ok "已创建 aarch64-linux-android-cpp wrapper → ${CROSS_COMPILE}cpp"
fi

# ★ tzdriver/Makefile:32 调的是 `python`（不是 python3）。
#   Ubuntu 22.04 没有 /usr/bin/python，装了 python-is-python3 才指向 3，
#   否则即使存在也可能指向 Python2 而 cfc_*.py 是 Python3 语法 → Error 1。
if ! command -v python >/dev/null 2>&1 || \
   ! python -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' >/dev/null 2>&1; then
    printf '#!/bin/sh\nexec python3 "$@"\n' > "$TOOLDIR/python"
    chmod +x "$TOOLDIR/python"
    ok "已创建 python wrapper → python3 ($(python3 -V 2>&1))"
fi

# ★ wrapper 自检：它们是延迟展开的，补装工具后必须重新验证，
#   否则 tzdriver 会在 make 时才报 command not found。
for w in aarch64-linux-android-cpp python; do
    if [ -f "$TOOLDIR/$w" ]; then
        if ! "$TOOLDIR/$w" --version >/dev/null 2>&1 && \
           ! "$TOOLDIR/$w" -V >/dev/null 2>&1; then
            bad "wrapper $w 的目标不可用（交叉工具链可能仍不完整）"
            exit 1
        fi
    fi
done

echo ""
echo "  共享目录: $SHARE"
echo "  工作目录: $DEST"
# =============================================================================
step "1/8  解包内核源码"
# =============================================================================
KS="$DEST/kernel"

if [ -f "$KS/Makefile" ]; then
    ok "已解包，跳过（幂等）"
else
    if [ -z "$KERTAR" ]; then
        for cand in \
            "$SHARE"/CLT_PIE*.tar.gz "$SHARE"/*opensource*.tar.gz "$SHARE"/*kernel*.tar.gz \
            "$SHARE"/ISO/CLT_PIE*.tar.gz "$SHARE"/*/CLT_PIE*.tar.gz \
            "$SHARE"/*/*opensource*.tar.gz \
            ; do
            [ -f "$cand" ] && KERTAR="$cand" && break
        done
        # ★ glob 匹配不到会原样保留通配符字面量，深层目录/非常规命名会漏，
        #   用 find 再兜一次底。
        if [ -z "$KERTAR" ]; then
            KERTAR=$(find "$SHARE" -maxdepth 3 -type f \
                     \( -name 'CLT_PIE*.tar.gz' -o -name '*opensource*.tar.gz' \) 2>/dev/null | head -1)
        fi
    fi
    if [ -z "$KERTAR" ] || [ ! -f "$KERTAR" ]; then
        bad "在共享目录下找不到内核 tar 包"
        say ""
        say "  正在搜索: $SHARE"
        F=$(find "$SHARE" -maxdepth 3 -name '*.tar.gz' 2>/dev/null)
        if [ -n "$F" ]; then
            say "  实际找到的 .tar.gz："
            echo "$F" | sed 's/^/      /'
            say ""
            say "  ★ 这些都不是内核包（内核包名含 CLT_PIE 或 opensource，约 460MB）。"
        else
            say "  (一个 .tar.gz 都没有)"
        fi
        say ""
        say "  可直接指定内核包："
        say "    bash $0 \"\$(find $SHARE -maxdepth 3 -name 'CLT_PIE*.tar.gz' | head -1)\""
        exit 1
    fi
    info "$(basename "$KERTAR")  $(du -h "$KERTAR" | cut -f1)"

    info "校验 gzip 流（1-2 分钟）..."
    gzip -t "$KERTAR" 2>/dev/null && ok "gzip 完整" || { bad "gzip 不完整，需重下"; exit 1; }

    info "解包（119,070 条目，2-5 分钟）..."
    tar xzf "$KERTAR" -C "$DEST" > "$LOGS/untar.log" 2>&1
    RC=$?
    [ $RC -ne 0 ] && { bad "解包失败(退出码 $RC)"; tail -5 "$LOGS/untar.log" | sed 's/^/      /'; exit 1; }

    # ★ 华为官方包的双层目录是个坑：
    #     Code_Opensource/kernel/Makefile       ← 外层有 Makefile 但没 arch/
    #     Code_Opensource/kernel/kernel/Makefile ← 内层还有一个
    #     Code_Opensource/kernel/arch/...        ← 但 arch/ 只在外层！
    #   所以不能靠「有 Makefile」判断内核根，必须要求 Makefile 与 arch/ 同时存在。
    for cand in "$DEST/Code_Opensource/kernel" "$DEST/Code_Opensource/kernel/kernel" \
                "$DEST/kernel" "$DEST"; do
        if [ -f "$cand/Makefile" ] && [ -d "$cand/arch" ]; then
            KS="$cand"; break
        fi
    done
    if [ ! -f "$KS/Makefile" ] || [ ! -d "$KS/arch" ]; then
        bad "解包后找不到内核根目录（需同时含 Makefile 与 arch/）"
        find "$DEST" -maxdepth 3 -name Makefile 2>/dev/null | head -5 | sed 's/^/      /'
        exit 1
    fi
    ok "内核根: $KS"
    ok "版本: $(grep -m1 '^VERSION\|^PATCHLEVEL\|^SUBLEVEL' "$KS/Makefile" 2>/dev/null | tr '\n' ' ' | cut -c1-60)"
fi

# =============================================================================
step "2/8  关闭华为 root 检测 / 完整性校验"
# =============================================================================
#  清单来源：Coconutat《KernelSU适配EMUI9或9.1.0系统的内核》wiki
#            https://github.com/Coconutat/HuaweiP10-GSI-And-Modify-Tutorial
#  ★ 严格只按社区文档，逐条照抄，多一项都不关、无一项都不关。
#    已实测：该 26 项在本机 defconfig 中【全部为 =y 且全部存在】，零缺失零多余。
DEFCONF=$(find "$KS/arch/arm64/configs" -name '*kirin970*defconfig' 2>/dev/null | head -1)
[ -z "$DEFCONF" ] && DEFCONF=$(find "$KS/arch/arm64/configs" -name '*defconfig' 2>/dev/null | head -1)
if [ -z "$DEFCONF" ] || [ ! -f "$DEFCONF" ]; then
    bad "找不到 defconfig"
    ls -la "$KS/arch/arm64/configs/" 2>/dev/null | head -15 | sed 's/^/      /'
    exit 1
fi
ok "defconfig: $(basename "$DEFCONF")"

# ---- 文档「4.9.x 内核」分节 24 项原文 ----
DOCUMENT_COCONUTAT="
HISI_PMALLOC HIVIEW_SELINUX HISI_SELINUX_EBITMAP_RO HISI_SELINUX_PROT
HISI_RO_LSM_HOOKS INTEGRITY INTEGRITY_AUDIT HUAWEI_CRYPTO_TEST_MDPP
HUAWEI_SELINUX_DSM HUAWEI_HIDESYMS HW_SLUB_SANITIZE HUAWEI_PROC_CHECK_ROOT
HW_ROOT_SCAN HUAWEI_EIMA HUAWEI_EIMA_ACCESS_CONTROL HW_DOUBLE_FREE_DYNAMIC_CHECK
HKIP_ATKINFO HW_KERNEL_STP HISI_HHEE HISI_HHEE_TOKEN HISI_DIEID HISI_SUBPMU
TEE_ANTIROOT_CLIENT HWAA
"
# ---- 文档「关闭 AVB 验证」分节 2 项 ----
DOCUMENT_AVB="DM_VERITY DM_VERITY_AVB"
DETECT_LIST="$DOCUMENT_COCONUTAT $DOCUMENT_AVB"

# ★ SELinux 保持官方 enforcing：文档把「设 permissive」列为【可选】，
#   且仅适用于刷 GSI 的场景；原生 EMUI 下反而降低安全性。
info "SELinux: 保持官方 enforcing（不改 defconfig）"

BAK2="$DEFCONF.pre-ksu.bak"
[ -f "$BAK2" ] || { cp "$DEFCONF" "$BAK2"; ok "已备份 $(basename "$BAK2")"; }

CLOSED=0; MISS=0
for k in $DETECT_LIST; do
    grep -qE "^# CONFIG_$k is not set$" "$DEFCONF" 2>/dev/null && continue   # 幂等
    if grep -qE "^CONFIG_$k=" "$DEFCONF" 2>/dev/null; then
        sed -i "/^CONFIG_$k=/d" "$DEFCONF"
        printf '# CONFIG_%s is not set\n' "$k" >> "$DEFCONF"
        CLOSED=$((CLOSED+1))
    else
        MISS=$((MISS+1))
    fi
done
ok "关闭检测项 $CLOSED 个"
[ "$MISS" -gt 0 ] && info "该内核不存在的 $MISS 项（自动跳过）"

# kprobes 是华为 root 检测的探测手段，一并关闭
if grep -qE "^CONFIG_KPROBES=y$" "$DEFCONF" 2>/dev/null; then
    sed -i "/^CONFIG_KPROBES=/d" "$DEFCONF"
    printf '# CONFIG_KPROBES is not set\n' >> "$DEFCONF"
    ok "关闭 CONFIG_KPROBES"
fi

# =============================================================================
step "3/8  安装 ReSukiSU"
# =============================================================================
KSU="$KS/drivers/kernelsu"
KSUSRC=""
for cand in "$SHARE/src/ReSukiSU-main/kernel" "$SHARE/resukisu-ksu" \
            "$SHARE/src/ReSukiSU-main"; do
    [ -f "$cand/Kbuild" ] && [ -f "$cand/Kconfig" ] && KSUSRC="$cand" && break
done
if [ -z "$KSUSRC" ]; then
    for t in "$SHARE"/resukisu-ksu.tar.gz; do
        [ -f "$t" ] || continue
        info "从 $(basename "$t") 解出 ReSukiSU..."
        TD="$DEST/.ksu-tmp"; rm -rf "$TD"; mkdir -p "$TD"
        tar xzf "$t" -C "$TD" 2>/dev/null
        for cand in "$TD/kernel" "$TD/ReSukiSU-main/kernel"; do
            [ -f "$cand/Kbuild" ] && KSUSRC="$cand" && break
        done
        [ -n "$KSUSRC" ] && break
    done
fi
[ -n "$KSUSRC" ] || { bad "找不到 ReSukiSU 源码（需 $SHARE/src/ReSukiSU-main/kernel/）"; exit 1; }
ok "ReSukiSU 源 $(find "$KSUSRC" -type f | wc -l) 个文件"

# ★ 用 tar 管道安装：cp -r 在目标已存在时会多套一层目录
if [ -f "$KSU/Kbuild" ] && grep -q "throne_tracker" "$KSU/Kbuild" 2>/dev/null; then
    ok "已安装，跳过（幂等）"
else
    [ -e "$KSU" ] && { rm -rf "$KSU"; info "清理旧目录"; }
    mkdir -p "$KSU"
    ( cd "$KSUSRC" && tar cf - . ) | ( cd "$KSU" && tar xf - )
    if ! ( cd "$KSU" && [ -f Kbuild ] ); then
        bad "解包后 kernelsu 为空——可能跨文件系统读取异常"
        exit 1
    fi
    for f in Kbuild Kconfig Makefile ksu.c throne_tracker.c; do
        [ -f "$KSU/$f" ] || { bad "安装后缺 $f，实际结构:"
            find "$KSU" -maxdepth 2 2>/dev/null | head -12 | sed 's/^/        /'; exit 1; }
    done
    ok "已安装并验证（5 个关键文件齐全）"
fi

# ---- Kconfig / Makefile 接入 ----
# ★ ReSukiSU 非 GKI 一律装在 drivers/kernelsu，obj-y 只需加进 drivers/Makefile。
#   绝不能往 init/Makefile 加 obj-$(CONFIG_KSU) += kernelsu/：
#     Kbuild 会据此下钻 init/kernelsu/ 找 Makefile（不存在）→ No rule to make target。
#   先防御性清掉任何残留的 init/Makefile 坏引用。
if [ -f "$KS/init/Makefile" ]; then
    grep -q 'obj-$(CONFIG_KSU) += kernelsu/' "$KS/init/Makefile" 2>/dev/null && \
        sed -i '/obj-$(CONFIG_KSU) += kernelsu\//d' "$KS/init/Makefile"
fi
if [ -f "$KS/drivers/Kconfig" ] && \
   ! grep -q 'source "drivers/kernelsu/Kconfig"' "$KS/drivers/Kconfig" 2>/dev/null; then
    printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$KS/drivers/Kconfig"
    ok "接入 drivers/Kconfig"
fi
if [ -f "$KS/drivers/Makefile" ] && \
   ! grep -q 'kernelsu' "$KS/drivers/Makefile" 2>/dev/null; then
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KS/drivers/Makefile"
    ok "接入 drivers/Makefile"
fi

# ---- ReSukiSU 强制要求 git submodule（Kbuild 用 git rev-list，无兜底）----
echo ""
if [ -d "$KS/drivers/.git" ]; then
    ok "git 环境已就绪"
else
    info "建 git 仓库（Kbuild 强制要求）..."
    ( cd "$KS/drivers" \
      && git init -q 2>/dev/null \
      && git config user.email "ksu@local" \
      && git config user.name "KSU" \
      && git config commit.gpgsign false \
      && printf '*\n!.gitignore\n!kernelsu/\n' > .gitignore \
      && git add -f kernelsu .gitignore >/dev/null 2>&1 \
      && git commit -q -m "integrate ReSukiSU" >/dev/null 2>&1 \
      && git tag -a v4.1.0 -m v >/dev/null 2>&1 ) 2>/dev/null
    [ -d "$KS/drivers/.git" ] \
      && ok "git 仓库已建（commits=$(cd "$KS/drivers" && git rev-list --count HEAD 2>/dev/null)）" \
      || { bad "git 仓库创建失败，Kbuild 会拒绝"; exit 1; }
fi

# =============================================================================
say ""
info "把 tzdriver 的 Python2 代码生成脚本转为 Python3"
# =============================================================================
# ★ 华为 tzdriver 的 CFC 状态机代码生成器是【Python 2】脚本：
#     tzdriver/Makefile:32
#       $(obj)/cfc_data.c: ... $(obj)/rule.out
#           +python $(srctree)/$(src)/cfc_codegen.py $(obj)/rule.out > $@
#     cfc_codegen.py → cfc_rule_parser.py / cfc_graph.py / cfc_graphgen.py
#   Ubuntu 22.04 只有 python3，直接跑必失败（三个实测错误）：
#     1) TypeError: object of type 'filter' has no len()
#        （py2 filter 返回 list，py3 返回迭代器；cfc_rule_parser.py:64）
#     2) AttributeError: 'dict' object has no attribute 'has_key'
#        （cfc_graph.py 6 处 + cfc_graphgen.py 2 处）
#     3) TypeError: unhashable type: 'DFAState'
#        （py3 中定义了 __eq__ 会自动置 __hash__=None；
#          同文件 Event/NFAState 都有 __hash__，所以必须【逐类】判断，
#          用全文件判断会漏 —— 第一版就栽在这）
#   ★ 不能关 CONFIG_TEE_CFC 绕过（Kconfig default y，TEE 完整性校验）。
#   已用官方 rule.out 实测：转换后能生成合法 cfc_data.c（13 events / 11 states）。
TZD="$KS/drivers/hisi/tzdriver"
if [ -d "$TZD" ]; then
    python3 - "$TZD" <<'PY2TO3'
import sys, os, re
d = sys.argv[1]
files = ['cfc_rule_parser.py', 'cfc_graph.py', 'cfc_graphgen.py', 'cfc_codegen.py']

def wrap_calls(s, name):
    """把 filter( ... ) / map( ... ) 成对包裹为 list(filter( ... ))。
    必须成对括号匹配——只加前缀会产生 SyntaxError。"""
    out, i = [], 0
    while True:
        m = re.search(r'(?<![\w.])' + name + r'\(', s[i:])
        if not m:
            out.append(s[i:]); break
        st, op = i + m.start(), i + m.end() - 1
        depth, j = 0, op
        while j < len(s):
            if s[j] == '(':
                depth += 1
            elif s[j] == ')':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        out.append(s[i:st]); out.append('list(%s(' % name)
        out.append(s[op + 1:j]); out.append('))'); i = j + 1
    return ''.join(out)

changed = []
for f in files:
    p = os.path.join(d, f)
    if not os.path.isfile(p):
        continue
    s = open(p, encoding='utf-8', errors='surrogateescape').read()
    orig = s
    # 1) X.has_key(Y)  ->  (Y in X)
    s = re.sub(r'([A-Za-z_][\w\.\[\]]*)\.has_key\(([^()]*(?:\([^()]*\))?[^()]*)\)',
               lambda m: '%s in %s' % (m.group(2).strip(), m.group(1).strip()), s)
    # 2) filter/map 成对包 list()
    s = wrap_calls(s, 'filter')
    s = wrap_calls(s, 'map')
    # 3) 【逐类】补 __hash__：有 __eq__ 无 __hash__ 的类在 py3 中不可哈希
    parts = re.split(r'(?m)^(?=class\s+\w+)', s)
    out_parts = []
    for part in parts:
        cm = re.match(r'class\s+(\w+)', part)
        if cm and '__eq__' in part and 'def __hash__' not in part:
            eq = re.search(r'(?m)^(\t*)def __eq__\(self,[^)]*\):[^\n]*\n(?:\1[^\n]*\n|\n)*', part)
            if eq:
                ind = eq.group(1)
                add = '\n%sdef __hash__(self):\n%s\treturn hash(self.idx)\n' % (ind, ind)
                part = part[:eq.end()] + add + part[eq.end():]
                changed.append('%s.%s: +__hash__' % (f, cm.group(1)))
        out_parts.append(part)
    s = ''.join(out_parts)
    if s != orig:
        open(p, 'w', encoding='utf-8', errors='surrogateescape', newline='').write(s)
        changed.append(f)
for c in changed:
    print('    %s' % c)
PY2TO3
    if [ -f "$TZD/cfc_graph.py" ] && \
       ! grep -qE '\.has_key\(' "$TZD/cfc_rule_parser.py" "$TZD/cfc_graph.py" "$TZD/cfc_graphgen.py" 2>/dev/null; then
        ok "tzdriver CFC 代码生成器已转为 Python3"
    else
        info "tzdriver 转换未完全生效，编译若报 filter/has_key/unhashable 需检查"
    fi
fi

# =============================================================================
step "4/8  打 hook（MANUAL_HOOK）"
# =============================================================================
# ★ 4.9 是非 GKI → TP_HOOK 会被 Kbuild $(error)，必须 MANUAL_HOOK。
for o in "CONFIG_KSU=y" "CONFIG_KALLSYMS_ALL=y" "CONFIG_KSU_MANUAL_HOOK=y" \
         "CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y" \
         "CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y" \
         "CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y"; do
    grep -qE "^${o%=}=" "$DEFCONF" 2>/dev/null && continue
    printf '%s\n' "$o" >> "$DEFCONF"
done
ok "defconfig 已加 KSU + MANUAL_HOOK"

do_hook() {   # do_hook <相对路径> <hook名>  已注入返回0
    grep -q "$2" "$KS/$1" 2>/dev/null
}

# ★★ Kbuild 的检查点决定哪些需要注入（这是权威依据，不是猜）：
#   setuid   → LSM hooks      (CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK)  不grep 源码
#   init rc  → LSM hooks      (CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK)  不 grep 源码
#   input    → input_handler  (CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK)   不 grep 源码
#   execveat / faccessat / stat / newfstat_ret / fstat64_ret / sys_reboot → 必须注入且被 grep
# 所以只需注入下面 6 个。往 kernel/sys.c 注入 setresuid 反而多余且致命
#（曾经引入 #include <linux/ksud.h> → fatal error）。
#
# ★★ 绝对不能加 #include <linux/ksud.h>：
#   KSU 头文件在 drivers/kernelsu/，内核文件(fs/exec.c 等)没有该 include 路径
#   → fatal error: linux/ksud.h: No such file or directory。
#   而且没有任何单一头文件声明全部 9 个 ksu_handle 函数（6 个只在 .c 里定义），
#   所以"加 include 路径"也解决不了。正确做法：在 hook 处 extern 声明原型。
#
# ★★ 插入位置：函数体的「声明段之后、语句段之前」。
#   Linux 4.9 用 -std=gnu89，声明必须在所有语句之前；
#   直接插在 '{' 后会造成 declaration-after-statement 而编译失败。
# ★★ 顺序：extern 声明在前，hook 调用在后（先用后声明是 C 错误）。

# --- 1) fs/exec.c : ksu_handle_execveat ---
#   原型（从 ReSukiSU 源码 sucompat.c:231 逐字确认）：
#     int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
#                             void *argv, void *envp, int *flags);
#   ★ argv/envp 在 4.9 的 do_execveat_common 里是【struct user_arg_ptr 结构体本身】
#     而该函数内部把 void* 转发给 struct user_arg_ptr*，
#     所以必须传 &argv / &envp 取地址；直接传值报
#     "incompatible type for argument 3/4"（此为实测错误）。
#     权威依据：ReSukiSU 自己在 ksud.c:871 就是
#       ksu_handle_execveat_ksud(&fd, &filename_p, &argv, NULL, NULL);
F="$KS/fs/exec.c"
if do_hook "fs/exec.c" "ksu_handle_execveat"; then
    ok "exec.c  execveat ✓"
else
    python3 - "$F" <<'PYEOF'
import sys, re

DECL = re.compile(
    r'^\s*(const\s+|struct\s+|union\s+|enum\s+|unsigned\s+|signed\s+|static\s+|'
    r'register\s+|volatile\s+|inline\s+|long\s+|short\s+|int\s+|char\s+|bool\s+|'
    r'void\s+|size_t\s+|uid_t\s+|gid_t\s+|kuid_t\s+|kgid_t\s+|mode_t\s+|dev_t\s+|'
    r'loff_t\s+|pid_t\s+|atomic_t\s+|spinlock_t\s+|struct\s+\w+\s*\**\s*\w+\s*(\[|;|=))')

def decl_end_of(sig_end, s):
    """在函数体的「声明段之后、语句段之前」定位插入点。"""
    i = s.find('{', sig_end)
    if i < 0:
        return None
    j = i + 1
    pos = None
    while j < len(s):
        while j < len(s) and s[j] in ' \t\r\n':
            j += 1
        if j >= len(s):
            break
        if s.startswith('/*', j):
            e = s.find('*/', j + 2); j = (e + 2) if e > 0 else len(s); continue
        if s.startswith('//', j):
            e = s.find('\n', j); j = (e + 1) if e > 0 else len(s); continue
        k = j
        while k < len(s) and s[k] != '\n' and s[k] != ';':
            k += 1
        if DECL.match(s[j:k]):
            j = k + 1; continue
        pos = j; break
    return pos if pos is not None else j

path = sys.argv[1]
s = open(path, encoding='utf-8', errors='surrogateescape').read()

# 先从签名里取实参名（do_execveat_common 有 5 个参数）
_m = re.search(r'static int do_execveat_common\(([^)]*)\)', s, re.S)
if not _m:
    sys.exit(1)
_p = [x.strip().split()[-1].lstrip('*') for x in _m.group(1).split(',') if x.strip()]
if len(_p) < 5:
    sys.exit(3)
a, b, c, d, e = _p[:5]

m = re.search(r'static int do_execveat_common\(', s)
if not m:
    sys.exit(1)
pos = decl_end_of(m.end(), s)
if pos is None:
    sys.exit(1)

# ★ 顺序：extern 声明在前，hook 调用在后
_ext = ("\n\t/* ReSukiSU: hook handler prototype */\n"
        "\textern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n"
        "\t\tvoid *argv, void *envp, int *flags);\n")
_hook = ("\n\t/* ReSukiSU hook */\n"
         f"\tif (ksu_handle_execveat(&{a}, &{b}, &{c}, &{d}, &{e}))\n"
         "\t\treturn -EPERM;\n")
s = s[:pos] + _ext + _hook + s[pos:]
# ★ 必须显式写回文件，否则函数凭空返回、注入是空操作
open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='').write(s)
sys.exit(0)
PYEOF
    do_hook "fs/exec.c" "ksu_handle_execveat" && ok "exec.c  execveat ✓" || bad "exec.c  execveat ✗"
fi

# --- 2) fs/open.c : ksu_handle_faccessat ---
#   原型（sucompat.h:11）：
#     int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
#                              int *mode, int *__unused_flags);
F="$KS/fs/open.c"
if do_hook "fs/open.c" "ksu_handle_faccessat"; then
    ok "open.c  faccessat ✓"
else
    python3 - "$F" <<'PYEOF'
import sys, re
DECL = re.compile(
    r'^\s*(const\s+|struct\s+|union\s+|enum\s+|unsigned\s+|signed\s+|static\s+|'
    r'register\s+|volatile\s+|inline\s+|long\s+|short\s+|int\s+|char\s+|bool\s+|'
    r'void\s+|size_t\s+|uid_t\s+|gid_t\s+|kuid_t\s+|kgid_t\s+|mode_t\s+|dev_t\s+|'
    r'loff_t\s+|pid_t\s+|atomic_t\s+|spinlock_t\s+|struct\s+\w+\s*\**\s*\w+\s*(\[|;|=))')
def decl_end_of(sig_end, s):
    i = s.find('{', sig_end)
    if i < 0: return None
    j = i + 1; pos = None
    while j < len(s):
        while j < len(s) and s[j] in ' \t\r\n': j += 1
        if j >= len(s): break
        if s.startswith('/*', j):
            e = s.find('*/', j + 2); j = (e + 2) if e > 0 else len(s); continue
        if s.startswith('//', j):
            e = s.find('\n', j); j = (e + 1) if e > 0 else len(s); continue
        k = j
        while k < len(s) and s[k] != '\n' and s[k] != ';': k += 1
        if DECL.match(s[j:k]): j = k + 1; continue
        pos = j; break
    return pos if pos is not None else j
path = sys.argv[1]
s = open(path, encoding='utf-8', errors='surrogateescape').read()
m = re.search(r'SYSCALL_DEFINE3\(faccessat,', s)
if not m: sys.exit(1)
pos = decl_end_of(m.end(), s)
if pos is None: sys.exit(1)
_ext = ("\n\t/* ReSukiSU: hook handler prototype */\n"
        "\textern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,\n"
        "\t\tint *mode, int *__unused_flags);\n")
_hook = ("\n\t/* ReSukiSU hook */\n"
         "\tif (ksu_handle_faccessat(&dfd, &filename, &mode, NULL))\n"
         "\t\treturn -EPERM;\n")
s = s[:pos] + _ext + _hook + s[pos:]
open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='').write(s)
sys.exit(0)
PYEOF
    do_hook "fs/open.c" "ksu_handle_faccessat" && ok "open.c  faccessat ✓" || bad "open.c  faccessat ✗"
fi

# --- 3) fs/stat.c : 3 个 hook ---
#   原型（sucompat.h:16 走 4.9 的 #else 分支 / ksud.c:554,563）：
#     int  ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#     void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#     void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);
#   ★ vfs_fstatat 的第二参数本就是 const char __user *filename，
#     所以直接 &filename，不要 (struct filename **) 强转（类型不匹配）。
F="$KS/fs/stat.c"
if do_hook "fs/stat.c" "ksu_handle_stat"; then
    ok "stat.c  stat / newfstat_ret / fstat64_ret ✓"
else
    python3 - "$F" <<'PYEOF'
import sys, re
DECL = re.compile(
    r'^\s*(const\s+|struct\s+|union\s+|enum\s+|unsigned\s+|signed\s+|static\s+|'
    r'register\s+|volatile\s+|inline\s+|long\s+|short\s+|int\s+|char\s+|bool\s+|'
    r'void\s+|size_t\s+|uid_t\s+|gid_t\s+|kuid_t\s+|kgid_t\s+|mode_t\s+|dev_t\s+|'
    r'loff_t\s+|pid_t\s+|atomic_t\s+|spinlock_t\s+|struct\s+\w+\s*\**\s*\w+\s*(\[|;|=))')
def decl_end_of(sig_end, s):
    i = s.find('{', sig_end)
    if i < 0: return None
    j = i + 1; pos = None
    while j < len(s):
        while j < len(s) and s[j] in ' \t\r\n': j += 1
        if j >= len(s): break
        if s.startswith('/*', j):
            e = s.find('*/', j + 2); j = (e + 2) if e > 0 else len(s); continue
        if s.startswith('//', j):
            e = s.find('\n', j); j = (e + 1) if e > 0 else len(s); continue
        k = j
        while k < len(s) and s[k] != '\n' and s[k] != ';': k += 1
        if DECL.match(s[j:k]): j = k + 1; continue
        pos = j; break
    return pos if pos is not None else j
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='surrogateescape').read()
cnt = 0
# a) vfs_fstatat -> ksu_handle_stat
m = re.search(r'int vfs_fstatat\(([^)]*)\)', s, re.S)
if m:
    prm = [x.strip().split()[-1].lstrip('*') for x in m.group(1).split(',') if x.strip()]
    if len(prm) >= 3:
        pos = decl_end_of(m.end(), s)
        if pos is not None:
            s = s[:pos] + (
                "\n\t/* ReSukiSU: hook handler prototype */\n"
                "\textern int ksu_handle_stat(int *dfd, const char __user **filename_user,\n"
                "\t\tint *flags);\n"
                "\n\t/* ReSukiSU hook */\n"
                f"\tif (ksu_handle_stat(&{prm[0]}, &{prm[1]}, &{prm[2]}))\n"
                "\t\treturn -EPERM;\n") + s[pos:]
            cnt += 1
# b) newfstatat -> ksu_handle_newfstat_ret
m = re.search(r'SYSCALL_DEFINE4\(newfstatat,', s)
if m:
    pos = decl_end_of(m.end(), s)
    if pos is not None:
        s = s[:pos] + (
            "\n\t/* ReSukiSU: hook handler prototype */\n"
            "\textern void ksu_handle_newfstat_ret(unsigned int *fd,\n"
            "\t\tstruct stat __user **statbuf_ptr);\n"
            "\n\t/* ReSukiSU hook */\n\t{\n\tunsigned int _fd = dfd;\n"
            "\tstruct stat __user **_sb = &statbuf;\n"
            "\tksu_handle_newfstat_ret(&_fd, &_sb);\n\t}\n") + s[pos:]
        cnt += 1
# c) fstat64 -> ksu_handle_fstat64_ret
m = re.search(r'SYSCALL_DEFINE2\(fstat64,', s)
if m:
    pos = decl_end_of(m.end(), s)
    if pos is not None:
        s = s[:pos] + (
            "\n\t/* ReSukiSU: hook handler prototype */\n"
            "\textern void ksu_handle_fstat64_ret(unsigned long *fd,\n"
            "\t\tstruct stat64 __user **statbuf_ptr);\n"
            "\n\t/* ReSukiSU hook */\n\t{\n\tunsigned long _fd = fd;\n"
            "\tstruct stat64 __user **_sb = &statbuf;\n"
            "\tksu_handle_fstat64_ret(&_fd, &_sb);\n\t}\n") + s[pos:]
        cnt += 1
if cnt != 3:
    sys.stderr.write('    stat.c: 只注入 %d/3\n' % cnt)
    sys.exit(3)
open(p, 'w', encoding='utf-8', errors='surrogateescape', newline='').write(s)
sys.exit(0)
PYEOF
    for h in ksu_handle_stat ksu_handle_newfstat_ret ksu_handle_fstat64_ret; do
        do_hook "fs/stat.c" "$h" && ok "stat.c  $h ✓" || bad "stat.c  $h ✗"
    done
fi

# --- 4) kernel/reboot.c : ksu_handle_sys_reboot ---
#   原型（supercalls.c:1016）：
#     int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,
#                              void __user **arg);
F="$KS/kernel/reboot.c"
if do_hook "kernel/reboot.c" "ksu_handle_sys_reboot"; then
    ok "reboot.c  sys_reboot ✓"
else
    python3 - "$F" <<'PYEOF'
import sys, re
DECL = re.compile(
    r'^\s*(const\s+|struct\s+|union\s+|enum\s+|unsigned\s+|signed\s+|static\s+|'
    r'register\s+|volatile\s+|inline\s+|long\s+|short\s+|int\s+|char\s+|bool\s+|'
    r'void\s+|size_t\s+|uid_t\s+|gid_t\s+|kuid_t\s+|kgid_t\s+|mode_t\s+|dev_t\s+|'
    r'loff_t\s+|pid_t\s+|atomic_t\s+|spinlock_t\s+|struct\s+\w+\s*\**\s*\w+\s*(\[|;|=))')
def decl_end_of(sig_end, s):
    i = s.find('{', sig_end)
    if i < 0: return None
    j = i + 1; pos = None
    while j < len(s):
        while j < len(s) and s[j] in ' \t\r\n': j += 1
        if j >= len(s): break
        if s.startswith('/*', j):
            e = s.find('*/', j + 2); j = (e + 2) if e > 0 else len(s); continue
        if s.startswith('//', j):
            e = s.find('\n', j); j = (e + 1) if e > 0 else len(s); continue
        k = j
        while k < len(s) and s[k] != '\n' and s[k] != ';': k += 1
        if DECL.match(s[j:k]): j = k + 1; continue
        pos = j; break
    return pos if pos is not None else j
path = sys.argv[1]
s = open(path, encoding='utf-8', errors='surrogateescape').read()
m = re.search(r'SYSCALL_DEFINE4\(reboot,', s)
if not m: sys.exit(1)
pos = decl_end_of(m.end(), s)
if pos is None: sys.exit(1)
_ext = ("\n\t/* ReSukiSU: hook handler prototype */\n"
        "\textern int ksu_handle_sys_reboot(int magic1, int magic2,\n"
        "\t\tunsigned int cmd, void __user **arg);\n")
_hook = ("\n\t/* ReSukiSU hook */\n"
         "\tif (ksu_handle_sys_reboot(magic1, magic2, cmd, &arg))\n"
         "\t\treturn -EPERM;\n")
s = s[:pos] + _ext + _hook + s[pos:]
open(path, 'w', encoding='utf-8', errors='surrogateescape', newline='').write(s)
sys.exit(0)
PYEOF
    do_hook "kernel/reboot.c" "ksu_handle_sys_reboot" && ok "reboot.c  sys_reboot ✓" || bad "reboot.c  sys_reboot ✗"
fi

# ---- 汇总：按 Kbuild 实际 grep 的 6 个检查点逐一验证 ----
say ""
say "  ── Kbuild 将 grep 检查这 6 处 ──"
MISSING=0
for c in "fs/exec.c:ksu_handle_execveat" \
         "fs/open.c:ksu_handle_faccessat" \
         "fs/stat.c:ksu_handle_stat" \
         "fs/stat.c:ksu_handle_newfstat_ret" \
         "fs/stat.c:ksu_handle_fstat64_ret" \
         "kernel/reboot.c:ksu_handle_sys_reboot"; do
    cf="${c%%:*}"; ch="${c#*:}"
    if [ ! -f "$KS/$cf" ]; then
        bad "$ch  (缺文件 $cf)"; MISSING=$((MISSING+1))
    elif do_hook "$cf" "$ch"; then
        ok "$ch"
    else
        bad "$ch  ($cf)"; MISSING=$((MISSING+1))
    fi
done
say ""
say "  ── 以下 3 处由 Kbuild LSM / input_handler 托管，无需源码注入 ──"
ok "ksu_handle_setresuid(LSM)              ← 不注入"
ok "ksu_handle_sys_read(LSM)               ← 不注入"
ok "ksu_handle_input_handle_event(input)   ← 不注入"

if [ "$MISSING" -gt 0 ]; then
    bad "有 $MISSING 个 Kbuild 检查点缺失，Kbuild 会 $(error) 拒绝"
    exit 1
fi

# =============================================================================
step "5/8  生成配置"
# =============================================================================
# 注意：必须在 KSU 装好之后跑，否则 make 重跑 defconfig 时会找不到 kernelsu。
OUT="$DEST/out"
mkdir -p "$OUT"
DEFNAME=$(basename "$DEFCONF")     # ★ 不能去掉 _defconfig 后缀，否则 No rule to make target

if make -C "$KS" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" O="$OUT" \
        "$DEFNAME" > "$LOGS/defconfig.log" 2>&1; then
    ok "defconfig 完成（$DEFNAME）"
else
    bad "defconfig 失败，日志尾部："
    tail -20 "$LOGS/defconfig.log" | sed 's/^/      /'
    exit 1
fi

if make -C "$KS" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" O="$OUT" \
        olddefconfig > "$LOGS/olddefconfig.log" 2>&1; then
    ok "olddefconfig 完成"
else
    bad "olddefconfig 失败，日志尾部："
    tail -20 "$LOGS/olddefconfig.log" | sed 's/^/      /'
    exit 1
fi

# ---- 校验最终 .config 里关键项确实生效 ----
KCFG="$OUT/.config"
[ -f "$KCFG" ] || { bad "生成 .config 失败"; exit 1; }
CHK_FAIL=0
for k in KSU KSU_MANUAL_HOOK KALLSYMS_ALL; do
    if grep -qE "^CONFIG_$k=y$" "$KCFG" 2>/dev/null; then
        ok "CONFIG_$k=y"
    else
        bad "CONFIG_$k 未生效（= $(grep -E "CONFIG_$k" "$KCFG" 2>/dev/null | head -1 || echo 未设置)）"
        CHK_FAIL=$((CHK_FAIL+1))
    fi
done
# ---- 校验最终 .config 里检测项确实关闭 ----
# ★ 必须区分两种「未落地」原因，二者性质完全不同：
#   A) 被 select 回来（=y）→ 该检测仍在编译运行，有风险，必须报出来
#   B) .config 里根本没这一项→ Kconfig 没有该选项，
#      或依赖不满足被丢弃（如 INTEGRITY_AUDIT 依赖 INTEGRITY，
#      而 INTEGRITY 已被关闭 → 自动失效）。此时不编译，无风险。
# ★ 不能笼统说"不影响"：A 类是有风险的，必须让用户看到具体是哪几项。
OFF_OK=0
OFF_SELECTED=""      # A 类：仍在 =y，危险
OFF_ABSENT=""        # B 类：内核不支持/依赖不满足，无风险
for k in $DETECT_LIST; do
    if grep -qE "^# CONFIG_$k is not set$" "$KCFG" 2>/dev/null; then
        OFF_OK=$((OFF_OK+1))
    elif grep -qE "^CONFIG_$k=" "$KCFG" 2>/dev/null; then
        OFF_SELECTED="$OFF_SELECTED $k"
    else
        OFF_ABSENT="$OFF_ABSENT $k"
    fi
done
ok "检测项已关闭 $OFF_OK / $(echo $DETECT_LIST | wc -w)"
if [ -n "$OFF_SELECTED" ]; then
    bad "以下 $(( $(echo $OFF_SELECTED | wc -w) )) 项仍被 select 回来（检测在运行，有风险）:$OFF_SELECTED"
fi
if [ -n "$OFF_ABSENT" ]; then
    info "以下 $(( $(echo $OFF_ABSENT | wc -w) )) 项内核不存在或依赖不满足（不编译，无风险）:$OFF_ABSENT"
fi

# ★ SELinux 必须保持 enforcing（用户明确要求）
if grep -qE "^CONFIG_SECURITY_SELINUX=y$" "$KCFG" 2>/dev/null; then
    ok "SELinux 保持 enforcing（CONFIG_SECURITY_SELINUX=y）"
else
    info "SELinux 状态: $(grep -E 'CONFIG_SECURITY_SELINUX' "$KCFG" 2>/dev/null | head -1 || echo 未设置)"
fi
if grep -qE "^CONFIG_SECURITY_SELINUX_DEVELOP=y$" "$KCFG" 2>/dev/null; then
    bad "SELinux 被设为 DEVELOP（会进 permissive），与要求不符"
    CHK_FAIL=$((CHK_FAIL+1))
fi

# ---- Makefile 兜底修正 ----
# ★ 必须追加到文件末尾，不能替换现有行——
#   内核 Makefile 里有大量续行(\)，中途插入会破坏 recipe 连行导致语法错误。
if [ -f "$KS/Makefile" ]; then
    if ! grep -q 'KBUILD_CFLAGS += -fcommon' "$KS/Makefile" 2>/dev/null; then
        cat >> "$KS/Makefile" <<'MKFIX'

# ---- ReSukiSU 集成追加（build_all.sh）----
# ★ 追加在文件末尾，勿插入中间：内核 Makefile 大量使用 \ 续行，
#   中途插入会破坏 recipe 连行，导致 Makefile 语法错误。
KBUILD_CFLAGS += -fcommon
KBUILD_CFLAGS += -w
HOSTCFLAGS += -fcommon
MKFIX
        ok "Makefile 已追加 -fcommon / -w（抑制 4.9 与新内核的头文件冲突告警）"
    fi
fi

# =============================================================================
step "6/8  编译"
# =============================================================================
# ---- 自动探测并行度：多源交叉验证 ----
# ★ 只用 nproc 不可靠：cgroup 限额会让它偏小；不存在时静默退回 4。
detect_cpus() {
    _n=""
    if [ -r /proc/cpuinfo ]; then
        _p=$(grep -c '^processor[[:space:]]*:' /proc/cpuinfo 2>/dev/null)
        [ "${_p:-0}" -gt 0 ] && _n="$_p"
    fi
    _np=$(nproc 2>/dev/null)
    [ -z "$_n" ] && { [ -n "$_np" ] && [ "$_np" -gt 0 ] && _n="$_np"; }
    if [ -z "$_n" ] && [ -r /sys/fs/cgroup/cpu.max ]; then
        _q=$(awk '{print int($1/$2)}' /sys/fs/cgroup/cpu.max 2>/dev/null)
        [ -n "$_q" ] && [ "$_q" -gt 0 ] && _n="$_q"
    fi
    if [ -z "$_n" ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        _cq=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null)
        _cp=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null)
        if [ -n "$_cq" ] && [ "$_cq" != "-1" ] && [ -n "$_cp" ] && [ "$_cp" -gt 0 ]; then
            _q=$(( _cq / _cp )); [ "$_q" -gt 0 ] && _n="$_q"
        fi
    fi
    [ -n "$_n" ] && [ "$_n" -gt 0 ] || _n=4
    echo "$_n"
}

# ---- 识别运行环境（WSL 必须单独识别：WSL2 也带 hypervisor 标志位）----
RUN_ENV="physical"; VIRT_HINT=""
if [ -r /proc/sys/kernel/osrelease ] && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
    RUN_ENV="wsl"; VIRT_HINT="WSL ($(uname -r | tr -d '\0' | cut -c1-40))"
elif [ -f /.dockerenv ]; then
    RUN_ENV="container"; VIRT_HINT="docker/container"
elif [ -r /sys/class/dmi/id/product_name ]; then
    PN=$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr -d '\0')
    case "$PN" in
        *"VirtualBox"*|*"VMware"*|*"QEMU"*|*"KVM"*|*"Xen"*|*"Parallels"*)
            RUN_ENV="vm"; VIRT_HINT="$PN" ;;
    esac
fi
if [ "$RUN_ENV" = "physical" ] && grep -qE '(^flags.*\bhypervisor\b)' /proc/cpuinfo 2>/dev/null; then
    RUN_ENV="vm"; VIRT_HINT="hypervisor flag"
fi

# ★ 全占用可用核，不预留。内核编译是纯 CPU 密集型，
#   make 调度开销远小于并行收益，少一核就少 1/N 吞吐。
if [ -n "${KSU_NPROC:-}" ] && [ "${KSU_NPROC}" -gt 0 ] 2>/dev/null; then
    NPROC="$KSU_NPROC"
    NPROC_SRC="环境变量 KSU_NPROC"
else
    CPUS_TOTAL=$(detect_cpus)
    NPROC="$CPUS_TOTAL"
    case "$RUN_ENV" in
        wsl)NPROC_SRC="WSL ${CPUS_TOTAL}核 全占用" ;;
        vm)NPROC_SRC="虚拟机($VIRT_HINT) ${CPUS_TOTAL}核 全占用" ;;
        container)NPROC_SRC="容器 ${CPUS_TOTAL}核 全占用" ;;
        *)NPROC_SRC="物理机 ${CPUS_TOTAL}核 全占用" ;;
    esac
fi

info "并行度 -j$NPROC  [$NPROC_SRC]"
[ "$RUN_ENV" != "physical" ] && info "运行环境: $VIRT_HINT（如宿主卡顿可用 KSU_NPROC=N 减核）"
info "内存: $(free -h 2>/dev/null | awk '/^Mem:/{print $2" 总 / "$7" 可用"}')"
info "预计 25-60 分钟 · 日志 $LOGS/build.log"
info "另开窗口可看: tail -f $LOGS/build.log"

# ★ 落盘编译环境，事后可核对 make 到底用了哪套工具链
{
    echo "CROSS_COMPILE = $CROSS_COMPILE"
    echo "CC            = $(command -v "$CROSS_CC" 2>/dev/null)"
    echo "dumpmachine   = $("$CROSS_CC" -dumpmachine 2>/dev/null)"
    echo "LD            = $(command -v "$CROSS_LD" 2>/dev/null)"
    echo "NPROC         = $NPROC"
    echo "date= $(date)"
} > "$LOGS/toolchain.txt" 2>&1
info "工具链记录: $LOGS/toolchain.txt"

if [ "$CHK_FAIL" -gt 0 ]; then
    bad "配置校验未通过 $CHK_FAIL 项，建议先修正再编译"
    exit 1
fi

make -C "$KS" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" O="$OUT" -j"$NPROC" \
    > "$LOGS/build.log" 2>&1
RC=$?

say ""
info "已编译 $(find "$OUT" -name '*.o' 2>/dev/null | wc -l) 个 .o"

if [ $RC -ne 0 ]; then
    bad "编译失败（退出码 $RC）"
    say ""
    say "  ===== 工具链 ====="
    sed 's/^/    /' "$LOGS/toolchain.txt" 2>/dev/null
    say ""
    say "  ===== 关键报错（error: / Error N）====="
    grep -nE "error:|Error [0-9]" "$LOGS/build.log" | head -30 | sed 's/^/    /'
    say ""
    # ★ 不含 'error:' 的失败格式也要抓：链接错误、规则错误
    say "  ===== 链接/规则错误（不含 error: 的常见失败）====="
    grep -nE "undefined reference|undefined!|recipe for target .* failed|No rule to make target" \
        "$LOGS/build.log" | head -30 | sed 's/^/    /'
    say ""
    say "  ===== Kbuild hook 检查 ====="
    grep -iE "You lost|manual_hook|incompatible" "$LOGS/build.log" | head -8 | sed 's/^/    /'
    say ""
    # ★ 兜底 tail：任何失败格式都漏不掉
    say "  ===== 日志最后 50 行 ====="
    tail -n 50 "$LOGS/build.log" | sed 's/^/    /'
    say ""
    say "  日志 $LOGS/build.log  ($(stat -c%s "$LOGS/build.log" 2>/dev/null) 字节)"
    exit 1
fi
ok "编译成功"

# =============================================================================
step "7/8  收集产物"
# =============================================================================
IMGOUT="$DEST/dist"
mkdir -p "$IMGOUT"
FOUND=""
for f in "$OUT/arch/arm64/boot/Image.gz" "$OUT/arch/arm64/boot/Image"; do
    [ -f "$f" ] && cp -f "$f" "$IMGOUT/" && FOUND="$FOUND $(basename "$f")"
done
[ -n "$FOUND" ] || { bad "没找到内核镜像"
    ls -la "$OUT/arch/arm64/boot/" 2>/dev/null | head -15 | sed 's/^/      /'; exit 1; }
ok "内核镜像:$FOUND"

DTB="$OUT/arch/arm64/boot/dts"
if [ -d "$DTB" ]; then
    ok "设备树 $(find "$DTB" -name '*.dtb' 2>/dev/null | wc -l) 个 .dtb"
    ok "路径   $DTB"
fi

# =============================================================================
step "8/8  打包 kernel.img"
# =============================================================================
IMG="$IMGOUT/kernel.img"
TOOLS="$KS/tools"
IMG_GZ="$OUT/arch/arm64/boot/Image.gz"

# ★ 官方 tools/pack_kernerimage_cmd.sh 的实际内容（已从源码核对，非猜测）：
#     ./mkbootimg --kernel kernel --base 0x0 \
#       --cmdline "loglevel=4 initcall_debug=n page_tracker=on \
#       ... androidboot.selinux=enforcing buildvariant=user" \
#       --tags_offset 0x07A00000 --kernel_offset 0x00080000 \
#       --ramdisk_offset 0x07C00000 --header_version 1 \
#       --os_version 9 --os_patch_level 2019-11-01 --output kernel.img
#
#   ★ 它把内核文件名【写死为 kernel】（不是 Image.gz），
#     且不接任何位置参数 —— 误传 Image.gz 路径会报
#     "argument --kernel: can't open 'kernel'"。
#   ★ 这些 offset / os_version 是 CLT(P20 Pro) 官方值，
#     不要套用社区文档里荣耀 Note10 的参数。
MK_CMDLINE="loglevel=4 initcall_debug=n page_tracker=on unmovable_isolate1=2:192M,3:224M,4:256M printktimer=0xfff0a000,0x534,0x538 androidboot.selinux=enforcing buildvariant=user"
MK_TAGS="0x07A00000"; MK_KOFF="0x00080000"; MK_ROFF="0x07C00000"
MK_HV="1"; MK_OSV="9"; MK_OSP="2019-11-01"

PACKED=""
if [ -f "$IMG_GZ" ] && [ -f "$TOOLS/mkbootimg" ]; then
    info "用源码自带 mkbootimg + CLT 官方 offset"
    chmod +x "$TOOLS/mkbootimg" 2>/dev/null
    ( cd "$TOOLS" && ./mkbootimg --kernel "$IMG_GZ" --base 0x0 \
        --cmdline "$MK_CMDLINE" \
        --tags_offset "$MK_TAGS" --kernel_offset "$MK_KOFF" \
        --ramdisk_offset "$MK_ROFF" --header_version "$MK_HV" \
        --os_version "$MK_OSV" --os_patch_level "$MK_OSP" \
        --output kernel.img ) > "$LOGS/pack.log" 2>&1
    if [ -f "$TOOLS/kernel.img" ]; then
        cp -f "$TOOLS/kernel.img" "$IMG"
        rm -f "$TOOLS/kernel.img"
        PACKED=1
    fi
fi

if [ -z "$PACKED" ] && [ -f "$TOOLS/mkbootimg" ] && [ -f "$IMG_GZ" ]; then
    info "备用：直接输出到目标路径"
    ( cd "$TOOLS" && ./mkbootimg --kernel "$IMG_GZ" --base 0x0 \
        --cmdline "$MK_CMDLINE" \
        --tags_offset "$MK_TAGS" --kernel_offset "$MK_KOFF" \
        --ramdisk_offset "$MK_ROFF" --header_version "$MK_HV" \
        --os_version "$MK_OSV" --os_patch_level "$MK_OSP" \
        -o "$IMG" ) > "$LOGS/pack.log" 2>&1
    [ -f "$IMG" ] && PACKED=1
fi

if [ -n "$PACKED" ]; then
    ok "打包完成 $(du -h "$IMG" | cut -f1)"
    # ---- 自动校验头部：kernel_size 必须等于内核实际字节数 ----
    if [ -f "$SHARE/bootimg_hdr.py" ]; then
        python3 "$SHARE/bootimg_hdr.py" "$IMG" 2>/dev/null | sed 's/^/    /' \
            | head -8 || info "(头部校验工具缺失，可跳过)"
    fi
else
    # ★ 绝不伪造镜像：旧版的「4KB 全零 + Image.gz」缺 kernel_size/cmdline/
    #   offset 等头部字段，bootloader 读不出内核大小与启动参数，开机必然失败，
    #   但看起来"打包成功"—— 比直接报错更危险。
    bad "打包失败：未生成合法 kernel.img"
    say ""
    say "  ⚠️ 不会用「4KB 全零 + Image.gz」伪造镜像——缺少头部字段，开机必失败。"
    say ""
    say "  可用内核(gzip): $IMG_GZ"
    say "  mkbootimg      : $TOOLS/mkbootimg"
    say "  打包日志      : $LOGS/pack.log"
    say ""
    say "  打包日志尾部："
    tail -12 "$LOGS/pack.log" 2>/dev/null | sed 's/^/      /'
    exit 1
fi

# =============================================================================
echo ""
echo "############################################################"
echo "# ✓ 全部完成"
echo "############################################################"
echo ""
[ -f "$IMG" ] && echo "  kernel.img  : $IMG"
[ -d "$DTB" ] && echo "  设备树      : $DTB"
echo "  Image.gz    : $IMG_GZ"
echo "  工作目录    : $DEST"
echo "  编译日志    : $LOGS/build.log"
echo "  工具链记录  : $LOGS/toolchain.txt"
echo ""
echo "  刷入前请确认："
echo "    1) bootloader 已解锁"
echo "    2) 已备份原厂 boot.img"
echo "    3) kernel_size 与 Image.gz 大小一致（见上方头部校验）"
echo "############################################################"
