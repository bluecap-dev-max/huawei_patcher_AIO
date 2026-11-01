#!/usr/bin/env bash
###############################################################################
#  华为 EMUI 9 / 9.1（Linux 4.9 内核）+ ReSukiSU 一键内核构建
#  适用：任何 EMUI 9.x 机型的官方开源内核包（非单一机型）
###############################################################################
#  用法：
#     bash build_all.sh                    # 自动用脚本所在目录
#     bash build_all.sh <共享目录>          # 指定含内核 tar 包的目录
#     bash build_all.sh <内核tar包路径>      # 直接指定那个 .tar.gz
#     bash build_all.sh <共享目录> <输出目录> # 手动指定输出目录
#
#  可选环境变量：
#     KSU_NPROC=N        # 手动指定编译并行度
#     KSU_DEFCONFIG=xxx  # 手动指定 defconfig 文件名（多 defconfig 时必用）
#     KSU_SUSFS=0        # 关闭 SUSFS，回到 MANUAL_HOOK 模式（默认开启 SUSFS）
#
#  环境要求：WSL (Ubuntu 20.04+) 或 Linux，能用 sudo 装包
#  核心设计：
#    · 自动安装缺失工具（宿主工具链 + aarch64 交叉编译器）
#    · 自动探测可用核心，全占用（可用 KSU_NPROC=N 覆盖）
#    · WSL 下输出目录强制走 $HOME（ext4），避开 /mnt/* 的跨文件系统瓶颈
#    · ReSukiSU 非 GKI：默认走 SUSFS inline hook（8 个检查点），
#      KSU_SUSFS=0 时回退到 MANUAL_HOOK（6 个 hook + LSM 托管 3 个）
#    · SUSFS v2.3.0 4.9 移植补丁 + 华为 4.9.148 树专用 fixup
#    · 严格按社区文档（EMUI 9/9.1 通用清单）关闭检测，SELinux 保持 enforcing
#    · 打包参数从内核源码自带的 pack_kernerimage_cmd.sh 提取——
#      每个机型用自己的官方值，脚本不写死任何机型的 offset
###############################################################################

SHARE_ARG="${1:-}"
DEST="${2:-$HOME/ksu-kernel-final}"

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
        /mnt/*|/media/*) DEST="$HOME/ksu-kernel-final" ;;
    esac
fi

# ---- 定位共享目录 ----
# ★ 顺序：脚本自身目录（最可靠）→ WSL 挂载盘下的构建类目录 → /media/sf_*（VirtualBox）
#   候选路径只做"初筛"，真正的有效性由后面的 tar 包搜索与参数校验把关，
#   所以这里不写死任何具体目录名。
KERTAR=""
SHARE="$SHARE_ARG"
if [ -z "$SHARE" ]; then
    SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
    SHARE_CANDS="$SELF_DIR"
    # WSL 挂载盘（/mnt/c /mnt/d ...）下一级目录里名字像构建目录的
    for m in /mnt/*/; do
        for sub in "$m"*build*/ "$m"*kirin*/ "$m"*ksu*/ "$m"*resukisu*/; do
            [ -d "$sub" ] && SHARE_CANDS="$SHARE_CANDS $sub"
        done
    done
    # VirtualBox / VMware 共享盘
    for m in /media/sf_*/ /mnt/hgfs/*/; do
        [ -d "$m" ] && SHARE_CANDS="$SHARE_CANDS $m"
    done
    for c in $SHARE_CANDS; do
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
    echo "    bash $0 <含内核 tar 包的目录>"
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

# ★ 把实际使用的输出目录落盘，供 test.sh 读取 ——
#   这样清理脚本永远清的是同一个目录（包括用户用第二个参数自定义的情况），
#   不靠正则去猜默认值，不会与本脚本失步。
_SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -n "$_SELF_DIR" ] && printf '%s\n' "$DEST" > "$_SELF_DIR/.ksu_dest" 2>/dev/null

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
HOST_PKGS="build-essential bc flex bison libssl-dev libncurses-dev python3 git cpio patch"
MISSING_HOST=""
for t in make bc flex bison python3 git tar gzip cpio patch; do
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
    say "        libssl-dev libncurses-dev python3 git cpio patch"
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
        # ★ 华为官方开源内核包的命名规律：{机型代号}_PIE_EMUI9.1.0_opensource.tar.gz
        #   机型代号随机器变化（CLT/VTR/BLA/EML/...），所以按通用特征匹配：
        #   文件名含 opensource / EMUI / PIE / kernel，且体积大（几百 MB）。
        for cand in \
            "$SHARE"/*opensource*.tar.gz "$SHARE"/*EMUI*.tar.gz \
            "$SHARE"/*PIE*.tar.gz "$SHARE"/*kernel*.tar.gz \
            "$SHARE"/ISO/*opensource*.tar.gz "$SHARE"/ISO/*EMUI*.tar.gz \
            "$SHARE"/*/*opensource*.tar.gz "$SHARE"/*/*EMUI*.tar.gz \
            ; do
            [ -f "$cand" ] && KERTAR="$cand" && break
        done
        # ★ glob 匹配不到会原样保留通配符字面量，深层目录/非常规命名会漏，
        #   用 find 再兜一次底。
        if [ -z "$KERTAR" ]; then
            KERTAR=$(find "$SHARE" -maxdepth 3 -type f \
                     \( -iname '*opensource*.tar.gz' -o -iname '*emui*.tar.gz' \
                        -o -iname '*pie*kernel*.tar.gz' \) 2>/dev/null | head -1)
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
            say "  ★ 这些都不是华为官方内核包（官方包名形如"
            say "    {机型代号}_PIE_EMUI9.1.0_opensource.tar.gz，通常数百 MB）。"
        else
            say "  (一个 .tar.gz 都没有)"
        fi
        say ""
        say "  可直接指定内核包："
        say "    bash $0 \"\$(find $SHARE -maxdepth 3 -iname '*opensource*.tar.gz' | head -1)\""
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
#  ★ 严格只按社区文档（EMUI 9/9.1 全机型通用清单），逐条照抄，
#    多一项都不关、无一项都不关。该清单与具体机型无关。

# ---- 选择 defconfig：不写死任何机型名 ----
#   优先级：
#     1) 环境变量 KSU_DEFCONFIG（多 defconfig 歧义时最可靠）
#     2) 文件名匹配机型代号（从内核 tar 包名前缀推断，如 CLT_PIE_* → CLT）
#     3) merge_*_defconfig（华为 EMUI 9 官方包惯例的合并 defconfig）
#     4) 仅有一个 defconfig → 直接用
#     5) 仍歧义 → 列出全部候选并报错，要求显式指定
CFGDIR="$KS/arch/arm64/configs"
DEFCONF=""
if [ -n "${KSU_DEFCONFIG:-}" ]; then
    DEFCONF="$CFGDIR/$KSU_DEFCONFIG"
    [ -f "$DEFCONF" ] || { bad "KSU_DEFCONFIG 指定的文件不存在: $KSU_DEFCONFIG"; exit 1; }
else
    # 从内核 tar 包名推断机型代号（如 CLT_PIE_EMUI9.1.0_opensource → CLT）
    DEV_CODE=$(basename "${KERTAR:-}" | sed -n 's/^\([A-Za-z0-9]*\)_PIE.*/\1/p' | tr 'A-Z' 'a-z')
    [ -n "$DEV_CODE" ] && \
        DEFCONF=$(find "$CFGDIR" -iname "*${DEV_CODE}*defconfig" 2>/dev/null | head -1)
    [ -z "$DEFCONF" ] && \
        DEFCONF=$(find "$CFGDIR" -name 'merge_*defconfig' 2>/dev/null | head -1)
    if [ -z "$DEFCONF" ]; then
        ALL_CFG=$(find "$CFGDIR" -name '*_defconfig' 2>/dev/null)
        if [ "$(echo "$ALL_CFG" | grep -c .)" = "1" ]; then
            DEFCONF="$ALL_CFG"
        elif [ -n "$ALL_CFG" ]; then
            bad "有多个 defconfig 无法自动判定，请用 KSU_DEFCONFIG 显式指定："
            echo "$ALL_CFG" | sed "s|$CFGDIR/|      |"
            say ""
            say "  用法：KSU_DEFCONFIG=<文件名> bash $0 ..."
            exit 1
        fi
    fi
fi
if [ -z "$DEFCONF" ] || [ ! -f "$DEFCONF" ]; then
    bad "找不到 defconfig"
    ls -la "$CFGDIR/" 2>/dev/null | head -15 | sed 's/^/      /'
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
step "3/8  安装 ReSukiSU + 集成 SUSFS"
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
# ---- SUSFS：Linux 4.9 NON-GKI 内核侧补丁 ----
# =============================================================================
# ★ 为什么不用官方 susfs4ksu 的 kernel-4.9 分支？
#   官方 kernel-4.9 分支停在 SUSFS v1.5.5（2025-02），而当前 ReSukiSU 4.x
#   的 kernel 代码调用的是 v2.x API（susfs_show_version / susfs_get_enabled_features
#   / susfs_run_sus_path_loop / susfs_set_current_proc_umounted ...），
#   用 v1.5.5 会直接编译失败。
#   → 这里用社区维护的 SUSFS v2.3.0 NON-GKI 4.9 移植补丁
#     （JackA1ltman/NonGKI_Kernel_Build_2nd，经 ReSukiSU 4.9 项目验证）。
#
# ★ 补丁基线是 4.9.186/4.9.337（CAF 4.9），在华为 4.9.148 真源码上实测：
#     fs/namei.c / fs/readdir.c / fs/proc/* 等 15 个文件全部直接应用成功，
#     其余由 fixup 脚本按华为树修复（每一项都有真实编译错误对应）：
#       include/linux/susfs_def.h  linux/bits.h 是 5.x 才有的头 → 换 bitops.h
#       fs/namespace.c             华为多一行 hisi include → Hunk #1 不匹配
#       kernel/sys.c               华为 newuname 不用临时结构体 → uname spoof 改写
#       fs/stat.c                  4.9 无 statx/result_mask → 等价移植（并补
#                                  susfs_def.h include，补丁本身没加）
#       fs/proc/task_mmu.c         纯尾随空格 hunk（华为无该上下文）
#       fs/notify/fdinfo.c         4.9 全系缺 inotify_mark_user_mask()
#       fs/proc/cmdline.c          fuzz 会把 hunk 贴错位置 → 重写为正确结构
#       fs/read_write.c / input.c  块作用域 extern 不能带 __read_mostly
#                                  （error: section attribute cannot be
#                                  specified for local variables）
#       fs/susfs.c                 susfs_run_sus_path_loop 是 static，
#                                  ReSukiSU 需要外部调用 → 去 static
#       fs/proc/task_mmu.c         4.9 没有 show_vma_header_prefix() → 补 helper
#       fs/stat.c                  SUSFS 模式不能注入 manual 专用的
#                                  newfstat_ret/fstat64_ret（会 undefined reference）
SUSFS_ON=""
KSU_SUSFS="${KSU_SUSFS:-1}"
case "$KSU_SUSFS" in
    0|n|N|no|NO|off|false)
        info "KSU_SUSFS=$KSU_SUSFS → 跳过 SUSFS，回退 MANUAL_HOOK"
        # 清掉以前可能写进 defconfig 的 SUSFS 项，避免“半开”状态
        if [ -n "${DEFCONF:-}" ] && [ -f "$DEFCONF" ]; then
            sed -i '/^CONFIG_KSU_SUSFS/d' "$DEFCONF"
            sed -i '/^# CONFIG_KSU_SUSFS/d' "$DEFCONF"
        fi
        ;;
    *)
        SUSFS_ON=1
        SUSFS_DIR=""
        for c in "$SHARE/susfs4ksu-4.9" "$SHARE/src/susfs4ksu-4.9" \
                 "$SHARE/susfs" "$SHARE/SUSFS"; do
            if [ -f "$c/susfs_patch_to_4.9.patch" ] && \
               [ -f "$c/fixup_susfs_4.9_huawei.py" ]; then
                SUSFS_DIR="$c"; break
            fi
        done
        if [ -z "$SUSFS_DIR" ]; then
            bad "找不到 SUSFS 4.9 补丁目录"
            say ""
            say "  需要以下两个文件（默认应放在 $SHARE/susfs4ksu-4.9/）："
            say "    susfs_patch_to_4.9.patch"
            say "    fixup_susfs_4.9_huawei.py"
            say ""
            say "  也可以设置 KSU_SUSFS=0 跳过 SUSFS，只用 MANUAL_HOOK。"
            exit 1
        fi
        info "SUSFS 源: $SUSFS_DIR"
        info "只修改 $DEST 下的解包副本；原始 tar 包和 src/ 均只读，不会被改动"

        # ★ ReSukiSU 的 Kconfig: config KSU_SUSFS depends on THREAD_INFO_IN_TASK
        #   华为 4.9.148 已 select，若没有会在 olddefconfig 被静默丢弃，
        #   这里提前硬失败，避免白编译一小时。
        if ! grep -q 'select THREAD_INFO_IN_TASK' "$KS/arch/arm64/Kconfig" 2>/dev/null && \
           ! grep -qE '^CONFIG_THREAD_INFO_IN_TASK=y$' "$DEFCONF" 2>/dev/null; then
            bad "内核没有 THREAD_INFO_IN_TASK，CONFIG_KSU_SUSFS 的 Kconfig 依赖不满足"
            say "    arch/arm64/Kconfig 未 select，defconfig 也没有该行。"
            say "    请用 KSU_SUSFS=0 构建 MANUAL_HOOK 版本。"
            exit 1
        fi
        ok "THREAD_INFO_IN_TASK 满足（CONFIG_KSU_SUSFS 可开启）"

        # 幂等判断：三个关键文件都在且版本宏已定义才算已集成
        if [ -f "$KS/fs/susfs.c" ] && [ -f "$KS/include/linux/susfs_def.h" ] && \
           grep -q '^#define SUSFS_VERSION' "$KS/include/linux/susfs.h" 2>/dev/null; then
            ok "SUSFS 已应用，跳过补丁（幂等）"
        else
            info "应用 SUSFS v2.3.0 4.9 补丁（预期少数 hunk 由 fixup 处理）..."
            ( cd "$KS" && patch -p1 -l --forward --fuzz=3 \
                --no-backup-if-mismatch \
                < "$SUSFS_DIR/susfs_patch_to_4.9.patch" ) \
                > "$LOGS/susfs-patch.log" 2>&1
            PRC=$?
            if [ $PRC -eq 0 ]; then
                ok "补丁全部 hunk 直接应用成功"
            elif [ $PRC -eq 1 ]; then
                info "有 hunk 未直接应用（退出码 1），交给 fixup 处理"
                grep -E 'FAILED|Hunk|checking file' "$LOGS/susfs-patch.log" \
                    | grep -B1 FAILED | head -20 | sed 's/^/      /'
            else
                bad "patch 执行异常（退出码 $PRC）"
                tail -20 "$LOGS/susfs-patch.log" | sed 's/^/      /'
                exit 1
            fi
        fi

        info "按华为 4.9.148 树结构做 fixup..."
        if ! python3 "$SUSFS_DIR/fixup_susfs_4.9_huawei.py" "$KS"; then
            bad "SUSFS fixup 失败（详见上方输出与 $LOGS/susfs-patch.log）"
            say ""
            say "  若提示某文件有 .rej，说明该内核版本的结构与 4.9.148 有出入，"
            say "  需要按 .rej 手工调整；不要带着 .rej 继续编译。"
            exit 1
        fi
        ok "SUSFS fixup 完成"

        # ---- 关键文件与 Makefile 接入校验 ----
        for f in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
            [ -f "$KS/$f" ] || { bad "SUSFS 关键文件缺失: $f"; exit 1; }
        done
        if ! grep -q 'susfs.o' "$KS/fs/Makefile" 2>/dev/null; then
            printf '\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n' >> "$KS/fs/Makefile"
            info "fs/Makefile 补加 obj-\$(CONFIG_KSU_SUSFS) += susfs.o"
        fi
        ok "SUSFS 就位: $(grep -m1 '^#define SUSFS_VERSION' "$KS/include/linux/susfs.h" | sed 's/.*"\(.*\)".*/\1/')"

        # ---- defconfig：开 SUSFS、关 MANUAL_HOOK ----
        # ★ 必须关 MANUAL_HOOK：
        #   ksu.c 的 ksu_hook_init() 在 CONFIG_KSU_MANUAL_HOOK 下选
        #   ksu_lsm_hook_init()，只有 SUSFS 分支才调 susfs_init()；
        #   两者同开会让 SUSFS 的内部结构/工作队列不初始化。
        if [ -n "${DEFCONF:-}" ] && [ -f "$DEFCONF" ]; then
            for k in KSU_MANUAL_HOOK KSU_MANUAL_HOOK_AUTO_SETUID_HOOK \
                     KSU_MANUAL_HOOK_AUTO_INITRC_HOOK KSU_MANUAL_HOOK_AUTO_INPUT_HOOK; do
                sed -i "/^CONFIG_$k=/d;/^# CONFIG_$k is not set\$/d" "$DEFCONF"
                printf '# CONFIG_%s is not set\n' "$k" >> "$DEFCONF"
            done
            for o in KSU_SUSFS SUS_PATH SUS_MOUNT SUS_KSTAT SPOOF_UNAME \
                     ENABLE_LOG HIDE_KSU_SUSFS_SYMBOLS SPOOF_CMDLINE_OR_BOOTCONFIG \
                     OPEN_REDIRECT SUS_MAP; do
                key="CONFIG_KSU_SUSFS"
                [ "$o" = "KSU_SUSFS" ] || key="CONFIG_KSU_SUSFS_$o"
                grep -qE "^${key}=" "$DEFCONF" 2>/dev/null && continue
                printf '%s=y\n' "$key" >> "$DEFCONF"
            done
            ok "defconfig 已开 SUSFS + 9 个子项，并显式关闭 MANUAL_HOOK"
        fi
        ;;
esac

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
step "4/8  打 hook（SUSFS inline / MANUAL_HOOK）"
# =============================================================================
# ★ 4.9 是非 GKI → TP_HOOK 会被 Kbuild $(error)。
#   · KSU_SUSFS=1（默认）→ SUSFS inline hook 模式：需要 8 个检查点，
#     其中 setuid / sys_read / input 不再由 LSM/input_handler 托管；
#     另外 SUSFS 用 vfs_fstat 代替 manual 模式下的 newfstat_ret/fstat64_ret
#     来修正 init.rc 的 st_size。
#   · KSU_SUSFS=0        → MANUAL_HOOK 模式：只注入 6 个，
#     setuid / init rc / input 由 LSM / input_handler 托管。
for o in "CONFIG_KSU=y" "CONFIG_KALLSYMS_ALL=y"; do
    grep -qE "^${o%=}=" "$DEFCONF" 2>/dev/null && continue
    printf '%s\n' "$o" >> "$DEFCONF"
done
if [ -z "$SUSFS_ON" ]; then
    for o in "CONFIG_KSU_MANUAL_HOOK=y" \
             "CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y" \
             "CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y" \
             "CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y"; do
        grep -qE "^${o%=}=" "$DEFCONF" 2>/dev/null && continue
        printf '%s\n' "$o" >> "$DEFCONF"
    done
    ok "defconfig 已加 KSU + MANUAL_HOOK"
else
    ok "defconfig 已加 KSU（SUSFS inline hook 模式，不启用 MANUAL_HOOK）"
fi

do_hook() {   # do_hook <相对路径> <hook名>  已注入返回0
    grep -q "$2" "$KS/$1" 2>/dev/null
}

# ★ 从 SUSFS 切回 MANUAL_HOOK 时，源码里残留的 3 个 SUSFS inline hook 会和
#   LSM / input_handler 重复调用（setuid 执行两次）。这种情况必须重新解包，
#   不能靠“跳过注入”混过去。
if [ -z "$SUSFS_ON" ]; then
    RESIDUE=""
    do_hook "kernel/sys.c"           "ksu_handle_setresuid"          && RESIDUE="$RESIDUE kernel/sys.c"
    do_hook "fs/read_write.c"        "ksu_handle_sys_read"           && RESIDUE="$RESIDUE fs/read_write.c"
    do_hook "drivers/input/input.c"  "ksu_handle_input_handle_event" && RESIDUE="$RESIDUE drivers/input/input.c"
    if [ -n "$RESIDUE" ]; then
        bad "检测到 SUSFS inline hook 残留:$RESIDUE"
        say "    当前是 KSU_SUSFS=0（MANUAL_HOOK），这些 hook 会与 LSM 重复调用。"
        say "    请先运行  bash test.sh  清理源码后重新构建，或继续用 SUSFS 模式。"
        exit 1
    fi
fi

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
    r'void\s+|size_t\s+|ssize_t\s+|uid_t\s+|gid_t\s+|kuid_t\s+|kgid_t\s+|mode_t\s+|dev_t\s+|'
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
    r'void\s+|size_t\s+|ssize_t\s+|uid_t\s+|gid_t\s+|kuid_t\s+|kgid_t\s+|mode_t\s+|dev_t\s+|'
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

# --- 3) fs/stat.c ---
#   MANUAL_HOOK 模式（3 个 hook）：
#     int  ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#     void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#     void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);
#   SUSFS 模式（只 1 个）：
#     ksu_handle_newfstat_ret / ksu_handle_fstat64_ret 在 ReSukiSU 源码里
#     被 #ifdef CONFIG_KSU_MANUAL_HOOK 包着；SUSFS 模式关了 MANUAL_HOOK，
#     再注入这两个调用会 undefined reference。SUSFS 用 vfs_fstat +
#     ksu_handle_vfs_fstat 完成同样的 init.rc 尺寸修正。
#   ★ vfs_fstatat 的第二参数本就是 const char __user *filename，
#     所以直接 &filename，不要 (struct filename **) 强转（类型不匹配）。
F="$KS/fs/stat.c"
if do_hook "fs/stat.c" "ksu_handle_stat"; then
    if [ -n "$SUSFS_ON" ]; then
        ok "stat.c  stat ✓（SUSFS 模式不需要 newfstat_ret/fstat64_ret）"
    else
        ok "stat.c  stat / newfstat_ret / fstat64_ret ✓"
    fi
else
    python3 - "$F" "${SUSFS_ON:-0}" <<'PYEOF'
import sys, re
DECL = re.compile(
    r'^\s*(const\s+|struct\s+|union\s+|enum\s+|unsigned\s+|signed\s+|static\s+|'
    r'register\s+|volatile\s+|inline\s+|long\s+|short\s+|int\s+|char\s+|bool\s+|'
    r'void\s+|size_t\s+|ssize_t\s+|uid_t\s+|gid_t\s+|kuid_t\s+|kgid_t\s+|mode_t\s+|dev_t\s+|'
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
susfs_mode = (len(sys.argv) > 2 and sys.argv[2] not in ('', '0'))
s = open(p, encoding='utf-8', errors='surrogateescape').read()
cnt = 0
want = 1 if susfs_mode else 3
# a) vfs_fstatat -> ksu_handle_stat
m = re.search(r'int vfs_fstatat\(([^)]*)\)', s, re.S)
if m:
    prm = [x.strip().split()[-1].lstrip('*') for x in m.group(1).split(',') if x.strip()]
    if len(prm) >= 3:
        # ★ vfs_fstatat(int dfd, const char __user *filename,
        #                struct kstat *stat, int flag)
        #   第 3 个参数是 struct kstat *，必须把最后一个参数（flag）传给
        #   ksu_handle_stat 的 int *flags；早期版本误传 &stat，类型不匹配。
        stat_flags = prm[-1]
        pos = decl_end_of(m.end(), s)
        if pos is not None:
            s = s[:pos] + (
                "\n\t/* ReSukiSU: hook handler prototype */\n"
                "\textern int ksu_handle_stat(int *dfd, const char __user **filename_user,\n"
                "\t\tint *flags);\n"
                "\n\t/* ReSukiSU hook */\n"
                f"\tif (ksu_handle_stat(&{prm[0]}, &{prm[1]}, &{stat_flags}))\n"
                "\t\treturn -EPERM;\n") + s[pos:]
            cnt += 1
# b/c) 只有 MANUAL_HOOK 模式才注入 newfstat_ret / fstat64_ret
if not susfs_mode:
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
if cnt != want:
    sys.stderr.write('    stat.c: 只注入 %d/%d\n' % (cnt, want))
    sys.exit(3)
open(p, 'w', encoding='utf-8', errors='surrogateescape', newline='').write(s)
sys.exit(0)
PYEOF
    if [ -n "$SUSFS_ON" ]; then
        do_hook "fs/stat.c" "ksu_handle_stat" && ok "stat.c  ksu_handle_stat ✓" || bad "stat.c  ksu_handle_stat ✗"
    else
        for h in ksu_handle_stat ksu_handle_newfstat_ret ksu_handle_fstat64_ret; do
            do_hook "fs/stat.c" "$h" && ok "stat.c  $h ✓" || bad "stat.c  $h ✗"
        done
    fi
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
    r'void\s+|size_t\s+|ssize_t\s+|uid_t\s+|gid_t\s+|kuid_t\s+|kgid_t\s+|mode_t\s+|dev_t\s+|'
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

# --- 5) SUSFS inline 模式专用：kernel/sys.c : ksu_handle_setresuid ---
#   原型（setuid_hook.h:10）：
#     int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);
#   ★ 只在 SUSFS 模式注入：MANUAL_HOOK 模式由 LSM task_fix_setuid 托管，
#     两处同时调用会在每个 setuid 上重复执行 hook。
if [ -n "$SUSFS_ON" ]; then
    F="$KS/kernel/sys.c"
    if do_hook "kernel/sys.c" "ksu_handle_setresuid"; then
        ok "sys.c  setresuid ✓"
    else
        python3 - "$F" <<'PYEOF'
import sys, re
DECL = re.compile(
    r'^\s*(const\s+|struct\s+|union\s+|enum\s+|unsigned\s+|signed\s+|static\s+|'
    r'register\s+|volatile\s+|inline\s+|long\s+|short\s+|int\s+|char\s+|bool\s+|'
    r'void\s+|size_t\s+|ssize_t\s+|uid_t\s+|gid_t\s+|kuid_t\s+|kgid_t\s+|mode_t\s+|dev_t\s+|'
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
m = re.search(r'SYSCALL_DEFINE3\(setresuid,', s)
if not m: sys.exit(1)
pos = decl_end_of(m.end(), s)
if pos is None: sys.exit(1)
_ext = ("\n\t/* ReSukiSU: hook handler prototype */\n"
        "\textern int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid);\n")
_hook = ("\n\t/* ReSukiSU hook */\n"
         "\t(void)ksu_handle_setresuid(ruid, euid, suid);\n")
s = s[:pos] + _ext + _hook + s[pos:]
open(p, 'w', encoding='utf-8', errors='surrogateescape', newline='').write(s)
sys.exit(0)
PYEOF
        do_hook "kernel/sys.c" "ksu_handle_setresuid" && ok "sys.c  setresuid ✓" || bad "sys.c  setresuid ✗"
    fi

    # --- 6) SUSFS inline 模式专用：fs/read_write.c : ksu_handle_sys_read ---
    #   原型（ksud.c:658，BakaSU/ReSukiSU 三参数版）：
    #     int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr,
    #                             size_t *count_ptr);
    #   4.9 的 SYSCALL_DEFINE3(read,...) 里 buf/count 是函数形参，直接取址。
    F="$KS/fs/read_write.c"
    if do_hook "fs/read_write.c" "ksu_handle_sys_read"; then
        ok "read_write.c  sys_read ✓"
    else
        python3 - "$F" <<'PYEOF'
import sys, re
DECL = re.compile(
    r'^\s*(const\s+|struct\s+|union\s+|enum\s+|unsigned\s+|signed\s+|static\s+|'
    r'register\s+|volatile\s+|inline\s+|long\s+|short\s+|int\s+|char\s+|bool\s+|'
    r'void\s+|size_t\s+|ssize_t\s+|uid_t\s+|gid_t\s+|kuid_t\s+|kgid_t\s+|mode_t\s+|dev_t\s+|'
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
m = re.search(r'SYSCALL_DEFINE3\(read,', s)
if not m: sys.exit(1)
pos = decl_end_of(m.end(), s)
if pos is None: sys.exit(1)
# ★ 块作用域（函数体内）的 extern 不能带 __read_mostly 段属性：
#     error: section attribute cannot be specified for local variables
#   变量定义在 ksud.c 里已经是 __read_mostly，这里只声明类型。
_ext = ("\n\t/* ReSukiSU: hook handler prototype */\n"
        "\textern bool ksu_init_rc_hook;\n"
        "\textern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr,\n"
        "\t\tsize_t *count_ptr);\n")
_hook = ("\n\t/* ReSukiSU hook */\n"
         "\tif (unlikely(ksu_init_rc_hook))\n"
         "\t\tksu_handle_sys_read(fd, &buf, &count);\n")
s = s[:pos] + _ext + _hook + s[pos:]
open(p, 'w', encoding='utf-8', errors='surrogateescape', newline='').write(s)
sys.exit(0)
PYEOF
        do_hook "fs/read_write.c" "ksu_handle_sys_read" && ok "read_write.c  sys_read ✓" || bad "read_write.c  sys_read ✗"
    fi

    # --- 7) SUSFS inline 模式专用：drivers/input/input.c : input hook ---
    #   原型（ksud.c:684）：
    #     int ksu_handle_input_handle_event(unsigned int *type,
    #                                       unsigned int *code, int *value);
    #   4.9 的 void input_event(...) 形参是值传递，调用处取址。
    F="$KS/drivers/input/input.c"
    if do_hook "drivers/input/input.c" "ksu_handle_input_handle_event"; then
        ok "input.c  input_handle_event ✓"
    else
        python3 - "$F" <<'PYEOF'
import sys, re
DECL = re.compile(
    r'^\s*(const\s+|struct\s+|union\s+|enum\s+|unsigned\s+|signed\s+|static\s+|'
    r'register\s+|volatile\s+|inline\s+|long\s+|short\s+|int\s+|char\s+|bool\s+|'
    r'void\s+|size_t\s+|ssize_t\s+|uid_t\s+|gid_t\s+|kuid_t\s+|kgid_t\s+|mode_t\s+|dev_t\s+|'
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
m = re.search(r'void input_event\(struct input_dev \*dev,', s)
if not m: sys.exit(1)
pos = decl_end_of(m.end(), s)
if pos is None: sys.exit(1)
# ★ 同上：函数体内 extern 不能带 __read_mostly。
_ext = ("\n\t/* ReSukiSU: hook handler prototype */\n"
        "\textern bool ksu_input_hook;\n"
        "\textern int ksu_handle_input_handle_event(unsigned int *type,\n"
        "\t\tunsigned int *code, int *value);\n")
_hook = ("\n\t/* ReSukiSU hook */\n"
         "\tif (unlikely(ksu_input_hook))\n"
         "\t\tksu_handle_input_handle_event(&type, &code, &value);\n")
s = s[:pos] + _ext + _hook + s[pos:]
open(p, 'w', encoding='utf-8', errors='surrogateescape', newline='').write(s)
sys.exit(0)
PYEOF
        do_hook "drivers/input/input.c" "ksu_handle_input_handle_event" \
            && ok "input.c  input_handle_event ✓" || bad "input.c  input_handle_event ✗"
    fi

    # --- 8) SUSFS inline 模式专用：fs/stat.c : vfs_fstat 的 init.rc 尺寸修正 ---
    #   原型（ksud.c:576，CONFIG_KSU_SUSFS 专用）：
    #     void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr);
    #   作用：init.rc 内容被 KSU 注入后，fstat 报告的 st_size 要同步加上
    #   ksu_rc_len，否则隐藏内容与文件长度对不上。
    #   ★ 必须在 vfs_getattr() 填好 stat 之后、fdput() 之前调用。
    F="$KS/fs/stat.c"
    if do_hook "fs/stat.c" "ksu_handle_vfs_fstat"; then
        ok "stat.c  vfs_fstat ✓"
    else
        python3 - "$F" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='surrogateescape').read()
m = re.search(r'int vfs_fstat\(unsigned int fd, struct kstat \*stat\)\s*\{', s)
if not m:
    sys.exit(1)
start = m.end()
end = s.find('\n}', start)
if end < 0:
    sys.exit(1)
body = s[start:end]
old = "\t\terror = vfs_getattr(&f.file->f_path, stat);\n\t\tfdput(f);"
new = ("\t\terror = vfs_getattr(&f.file->f_path, stat);\n"
       "#ifdef CONFIG_KSU_SUSFS\n"
       "\t\tif (unlikely(ksu_init_rc_hook))\n"
       "\t\t\tksu_handle_vfs_fstat(fd, &stat->size);\n"
       "#endif\n"
       "\t\tfdput(f);")
if "ksu_handle_vfs_fstat" not in body:
    if old not in body:
        sys.exit(3)
    body = body.replace(old, new, 1)
    s = s[:start] + body + s[end:]
_ext = ("#ifdef CONFIG_KSU_SUSFS\n"
        "extern bool ksu_init_rc_hook __read_mostly;\n"
        "extern void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr);\n"
        "#endif\n\n")
if "extern void ksu_handle_vfs_fstat" not in s:
    s = s.replace("int vfs_fstat(unsigned int fd, struct kstat *stat)",
                  _ext + "int vfs_fstat(unsigned int fd, struct kstat *stat)", 1)
open(p, 'w', encoding='utf-8', errors='surrogateescape', newline='').write(s)
sys.exit(0)
PYEOF
        do_hook "fs/stat.c" "ksu_handle_vfs_fstat" \
            && ok "stat.c  vfs_fstat ✓" || bad "stat.c  vfs_fstat ✗"
    fi
fi

# ---- 汇总：按实际 hook 模式逐一验证 ----
say ""
if [ -n "$SUSFS_ON" ]; then
    say "  ── SUSFS inline 模式将检查这 8 处 ──"
    HOOK_CHECK="fs/exec.c:ksu_handle_execveat \
fs/open.c:ksu_handle_faccessat \
fs/stat.c:ksu_handle_stat \
fs/stat.c:ksu_handle_vfs_fstat \
kernel/reboot.c:ksu_handle_sys_reboot \
kernel/sys.c:ksu_handle_setresuid \
fs/read_write.c:ksu_handle_sys_read \
drivers/input/input.c:ksu_handle_input_handle_event"
else
    say "  ── MANUAL_HOOK 模式将检查这 6 处 ──"
    HOOK_CHECK="fs/exec.c:ksu_handle_execveat \
fs/open.c:ksu_handle_faccessat \
fs/stat.c:ksu_handle_stat \
fs/stat.c:ksu_handle_newfstat_ret \
fs/stat.c:ksu_handle_fstat64_ret \
kernel/reboot.c:ksu_handle_sys_reboot"
fi
MISSING=0
for c in $HOOK_CHECK; do
    cf="${c%%:*}"; ch="${c#*:}"
    if [ ! -f "$KS/$cf" ]; then
        bad "$ch  (缺文件 $cf)"; MISSING=$((MISSING+1))
    elif do_hook "$cf" "$ch"; then
        ok "$ch"
    else
        bad "$ch  ($cf)"; MISSING=$((MISSING+1))
    fi
done
if [ -z "$SUSFS_ON" ]; then
    say ""
    say "  ── 以下 3 处由 Kbuild LSM / input_handler 托管，无需源码注入 ──"
    ok "ksu_handle_setresuid(LSM)              ← 不注入"
    ok "ksu_handle_sys_read(LSM)               ← 不注入"
    ok "ksu_handle_input_handle_event(input)   ← 不注入"
fi

if [ "$MISSING" -gt 0 ]; then
    bad "有 $MISSING 个 hook 检查点缺失，Kbuild/内核会 $(error) 或行为异常"
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
if [ -n "$SUSFS_ON" ]; then
    CHK_LIST="KSU KSU_SUSFS KALLSYMS_ALL"
else
    CHK_LIST="KSU KSU_MANUAL_HOOK KALLSYMS_ALL"
fi
for k in $CHK_LIST; do
    if grep -qE "^CONFIG_$k=y$" "$KCFG" 2>/dev/null; then
        ok "CONFIG_$k=y"
    else
        bad "CONFIG_$k 未生效（= $(grep -E "CONFIG_$k" "$KCFG" 2>/dev/null | head -1 || echo 未设置)）"
        CHK_FAIL=$((CHK_FAIL+1))
    fi
done

# ---- SUSFS 模式：子项 + 依赖 + 必须没有 MANUAL_HOOK ----
if [ -n "$SUSFS_ON" ]; then
    if ! grep -qE '^CONFIG_THREAD_INFO_IN_TASK=y$' "$KCFG" 2>/dev/null; then
        bad "CONFIG_THREAD_INFO_IN_TASK 未开启 → CONFIG_KSU_SUSFS 的 Kconfig 依赖不满足"
        say "    华为 4.9.148 的 arch/arm64/Kconfig 已 select 该项；若这里缺失，"
        say "    说明 defconfig/树被改过，SUSFS 会被 olddefconfig 丢弃。"
        CHK_FAIL=$((CHK_FAIL+1))
    fi
    if grep -qE '^CONFIG_KSU_MANUAL_HOOK=y$' "$KCFG" 2>/dev/null; then
        bad "CONFIG_KSU_MANUAL_HOOK 仍为 y → 会走 LSM 分支，susfs_init() 不会被调用"
        CHK_FAIL=$((CHK_FAIL+1))
    fi
    for k in SUS_PATH SUS_MOUNT SUS_KSTAT SPOOF_UNAME ENABLE_LOG \
             HIDE_KSU_SUSFS_SYMBOLS SPOOF_CMDLINE_OR_BOOTCONFIG \
             OPEN_REDIRECT SUS_MAP; do
        if grep -qE "^CONFIG_KSU_SUSFS_$k=y$" "$KCFG" 2>/dev/null; then
            ok "CONFIG_KSU_SUSFS_$k=y"
        else
            info "CONFIG_KSU_SUSFS_$k 未生效（该子功能关闭，不影响编译）"
        fi
    done
fi
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

# ★★ 打包只用【源码自带的官方打包脚本】，不写死任何机型的 offset。
#
#   每个机型的 kernel_offset / ramdisk_offset / tags_offset / cmdline /
#   os_version 都不同，写死在构建脚本里必然只适用一个机型。
#   而华为官方内核源码包自带 tools/pack_kernerimage_cmd.sh，
#   里面就是【该机型的官方值】——直接用它，参数 100% 与官方一致。
#
#   ★ 官方脚本的已知特点（已实测）：
#     - 内部调用 ./mkbootimg --kernel kernel ...，内核名写死为 kernel
#     - 不接任何位置参数
#     - 输出 kernel.img 到当前目录
#   所以执行前必须把 Image.gz 复制成 tools/kernel，执行后把产物搬走。
#
#   找不到官方脚本 → 直接报错退出。
#   ★ 不用"通用默认参数"兜底：offset 猜错会导致 bootloader 读不到
#     内核大小与启动参数，开机必然失败，而文件看起来是正常的。
PACK_SH=$(ls "$TOOLS"/pack_kernerimage_cmd*.sh "$TOOLS"/pack_kernel*cmd*.sh 2>/dev/null | head -1)
PACKED=""

if [ -z "$PACK_SH" ] || [ ! -f "$PACK_SH" ]; then
    bad "源码中找不到官方打包脚本（tools/pack_kernerimage_cmd.sh）"
    say ""
    say "  本脚本只使用内核源码自带的官方打包脚本（各机型参数在脚本里）。"
    say "  找不到说明这个内核源码包不含打包脚本，或解包路径异常。"
    say ""
    say "  当前 tools/ 下与打包相关的文件："
    ls -la "$TOOLS" 2>/dev/null | grep -iE "pack|mkbootimg|img" | sed 's/^/      /' \
        || echo "      (无)"
    say ""
    say "  处理办法："
    say "    1) 确认内核源码包完整（官方 HuaweiUpdateExtractor 提取的整包）"
    say "    2) 或手动用 mkbootimg 打包，参数务必取自你手机原厂 boot.img"
    say "       可用 bootimg_hdr.py 读出原厂头部字段"
    exit 1
fi

if [ ! -f "$IMG_GZ" ]; then
    bad "找不到编译产物 Image.gz，无法打包"
    exit 1
fi

info "用源码自带官方打包脚本: $(basename "$PACK_SH")"
chmod +x "$TOOLS/mkbootimg" "$PACK_SH" 2>/dev/null
# 官方脚本写死 --kernel kernel，先在 tools/ 里准备这个名字
cp -f "$IMG_GZ" "$TOOLS/kernel"
( cd "$TOOLS" && bash "$(basename "$PACK_SH")" ) > "$LOGS/pack.log" 2>&1
PACK_RC=$?
rm -f "$TOOLS/kernel"

# 官方脚本输出 kernel.img（个别机型输出名不同，取最近生成的 img）
OUTIMG=$(ls -t "$TOOLS"/*.img 2>/dev/null | head -1)
if [ $PACK_RC -eq 0 ] && [ -n "$OUTIMG" ] && [ -s "$OUTIMG" ]; then
    cp -f "$OUTIMG" "$IMG"
    rm -f "$OUTIMG"
    PACKED=1
    ok "官方脚本打包完成"
else
    bad "官方打包脚本执行失败（退出码 $PACK_RC）"
    say ""
    say "  打包日志："
    tail -12 "$LOGS/pack.log" 2>/dev/null | sed 's/^/      /'
    say ""
    say "  可用内核(gzip): $IMG_GZ"
    exit 1
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
