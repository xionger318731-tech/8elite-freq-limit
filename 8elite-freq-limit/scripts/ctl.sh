#!/system/bin/sh
# ============================================================
# 8elite限频 控制脚本 v1.0
#   status  状态   start  启动   stop  停止
#   mode    切换   release 归还  log   日志
# ============================================================

D=/data/adb/eta_sched
OBS=/storage/emulated/0/Android/8elite/obs
CFG=/storage/emulated/0/Android/8elite/config.conf
CD_B=/sys/class/thermal/cooling_device3/cur_state
CD_P=/sys/class/thermal/cooling_device4/cur_state

do_status(){
    echo "=============================================================="
    echo "8elite限频 v1.0"
    echo "=============================================================="

    local dp=""
    [ -f "$OBS/daemon.pid" ] && read -r dp < "$OBS/daemon.pid" 2>/dev/null
    if [ -n "$dp" ] && [ -d "/proc/$dp" ]; then
        echo "守护进程: 运行中 (pid $dp)"
    else
        echo "守护进程: 未运行"
    fi

    if [ -f "$OBS/state" ]; then
        echo
        echo "--- 实时 ---"
        while IFS='=' read -r k v; do
            case "$k" in
                scene)
                    case "$v" in
                        idle)     echo "  状态: 静止 → 锁最低频" ;;
                        boost)    echo "  状态: 需求逼近 → 升档" ;;
                        rich)     echo "  状态: 需求富余 → 降档" ;;
                        hold)     echo "  状态: 跟随中" ;;
                        launch)   echo "  状态: 应用启动 → 锁 2.4G" ;;
                        game)     echo "  状态: 游戏 → 不干预" ;;
                        off)      echo "  状态: 熄屏 → 交还官方" ;;
                        hot)      echo "  状态: 过热 → 交还官方" ;;
                        boot)     echo "  状态: 开机保护" ;;
                        disabled) echo "  状态: 已关闭" ;;
                        *)        echo "  状态: $v" ;;
                    esac ;;
                style)    echo "  风格: $v" ;;
                fg)       echo "  前台: $v" ;;
                eff_big)  echo "  需求: $v kHz" ;;
                cap_big)  echo "  大核天花板: $v kHz" ;;
                cap_prime) echo "  超核天花板: $v kHz" ;;
                ratio_big) echo "  占比: $v%" ;;
                temp_big) echo "  温度: $v" ;;
            esac
        done < "$OBS/state"
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

do_start(){
    local p=""
    [ -f "$OBS/daemon.pid" ] && read -r p < "$OBS/daemon.pid" 2>/dev/null
    if [ -n "$p" ] && [ -d "/proc/$p" ]; then
        echo "已在运行 pid=$p"
        return 0
    fi
    mkdir -p "$OBS" 2>/dev/null
    rm -f "$OBS/daemon.lock"
    setsid sh "$D/daemon.sh" >/dev/null 2>&1 < /dev/null &
    sleep 3

    # 看门狗
    p=""
    [ -f "$OBS/watchdog.pid" ] && read -r p < "$OBS/watchdog.pid" 2>/dev/null
    if [ -z "$p" ] || [ ! -d "/proc/$p" ]; then
        setsid sh "$D/watchdog.sh" >/dev/null 2>&1 < /dev/null &
        echo $! > "$OBS/watchdog.pid" 2>/dev/null
    fi
    do_status
}

do_stop(){
    local p=""
    [ -f "$OBS/watchdog.pid" ] && read -r p < "$OBS/watchdog.pid" 2>/dev/null
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null

    p=""
    [ -f "$OBS/daemon.pid" ] && read -r p < "$OBS/daemon.pid" 2>/dev/null
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
        echo "8elite限频 v1.0"
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
