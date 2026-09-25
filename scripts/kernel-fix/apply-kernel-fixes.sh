#!/usr/bin/env bash
# 针对本源码树(Sukisu 分支)的定点修复, 在克隆后、生成 .config 前执行
# 1) 补回 net/bridge/br_private.h 被误删的 nf_call_* 成员
#    (CONFIG_BRIDGE_NETFILTER=y 时 br_netlink.c/br_netfilter_hooks.c 引用它们)
# 2) ReSukiSU 非 GKI 内核必须使用 manual hook 模式
#    (默认的 tracepoint hook 仅支持 GKI 2.0, Kbuild 会直接报错)
set -euo pipefail

KERNEL_DIR="${1:?用法: $0 <内核源码目录> <defconfig路径>}"
DEFCONFIG="${2:-}"

log() { echo "==> $*"; }

# ---- 修复 1: br_private.h nf_call_* 成员 ----
BR_H="$KERNEL_DIR/net/bridge/br_private.h"
if [ ! -f "$BR_H" ]; then
  log "[bridge] 未找到 br_private.h, 跳过"
elif grep -q "nf_call_iptables" "$BR_H"; then
  log "[bridge] nf_call_* 成员已存在, 跳过"
else
  # 在 CONFIG_BRIDGE_NETFILTER 守卫内的 metrics[RTAX_MAX]; 行后补回 3 个成员
  if grep -q 'metrics\[RTAX_MAX\];' "$BR_H"; then
    sed -i '/u32[[:space:]]*metrics\[RTAX_MAX\];/a\
\tbool\t\t\t\tnf_call_iptables;\
\tbool\t\t\t\tnf_call_ip6tables;\
\tbool\t\t\t\tnf_call_arptables;' "$BR_H"
    grep -q "nf_call_arptables" "$BR_H" \
      || { echo "错误: br_private.h 成员插入失败" >&2; exit 1; }
    log "[bridge] 已补回 nf_call_iptables/ip6tables/arptables 成员"
  else
    echo "错误: br_private.h 中未找到 metrics[RTAX_MAX] 锚点" >&2
    exit 1
  fi
fi

# ---- 修复 2: ReSukiSU manual hook (非 GKI 必须) ----
KSU_DIR="$KERNEL_DIR/drivers/kernelsu"
if [ ! -d "$KSU_DIR" ]; then
  log "[ksu] 未找到 drivers/kernelsu, 跳过"
else
  log "[ksu] 检测到 ReSukiSU, 启用 CONFIG_KSU_MANUAL_HOOK (非 GKI 必须)"
  if [ -n "$DEFCONFIG" ] && [ -f "$DEFCONFIG" ]; then
    sed -i "/^\(# \)\?CONFIG_KSU_MANUAL_HOOK[= ]/d" "$DEFCONFIG"
    echo "CONFIG_KSU_MANUAL_HOOK=y" >> "$DEFCONFIG"
    log "[ksu] 已写入 CONFIG_KSU_MANUAL_HOOK=y 到 defconfig"
  else
    echo "错误: 未提供 defconfig 路径, 无法启用 manual hook" >&2
    exit 1
  fi
fi
