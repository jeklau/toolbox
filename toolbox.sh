#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: toolbox_menu.sh
# 描述: 服务器运维工具箱 N合一菜单，用于快速执行常用初始化与网络配置脚本。
# 作者: Linux Shell 脚本架构师
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 严格模式 (Strict Mode) 与环境设置
# ------------------------------------------------------------------------------
# -e: 任何命令执行失败（返回值非 0）即刻退出
# -u: 引用未定义变量时报错并退出
# -o pipefail: 管道中任何一个命令失败，则整个管道的退出状态非 0
set -euo pipefail

# ------------------------------------------------------------------------------
# 2. 全局常量定义 (避免硬编码)
# ------------------------------------------------------------------------------
# 界面颜色配置
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_RESET='\033[0m'

# 远程脚本 URL 配置
readonly URL_VPS_INIT="https://raw.githubusercontent.com/jeklau/toolbox/main/vps_init.sh"
readonly URL_BBR_SMART="https://raw.githubusercontent.com/jeklau/toolbox/main/bbr-smart.sh"
readonly URL_SS_RUST="https://raw.githubusercontent.com/jeklau/toolbox/main/ss-rust.sh"
readonly URL_NFT_MANAGER="https://raw.githubusercontent.com/jeklau/toolbox/main/nft-manager.sh"

# ------------------------------------------------------------------------------
# 3. 核心功能函数
# ------------------------------------------------------------------------------

# 打印信息辅助函数
log_info() { echo -e "${COLOR_GREEN}[INFO] ${1}${COLOR_RESET}"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN] ${1}${COLOR_RESET}"; }
log_err()  { echo -e "${COLOR_RED}[ERROR] ${1}${COLOR_RESET}" >&2; }

# 函数名称: execute_remote_script
# 功能描述: 安全地下载并执行远程 Shell 脚本
# 输入参数:
#   $1 - 脚本的下载 URL
#   $2 - 任务的显示名称
execute_remote_script() {
  local script_url="${1}"
  local task_name="${2}"

  log_info "准备执行任务: ${task_name}"

  # 依赖检查：确保当前系统已安装 curl
  if ! command -v curl >/dev/null 2>&1; then
    log_err "系统未安装 curl，请先执行 apt/yum install curl 安装后重试。"
    return 1
  fi

  log_warn "正在从 GitHub 获取并执行脚本，请确保网络通畅..."
  
  # 使用 if 捕获执行状态，避免因子脚本的错误导致主菜单脚本崩溃 (绕过 set -e)
  # 使用 bash -c 进行隔离执行，避免局部环境变量互相污染
  if bash <(curl -sL "${script_url}"); then
    echo ""
    log_info "任务 [${task_name}] 执行完成。"
  else
    echo ""
    log_err "任务 [${task_name}] 执行异常中止，或脚本内存在错误返回。"
  fi

  # 暂停以供用户查看输出
  echo ""
  read -r -p "按 <Enter> 键返回主菜单..." || true
}

# 函数名称: show_menu
# 功能描述: 渲染用户交互菜单
show_menu() {
  clear
  echo -e "${COLOR_YELLOW}====================================================${COLOR_RESET}"
  echo -e "${COLOR_GREEN}           服务器运维工具箱 (N合一控制台)           ${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}====================================================${COLOR_RESET}"
  echo "  1. VPS 初始化配置 (vps_init.sh)"
  echo "  2. 开启 BBR 参数调优 (bbr-smart.sh)"
  echo "  3. 安装配置 Shadowsocks-Rust (ss-rust.sh)"
  echo "  4. 增加 nftables 转发 (nft-manager.sh)"
  echo "  0. 安全退出"
  echo -e "${COLOR_YELLOW}====================================================${COLOR_RESET}"
}

# ------------------------------------------------------------------------------
# 4. 主程序控制逻辑
# ------------------------------------------------------------------------------
main() {
  local choice

  # 捕获 Ctrl+C (SIGINT)，确保优雅退出
  trap 'echo -e "\n${COLOR_YELLOW}检测到中断信号，安全退出。${COLOR_RESET}"; exit 0' SIGINT

  while true; do
    show_menu
    
    # 获取用户输入，使用 || true 防止在纯回车或 EOF 时触发 set -e 导致退出
    read -r -p "请输入对应任务的数字序号 [0-4]: " choice || true

    case "${choice}" in
      1) execute_remote_script "${URL_VPS_INIT}" "VPS 初始化配置" ;;
      2) execute_remote_script "${URL_BBR_SMART}" "BBR 参数调优" ;;
      3) execute_remote_script "${URL_SS_RUST}" "Shadowsocks-Rust 安装" ;;
      4) execute_remote_script "${URL_NFT_MANAGER}" "nftables 转发配置" ;;
      0) 
         log_info "感谢使用，再见！"
         exit 0 
         ;;
      *) 
         log_err "无效的输入 [${choice}]，请准确输入 0 到 4 之间的数字。"
         sleep 1.5 
         ;;
    esac
  done
}

# 启动入口，传递所有外部参数（当前虽未使用，但保留扩展性）
main "$@"
