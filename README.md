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
