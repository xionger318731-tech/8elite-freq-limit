#!/system/bin/sh
# ============================================================
# 8elite限频 控制脚本 v1.4fix2
#   status  状态   start  启动   stop  停止
#   mode    切换   release 归还  log   日志
# ============================================================

D=/data/adb/eta_sched
OBS=/storage/emulated/0/Android/8elite/obs
STATE=$D/state
CFG=/storage/emulated/0/Android/8elite/config.conf
# 自动探测 cpufreq cooling 设备（与 daemon.sh find_paths 一致），避免硬编码到旧版 device3/4
THERMAL=/sys/class/thermal
CD_B=""; CD_P=""
for d in $THERMAL/cooling_device*/; do
    t=$(cat "${d}type" 2>/dev/null)
    case "$t" in
        cpufreq-cpu0)             CD_B="${d%/}/cur_state" ;;
        cpufreq-cpu6|cpufreq-cpu7) CD_P="${d%/}/cur_state" ;;
    esac
done
[ -n "$CD_B" ] || CD_B="$THERMAL/cooling_device3/cur_state"
[ -n "$CD_P" ] || CD_P="$THERMAL/cooling_device4/cur_state"

# 辅助：把 kHz 显示成 MHz；0/空 显示“不压/—”
fmt_mhz(){ case "$1" in ''|*[!0-9]*) echo "—"; return ;; esac; [ "$1" -le 0 ] 2>/dev/null && { echo "不压"; return; }; echo "$(( $1 / 1000 )) MHz"; }
fmt_temp(){ case "$1" in ''|*[!0-9]*) echo "—"; return ;; esac; echo "$(( $1 / 1000 )).$(( ( $1 % 1000 ) / 100 ))°C"; }

# 以 root 后台拉起守护/看门狗：
#   1) 先把自己移出 KernelSU 管理器的 app cgroup，否则子进程会继承冻结域，
#      管理器退后台就整组挂起（这是 V1.4 “服务未运行”/反复重启的真根因）
#   2) 补齐 PATH，优先 setsid
#   3) pid 以子进程自己写的 pid 文件为准，不依赖 $!（setsid 下 $! 是中间进程）
_detach(){
    local cur
    while IFS= read -r cur; do
        case "$cur" in "0::/") return 0 ;; esac
    done < /proc/$$/cgroup 2>/dev/null
    echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null && return 0
    return 1
}
_launch(){
    export PATH="/system/bin:/system/xbin:/sbin:/vendor/bin:$PATH"
    mkdir -p "$D" "$OBS" 2>/dev/null
    _detach
    if command -v setsid >/dev/null 2>&1; then
        setsid sh "$1" >/dev/null 2>&1 < /dev/null &
    else
        sh "$1" >/dev/null 2>&1 < /dev/null &
    fi
    echo "$(date '+%m-%d %H:%M:%S') launch $1" >> "$OBS/ctl.log" 2>/dev/null
}

do_status(){
    echo "=============================================================="
    echo "8elite限频 v1.4fix2"
    echo "=============================================================="

    local dp=""
    [ -f "$D/daemon.pid" ] && read -r dp < "$D/daemon.pid" 2>/dev/null
    [ -z "$dp" ] && [ -f "$OBS/daemon.pid" ] && read -r dp < "$OBS/daemon.pid" 2>/dev/null
    if [ -n "$dp" ] && [ -d "/proc/$dp" ]; then
        echo "守护进程: 运行中 (pid $dp)"
    else
        echo "守护进程: 未运行"
    fi

    if [ -f "$STATE" ]; then
        stf="$STATE"
    elif [ -f "$OBS/state" ]; then
        stf="$OBS/state"
    else
        stf=""
    fi
    if [ -n "$stf" ]; then
        echo
        echo "--- 实时 ---"
        while IFS='=' read -r k v; do
            case "$k" in
                scene)
                    case "$v" in
                        init)      echo "  状态: 初始化" ;;
                        disabled)  echo "  状态: 已关闭" ;;
                        off)       echo "  状态: 熄屏 → 交还官方" ;;
                        boot)      echo "  状态: 开机保护" ;;
                        charging)  echo "  状态: 充电 → 放开" ;;
                        panic)     echo "  状态: 过热 → 让路" ;;
                        rich_wait) echo "  状态: 升档待确认" ;;
                        boost)     echo "  状态: 需求逼近 → 升档" ;;
                        hold)      echo "  状态: 跟随中" ;;
                        save)      echo "  状态: 富余 → 降档省电" ;;
                        idle)      echo "  状态: 空闲 → 已落 748M 底板" ;;
                        rich)      echo "  状态: 需求富余" ;;
                        *)         echo "  状态: $v" ;;
                    esac ;;
                mode)      echo "  模式: $v" ;;
                style)     echo "  风格: $v" ;;
                fg)        echo "  前台: $v" ;;
                need_big)  echo "  需求频率: $(fmt_mhz $v)" ;;
                cap_big)   echo "  大核天花板: $(fmt_mhz $v)" ;;
                cap_prime) echo "  超大核天花板: $(fmt_mhz $v)" ;;
                sat_big)   echo "  撞顶率: $((v/10))%（满 ${v}‰）" ;;
                target)    echo "  目标占用: ${v}%" ;;
                power)     echo "  整机功耗: ${v} mW" ;;
                temp)      echo "  温度: $(fmt_temp $v)" ;;
            esac
        done < "$stf"
    fi

    echo
    echo "--- 实测 ---"
    echo "  大核:   $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null) kHz"
    echo "  超大核: $(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq 2>/dev/null) kHz"
    echo "  cooling: cd3=$(cat $CD_B 2>/dev/null) cd4=$(cat $CD_P 2>/dev/null)"
    echo
    echo "--- 配置 ---"
    grep -vE '^\s*#|^\s*$' "$CFG" 2>/dev/null | sed 's/^/  /'
}

# 清掉历史遗留的重复实例（V1.4 冻结 bug 会堆出一堆 daemon）
_reap_dupes(){
    local n=0 pid cmd keep="$1"
    for pid in /proc/[0-9]*; do
        pid="${pid#/proc/}"
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        [ "$pid" = "$keep" ] && continue
        [ -r "/proc/$pid/cmdline" ] || continue
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        case "$cmd" in
            "sh $D/daemon.sh "*) kill -9 "$pid" 2>/dev/null && n=$((n+1)) ;;
        esac
    done
    [ "$n" -gt 0 ] && echo "清理重复守护 ×$n" && \
        echo "$(date '+%m-%d %H:%M:%S') reap dupes x$n" >> "$OBS/ctl.log" 2>/dev/null
}

do_start(){
    local p=""
    [ -f "$D/daemon.pid" ] && read -r p < "$D/daemon.pid" 2>/dev/null
    [ -z "$p" ] && [ -f "$OBS/daemon.pid" ] && read -r p < "$OBS/daemon.pid" 2>/dev/null
    if [ -n "$p" ] && [ -d "/proc/$p" ] && ! grep -q do_freezer_trap "/proc/$p/wchan" 2>/dev/null; then
        _reap_dupes "$p"
        echo "已在运行 pid=$p"
        return 0
    fi
    # 旧 pid 存在但被冻结：解冻而不是新拉一个
    if [ -n "$p" ] && [ -d "/proc/$p" ]; then
        echo "$p" > /sys/fs/cgroup/cgroup.procs 2>/dev/null && {
            echo "守护曾被冻结，已解冻 pid=$p"
            sleep 1
            do_status
            return 0
        }
        kill -9 "$p" 2>/dev/null
    fi
    mkdir -p "$OBS" 2>/dev/null
    rm -f "$D/daemon.lock" 2>/dev/null
    _reap_dupes ""
    _launch "$D/daemon.sh"
    sleep 3

    # 看门狗（pid 由看门狗自己写，见 watchdog.sh）
    p=""
    [ -f "$D/watchdog.pid" ] && read -r p < "$D/watchdog.pid" 2>/dev/null
    [ -z "$p" ] && [ -f "$OBS/watchdog.pid" ] && read -r p < "$OBS/watchdog.pid" 2>/dev/null
    if [ -z "$p" ] || [ ! -d "/proc/$p" ] || grep -q do_freezer_trap "/proc/$p/wchan" 2>/dev/null; then
        _launch "$D/watchdog.sh"
        sleep 2
    fi
    do_status
}

do_stop(){
    local p=""
    [ -f "$OBS/watchdog.pid" ] && read -r p < "$OBS/watchdog.pid" 2>/dev/null
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null

    p=""
    [ -f "$D/daemon.pid" ] && read -r p < "$D/daemon.pid" 2>/dev/null
    [ -z "$p" ] && [ -f "$OBS/daemon.pid" ] && read -r p < "$OBS/daemon.pid" 2>/dev/null
    if [ -n "$p" ] && [ -d "/proc/$p" ]; then
        kill -TERM "$p" 2>/dev/null
        sleep 2
        [ -d "/proc/$p" ] && kill -9 "$p" 2>/dev/null
    fi
    echo 0 > "$CD_B" 2>/dev/null
    echo 0 > "$CD_P" 2>/dev/null
    rm -f "$OBS/daemon.lock"
    echo "已停止，限制已归还"
}

do_mode(){
    local m="$1"
    case "$m" in
        auto|learn)
            mkdir -p "$(dirname "$CFG")" 2>/dev/null
            if [ -f "$CFG" ]; then
                if grep -q '^mode=' "$CFG"; then
                    sed -i "s/^mode=.*/mode=$m/" "$CFG"
                else
                    echo "mode=$m" >> "$CFG"
                fi
            else
                printf 'mode=%s\nenabled=1\nstyle=eco\n' "$m" > "$CFG"
            fi
            echo "已切换到 $m"
            [ "$m" = "learn" ] && { echo 0 > "$CD_B" 2>/dev/null; echo 0 > "$CD_P" 2>/dev/null; echo "（已归还）"; }
            ;;
        *) echo "用法: sh ctl.sh mode <auto|learn>" ;;
    esac
}

do_release(){
    echo 0 > "$CD_B" 2>/dev/null
    echo 0 > "$CD_P" 2>/dev/null
    chmod 644 /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null
    chmod 644 /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq 2>/dev/null
    echo "已归还全部限制"
    echo "  大核:   $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null)"
    echo "  超大核: $(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq 2>/dev/null)"
}

case "$1" in
    status)  do_status ;;
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 1; do_start ;;
    mode)    do_mode "$2" ;;
    release) do_release ;;
    log)     tail -n "${2:-20}" "$OBS/daemon.log" 2>/dev/null ;;
    *)
        echo "8elite限频 v1.4fix2"
        echo ""
        echo "  status   查看状态"
        echo "  start    启动"
        echo "  stop     停止并归还"
        echo "  restart  重启"
        echo "  mode auto|learn  启用/关闭"
        echo "  release  强制归还"
        echo "  log      日志"
        ;;
esac
