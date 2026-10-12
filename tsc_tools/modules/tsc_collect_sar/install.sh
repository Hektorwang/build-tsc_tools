#!/bin/bash
# 1.0.0 20210916
# 1.0.1 20231213 适配FOS

# Curdir=$(cd "$(dirname "$0")" && pwd) || exit 66

#安装环境检测
echo -n "Check OS "
SysVersion=$(uname -r | grep -Eow 'el[67]|fos[0-9]+|ky[0-9]+' | head -n1)
if [ "$SysVersion" == "el7" ]; then
	echo -e "RHEL/CENTOS 7\033[60G[\033[1;32m  OK  \033[0m]"
elif [ "$SysVersion" == "el6" ]; then
	echo -e "RHEL/CENTOS 6\033[60G[\033[1;32m  OK  \033[0m]"
elif [[ "$SysVersion" =~ "fos" ]]; then
	echo -e "FitStarrySkyOS\033[60G[\033[1;32m  OK  \033[0m]"
elif [ "$SysVersion" == "ky10" ]; then
	echo -e "KylinOS10\033[60G[\033[1;32m  OK  \033[0m]"
else
	#echo "OS must be RHEL/CENTOS 6 or 7! exit"
	echo -e "not RHEL/CENTOS 6/7 or FitStarrySkyOS or KylinOS10\033[60G[\033[1;31m ERROR \033[0m]"
	exit 1
fi

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
[ ! -d /var/log/tsc/CollectSar ] && mkdir -p /var/log/tsc/CollectSar
#创建sar历史文件保存目录
[ -d /var/log/tsc/CollectSar/BackSar ] && /bin/rm -rf /var/log/tsc/CollectSar/BackSar
mkdir -p /var/log/tsc/CollectSar/BackSar
#将当前的历史文件拷贝到/var/log/tsc/CollectSar/BackSar
echo -n "Backup sar logfile"
if \cp /var/log/sa/sa?? /var/log/tsc/CollectSar/BackSar/; then
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
