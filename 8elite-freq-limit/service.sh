#!/system/bin/sh
MODDIR="${0%/*}"
DATA=/data/adb/eta_sched
BASE=/storage/emulated/0/Android/8elite

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 90 ]; do sleep 2; i=$((i+1)); done
i=0
while [ ! -d /storage/emulated/0/Android ] && [ $i -lt 60 ]; do sleep 2; i=$((i+1)); done
sleep 12

mkdir -p "$DATA" "$BASE/obs" 2>/dev/null

# 自愈
for f in daemon.sh ctl.sh watchdog.sh; do
    [ -f "$DATA/$f" ] || cp -f "$MODDIR/scripts/$f" "$DATA/" 2>/dev/null
done
chmod 755 "$DATA"/*.sh 2>/dev/null

[ -f "$BASE/config.conf" ] || printf 'mode=auto\nenabled=1\nstyle=eco\n' > "$BASE/config.conf"

sh "$DATA/ctl.sh" start 2>/dev/null
