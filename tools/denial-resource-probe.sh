#!/bin/sh
# Denial 资源探针：RSS / VRAM / 空闲 CPU / 帧数
#   tools/denial-resource-probe.sh [采样秒数]
set -u
SECS="${1:-10}"

PID=$(pgrep -n -x deniald 2>/dev/null || true)
if [ -z "$PID" ]; then
  echo "deniald 未运行（需要在 Denial 会话里执行）"; exit 1
fi

rss() { awk '/VmRSS/{printf "%.0f", $2/1024}' "/proc/$PID/status" 2>/dev/null; }

vram() {
  # 文档口径：drm-total-system0（NVIDIA/AMD/Intel 命名可能不同，全部累加）
  awk '
    /^drm-total-/ { split($1,k,"-"); name=k[3]; if (name ~ /^(system|vram|gtt|memory)/) s+=strtonum($2) }
    END { printf "%.0f", s/1048576 }
  ' /proc/$PID/fdinfo/* 2>/dev/null
}

cpu_ticks() { awk '{print $14+$15}' "/proc/$PID/stat" 2>/dev/null; }

T0=$(cpu_ticks); A0=$(rss); V0=$(vram)
sleep "$SECS"
T1=$(cpu_ticks); A1=$(rss); V1=$(vram)

HZ=$(getconf CLK_TCK)
CPU=$(awk -v d="$((T1-T0))" -v s="$SECS" -v h="$HZ" 'BEGIN{printf "%.1f", (d/h)/s*100}')

echo "deniald pid=$PID"
echo "  RSS        ${A1} MB"
echo "  VRAM       ${V1} MB   (fdinfo drm-total-*，基线 ${V0} MB)"
echo "  空闲 CPU   ${CPU}%     (${SECS}s 平均)"
