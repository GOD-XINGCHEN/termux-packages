#!/usr/bin/bash

termux_download() {
	if [[ $# != 2 ]] && [[ $# != 3 ]]; then
		echo "termux_download(): Invalid arguments - expected <URL> <DESTINATION> [<CHECKSUM>]" 1>&2
		return 1
	fi
	local URL="$1"
	local DESTINATION="$2"
	local CHECKSUM="${3:-SKIP_CHECKSUM}"

	if [[ "$URL" =~ ^file://(/[^/]+)+$ ]]; then
		local source="${URL:7}" # Remove `file://` prefix

		if [ -d "$source" ]; then
			# Create tar file from local directory
			echo "Downloading local source directory at '$source'"
			rm -f "$DESTINATION"
			(cd "$(dirname "$source")" && tar -cf "$DESTINATION" --exclude=".git" "$(basename "$source")")
			return 0
		elif [ ! -f "$source" ]; then
			echo "No local source file found at path of URL '$URL'"
			return 1
		else
			ln -sf "$source" "$DESTINATION"
			return 0
		fi
	fi

	if [ -f "$DESTINATION" ] && [ "$CHECKSUM" != "SKIP_CHECKSUM" ]; then
		# Keep existing file if checksum matches.
		local EXISTING_CHECKSUM
		EXISTING_CHECKSUM=$(sha256sum "$DESTINATION" | cut -d' ' -f1)
		[[ "$EXISTING_CHECKSUM" == "$CHECKSUM" ]] && return
	fi

	local TMPFILE
	local -a CURL_OPTIONS=(
		--fail               # Consider 4xx and 5xx responses as failures
		--retry 3            # curl 内层重试（外层还有一层，别叠加太猛）
		--retry-connrefused  # Also retry on refused connections
		--retry-delay 5      # Wait 5 seconds between retries
		--connect-timeout 30 # Wait at most 30 seconds for a connection to be established
		--retry-max-time 300 # 300s 内允许 curl 自己重试（原 120s 对 30s 连接超时太短）
		--speed-limit 1000   # Expect at least 1000 Bytes per second
		--speed-time 60      # Fail if the minimum speed isn't met for at least 60 seconds
		--location           # Follow redirects
	)
	TMPFILE=$(mktemp "$TERMUX_PKG_TMPDIR/download.${TERMUX_PKG_NAME-unnamed}.XXXXXXXXX")
	if [[ "${TERMUX_QUIET_BUILD-}" == "true" ]]; then
		CURL_OPTIONS+=(--no-progress-meter) # Don't print out transfer statistics
	fi

	echo "Downloading ${URL}"
	echo "Downloading ${URL}"

	# ------------------------------------------------------------------
	# 外层重试：指数退避，次数可配。
	#   TERMUX_DOWNLOAD_RETRIES      总尝试次数（含首次），默认 6
	#   TERMUX_DOWNLOAD_RETRY_DELAY  退避基数（秒），默认 15
	#   TERMUX_DOWNLOAD_RETRY_MAX    单次退避上限（秒），默认 300
	# 默认退避序列 15/30/60/120/240，累计容错约 7.5 分钟。
	# 原版写死 retry=2 且 delay 从不递增，等于只等 2 分钟就放弃 ——
	# 一次 55 分钟的构建就死在单个 30s TCP 超时上。
	# ------------------------------------------------------------------
	local max_try="${TERMUX_DOWNLOAD_RETRIES:-6}"
	local base_delay="${TERMUX_DOWNLOAD_RETRY_DELAY:-15}"
	local max_delay="${TERMUX_DOWNLOAD_RETRY_MAX:-300}"
	local try=1
	local rc=0
	while :; do
		rc=0
		curl "${CURL_OPTIONS[@]}" --output "$TMPFILE" "$URL" || rc=$?
		if [[ $rc -eq 0 ]]; then
			break
		fi
		if [[ $try -ge $max_try ]]; then
			echo "Failed to download $URL (curl exit $rc, tried $try times)" 1>&2
			return 1
		fi
		local delay=$(( base_delay * (1 << (try - 1)) ))
		[[ $delay -gt $max_delay ]] && delay=$max_delay
		echo "Download attempt ${try}/${max_try} failed (curl exit $rc), retry in ${delay}s: $URL" 1>&2
		sleep "$delay"
		try=$(( try + 1 ))
	done

	# 校验和重试：截断的下载（代理掐连接、上游限速）算出的 sha256 必然不同。
	# 原版这里直接 return 1 放弃，是一次可避免的构建失败。
	# TERMUX_DOWNLOAD_SUM_RETRIES 控制重下次数，默认 3。
	local sum_try=1
	local sum_max="${TERMUX_DOWNLOAD_SUM_RETRIES:-3}"
	local ACTUAL_CHECKSUM
	while :; do
		ACTUAL_CHECKSUM=$(sha256sum "$TMPFILE" | cut -d' ' -f1)
		if [[ -z "$CHECKSUM" ]]; then
			printf "WARNING: No checksum check for %s:\nActual: %s\n" \
				"$URL" "$ACTUAL_CHECKSUM"
			break
		elif [[ "$CHECKSUM" == "SKIP_CHECKSUM" ]]; then
			break
		elif [[ "$CHECKSUM" == "$ACTUAL_CHECKSUM" ]]; then
			break
		fi
		if [[ $sum_try -ge $sum_max ]]; then
			printf "Wrong checksum for %s\nExpected: %s\nActual:   %s\n" \
				"$URL" "$CHECKSUM" "$ACTUAL_CHECKSUM" 1>&2
			return 1
		fi
		local sdelay=$(( ${TERMUX_DOWNLOAD_RETRY_DELAY:-15} * (1 << (sum_try - 1)) ))
		[[ $sdelay -gt ${TERMUX_DOWNLOAD_RETRY_MAX:-300} ]] && sdelay=${TERMUX_DOWNLOAD_RETRY_MAX:-300}
		printf "Checksum mismatch (attempt %s/%s), file likely truncated, re-downloading in %ss\n" \
			"$sum_try" "$sum_max" "$sdelay" 1>&2
		sleep "$sdelay"
		local rrc=0
		curl "${CURL_OPTIONS[@]}" --output "$TMPFILE" "$URL" || rrc=$?
		if [[ $rrc -ne 0 ]]; then
			printf "Re-download failed (curl exit %s)\n" "$rrc" 1>&2
			return 1
		fi
		sum_try=$(( sum_try + 1 ))
	done
	mv "$TMPFILE" "$DESTINATION"
	return 0
}

# Make script standalone executable as well as sourceable
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	termux_download "$@"
fi
