# CI/CD 说明

本仓库的 GitHub Actions 流水线已于 2026-10-12 移除：打包体系由 makeself 自解压包迁移到 RPM，
`.github/workflows/` 目录已清空，不再包含任何工作流。

构建产物的分发后续计划改用制品库（artifact repository）承载，方案确定后再补充文档。

在此之前，构建与验证均在本地完成：

```bash
./build.sh                     # 打 RPM, 产出 release/tsc_tools-<version>-<release>.noarch.rpm
bash -n build.sh               # 语法检查（scriptlet 由 build.sh 打包前自检）
shellcheck build.sh            # 静态检查
rpm -qp --scripts <rpm>        # 人工核验包信息与三段 scriptlet
```

打包机依赖 `nfpm`（默认 `/bin/nfpm`，可用 `NFPM_BIN` 覆盖）与 `dos2unix`，详见 `README.md` 的「打包」一节。
