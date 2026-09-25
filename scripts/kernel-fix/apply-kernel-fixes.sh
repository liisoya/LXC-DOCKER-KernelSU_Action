#!/usr/bin/env bash
# 针对本源码树(LKGeek_sdm660 各分支通用)的定点修复, 在克隆后、生成 .config 前执行
# 累积经验清单(全部幂等, 按需自动跳过):
#   0) 启用 pstore ramoops, 失败时可在 TWRP 抓取内核 panic 日志
#   1) 补回 net/bridge/br_private.h 被误删的 nf_call_* 成员
#   2) KSU: 非 GKI 必须 manual hook; ENABLE_KSU=false 时整体禁用 KSU(用于隔离测试)
#   3) fs/stat.c 补齐 newfstat_ret/fstat64_ret hook(manual_hook_check 强制要求)
#   4) fs/stat.c 的 vfs_fstat 引用补 CONFIG_KSU_SUSFS 守卫
#   5) scripts/gcc-version.sh 修复由 workflow 单独步骤完成(上游 v4.19 原版覆盖)
#
# 用法: apply-kernel-fixes.sh <内核源码目录> <defconfig路径> [ENABLE_KSU: true|false]
set -euo pipefail

KERNEL_DIR="${1:?用法: $0 <内核源码目录> <defconfig路径> [ENABLE_KSU]}"
DEFCONFIG="${2:-}"
ENABLE_KSU="${3:-true}"

log() { echo "==> $*"; }

# 追加/清理 defconfig 中单个 CONFIG 选项(幂等)
set_opt() {
  local key="$1" val="$2"
  [ -n "$DEFCONFIG" ] && [ -f "$DEFCONFIG" ] || { echo "错误: defconfig 不可用" >&2; exit 1; }
  sed -i "/^\(# \)\?${key}[= ]/d" "$DEFCONFIG"
  printf '%s=%s\n' "$key" "$val" >> "$DEFCONFIG"
}

set_disabled() {
  local key="$1"
  [ -n "$DEFCONFIG" ] && [ -f "$DEFCONFIG" ] || { echo "错误: defconfig 不可用" >&2; exit 1; }
  sed -i "/^\(# \)\?${key}[= ]/d" "$DEFCONFIG"
  printf '# %s is not set\n' "$key" >> "$DEFCONFIG"
}

# ---- 修复 0: pstore ramoops(诊断用, 记录 panic 日志) ----
if [ -f "$KERNEL_DIR/fs/pstore/Kconfig" ] || [ -f "$KERNEL_DIR/fs/pstore/ram.c" ]; then
  set_opt CONFIG_PSTORE y
  set_opt CONFIG_PSTORE_RAM y
  log "[pstore] 已启用 CONFIG_PSTORE/CONFIG_PSTORE_RAM"
else
  log "[pstore] 源码无 pstore, 跳过"
fi

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

# ---- 修复 2/3/4: ReSukiSU 相关(ENABLE_KSU=false 时整体跳过并禁用 KSU) ----
KSU_DIR="$KERNEL_DIR/drivers/kernelsu"
if [ "$ENABLE_KSU" != "true" ]; then
  log "[ksu] ENABLE_KSU=false: 禁用 CONFIG_KSU(隔离测试模式, 无 root)"
  set_disabled CONFIG_KSU
  set_disabled CONFIG_KSU_MANUAL_HOOK
elif [ ! -d "$KSU_DIR" ]; then
  log "[ksu] 未找到 drivers/kernelsu(子模块未初始化?), 跳过 KSU 修复"
else
  log "[ksu] 检测到 ReSukiSU, 启用 CONFIG_KSU_MANUAL_HOOK (非 GKI 必须)"
  sed -i "/^\(# \)\?CONFIG_KSU_MANUAL_HOOK[= ]/d" "$DEFCONFIG"
  echo "CONFIG_KSU_MANUAL_HOOK=y" >> "$DEFCONFIG"
  log "[ksu] 已写入 CONFIG_KSU_MANUAL_HOOK=y 到 defconfig"

  # ---- 修复 3: fs/stat.c 缺失的 ksu_handle_newfstat_ret/fstat64_ret hook ----
  # manual_hook_check.mk 强制要求, 源码树集成时遗漏。
  # 按 ReSukiSU 官方文档(resukisu.github.io/guide/manual-integrate.html):
  #   声明加在 ksu_handle_stat 声明之后,
  #   调用分别加在 SYSCALL_DEFINE2(newfstat) / SYSCALL_DEFINE2(fstat64) 的
  #   cp_new_stat(64) 之后、return 之前, 受 CONFIG_KSU_MANUAL_HOOK 守卫。
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

  # ---- 修复 4: fs/stat.c 的 ksu_handle_vfs_fstat 引用缺守卫 ----
  # 定义在 KernelSU 内受 CONFIG_KSU_SUSFS 守卫, 而引用处未加守卫,
  # SUSFS=n 时链接报 undefined symbol。按定义方守卫包住引用。
  python3 - "$STAT_C" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8", errors="surrogateescape").read()

if "#ifdef CONFIG_KSU_SUSFS\nextern void ksu_handle_vfs_fstat" in src:
    print("vfs_fstat guard already present")
else:
    a1 = "extern void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr);"
    assert src.count(a1) == 1, "vfs_fstat 声明锚点异常"
    src = src.replace(a1,
        "#ifdef CONFIG_KSU_SUSFS\n" + a1 + "\n#endif", 1)
    a2 = "\t\tksu_handle_vfs_fstat(fd, &stat->size);"
    assert src.count(a2) == 1, "vfs_fstat 调用锚点异常"
    src = src.replace(a2,
        "#ifdef CONFIG_KSU_SUSFS\n" + a2 + "\n#endif", 1)
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(src)
    print("vfs_fstat guard added")
PYEOF
  log "[ksu] fs/stat.c 的 vfs_fstat 引用已加 SUSFS 守卫"
fi

log "全部定点修复完成"
