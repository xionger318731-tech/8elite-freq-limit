#!/system/bin/sh
# =====================================================================
# probe.sh — 8elite 限频 上机校准工具（V1.4fix2）
#
# 用途：
#   1. 逐档写 cooling_device 的 cur_state，读回真实 scaling_max_freq，
#      自动生成 config/map_big.conf 与 config/map_prime.conf
#   2. 检查 time_in_state 是否可用（DCS 主数据源）
#   3. 检查功耗节点、判断 current_now 单位（mA 还是 µA）
#   4. 检查温区单位与官方 trip point
#   5. 检查是否存在会与自己抢写的其它模块
#
# 用法：
#   sh probe.sh              # 生成报告 + 自动写入 map 文件
#   sh probe.sh --dry-run    # 只生成报告，不写文件
#   sh probe.sh --yes        # 不询问，直接覆盖
#   sh probe.sh > /sdcard/probe.txt
#
# 注意：扫描过程中会临时压低 CPU 上限，约 5-15 秒，结束后自动归 0。
#       全程在 root shell 下执行，勿在跑分时运行。
# =====================================================================

CPUFREQ=/sys/devices/system/cpu/cpufreq
THERMAL=/sys/class/thermal
MSM=/sys/kernel/msm_performance/parameters/cpu_max_freq
BAT=/sys/class/power_supply/battery
D=/data/adb/eta_sched

_rv=""
get(){ _rv=""; read -r _rv < "$1" 2>/dev/null; }
say(){ echo "$*"; }

# 写 cooling state 并等待 scaling_max_freq 稳定。
# 【为什么需要】cooling->cpufreq 的联动不是同步的：实测写完后常驻 0.15s 读到
# 的还是上一档（偶尔要 1s+）。直接记录会采到相邻档的值（实测 state0 采成 3532800）。
# 做法：最多轮询 15 次×200ms，连续 3 次读到相同值才采纳。
set_state(){
    local d="$1" s="$2" pol="$3" i=0 prev="" cur="" same=0
    echo "$s" > "$d/cur_state" 2>/dev/null
    i=0
    while [ "$i" -lt 15 ]; do
        usleep 200000
        cur=$(cat "$pol/scaling_max_freq" 2>/dev/null)
        if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then
            same=$((same+1))
            [ "$same" -ge 2 ] && { _st=$cur; return 0; }
        else
            same=0
        fi
        prev=$cur
        i=$((i+1))
    done
    _st=$cur
    return 0
}

DRY=0; ASSUME_YES=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        -y|--yes)  ASSUME_YES=1 ;;
        -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
    esac
done

say "=============================================================="
say " 8elite DVFS 环境探针 / map 自动生成"
say " $(date '+%F %T')"
say "=============================================================="
say ""

# ---------- 1. 拓扑 ----------
say "--- 1. CPU 拓扑 ---"
POL_B=""; POL_P=""; CPUS_B=""; CPUS_P=""
for d in $CPUFREQ/policy*/; do
    [ -d "$d" ] || continue
    get "${d}related_cpus"; rc="$_rv"
    av=""; get "${d}scaling_available_frequencies"; av="$_rv"
    mx=""; get "${d}cpuinfo_max_freq"; mx="$_rv"
    say "  ${d%/}  cpus=[$rc]  hwmax=$mx"
    say "      avail: $av"
    case "$rc" in *6*|*7*) POL_P="${d%/}"; CPUS_P="$rc" ;; esac
    [ -z "$POL_B" ] && { POL_B="${d%/}"; CPUS_B="$rc"; }
done
[ -n "$POL_B" ] || POL_B="$CPUFREQ/policy0"
[ -n "$POL_P" ] || POL_P="$CPUFREQ/policy6"
say ""

# ---------- 2. msm_performance ----------
say "--- 2. 官方天花板 (msm_performance) ---"
if [ -r "$MSM" ]; then
    say "  cpu_max_freq = $(cat $MSM 2>/dev/null)"
else
    say "  [不可读] $MSM"
fi
say ""

# ---------- 3. time_in_state ----------
say "--- 3. cpufreq stats (time_in_state) ---"
for d in $CPUFREQ/policy*/; do
    f="${d}stats/time_in_state"
    if [ -r "$f" ]; then
        say "  [可用] $f"
        # 校验：加权和是否会超过 32 位（daemon 里已改 awk，这里只提示数据规模）
        chk=$(awk '{s+=$2; w+=$1*$2} END{printf "%d %.3e\n", s, w}' "$f" 2>/dev/null)
        say "      Σticks / Σ(f×j) = $chk"
        say "      （Σf×j 超过 2.1e9 时，32 位 shell 会溢出 → daemon 必须用 awk）"
    else
        say "  [缺失] $f  -> DCS 降级为轮询 scaling_cur_freq"
    fi
done
say ""

# ---------- 4. 功耗节点 + 单位判定 ----------
say "--- 4. 功耗节点 ---"
CN=""; VN=""
for n in current_now voltage_now status capacity; do
    if [ -r "$BAT/$n" ]; then
        say "  [可用] $n = $(cat $BAT/$n 2>/dev/null)"
        [ "$n" = current_now ] && CN=$(cat "$BAT/$n" 2>/dev/null)
        [ "$n" = voltage_now ] && VN=$(cat "$BAT/$n" 2>/dev/null)
    else say "  [缺失] $n"; fi
done
case "$VN" in ''|*[!0-9]*) VN=0 ;; esac
case "$CN" in ''|*[!0-9-]*) CN=0 ;; esac
[ "$CN" -lt 0 ] && CN=$(( -CN ))
if [ "$VN" -gt 1000000 ]; then VU="µV"; else VU="mV"; fi
if [ "$CN" -gt 20000 ]; then CU="µA"; else CU="mA"; fi
say ""
say "  单位判定: current=$CU  voltage=$VU   (daemon 按同一规则自适应)"
if [ "$VN" -gt 0 ] && [ "$CN" -gt 0 ]; then
    awk -v i="$CN" -v u="$VN" 'BEGIN{
        vv=(u>1000000)?u/1000:u; ii=(i>20000)?i/1000:i
        printf "  当前功耗: %.0f mW\n", ii*vv/1000 }'
fi
say ""

# ---------- 5. 温区 + trip point ----------
say "--- 5. 温区与官方 trip point ---"
say "  （daemon 的 T_SOFT/T_HARD/T_PANIC 应对齐官方 trip，不能凭感觉定）"
for d in $THERMAL/thermal_zone*/; do
    [ -d "$d" ] || continue
    t=$(cat "${d}type" 2>/dev/null)
    v=$(cat "${d}temp" 2>/dev/null)
    case "$t" in *cpu*|*soc*|*tsens*|*cluster*)
        line="  ${d%/}  type=$t  temp=$v"
        # 抓 trip point
        trips=""
        for tp in "${d}"trip_point_*_temp; do
            [ -f "$tp" ] || continue
            tv=$(cat "$tp" 2>/dev/null)
            [ -n "$tv" ] && trips="$trips $tv"
        done
        [ -n "$trips" ] && line="$line  trips:$trips"
        say "$line"
        ;;
    esac
done
say ""

# ---------- 6. 抢写检测 ----------
say "--- 6. 共存模块 / 抢写风险 ---"
for m in eta_tune x8u_eco eta_sched; do
    [ -d "/data/adb/modules/$m" ] && say "  [存在] /data/adb/modules/$m"
done
say "  可能抢写的进程（非本探针）:"
for pid in /proc/[0-9]*; do
    p=${pid#/proc/}
    case "$p" in ''|*[!0-9]*) continue ;; esac
    cmd=$(tr '\0' ' ' < "$pid/cmdline" 2>/dev/null)
    case "$cmd" in
        *probe.sh*) continue ;;
        *eta_tune*|*x8u_eco*|*oiface*|*thermal-engine*|*mi_thermal*)
            say "    pid=$p  $cmd" ;;
    esac
done
say ""

# ---------- 7. cooling 真表 + 自动生成 map ----------
say "--- 7. cooling_device -> 频率映射（自动生成 map）---"

GEN_B=""; GEN_P=""
TMP_B=/data/local/tmp/.probe_map_big.$$
TMP_P=/data/local/tmp/.probe_map_prime.$$
: > "$TMP_B"; : > "$TMP_P"

# 单次扫描：先判定归属（用中档试探），再逐档采集
# 逐档采集并写表
say ""
say "  --- 归属判定 ---"
for d in $THERMAL/cooling_device*/; do
    [ -d "$d" ] || continue
    t=$(cat "${d}type" 2>/dev/null)
    case "$t" in cpufreq-cpu*) ;; *) continue ;; esac
    get "${d}max_state"
    case "$_rv" in ''|*[!0-9]*) mx=0 ;; *) mx=$_rv ;; esac
    [ "$mx" -gt 20 ] && mx=20

    # baseline
    echo 0 > "${d}cur_state" 2>/dev/null
    usleep 200000
    b0=$(cat "$POL_B/scaling_max_freq" 2>/dev/null)
    p0=$(cat "$POL_P/scaling_max_freq" 2>/dev/null)

    # 用中档 state 试
    mid=$(( mx / 2 ))
    echo "$mid" > "${d}cur_state" 2>/dev/null
    usleep 250000
    b1=$(cat "$POL_B/scaling_max_freq" 2>/dev/null)
    p1=$(cat "$POL_P/scaling_max_freq" 2>/dev/null)
    echo 0 > "${d}cur_state" 2>/dev/null
    usleep 150000

    chg_b=0; chg_p=0
    [ "$b0" != "$b1" ] && chg_b=1
    [ "$p0" != "$p1" ] && chg_p=1

    if [ "$chg_b" = 1 ] && [ "$chg_p" = 0 ]; then
        say "  ${d%/} ($t) -> 大核 (policy0)"
        echo "# cooling_device: ${d%/}  type=$t  max_state=$mx" > "$TMP_B"
        echo "# 由 probe.sh 自动生成于 $(date '+%F %T')" >> "$TMP_B"
        i=0
        while [ "$i" -le "$mx" ]; do
            set_state "${d%/}" "$i" "$POL_B"
            [ -n "$_st" ] && echo "$i $_st" >> "$TMP_B"
            i=$((i+1))
        done
        echo 0 > "${d}cur_state" 2>/dev/null
        GEN_B="$TMP_B"
    elif [ "$chg_p" = 1 ] && [ "$chg_b" = 0 ]; then
        say "  ${d%/} ($t) -> 超大核 (policy6)"
        echo "# cooling_device: ${d%/}  type=$t  max_state=$mx" > "$TMP_P"
        echo "# 由 probe.sh 自动生成于 $(date '+%F %T')" >> "$TMP_P"
        i=0
        while [ "$i" -le "$mx" ]; do
            set_state "${d%/}" "$i" "$POL_P"
            [ -n "$_st" ] && echo "$i $_st" >> "$TMP_P"
            i=$((i+1))
        done
        echo 0 > "${d}cur_state" 2>/dev/null
        GEN_P="$TMP_P"
    else
        say "  ${d%/} ($t) -> 未识别（chg_b=$chg_b chg_p=$chg_p），跳过"
    fi
done

say ""
say "=============================================================="
say " 校准完成，所有 cooling_device 已归 0"
say ""

# ---------- 8. 写入 map ----------
if [ -z "$GEN_B" ] && [ -z "$GEN_P" ]; then
    say " !! 没能识别出任何 cpufreq cooling 设备，map 未生成"
    rm -f "$TMP_B" "$TMP_P"
    exit 1
fi

say "--- 8. 生成结果 ---"
[ -n "$GEN_B" ] && { say "  大核 map ($(grep -vc '^#' "$GEN_B") 档):"; sed 's/^/    /' "$GEN_B"; }
[ -n "$GEN_P" ] && { say "  超大核 map ($(grep -vc '^#' "$GEN_P") 档):"; sed 's/^/    /' "$GEN_P"; }
say ""

if [ "$DRY" = 1 ]; then
    say " (--dry-run：不写文件)"
    say " 临时文件保留在 $TMP_B / $TMP_P"
    exit 0
fi

# 备份 + 写入
if [ "$ASSUME_YES" != 1 ]; then
    say ""
    say " 即将覆盖:"
    [ -n "$GEN_B" ] && say "   $D/config/map_big.conf"
    [ -n "$GEN_P" ] && say "   $D/config/map_prime.conf"
    printf " 继续? [y/N] "
    read -r ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) say " 已取消，临时文件保留在 $TMP_B / $TMP_P"; exit 0 ;;
    esac
fi

mkdir -p "$D/config" 2>/dev/null
TS=$(date '+%Y%m%d-%H%M%S')
if [ -n "$GEN_B" ]; then
    [ -f "$D/config/map_big.conf" ] && cp -f "$D/config/map_big.conf" "$D/config/map_big.conf.bak.$TS" 2>/dev/null
    cp -f "$GEN_B" "$D/config/map_big.conf" && say " ✓ 已写入 $D/config/map_big.conf (备份 .bak.$TS)"
fi
if [ -n "$GEN_P" ]; then
    [ -f "$D/config/map_prime.conf" ] && cp -f "$D/config/map_prime.conf" "$D/config/map_prime.conf.bak.$TS" 2>/dev/null
    cp -f "$GEN_P" "$D/config/map_prime.conf" && say " ✓ 已写入 $D/config/map_prime.conf (备份 .bak.$TS)"
fi
rm -f "$TMP_B" "$TMP_P"

say ""
say " 下一步：重启守护使新表生效"
say "   sh $D/ctl.sh restart"
say "=============================================================="
