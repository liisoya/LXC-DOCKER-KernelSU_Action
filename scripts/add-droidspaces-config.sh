#!/usr/bin/env bash
# 幂等写入 Droidspaces 非 GKI 内核配置到设备 defconfig
# 来源: Kernel-Configuration.md「配置非 GKI 内核（旧版内核）」步骤 1 / 步骤 2
#
# 用法: add-droidspaces-config.sh <defconfig路径> [ENABLE_UFW_FAIL2BAN: true|false]
set -euo pipefail

DEFCONFIG="${1:?用法: $0 <defconfig路径> [ENABLE_UFW_FAIL2BAN]}"
ENABLE_UFW_FAIL2BAN="${2:-false}"

if [ ! -f "$DEFCONFIG" ]; then
  echo "错误: defconfig 不存在: $DEFCONFIG" >&2
  exit 1
fi

# 删除同名行（含 "# CONFIG_xxx is not set" 注释形式）后追加，保证幂等
set_opt() {
  local key="$1" val="$2"
  sed -i "/^\(# \)\?${key}[= ]/d" "$DEFCONFIG"
  printf '%s=%s\n' "$key" "$val" >> "$DEFCONFIG"
}

set_disabled() {
  local key="$1"
  sed -i "/^\(# \)\?${key}[= ]/d" "$DEFCONFIG"
  printf '# %s is not set\n' "$key" >> "$DEFCONFIG"
}

echo "==> 写入 Droidspaces 基础配置（步骤 1）到 $DEFCONFIG"

# IPC 机制
set_opt CONFIG_SYSCTL y
set_opt CONFIG_SYSVIPC y
set_opt CONFIG_POSIX_MQUEUE y

# 核心命名空间支持
set_opt CONFIG_NAMESPACES y
set_opt CONFIG_PID_NS y
set_opt CONFIG_UTS_NS y
set_opt CONFIG_IPC_NS y

# Seccomp 支持
set_opt CONFIG_SECCOMP y
set_opt CONFIG_SECCOMP_FILTER y

# 控制组支持
set_opt CONFIG_CGROUPS y
set_opt CONFIG_CGROUP_DEVICE y
set_opt CONFIG_CGROUP_PIDS y
# 注意: 不启用 CONFIG_MEMCG!
# 原因: Sukisu 分支 mm/vmscan.c 含未完成的 shrinker rwsem->rwlock 优化补丁,
# MEMCG_KMEM=y 时会引用不存在的 shrinker_rwsem 导致编译失败。
# MEMCG 仅影响 Docker 内存限额(docker -m), Droidspaces 需求检查不依赖它,
# 原始 wayne-perf_defconfig 也未启用, 与原内核行为保持一致。
set_disabled CONFIG_MEMCG
set_disabled CONFIG_MEMCG_KMEM
set_opt CONFIG_CGROUP_SCHED y
set_opt CONFIG_FAIR_GROUP_SCHED y
set_opt CONFIG_CGROUP_FREEZER y
set_opt CONFIG_CGROUP_NET_PRIO y

# 设备文件系统支持
set_opt CONFIG_DEVTMPFS y

# Overlay 文件系统支持（易失模式必需）
set_opt CONFIG_OVERLAY_FS y

# tmpfs 上的 xattr、posix acl 支持（NixOS 支持）
set_opt CONFIG_TMPFS_POSIX_ACL y
set_opt CONFIG_TMPFS_XATTR y

# 固件加载支持
set_opt CONFIG_FW_LOADER y
set_opt CONFIG_FW_LOADER_USER_HELPER y
set_opt CONFIG_FW_LOADER_COMPRESS y

# Droidspaces 网络隔离支持 - NAT/None 模式
set_opt CONFIG_NET_NS y
set_opt CONFIG_VETH y
set_opt CONFIG_BRIDGE y
set_opt CONFIG_NETFILTER y
set_opt CONFIG_BRIDGE_NETFILTER y
set_opt CONFIG_NETFILTER_ADVANCED y
set_opt CONFIG_NF_CONNTRACK y
set_opt CONFIG_IP_NF_IPTABLES y
set_opt CONFIG_IP_NF_FILTER y
set_opt CONFIG_NF_NAT y
set_opt CONFIG_NF_TABLES y
set_opt CONFIG_IP_NF_TARGET_MASQUERADE y
set_opt CONFIG_NETFILTER_XT_TARGET_MASQUERADE y
set_opt CONFIG_NETFILTER_XT_TARGET_TCPMSS y
set_opt CONFIG_NETFILTER_XT_MATCH_ADDRTYPE y
set_opt CONFIG_NF_CONNTRACK_NETLINK y
set_opt CONFIG_NF_NAT_REDIRECT y
set_opt CONFIG_IP_ADVANCED_ROUTER y
set_opt CONFIG_IP_MULTIPLE_TABLES y

# 旧版兼容（4.19 仍使用 IPv4 后缀符号）
set_opt CONFIG_NF_CONNTRACK_IPV4 y
set_opt CONFIG_NF_NAT_IPV4 y
set_opt CONFIG_IP_NF_NAT y

# 在旧内核上禁用此选项以使互联网正常工作
set_disabled CONFIG_ANDROID_PARANOID_NETWORK

if [ "$ENABLE_UFW_FAIL2BAN" = "true" ]; then
  echo "==> 追加 UFW/Fail2ban 可选配置（步骤 2）"
  set_opt CONFIG_NETFILTER_XT_MATCH_COMMENT y
  set_opt CONFIG_NETFILTER_XT_MATCH_STATE y
  set_opt CONFIG_NETFILTER_XT_MATCH_CONNTRACK y
  set_opt CONFIG_NETFILTER_XT_MATCH_MULTIPORT y
  set_opt CONFIG_NETFILTER_XT_MATCH_HL y
  set_opt CONFIG_NETFILTER_XT_TARGET_REJECT y
  set_opt CONFIG_IP_NF_TARGET_REJECT y
  set_opt CONFIG_NETFILTER_XT_TARGET_LOG y
  set_opt CONFIG_IP_NF_TARGET_ULOG y
  set_opt CONFIG_NETFILTER_XT_MATCH_RECENT y
  set_opt CONFIG_NETFILTER_XT_MATCH_LIMIT y
  set_opt CONFIG_NETFILTER_XT_MATCH_HASHLIMIT y
  set_opt CONFIG_NETFILTER_XT_MATCH_OWNER y
  set_opt CONFIG_NETFILTER_XT_MATCH_PKTTYPE y
  set_opt CONFIG_NETFILTER_XT_MATCH_MARK y
  set_opt CONFIG_NETFILTER_XT_TARGET_MARK y
  set_opt CONFIG_IP_SET y
  set_opt CONFIG_IP_SET_HASH_IP y
  set_opt CONFIG_IP_SET_HASH_NET y
  set_opt CONFIG_NETFILTER_XT_SET y
  set_opt CONFIG_NETFILTER_NETLINK_QUEUE y
  set_opt CONFIG_NETFILTER_NETLINK_LOG y
  set_opt CONFIG_NETFILTER_XT_TARGET_NFLOG y
else
  echo "==> 跳过 UFW/Fail2ban 可选配置（ENABLE_UFW_FAIL2BAN != true）"
fi

echo "==> Droidspaces 配置写入完成"
