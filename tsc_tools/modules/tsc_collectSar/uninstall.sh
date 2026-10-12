#!/bin/bash
# 1.0.0 20210916
# 1.0.1 20231213 适配FOS

#sar信息采集器类型, 预定义 cron
sar_collector="cron"

#默认sysstat已经安装,未安装则退出
echo -n "Check sysstat service "
if [[ -f /etc/cron.d/sysstat ]]; then
	:
elif systemctl list-unit-files --type=timer 2>/dev/null | grep -q 'sysstat-collect.timer.*enabled'; then
	sar_collector="systemd"
else
	echo -e "\033[31mERROR: sar信息采集器类型获取失败\033[0m"
	exit 1
fi

#将sar取值改为10分钟一次
if [[ "${sar_collector}" == "cron" ]]; then
	salineno=`cat -n /etc/cron.d/sysstat | sed "s/#.*//g"| grep '/usr/lib64/sa/sa1'  | head -n 1 | awk '{print $1}'`
	if [ "${salineno}" != "" ];then
		sed -i "${salineno}c */10 * * * * root /usr/lib64/sa/sa1 1 1" /etc/cron.d/sysstat
	fi
elif [[ "${sar_collector}" == "systemd" ]]; then
	timer_cfg_file="/usr/lib/systemd/system/sysstat-collect.timer"
	if ! [[ -f "${timer_cfg_file}" ]]; then
		echo -e "\033[31mERROR: ${timer_cfg_file}文件不存在\033[0m"
		exit 1
	fi
	sed -i 's/^OnCalendar=.*$/OnCalendar=*:00\/10/g' "${timer_cfg_file}"
	if ! grep -q '^OnCalendar=\*:00/10$' "${timer_cfg_file}"; then
		echo -e "\033[31mERROR: 将sar取值改为10分钟一次, 修改失败\033[0m"
		exit 1
	fi
fi

/bin/rm -rf /tmp/CollectSar 2>/dev/null

\mv /var/log/tsc/CollectSar /tmp/CollectSar
if command -v systemctl &>/dev/null; then
	systemctl daemon-reload
	systemctl restart crond
	systemctl restart sysstat
	systemctl restart sysstat-collect.timer &>/dev/null
else
	service crond restart
	service sysstat restart
fi

echo "uninstall finished"
