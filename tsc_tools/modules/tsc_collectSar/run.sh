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
		glow "${WORK_DIR}"/readme.md
		;;
esac

