来源：AI和互联网，仅用于服务器测试。

示例：

```bash
bash <(curl -sL https://raw.githubusercontent.com/jeklau/toolbox/main/nft-manager.sh)
```
```
=====================================================
            Nftables 端口转发管理菜单            
=====================================================
  1) 全新机器添加转发 (清空现有规则，仅保留本次新增)
  2) 在原有规则上增加转发 (追加模式，不影响现有业务)
  3) 一键清空所有转发规则
  4) 查看当前生效的完整转发规则
  5) 批量删除单条/多条规则 (按 Handle 编号精准删除)
  0) 退出脚本
=====================================================
请输入选项 [0-5]: 
```

### SS-Rust：Alpine Linux

支持 Alpine Linux（OpenRC + musl）的 x86_64、aarch64 和 armv7l。
以 root 用户先下载脚本，再运行；Alpine 未安装 Bash 时会自动通过 `apk` 安装。

```sh
wget -O ss-rust.sh https://raw.githubusercontent.com/jeklau/toolbox/main/ss-rust.sh
sh ss-rust.sh install
```

安装后可运行 `sh ss-rust.sh` 打开管理菜单，或使用 `start`、`stop`、
`restart`、`show`、`logs`、`reset`、`uninstall` 子命令。
OpenRC 服务名为 `ss-rust`，加入 `default` 运行级别，日志位于
`/var/log/ss-rust.log`；配置和订阅仍保存在 `/etc/shadowsocks-rust/`。
Debian/Ubuntu 等系统继续使用 systemd。BBR 是可选项，取决于主机内核支持和权限。

### BBR Smart：Alpine Linux

`bbr-smart.sh` 支持 Alpine 默认的 BusyBox `sh`，无需安装 Bash。
以 root 运行，系统需具备 OpenRC（最小化系统可先执行 `apk add openrc`），
且当前内核提供 BBR、fq 和 sysctl 写入权限。

```sh
wget -O bbr-smart.sh https://raw.githubusercontent.com/jeklau/toolbox/main/bbr-smart.sh
sh bbr-smart.sh
```

脚本保留 `/etc/sysctl.conf` 中的其他设置，生成唯一备份，并通过 OpenRC 的
`modules`、`sysctl` boot 服务在开机时加载模块与参数。
Alpine 使用当前内核自带的模块；`kmod-tcp-bbr` 安装逻辑仅用于 OpenWrt。
内核不支持、权限不足或校验失败时会返回非零状态，不显示配置成功。
