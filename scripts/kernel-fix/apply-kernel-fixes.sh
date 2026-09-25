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

  # ---- 修复 3: fs/stat.c 缺失的 ksu_handle_newfstat_ret hook ----
  # manual_hook_check.mk 强制要求, 源码树集成时遗漏了这一处。
  # 按 ReSukiSU 官方文档(resukisu.github.io/guide/manual-integrate.html):
  #   声明加在 ksu_handle_stat 声明之后,
  #   调用加在 SYSCALL_DEFINE2(newfstat,...) 的 cp_new_stat 之后、return 之前。
  STAT_C="$KERNEL_DIR/fs/stat.c"
  if [ ! -f "$STAT_C" ]; then
    log "[ksu] 未找到 fs/stat.c, 跳过"
  else
    python3 - "$STAT_C" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8", errors="surrogateescape").read()
changed = []

# ---- hook 1: ksu_handle_newfstat_ret (SYSCALL_DEFINE2(newfstat) 返回值) ----
if "ksu_handle_newfstat_ret" not in src:
    decl_anchor = "extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);"
    assert src.count(decl_anchor) == 1, "stat.c 声明锚点异常"
    src = src.replace(decl_anchor, decl_anchor +
        "\nextern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);", 1)

    func_anchor = "SYSCALL_DEFINE2(newfstat, unsigned int, fd, struct stat __user *, statbuf)"
    assert src.count(func_anchor) == 1, "stat.c newfstat 锚点异常"
    head, rest = src.split(func_anchor, 1)
    ret_anchor = "\n\treturn error;\n}"
    assert ret_anchor in rest, "stat.c newfstat return 锚点缺失"
    rest = rest.replace(ret_anchor,
        "\n#ifdef CONFIG_KSU_MANUAL_HOOK"
        "\n\tksu_handle_newfstat_ret(&fd, &statbuf);"
        "\n#endif" + ret_anchor, 1)
    src = head + func_anchor + rest
    changed.append("ksu_handle_newfstat_ret")

# ---- hook 2: ksu_handle_fstat64_ret (SYSCALL_DEFINE2(fstat64) 返回值, 32 位 su) ----
if "ksu_handle_fstat64_ret" not in src:
    decl_anchor2 = "extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);"
    assert src.count(decl_anchor2) == 1, "stat.c 声明锚点2异常"
    src = src.replace(decl_anchor2, decl_anchor2 +
        "\n#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)"
        "\nextern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);"
        "\n#endif", 1)

    func_anchor2 = "SYSCALL_DEFINE2(fstat64, unsigned long, fd, struct stat64 __user *, statbuf)"
    assert src.count(func_anchor2) == 1, "stat.c fstat64 锚点异常"
    head2, rest2 = src.split(func_anchor2, 1)
    ret2_anchor = "\n\t\terror = cp_new_stat64(&stat, statbuf);\n\n\treturn error;"
    assert ret2_anchor in rest2, "stat.c fstat64 return 锚点缺失"
    rest2 = rest2.replace(ret2_anchor,
        "\n\t\terror = cp_new_stat64(&stat, statbuf);"
        "\n\n#ifdef CONFIG_KSU_MANUAL_HOOK"
        "\n\tksu_handle_fstat64_ret(&fd, &statbuf);"
        "\n#endif\n\treturn error;", 1)
    src = head2 + func_anchor2 + rest2
    changed.append("ksu_handle_fstat64_ret")

if changed:
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(src)
    print("inserted: " + ", ".join(changed))
else:
    print("already integrated")
PYEOF
    grep -q "ksu_handle_newfstat_ret" "$STAT_C" \
      && grep -q "ksu_handle_fstat64_ret" "$STAT_C" \
      || { echo "错误: fs/stat.c hook 插入失败" >&2; exit 1; }
    log "[ksu] fs/stat.c 的 newfstat_ret/fstat64_ret hook 已就位"
  fi
fi
