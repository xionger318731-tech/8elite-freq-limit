#!/system/bin/sh
# ============================================================
# 8elite限频 —— 核心守护 V2.0
#
# 【V1.0 的根本缺陷（已修复）】
#
#   V1.0 用「有效频率 vs 天花板」判断需求。
#   致命问题：压到 748800 后，CPU 满载也只能跑 748800，
#   有效频率 = 748800，占比 = 100%。
#   空载和满载看起来一样，无法区分真实需求。
#
#   实测证据：
#     压到 748800 后，空载/单核满载/8核满载 的撞顶率都是 100%
#     → 频率信号在被限制后完全失效
#
# 【V2.0 的判据：CPU 使用率】
#
#   CPU 使用率是「时间维度」的，不受频率限制影响。
#   实测（不同上限下 8 核满载）：
#     state=0  上限 2227200 → 使用率 100%
#     state=8  上限 1785600 → 使用率 100%
#     state=13 上限 748800  → 使用率 100%
#   恒定！所以能准确反映「有多少活要干」。
#
# 【算法】
#
#   load > HIGH(85%)  → 算力紧张，阶梯升 2 档
#   load < LOW(55%)   → 有余力，降一档
#   中间              → 保持
#
#   响应速度：250ms 采样，500ms 判定
#
# 【额外保护】
#   · 冷启动 15s 锁 2.4G（实测无损点）
#   · 游戏前台不干预
#   · 熄屏交还官方
#   · 温度 >72°C 交还官方
# ============================================================

D=/data/adb/eta_sched
OBS=/storage/emulated/0/Android/8elite/obs
CFG=/storage/emulated/0/Android/8elite/config.conf

CPUFREQ=/sys/devices/system/cpu/cpufreq
THERMAL=/sys/class/thermal
MSM=/sys/kernel/msm_performance/parameters/cpu_max_freq

# ---------- 调参 ----------
TICK_MS=200              # 采样周期（200ms）
FG_TICK=5                # 每 5 轮查前台（1s）
STATE_TICK=5             # 每 5 轮写状态（1s）
CFG_TICK=25              # 每 25 轮重载配置（5s）

HIGH_LOAD=85             # 使用率 > 此值 → 升档
LOW_LOAD=55              # 使用率 < 此值 → 降档
UP_CONFIRM=2             # 升档连续确认
DOWN_CONFIRM=10          # 降档累积确认
BOOST_STEP=2             # 每次升 2 档

FLOOR_BIG=748800
FLOOR_PRIME=1017600
PRIME_TRIGGER=1800000    # 大核到多少让超大核介入
LAUNCH_CAP_B=2400000     # 冷启动锁 2.4G（实测无损点）
LAUNCH_CAP_P=2200000
APP_SKIP_MS=15000         # 冷启动保护 15s
T_HARD=72000
BOOT_SKIP=60

# ---------- 状态 ----------
RUN=1
MODE=auto
STYLE=eco
ENABLED=1

CUR_STB=0; CUR_STP=0
CAP_B=0; CAP_P=0
UP_CNT=0; DOWN_CNT=0
FG=""; FG_TS=0
BOOT_TS=0
TICK=0

SCENE=""; LOAD=0; LOAD_P=0; TB=0
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
    FREQ_B=$(cat "$POL_B/scaling_available_frequencies" 2>/dev/null)
    FREQ_P=$(cat "$POL_P/scaling_available_frequencies" 2>/dev/null)
}

load_cfg(){
    [ -f "$CFG" ] || return 0
    local k v om="" ohi="" olo="" op=""
    while IFS='=' read -r k v; do
        case "$k" in ''|'#'*) continue ;; esac
        v=$(printf '%s' "$v" | tr -d ' \t\r')
        case "$k" in
            mode) MODE=$v ;;
            style) STYLE=$v ;;
            enabled) ENABLED=$v ;;
            high_load) HIGH_LOAD=$v; ohi=1 ;;
            low_load) LOW_LOAD=$v; olo=1 ;;
            prime_trigger) PRIME_TRIGGER=$v; op=1 ;;
        esac
    done < "$CFG"

    case "$STYLE" in
        eco)
            [ -z "$ohi" ] && HIGH_LOAD=90
            [ -z "$olo" ] && LOW_LOAD=65
            [ -z "$op" ] && PRIME_TRIGGER=2200000
            ;;
        perf)
            [ -z "$ohi" ] && HIGH_LOAD=75
            [ -z "$olo" ] && LOW_LOAD=45
            [ -z "$op" ] && PRIME_TRIGGER=1500000
            ;;
        *)
            [ -z "$ohi" ] && HIGH_LOAD=85
            [ -z "$olo" ] && LOW_LOAD=55
            [ -z "$op" ] && PRIME_TRIGGER=1800000
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

# ---------- CPU 使用率（核心判据）----------
# 一次读 /proc/stat，输出整数百分比
# 注意：用 awk 单次调用，避免多次 fork
snap_stat(){ awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9; exit}' /proc/stat; }

calc_load(){
    # $1 = 上一轮快照, $2 = 本轮快照
    echo "$1 $2" | awk '{
        busy=($9-$1)+($10-$2)+($11-$3)+($14-$6)+($15-$7)+($16-$8)
        idle=($12-$4)+($13-$5)
        if(busy+idle>0) printf "%d", busy*100/(busy+idle)
        else print 0
    }'
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

step_down(){
    local which="$1" cur="$2" n="$3" f list idx=0 tot=0 cnt=0 floor
    if [ "$which" = "B" ]; then list="$FREQ_B"; floor=$FLOOR_BIG; else list="$FREQ_P"; floor=$FLOOR_PRIME; fi
    for f in $list; do
        tot=$((tot+1))
        case "$f" in ''|*[!0-9]*) continue ;; esac
        [ "$f" -le "$cur" ] && idx=$tot
    done
    local tgt=$((idx-n))
    [ "$tgt" -lt 1 ] && tgt=1
    for f in $list; do
        cnt=$((cnt+1))
        [ "$cnt" -eq "$tgt" ] && {
            # 不能低于地板
            if [ "$f" -lt "$floor" ]; then printf '%s' "$floor"; else printf '%s' "$f"; fi
            return
        }
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
        echo "load=$LOAD"
        echo "cap_big=$CAP_B"
        echo "cap_prime=$CAP_P"
        echo "off_big=$OFF_B"
        echo "off_prime=$OFF_P"
        echo "st_big=$CUR_STB"
        echo "st_prime=$CUR_STP"
        echo "temp_big=$TB"
        echo "up_cnt=$UP_CNT"
        echo "down_cnt=$DOWN_CNT"
        echo "ts=$(date +%s)"
    } > "$OBS/state.tmp" 2>/dev/null && mv "$OBS/state.tmp" "$OBS/state" 2>/dev/null
}

skip_round(){
    SCENE="$1"
    # 注意：不重置 STAT_PREV！
    # 负载计算必须基于连续采样，重置会导致窗口变成"刚重置的瞬间"
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
log "启动 V2.0 pid=$$ style=$STYLE"

STAT_PREV=$(snap_stat)

while [ "$RUN" = "1" ]; do
    usleep $((TICK_MS * 1000))
    TICK=$((TICK+1))

    [ $((TICK % CFG_TICK)) -eq 0 ] && load_cfg

    # 熄屏
    if [ "$(screen_on)" = "0" ]; then
        release; CAP_B=0; CAP_P=0; UP_CNT=0; DOWN_CNT=0
        skip_round "off"
        continue
    fi

    # 关闭
    if [ "$ENABLED" != "1" ] || [ "$MODE" != "auto" ]; then
        release; CAP_B=0; CAP_P=0; UP_CNT=0; DOWN_CNT=0
        skip_round "disabled"
        continue
    fi

    read_off

    # 开机保护
    NOW_S=$(date +%s)
    if [ $((NOW_S - BOOT_TS)) -lt "$BOOT_SKIP" ]; then
        release; CAP_B=0; CAP_P=0; UP_CNT=0; DOWN_CNT=0
        skip_round "boot"
        continue
    fi

    # 温度
    TB=$(cat "$THERMAL/thermal_zone1/temp" 2>/dev/null)
    case "$TB" in ''|*[!0-9]*) TB=0 ;; esac
    if [ "$TB" -ge "$T_HARD" ]; then
        release; CAP_B=0; CAP_P=0; UP_CNT=0; DOWN_CNT=0
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
        release; CAP_B=0; CAP_P=0; UP_CNT=0; DOWN_CNT=0
        skip_round "game"
        continue
    fi

    # 冷启动保护
    NOWMS=$(date +%s%3N)
    if [ $((NOWMS - FG_TS)) -lt "$APP_SKIP_MS" ]; then
        CAP_B=$LAUNCH_CAP_B; CAP_P=$LAUNCH_CAP_P
        apply "$CAP_B" "$CAP_P"
        UP_CNT=0; DOWN_CNT=0
        skip_round "launch"
        continue
    fi

    # ---------- 核心：CPU 使用率 ----------
    STAT_NOW=$(snap_stat)
    LOAD=$(calc_load "$STAT_PREV" "$STAT_NOW")
    case "$LOAD" in ''|*[!0-9]*) LOAD=0 ;; esac
    STAT_PREV="$STAT_NOW"

    # 关键：CAP_B 必须与实际值同步，否则会基于过期缓存做决策
    CUR_MAX=$(cat "$POL_B/scaling_max_freq" 2>/dev/null)
    case "$CUR_MAX" in ''|*[!0-9]*) CUR_MAX=$OFF_B ;; esac
    # 如果实际值 >= 官方天花板，说明我们没在压（让路状态）
    if [ "$CUR_MAX" -ge "$OFF_B" ]; then
        CAP_B=0
    else
        CAP_B=$CUR_MAX
    fi

    # ---------- 决策：用使用率直接换算目标频率 ----------
    #
    # 原理：CPU 使用率反映「有多少活」
    #   使用率 100% → 活干不完，需要更多频率
    #   使用率 50%  → 正好一半时间在跑，频率够用
    #
    # 目标频率 = 当前频率 × (使用率 / 目标使用率)
    #   目标使用率 = 70%（留 30% 余量应对突发）
    #
    # 例：当前 748800，使用率 100%
    #     → 目标 = 748800 × (100/70) = 1069714 → 对齐 960000
    #   例：当前 1785600，使用率 40%
    #     → 目标 = 1785600 × (40/70) = 1020342 → 对齐 960000
    #
    # 这样一次就能算出合适值，不用逐档试探

    CUR_MAX=$(cat "$POL_B/scaling_max_freq" 2>/dev/null)
    case "$CUR_MAX" in ''|*[!0-9]*) CUR_MAX=$OFF_B ;; esac

    # 关键公式：NEW_CAP = CUR_MAX × (LOAD / TARGET)^2
    #
    # 为什么用平方：
    #   LOAD=100%, TARGET=70 → (100/70)^2 = 2.04 → 翻倍（饱和说明严重不足）
    #   LOAD=70%,  TARGET=70 → 1.0 → 不变（正好）
    #   LOAD=50%,  TARGET=70 → 0.51 → 减半（一半时间闲着）
    #
    # 线性公式的问题是：饱和时只升 1.4 倍，不够

    TARGET_LOAD=70

    if [ "$LOAD" -gt 0 ]; then
        # 先算比例，再平方（用整数运算放大精度）
        RATIO=$(( LOAD * 100 / TARGET_LOAD ))       # 例如 142 = 1.42x
        NEW_CAP=$(( CUR_MAX * RATIO / 100 * RATIO / 100 ))
    else
        NEW_CAP=$(( CUR_MAX / 4 ))
    fi

    # 限幅：单次 0.4x ~ 2.5x
    MAX_STEP=$(( CUR_MAX * 25 / 10 ))
    MIN_STEP=$(( CUR_MAX * 4 / 10 ))
    [ "$NEW_CAP" -gt "$MAX_STEP" ] && NEW_CAP=$MAX_STEP
    [ "$NEW_CAP" -lt "$MIN_STEP" ] && NEW_CAP=$MIN_STEP

    # 对齐到真实频点
    NEW_CAP=$(snap_freq B "$NEW_CAP")

    # 只在偏离当前值足够大时才调整（死区，防抖）
    DIFF=$(( NEW_CAP - CUR_MAX ))
    [ "$DIFF" -lt 0 ] && DIFF=$(( -DIFF ))
    DEAD_ZONE=$(( CUR_MAX * 12 / 100 ))    # 12% 死区

    if [ "$DIFF" -ge "$DEAD_ZONE" ]; then
        if [ "$NEW_CAP" -gt "$CUR_MAX" ]; then
            # 升档：立即执行（防卡优先）
            CAP_B=$NEW_CAP
            UP_CNT=0
            DOWN_CNT=0
            SCENE="boost"
        else
            # 降档：累积 8 次确认（不要求连续，因为负载有波动）
            DOWN_CNT=$((DOWN_CNT+1))
            UP_CNT=0
            if [ "$DOWN_CNT" -ge 8 ]; then
                CAP_B=$NEW_CAP
                DOWN_CNT=0
                SCENE="rich"
            else
                SCENE="rich_wait"
                CAP_B=$CUR_MAX
            fi
        fi
    else
        # 死区内：保持，但不重置降档计数（允许累积）
        SCENE="hold"
        UP_CNT=0
        if [ "$DOWN_CNT" -gt 0 ] && [ "$LOAD" -gt "$TARGET_LOAD" ]; then
            # 负载回升到目标以上，才清零降档计数
            DOWN_CNT=0
        fi
        CAP_B=$CUR_MAX
    fi




    # 超大核
    if [ "$STYLE" = "eco" ]; then
        CAP_P=$FLOOR_PRIME
    else
        # 按使用率决定：高负载时给满
        if [ "$LOAD" -ge "$HIGH_LOAD" ]; then
            CAP_P=$OFF_P
        elif [ "$CAP_B" -ge "$PRIME_TRIGGER" ]; then
            CAP_P=$OFF_P
        else
            CAP_P=$FLOOR_PRIME
        fi
    fi

    # 地板
    [ "$CAP_B" -gt 0 ] && [ "$CAP_B" -lt "$FLOOR_BIG" ] && CAP_B=$FLOOR_BIG
    [ "$CAP_P" -gt 0 ] && [ "$CAP_P" -lt "$FLOOR_PRIME" ] && CAP_P=$FLOOR_PRIME

    apply "$CAP_B" "$CAP_P"
    [ $((TICK % STATE_TICK)) -eq 0 ] && write_state
done

cleanup
