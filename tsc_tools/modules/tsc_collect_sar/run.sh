#!/bin/bash

WORK_DIR="$(dirname "$(readlink -f "$0")")" && cd "${WORK_DIR}" || exit 99

case "$1" in
	"compare") 
		shift
		./compare.sh "$@"
		;;
	"install")
		shift
		./install.sh "$@"
		;;
	"uninstall")
		shift
		./uninstall.sh "$@"
		;;
	*)
		if [[ -t 1 ]] && command -v glow >/dev/null 2>&1; then
			glow "${WORK_DIR}"/README.md
		else
			cat "${WORK_DIR}"/README.md
		fi
		;;
esac

