source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1

elog() {
	echo "[1m *[m $*"
}

einfo() {
	echo "[1;32m *[m $*"
}

ewarn() {
	echo "[1;33m *[m $*" >&2
}

eerror() {
	echo "[1;31m * ERROR:[m $*" >&2
}

die() {
	eerror "$*"
	kill "$GENTOO_INSTALL_REPO_SCRIPT_PID"
	exit 1
}

# Prints an error with file:line info of the nth "stack frame".
# 0 is this function, 1 the calling function, 2 its parent, and so on.
die_trace() {
	local idx="${1:-0}"
	shift
	echo "[1m${BASH_SOURCE[$((idx + 1))]}:${BASH_LINENO[$idx]}: [1;31merror:[m ${FUNCNAME[$idx]}: $*" >&2
	exit 1
}

for_line_in() {
	while IFS="" read -r line || [[ -n $line ]]; do
		"$2" "$line"
	done <"$1"
}

flush_stdin() {
	local empty_stdin
	while read -r -t 0.01 empty_stdin; do true; done
}

ask() {
	local response
	while true; do
		flush_stdin
		read -r -p "$* (Y/n) " response \
			|| die "Error in read"
		case "${response,,}" in
			'') return 0 ;;
			y|yes) return 0 ;;
			n|no) return 1 ;;
			*) continue ;;
		esac
	done
}

try() {
	local response
	local cmd_status
	local prompt_parens="([1mS[mhell/[1mr[metry/[1ma[mbort/[1mc[montinue/[1mp[mrint)"

	# Outer loop, allows us to retry the command
	while true; do
		# Try command
		"$@"
		cmd_status="$?"

		if [[ $cmd_status != 0 ]]; then
			echo "[1;31m * Command failed: [1;33m\$[m $*"
			echo "Last command failed with exit code $cmd_status"

			# Prompt until input is valid
			while true; do
				echo -n "Specify next action $prompt_parens "
				flush_stdin
				read -r response \
					|| die "Error in read"
				case "${response,,}" in
					''|s|shell)
						echo "You will be prompted for action again after exiting this shell."
						/bin/bash --init-file <(echo "init_bash")
						;;
					r|retry) continue 2 ;;
					a|abort) die "Installation aborted" ;;
					c|continue) return 0 ;;
					p|print) echo "[1;33m\$[m $*" ;;
					*) ;;
				esac
			done
		fi

		return
	done
}

countdown() {
	echo -n "$1" >&2

	local i="$2"
	while [[ $i -gt 0 ]]; do
		echo -n "[1;31m$i[m " >&2
		i=$((i - 1))
		sleep 1
	done
	echo >&2
}

download_stdout() {
	wget --quiet --https-only --secure-protocol=PFS -O - -- "$1"
}

download() {
	wget --quiet --https-only --secure-protocol=PFS --show-progress -O "$2" -- "$1"
}

get_device_by_blkid_field() {
	local blkid_field="$1"
	local field_value="$2"
	blkid -g \
		|| die "Error while executing blkid"
	local dev
	dev="$(blkid -o export -t "$blkid_field=$field_value")" \
		|| die "Error while executing blkid to find $blkid_field=$field_value"
	dev="$(grep DEVNAME <<< "$dev")" \
		|| die "Could not find DEVNAME=... in blkid output"
	dev="${dev:8}"
	echo -n "$dev"
}

get_device_by_partuuid() {
	get_device_by_blkid_field 'PARTUUID' "$1"
}

get_device_by_ptuuid() {
	get_device_by_blkid_field 'PTUUID' "$1"
}

get_device_by_uuid() {
	get_device_by_blkid_field 'UUID' "$1"
}

load_or_generate_uuid() {
	local uuid
	local uuid_file="$UUID_STORAGE_DIR/$1"

	if [[ -e $uuid_file ]]; then
		uuid="$(cat "$uuid_file")"
	else
		uuid="$(uuidgen -r)"
		mkdir -p "$UUID_STORAGE_DIR"
		echo -n "$uuid" > "$uuid_file"
	fi

	echo -n "$uuid"
}

# Parses named arguments and stores them in the associative array `arguments`.
# If given, the associative array `known_arguments` must contain a list of arguments
# prefixed with + (mandatory) or ? (optional). "at least one of" can be expressed by +a|b|c.
parse_arguments() {
	local key
	local value
	local a
	for a in "$@"; do
		key="${a%%=*}"
		value="${a#*=}"
		arguments[$key]="$value"
	done

	declare -A allowed_keys
	if [[ -v known_arguments ]]; then
		local m
		for m in "${known_arguments[@]}"; do
			case "${m:0:1}" in
				'+')
					m="${m:1}"
					local has_opt=false
					local m_opt
					# Splitting is intentional here
					# shellcheck disable=SC2086
					for m_opt in ${m//|/ }; do
						allowed_keys[$m_opt]=true
						if [[ -v arguments[$m_opt] ]]; then
							has_opt=true
						fi
					done

					[[ $has_opt == true ]] \
						|| die_trace 2 "Missing mandatory argument $m=..."
					;;

				'?')
					allowed_keys[${m:1}]=true
					;;

				*) die_trace 2 "Invalid start character in known_arguments, in argument '$m'" ;;
			esac
		done

		for a in "${!arguments[@]}"; do
			[[ -v allowed_keys[$a] ]] \
				|| die_trace 2 "Unkown argument '$a'"
		done
	fi
}
