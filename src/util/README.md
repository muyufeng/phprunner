# util/（占位）

预设用途：SSL 自签证书工具（同 serversideup `utilities-webservers/`
的 `5-generate-ssl.sh` 语义——SSL_MODE≠off 且用户未提供证书时，
运行期生成自签对供起服/健康检查）。

状态：**证书问题暂不处理**（M3-3 拍板：healthcheck-web 走 http→https(-k)
回退的薄方案），目录先立位。启用时本目录按路径镜像布局放置
`etc/entrypoint.d/NN-generate-ssl.sh`。
