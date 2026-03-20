# 脚本工具箱
来源：AI和互联网，仅用于服务器测试。

## 多合一脚本，复制以下命令执行

```bash
bash <(curl -sL https://raw.githubusercontent.com/jeklau/toolbox/main/toolbox.sh)
```
```
====================================================
           服务器运维工具箱 (N合一控制台)           
====================================================
  1. VPS 初始化配置 (vps_init.sh)
  2. 开启 BBR 参数调优 (bbr-smart.sh)
  3. 安装配置 Shadowsocks-Rust (ss-rust.sh)
  4. 增加 nftables 转发 (nft-manager.sh)
  0. 安全退出
====================================================
请输入对应任务的数字序号 [0-4]:
```

## 单一脚本

智能调整BBR参数，适用 Debian/Ubuntu/OpenWRT
```bash
bash <(curl -sL https://raw.githubusercontent.com/jeklau/toolbox/main/bbr-smart.sh)
```

VPS初始化
```bash
bash <(curl -sL https://raw.githubusercontent.com/jeklau/toolbox/main/vps_init.sh)
```

增加NFT转发
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
