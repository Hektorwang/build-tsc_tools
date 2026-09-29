#!/usr/bin/env bash
set -o errexit    # Exit immediately if a command exits with a non-zero status
set -o nounset    # Treat unset variables and parameters as an error
set -o pipefail   # If any command in a pipeline fails, the pipeline returns an error code
set +o posix      # Disable POSIX mode, allowing Bash-specific extensions (less portable)
shopt -s nullglob # When no files match a glob pattern, expand to nothing instead of the pattern itself

IFNAME="${1:-}"
INTERVAL="3"

if [[ -z "${IFNAME}" ]] || [[ "${IFNAME}" == "-h" ]] || [[ "${IFNAME}" == "--help" ]]; then
    echo ""
    echo "usage: $0 [network-interface]"
    echo ""
    echo "e.g. $0 eth0"
    echo ""
    glow "$(dirname "$0")/readme.md"
    exit 0
fi

if [[ ! -d "/sys/class/net/${IFNAME}" ]]; then
    {
        echo "Error: interface '${IFNAME}' not found."
        echo "Available interfaces: $(ls /sys/class/net/ | tr '\n' ' ')"
    } >&2
    exit 1
fi

# 读取网卡统计项; 失败(如网卡中途消失)时打印错误并返回非零
read_stat() {
    local stat_value
    stat_value="$(cat "/sys/class/net/${1}/statistics/${2}" 2>/dev/null)" || {
        echo "Error: Could not read ${2} for ${1}. Does the interface exist?" >&2
        return 1
    }
    echo "${stat_value}"
}

line_count=0

while true; do
    if ((line_count % 20 == 0)); then
        printf "%-20s|%-12s|%-12s|%-12s|%-12s|%-12s|%-12s\n" \
            "Datetime" \
            "Interface" \
            "TX(Mb/s)" \
            "TX(Pkts/s)" \
            "RX(Mb/s)" \
            "RX(Pkts/s)" \
            "Total(Mb/s)"
    fi

    rxb_1="$(read_stat "${IFNAME}" rx_bytes)" || exit 1
    txb_1="$(read_stat "${IFNAME}" tx_bytes)" || exit 1
    rxp_1="$(read_stat "${IFNAME}" rx_packets)" || exit 1
    txp_1="$(read_stat "${IFNAME}" tx_packets)" || exit 1

    sleep "${INTERVAL}"

    rxb_2="$(read_stat "${IFNAME}" rx_bytes)" || exit 1
    txb_2="$(read_stat "${IFNAME}" tx_bytes)" || exit 1
    rxp_2="$(read_stat "${IFNAME}" rx_packets)" || exit 1
    txp_2="$(read_stat "${IFNAME}" tx_packets)" || exit 1

    tx_bytes_diff=$((txb_2 - txb_1))
    rx_bytes_diff=$((rxb_2 - rxb_1))
    tx_packets_diff=$((txp_2 - txp_1))
    rx_packets_diff=$((rxp_2 - rxp_1))

    tx_mbps=$(awk "BEGIN {printf \"%.2f\", $tx_bytes_diff / 1024 / 1024 / $INTERVAL}")
    rx_mbps=$(awk "BEGIN {printf \"%.2f\", $rx_bytes_diff / 1024 / 1024 / $INTERVAL}")

    tx_pps=$(awk "BEGIN {printf \"%.2f\", $tx_packets_diff / $INTERVAL}")
    rx_pps=$(awk "BEGIN {printf \"%.2f\", $rx_packets_diff / $INTERVAL}")

    total_mbps=$(awk "BEGIN {printf \"%.2f\", $rx_mbps + $tx_mbps}")

    printf "%-20s|%-12s|%12.2f|%12.2f|%12.2f|%12.2f|%12.2f\n" \
        "$(date '+%F %T')" \
        "${IFNAME}" \
        "$tx_mbps" "$tx_pps" \
        "$rx_mbps" "$rx_pps" \
        "$total_mbps"

    line_count=$((line_count + 1))
done
