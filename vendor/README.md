# 服务商 OpenWrt 客户端文件

把服务商提供的定制 `.ipk` 放在本目录，然后重新执行：

```sh
docker compose build --no-cache
docker compose up -d
```

构建过程会在上游 OpenClash 之后安装这里的全部 IPK。

特殊文件名 `openclash.ipk` 保留给上游 OpenClash 安装包：如果构建服务器无法访问
GitHub，可手动下载仓库当前固定的版本并以该名称放到这里，构建过程会优先使用它。
该文件应与 `Dockerfile` 中的 `OPENCLASH_RELEASE` 版本一致；更新版本时只需修改该处，
不需要额外维护 SHA-256 构建参数。

如果服务商提供的是安装命令而不是 IPK，可创建 `install.sh`。该脚本在 OpenWrt
镜像构建阶段执行。不要把账号、密码、订阅 URL 或令牌写入脚本并提交到 Git；敏感
配置应在容器启动后通过 LuCI 导入，或以只读 secret/volume 注入。

如果服务商交付的是完整固件（`.img`/`.bin`）、仅适用于特定路由器 CPU 的二进制，
或要求读取路由器硬件标识，则不能直接按 IPK 方式安装，需要先分析文件。
