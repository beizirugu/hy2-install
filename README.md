# Hysteria 2 一键安装优化脚本

## GitHub 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/beizirugu/hy2-install/main/install.sh)
```

如果系统没有 `curl`，可使用：

```bash
wget -O install_hysteria2.sh https://raw.githubusercontent.com/beizirugu/hy2-install/main/install.sh && sudo bash install.sh
```

仓库地址：[beizirugu/hy2-install](https://github.com/beizirugu/hy2-install)

适用于 Ubuntu、Debian 及常见 systemd Linux。脚本会安装 Hysteria 2、写入服务端配置、优化 UDP/QUIC 相关内核参数，并在结束时打印 Shadowrocket / Hysteria 2 导入链接。

## 功能

- 自动检测并尝试开启 BBR。
- 写入 UDP/QUIC 内核优化：`fs.file-max=1000000`、`net.core.rmem_max=67108864`、`net.core.wmem_max=67108864` 等。
- 调用 Hysteria 2 官方安装脚本：`https://get.hy2.sh/`。
- 自动生成自签名证书，CN/SAN 为 `www.bing.com`。
- 自动执行 `chown -R hysteria:hysteria /etc/hysteria`，避免服务启动时报证书权限错误。
- `listen` 使用端口范围，触发 Hysteria 2 Linux 端口跳跃。
- 开启 Salamander 混淆、Bing 伪装站、动态 QUIC 窗口。
- 检测日志目录磁盘类型与简单同步写入速度，日志级别通过 `HYSTERIA_LOG_LEVEL=error` 固定为 error，保护慢盘。
- 启动前检测本机是否已有 Hy2 正在运行，已运行时可选择卸载或退出。
- 支持 `--uninstall` 清理服务、配置、本脚本写入的 sysctl、systemd drop-in 和 Hysteria 相关 nftables 残留表。

## 使用

```bash
chmod +x install_hysteria2.sh
sudo bash install_hysteria2.sh
```

运行时会要求输入：

- Hysteria 认证密码：回车随机生成。
- Salamander 混淆密码：回车随机生成。
- 端口跳跃范围：例如 `50000-60000`，回车随机生成高位端口范围。

完整安装日志会写入：

```text
/var/log/hysteria2-install-YYYYMMDD-HHMMSS.txt
```

终端只显示关键步骤和最终导入链接；如果某一步失败，脚本会退出并提示详细日志路径。

## 卸载

```bash
sudo bash install.sh --uninstall
```

卸载流程会先停止并禁用 `hysteria-server.service`，然后清理 Hysteria 相关 nftables 表，再尝试调用官方 `--remove`。最后会兜底删除本脚本写入的配置文件和服务覆盖配置。

## 防火墙提醒

脚本会自动处理本机启用的 `ufw` 或 `firewalld`。如果 VPS 控制台、云安全组或上游防火墙单独限制 UDP，请手动放行你输入的端口范围。

## 配置位置

- 服务端配置：`/etc/hysteria/config.yaml`
- 证书文件：`/etc/hysteria/server.crt`
- 私钥文件：`/etc/hysteria/server.key`
- systemd 服务：`hysteria-server.service`
- systemd 覆盖配置：`/etc/systemd/system/hysteria-server.service.d/10-hysteria2-tuning.conf`
- 内核优化配置：`/etc/sysctl.d/99-hysteria2-tuning.conf`
