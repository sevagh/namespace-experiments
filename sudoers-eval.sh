#!/usr/bin/env bash

set -e

unshare --map-root-user --uts --mount /usr/bin/env bash -c "$(tail -n +8 "${0}")" "${0}" "${@}"
exit "${?}"

set -e

# test setresuid before sudo trips us up
python -c "import os; os.setresuid(-1, 0, -1);"

host="localhost"
user="root"

while getopts ":h:u:" opt; do
	case $opt in
	h)
		host="${OPTARG}"
		;;
	u)
		user="${OPTARG}"
		;;
	\?)
		echo "Invalid option: -$OPTARG" >&2
		exit 1
		;;
	:)
		echo "Option -$OPTARG requires an argument." >&2
		exit 1
		;;
	esac
done
shift "$((OPTIND - 1))"

sudoers_file="${1:-}"
if [ -z "${sudoers_file}" ]; then
	printf "Usage: sudoers-eval.sh path/to/test/sudoers/file\\n" >&2
	exit 1
fi

declare -a on_exit_items

function on_exit() {
	for ((idx = ${#on_exit_items[@]} - 1; idx >= 0; idx--)); do
		eval "${on_exit_items[idx]}" 2>/dev/null
	done
}

function add_on_exit() {
	local n=${#on_exit_items[*]}
	on_exit_items[$n]="$*"
	if [[ $n -eq 0 ]]; then
		trap on_exit EXIT
	fi
}

secret_dir=$(mktemp -d --tmpdir=/tmp)
add_on_exit rm -rf "${secret_dir}"

function copy_and_mount() {
	orig_file="${1}"
	orig_file_cp="${1}"
	if [ -n "${3}" ]; then
		orig_file_cp="${3}"
	fi
	copy_file="${secret_dir}/$(basename "${orig_file_cp}")"
	cp "${orig_file_cp}" "${copy_file}"
	mount --bind -o exec "${copy_file}" "${orig_file}"
	add_on_exit umount "${orig_file}"
	chmod "${2}" "${orig_file}"
}

mount_name="/namespace-mnt-$(cat /proc/sys/kernel/random/uuid)"
mount -o size=1m -t tmpfs "${mount_name}" "${secret_dir}"
add_on_exit umount "${mount_name}"

copy_and_mount "/etc/sudoers" 440 "${sudoers_file}"
copy_and_mount "/usr/libexec/sudo/sudoers.so" 644

hostname "${host}"
sudo -l -h "${host}" -U "${user}"

exit 0
