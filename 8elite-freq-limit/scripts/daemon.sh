#!/system/bin/sh
# ============================================================
# 8elite限频 —— 核心守护 v1.0
#
# 【设计依据：全部来自本机实测】
#   time_in_state：16 档，单位 10ms，只统计 policy 首核（CPU0）
#   微信前台不干预时有效频率：0.78 ~ 1.03 GHz
#   冷启动拐点：2.4G=455ms(无损) 2.0G=536ms 1.78G=584ms 1.15G=678ms
#   静止锁 748M：电流 150mA（官方 395mA）
#
# 【核心算法】
#   天花板 = 实际需求 × 余量，每 500ms 跟随一次
#     idle   需求 < 阈值持续 2s      → 锁 748800
#     boost  需求 ≥ 天花板 92%       → 阶梯升 2 档
#     rich   需求 < 天花板 72% 持续 1s → 降到 需求×余量
#     hold   中间地带                → 保持
#     launch 前台切换 15s 内         → 锁 2.4G（无损点）
#     game   游戏前台                → 不干预
#
# 【性能优化】
#   1. 前台检测 1s 一次（原 250ms）→ 省 75% dumpsys
#   2. 频率表缓存到变量，循环内零 cat
#   3. 状态文件 1s 写一次
#   4. 只在状态变化时写 cooling 节点
#   5. 目标：< 0.15% 系统 CPU
# ============================================================

D=/data/adb/eta_sched
OBS=/storage/emulated/0/Android/8elite/obs
CFG=/storage/emulated/0/Android/8elite/config.conf

CPUFREQ=/sys/devices/system/cpu/cpufreq
THERMAL=/sys/class/thermal
MSM=/sys/kernel/msm_performance/parameters/cpu_max_freq

# ---------- 调参 ----------
TICK_MS=1000             # 主循环（1s，采样精度足够）
FG_TICK=1                # 每轮查前台（1s）
STATE_TICK=1             # 每轮写状态（1s）
CFG_TICK=5                # 每 5 轮重载配置（5s）

MARGIN_PCT=112
RICH_RATIO=72
NEAR_RATIO=92
IDLE_FREQ=1100000
IDLE_CONFIRM=2           # 连续 2 次（2s）
BOOST_STEP=2

FLOOR_BIG=748800
FLOOR_PRIME=1017600
PRIME_TRIGGER=2200000
LAUNCH_CAP_B=2400000
LAUNCH_CAP_P=2200000
APP_SKIP_MS=15000
T_HARD=72000
BOOT_SKIP=60

# ---------- 状态 ----------
RUN=1
MODE=auto
STYLE=eco
ENABLED=1

CUR_STB=0; CUR_STP=0
CAP_B=0; CAP_P=0
RICH=0; IDLE=0
FG=""; FG_TS=0
BOOT_TS=0
TICK=0

SCENE=""; EFF_B=0; EFF_P=0; RATIO=0; TB=0
OFF_B=3532800; OFF_P=4320000
FREQ_B=""; FREQ_P=""

log(){ echo "$(date '+%m-%d %H:%M:%S') $*" >> "$OBS/daemon.log"; }

# ============================================================
find_paths(){
    local d rc c t
    POL_B=""; POL_P=""
    for d in $CPUFREQ/policy*/; do
        [ -d "$d" ] || continue
        rc=""
        read -r rc < "$d/related_cpus" 2>/dev/null
        case "$rc" in
            *6*|*7*) POL_P="${d%/}" ;;
        esac
        [ -z "$POL_B" ] && POL_B="${d%/}"
    done
    CD_B=""; CD_P=""
    for d in $THERMAL/cooling_device*/; do
        t=""
        read -r t < "$d/type" 2>/dev/null
        case "$t" in
            cpufreq-cpu0) CD_B="${d%/}" ;;
            cpufreq-cpu4|cpufreq-cpu6|cpufreq-cpu7) CD_P="${d%/}" ;;
        esac
    done
    [ -z "$CD_B" ] && CD_B="$THERMAL/cooling_device3"
    [ -z "$CD_P" ] && CD_P="$THERMAL/cooling_device4"
    # 缓存频率表
    FREQ_B=$(cat "$POL_B/scaling_available_frequencies" 2>/dev/null)
    FREQ_P=$(cat "$POL_P/scaling_available_frequencies" 2>/dev/null)
}

load_cfg(){
    [ -f "$CFG" ] || return 0
    local k v om="" oi="" orr="" on="" op=""
    while IFS='=' read -r k v; do
        case "$k" in ''|'#'*) continue ;; esac
        v=$(printf '%s' "$v" | tr -d ' \t\r')
        case "$k" in
            mode) MODE=$v ;;
            style) STYLE=$v ;;
            enabled) ENABLED=$v ;;
            margin) MARGIN_PCT=$v; om=1 ;;
            idle_freq) IDLE_FREQ=$v; oi=1 ;;
            rich_ratio) RICH_RATIO=$v; orr=1 ;;
            near_ratio) NEAR_RATIO=$v; on=1 ;;
            prime_trigger) PRIME_TRIGGER=$v; op=1 ;;
        esac
    done < "$CFG"

    case "$STYLE" in
        eco)
            [ -z "$om" ] && MARGIN_PCT=105
            [ -z "$oi" ] && IDLE_FREQ=1300000
            [ -z "$orr" ] && RICH_RATIO=80
            [ -z "$on" ] && NEAR_RATIO=95
            [ -z "$op" ] && PRIME_TRIGGER=2800000
            ;;
        perf)
            [ -z "$om" ] && MARGIN_PCT=135
            [ -z "$oi" ] && IDLE_FREQ=800000
            [ -z "$orr" ] && RICH_RATIO=55
            [ -z "$on" ] && NEAR_RATIO=85
            [ -z "$op" ] && PRIME_TRIGGER=1500000
            ;;
        *)
            [ -z "$om" ] && MARGIN_PCT=112
            [ -z "$oi" ] && IDLE_FREQ=1100000
            [ -z "$orr" ] && RICH_RATIO=72
            [ -z "$on" ] && NEAR_RATIO=92
            [ -z "$op" ] && PRIME_TRIGGER=2200000
            ;;
    esac
}

read_off(){
    local v="" pair k
    OFF_B=0; OFF_P=0
    [ -r "$MSM" ] && read -r v < "$MSM" 2>/dev/null
    for pair in $v; do
        k="${pair%%:*}"
        case "$k" in
            0) OFF_B="${pair#*:}" ;;
            6) OFF_P="${pair#*:}" ;;
        esac
    done
    case "$OFF_B" in ''|*[!0-9]*) OFF_B=3532800 ;; esac
    case "$OFF_P" in ''|*[!0-9]*) OFF_P=4320000 ;; esac
    [ "$OFF_B" -le 0 ] && OFF_B=3532800
    [ "$OFF_P" -le 0 ] && OFF_P=4320000
}

get_fg(){
    local line fg
    line=$(timeout 3 dumpsys window 2>/dev/null | grep -m1 mCurrentFocus)
    fg=$(printf '%s' "$line" | sed -n 's/.* \([a-zA-Z0-9_][a-zA-Z0-9_.]*\)\/[^ ]*.*/\1/p')
    case "$fg" in
        NotificationShade|StatusBar|InputMethod) fg="" ;;
        *InputMethod*) fg="" ;;
        com.android.systemui) fg="" ;;
    esac
    if [ -z "$fg" ]; then
        line=$(timeout 3 dumpsys activity activities 2>/dev/null | grep -m1 ResumedActivity)
        fg=$(printf '%s' "$line" | sed -n 's/.* \([a-zA-Z0-9_][a-zA-Z0-9_.]*\)\/[^ ]*.*/\1/p')
    fi
    printf '%s' "$fg"
}

screen_on(){
    local s=""
    read -r s < /sys/class/backlight/panel0-backlight/brightness 2>/dev/null
    [ -z "$s" ] && read -r s < /sys/class/leds/lcd-backlight/brightness 2>/dev/null
    [ -n "$s" ] && [ "$s" -gt 0 ] 2>/dev/null && { printf '1'; return; }
    printf '0'
}

is_game(){
    [ -f "$D/config/games.list" ] || return 1
    local p
    while IFS= read -r p; do
        case "$p" in ''|'#'*) continue ;; esac
        [ "$p" = "$1" ] && return 0
    done < "$D/config/games.list"
    return 1
}

eff_freq(){
    [ -f "$1" ] && [ -f "$2" ] || { printf '0'; return; }
    awk '
    NR==FNR { a[FNR]=$2; n=FNR; next }
    {
        # 行数不匹配或缺失基线 → 跳过该行
        if (FNR > n || !(FNR in a)) next
        d = $2 - a[FNR]
        if (d < 0) d = 0
        s += d
        w += $1 * d
    }
    END { if (s > 0) printf "%d", w/s; else print 0 }
    ' "$1" "$2" 2>/dev/null
}



snap_freq(){
    local which="$1" t="$2" best=0 f list
    if [ "$which" = "B" ]; then list="$FREQ_B"; else list="$FREQ_P"; fi
    for f in $list; do
        case "$f" in ''|*[!0-9]*) continue ;; esac
        [ "$f" -le "$t" ] || continue
        [ "$f" -gt "$best" ] && best=$f
    done
    [ "$best" -eq 0 ] && best=$FLOOR_BIG
    printf '%s' "$best"
}

step_up(){
    local which="$1" cur="$2" n="$3" f list idx=0 tot=0 cnt=0
    if [ "$which" = "B" ]; then list="$FREQ_B"; else list="$FREQ_P"; fi
    for f in $list; do
        tot=$((tot+1))
        case "$f" in ''|*[!0-9]*) continue ;; esac
        [ "$f" -le "$cur" ] && idx=$tot
    done
    local tgt=$((idx+n))
    [ "$tgt" -gt "$tot" ] && tgt=$tot
    [ "$tgt" -lt 1 ] && tgt=1
    for f in $list; do
        cnt=$((cnt+1))
        [ "$cnt" -eq "$tgt" ] && { printf '%s' "$f"; return; }
    done
    printf '%s' "$cur"
}

state_for(){
    local map="$1" t="$2" st f best=0 bf=-1
    [ -f "$map" ] || { printf '0'; return; }
    while read -r st f; do
        case "$f" in ''|*[!0-9]*) continue ;; esac
        [ "$f" -le "$t" ] || continue
        [ "$f" -gt "$bf" ] && { best=$st; bf=$f; }
    done < "$map"
    printf '%s' "$best"
}

apply(){
    local b="$1" p="$2" sb sp
    if [ "$b" -le 0 ] || [ "$b" -ge "$OFF_B" ]; then
        sb=0
    else
        sb=$(state_for "$D/config/map_big.conf" "$b")
    fi
    if [ "$p" -le 0 ] || [ "$p" -ge "$OFF_P" ]; then
        sp=0
    else
        sp=$(state_for "$D/config/map_prime.conf" "$p")
    fi
    [ "$sb" != "$CUR_STB" ] && { echo "$sb" > "$CD_B/cur_state" 2>/dev/null; CUR_STB=$sb; }
    [ "$sp" != "$CUR_STP" ] && { echo "$sp" > "$CD_P/cur_state" 2>/dev/null; CUR_STP=$sp; }
}

release(){
    [ "$CUR_STB" != "0" ] && { echo 0 > "$CD_B/cur_state" 2>/dev/null; CUR_STB=0; }
    [ "$CUR_STP" != "0" ] && { echo 0 > "$CD_P/cur_state" 2>/dev/null; CUR_STP=0; }
}

write_state(){
    {
        echo "alive=1"
        echo "pid=$$"
        echo "mode=$MODE"
        echo "style=$STYLE"
        echo "scene=$SCENE"
        echo "fg=$FG"
        echo "cap_big=$CAP_B"
        echo "cap_prime=$CAP_P"
        echo "eff_big=$EFF_B"
        echo "eff_prime=$EFF_P"
        echo "ratio_big=$RATIO"
        echo "off_big=$OFF_B"
        echo "off_prime=$OFF_P"
        echo "st_big=$CUR_STB"
        echo "st_prime=$CUR_STP"
        echo "temp_big=$TB"
        echo "ts=$(date +%s)"
    } > "$OBS/state.tmp" 2>/dev/null && mv "$OBS/state.tmp" "$OBS/state" 2>/dev/null
}

# 跳过本轮：刷新快照 + 可选写状态
skip_round(){
    SCENE="$1"
    cat "$POL_B/stats/time_in_state" > /tmp/ti_b.1 2>/dev/null
    cat "$POL_P/stats/time_in_state" > /tmp/ti_p.1 2>/dev/null
    [ $((TICK % STATE_TICK)) -eq 0 ] && write_state
}

cleanup(){
    [ "$RUN" = "0" ] && return
    RUN=0
    echo 0 > "$CD_B/cur_state" 2>/dev/null
    echo 0 > "$CD_P/cur_state" 2>/dev/null
    rm -f "$OBS/daemon.lock"
    log "退出，已归还"
    exit 0
}

# ============================================================
mkdir -p "$OBS" 2>/dev/null
find_paths
load_cfg

LOCK="$OBS/daemon.lock"
if [ -f "$LOCK" ]; then
    old=""
    read -r old < "$LOCK" 2>/dev/null
    if [ -n "$old" ] && [ -d "/proc/$old" ]; then exit 1; fi
fi
echo $$ > "$LOCK"
echo $$ > "$OBS/daemon.pid"

BOOT_TS=$(date +%s)
trap cleanup TERM INT EXIT
log "启动 v1.0 pid=$$ style=$STYLE"

cat "$POL_B/stats/time_in_state" > /tmp/ti_b.1 2>/dev/null
cat "$POL_P/stats/time_in_state" > /tmp/ti_p.1 2>/dev/null

while [ "$RUN" = "1" ]; do
    usleep $((TICK_MS * 1000))
    TICK=$((TICK+1))

    [ $((TICK % CFG_TICK)) -eq 0 ] && load_cfg

    # 熄屏
    if [ "$(screen_on)" = "0" ]; then
        release; CAP_B=0; CAP_P=0; RICH=0; IDLE=0
        skip_round "off"
        continue
    fi

    # 关闭
    if [ "$ENABLED" != "1" ] || [ "$MODE" != "auto" ]; then
        release; CAP_B=0; CAP_P=0
        skip_round "disabled"
        continue
    fi

    read_off

    # 开机保护
    NOW_S=$(date +%s)
    if [ $((NOW_S - BOOT_TS)) -lt "$BOOT_SKIP" ]; then
        release; CAP_B=0; CAP_P=0
        skip_round "boot"
        continue
    fi

    # 温度硬墙
    TB=$(cat "$THERMAL/thermal_zone1/temp" 2>/dev/null)
    case "$TB" in ''|*[!0-9]*) TB=0 ;; esac
    if [ "$TB" -ge "$T_HARD" ]; then
        release; CAP_B=0; CAP_P=0; RICH=0; IDLE=0
        skip_round "hot"
        continue
    fi

    # 前台（1s 一次）
    if [ $((TICK % FG_TICK)) -eq 0 ]; then
        NF=$(get_fg)
        if [ "$NF" != "$FG" ]; then
            FG="$NF"
            FG_TS=$(date +%s%3N)
        fi
    fi

    # 游戏
    if [ -n "$FG" ] && is_game "$FG"; then
        release; CAP_B=0; CAP_P=0
        skip_round "game"
        continue
    fi

    # 冷启动保护：锁 2.4G
    NOWMS=$(date +%s%3N)
    if [ $((NOWMS - FG_TS)) -lt "$APP_SKIP_MS" ]; then
        CAP_B=$LAUNCH_CAP_B; CAP_P=$LAUNCH_CAP_P
        apply "$CAP_B" "$CAP_P"
        skip_round "launch"
        continue
    fi

    # 采样
    cat "$POL_B/stats/time_in_state" > /tmp/ti_b.2 2>/dev/null
    cat "$POL_P/stats/time_in_state" > /tmp/ti_p.2 2>/dev/null
    EFF_B=$(eff_freq /tmp/ti_b.1 /tmp/ti_b.2)
    EFF_P=$(eff_freq /tmp/ti_p.1 /tmp/ti_p.2)
    case "$EFF_B" in ''|*[!0-9]*) EFF_B=0 ;; esac
    case "$EFF_P" in ''|*[!0-9]*) EFF_P=0 ;; esac

    CM=$(cat "$POL_B/scaling_max_freq" 2>/dev/null)
    case "$CM" in ''|*[!0-9]*) CM=$OFF_B ;; esac
    RATIO=0
    [ "$CM" -gt 0 ] && RATIO=$(( EFF_B * 100 / CM ))

    # 决策
    if [ "$EFF_B" -lt "$IDLE_FREQ" ]; then
        IDLE=$((IDLE+1))
    else
        IDLE=0
    fi

    if [ "$IDLE" -ge "$IDLE_CONFIRM" ]; then
        SCENE="idle"
        CAP_B=$FLOOR_BIG; CAP_P=$FLOOR_PRIME; RICH=0
    elif [ "$RATIO" -ge "$NEAR_RATIO" ]; then
        SCENE="boost"
        if [ "$CAP_B" -le 0 ]; then
            CAP_B=$(step_up B "$FLOOR_BIG" "$BOOST_STEP")
        else
            CAP_B=$(step_up B "$CAP_B" "$BOOST_STEP")
        fi
        REQ=$(( EFF_B * MARGIN_PCT / 100 ))
        [ "$REQ" -gt "$CAP_B" ] && CAP_B=$(snap_freq B "$REQ")
        [ "$CAP_B" -gt "$OFF_B" ] && CAP_B=$OFF_B
        RICH=0
    elif [ "$RATIO" -lt "$RICH_RATIO" ]; then
        SCENE="rich"
        RICH=$((RICH+1))
        if [ "$RICH" -ge 2 ]; then
            REQ=$(( EFF_B * MARGIN_PCT / 100 ))
            [ "$REQ" -lt "$FLOOR_BIG" ] && REQ=$FLOOR_BIG
            CAP_B=$(snap_freq B "$REQ")
            RICH=2
        fi
    else
        SCENE="hold"
        RICH=0
        if [ "$CAP_B" -le 0 ]; then
            REQ=$(( EFF_B * MARGIN_PCT / 100 ))
            CAP_B=$(snap_freq B "$REQ")
        fi
    fi

    # 超大核
    if [ "$STYLE" = "eco" ]; then
        CAP_P=$FLOOR_PRIME
    elif [ "$EFF_B" -ge "$PRIME_TRIGGER" ]; then
        CAP_P=$OFF_P
    else
        CAP_P=$FLOOR_PRIME
    fi

    [ "$CAP_B" -gt 0 ] && [ "$CAP_B" -lt "$FLOOR_BIG" ] && CAP_B=$FLOOR_BIG
    [ "$CAP_P" -gt 0 ] && [ "$CAP_P" -lt "$FLOOR_PRIME" ] && CAP_P=$FLOOR_PRIME

    apply "$CAP_B" "$CAP_P"
    [ $((TICK % STATE_TICK)) -eq 0 ] && write_state

    mv -f /tmp/ti_b.2 /tmp/ti_b.1 2>/dev/null
    mv -f /tmp/ti_p.2 /tmp/ti_p.1 2>/dev/null
done

cleanup
