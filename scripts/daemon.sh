#!/system/bin/sh
# =====================================================================
# 8elite 限频 V1.4fix — 双判据容积伺服 (Dual-Criterion Servo, DCS)
# 模块包版本 V1.4fix
#
# 【上机前必做】
#   1. 跑 probe.sh，把 cooling state -> 频率 的真表确认一遍，
#      替换 $D/config/map_big.conf / map_prime.conf
#   2. 用 sh -n daemon.sh 过一遍语法（Android 是 mksh / toybox sh）
#
# 【V1.4fix 修复：守护被系统冻结 → 状态不更新 / WebUI 报“服务未运行” / 反复重启】
#   根因：WebUI / ctl.sh 通过 KernelSU 的 ksu.exec 拉起守护，子进程继承的是
#         KernelSU 管理器自己的 app cgroup（/sys/fs/cgroup/apps/uid_XXXX/pid_XXXX）。
#         管理器一切到后台，整组 cgroup.freeze 被置 1，daemon / watchdog 连同
#         触摸协程一起被冻住：state 不再刷新 → watchdog 醒来判定“状态超时” →
#         kill -9 后重拉 → 新进程又落进同一个冻结域 → 越拉越多（实测堆了 9 个）。
#   修复：启动第一件事把自身移出 app 冻结域（写 /sys/fs/cgroup/cgroup.procs 到根），
#         子进程再 fork 时继承根 cgroup；watchdog 增加“被冻结则解冻而非错杀”；
#         单实例改用 pid+cmdline+冻结状态三重校验，杜绝重复实例。
#
# 【V1.4fix 修复：map 表是凭空编的】
#   V1.4 的 map_big.conf 声称“大核 cooling 只有 3 个有效档、state0-9=2400000”，
#   实测为假：state 0-15 逐档是 3072000 一路降到 384000，748800 真实存在。
#   map_prime.conf 声称“全部 16 档都是 1689600”，同样为假：实测 15 档可用，
#   最低 1017600。两张表已按 probe.sh 实测结果重写。
#
# 【V1.4 修复：为什么静止落不到 748MHz】
#   1. 需求前馈单位口径错 100 倍：LOAD_B 是千分比(0-1000)、TARGET 是
#      百分比(0-100)，原式 /1000 应为 /10；且 FAVG_B 是"含空闲时段的
#      总均频"而非"忙时均频"，须扣除 F_min*(1-U)。
#      两错叠加 -> 需求信号彻底失效，cap 被钉死在 ~1.1G 上限（又卡又费电）。
#      现式：NEED=(FAVG*1000 - FLOOR*(1000-U))/(10*TARGET)
#   2. 撞顶率判据在底板退化：cap==最低OPP 时 CPU 只能贴着天花板跑，
#      SAT 恒为 100% -> 上行增益永久顶满 -> 748<->1122 极限环振荡，
#      表现就是"永远落不下去"。
#      修复：NEED 到底板时强制 BOOST=1000，禁止再抬。
#   3. 新增空闲快降通道：非交互/非冷启动/非游戏 且 U<12% 持续 6 tick 后，
#      跳过 8 次确认，按 -40%/tick 直落 748（原来 32 tick，现约 3 tick）。
#   4. 对偶的触摸瞬时抬升：激进下压必须配瞬时抬升——有交互/冷启动时
#      若 cap 还压在低位，直接抬到 TOUCH_FLOOR，不等反馈环（保流畅）。
#   5. 空闲时立即释放超大核（省掉 5 tick 迟滞），触摸时立即挂回。
#   6. 窗口拉伸仅在真空闲时启用（原来越空闲采样越慢，自相矛盾）。
#   7. 接上原为死代码的 is_game()：游戏前台不做激进下压，保流畅。
#
# 【固有机制（沿用 V1.3）】
#        need = 忙时均频 * U / T          cap-invariant 需求密度前馈
#        cap  = need * (1 + K*(S - Sband)) 撞顶率伺服（不饱和判据）
#        TARGET_LOAD 由整机功耗外环整定    消除魔法常数
#        内部维护权威 cap，节点值仅用于对账 抗 oiface 抢写
#        触摸/功耗/网络档位等感知输入      借自 EtaTune，不引入其调度逻辑
#
# 【作者】罗霄山
# =====================================================================

D=/data/adb/eta_sched
BASE=/storage/emulated/0/Android/8elite
OBS=$BASE/obs
# 主状态文件放在 root 私有目录：daemon 一定能写、ksu.exec(root) 一定能读，
# 彻底避开 /storage/emulated/0 的 FUSE 挂载/命名空间不确定性（这正是 WebUI 偶发
# “服务未运行” 的根因之一）。OBS/state 仅作兼容镜像。
STATE=$D/state
CFG=$BASE/config.conf
LEARN=$D/learned

CPUFREQ=/sys/devices/system/cpu/cpufreq
THERMAL=/sys/class/thermal
MSM=/sys/kernel/msm_performance/parameters/cpu_max_freq
BAT=/sys/class/power_supply/battery
GPU=/sys/class/kgsl/kgsl-3d0/devfreq/mod_percent

# ---------------- 参数（均可被 config.conf 覆盖）----------------
WIN_MS=200            # 决策窗口 ms（静置时自动拉伸）
TARGET_LOAD=50        # 目标忙占比 %，由功耗外环在 [35,75] 内整定
SAT_HI=300            # 撞顶率上限 ‰ (0.300)
SAT_LO=60             # 撞顶率下限 ‰ (0.060)
K_UP=1200             # 上行增益 x1000
K_DN=600              # 下行增益 x1000
FLOOR_BIG=748800        # 大核地板（实测 cooling state13 = 748800，真实存在）
FLOOR_PRIME=1017600     # 超大核地板（实测 cooling state15 = 1017600）
CPU_MIN_B=384000        # 大核硬件最低频，仅用于把“总均频”折算成“忙时均频”
UP_CONFIRM=2
DOWN_CONFIRM=8
UP_RATE=1500          # 单 tick 最大 +50% (x1000)
DOWN_RATE=750         # 单 tick 最大 -25% (x1000)
T_SOFT=62000          # m°C
T_HARD=82000
T_MIN_GAIN=550        # x1000
T_PANIC=90000         # 真危险才彻底让路
PWR_BUDGET_DATA=2200  # mW
PWR_BUDGET_WIFI=2700
PWR_HYST=250          # mW
LAUNCH_MS=2500        # 冷启动保护窗口（替代 V1 的 15s）
TOUCH_HOLD=3          # 触摸后保持秒数
TOUCH_FLOOR=1363200   # 交互期间大核下限
PRIME_ON=2000000      # 超大核 engage 阈值
PRIME_OFF=1500000     # 超大核 release 阈值
PRIME_ON_HOLD=2       # tick
PRIME_OFF_HOLD=5      # tick
BOOT_SKIP=60          # s
REASSERT=10           # 每 N tick 强制重断言（抗漂移）
IDLE_STRETCH=30       # 连续 N tick 无事件 -> 窗口拉伸到 500ms
IDLE_ENTER=6          # 连续 N tick 达成空闲 -> 进入快降通道
IDLE_LOAD=120         # 空闲判据：大核利用率 < 12.0 千分比(12.0%)
IDLE_RATE=600         # 快降：单 tick 最大 -40% (x1000)
STYLE=eco
ENABLED=1
MODE=auto

# ---------------- 状态 ----------------
RUN=1
TICK=0
QUIET=0
IDLE_CNT=0
IDLE_MODE=0
GAMEF=0
CAP_B=0
CAP_P=0
STB=-1
STP=-1
UP_CNT=0
DOWN_CNT=0
TARGET=50          # 运行时 TARGET_LOAD（会被外环改）
PRIME_ONF=0
PRIME_HOLD=0
LAST_TOUCH=0
LAUNCH_UNTIL=0
FG=""
PREV_FG=""
SCENE="init"
LOAD_B=0
FAVG_B=0
SAT_B=0
POW=0
NEED=0
TB=0
STOCK_B=3532800
STOCK_P=4320000
CPUS_B="0 1 2 3 4 5"
CPUS_P="6 7"
FREQ_B=""
FREQ_P=""

LOG=$OBS/daemon.log
# ---------------------------------------------------------------------
# 逃逸 app 冻结域（V1.4fix 核心修复）
#   ksu.exec 拉起的进程默认落在 KernelSU 管理器的 app cgroup 里，
#   管理器退后台 -> cgroup.freeze=1 -> 本进程连带子进程全部挂起，
#   state 停更 -> watchdog 判超时 -> kill 后重拉 -> 又落回同一冻结域。
#   移入 cgroup v2 根（/sys/fs/cgroup/cgroup.procs）后由 init 托管，不再被 app 冻结。
detach_freeze(){
    local me cur i=0
    me=$$
    # 已经在根 cgroup（0::/）就不用动
    while IFS= read -r cur; do
        case "$cur" in
            "0::/") return 0 ;;
        esac
    done < /proc/$$/cgroup 2>/dev/null
    echo $me > /sys/fs/cgroup/cgroup.procs 2>/dev/null && return 0
    # 兜底：逐个父进程试
    while [ $i -lt 3 ]; do
        i=$((i+1))
        echo $me > /sys/fs/cgroup/cgroup.procs 2>/dev/null && return 0
        usleep 200000
    done
    return 1
}

# ---------------------------------------------------------------------
# Android /system/bin/sh (mksh) 的 $(( )) 是 32 位有符号整型：
#   1555200 * 1500 = 2332800000 > 2^31-1  → 溢出成负数
# 所有「频率 × 千分比系数」都必须先除后乘，否则算出的上限是负值，
# 表现为「满载反而降频 / 上限完全失效」。这个函数封装安全的按千分比缩放。
#   pct_mul <数值> <千分比>  -> 结果（四舍五入到整数）
pct_mul(){
    local v=$1 p=$2
    if [ "$v" -ge 0 ]; then
        _pm=$(( (v / 1000) * p + ((v % 1000) * p) / 1000 ))
    else
        _pm=$(( -(( (-v / 1000) * p + ((-v % 1000) * p) / 1000 )) ))
    fi
}
# ---------------------------------------------------------------------
# 零 fork 工具：全部用 shell 内建 read，避免 $(cat) / $(awk) / $(date)
_rv=""
get(){ _rv=""; read -r _rv < "$1" 2>/dev/null; case "$_rv" in ''|*[!0-9-]*) _rv="${2:-0}";; esac; }
gets(){ _rv=""; read -r _rv < "$1" 2>/dev/null; }

log(){ echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }

# 统一用 /proc/uptime 做单调秒计数（read 是内建，零 fork）
now_s(){
    gets /proc/uptime
    case "$_rv" in *.*) _rv=${_rv%%.*} ;; esac
    case "$_rv" in ''|*[!0-9]*) _rv=0 ;; esac
}
# ---------------------------------------------------------------------
# 拓扑探测
find_paths(){
    local d rc
    POL_B=""; POL_P=""
    for d in $CPUFREQ/policy*/; do
        [ -d "$d" ] || continue
        gets "${d}related_cpus"; rc="$_rv"
        case "$rc" in *6*|*7*) POL_P="${d%/}"; CPUS_P="$rc" ;; esac
        [ -z "$POL_B" ] && { POL_B="${d%/}"; CPUS_B="$rc"; }
    done
    [ -n "$POL_B" ] || POL_B="$CPUFREQ/policy0"
    [ -n "$POL_P" ] || POL_P="$CPUFREQ/policy6"

    CD_B=""; CD_P=""
    for d in $THERMAL/cooling_device*/; do
        [ -d "$d" ] || continue
        gets "${d}type"
        case "$_rv" in
            cpufreq-cpu0) CD_B="${d%/}" ;;
            cpufreq-cpu6|cpufreq-cpu7) CD_P="${d%/}" ;;
        esac
    done
    [ -n "$CD_B" ] || CD_B="$THERMAL/cooling_device3"
    [ -n "$CD_P" ] || CD_P="$THERMAL/cooling_device4"

    gets "$POL_B/scaling_available_frequencies"; FREQ_B="$_rv"
    gets "$POL_P/scaling_available_frequencies"; FREQ_P="$_rv"
}

read_stock(){
    local v pair k
    gets "$MSM"; v="$_rv"
    for pair in $v; do
        k="${pair%%:*}"
        case "$k" in 0) get_val "${pair#*:}"; STOCK_B=$_nv ;; 6) get_val "${pair#*:}"; STOCK_P=$_nv ;; esac
    done
    # 兜底：cpuinfo_max_freq
    get "$POL_B/cpuinfo_max_freq" 3532800; rb=$_rv
    get "$POL_P/cpuinfo_max_freq" 4320000; rp=$_rv
    [ "$STOCK_B" -le 0 ] 2>/dev/null && STOCK_B=$rb
    [ "$STOCK_P" -le 0 ] 2>/dev/null && STOCK_P=$rp
    [ "$STOCK_B" -gt "$rb" ] 2>/dev/null && STOCK_B=$rb
    [ "$STOCK_P" -gt "$rp" ] 2>/dev/null && STOCK_P=$rp
}
_nv=0
get_val(){ case "$1" in ''|*[!0-9]*) _nv=0;; *) _nv=$1;; esac; }
# ---------------------------------------------------------------------
# 配置
load_cfg(){
    [ -f "$CFG" ] || return 0
    local k v
    while IFS='=' read -r k v || [ -n "$k" ]; do
        case "$k" in ''|'#'*) continue ;; esac
        v=$(printf '%s' "$v" | tr -d ' \t\r')
        case "$v" in ''|*[!0-9]*) ;; esac
        case "$k" in
            enabled)            [ -n "$v" ] && ENABLED=$v ;;
            mode)               MODE=$v ;;
            style)              STYLE=$v ;;
            window_ms)          WIN_MS=$v ;;
            target_load)        TARGET_LOAD=$v ;;
            sat_hi)             SAT_HI=$v ;;
            sat_lo)             SAT_LO=$v ;;
            k_up)               K_UP=$v ;;
            k_dn)               K_DN=$v ;;
            floor_big)          FLOOR_BIG=$v ;;
            floor_prime)        FLOOR_PRIME=$v ;;
            prime_on)           PRIME_ON=$v ;;
            prime_off)          PRIME_OFF=$v ;;
            pwr_budget)         PWR_BUDGET_DATA=$v ;;
            pwr_budget_wifi)    PWR_BUDGET_WIFI=$v ;;
            touch_floor)        TOUCH_FLOOR=$v ;;
            launch_ms)          LAUNCH_MS=$v ;;
        esac
    done < "$CFG"
    case "$STYLE" in
        perf)   TARGET=$((TARGET_LOAD + 20)) ;;
        eco)    TARGET=$((TARGET_LOAD - 5)) ;;
        *)      TARGET=$TARGET_LOAD ;;
    esac
    [ "$TARGET" -lt 35 ] && TARGET=35
    [ "$TARGET" -gt 85 ] && TARGET=85
}
# ---------------------------------------------------------------------
# 前台：异步探测，主循环永不阻塞
probe_fg(){
    [ -f "$D/.fg.busy" ] && return
    : > "$D/.fg.busy"
    (
        f=$(timeout 3 dumpsys activity activities 2>/dev/null \
            | sed -n 's/.* topResumedActivity[^ ]* u[0-9]* \([a-zA-Z0-9_][a-zA-Z0-9_.]*\)\/.*/\1/p' | head -1)
        [ -n "$f" ] || f=$(timeout 3 dumpsys window 2>/dev/null \
            | sed -n 's/.* mCurrentFocus=Window{[^}]* u[0-9]* \([a-zA-Z0-9_][a-zA-Z0-9_.]*\)\/.*/\1/p' | head -1)
        case "$f" in
            ''|*InputMethod*|com.android.systemui|NotificationShade|StatusBar) f="" ;;
        esac
        printf '%s' "$f" > "$D/.fg"
        rm -f "$D/.fg.busy"
    ) &
}
read_fg(){
    [ -f "$D/.fg" ] || return
    gets "$D/.fg"
    case "$_rv" in ''|*[!a-zA-Z0-9_.]*) return ;; esac
    [ "$_rv" = "$FG" ] && return
    PREV_FG="$FG"; FG="$_rv"
    on_fg_change
}
# 网络模式（WiFi / 数据双功耗预算，思路移植自 EtaTune x8u_eco）
net_probe(){
    local iface dest
    while read -r iface dest rest; do
        [ "$iface" = lo ] && continue
        case "$dest" in
            00000000)
                case "$iface" in
                    wlan*) echo wifi > "$D/net.mode" 2>/dev/null; return ;;
                esac ;;
        esac
    done < /proc/net/route
    echo data > "$D/net.mode" 2>/dev/null
}
# ---------------------------------------------------------------------
# 触摸监听协程（移植自 EtaTune x8u_eco，改为写时间戳）
# 找触摸屏对应的 eventN
#   旧实现用 `grep -A6 NAME | grep event` 向后越界匹配，在本机会先抓到
#   指纹传感器 tmf8806 的 event9，导致每秒都被判定为"正在触摸"，
#   结果永远 RUSH=1、永远不降频（表现为静止也锁着高频）。必须按设备块解析：
#   在同一个 "I: Bus=" 块内，Name 命中触摸名后只取其自身的 Handlers 行。
find_touch_ev(){
    # 一次 awk 扫完整文件：只有在「当前块 Name 命中触摸名」时才记录该块的 Handlers
    _ev=$(awk '
        /^I: Bus=/ { name=""; hd="" }
        /^N: Name=/ { name=$0 }
        /^H: Handlers=/ { if (name ~ /touchpanel|fts_ts|synaptics|goodix|sec_touchscreen/) { hd=$0 } }
        /^$/ { if (hd != "") { print hd; exit } }
        END { if (hd != "") print hd }
    ' /proc/bus/input/devices 2>/dev/null | head -1 | sed 's/^H: Handlers=//')
    case "$_ev" in *event[0-9]*) ;; *) _ev=""; return 1 ;; esac
    # 从 Handlers 行里挑出 eventN
    # Handlers 可能含多个 eventN，取第一个
    for t in $_ev; do
        case "$t" in event[0-9]*) _ev=$t; return 0 ;; esac
    done
    _ev=""; return 1
}
start_touch(){
    local ev
    find_touch_ev && ev=$_ev
    [ -z "$ev" ] && { log "[touch] 未找到触摸屏输入设备，触摸抬频已禁用（不影响限频主逻辑）"; return; }
    case "$ev" in event[0-9]*) ;; *) log "[touch] 设备名异常 $ev，禁用"; return ;; esac
    log "[touch] 监听 /dev/input/$ev"
    (
        # 只有「阻塞读」才算真实触摸：
        # 本机 event9 在无操作时会立即返回 EOF/0 字节，旧实现对每次返回都记一次
        # 触摸 → touch.ts 每秒刷新 → 永远 RUSH=1 → 永远不降频（幽灵触摸的真身）。
        # 这里用 /proc/uptime 前后差判定：读取耗时 < 300ms 视为噪声，丢弃。
        while [ -d "/proc/$$" ]; do
            now_s; _t0=$_rv
            dd if="/dev/input/$ev" bs=24 count=1 2>/dev/null >/dev/null
            now_s; _t1=$_rv
            if [ $(( _t1 - _t0 )) -ge 1 ]; then
                echo "$_t1" > "$D/touch.ts"
            else
                usleep 400000        # 噪声，退避避免空转
            fi
        done
    ) &
}
touch_recent(){
    [ -f "$D/touch.ts" ] || return 1
    gets "$D/touch.ts"
    case "$_rv" in ''|*[!0-9]*) return 1 ;; esac
    LAST_TOUCH=$_rv
    now_s
    [ $(( _rv - LAST_TOUCH )) -lt "$TOUCH_HOLD" ]
}
# ---------------------------------------------------------------------
# 屏幕状态：多源判定 + fail-safe 到“亮”
SCR=0
screen_off(){
    local s=0 w
    for p in /sys/class/backlight/panel0-backlight/brightness \
             /sys/class/backlight/panel0-backlight/max_brightness \
             /sys/class/leds/lcd-backlight/brightness; do
        [ -r "$p" ] || continue
        get "$p" 0; s=$_rv
        break
    done
    [ "$s" -gt 0 ] && { SCR=1; return 1; }
    # 回退到 PowerManager（较重，低频调用）
    w=$(timeout 2 dumpsys power 2>/dev/null | sed -n 's/.*mWakefulness=\([a-zA-Z]*\).*/\1/p' | head -1)
    case "$w" in
        Asleep|Dozing) SCR=0; return 0 ;;
        Awake)         SCR=1; return 1 ;;
    esac
    SCR=1; return 1   # 全部失败 -> 假定亮屏（fail-safe）
}
# ---------------------------------------------------------------------
# charging
charging(){
    gets "$BAT/status"
    case "$_rv" in Charging|Full) return 0 ;; esac
    return 1
}
# ---------------------------------------------------------------------
# 温度：遍历 zone，取 type 含 cpu/soc 的最大值 + 单位自适应
read_temp(){
    local best=0 v t d
    for d in $THERMAL/thermal_zone*/; do
        [ -d "$d" ] || continue
        gets "${d}type"
        case "$_rv" in *cpu*|*soc*|*tsens*|*cluster*) ;; *) continue ;; esac
        get "${d}temp" 0; v=$_rv
        [ "$v" -le 0 ] 2>/dev/null && continue
        [ "$v" -lt 1000 ] && v=$((v * 1000))   # 单位自适应
        [ "$v" -gt "$best" ] && best=$v
    done
    TB=$best
    [ "$TB" -eq 0 ] && get "$THERMAL/thermal_zone1/temp" 0 && TB=$_rv && { [ "$TB" -lt 1000 ] && TB=$((TB*1000)); }
}
# ---------------------------------------------------------------------
# 每簇利用率：/proc/stat cpuN 行按簇求和（零 fork）
SB_PREV=0; SI_PREV=0; SP_PREV=0; SPI_PREV=0
U_B=0; U_P=0
read_stat(){
    local tag n b i f1 f2 f3 f4 f5 f6 f7 f8
    local bb=0 ib=0 bp=0 ip=0
    while read -r tag f1 f2 f3 f4 f5 f6 f7 f8 rest; do
        case "$tag" in cpu[0-9]*) ;; *) continue ;; esac
        case "$f8" in ''|*[!0-9]*) continue ;; esac
        n=${tag#cpu}
        case "$n" in *[!0-9]*) continue ;; esac
        b=$(( f1 + f2 + f3 + f6 + f7 + f8 ))     # user nice system irq softirq steal
        i=$(( f4 + f5 ))                          # idle + iowait
        case " $CPUS_B " in *" $n "*) bb=$((bb+b)); ib=$((ib+i)) ;; esac
        case " $CPUS_P " in *" $n "*) bp=$((bp+b)); ip=$((ip+i)) ;; esac
    done < /proc/stat
    local db di
    if [ "$SB_PREV" -gt 0 ] 2>/dev/null; then
        db=$((bb - SB_PREV)); di=$((ib - SI_PREV))
        if [ $((db + di)) -gt 0 ] 2>/dev/null; then U_B=$(( db / (db + di) * 1000 + (db % (db + di)) * 1000 / (db + di) )); else U_B=0; fi
    fi
    if [ "$SP_PREV" -gt 0 ] 2>/dev/null; then
        db=$((bp - SP_PREV)); di=$((ip - SPI_PREV))
        if [ $((db + di)) -gt 0 ] 2>/dev/null; then U_P=$(( db / (db + di) * 1000 + (db % (db + di)) * 1000 / (db + di) )); else U_P=0; fi
    fi
    SB_PREV=$bb; SI_PREV=$ib; SP_PREV=$bp; SPI_PREV=$ip
}
# ---------------------------------------------------------------------
# time_in_state：一次遍历得到 累计总和 / 累计加权频率 / 累计近顶驻留
TIS_B=$CPUFREQ/policy0/stats/time_in_state
TIS_P=$CPUFREQ/policy6/stats/time_in_state
WTOT_B=0; WSUM_B=0; WTOP_B=0; TSUM_B=0; TTOP_B=0
WTOT_P=0; WSUM_P=0; WTOP_P=0
_has_tis=0
tis_scan(){    # $1=file  $2=threshold_freq  -> _t_sum _t_wsum _t_top (累计值)
    local f j
    _t_sum=0; _t_wsum=0; _t_top=0
    while read -r f j rest; do
        case "$f" in ''|*[!0-9]*) continue ;; esac
        case "$j" in ''|*[!0-9]*) continue ;; esac
        _t_sum=$(( _t_sum + j ))
        _t_wsum=$(( _t_wsum + (f / 100) * j * 100 ))
        [ "$f" -ge "$2" ] 2>/dev/null && _t_top=$(( _t_top + j ))
    done < "$1"
}
# ---------------------------------------------------------------------
# 撞顶率降级采样（无 time_in_state 时用）
poll_sat(){
    local i n=0 cur th
    th=$(( $1 * 9 / 10 ))
    i=0
    while [ $i -lt 5 ]; do
        get "$POL_B/scaling_cur_freq" 0; cur=$_rv
        [ "$cur" -ge "$th" ] 2>/dev/null && n=$((n+1))
        i=$((i+1))
        usleep 30000
    done
    _ps=$(( n * 1000 / 5 ))
}
# ---------------------------------------------------------------------
# 功耗
PWR_AVG=0
read_power(){
    local c v
    get "$BAT/current_now" 0; c=$_rv
    get "$BAT/voltage_now" 0; v=$_rv
    [ "$c" -lt 0 ] && c=$(( -c ))
    [ "$v" -le 0 ] 2>/dev/null && { POW=0; return; }
    POW=$(( c / 1000 * (v / 1000) / 1000 ))
    if [ "$PWR_AVG" -eq 0 ] 2>/dev/null; then PWR_AVG=$POW
    else PWR_AVG=$(( (PWR_AVG * 7 + POW * 3) / 10 )); fi
}
# ---------------------------------------------------------------------
# 应用到 cooling device（state map）
_st=0
freq_to_state(){   # $1=map  $2=freq  $3=可用频率表(兜底用)
    local st f bf=-1 lof=999999999 lost=0
    _st=0
    if [ -f "$1" ]; then
        while read -r st f; do
            case "$f" in ''|*[!0-9]*) continue ;; esac
            [ "$f" -lt "$lof" ] && { lof=$f; lost=$st; }
            [ "$f" -le "$2" ] 2>/dev/null || continue
            [ "$f" -gt "$bf" ] && { bf=$f; _st=$st; }
        done < "$1"
        # 目标低于真表所有档时，返回最低档（state 号最大者）而非默认 0（=释放），
        # 否则会把"想限到很低"误判成"释放到 2400000"，正是旧版静止天花板的根因类别。
        [ "$bf" -lt 0 ] && _st=$lost
        return
    fi
    # 兜底：假定 state N = 降序第 N 个 OPP
    local idx=0 prev=0
    for f in $3; do
        case "$f" in ''|*[!0-9]*) continue ;; esac
        [ "$f" -gt "$2" ] 2>/dev/null && idx=$((idx+1))
    done
    _st=$idx
}
st_set(){
    local cur
    get "$2/cur_state" -1; cur=$_rv
    if [ "$1" != "$cur" ] || [ $((TICK % REASSERT)) -eq 0 ]; then
        echo "$1" > "$2/cur_state" 2>/dev/null
    fi
}
release_all(){
    echo 0 > "$CD_B/cur_state" 2>/dev/null
    echo 0 > "$CD_P/cur_state" 2>/dev/null
    STB=0; STP=0
}
apply_caps(){
    local sb sp
    if [ "$CAP_B" -ge "$STOCK_B" ] 2>/dev/null; then sb=0
    else freq_to_state "$D/config/map_big.conf" "$CAP_B" "$FREQ_B"; sb=$_st; fi
    if [ "$CAP_P" -ge "$STOCK_P" ] 2>/dev/null; then sp=0
    else freq_to_state "$D/config/map_prime.conf" "$CAP_P" "$FREQ_P"; sp=$_st; fi
    st_set "$sb" "$CD_B"; STB=$sb
    st_set "$sp" "$CD_P"; STP=$sp
}
snap(){   # snap <list> <freq> -> _sn
    local f best=0
    _sn=0
    for f in $1; do
        case "$f" in ''|*[!0-9]*) continue ;; esac
        [ "$f" -le "$2" ] 2>/dev/null || continue
        [ "$f" -gt "$best" ] && best=$f
    done
    _sn=$best
}
# ---------------------------------------------------------------------
# 按包学习表
_lb=0; _lp=0; _ll=0
learn_get(){    # $1=pkg
    local p a b c
    _lb=0; _lp=0; _ll=0
    [ -f "$LEARN" ] || return 1
    while read -r p a b c; do
        case "$p" in ''|'#'*) continue ;; esac
        [ "$p" = "$1" ] || continue
        _lb=$a; _lp=$b; _ll=$c
        return 0
    done < "$LEARN"
    return 1
}
learn_put(){    # $1=pkg $2=capB $3=capP $4=launch
    local tmp="$LEARN.tmp" p a b c hit=0 n=0
    : > "$tmp" 2>/dev/null || return
    if [ -f "$LEARN" ]; then
        while read -r p a b c; do
            case "$p" in ''|'#'*) continue ;; esac
            n=$((n+1))
            [ "$n" -gt 300 ] && continue
            if [ "$p" = "$1" ]; then
                p=$1; a=$2; b=$3; c=$4; hit=1
            fi
            printf '%s %s %s %s\n' "$p" "$a" "$b" "$c" >> "$tmp"
        done < "$LEARN"
    fi
    [ "$hit" = 1 ] || printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$tmp"
    mv "$tmp" "$LEARN" 2>/dev/null
}
STABLE_TICK=0
learn_update(){
    # 只有判据可信（撞顶率落在死区内）且稳定足够久才回写
    if [ "$SAT_B" -le "$SAT_HI" ] && [ "$SAT_B" -ge "$SAT_LO" ] && [ -n "$FG" ]; then
        STABLE_TICK=$((STABLE_TICK+1))
        if [ "$STABLE_TICK" -ge 20 ]; then
            learn_get "$FG"
            local nb=$_lb np=$_lp nl=$_ll
            if [ "$nb" -le 0 ] 2>/dev/null; then nb=$CAP_B
            else nb=$(( (nb*7 + CAP_B*3) / 10 )); fi
            if [ "$np" -le 0 ] 2>/dev/null; then np=$CAP_P
            else np=$(( (np*7 + CAP_P*3) / 10 )); fi
            [ "$CAP_B" -gt "$nl" ] && nl=$CAP_B
            learn_put "$FG" "$nb" "$np" "$nl"
            STABLE_TICK=0
        fi
    else
        STABLE_TICK=0
    fi
}
on_fg_change(){
    STABLE_TICK=0
    now_s
    LAUNCH_UNTIL=$(( _rv * 1000 + LAUNCH_MS ))
    DOWN_CNT=0; UP_CNT=0
    # 用学习值做伺服初值，跳过 rate limit（爬升过程不再发生在用户眼前）
    learn_get "$FG"
    if [ "$_lb" -gt 0 ] 2>/dev/null; then
        snap "$FREQ_B" "$_lb"; CAP_B=$_sn
        [ "$CAP_B" -lt "$FLOOR_BIG" ] && CAP_B=$FLOOR_BIG
        snap "$FREQ_P" "$_lp"; CAP_P=$_sn
        [ "$CAP_P" -lt "$FLOOR_PRIME" ] && CAP_P=$FLOOR_PRIME
        log "[fg] $FG 载入学习值 capB=$CAP_B capP=$CAP_P"
    fi
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
# ---------------------------------------------------------------------
write_state(){
    {
        echo "alive=1"
        echo "scene=$SCENE"
        echo "fg=$FG"
        echo "mode=$MODE"
        echo "style=$STYLE"
        echo "load_big=$LOAD_B"
        echo "favg_big=$FAVG_B"
        echo "sat_big=$SAT_B"
        echo "need_big=$NEED"
        echo "cap_big=$CAP_B"
        echo "cap_prime=$CAP_P"
        echo "target=$TARGET"
        echo "power=$PWR_AVG"
        echo "temp=$TB"
        echo "st_big=$STB"
        echo "st_prime=$STP"
        echo "ts=$NOW"
        echo "tick=$TICK"
    } > "$STATE" 2>/dev/null
    # 兼容镜像到 emulated 路径（失败不影响主链路）
    cat "$STATE" > "$OBS/state" 2>/dev/null
}
cleanup(){
    [ "$RUN" = 0 ] && return
    RUN=0
    release_all
    rm -f "$D/daemon.pid" "$D/touch.ts" "$D/.fg.busy"
    log "退出 tick=$TICK，已归还"
    exit 0
}
# ---------------------------------------------------------------------
# ============================== 初始化 ==============================
# 必须先脱离冻结域，再 fork 任何子进程（触摸协程、前台探测都在后面）
detach_freeze || log "!! 移出 cgroup 冻结域失败（可能被系统冻结）"

mkdir -p "$OBS" "$D/config" 2>/dev/null
[ -f "$D/config/map_big.conf" ] || echo "!! map_big.conf 缺失" >> "$LOG"

find_paths
read_stock
load_cfg
# 真实上限必须以 calibration 真表 state0 为准：本机 cooling 的 state0 即允许的最高
# 频（大核 2400000），msm_performance / hwmax 读取到的 3072000/3532800 高于 cooling
# 实际允许值，若用它们会令"释放"档仍压在错误高位甚至越界。
while read -r _k _v; do
    case "$_k" in ''|\#*) continue ;; esac
    case "$_v" in *[!0-9]*) continue ;; esac
    STOCK_B=$_v; break
done < "$D/config/map_big.conf"
while read -r _k _v; do
    case "$_k" in ''|\#*) continue ;; esac
    case "$_v" in *[!0-9]*) continue ;; esac
    STOCK_P=$_v; break
done < "$D/config/map_prime.conf"
TIS_B="$POL_B/stats/time_in_state"
TIS_P="$POL_P/stats/time_in_state"
[ -r "$TIS_B" ] && _has_tis=1
echo data > "$D/net.mode" 2>/dev/null

# 本模块独立运行，不与其他限频模块共存（用户确认），无需共存检测。

# ---------------------------------------------------------------------
# 主循环内的自我解冻：系统可能反复把本进程挪回 app 冻结域，
# watchdog 每 60s 才巡一次太慢；这里每 10 tick 廉价检查一次（纯内建 read）
self_thaw(){
    local cur
    while IFS= read -r cur; do
        case "$cur" in
            "0::/") return 0 ;;
        esac
    done < /proc/$$/cgroup 2>/dev/null
    echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
}

# 单实例：pid 文件 + 「进程确实是 daemon.sh 且未被冻结」双重校验。
# 不用 flock：daemon 会 fork 触摸协程/前台探测，fd 被子进程继承后，
# 即使守护被 kill -9 锁也不会释放，下次启动会永久抢不到锁。
_holder=""
[ -f "$D/daemon.pid" ] && read -r _holder < "$D/daemon.pid" 2>/dev/null
if [ -n "$_holder" ] && [ -d "/proc/$_holder" ]; then
    _hcmd=$(tr '\0' ' ' < "/proc/$_holder/cmdline" 2>/dev/null)
    case "$_hcmd" in
        "sh $D/daemon.sh "*|"sh $D/daemon.sh")
            if ! grep -q do_freezer_trap "/proc/$_holder/wchan" 2>/dev/null; then
                log "已有实例运行 pid=$_holder，退出 pid=$$"
                exit 0
            fi
            # 旧实例被冻结：先解冻它，让它自己继续跑，本次退出
            echo "$_holder" > /sys/fs/cgroup/cgroup.procs 2>/dev/null && {
                log "解冻旧实例 pid=$_holder，退出 pid=$$"
                exit 0
            }
            ;;
    esac
fi
echo $$ > "$D/daemon.pid"
echo $$ > "$OBS/daemon.pid" 2>/dev/null

now_s; BOOT=$_rv
trap cleanup TERM INT EXIT
log "启动 V1.4fix-DCS pid=$$ win=${WIN_MS}ms base=${TARGET} sat=[$SAT_LO,$SAT_HI] tis=$_has_tis"

CAP_B=$STOCK_B
CAP_P=$STOCK_P
read_stat                     # 建立基线，下一 tick 出第一个 U
tis_scan "$TIS_B" 0; WTOT_B=$_t_sum; WSUM_B=$_t_wsum; WTOP_B=$_t_top
read_fg
start_touch
probe_fg

last_probe=0
last_cfg=0
last_pwr=0
last_learn=0
last_net=0
last_game=0
# ============================== 主循环 ==============================
log "进入主循环 pid=$$"
while [ "$RUN" = 1 ]; do
    now_s; NOW=$_rv
    QUIET=$((QUIET+1))
    # 被挪回冻结域就自己挪出来（开销：一次 read，无 fork）
    [ $((TICK % 10)) -eq 0 ] && self_thaw

    # ---------- L2 周期任务 ----------
    [ $((NOW - last_cfg)) -ge 5 ] && { load_cfg; last_cfg=$NOW; }
    [ $((NOW - last_probe)) -ge 5 ] && { probe_fg; last_probe=$NOW; }
    [ $((NOW - last_net)) -ge 30 ] && { net_probe; last_net=$NOW; }
    read_fg
    # 游戏前台判定（低频 5s 一次；游戏内不做激进下压，保流畅）
    [ $((NOW - last_game)) -ge 5 ] && { is_game "$FG" && GAMEF=1 || GAMEF=0; last_game=$NOW; }

    # 自适应决策窗口：仅真空闲时拉伸到 2.5x；下降途中保持高频采样以加快回落
    if [ "$QUIET" -gt "$IDLE_STRETCH" ] && [ "$IDLE_CNT" -ge "$IDLE_ENTER" ]; then
        usleep $(( WIN_MS * 2500 ))
    else
        usleep $(( WIN_MS * 1000 ))
    fi
    TICK=$((TICK+1))

    # ---------- 前置门控 ----------
    if [ "$ENABLED" != 1 ] || [ "$MODE" != auto ]; then
        release_all; CAP_B=$STOCK_B; CAP_P=$STOCK_P; DOWN_CNT=0
        SCENE="disabled"; write_state
        usleep 500000; continue
    fi
    if screen_off; then
        release_all; CAP_B=$STOCK_B; CAP_P=$STOCK_P; DOWN_CNT=0
        SCENE="off"; write_state
        usleep 500000; continue
    fi
    if [ $((NOW - BOOT)) -lt "$BOOT_SKIP" ]; then
        release_all; SCENE="boot"; write_state; continue
    fi

    read_temp
    read_power

    # ---------- L0 事件层：触摸 / 冷启动 ----------
    touch_recent && RUSH=1 || RUSH=0
    now_s
    [ "$_rv" -lt $((LAUNCH_UNTIL/1000)) ] 2>/dev/null && IN_LAUNCH=1 || IN_LAUNCH=0

    # 充电 -> 放开（借用 EtaTune 的判断）
    if charging && [ "$TB" -lt "$T_SOFT" ]; then
        release_all; CAP_B=$STOCK_B; CAP_P=$STOCK_P
        SCENE="charging"; write_state; continue
    fi

    # ---------- L1 采样 ----------
    read_stat
    LOAD_B=$U_B
    CAP_REF=$CAP_B
    if [ "$_has_tis" = 1 ] && [ -r "$TIS_B" ]; then
        # 撞顶率阈值必须用「固定」参考，不能跟着 CAP_B 走：
        # 每轮换阈值会让累计量 PN 与上轮 WTOP_B 的口径不一致，
        # 两者相减会出现负值，×1000/d 后直接溢出（实测 sat=30924400‰）。
        # 这里固定用当前档位的 90%，并在一轮内保持同一基准。
        tis_scan "$TIS_B" $(( CAP_REF * 9 / 10 ))
        PT=$_t_sum; PW=$_t_wsum; PN=$_t_top
        d=$(( PT - WTOT_B ))
        if [ "$d" -gt 0 ] 2>/dev/null; then
            FAVG_B=$(( (PW - WSUM_B) / d ))
            dt=$(( PN - WTOP_B ))
            [ "$dt" -lt 0 ] && dt=0          # 口径切换保护
            [ "$dt" -gt "$d" ] && dt=$d
            SAT_B=$(( dt / d * 1000 + (dt % d) * 1000 / d ))
        else
            SAT_B=0; FAVG_B=$CAP_REF
        fi
        WTOT_B=$PT; WSUM_B=$PW; WTOP_B=$PN
    else
        poll_sat "$CAP_REF"; SAT_B=$_ps
        FAVG_B=$CAP_REF
    fi

    # ---------- 4.2 需求密度前馈（绝对量，cap-invariant）----------
    # need = 忙时均频 * U / T
    #   忙时均频 * U = FAVG_total*1000 - F_min*(1000-U)   （FAVG_total 含空闲时段，须扣除）
    #   F_min 是硬件最低频（384000），不是地板 cap，否则空闲时会低估需求
    # => NEED = (FAVG_B*1000 - CPU_MIN_B*(1000-U)) / (10*TARGET)
    # 单位口径：FAVG_B:kHz   LOAD_B:千分比(0-1000)   TARGET:百分比(0-100)
    if [ "$LOAD_B" -gt 0 ] && [ "$FAVG_B" -gt 0 ] && [ "$TARGET" -gt 0 ]; then
        # 需求密度前馈：need = 忙时平均频率 × 利用率 / 目标占用
        #   FAVG_B  : 大核时间加权总均频（含空闲），kHz
        #   LOAD_B  : 簇利用率，千分比 0..1000
        #   TARGET  : 目标占用，百分比 35..85
        # 全程用 MHz 量级计算：Android 的 /system/bin/sh 是 32 位算术，
        # kHz 量级的中间量（3e6 × 1000）会溢出成负数。
        #   busy_mhz = FAVG_MHZ - MIN_MHZ*(1000-U)/1000
        #   need_khz = busy_mhz * 1000 * U / 1000 / (TARGET/100)
        #            = busy_mhz * U * 100 / TARGET
        _fu=$(( FAVG_B / 1000 ))                       # kHz -> MHz
        _cu=$(( CPU_MIN_B / 1000 ))                    # kHz -> MHz
        _idle=$(( _cu * (1000 - LOAD_B) / 1000 ))      # 空闲占比折算的等效 MHz
        _busy=$(( _fu - _idle ))                       # 忙时均频 MHz
        [ "$_busy" -lt 0 ] && _busy=0
        # busy(MHz) × U(‰) / 1000 = 实际需求 MHz；再 / (TARGET%) 放大到目标占用
        _needmhz=$(( _busy * LOAD_B / 1000 * 100 / TARGET ))
        NEED=$(( _needmhz * 1000 ))                    # MHz -> kHz       # MHz·‰ -> kHz
    else
        NEED=$FLOOR_BIG
    fi

    # ---------- 4.3 撞顶率伺服 ----------
    BOOST=1000
    if [ "$SAT_B" -gt "$SAT_HI" ]; then
        BOOST=$(( 1000 + (SAT_B - SAT_HI) * K_UP / 1000 ))
        [ "$BOOST" -gt 1500 ] && BOOST=1500
    elif [ "$SAT_B" -lt "$SAT_LO" ]; then
        BOOST=$(( 1000 - (SAT_LO - SAT_B) * K_DN / 1000 ))
        [ "$BOOST" -lt 700 ] && BOOST=700
    fi
    # 地板保护：需求已到底板时，撞顶率判据退化（cap==最低OPP 时 SAT 恒 100%），
    # 必须禁用上行增益，否则 748<->1122 极限环振荡、永远落不下去
    if [ "$NEED" -le "$FLOOR_BIG" ]; then BOOST=1000; fi
    pct_mul "$NEED" "$BOOST"; RAW=$_pm

    # ---------- 4.7 温度软增益 ----------
    if [ "$TB" -ge "$T_PANIC" ]; then
        release_all; CAP_B=$STOCK_B; CAP_P=$STOCK_P
        SCENE="panic"; write_state; continue
    fi
    if [ "$TB" -gt "$T_SOFT" ]; then
        span=$(( T_HARD - T_SOFT )); [ "$span" -le 0 ] && span=1
        g=$(( 1000 - (TB - T_SOFT) * (1000 - T_MIN_GAIN) / span ))
        [ "$g" -gt 1000 ] && g=1000
        [ "$g" -lt "$T_MIN_GAIN" ] && g=$T_MIN_GAIN
        pct_mul "$RAW" "$g"; RAW=$_pm
    fi

    # ---------- 地板 / 天花板 ----------
    [ "$RAW" -gt "$STOCK_B" ] && RAW=$STOCK_B
    [ "$RAW" -lt "$FLOOR_BIG" ] && RAW=$FLOOR_BIG
    snap "$FREQ_B" "$RAW"; RAW=$_sn
    [ "$RAW" -le 0 ] && RAW=$CAP_B

    # ---------- 4.45 触摸瞬时抬升（激进下压的对偶，保流畅）----------
    # 有交互/冷启动时，若 cap 还压在低位，直接抬到交互下限，不等反馈环
    if [ "$RUSH" = 1 ] || [ "$IN_LAUNCH" = 1 ]; then
        if [ "$CAP_B" -lt "$TOUCH_FLOOR" ]; then CAP_B=$TOUCH_FLOOR; fi
        DOWN_CNT=0; UP_CNT=0; IDLE_CNT=0
    fi

    # ---------- 4.46 空闲快降判定 ----------
    # 条件：非交互、非冷启动、非游戏前台，且大核利用率低于空闲判据
    if [ "$RUSH" = 0 ] && [ "$IN_LAUNCH" = 0 ] && [ "$GAMEF" = 0 ] \
       && [ "$LOAD_B" -lt "$IDLE_LOAD" ]; then
        IDLE_CNT=$((IDLE_CNT+1))
    else
        IDLE_CNT=0
    fi
    if [ "$IDLE_CNT" -ge "$IDLE_ENTER" ]; then IDLE_MODE=1; else IDLE_MODE=0; fi

    # ---------- 4.5 限速 + 非对称确认 ----------
    pct_mul "$CAP_B" "$UP_RATE"; HI=$_pm
    if [ "$IDLE_MODE" = 1 ]; then pct_mul "$CAP_B" "$IDLE_RATE"; LO=$_pm
    else pct_mul "$CAP_B" "$DOWN_RATE"; LO=$_pm; fi
    if [ "$RAW" -gt "$HI" ]; then RAW=$HI; fi

    # RAW 与 CAP_B 都是 snap 后的离散 OPP；相等即"已贴住目标"，无动作。
    if [ "$RAW" -ge "$CAP_B" ]; then
        DOWN_CNT=0
        if [ "$RAW" -eq "$CAP_B" ]; then
            UP_CNT=0; SCENE="hold"
        else
            UP_CNT=$((UP_CNT+1))
            if [ "$UP_CNT" -ge "$UP_CONFIRM" ] || [ "$RUSH" = 1 ] || [ "$IN_LAUNCH" = 1 ]; then
                CAP_B=$RAW; UP_CNT=0; SCENE="boost"
            else
                SCENE="rich_wait"
            fi
        fi
    else
        UP_CNT=0
        if [ "$RAW" -lt "$LO" ]; then RAW=$LO; fi
        if [ "$RUSH" = 1 ] || [ "$IN_LAUNCH" = 1 ]; then
            DOWN_CNT=0; SCENE="hold"
        elif [ "$IDLE_MODE" = 1 ]; then
            # 快降通道：跳过 8 次确认，直接落地（每 tick 最多 -40%）
            [ "$RAW" -lt "$FLOOR_BIG" ] && RAW=$FLOOR_BIG
            CAP_B=$RAW; DOWN_CNT=0; UP_CNT=0
            if [ "$CAP_B" -le "$FLOOR_BIG" ]; then SCENE="idle"; else SCENE="save"; fi
        else
            DOWN_CNT=$((DOWN_CNT+1))
            if [ "$DOWN_CNT" -ge "$DOWN_CONFIRM" ]; then
                # 交互下限：有人在戳就别压到最低
                if [ "$RUSH" = 1 ] && [ "$RAW" -lt "$TOUCH_FLOOR" ]; then RAW=$TOUCH_FLOOR; fi
                CAP_B=$RAW; DOWN_CNT=0; SCENE="save"
            else
                SCENE="rich"
            fi
        fi
    fi

    # 统一出口钳制：任何分支都不许把 CAP_B 写到地板以下 / 上限以上。
    # （V1.4 漏了这一步：快降通道按 -40%/tick 连乘会击穿地板，出现 469548kHz 这种
    #   比硬件最低 OPP 还低的值，snap 后再映射成错误 state。）
    [ "$CAP_B" -lt "$FLOOR_BIG" ] && CAP_B=$FLOOR_BIG
    [ "$CAP_B" -gt "$STOCK_B" ] && CAP_B=$STOCK_B
    snap "$FREQ_B" "$CAP_B"; [ "$_sn" -gt 0 ] && CAP_B=$_sn

    # 落底板时 RAW==CAP_B 会走进升档分支，导致场景误报为 boost/升档待确认，
    # 这里统一按空闲态纠正（cap 本身不受影响）
    if [ "$IDLE_MODE" = 1 ] && [ "$CAP_B" -le "$FLOOR_BIG" ]; then SCENE="idle"; fi

    # 空闲时直接释放超大核（省掉 5 tick 迟滞等待）；触摸时由下方 RUSH 立即重新挂上
    if [ "$IDLE_MODE" = 1 ] && [ "$CAP_B" -le "$PRIME_OFF" ]; then
        PRIME_ONF=0; PRIME_HOLD=0
    fi

    # ---------- 4.7 超大核双阈值迟滞 ----------
    if [ "$PRIME_ONF" = 0 ]; then
        if [ "$CAP_B" -ge "$PRIME_ON" ]; then
            PRIME_HOLD=$((PRIME_HOLD+1))
            if [ "$PRIME_HOLD" -ge "$PRIME_ON_HOLD" ]; then PRIME_ONF=1; PRIME_HOLD=0; fi
        else PRIME_HOLD=0; fi
    else
        if [ "$CAP_B" -le "$PRIME_OFF" ]; then
            PRIME_HOLD=$((PRIME_HOLD+1))
            if [ "$PRIME_HOLD" -ge "$PRIME_OFF_HOLD" ]; then PRIME_ONF=0; PRIME_HOLD=0; fi
        else PRIME_HOLD=0; fi
    fi
    if [ "$RUSH" = 1 ] || [ "$IN_LAUNCH" = 1 ]; then PRIME_ONF=1; fi
    if [ "$PRIME_ONF" = 1 ]; then CAP_P=$STOCK_P; else CAP_P=$FLOOR_PRIME; fi

    # ---------- 施加 ----------
    apply_caps

    # ---------- L2 外环：功耗 -> 目标利用率 ----------
    if [ $((NOW - last_pwr)) -ge 5 ]; then
        last_pwr=$NOW
        gets "$D/net.mode"; nm="$_rv"
        case "$nm" in wifi) BUD=$PWR_BUDGET_WIFI ;; *) BUD=$PWR_BUDGET_DATA ;; esac
        if [ "$PWR_AVG" -gt 0 ]; then
            if [ "$PWR_AVG" -gt "$BUD" ] && [ "$TARGET" -lt 75 ]; then TARGET=$((TARGET+1))
            elif [ "$PWR_AVG" -lt $((BUD - PWR_HYST)) ] && [ "$TARGET" -gt 35 ]; then TARGET=$((TARGET-1)); fi
        fi
    fi
    [ $((NOW - last_learn)) -ge 3 ] && { learn_update; last_learn=$NOW; }

    # ---------- 自适应窗口 ----------
    if [ "$RUSH" = 1 ] || [ "$IN_LAUNCH" = 1 ] || [ "$SAT_B" -gt "$SAT_HI" ]; then QUIET=0; fi

    [ $((TICK % 5)) -eq 0 ] && write_state
done

cleanup
