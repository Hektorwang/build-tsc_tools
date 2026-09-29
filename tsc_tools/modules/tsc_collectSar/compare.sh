#!/bin/bash
# compare.sh — 对比两个日期的 sar 数据, 按小时输出 CSV 比率报告
# 用法: ./compare.sh <date1> <date2> <localIp>  (由 run.sh 的 compare 子命令调用)
# 说明: sar 各列的取列逻辑与 sysstat 版本相关, 按目标机(老版本 sysstat)校准,
#       本脚本不改变取列语义, 仅规范错误返回码/输入校验/引用与接口探测方式。

if [ $# -lt 3 ]; then
	echo "Usage:   ./CollectSar.bin compare date1 date2 localIp"
	echo "Example: ./CollectSar.bin compare 20210910 20210914 172.16.40.43"
	exit 1
fi

REPORT_DIR="/home/fox/CollectSar"
date1="$1"
date2="$2"
ipaddr="$3"

# 输入校验: 8 位数字日期
for d in "${date1}" "${date2}"; do
	if ! [[ "${d}" =~ ^[0-9]{8}$ ]]; then
		echo "Error: date must be YYYYMMDD, got '${d}'"
		exit 1
	fi
done

[ -d "${REPORT_DIR}" ] || mkdir -p "${REPORT_DIR}" >/dev/null 2>&1 || {
	echo "Error: cannot create report dir ${REPORT_DIR}"
	exit 1
}

if [ "${date1}" -gt "${date2}" ]; then
	tmp="${date1}"
	date1="${date2}"
	date2="${tmp}"
fi

output="${REPORT_DIR}/compare-${ipaddr}-${date1}-${date2}.csv"

function CalcDate() {
	awk -v a="$1" -v b="$2" 'BEGIN{printf("%d", (b-a)/86400)}'
}

function CalcRate() {
	awk -v a="$1" -v b="$2" 'BEGIN{if( b > 0 ) printf("%.2f", a/b) ; else print "NA"}'
}

function CalcSubtract() {
	awk -v a="$1" -v b="$2" 'BEGIN{printf("%.2f", a-b)}'
}

#计算日期差，不能超过28天
date1_sec="$(date +%s -d "${date1}" 2>/dev/null)"
date2_sec="$(date +%s -d "${date2}" 2>/dev/null)"
if [ -z "${date1_sec}" ] || [ -z "${date2_sec}" ]; then
	echo "Error: invalid date '${date1}' or '${date2}'"
	exit 1
fi
dates="$(CalcDate "${date1_sec}" "${date2_sec}")"
if [ "${dates}" -gt 28 ]; then
	echo "Error: ${date2} - ${date1} is more than 28 days !"
	exit 1
fi

#组合sa文件名，并判断是否存在
date1_sa="/var/log/sa/sa$(date +%d -d "${date1}")"
date2_sa="/var/log/sa/sa$(date +%d -d "${date2}")"

[ -f "${date1_sa}" ] || {
	echo "Error: sar log for ${date1} ( ${date1_sa} ) is not exist !!!"
	exit 1
}

[ -f "${date2_sa}" ] || {
	echo "Error: sar log for ${date2} ( ${date2_sa} ) is not exist !!!"
	exit 1
}

#获取通讯口名称: 优先 ip 命令(现代发行版), 无 ip 时回退 ifconfig
if command -v ip >/dev/null 2>&1; then
	netname="$(ip -o addr show | awk -v ip="${ipaddr}" '{split($4, a, "/")} $3 == "inet" && a[1] == ip {gsub(":", "", $1); print $2; exit}')"
else
	netname="$(ifconfig 2>/dev/null | grep "${ipaddr}" -B 1 | head -n 1 | awk -F '[: ]' '{print $1}')"
fi
if [ -z "${netname}" ]; then
	echo "Error: ${ipaddr} is not local host IP !!!"
	exit 1
fi

echo "本机IP,时间,CPU峰值比率,内存峰值比率,磁盘IO数比率,网络输入最大值比率,网络输出最大值比率,网络输入平均值比率,网络输出平均值比率,${date1}号CPU当前小时最大使用率,${date2}号CPU当前小时最大使用率,${date1}号内存当前小时最大使用率,${date2}号内存当前小时最大使用率,${date1}号磁盘当前小时最大IO数,${date2}号磁盘当前小时最大IO数,${date1}号网络输入最大流量,${date2}号网络输入最大流量,${date1}号网络输出最大流量,${date2}号网络输出最大流量,${date1}号网络输入平均流量,${date2}号网络输入平均流量,${date1}号网络输出平均流量,${date2}号网络输出平均流量" > "${output}"
for i in {0..23}
do
	if [ "${i}" -lt 10 ];then
		i="0${i}"
	fi
	echo "Process ${i}:00:00 ~ ${i}:59:59 ..."

	#计算CPU使用率最大值
	cpuidle1="$(sar -f "${date1_sa}" -s "${i}:00:00" -e "${i}:59:59" -u | head -n -1 | awk '{print $9}' | grep -v idle | sed '1d' | sed '/^$/d' | sort -n -r | tail -n 1)"
	if [ -n "${cpuidle1}" ];then
		cpuusage1="$(CalcSubtract 100 "${cpuidle1}")"
	else
		cpuusage1="null"
	fi

	cpuidle2="$(sar -f "${date2_sa}" -s "${i}:00:00" -e "${i}:59:59" -u | head -n -1 | awk '{print $9}' | grep -v idle | sed '1d' | sed '/^$/d' | sort -n -r | tail -n 1)"
	if [ -n "${cpuidle2}" ];then
		cpuusage2="$(CalcSubtract 100 "${cpuidle2}")"
	else
		cpuusage2="null"
	fi

	if [[ "${cpuusage1}" != "null" && "${cpuusage2}" != "null" ]];then
		cpurate="$(CalcRate "${cpuusage1}" "${cpuusage2}")"
	else
		cpurate="null"
	fi

	#计算内存最大值
	memusage1="$(sar -f "${date1_sa}" -s "${i}:00:00" -e "${i}:59:59" -r | head -n -1 | awk '{print $5}' | grep -v mem | sed '1d' | sed '/^$/d' | sort -n | tail -n 1)"
	memusage2="$(sar -f "${date2_sa}" -s "${i}:00:00" -e "${i}:59:59" -r | head -n -1 | awk '{print $5}' | grep -v mem | sed '1d' | sed '/^$/d' | sort -n | tail -n 1)"

	if [ ! -n "${memusage1}" ];then
		memusage1="null"
	fi

	if [ ! -n "${memusage2}" ];then
		memusage2="null"
	fi

	if [[ "${memusage1}" != "null" && "${memusage2}" != "null" ]];then
		memrate="$(CalcRate "${memusage1}" "${memusage2}")"
	else
		memrate="null"
	fi

	#计算磁盘IO最大值
	io1="$(sar -f "${date1_sa}" -s "${i}:00:00" -e "${i}:59:59" -b | head -n -1 | awk '{print $3}' | grep -v tps | sed '1d' | sed '/^$/d' | sort -n | tail -n 1)"
	io2="$(sar -f "${date2_sa}" -s "${i}:00:00" -e "${i}:59:59" -b | head -n -1 | awk '{print $3}' | grep -v tps | sed '1d' | sed '/^$/d' | sort -n | tail -n 1)"

	if [ ! -n "${io1}" ];then
		io1="null"
	fi
	if [ ! -n "${io2}" ];then
		io2="null"
	fi

	if [[ "${io1}" != "null" && "${io2}" != "null" ]];then
		iorate="$(CalcRate "${io1}" "${io2}")"
	else
		iorate="null"
	fi

	#计算网络输入输出最大值
	rxnet1_max="$(sar -f "${date1_sa}" -s "${i}:00:00" -e "${i}:59:59" -n DEV | grep "${netname}" | head -n -1 | awk '{print $6}' | sort -n | tail -n 1)"
	txnet1_max="$(sar -f "${date1_sa}" -s "${i}:00:00" -e "${i}:59:59" -n DEV | grep "${netname}" | head -n -1 | awk '{print $7}' | sort -n | tail -n 1)"
	rxnet2_max="$(sar -f "${date2_sa}" -s "${i}:00:00" -e "${i}:59:59" -n DEV | grep "${netname}" | head -n -1 | awk '{print $6}' | sort -n | tail -n 1)"
	txnet2_max="$(sar -f "${date2_sa}" -s "${i}:00:00" -e "${i}:59:59" -n DEV | grep "${netname}" | head -n -1 | awk '{print $7}' | sort -n | tail -n 1)"

	[ ! -n "${rxnet1_max}" ] && rxnet1_max="null"
	[ ! -n "${txnet1_max}" ] && txnet1_max="null"
	[ ! -n "${rxnet2_max}" ] && rxnet2_max="null"
	[ ! -n "${txnet2_max}" ] && txnet2_max="null"

	if [[ "${rxnet1_max}" != "null" && "${txnet1_max}" != "null" && "${rxnet2_max}" != "null" && "${txnet2_max}" != "null" ]];then
		rxrate_max="$(CalcRate "${rxnet1_max}" "${rxnet2_max}")"
		txrate_max="$(CalcRate "${txnet1_max}" "${txnet2_max}")"
	else
		rxrate_max="null"
		txrate_max="null"
	fi

	#计算网络输入输出平均值
	rxnet1_avg="$(sar -f "${date1_sa}" -s "${i}:00:00" -e "${i}:59:59" -n DEV | grep "${netname}" | head -n -1 | awk 'BEGIN{s=0}{s+=$6}END{printf("%.2f\n", s/NR)}')"
	txnet1_avg="$(sar -f "${date1_sa}" -s "${i}:00:00" -e "${i}:59:59" -n DEV | grep "${netname}" | head -n -1 | awk 'BEGIN{s=0}{s+=$7}END{printf("%.2f\n", s/NR)}')"
	rxnet2_avg="$(sar -f "${date2_sa}" -s "${i}:00:00" -e "${i}:59:59" -n DEV | grep "${netname}" | head -n -1 | awk 'BEGIN{s=0}{s+=$6}END{printf("%.2f\n", s/NR)}')"
	txnet2_avg="$(sar -f "${date2_sa}" -s "${i}:00:00" -e "${i}:59:59" -n DEV | grep "${netname}" | head -n -1 | awk 'BEGIN{s=0}{s+=$7}END{printf("%.2f\n", s/NR)}')"

	[ ! -n "${rxnet1_avg}" ] && rxnet1_avg="null"
	[ ! -n "${txnet1_avg}" ] && txnet1_avg="null"
	[ ! -n "${rxnet2_avg}" ] && rxnet2_avg="null"
	[ ! -n "${txnet2_avg}" ] && txnet2_avg="null"

	if [[ "${rxnet1_avg}" != "null" && "${txnet1_avg}" != "null" && "${rxnet2_avg}" != "null" && "${txnet2_avg}" != "null" ]];then
		rxrate_avg="$(CalcRate "${rxnet1_avg}" "${rxnet2_avg}")"
		txrate_avg="$(CalcRate "${txnet1_avg}" "${txnet2_avg}")"
	else
		rxrate_avg="null"
		txrate_avg="null"
	fi

	echo "${ipaddr},${i}:00:00,${cpurate},${memrate},${iorate},${rxrate_max},${txrate_max},${rxrate_avg},${txrate_avg},${cpuusage1},${cpuusage2},${memusage1},${memusage2},${io1},${io2},${rxnet1_max},${rxnet2_max},${txnet1_max},${txnet2_max},${rxnet1_avg},${rxnet2_avg},${txnet1_avg},${txnet2_avg}" >> "${output}"
done
echo "Run Finished, log write to ${output} ."
exit 0
