#!/bin/bash
# 1.0.0 20210916
# 1.0.1 20231213 适配FOS
# 1.0.2 20261013 移除 OS 门禁(由 RPM %pre 统一校验); rm -rf 加错误处理

#sar信息采集器类型, 预定义 cron
sar_collector="cron"

#默认sysstat已经安装,未安装则退出
echo -n "Check sysstat service "
if [[ -f /etc/cron.d/sysstat ]]; then
	echo -e "\033[60G[\033[1;32m  OK  \033[0m]"
elif systemctl list-unit-files --type=timer 2>/dev/null | grep -q 'sysstat-collect.timer.*enabled'; then
	sar_collector="systemd"
	echo -e "\033[60G[\033[1;32m  OK  \033[0m]"
else
	echo -e "\033[60G[\033[1;31m ERROR \033[0m]"
	exit 1
fi

#创建报告生成文件夹
[ ! -d /var/log/tsc/tsc_collect_sar ] && mkdir -p /var/log/tsc/tsc_collect_sar
#创建sar历史文件保存目录
# rm 失败时不能继续: 旧目录残留, 后续 cp 会把新旧文件混在一起, 备份数据被污染
if [ -d /var/log/tsc/tsc_collect_sar/back_sar ]; then
	if ! /bin/rm -rf /var/log/tsc/tsc_collect_sar/back_sar; then
		echo -e "\033[31mERROR: 无法清理旧备份目录 /var/log/tsc/tsc_collect_sar/back_sar\033[0m"
		exit 1
	fi
fi
mkdir -p /var/log/tsc/tsc_collect_sar/back_sar
#将当前的历史文件拷贝到/var/log/tsc/tsc_collect_sar/back_sar
echo -n "Backup sar logfile"
if \cp /var/log/sa/sa?? /var/log/tsc/tsc_collect_sar/back_sar/; then
	echo -e "\033[60G[\033[1;32m  OK  \033[0m]"
else
	echo -e "\033[60G[\033[1;31m ERROR \033[0m]"
	exit 1
fi

#修改sar周期
#注释每10分钟一次的定时任务
#[ `cat /etc/cron.d/sysstat | grep '/usr/lib64/sa/sa1' | grep "^\*\/10\ \*" -c ` -eq 1 ] && sed -i '/^\*\/10/s/^/#/' /etc/cron.d/sysstat

#新增每分钟一次的定时任务
#[ `cat /etc/cron.d/sysstat | grep '/usr/lib64/sa/sa1' | grep "^\*\/1\ \*" -c ` -eq 0 ] && echo "*/1 * * * * root /usr/lib64/sa/sa1 1 1" >> /etc/cron.d/sysstat

#将sar取值改为1分钟一次
if [[ "${sar_collector}" == "cron" ]]; then
	salineno=$(cat -n /etc/cron.d/sysstat | sed "s/#.*//g" | grep '/usr/lib64/sa/sa1' | head -n 1 | awk '{print $1}')
	if [ "${salineno}" != "" ]; then
		sed -i "${salineno}c */1 * * * * root /usr/lib64/sa/sa1 1 1" /etc/cron.d/sysstat
	else
		echo "*/1 * * * * root /usr/lib64/sa/sa1 1 1" >>/etc/cron.d/sysstat
	fi
elif [[ "${sar_collector}" == "systemd" ]]; then
	timer_cfg_file="/usr/lib/systemd/system/sysstat-collect.timer"
	if ! [[ -f "${timer_cfg_file}" ]]; then
		echo -e "\033[31mERROR: ${timer_cfg_file}文件不存在\033[0m"
		exit 1
	fi
	sed -i 's/^OnCalendar=.*$/OnCalendar=*:00\/1/g' "${timer_cfg_file}"
	if ! grep -q '^OnCalendar=\*:00/1$' "${timer_cfg_file}"; then
		echo -e "\033[31mERROR: 将sar取值改为1分钟一次, 修改失败\033[0m"
		exit 1
	fi
fi

#修改sar历史数据保存28天
sed -i '/^HISTORY=/s/^.*$/HISTORY=28/g' /etc/sysconfig/sysstat
if ! grep -q '^HISTORY=28$' /etc/sysconfig/sysstat; then
	echo -e "\033[31mERROR: 修改sar历史数据保存28天, 修改失败\033[0m"
	exit 1
fi

if command -v systemctl &>/dev/null; then
	systemctl daemon-reload
	systemctl restart crond
	systemctl restart sysstat
	systemctl restart sysstat-collect.timer &>/dev/null
else
	service crond restart
	service sysstat restart
fi
