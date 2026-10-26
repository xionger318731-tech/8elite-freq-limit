#!/system/bin/sh
command -v ui_print >/dev/null 2>&1 || ui_print(){ echo "$@"; }

DATA=/data/adb/eta_sched
BASE=/storage/emulated/0/Android/8elite

ui_print "*******************************"
ui_print "  8elite限频  V1.0"
ui_print "  作者：罗霄山"
ui_print "*******************************"

ui_print "- 部署"
mkdir -p "$DATA/config" "$BASE/obs"
cp -f "$MODPATH/scripts/"*.sh "$DATA/" 2>/dev/null
cp -f "$MODPATH/config/"*.conf "$DATA/config/" 2>/dev/null
cp -f "$MODPATH/config/games.list" "$DATA/config/" 2>/dev/null
chmod 755 "$DATA"/*.sh 2>/dev/null

[ -f "$BASE/config.conf" ] || printf 'mode=auto\nenabled=1\nstyle=eco\n' > "$BASE/config.conf"

ui_print "- 启动"
sh "$DATA/ctl.sh" start 2>/dev/null

ui_print ""
ui_print "安装完成"
ui_print "  静止锁 748MHz，需求高时自动抬到官方上限"
ui_print "  冷启动锁 2.4G（无损点）"
ui_print "  打开 WebUI 可切换省电/均衡/流畅"
ui_print ""
