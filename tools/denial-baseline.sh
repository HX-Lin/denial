#!/bin/sh
# Denial 基线采集：在 Denial 会话内的终端里运行
#   tools/denial-baseline.sh            全部场景
#   tools/denial-baseline.sh --quick    只测空闲 + 窗口开关
# 结果写到 ~/denial-baseline.txt（同时打印）
set -u
OUT="$HOME/denial-baseline.txt"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

PID=$(pgrep -n -x deniald 2>/dev/null || true)
if [ -z "$PID" ]; then
  echo "deniald 未运行 —— 请在 Denial 会话里执行"; exit 1
fi

rss()  { awk '/VmRSS/{printf "%.0f", $2/1024}' "/proc/$PID/status" 2>/dev/null; }
vram() {
  awk '/^drm-total-/ { s += strtonum($2) } END { printf "%.0f", s/1048576 }' \
      /proc/$PID/fdinfo/* 2>/dev/null
}
ticks() { awk '{print $14+$15}' "/proc/$PID/stat" 2>/dev/null; }

sample() { # $1 秒数 -> 输出 "RSS VRAM CPU%"
  t0=$(ticks); a0=$(rss); v0=$(vram)
  sleep "$1"
  t1=$(ticks); a1=$(rss); v1=$(vram)
  hz=$(getconf CLK_TCK)
  cpu=$(awk -v d="$((t1-t0))" -v s="$1" -v h="$hz" 'BEGIN{printf "%.1f",(d/h)/s*100}')
  echo "$a1 $v1 $cpu"
}

log() { echo "$@" | tee -a "$OUT"; }

: > "$OUT"
log "# Denial 基线 $(date -Is)"
log "deniald pid=$PID"
log "kernel=$(uname -r)  driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)"
log "gpu_mem_total=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -n1) MiB"
log "outputs:"
denialctl outputs 2>/dev/null | sed 's/^/  /' | tee -a "$OUT"
log ""
log "场景                        RSS(MB)  VRAM(MB)  CPU(%)"
log "-----------------------------------------------------"

idle=$(sample 10);               set -- $idle;  log "$(printf '%-24s %8s %9s %7s' '空桌面待机' "$1" "$2" "$3")"

# 窗口开关：10 次
before=$(vram); beforer=$(rss)
if command -v kitty >/dev/null 2>&1; then
  i=1
  while [ "$i" -le 10 ]; do
    kitty --title "probe-$i" >/dev/null 2>&1 &
    sleep 0.4
    pkill -f "title probe-$i" 2>/dev/null
    sleep 0.4
    i=$((i+1))
  done
  sleep 2
  after=$(vram); afterr=$(rss)
  log "$(printf '%-24s %8s %9s %7s' '开关窗口×10后' "$afterr" "$after" '-')"
  log "  VRAM 变化: ${before} -> ${after} MB（增长 $((after-before)) MB）"
  log "  RSS  变化: ${beforer} -> ${afterr} MB（增长 $((afterr-beforer)) MB）"
else
  log "  （未找到 kitty，跳过窗口开关测试）"
fi

if [ "$QUICK" -eq 0 ]; then
  log ""
  printf "打开概览（Overview）后按回车…"; read -r _
  ov=$(sample 10); set -- $ov; log "$(printf '%-24s %8s %9s %7s' '概览打开' "$1" "$2" "$3")"
  printf "关闭概览后按回车…"; read -r _
  co=$(sample 10); set -- $co; log "$(printf '%-24s %8s %9s %7s' '概览关闭后' "$1" "$2" "$3")"
fi

log ""
log "denialctl --json status:"
denialctl --json status 2>/dev/null | tee -a "$OUT" | head -n 20
log ""
log "# 完成：$OUT"
