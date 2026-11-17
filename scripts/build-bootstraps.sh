#!/usr/bin/env bash
# shellcheck disable=SC2039,SC2059

# Title:         build-bootstrap.sh
# Description:   A script to build bootstrap archives for the termux-app
#                from local package sources instead of debs published in
#                apt repo like done by generate-bootstrap.sh. It allows
#                bootstrap archives to be easily built for (forked) termux
#                apps without having to publish an apt repo first.
# Usage:         run "build-bootstrap.sh --help"
version=0.1.0

set -e

export TERMUX_SCRIPTDIR=$(realpath "$(dirname "$(realpath "$0")")/../")
: "${TERMUX_TOPDIR:="$HOME/.termux-build"}"
. "${TERMUX_SCRIPTDIR}"/scripts/properties.sh
. "${TERMUX_SCRIPTDIR}"/scripts/build/termux_step_handle_buildarch.sh

BOOTSTRAP_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-tmp.XXXXXXXX")

# By default, bootstrap archives are compatible with Android >=7.0
# and <10.
BOOTSTRAP_ANDROID10_COMPATIBLE=false

# By default, bootstrap archives will be built for all architectures
# supported by Termux application.
# Override with option '--architectures'.
TERMUX_DEFAULT_ARCHITECTURES=("aarch64" "arm" "i686" "x86_64")
TERMUX_ARCHITECTURES=("${TERMUX_DEFAULT_ARCHITECTURES[@]}")

TERMUX_PACKAGES_DIRECTORY="/home/builder/termux-packages"
TERMUX_BUILT_DEBS_DIRECTORY="$TERMUX_PACKAGES_DIRECTORY/output"
TERMUX_BUILT_PACKAGES_DIRECTORY="/data/data/.built-packages"

IGNORE_BUILD_SCRIPT_NOT_FOUND_ERROR=1
FORCE_BUILD_PACKAGES=0

# Durable copy of TERMUX_BUILT_PACKAGES_DIRECTORY.
#
# TERMUX_BUILT_PACKAGES_DIRECTORY is /data/data/.built-packages, which lives in
# the container's writable layer when /data is not bind-mounted (run-docker.sh
# only does that with -m). Anything written there is lost the moment the
# container goes away, so a cancelled build leaves no trace of what it finished.
#
# This directory sits inside TERMUX_PACKAGES_DIRECTORY, which run-docker.sh does
# mount from the host, so its contents survive and can be cached across runs.
# Where the durable copy of the markers lives.
#
# Must be somewhere the container user can create directories. The mounted repo
# root is not: run-docker.sh only chowns it when the host uid is neither 1001 nor
# 0, and GitHub runners are 1001, so the container's builder user cannot mkdir
# there ("Permission denied"). /tmp inside the container is writable, and the
# workflow lifts the result out with docker cp, which runs as the host user.
TERMUX_BUILT_PACKAGES_MIRROR="${TERMUX_CI_CACHE_DIR:-/tmp/.ci-cache}/built-packages"

# Written before the build loop: the full ordered plan, one package per line.
# Diffing it against the built-package directory answers "what is left".
TERMUX_BUILD_PLAN_FILE="${TERMUX_CI_CACHE_DIR:-/tmp/.ci-cache}/build-plan.txt"

# Records which app package name the cached debs were built for.
#
# The name is compiled into every artefact (ELF DT_RUNPATH, script $PREFIX
# defaults), so a cache built under one name must never be adopted under
# another. Comparing this stamp against the current build's own resolved prefix
# catches a mismatch that the cache key alone would miss if the key were built
# from a stale or hand-edited value.
TERMUX_CACHE_STAMP_FILE="${TERMUX_CI_CACHE_DIR:-/tmp/.ci-cache}/package-name.txt"


# Set TERMUX_KEEP_BUILT_PACKAGES=1 to resume from a previous run instead of
# wiping everything. Still forced off whenever the package name changed, because
# cached debs bake the old prefix into their ELF DT_RUNPATH and reusing them
# produces a bootstrap whose paths point at a package that no longer exists.
TERMUX_KEEP_BUILT_PACKAGES="${TERMUX_KEEP_BUILT_PACKAGES:-0}"

# A list of packages to build
declare -a PACKAGES=()

# A list of non-essential packages to build.
# By default it is empty, but can be filled with option '--add'.
declare -a ADDITIONAL_PACKAGES=()

# A list of already extracted packages
declare -a EXTRACTED_PACKAGES=()

# A list of options to pass to build-package.sh
declare -a BUILD_PACKAGE_OPTIONS=()

# Check for some important utilities that may not be available for
# some reason.
for cmd in ar awk curl grep gzip find sed tar xargs xz zip; do
	if [ -z "$(command -v $cmd)" ]; then
		echo "[!] Utility '$cmd' is not available in PATH."
		exit 1
	fi
done

# Build deb files for package and its dependencies deb from source for arch
build_package() {

	local return_value

	local TERMUX_ARCH="$1"
	local package_name="$2"

	local build_output

	# Build package from source
	# stderr will be redirected to stdout and both will be captured into variable and printed on screen
	cd "$TERMUX_PACKAGES_DIRECTORY"
	echo $'\n\n\n'"[*] Building '$package_name'..."
	exec 99>&1
	build_output="$("$TERMUX_PACKAGES_DIRECTORY"/build-package.sh "${BUILD_PACKAGE_OPTIONS[@]}" -a "$TERMUX_ARCH" "$package_name" 2>&1 | tee >(cat - >&99); exit ${PIPESTATUS[0]})";
	return_value=$?
	echo "[*] Building '$package_name' exited with exit code $return_value"
	exec 99>&-
	if [ $return_value -ne 0 ]; then
		echo "Failed to build package '$package_name' for arch '$TERMUX_ARCH'" 1>&2

		# Dependency packages may not have a build.sh, so we ignore the error.
		# A better way should be implemented to validate if its actually a dependency
		# and not a required package itself, by removing dependencies from PACKAGES array.
		if [[ $IGNORE_BUILD_SCRIPT_NOT_FOUND_ERROR == "1" ]] && [[ "$build_output" == *"No build.sh script at package dir"* ]]; then
			echo "Ignoring error 'No build.sh script at package dir'" 1>&2
			return 0
		fi
	fi

	return $return_value

}

# Extract *.deb files to the bootstrap root.
extract_debs() {

	local package_arch="$1"
	local current_package_name
	local data_archive
	local control_archive
	local package_tmpdir
	local deb
	local file

	cd "$TERMUX_BUILT_DEBS_DIRECTORY"

	if [ -z "$(ls -A)" ]; then
		echo $'\n\n\n'"No debs found"
		return 1
	else
		echo $'\n\n\n'"Deb Files:"
		echo "\""
		ls
		echo "\""
	fi

	for deb in *.deb; do

		current_package_name="$(echo "$deb" | sed -E 's/^([^_]+).*/\1/' )"
		current_package_arch="$(echo "$deb" | sed -E 's/.*_(aarch64|all|arm|i686|x86_64).deb$/\1/' )"
		echo "current_package_name: '$current_package_name'"
		echo "current_package_arch: '$current_package_arch'"

		if [[ "$current_package_arch" != "$package_arch" ]] && [[ "$current_package_arch" != "all" ]]; then
			echo "[*] Skipping incompatible package '$deb' for target '$package_arch'..."
			continue
		fi

		if [[ "$current_package_name" == *"-static" ]]; then
			echo "[*] Skipping static package '$deb'..."
			continue
		fi

		if [[ " ${EXTRACTED_PACKAGES[*]} " == *" $current_package_name "* ]]; then
			echo "[*] Skipping already extracted package '$current_package_name'..."
			continue
		fi

		EXTRACTED_PACKAGES+=("$current_package_name")

		package_tmpdir="${BOOTSTRAP_PKGDIR}/${current_package_name}"
		mkdir -p "$package_tmpdir"
		rm -rf "$package_tmpdir"/*

		echo "[*] Extracting '$deb'..."
		(cd "$package_tmpdir"
			ar x "$TERMUX_BUILT_DEBS_DIRECTORY/$deb"

			# data.tar may have extension different from .xz
			if [ -f "./data.tar.xz" ]; then
				data_archive="data.tar.xz"
			elif [ -f "./data.tar.gz" ]; then
				data_archive="data.tar.gz"
			else
				echo "No data.tar.* found in '$deb'."
				return 1
			fi

			# Do same for control.tar.
			if [ -f "./control.tar.xz" ]; then
				control_archive="control.tar.xz"
			elif [ -f "./control.tar.gz" ]; then
				control_archive="control.tar.gz"
			else
				echo "No control.tar.* found in '$deb'."
				return 1
			fi

			# Extract files.
			tar xf "$data_archive" -C "$BOOTSTRAP_ROOTFS"

			if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
				# Register extracted files.
				tar tf "$data_archive" | sed -E -e 's@^\./@/@' -e 's@^/$@/.@' -e 's@^([^./])@/\1@' > "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info/${current_package_name}.list"

				# Generate checksums (md5).
				tar xf "$data_archive"
				find data -type f -print0 | xargs -0 -r md5sum | sed 's@^\.$@@g' > "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info/${current_package_name}.md5sums"

				# Extract metadata.
				tar xf "$control_archive"
				{
					cat control
					echo "Status: install ok installed"
					echo
				} >> "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/status"

				# Additional data: conffiles & scripts
				for file in conffiles postinst postrm preinst prerm; do
					if [ -f "${PWD}/${file}" ]; then
						cp "$file" "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info/${current_package_name}.${file}"
					fi
				done
			fi
		)
	done

}

# Add termux bootstrap second stage files
add_termux_bootstrap_second_stage_files() {

	local package_arch="$1"

	echo $'\n\n\n'"[*] Adding termux bootstrap second stage files..."

	mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}"
	sed -e "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" \
		-e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}|g" \
		-e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE}|g" \
		-e "s|@TERMUX_PACKAGE_MANAGER@|${TERMUX_PACKAGE_MANAGER}|g" \
		-e "s|@TERMUX_PACKAGE_ARCH@|${package_arch}|g" \
		-e "s|@TERMUX_APP__NAME@|${TERMUX_APP__NAME}|g" \
		-e "s|@TERMUX_ENV__S_TERMUX@|${TERMUX_ENV__S_TERMUX}|g" \
		"$TERMUX_SCRIPTDIR/scripts/bootstrap/$TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE" \
		> "${BOOTSTRAP_ROOTFS}/${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}/$TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE"
	chmod 700 "${BOOTSTRAP_ROOTFS}/${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}/$TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE"

	# TODO: Remove it when Termux app supports `pacman` bootstraps installation.
	sed -e "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" \
		-e "s|@TERMUX__PREFIX__PROFILE_D_DIR@|${TERMUX__PREFIX__PROFILE_D_DIR}|g" \
		-e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_DIR}|g" \
		-e "s|@TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE@|${TERMUX_BOOTSTRAP__BOOTSTRAP_SECOND_STAGE_ENTRY_POINT_SUBFILE}|g" \
		"$TERMUX_SCRIPTDIR/scripts/bootstrap/01-termux-bootstrap-second-stage-fallback.sh" \
		> "${BOOTSTRAP_ROOTFS}/${TERMUX__PREFIX__PROFILE_D_DIR}/01-termux-bootstrap-second-stage-fallback.sh"
	chmod 600 "${BOOTSTRAP_ROOTFS}/${TERMUX__PREFIX__PROFILE_D_DIR}/01-termux-bootstrap-second-stage-fallback.sh"

}

# Final stage: generate bootstrap archive and place it to current
# working directory.
# Information about symlinks is stored in file SYMLINKS.txt.
create_bootstrap_archive() {

	echo $'\n\n\n'"[*] Creating 'bootstrap-${1}.zip'..."

	# =========================================================================
	# 统一清除 com.termux 残留（打包前）
	#
	# 背景：改名只改 properties.sh 的 TERMUX_APP__PACKAGE_NAME 是不够的。
	# 上游有一批包把 com.termux 直接硬写在源码里，没走 $TERMUX_APP__NAMESPACE /
	# $TERMUX_PREFIX 变量，所以 properties.sh 的 sed 占位符替换管不到它们。
	#
	# 实测（对线上 375MB 构建产物全量扫描）：
	#   com.termux 共 107 处，分布如下
	#     ELF 二进制   : 0 处   ← 说明编译期路径派生是对的，没有烧进二进制
	#     TEXT 文本    : 4 个文件（motd.sh / termux-login.sh /
	#                    init-termux-properties.sh / termux.properties）
	#     其他         : 20 个文件，全是 shell 脚本（bin/pkg x22、bin/login x14、
	#                    bin/termux-reset x11、bin/termux-change-repo x9 ...）
	#
	# 因为 ELF 里一处都没有，所以**纯文本替换是安全的**：
	#   com.termux (10) -> <新包名> (13 或 19)，长度变化只影响文本，不影响二进制。
	# 若将来真出现 ELF 残留，这里的 ELF 检测会把它们跳过并报出来，不会改坏。
	#
	# 替换规则：com.termux -> TERMUX_APP__PACKAGE_NAME 的实际值。
	# 注意 Shell API 的 namespace 也必须是新包名，否则 termux-clipboard-* 之类
	# 命令里的 am start -n <namespace>.app.TermuxService 会指向不存在的组件。
	# =========================================================================
	termux_bootstrap_replace_prefix() {
		local new_pkg="${TERMUX_APP__PACKAGE_NAME:?}"
		local rootfsprefix="${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}"
		local changed=0 skipped_elf=0 scanned=0

		[ -d "$rootfsprefix" ] || { echo "[*] skip prefix rewrite: no $rootfsprefix"; return 0; }

		echo "[*] Rewriting com.termux -> ${new_pkg} under $rootfsprefix"

		# 只处理文本：用 grep -Il 列出「含 com.termux 且被判定为文本」的文件。
		# -I 跳过二进制（等价于 ELF 安全网），-l 只列文件名，-r 递归。
		# 先记录「含 com.termux 但被判定为二进制」的文件，用于报警。
		local bin_hits
		bin_hits="$(grep -rl --binary-files=text -e 'com\.termux' "$rootfsprefix" 2>/dev/null |
		            while IFS= read -r f; do
		                if ! grep -qI . "$f" 2>/dev/null; then printf '%s\n' "$f"; fi
		            done)"

		if [ -n "$bin_hits" ]; then
			echo "[!] WARNING: $? binary file(s) still contain com.termux (NOT modified):"
			printf '%s\n' "$bin_hits" | head -20 | sed 's/^/      /'
			echo "    These need a source-level fix; text-only rewriting cannot handle them."
		else
			echo "[*] No binary file contains com.termux (text-only rewrite is safe)"
		fi

		# 正式替换：只对文本文件动手
		while IFS= read -r -d '' f; do
			scanned=$((scanned + 1))
			# grep -I 判定为非文本的直接跳过（双保险）
			if ! grep -qI . "$f" 2>/dev/null; then
				skipped_elf=$((skipped_elf + 1))
				continue
			fi
			# 用 | 作分隔符，避免包名里可能出现的 / （包名不会含 /，但防御性写法）
			if sed -i "s|com\.termux|${new_pkg}|g" "$f" 2>/dev/null; then
				changed=$((changed + 1))
			fi
		# find -print0 / grep -lZ 配合 read -d '' 处理带空格的文件名
		done < <(grep -rlZ --binary-files=text -e 'com\.termux' "$rootfsprefix" 2>/dev/null)

		echo "[*] Rewrite done: scanned=$scanned changed=$changed skipped_binary=$skipped_elf"

		# 复核：替换后理论上不该再有 com.termux 文本残留
		local remain
		remain=$(grep -rlI -e 'com\.termux' "$rootfsprefix" 2>/dev/null | wc -l)
		echo "[*] Text files still containing com.termux: $remain"

		if [ "$remain" -ne 0 ]; then
			echo "[!] Remaining files:"
			grep -rlI -e 'com\.termux' "$rootfsprefix" 2>/dev/null | head -30 | sed 's|^.*/usr/|      usr/|'
		fi
	}

	termux_bootstrap_replace_prefix

	# =========================================================================
	# 注入 opt/ 静态资源（dex2jar / Sources-AI-dexkit）
	#
	# 这些不是通过 termux 包管理器安装的，是直接放进 $PREFIX/opt/ 的静态文件：
	#   opt/dex2jar/                dex↔jar 转换工具（含 lib/*.jar 依赖）
	#   opt/Sources-AI-dexkit/      APK 脱壳/逆向一体工具
	#     bin/apksigner             签名包装（apksigner.jar from build-tools 37）
	#     bin/Sources-AI-unpack     脱壳/逆向入口
	#     lib/dump.js               frida 内存 DEX 扫描脚本
	#     payload/frida-*.xz        frida server/inject/gadget（arm64 + arm）
	#     tools/apksigner.jar       来自 Android build-tools 37.0.0
	#     tools/debug.keystore
	#
	# 源文件保存在仓库的 termux-bootstrap-opt/ 目录（与 opt/ 下布局一致），
	# 这里原样拷到 $PREFIX/opt/，随 zip 一起打进 bootstrap。
	#
	# 注意：这些文件在打包前已经做过路径改写（com.termux -> 当前包名），
	# 其中的 shebang 和 PREFIX 默认值都指向新路径。
	# =========================================================================
	termux_bootstrap_install_opt() {
		local srcdir="${TERMUX_SCRIPTDIR}/termux-bootstrap-opt"
		local destdir="${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/opt"

		if [ ! -d "$srcdir" ]; then
			echo "[*] skip opt install: no $srcdir"
			return 0
		fi

		echo "[*] Installing opt/ assets from $srcdir"
		mkdir -p "$destdir"

		# cp -a 保留权限；某些脚本需要可执行位
		cp -a "$srcdir"/. "$destdir"/

		# 显式修正可执行位：bin/ 下的包装脚本必须有 +x，
		# 否则 termux 里调用会 "Permission denied"。
		# zip 会保留 unix 权限位，所以这一步在打包前必须做对。
		find "$destdir" -type f 			\( -path '*/bin/*' -o -path '*/dex2jar/*.sh' \) 			-exec chmod 755 {} + 2>/dev/null || true

		# frida payload 是 .xz 压缩包，保持 644 即可
		find "$destdir" -name '*.xz' -exec chmod 644 {} + 2>/dev/null || true

		local n
		n=$(find "$destdir" -type f | wc -l)
		local sz
		sz=$(du -sb "$destdir" 2>/dev/null | awk '{print $1}')
		echo "[*] opt installed: files=$n size=${sz:-?} bytes"

		# 自检：确认关键入口存在且可执行
		for f in opt/Sources-AI-dexkit/bin/Sources-AI-unpack 		         opt/Sources-AI-dexkit/bin/apksigner 		         opt/dex2jar/bin/dex-tools; do
			if [ -x "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/$f" ]; then
				echo "    ok  $f (executable)"
			else
				echo "    [!] MISSING or not executable: $f"
			fi
		done

		# ------------------------------------------------------------------
		# 在 $PREFIX/bin/ 下建符号链接指向 opt/ 里的真实脚本
		#
		# 为什么必须有：opt/ 里的东西不在 $PATH 上，直接敲 d2j-dex2jar /
		# apksigner / Sources-AI-unpack 会 command not found。v3 的做法就是
		# 在 bin/ 下建 24 个链接指向 ../opt/...，这些链接会在打包时被
		# create_bootstrap_archive 收集进 SYMLINKS.txt —— 该函数用
		# `find . -type l` 扫描全部链接，rm 掉实体并把 readlink 结果写进
		# 清单。所以这里只需建真链接，不需要手写 SYMLINKS.txt。
		#
		# 目标用相对路径 ../opt/... 而不是绝对路径：bootstrap 的前缀在运行时
		# 才确定（/data/data/<pkg>/files/usr），绝对路径会把自己写死。
		# ------------------------------------------------------------------
		local binpfx="${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/bin"
		mkdir -p "$binpfx"
		local nlink=0

		# 建单个链接。已有同名实体文件时跳过，避免覆盖 termux 自己装的命令。
		__opt_link() {
			local target="$1" link="$2"
			local full="${binpfx}/${link}"
			if [ -e "$full" ] && [ ! -L "$full" ]; then
				echo "    [!] skip link $link: a real file already exists"
				return 0
			fi
			rm -f "$full"
			if ln -sf "$target" "$full"; then
				nlink=$((nlink + 1))
			fi
		}

		# Sources-AI-dexkit 的两个入口
		__opt_link ../opt/Sources-AI-dexkit/bin/Sources-AI-unpack Sources-AI-unpack
		__opt_link ../opt/Sources-AI-dexkit/bin/apksigner apksigner

		# dex2jar 的启动器：同一个 dex-tools 提供 d2j-run 与 dex2jar 两个名字
		__opt_link ../opt/dex2jar/bin/dex-tools d2j-run
		__opt_link ../opt/dex2jar/bin/dex-tools dex2jar

		# dex2jar 的 17 个 d2j-*.sh，链接名去掉 .sh 后缀
		for shfile in "${destdir}/dex2jar"/d2j-*.sh; do
			[ -e "$shfile" ] || continue
			local base name
			base="$(basename "$shfile")"
			name="${base%.sh}"
			__opt_link "../opt/dex2jar/${base}" "$name"
		done

		# d2j_invoke.sh 用的是下划线，不在上面的 d2j-*.sh 通配里，
		# 但 v3 确实为它建了链接（d2j_invoke），补上以保持行为一致。
		if [ -e "${destdir}/dex2jar/d2j_invoke.sh" ]; then
			__opt_link ../opt/dex2jar/d2j_invoke.sh d2j_invoke
		fi

		echo "[*] opt symlinks created in bin/: $nlink"

		# 自检：回读全局范围内所有指向 opt/ 的链接，打印出来核对
		local back
		back=$(find "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}" -type l 2>/dev/null |
		       while IFS= read -r l; do
		           case "$(readlink "$l")" in
		               *opt/*) printf '%s\n' "$l" ;;
		           esac
		       done | wc -l)
		echo "[*] links pointing into opt/ (will be written to SYMLINKS.txt): $back"
	}

	termux_bootstrap_install_opt

	(cd "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}"
		# Do not store symlinks in bootstrap archive.
		# Instead, put all information to SYMLINKS.txt
		while read -r -d '' link; do
			echo "$(readlink "$link")←${link}" >> SYMLINKS.txt
			rm -f "$link"
		done < <(find . -type l -print0)

		zip -r9 "${BOOTSTRAP_TMPDIR}/bootstrap-${1}.zip" ./*
	)

	mv -f "${BOOTSTRAP_TMPDIR}/bootstrap-${1}.zip" "$TERMUX_PACKAGES_DIRECTORY/"

	echo "[*] Finished successfully (${1})."

}

set_build_bootstrap_traps() {

	#set traps for the build_bootstrap_trap itself
	trap 'build_bootstrap_trap' EXIT
	trap 'build_bootstrap_trap TERM' TERM
	trap 'build_bootstrap_trap INT' INT
	trap 'build_bootstrap_trap HUP' HUP
	trap 'build_bootstrap_trap QUIT' QUIT

	return 0

}

build_bootstrap_trap() {

	local build_bootstrap_trap_exit_code=$?
	trap - EXIT

	[ -h "$TERMUX_BUILT_PACKAGES_DIRECTORY" ] && rm -f "$TERMUX_BUILT_PACKAGES_DIRECTORY"
	[ -d "$BOOTSTRAP_TMPDIR" ] && rm -rf "$BOOTSTRAP_TMPDIR"

	[ -n "$1" ] && trap - "$1"; exit $build_bootstrap_trap_exit_code

}

show_usage() {

    cat <<'HELP_EOF'

build-bootstraps.sh is a script to build bootstrap archives for the
termux-app from local package sources instead of debs published in
apt repo like done by generate-bootstrap.sh. It allows bootstrap archives
to be easily built for (forked) termux apps without having to publish
an apt repo first.


Usage:
  build-bootstraps.sh [command_options]


Available command_options:
  [ -h  | --help ]             Display this help screen
  [ -f ]             Force build even if packages have already been built.
  [ --android10 ]
                     Generate bootstrap archives for Android 10+ for
                     apk packaging system.
  [ -a | --add <packages> ]
                     Additional packages to include into bootstrap archive.
                     Multiple packages should be passed as comma-separated list.
  [ --architectures <architectures> ]
                     Override default list of architectures for which bootstrap
                     archives will be created. Multiple architectures should be
                     passed as comma-separated list.


The package name/prefix that the bootstrap is built for is defined by
TERMUX_APP_PACKAGE in 'scrips/properties.sh'. It defaults to 'com.termux'.
If package name is changed, make sure to run
`./scripts/run-docker.sh ./clean.sh` or pass '-f' to force rebuild of packages.

### Examples

Build default bootstrap archives for all supported archs:
./scripts/run-docker.sh ./scripts/build-bootstraps.sh &> build.log

Build default bootstrap archive for aarch64 arch only:
./scripts/run-docker.sh ./scripts/build-bootstraps.sh --architectures aarch64 &> build.log

Build bootstrap archive with additionall openssh package for aarch64 arch only:
./scripts/run-docker.sh ./scripts/build-bootstraps.sh --architectures aarch64 --add openssh &> build.log
HELP_EOF

echo $'\n'"TERMUX_APP_PACKAGE: \"$TERMUX_APP_PACKAGE\""
echo "TERMUX_PREFIX: \"${TERMUX_PREFIX[*]}\""
echo "TERMUX_ARCHITECTURES: \"${TERMUX_ARCHITECTURES[*]}\""

}

main() {

	local return_value

	while (($# > 0)); do
		case "$1" in
			-h|--help)
				show_usage
				return 0
				;;
			--android10)
				BOOTSTRAP_ANDROID10_COMPATIBLE=true
				;;
			-a|--add)
				if [ $# -gt 1 ] && [ -n "$2" ] && [[ $2 != -* ]]; then
					for pkg in $(echo "$2" | tr ',' ' '); do
						ADDITIONAL_PACKAGES+=("$pkg")
					done
					unset pkg
					shift 1
				else
					echo "[!] Option '--add' requires an argument." 1>&2
					show_usage
					return 1
				fi
				;;
			--architectures)
				if [ $# -gt 1 ] && [ -n "$2" ] && [[ $2 != -* ]]; then
					TERMUX_ARCHITECTURES=()
					for arch in $(echo "$2" | tr ',' ' '); do
						TERMUX_ARCHITECTURES+=("$arch")
					done
					unset arch
					shift 1
				else
					echo "[!] Option '--architectures' requires an argument." 1>&2
					show_usage
					return 1
				fi
				;;
			-f)
				BUILD_PACKAGE_OPTIONS+=("-f")
				FORCE_BUILD_PACKAGES=1
				;;
			*)
				echo "[!] Got unknown option '$1'" 1>&2
				show_usage
				return 1
				;;
		esac
		shift 1
	done

	set_build_bootstrap_traps

	for TERMUX_ARCH in "${TERMUX_ARCHITECTURES[@]}"; do
		if [[ " ${TERMUX_DEFAULT_ARCHITECTURES[*]} " != *" $TERMUX_ARCH "* ]]; then
			echo "Unsupported architecture '$TERMUX_ARCH' for in architectures list: '${TERMUX_ARCHITECTURES[*]}'" 1>&2
			echo "Supported architectures: '${TERMUX_DEFAULT_ARCHITECTURES[*]}'" 1>&2
			return 1
		fi
	done

	for TERMUX_ARCH in "${TERMUX_ARCHITECTURES[@]}"; do
		termux_step_handle_buildarch

		if [[ $FORCE_BUILD_PACKAGES == "1" ]]; then
			if [[ "$TERMUX_KEEP_BUILT_PACKAGES" == "1" ]]; then
				echo "[*] -f given but TERMUX_KEEP_BUILT_PACKAGES=1: keeping built packages and debs"
			else
				rm -f -- "${TERMUX_BUILT_PACKAGES_DIRECTORY:?}/"*
				rm -f -- "${TERMUX_BUILT_DEBS_DIRECTORY:?}/"*
			fi
		fi

		# Reconstitute markers from debs when the marker store lost them.
		#
		# A deb is named <pkg>_<fullversion>_<arch>.deb, which is exactly what
		# the marker file contains, so the debs alone are enough to resume. This
		# matters because the two caches can drift: the deb output lives in the
		# mounted repo root and always survives, while markers historically did
		# not. Rebuilding them here means a run that only preserved output/ still
		# does not recompile everything.
		# Unpack every cached deb into the live sysroot.
		#
		# A deb restored to output/ does nothing for the compiler: configure probes read
		# $TERMUX_PREFIX, not the deb directory. Without this step a resumed build runs
		# against an empty prefix and fails feature probes that a from-scratch build
		# passes. libmp3lame hit exactly that -- HAVE_LANGINFO_H (provided by
		# libandroid-support) probed false, so its <locale.h> include was compiled out
		# and setlocale() was reported undeclared.
		#
		# Extraction matches termux_step_get_dependencies: ar to pull the data member,
		# tar to unpack at /. GNU tar sniffs the compression, so xz/gz/bz2 need no case
		# statement. --no-overwrite-dir preserves existing directory permissions instead
		# of taking the archive's, which would clobber a prefix that is in use.
		install_cached_debs() {
			local deb data_archive
			local installed=0 failed=0
			local installed_le=0
			local current_pkg cached_pkg

			[ -d "$TERMUX_BUILT_DEBS_DIRECTORY" ] || return 0
			compgen -G "$TERMUX_BUILT_DEBS_DIRECTORY/*.deb" > /dev/null 2>&1 || return 0

			# Never install debs built for a different app package name: they carry the
			# other prefix in their paths and would scatter a second tree under
			# /data/data, leaving the prefix half-populated -- worse than empty.
			current_pkg="${TERMUX_APP__PACKAGE_NAME:-unknown}"
			cached_pkg=""
			[ -f "$TERMUX_CACHE_STAMP_FILE" ] && cached_pkg="$(tr -d '[:space:]' < "$TERMUX_CACHE_STAMP_FILE" 2>/dev/null)"
			if [ -z "$cached_pkg" ]; then
				echo "[!] cached debs carry no package-name stamp; not installing them" 1>&2
				return 0
			fi
			if [ "$cached_pkg" != "$current_pkg" ]; then
				echo "[!] cached debs are for '$cached_pkg' but this build is '$current_pkg'; not installing" 1>&2
				return 0
			fi

			echo "[*] Installing cached debs into the sysroot..."
			local workdir
			workdir="$(mktemp -d "${TMPDIR:-/tmp}/debunpack.XXXXXX")" || workdir=""
			if [ -z "$workdir" ]; then
				echo "[!] cannot create a temp dir; skipping deb installation" 1>&2
				return 0
			fi
			for deb in "$TERMUX_BUILT_DEBS_DIRECTORY"/*.deb; do
				[ -e "$deb" ] || continue
				local data_archive=""
				for cand in data.tar.xz data.tar.gz data.tar.bz2 data.tar; do
					if ar p "$deb" "$cand" > "$workdir/data.tar" 2>/dev/null && [ -s "$workdir/data.tar" ]; then
						data_archive="$cand"
						break
					fi
				done
				if [ -z "$data_archive" ]; then
					failed=$((failed + 1))
					echo "[!] no non-empty data member in $(basename "$deb")" 1>&2
					continue
				fi
				# Extract from a file rather than stdin: ar keeps its end of the pipe open
				# while tar streams, and a hiccup then surfaces as SIGPIPE with no text.
				# The compression is known from the member name, so name it explicitly
				# instead of asking tar to sniff it; some tars refuse to guess when the
				# file on disk is called data.tar rather than data.tar.xz.
				# -J is intentionally absent: xz is handled above, outside tar. gz and
				# bz2 are handled by tar everywhere, so they keep their flags.
				local decompress_flag=""
				case "$data_archive" in
					data.tar.gz)   decompress_flag="-z" ;;
					data.tar.bz2)  decompress_flag="-j" ;;
					*)             decompress_flag="" ;;
				esac
				# tar must run as an if-condition, not as a bare command.
				# The script runs with set -e, so a bare failing command aborts the whole
				# build before the next line can read $?. tar exits 2 on fatal errors, which
				# is exactly the BUILD_EXIT_CODE=2 seen in the log, with the failure branch
				# unreachable and no error text. Inside an if condition set -e stands down.
				# xz is decompressed outside tar. The container tar rejected -J with
				# "This does not look like a tar archive" / "-J: Not found in archive",
				# which is busybox tar behaving as if the flag were a member name. Rather
				# than depend on tar having xz compiled in, unwrap the stream first and hand
				# tar a plain archive. Every real Termux deb uses xz, so this is the path
				# that matters.
				local payload="$workdir/data.tar"
				if [ "$data_archive" = "data.tar.xz" ]; then
					local decompressed="$workdir/data.unpacked"
					if command -v xz > /dev/null 2>&1; then
						xz -dc "$workdir/data.tar" > "$decompressed" 2>"$workdir/err"
					elif command -v unxz > /dev/null 2>&1; then
						unxz -c "$workdir/data.tar" > "$decompressed" 2>"$workdir/err"
					elif command -v busybox > /dev/null 2>&1 && busybox unxz --help > /dev/null 2>&1; then
						busybox unxz -c "$workdir/data.tar" > "$decompressed" 2>"$workdir/err"
					elif command -v python3 > /dev/null 2>&1; then
						python3 -c "import lzma,sys,shutil;\
						src=open(sys.argv[1],'rb'); \
						dst=open(sys.argv[2],'wb'); \
						shutil.copyfileobj(lzma.LZMAFile(src), dst)" "$workdir/data.tar" "$decompressed" 2>"$workdir/err"
					else
						echo "[!] no xz decompressor available" > "$workdir/err"
					fi
					# Decompression failure must be caught here: every decompressor writes to
					# $decompressed and its status is discarded, so a failed xz leaves an empty
					# file and tar then reports "This does not look like a tar archive", blaming
					# the wrong tool. An empty result aborts this deb instead.
					if [ -s "$decompressed" ]; then
						payload="$decompressed"
					else
						failed=$((failed + 1))
						if [ "$failed" -le 3 ]; then
							echo "[!] xz produced nothing: $(basename "$deb"): $(head -2 "$workdir/err" 2>/dev/null | tr '\n' ' ')" 1>&2
						fi
						rm -f "$workdir/data.tar" "$decompressed"
						continue
					fi
				fi
				# Plain -x -f: no combined flag cluster, no compression flag for tar to
				# misinterpret.
				#
				# tar almost always exits non-zero here for a reason that does not matter:
				#
				#   tar: .: Cannot utime: Operation not permitted
				#   tar: Exiting with failure status due to previous errors
				#
				# The container user cannot set timestamps on "/", so tar reports failure
				# after having written every file. Judge by what landed on disk instead of
				# by the exit status: list the archive first, and if the contents made it
				# out, accept it. A genuine failure (corrupt archive, no permission to
				# create the prefix) produces no files and is still reported.
				local tar_status unpacked
				tar -x ${decompress_flag} -f "$payload" -C / > /dev/null 2>>"$workdir/err"
				tar_status=$?
				unpacked=$(tar -t ${decompress_flag} -f "$payload" 2>/dev/null | wc -l)
				if [ "$tar_status" -eq 0 ] || { [ "$tar_status" -ne 0 ] && [ "$unpacked" -gt 0 ] && ! grep -q "Cannot open\|Cannot mkdir\|No space" "$workdir/err" 2>/dev/null; }; then
					installed=$((installed + 1))
					if [ "$tar_status" -ne 0 ] && [ "$failed" -le 3 ] && [ "$installed_le" != "1" ]; then
						# Informational: the utime warning will repeat on all 404 debs.
						echo "[*] note: tar reported a non-fatal status for $(basename "$deb") (timestamps only)"
						installed_le=1
					fi
				else
					failed=$((failed + 1))
					if [ "$failed" -le 3 ]; then
						echo "[!] unpack failed: $(basename "$deb") [$data_archive]: $(head -2 "$workdir/err" 2>/dev/null | tr '\n' ' ')" 1>&2
					fi
				fi
				rm -f "$workdir/data.tar"
			done
			rm -rf "$workdir"
			echo "[*] installed $installed deb(s) into the sysroot, $failed failed"
			return 0
		}

		adopt_debs_as_markers() {
			local deb name version
			local adopted=0
			local current_pkg="${TERMUX_APP__PACKAGE_NAME:-unknown}"
			local cached_pkg=""
			
			# Refuse to adopt anything unless the cache was built for the same
			# app package name. A deb from another name is not merely stale: its
			# ELF DT_RUNPATH points at a different data dir, so shipping it yields
			# a bootstrap that cannot find its own libraries.
			if [ -f "$TERMUX_CACHE_STAMP_FILE" ]; then
				cached_pkg="$(cat "$TERMUX_CACHE_STAMP_FILE" 2>/dev/null | tr -d '[:space:]')"
			fi
			if [ -n "$cached_pkg" ] && [ "$cached_pkg" != "$current_pkg" ]; then
				echo "[!] cache was built for package name '$cached_pkg' but this build is '$current_pkg'" 1>&2
				echo "[!] refusing to reuse cached debs; they carry the wrong prefix in their ELF DT_RUNPATH" 1>&2
				echo "[!] run with resume_build=false to rebuild from scratch" 1>&2
				return 0
			fi
			if [ -z "$cached_pkg" ] && [ -d "$TERMUX_BUILT_DEBS_DIRECTORY" ]; then
				if compgen -G "$TERMUX_BUILT_DEBS_DIRECTORY/*.deb" > /dev/null 2>&1; then
					echo "[!] debs present but no package-name stamp; refusing to adopt them" 1>&2
					echo "[!] run with resume_build=false to rebuild from scratch" 1>&2
					return 0
				fi
			fi
			[ -d "$TERMUX_BUILT_DEBS_DIRECTORY" ] || return 0
			mkdir -p "$TERMUX_BUILT_PACKAGES_DIRECTORY" 2>/dev/null || return 0
			for deb in "$TERMUX_BUILT_DEBS_DIRECTORY"/*.deb; do
				[ -e "$deb" ] || continue
				name="$(basename "$deb")"
				# <pkg>_<version>_<arch>.deb -- split from the right so versions
				# containing underscores stay intact.
				name="${name%.deb}"
				version="${name##*_}"
				name="${name%_*}"
				version="${name##*_}"
				name="${name%_*}"
				[ -n "$name" ] && [ -n "$version" ] || continue
				[ -e "$TERMUX_BUILT_PACKAGES_DIRECTORY/$name" ] && continue
				printf '%s\n' "$version" > "$TERMUX_BUILT_PACKAGES_DIRECTORY/$name" 2>/dev/null || continue
				adopted=$((adopted + 1))
			done
			[ "$adopted" -gt 0 ] && echo "[*] adopted $adopted package(s) from existing debs"
			return 0
		}

		# Resuming: restore the markers the previous run managed to record, so
		# build-package.sh prints "built - skipping" instead of rebuilding.
		if [[ "$TERMUX_KEEP_BUILT_PACKAGES" == "1" ]]; then
			if [ -d "$TERMUX_BUILT_PACKAGES_MIRROR" ]; then
				mkdir -p "$TERMUX_BUILT_PACKAGES_DIRECTORY"
				cp -a "$TERMUX_BUILT_PACKAGES_MIRROR"/. "$TERMUX_BUILT_PACKAGES_DIRECTORY"/ 2>/dev/null || true
				echo "[*] resumed markers: $(find "$TERMUX_BUILT_PACKAGES_DIRECTORY" -maxdepth 1 -type f | wc -l) packages marked built"
			else
				echo "[*] resume requested but $TERMUX_BUILT_PACKAGES_MIRROR is absent"
			fi
			# Whatever the marker store did not cover is recovered from the debs.
			adopt_debs_as_markers
		fi

		BOOTSTRAP_ROOTFS="$BOOTSTRAP_TMPDIR/rootfs-${TERMUX_ARCH}"
		BOOTSTRAP_PKGDIR="$BOOTSTRAP_TMPDIR/packages-${TERMUX_ARCH}"

		# Create initial directories for $TERMUX_PREFIX
		if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/etc/apt/apt.conf.d"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/etc/apt/preferences.d"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/info"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/triggers"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/updates"
			mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/log/apt"
			touch "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/available"
			touch "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/var/lib/dpkg/status"
		fi
		mkdir -p "${BOOTSTRAP_ROOTFS}/${TERMUX_PREFIX}/tmp"



		PACKAGES=()
		EXTRACTED_PACKAGES=()

		# Package manager.
		if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
			PACKAGES+=("apt")
		fi

		# Core utilities.
		PACKAGES+=("bash") # Used by `termux-bootstrap-second-stage.sh`
		PACKAGES+=("libbz2")
		if ! ${BOOTSTRAP_ANDROID10_COMPATIBLE}; then
			PACKAGES+=("command-not-found")
		else
			PACKAGES+=("proot")
		fi
		PACKAGES+=("coreutils")
		PACKAGES+=("dash")
		PACKAGES+=("diffutils")
		PACKAGES+=("findutils")
		PACKAGES+=("gawk")
		PACKAGES+=("grep")
		PACKAGES+=("gzip")
		PACKAGES+=("less")
		PACKAGES+=("procps")
		PACKAGES+=("psmisc")
		PACKAGES+=("sed")
		PACKAGES+=("tar")
		PACKAGES+=("termux-core")
		PACKAGES+=("termux-exec")
		PACKAGES+=("termux-keyring")
		PACKAGES+=("termux-tools")
		PACKAGES+=("util-linux")

		# Additional.
		PACKAGES+=("ed")
		PACKAGES+=("debianutils")
		PACKAGES+=("dos2unix")
		PACKAGES+=("inetutils")
		PACKAGES+=("lsof")
		PACKAGES+=("nano")
		PACKAGES+=("net-tools")
		PACKAGES+=("patch")
		PACKAGES+=("unzip")

		# Handle additional packages.
		for add_pkg in "${ADDITIONAL_PACKAGES[@]}"; do
			if [[ " ${PACKAGES[*]} " != *" $add_pkg "* ]]; then
				PACKAGES+=("$add_pkg")
			fi
		done
		unset add_pkg

		# Order packages by runtime dependencies before building them.
		#
		# Packages used to be built in the order written above, with each package's
		# dependencies resolved separately inside
		# scripts/build/termux_step_get_dependencies.sh. That only works while the
		# prebuilt-deb path ("-i") is available. In a renamed fork build-package.sh
		# disables it ("Ignoring -i option to download dependencies ..."), every
		# dependency then builds from source, and the per-package resolver orders by
		# mixing TERMUX_PKG_BUILD_DEPENDS into the graph. On the audio chain that mix
		# is cyclic:
		#
		#   pulseaudio --DEPENDS------->  libsndfile
		#   libsndfile --DEPENDS------->  libmp3lame
		#   libmp3lame --DEPENDS------->  libmpg123
		#   libmpg123  --BUILD_DEPENDS->  pulseaudio
		#
		# so pulseaudio gets built before libsndfile exists, its meson configure
		# cannot find sndfile.pc, and the build dies at
		# '../src/meson.build:613:14: ERROR: Dependency "sndfile" not found'.
		#
		# scripts/resolve-bootstrap-order.py breaks that by ordering on runtime edges
		# only. Build-deps are still satisfied at compile time by the per-package
		# resolver, exactly as before; they just no longer constrain install order.
		# If the helper is missing or fails, the flat list is kept, so this can never
		# make the build worse than it was.
		resolve_bootstrap_order() {

			local script="${TERMUX_SCRIPTDIR}/scripts/resolve-bootstrap-order.py"
			local -a packages_dirs=()
			local seen_dirs=" "
			local -a dir_args=()
			local -a ordered=()
			local -a dropped=()
			local dir
			local line
			local pkg
			local found

			if [ ! -f "$script" ]; then
				echo "[!] resolve-bootstrap-order.py missing; keeping flat build order" 1>&2
				return 1
			fi

			for dir in \
				"${TERMUX_PACKAGES_DIRECTORY}/packages" \
				"${TERMUX_PACKAGES_DIRECTORY}/x11-packages" \
				"${TERMUX_PACKAGES_DIRECTORY}/root-packages" \
				"${TERMUX_SCRIPTDIR}/packages" \
				"${TERMUX_SCRIPTDIR}/x11-packages" \
				"${TERMUX_SCRIPTDIR}/root-packages"; do
				[ -d "$dir" ] || continue
				# TERMUX_SCRIPTDIR and TERMUX_PACKAGES_DIRECTORY normally resolve
				# to the same checkout, so dedupe: buildorder.py aborts with
				# "Duplicated package" if one directory is passed twice.
				dir="$(realpath -m "$dir")"
				case "$seen_dirs" in
					*" $dir "*) continue ;;
				esac
				seen_dirs="$seen_dirs$dir "
				packages_dirs+=("$dir")
			done

			if [ "${#packages_dirs[@]}" -eq 0 ]; then
				echo "[!] no package directories found; keeping flat build order" 1>&2
				return 1
			fi

			for dir in "${packages_dirs[@]}"; do
				dir_args+=("--packages-dir" "$dir")
			done

			# Run from the source tree: the helper imports the sibling buildorder.py,
			# which resolves recipe paths relative to it. stderr is tagged so ordering
			# diagnostics can be told apart from build output.
			if ! mapfile -t ordered < <(
				cd "${TERMUX_SCRIPTDIR}" &&
				TERMUX_ARCH="$TERMUX_ARCH" python3 "$script" \
					--names-only "${PACKAGES[@]}" "${dir_args[@]}" 2> >(sed "s/^/[order] /" >&2)
			); then
				echo "[!] dependency ordering failed; keeping flat build order" 1>&2
				return 1
			fi

			# mapfile also succeeds on an empty stream, so check the size explicitly.
			if [ "${#ordered[@]}" -eq 0 ]; then
				echo "[!] dependency ordering produced nothing; keeping flat build order" 1>&2
				return 1
			fi

			# Never silently drop a requested package: anything the ordering helper did
			# not return gets appended, so the archive still contains it.
			for pkg in "${PACKAGES[@]}"; do
				found=0
				for line in "${ordered[@]}"; do
					if [ "$line" = "$pkg" ]; then
						found=1
						break
					fi
				done
				[ "$found" -eq 0 ] && dropped+=("$pkg")
			done

			echo "[*] Build order resolved: ${#PACKAGES[@]} requested -> ${#ordered[@]} packages (runtime deps first)"
			if [ "${#dropped[@]}" -gt 0 ]; then
				echo "[!] ordering omitted ${#dropped[@]} package(s), appending: ${dropped[*]}" 1>&2
				ordered+=("${dropped[@]}")
			fi

			PACKAGES=("${ordered[@]}")
			return 0
		}

		resolve_bootstrap_order || true
		# Break the libmpg123/pulseaudio/libsndfile/libmp3lame cycle by pre-building
		# its members in dependency-safe order.
		#
		# The cycle:
		#   libmpg123 --BUILD_DEPENDS--> pulseaudio --DEPENDS--> libsndfile
		#       ^                                                    |
		#       +-------------- DEPENDS -------- libmp3lame <---------+
		#
		# Building libmpg123 normally makes termux_step_get_dependencies resolve its
		# build-deps, which recurses into pulseaudio -> libsndfile -> libmp3lame. That
		# recursive build of libmp3lame runs with -s (TERMUX_SKIP_DEPCHECK), so its own
		# dependencies are not installed for it, and its configure aborts with
		#   checking for libmpg123 >= 1.26.0... no
		#   configure: error: no, libmpg123 not found
		# because libmpg123 has not been installed yet at that point.
		#
		# No ordering of a flat build list can satisfy a cycle, so the members are
		# staged instead:
		#   1. libmpg123 with dep checking skipped. mpg123's configure treats a missing
		#      libpulse as "pulse output module not built" rather than an error
		#      (check_forced is only set when --with-audio is passed, which the recipe
		#      does not do). The library and its headers land in the sysroot.
		#   2. libmp3lame normally: its DEPENDS (libiconv, libmpg123) now exist, so
		#      configure finds libmpg123.pc.
		#   3. pulseaudio normally: libsndfile -> libmp3lame -> libmpg123 are all
		#      present, so the rest of the chain resolves without recursion.
		# The main loop then rebuilds libmpg123 with pulseaudio in the sysroot, so the
		# pulse output module is compiled in. Nothing is disabled.
		bootstrap_prestage_audio_cycle() {

			local arch="$1"
			local rc
			local -a saved_options=("${BUILD_PACKAGE_OPTIONS[@]}")

			# Only needed when all four members are actually part of this build.
			local pkg
			for pkg in libmpg123 libmp3lame pulseaudio libsndfile; do
				if [[ " ${PACKAGES[*]} " != *" $pkg "* ]]; then
					echo "[*] audio cycle pre-stage skipped: $pkg not in this build"
					return 0
				fi
			done

			local need_mpg123=1 need_lame=1 need_pulse=1
			if [ -f "$TERMUX_BUILT_PACKAGES_DIRECTORY/libmpg123" ]; then need_mpg123=0; fi
			if [ -f "$TERMUX_BUILT_PACKAGES_DIRECTORY/libmp3lame" ]; then need_lame=0; fi
			if [ -f "$TERMUX_BUILT_PACKAGES_DIRECTORY/pulseaudio" ]; then need_pulse=0; fi

			if [ "$need_mpg123" -eq 0 ] && [ "$need_lame" -eq 0 ] && [ "$need_pulse" -eq 0 ]; then
				echo "[*] Audio cycle pre-stage skipped: all three already marked built"
				return 0
			fi

			echo "[*] Audio cycle pre-stage: need mpg123=$need_mpg123 lame=$need_lame pulse=$need_pulse"

			# 1. libmpg123 without dependency resolution.
			#    -s sets TERMUX_SKIP_DEPCHECK, which makes termux_step_get_dependencies
			#    return immediately, so pulseaudio is not pulled in recursively.
			if [ "$need_mpg123" -eq 1 ]; then
				BUILD_PACKAGE_OPTIONS+=("-s")
				build_package "$arch" "libmpg123"
				rc=$?
				BUILD_PACKAGE_OPTIONS=("${saved_options[@]}")
				if [ "$rc" -ne 0 ]; then
					echo "[!] audio cycle pre-stage: libmpg123 failed ($rc)" 1>&2
					return "$rc"
				fi
			fi

			# 2. libmp3lame now that libmpg123.pc exists.
			if [ "$need_lame" -eq 1 ]; then
				build_package "$arch" "libmp3lame"
				rc=$?
				if [ "$rc" -ne 0 ]; then
					echo "[!] audio cycle pre-stage: libmp3lame failed ($rc)" 1>&2
					return "$rc"
				fi
			fi

			# 3. pulseaudio now that the whole libsndfile chain below it is built.
			if [ "$need_pulse" -eq 1 ]; then
				build_package "$arch" "pulseaudio"
				rc=$?
				if [ "$rc" -ne 0 ]; then
					echo "[!] audio cycle pre-stage: pulseaudio failed ($rc)" 1>&2
					return "$rc"
				fi
			fi

			# Persist what the pre-stage built. Without this, a cancellation
			# during the pre-stage would make the next run redo these three
			# packages from scratch -- up to an hour of wasted work.
			if [ -d "$TERMUX_BUILT_PACKAGES_DIRECTORY" ]; then
				mkdir -p "$TERMUX_BUILT_PACKAGES_MIRROR"
				cp -a "$TERMUX_BUILT_PACKAGES_DIRECTORY"/. "$TERMUX_BUILT_PACKAGES_MIRROR"/ 2>/dev/null || true
			fi

			# If step 1 built libmpg123 without libpulse in the sysroot, its pulse
			# output module was skipped. Drop the marker so the main loop rebuilds
			# it now that pulseaudio is installed. When libmpg123 came from cache it
			# was built with pulse already, so rebuilding would only risk a failure
			# for no gain.
			if [ "$need_mpg123" -eq 1 ] && [ -d "$TERMUX_BUILT_PACKAGES_DIRECTORY" ]; then
				rm -f -- "$TERMUX_BUILT_PACKAGES_DIRECTORY/libmpg123"
				echo "[*] cleared libmpg123 marker so the main loop rebuilds it with pulse"
			fi

			echo "[*] Audio cycle pre-stage done; main loop will rebuild libmpg123 with pulse support"
			return 0
		}

		# Make the sysroot match what the cache says has been built.
		# Must run before anything compiles: configure probes read the live
		# prefix, so an un-unpacked cache is indistinguishable from an empty one.
		if [[ "$TERMUX_KEEP_BUILT_PACKAGES" == "1" ]]; then
			# Best-effort sysroot population. A failure here degrades the build
			# (some packages may recompile) but must never abort it: the counters
			# inside the function already report what went wrong, and set +e keeps a
			# stray non-zero from tripping the caller's set -e.
			set +e
			install_cached_debs
			set -e
		fi

		bootstrap_prestage_audio_cycle "$TERMUX_ARCH" || return $?


		# Mirror the built-package markers into the mounted repo root.
		#
		# Called after every package so a cancellation (GitHub kills the job at
		# six hours) loses at most the package that was in flight. These are a
		# few hundred bytes of text each, so the per-package cost is noise next
		# to the compile time it protects.
		mirror_built_packages() {
			[ -d "$TERMUX_BUILT_PACKAGES_DIRECTORY" ] || return 0
			mkdir -p "$TERMUX_BUILT_PACKAGES_MIRROR" || return 0
			cp -a "$TERMUX_BUILT_PACKAGES_DIRECTORY"/. "$TERMUX_BUILT_PACKAGES_MIRROR"/ 2>/dev/null || true
			
			# Stamp the package name next to the markers. Written on every call so a
			# cache always describes the name its contents were built for, even if the
			# workflow-level key were somehow wrong.
			if [ -d "$(dirname "$TERMUX_CACHE_STAMP_FILE")" ]; then
				printf '%s\n' "${TERMUX_APP__PACKAGE_NAME:-unknown}" > "$TERMUX_CACHE_STAMP_FILE" 2>/dev/null || true
			fi
			
			# Progress line: how many of the planned packages exist, and the tail
			# of what is still missing. Cheap enough to run per package and it makes
			# the log answer "how far along is this" without reading the plan by hand.
			if [ -f "$TERMUX_BUILD_PLAN_FILE" ]; then
				local total done_n remaining
				total=$(wc -l < "$TERMUX_BUILD_PLAN_FILE" 2>/dev/null || echo 0)
				# Count only planned packages that have a marker. The marker
				# directory also holds subpackage entries (aapt2, d8, dx ...), so its
				# file count can exceed the plan and any total-based ratio is nonsense.
				done_n=0
				while IFS= read -r _pkg; do
					[ -n "$_pkg" ] || continue
					[ -e "$TERMUX_BUILT_PACKAGES_DIRECTORY/$_pkg" ] && done_n=$((done_n + 1))
				done < "$TERMUX_BUILD_PLAN_FILE"
				remaining=$((total - done_n))
				[ "$remaining" -lt 0 ] && remaining=0
				printf '[*] progress: %s/%s planned built, %s remaining\n' "$done_n" "$total" "$remaining"
			fi
		}

		# Drop packages a previous run already produced.
		#
		# Without this the loop walks all ${#PACKAGES[@]} entries and each already-built
		# one still pays for build-package.sh startup and dependency resolution before
		# printing "built - skipping". On a resumed run that is most of the wall clock
		# spent on no work at all.
		#
		# Runs after the audio pre-stage on purpose: the pre-stage clears libmpg123's
		# marker so the loop rebuilds it with pulse support, and filtering earlier would
		# drop it from the queue and ship an mpg123 with no pulse backend.
		# Record the plan before executing it, so progress is measurable.
		# The done-markers alone answer "what finished" but not "what is left";
		# with the plan on disk the remaining work is a set difference.
		# The plan records the full ordered set, not just this run's queue, so the
		# done-vs-total ratio reflects real progress across resumed runs.
		mkdir -p "$(dirname "$TERMUX_BUILD_PLAN_FILE")" 2>/dev/null || true
		if [ ! -s "$TERMUX_BUILD_PLAN_FILE" ]; then
			printf '%s\n' "${PACKAGES[@]}" > "$TERMUX_BUILD_PLAN_FILE" 2>/dev/null || true
		fi
		echo "[*] Building for package name: ${TERMUX_APP__PACKAGE_NAME:-unknown} (prefix ${TERMUX__PREFIX:-?})"
		if [ -f "$TERMUX_CACHE_STAMP_FILE" ]; then
			echo "[*] Cache stamp says: $(cat "$TERMUX_CACHE_STAMP_FILE" 2>/dev/null | tr -d '[:space:]')"
		fi
		echo "[*] Build plan: $TERMUX_BUILD_PLAN_FILE ($(wc -l < "$TERMUX_BUILD_PLAN_FILE" 2>/dev/null || echo 0) packages, $(wc -l < "$TERMUX_BUILD_PLAN_FILE" 2>/dev/null || echo 0) total)"

		filter_already_built() {
			local pkg
			local -a remaining=()
			local skipped=0
			[ -d "$TERMUX_BUILT_PACKAGES_DIRECTORY" ] || return 0
			for pkg in "${PACKAGES[@]}"; do
				if [ -f "$TERMUX_BUILT_PACKAGES_DIRECTORY/$pkg" ]; then
					skipped=$((skipped + 1))
				else
					remaining+=("$pkg")
				fi
			done
			echo "[*] queue: ${#PACKAGES[@]} planned, $skipped already built, ${#remaining[@]} to build"
			if [ "${#remaining[@]}" -eq 0 ]; then
				echo "[*] nothing left to build; every planned package is already present"
			fi
			PACKAGES=("${remaining[@]}")
		}

		filter_already_built

		# Build packages.
		for package_name in "${PACKAGES[@]}"; do
			set +e
			build_package "$TERMUX_ARCH" "$package_name"
			build_rc=$?
			mirror_built_packages
			if [ "$build_rc" -ne 0 ]; then
				set -e
				return "$build_rc"
			fi
			set -e
		done

		# Extract all debs.
		extract_debs "$TERMUX_ARCH" || return $?

		# Add termux bootstrap second stage files
		add_termux_bootstrap_second_stage_files "$TERMUX_ARCH"

		# Create bootstrap archive.
		create_bootstrap_archive "$TERMUX_ARCH" || return $?

	done

}

main "$@"
