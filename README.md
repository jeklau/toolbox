# 脚本工具箱
来源：AI和互联网，仅在Debian12/13进行测试。

复制以下命令，根据脚本名进行调整

```bash
bash <(curl -sL https://raw.githubusercontent.com/jeklau/toolbox/main/脚本名)
```

## 例子：

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
