#!/usr/bin/env python3
# =============================================================================
# 把包名清单解析成「真正能传给 build-bootstraps.sh --add 的主包名」
# =============================================================================
#
# 为什么需要这个脚本
# ------------------
# `--add` 只接受 **主包目录名**（packages/xxx、root-packages/xxx ... 下真实存在的
# 目录）。但人写清单时脑子里想的是命令名或 dpkg 子包名：
#
#     clang  lld  llvm  libcompiler-rt  -> 都属于 libllvm 一个包
#     aapt2  -> aapt 的子包
#     xxd    -> vim 的子包
#     libltdl -> libtool 的子包
#
# 这些名字在仓库里都**找不到同名目录**，直接塞给 --add 会让 build-package.sh
# 在循环跑到它时才炸 —— 那时前面几十个包已经编完，白烧几十分钟 CI。
#
# 之前 preflight 的做法是「发现非法就 exit 1」，然后由人手工改清单。
# 这是错的：从子包名找到主包名是**纯机械、可完全判定**的映射，
# 不该占用人的注意力。
#
# 判定规则（零网络，只扫当前工作区）
# ----------------------------------
#   1. 名字能在 <root>-packages/<name> 找到           -> 已是主包，原样保留
#   2. 能扫到某个 <root>/<main>/<name>.subpackage.sh  -> 自动替换成 <main>
#   3. 都不满足                                        -> 报错，并给出最接近的主包名
#
# 第 2 条是整个脚本的价值所在：仓库里每个子包必然有对应的 .subpackage.sh，
# 文件名就是子包名，所在目录就是主包。这是仓库自带的权威映射，
# 比任何手工维护的对照表都可靠，而且新增子包时自动生效、永不过期。
#
# 用法
# ----
#   ./resolve-packages.py "clang,xxd,vim,aapt2"
#   echo "clang xxd" | ./resolve-packages.py -
#
# stdout  : 修正后的逗号分隔主包名（供 --add 直接使用）
# stderr  : 修正记录（::warning）与无法解析项（::error），GitHub 会显示为注解
# exit 0  : 全部解析成功
# exit 1  : 存在既非主包也非子包的名字（拼写错误等），需人看
# =============================================================================

import os
import re
import sys
import glob
import difflib

SUB_SUFFIX = ".subpackage.sh"
PKG_ROOTS = ("packages", "root-packages", "x11-packages", "science-packages")


def collect_mains():
    """所有主包目录名 -> 所在的 root 目录"""
    mains = {}
    roots = []
    for d in os.listdir("."):
        if os.path.isdir(d) and (d == "packages" or d.endswith("-packages")):
            roots.append(d)
    for root in roots:
        try:
            entries = os.listdir(root)
        except OSError:
            continue
        for name in entries:
            if os.path.isdir(os.path.join(root, name)):
                mains.setdefault(name, root)
    return mains


def collect_sub2main():
    """子包名 -> 主包名。来自每个 xxx.subpackage.sh 的所在目录。"""
    sub2main = {}
    for root in os.listdir("."):
        if not os.path.isdir(root):
            continue
        if not (root == "packages" or root.endswith("-packages")):
            continue
        for main_dir in glob.glob(os.path.join(root, "*")):
            if not os.path.isdir(main_dir):
                continue
            main = os.path.basename(main_dir)
            for f in glob.glob(os.path.join(main_dir, "*" + SUB_SUFFIX)):
                sub = os.path.basename(f)[:-len(SUB_SUFFIX)]
                if sub and sub not in sub2main:
                    sub2main[sub] = main
    return sub2main


def read_input(argv):
    if not argv:
        return ""
    if argv[0] == "-":
        return sys.stdin.read()
    return " ".join(argv)


def split_names(raw):
    # 输入可能是三种形态，这里统一处理，调用方不必先 sed：
    #   1. 逗号串            "libllvm,vim,nmap"
    #   2. 清单文件全文      每行一个包名，支持 # 注释（整行或行尾）
    #   3. 两者混排
    #
    # 之所以让本脚本自己剥注释，是因为之前注释剥离线写在 YAML 的 sed 里，
    # build 步骤和 preflight 步骤各写了一份，导致两处校验的集合可能不一致。
    # 剥注释这件事只该有一个实现。
    names = []
    for line in raw.splitlines():
        line = line.split("#", 1)[0]
        for tok in re.split(r"[,\s]+", line):
            if tok:
                names.append(tok)
    return names


def main():
    raw = read_input(sys.argv[1:])
    names = split_names(raw)

    if not names:
        sys.stdout.write("")
        return 0

    mains = collect_mains()
    sub2main = collect_sub2main()

    if not mains:
        sys.stderr.write(
            "::error title=resolve-packages::找不到任何 *-packages 目录，"
            "请在仓库根目录运行本脚本\n")
        return 1

    out, seen, unresolved = [], set(), []

    for name in names:
        if name in mains:
            final = name
        elif name in sub2main:
            final = sub2main[name]
            sys.stderr.write(
                "::warning title=autofix::%s 是子包名（%s/%s/%s%s），"
                "已自动替换为主包 %s\n"
                % (name, mains.get(final, "?"), final, name, SUB_SUFFIX, final))
        else:
            unresolved.append(name)
            continue

        if final not in seen:
            seen.add(final)
            out.append(final)

    if unresolved:
        for name in unresolved:
            close = difflib.get_close_matches(name, sorted(mains), n=3, cutoff=0.6)
            hint = "、".join(close) if close else "无"
            sys.stderr.write(
                "::error title=add_packages::%s 既不是主包目录，也不是任何包的子包；"
                "最接近的主包: %s\n" % (name, hint))
        return 1

    sys.stdout.write(",".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())