#!/usr/bin/env bash
# 幂等且"保证打上"的 Droidspaces 非 GKI 补丁应用脚本
#
# 对 patches/ 下的每个补丁按三层策略处理：
#   1) 检测目标代码已存在（源码已打过补丁/已含等价修改）-> 跳过
#   2) patch -p1 --forward 常规应用
#   3) 上下文漂移导致失败 -> 按补丁的确定内容做定点插入/替换（兜底，必定成功）
#
# 用法: apply-droidspaces-patches.sh <内核源码目录> <补丁目录>
set -euo pipefail

KERNEL_DIR="${1:?用法: $0 <内核源码目录> <补丁目录>}"
PATCH_DIR="${2:?用法: $0 <内核源码目录> <补丁目录>}"

# 转为绝对路径，避免脚本内部 cd 后相对路径失效
KERNEL_DIR="$(cd "$KERNEL_DIR" && pwd)"
PATCH_DIR="$(cd "$PATCH_DIR" && pwd)"

QTAGUID_REL="net/netfilter/xt_qtaguid.c"
CGROUP_REL="kernel/cgroup/cgroup.c"

log() { echo "==> $*"; }
die() { echo "错误: $*" >&2; exit 1; }

# ---------------------------------------------------------------- 补丁 01
# xt_qtaguid 内核 panic 修复
apply_patch_01() {
  local f="$KERNEL_DIR/$QTAGUID_REL"
  if [ ! -f "$f" ]; then
    log "[补丁01] 源码无 $QTAGUID_REL，跳过（本源码树不含 qtaguid）"
    return 0
  fi

  # 已修复的特征: 不再调用 dev_get_stats(iface_entry->net_dev, ...)
  if ! grep -q 'dev_get_stats(iface_entry->net_dev' "$f"; then
    log "[补丁01] 已应用（未检测到旧代码），跳过"
    return 0
  fi

  log "[补丁01] 检测到旧代码，尝试 patch -p1 --forward"
  if (cd "$KERNEL_DIR" && patch -p1 --forward --silent \
        < "$PATCH_DIR/01.fix_kernel_panic_in_xt_qtaguid.patch" >/dev/null 2>&1); then
    log "[补丁01] patch 应用成功"
    return 0
  fi

  log "[补丁01] patch 失败（上下文漂移），使用定点替换兜底"
  python3 - "$f" <<'PYEOF'
import re, sys

path = sys.argv[1]
src = open(path, encoding="utf-8", errors="surrogateescape").read()

# 替换 1: 去掉栈上 dev_stats 变量
new = src.replace(
    "struct rtnl_link_stats64 dev_stats, *stats;",
    "struct rtnl_link_stats64 *stats;", 1)

# 替换 2: 删除 active 分支判断, 恒用 no_dev_stats
pattern = re.compile(
    r"\tif \(iface_entry->active\) \{\n"
    r"\t\tstats = dev_get_stats\(iface_entry->net_dev,\n"
    r"\s*&dev_stats\);\n"
    r"\t\} else \{\n"
    r"\t\tstats = &no_dev_stats;\n"
    r"\t\}")
new, n = pattern.subn("\tstats = &no_dev_stats;", new, count=1)

if n != 1 or new == src:
    sys.exit(1)
open(path, "w", encoding="utf-8", errors="surrogateescape").write(new)
PYEOF

  grep -q 'dev_get_stats(iface_entry->net_dev' "$f" && die "[补丁01] 兜底替换后仍检测到旧代码"
  log "[补丁01] 定点替换完成"
}

# ---------------------------------------------------------------- 补丁 02
# cgroup 文件前缀处理恢复（与 runcpatch 等价，二选一，不能重复打）
apply_patch_02() {
  local f="$KERNEL_DIR/$CGROUP_REL"
  [ -f "$f" ] || die "[补丁02] 源码无 $CGROUP_REL，请检查源码树"

  # 已应用的特征: cgroup_add_file 中存在 NOPREFIX 前缀链接逻辑
  # (同时覆盖官方补丁与 runcpatch.sh 两种等价实现)
  if grep -q 'CGRP_ROOT_NOPREFIX) && !(cft->flags & CFTYPE_NO_PREFIX)' "$f"; then
    log "[补丁02] 已应用（检测到等价代码，含 runcpatch 情况），跳过"
    return 0
  fi

  log "[补丁02] 未检测到目标代码，尝试 patch -p1 --forward"
  if (cd "$KERNEL_DIR" && patch -p1 --forward --silent \
        < "$PATCH_DIR/02.fix_restore_cgroup_file_prefix_handling.patch" >/dev/null 2>&1); then
    log "[补丁02] patch 应用成功"
    return 0
  fi

  log "[补丁02] patch 失败（上下文漂移），使用定点插入兜底"
  python3 - "$f" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8", errors="surrogateescape").read()

block = (
    "\tif (cft->ss && (cgrp->root->flags & CGRP_ROOT_NOPREFIX) && "
    "!(cft->flags & CFTYPE_NO_PREFIX)) {\n"
    "\t\t\t\tsnprintf(name, CGROUP_FILE_NAME_MAX, \"%s.%s\", "
    "cft->ss->name, cft->name);\n"
    "\t\t\t\tkernfs_create_link(cgrp->kn, name, kn);\n"
    "\t}\n"
    "\n"
)

# 锚点: cgroup_add_file 尾部的 return 0（补丁上下文锚定的唯一序列）
anchor = "\t\tspin_unlock_irq(&cgroup_file_kn_lock);\n\t}\n\n\treturn 0;"
if src.count(anchor) != 1:
    sys.exit(1)
src = src.replace(anchor, "\t\tspin_unlock_irq(&cgroup_file_kn_lock);\n\t}\n\n" + block + "\treturn 0;", 1)
open(path, "w", encoding="utf-8", errors="surrogateescape").write(src)
PYEOF

  grep -q 'CGRP_ROOT_NOPREFIX) && !(cft->flags & CFTYPE_NO_PREFIX)' "$f" \
    || die "[补丁02] 兜底插入后未检测到目标代码"
  log "[补丁02] 定点插入完成"
}

apply_patch_01
apply_patch_02
log "全部补丁处理完成"
