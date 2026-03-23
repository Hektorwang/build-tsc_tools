---
category: 系统管理
keywords: [内存, 缓存, 释放, drop_cache, 内存压力, 系统优化]
---

# drop_cache

## 功能说明

通过 `echo 3 > /proc/sys/vm/drop_caches` 手动释放内存缓存, 以缓解系统压力. 效果取决于系统可释放的缓存.

## 运行方法说明

```bash
# 默认当内存使用率达到 80% 释放, 可自定义阈值
source /home/tsc/tsc_profile
tsc --drop_cache <自定义释放阈值>
```
