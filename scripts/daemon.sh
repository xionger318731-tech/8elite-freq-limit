#!/system/bin/sh
# ============================================================
# 8elite限频 —— 核心守护 V1.1
#
# 判据：CPU 使用率（时间维度，不受限频影响）
#   实测：不同上限下 8 核满载均为 100%，空载 20-50%
#
# 算法：目标频率 = 当前频率 × (使用率 / 目标使用率)²
#   100%/50% → 4.0x（饱和严重不足）
#    70%/50% → 1.96x
#    50%/50% → 1.0x（正好）
#    30%/50% → 0.36x（有余力）
#
# 响应：升档立即执行，降档累积确认
# ============================================================

D=/data/adb/eta_sched
OBS=/storage/emulated/0/Android/8elite/obs
CFG=/storage/emulated/0/Android/8elite/config.conf

CPUFREQ=/sys/devices/system/cpu/cpufreq
THERMAL=/sys/class/thermal
MSM=/sys/kernel/msm_performance/parameters/cpu_max_freq

# ---------- 参数 ----------
TICK_MS=100
FG_TICK=10
STATE_TICK=10
CFG_TICK=50

TARGET_LOAD=50
DEAD_ZONE_PCT=12
DOWN_CONFIRM=8

FLOOR_BIG=748800
FLOOR_PRIME=1017600
LAUNCH_CAP_B=2400000
LAUNCH_CAP_P=2200000
APP_SKIP_MS=15000
T_HARD=78000
BOOT_SKIP=60
PRIME_TRIGGER=1800000

# ---------- 状态 ----------
RUN=1
MODE=auto
STYLE=eco
ENABLED=1

CUR_STB=0; CUR_STP=0
CAP_B=0; CAP_P=0
DOWN_CNT=0
FG=""
LAUNCH_UNTIL=0
BOOT_SEC=0
TICK=0

SCENE=""; LOAD=0; TB=0
OFF_B=3532800; OFF_P=4320000
FREQ_B=""; FREQ_P=""

log(){ echo "$(date '+%m-%d %H:%M:%S') $*" >> "$OBS/daemon.log"; }

# ============================================================
find_paths(){
    local d rc t
    POL_B=""; POL_P=""
    for d in $CPUFREQ/policy*/; do
        [ -d "$d" ] || continue
        rc=""
        read -r rc < "$d/related_cpus" 2>/dev/null
        case "$rc" in *6*|*7*) POL_P="${d%/}" ;; esac
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
    FREQ_B=$(cat "$POL_B/scaling_available_frequencies" 2>/dev/null)
    FREQ_P=$(cat "$POL_P/scaling_available_frequencies" 2>/dev/null)
}

load_cfg(){
    [ -f "$CFG" ] || return 0
    local k v
    while IFS='=' read -r k v; do
        case "$k" in ''|'#'*) continue ;; esac
        v=$(printf '%s' "$v" | tr -d ' \t\r')
        case "$k" in
            mode) MODE=$v ;;
            style) STYLE=$v ;;
            enabled) ENABLED=$v ;;
            target_load) TARGET_LOAD=$v ;;
            prime_trigger) PRIME_TRIGGER=$v ;;
        esac
    done < "$CFG"
    case "$STYLE" in
        eco)     : ;;
        perf)    : ;;
        *)       : ;;
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
        NotificationShade|StatusBar|InputMethod) printf ''; return ;;
        *InputMethod*) printf ''; return ;;
        com.android.systemui) printf ''; return ;;
    esac
    if [ -n "$fg" ]; then printf '%s' "$fg"; return; fi
    line=$(timeout 3 dumpsys activity activities 2>/dev/null | grep -m1 ResumedActivity)
    fg=$(printf '%s' "$line" | sed -n 's/.* \([a-zA-Z0-9_][a-zA-Z0-9_.]*\)\/[^ ]*.*/\1/p')
    printf '%s' "$fg"
}

screen_on(){
    local s=""
    read -r s < /sys/class/backlight/panel0-backlight/brightness 2>/dev/null
    case "$s" in ''|*[!0-9]*) s=0 ;; esac
    [ "$s" -gt 0 ] && { printf '1'; return; }
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
        echo "load=$LOAD"
        echo "cap_big=$CAP_B"
        echo "cap_prime=$CAP_P"
        echo "off_big=$OFF_B"
        echo "off_prime=$OFF_P"
        echo "st_big=$CUR_STB"
        echo "st_prime=$CUR_STP"
        echo "temp_big=$TB"
        echo "down_cnt=$DOWN_CNT"
        echo "ts=$(date +%s)"
    } > "$OBS/state.tmp" 2>/dev/null && mv "$OBS/state.tmp" "$OBS/state" 2>/dev/null
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

BOOT_SEC=$(cut -d. -f1 /proc/uptime 2>/dev/null)
case "$BOOT_SEC" in ''|*[!0-9]*) BOOT_SEC=999999 ;; esac

trap cleanup TERM INT EXIT
log "启动 V1.1 pid=$$ style=$STYLE target=$TARGET_LOAD"

STAT_PREV=$(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9; exit}' /proc/stat)

# ============================================================
while [ "$RUN" = "1" ]; do
    usleep $((TICK_MS * 1000))
    TICK=$((TICK+1))

    [ $((TICK % CFG_TICK)) -eq 0 ] && load_cfg

    # 熄屏
    if [ "$(screen_on)" = "0" ]; then
        release; CAP_B=0; CAP_P=0; DOWN_CNT=0
        SCENE="off"
        [ $((TICK % STATE_TICK)) -eq 0 ] && write_state
        continue
    fi

    # 关闭
    if [ "$ENABLED" != "1" ] || [ "$MODE" != "auto" ]; then
        release; CAP_B=0; CAP_P=0; DOWN_CNT=0
        SCENE="disabled"
        [ $((TICK % STATE_TICK)) -eq 0 ] && write_state
        continue
    fi

    read_off

    # 开机保护
    if [ "$BOOT_SEC" -lt "$BOOT_SKIP" ]; then
        release; CAP_B=0; CAP_P=0; DOWN_CNT=0
        SCENE="boot"
        [ $((TICK % STATE_TICK)) -eq 0 ] && write_state
        continue
    fi

    # 温度
    TB=$(cat "$THERMAL/thermal_zone1/temp" 2>/dev/null)
    case "$TB" in ''|*[!0-9]*) TB=0 ;; esac
    if [ "$TB" -ge "$T_HARD" ]; then
        release; CAP_B=0; CAP_P=0; DOWN_CNT=0
        SCENE="hot"
        [ $((TICK % STATE_TICK)) -eq 0 ] && write_state
        continue
    fi

    # 前台
    if [ $((TICK % FG_TICK)) -eq 0 ]; then
        NF=$(get_fg)
        if [ -n "$NF" ] && [ "$NF" != "$FG" ]; then
            FG="$NF"
            # 从桌面切到应用 → 触发冷启动保护
            if [ "$FG" != "com.android.launcher" ] && [ "$FG" != "com.android.launcher3" ]; then
                LAUNCH_UNTIL=$(( $(date +%s%3N) + APP_SKIP_MS ))
            fi
        fi
    fi

    # 游戏
    if [ -n "$FG" ] && is_game "$FG"; then
        release; CAP_B=0; CAP_P=0; DOWN_CNT=0
        SCENE="game"
        [ $((TICK % STATE_TICK)) -eq 0 ] && write_state
        continue
    fi

    # 冷启动保护
    if [ "$(date +%s%3N)" -lt "$LAUNCH_UNTIL" ]; then
        CAP_B=$LAUNCH_CAP_B; CAP_P=$LAUNCH_CAP_P
        apply "$CAP_B" "$CAP_P"
        DOWN_CNT=0
        SCENE="launch"
        [ $((TICK % STATE_TICK)) -eq 0 ] && write_state
        continue
    fi

    # ---------- CPU 使用率 ----------
    STAT_NOW=$(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9; exit}' /proc/stat)
    LOAD=$(echo "$STAT_PREV $STAT_NOW" | awk '{
        busy=($9-$1)+($10-$2)+($11-$3)+($14-$6)+($15-$7)+($16-$8)
        idle=($12-$4)+($13-$5)
        if(busy+idle>0) printf "%d", busy*100/(busy+idle)
        else print 0
    }')
    case "$LOAD" in ''|*[!0-9]*) LOAD=0 ;; esac
    STAT_PREV="$STAT_NOW"

    CUR_MAX=$(cat "$POL_B/scaling_max_freq" 2>/dev/null)
    case "$CUR_MAX" in ''|*[!0-9]*) CUR_MAX=$OFF_B ;; esac

    # 目标频率 = 当前 × (LOAD/TARGET)²
    if [ "$LOAD" -gt 0 ]; then
        RATIO=$(( LOAD * 100 / TARGET_LOAD ))
        NEW_CAP=$(( CUR_MAX * RATIO / 100 * RATIO / 100 ))
    else
        NEW_CAP=$(( CUR_MAX / 4 ))
    fi

    # 限幅 0.4x ~ 3x
    MAXS=$(( CUR_MAX * 3 ))
    MINS=$(( CUR_MAX * 4 / 10 ))
    [ "$NEW_CAP" -gt "$MAXS" ] && NEW_CAP=$MAXS
    [ "$NEW_CAP" -lt "$MINS" ] && NEW_CAP=$MINS
    [ "$NEW_CAP" -gt "$OFF_B" ] && NEW_CAP=$OFF_B

    NEW_CAP=$(snap_freq B "$NEW_CAP")

    # 死区
    DIFF=$(( NEW_CAP - CUR_MAX ))
    [ "$DIFF" -lt 0 ] && DIFF=$(( -DIFF ))
    DZ=$(( CUR_MAX * DEAD_ZONE_PCT / 100 ))

    if [ "$DIFF" -ge "$DZ" ]; then
        if [ "$NEW_CAP" -gt "$CUR_MAX" ]; then
            # 升档立即
            CAP_B=$NEW_CAP
            DOWN_CNT=0
            SCENE="boost"
        else
            DOWN_CNT=$((DOWN_CNT+1))
            if [ "$DOWN_CNT" -ge "$DOWN_CONFIRM" ]; then
                CAP_B=$NEW_CAP
                DOWN_CNT=0
                SCENE="rich"
            else
                CAP_B=$CUR_MAX
                SCENE="rich_wait"
            fi
        fi
    else
        CAP_B=$CUR_MAX
        SCENE="hold"
        [ "$LOAD" -gt "$TARGET_LOAD" ] && DOWN_CNT=0
    fi

    # 超大核
    if [ "$STYLE" = "eco" ]; then
        CAP_P=$FLOOR_PRIME
    elif [ "$CAP_B" -ge "$PRIME_TRIGGER" ]; then
        CAP_P=$OFF_P
    else
        CAP_P=$FLOOR_PRIME
    fi

    # 地板
    [ "$CAP_B" -gt 0 ] && [ "$CAP_B" -lt "$FLOOR_BIG" ] && CAP_B=$FLOOR_BIG
    [ "$CAP_P" -gt 0 ] && [ "$CAP_P" -lt "$FLOOR_PRIME" ] && CAP_P=$FLOOR_PRIME

    apply "$CAP_B" "$CAP_P"
    [ $((TICK % STATE_TICK)) -eq 0 ] && write_state
done

cleanup
