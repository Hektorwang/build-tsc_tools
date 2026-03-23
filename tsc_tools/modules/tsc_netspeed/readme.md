---
category: 网络监控
keywords: [网卡, 流量, 监控, 速率, 带宽, 收发包, 网络性能, interface]
---

# 网卡速度监测

## 功能说明

持续监控指定网卡的收发包速率

## 使用方法

```bash
source /home/tsc/tsc_profile
tsc --tsc_netspeed ens192
```

## 输出样例

```text
Datetime            |Interface   |TX(Mb/s)    |TX(Pkts/s)  |RX(Mb/s)    |RX(Pkts/s)  |Total(Mb/s)
2025-07-19 02:58:43 |ens192      |        0.00|        3.33|        0.00|        5.33|        0.00
2025-07-19 02:58:46 |ens192      |        0.00|        2.00|        0.00|        2.33|        0.00
2025-07-19 02:58:49 |ens192      |        0.00|        4.33|        0.00|        6.33|        0.00
```
