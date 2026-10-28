# xmhkmail 部署

公共部署仓库，只包含入口脚本、发布索引、部署包和 SHA256 校验文件。不包含应用源码、凭据或业务数据。

## 安装、更新与卸载

在已安装 Docker Engine、稳定 Compose 插件、curl 和 openssl 的 Linux amd64 主机执行：

```sh
curl -fsSL https://raw.githubusercontent.com/ythzaaa/xmhkmail-deploy/main/xmhkmail.sh | sudo bash
```

从菜单选择安装、更新、状态、停启、备份、恢复包、中断恢复或卸载。首次安装按向导填写邮件主机名和证书通知邮箱，公网 IPv4 可留空。

直接更新：

```sh
curl -fsSL https://raw.githubusercontent.com/ythzaaa/xmhkmail-deploy/main/xmhkmail.sh | sudo bash -s -- update
```

新部署状态保存在 `/var/lib/xmhkmail`。已有默认项目自动识别原目录；非默认项目追加 `--directory /原部署目录`。不要删除原部署目录。卸载仅移除本项目容器与网络，配置、密钥、备份、镜像和数据卷保留。

更新先验证发布包，再更新公共脚本与业务镜像；不覆盖配置或数据，不自动升级 PostgreSQL、Redis 或 Caddy。同版本、同运行镜像且健康时不重复停机。版本变更时自动执行离线加密备份和迁移检查，会暂停邮件与网页。

## 当前版本

本轮部署包为 `v0.1.0-rc.3-r4`，邮件镜像仍为已发布 rc.3，使用固定 SHA256 摘要。r4 是 GitHub 部署说明修订，不是新的镜像版本。

安装密码规则和网页恢复包下载的新应用代码尚需下一次镜像发布；当前 rc.3 镜像不包含这些页面改动。主机工具已经自动准备备份密钥，已有密钥不会重新生成。

支持 Debian 12/13、Ubuntu 24.04/26.04 的 Linux amd64 宿主。不自动安装 Docker、修改 DNS/防火墙或探测公网 SMTP；容器健康不代表公网收发已经验收。详细说明随 Release 部署包提供。
