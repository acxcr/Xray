#!/bin/bash

#====================================================================================
#
#          FILE: deploy_xray.sh
# 
#         USAGE: ./deploy_xray.sh
# 
#   DESCRIPTION: 一个用于自动化部署 Xray (VLESS + TCP + XTLS-Vision) 的脚本。
#                集成了证书申请、Nginx 伪装、Xray 部署及日志管理。
# 
#       OPTIONS: ---
#  REQUIREMENTS: ---
#          BUGS: ---
#         NOTES: ---
#        AUTHOR: acxcr & Manus AI
#  ORGANIZATION: 
#       CREATED: 2025年08月20日
#      REVISION: 1.1
#
#====================================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 全局变量
DOMAIN=""
EMAIL=""
UUID=""
XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json" # 官方脚本默认路径
CERT_DIR="/opt/xray/certs"
LOG_DIR="/opt/xray/logs"

# 函数：错误退出
error_exit() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# 函数：信息提示
info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

# 函数：成功提示
success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

# 函数：警告提示
warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

# 函数：输入提示
prompt_input() {
    read -p "$(echo -e "${YELLOW}[INPUT] $1: ${NC}")" val
    echo $val
}

# 函数：按任意键继续
press_any_key() {
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

# 函数：更新系统并安装依赖
prepare_system() {
    info "正在更新系统软件包列表并升级..."
    if ! apt-get update && apt-get upgrade -y; then
        warning "使用 apt-get 失败，尝试使用 yum..."
        if ! yum update -y; then
            error_exit "系统更新失败，请检查您的包管理器。"
        fi
    fi
    
    info "正在安装基础依赖工具 (socat, curl, git)..."
    if ! command -v socat &> /dev/null || ! command -v curl &> /dev/null; then
        if ! apt-get install -y socat curl git; then
            if ! yum install -y socat curl git; then
                error_exit "安装依赖失败。"
            fi
        fi
    fi
    success "系统准备完成。"
}

# 选项1: 证书管理
manage_certificate() {
    info "开始执行: 【证书管理】..."
    
    prepare_system
    
    info "正在创建核心工作目录: ${CERT_DIR}"
    mkdir -p ${CERT_DIR} || error_exit "创建目录 ${CERT_DIR} 失败。"
    
    if [ -f ~/.acme.sh/acme.sh ]; then
        info "Acme.sh 已安装，跳过安装步骤。"
    else
        info "正在从 GitHub 下载并安装 Acme.sh..."
        curl https://get.acme.sh | sh || error_exit "Acme.sh 安装失败 。"
        source ~/.bashrc
        info "Acme.sh 安装成功，自动续期任务已添加。"
    fi
    
    DOMAIN=$(prompt_input "请输入您已正确解析到本服务器 IP 的域名")
    [ -z "${DOMAIN}" ] && error_exit "域名不能为空。"
    
    local_ip=$(curl -s ip.sb)
    resolved_ip=$(ping -c 1 ${DOMAIN} | sed -n '1p' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
    
    if [ "${local_ip}" != "${resolved_ip}" ]; then
        warning "检测到域名 ${DOMAIN} 解析的 IP (${resolved_ip}) 与本机 IP (${local_ip}) 不符！"
        warning "请检查您的 DNS 解析设置，并在解析生效后重试。"
        read -p "是否继续？(y/N): " choice
        [[ "$choice" != "y" && "$choice" != "Y" ]] && return
    fi

    EMAIL=$(prompt_input "请输入您的邮箱 (用于 Let's Encrypt 证书到期提醒)")
    [ -z "${EMAIL}" ] && error_exit "邮箱不能为空。"

    info "域名: ${DOMAIN} | 邮箱: ${EMAIL}"
    info "正在使用 standalone 模式申请证书，请确保 80 端口未被占用。"
    warning "请确保您的服务器防火墙 (如 ufw, firewalld) 或云服务商安全组已放行 TCP 80 端口。"

    if lsof -i:80 &> /dev/null; then
        warning "检测到 80 端口已被占用，脚本将尝试临时停止 Nginx/Apache。"
        systemctl stop nginx 2>/dev/null
        systemctl stop apache2 2>/dev/null
    fi

    ~/.acme.sh/acme.sh --issue -d ${DOMAIN} --standalone -k ec-256 --server letsencrypt --force
    
    if [ $? -ne 0 ]; then
        systemctl start nginx 2>/dev/null
        systemctl start apache2 2>/dev/null
        error_exit "证书申请失败。"
    fi

    info "正在将证书安装到 ${CERT_DIR} 目录..."
    ~/.acme.sh/acme.sh --install-cert -d ${DOMAIN} --ecc \
        --key-file       ${CERT_DIR}/private.key \
        --fullchain-file ${CERT_DIR}/fullchain.pem \
        --reloadcmd      "systemctl reload xray 2>/dev/null; systemctl reload nginx 2>/dev/null"

    if [ $? -eq 0 ]; then
        success "证书申请及安装全部完成！"
    else
        error_exit "证书安装失败。"
    fi
}

# 选项2: 配置 Nginx
configure_nginx() {
    info "开始执行: 【伪装站点】..."
    
    if ! command -v nginx &> /dev/null; then
        info "正在安装 Nginx..."
        if ! apt-get install -y nginx; then
            if ! yum install -y nginx; then
                error_exit "Nginx 安装失败。"
            fi
        fi
    fi
    
    info "正在生成 Nginx 配置文件..."
    info "伪装模式: 跳转到 https://www.jnto.go.jp/"
    
    cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 302 https://www.jnto.go.jp/;
}
EOF
    
    info "正在启动 Nginx 并设置为开机自启..."
    if systemctl enable --now nginx; then
        success "Nginx 伪装站点配置完成！"
        info "您可以在完成所有步骤后 ，访问 https://<你的域名> 来验证跳转效果 。"
    else
        error_exit "Nginx 启动或启用失败。"
    fi
}

# 选项3: 安装 Xray
install_xray() {
    info "开始执行: 【核心服务】..."
    
    info "正在执行 Xray 官方安装脚本..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh )" @ install
    if [ $? -ne 0 ]; then
        error_exit "Xray 安装失败。"
    fi
    
    info "正在创建日志目录: ${LOG_DIR}"
    mkdir -p ${LOG_DIR} || error_exit "创建日志目录失败。"
    
    DOMAIN=$(prompt_input "请再次确认您的域名 (必须与证书一致)")
    [ -z "${DOMAIN}" ] && error_exit "域名不能为空。"
    
    UUID_INPUT=$(prompt_input "请输入您的 VLESS UUID (留空将自动生成)")
    if [ -z "${UUID_INPUT}" ]; then
        UUID=$(xray uuid)
        info "自动生成的 UUID 为: ${UUID}"
    else
        UUID=${UUID_INPUT}
    fi
    
    info "正在根据您的配置生成 config.json..."
    cat > ${XRAY_CONFIG_PATH} <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${LOG_DIR}/access.log",
    "error": "${LOG_DIR}/error.log"
  },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private",
          "geoip:cn"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "outboundTag": "block",
        "protocol": ["bittorrent"]
      }
    ]
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": 80
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "certificates": [
            {
              "certificateFile": "${CERT_DIR}/fullchain.pem",
              "keyFile": "${CERT_DIR}/private.key"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
    
    info "正在配置日志自动轮转 (logrotate)..."
    cat > /etc/logrotate.d/xray <<EOF
${LOG_DIR}/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
    postrotate
        /bin/systemctl reload xray > /dev/null 2>/dev/null || true
    endscript
}
EOF

    info "正在启动 Xray 并设置为开机自启..."
    if systemctl enable --now xray; then
        success "Xray 核心服务部署完成！"
        echo "-------------------------------------------------"
        echo -e "${YELLOW}[!] 您的配置信息如下，请妥善保管:${NC}"
        echo "    地址 (Address): ${DOMAIN}"
        echo "    端口 (Port): 443"
        echo "    用户ID (UUID): ${UUID}"
        echo "    加密 (Encryption): none"
        echo "    传输协议 (Network): tcp"
        echo "    流控 (Flow): xtls-rprx-vision"
        echo "    安全 (Security): tls"
        echo "    SNI: ${DOMAIN}"
        echo "-------------------------------------------------"
        echo -e "${GREEN}分享链接 (VLESS):${NC}"
        echo "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&flow=xtls-rprx-vision&type=tcp#Xray-Vision-by-${DOMAIN}"
        echo "-------------------------------------------------"
    else
        error_exit "Xray 启动或启用失败。请运行 'journalctl -u xray' 查看日志。"
    fi
}

# 选项4: 卸载
uninstall() {
    warning "此操作将彻底删除 Xray, Nginx, Acme.sh 及其所有配置文件！"
    warning "数据将无法恢复，请谨慎操作！"
    
    read -p "您确定要继续执行卸载吗？ (y/N): " choice
    if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
        info "卸载操作已取消。"
        return
    fi
    
    info "正在停止并禁用 Xray 和 Nginx 服务..."
    systemctl stop xray nginx 2>/dev/null
    systemctl disable xray nginx 2>/dev/null
    
    info "正在卸载 Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh )" @ remove --purge
    
    info "正在卸载 Nginx..."
    apt-get purge -y nginx 2>/dev/null || yum remove -y nginx 2>/dev/null
    
    info "正在卸载 Acme.sh..."
    ~/.acme.sh/acme.sh --uninstall
    
    info "正在删除工作目录和日志配置..."
    rm -rf /opt/xray
    rm -f /etc/logrotate.d/xray
    rm -rf ~/.acme.sh
    
    success "所有相关组件和文件均已成功卸载。"
}

# 主菜单
main_menu() {
    clear
    echo "================================================"
    echo "=                                              ="
    echo "=      Xray 自动化部署脚本 (VLESS + Vision)      ="
    echo "=                 by acxcr                       ="
    echo "================================================"
    echo -e "[当前时间: $(date '+%Y-%m-%d %H:%M:%S')]"
    echo ""
    echo "请选择要执行的操作:"
    echo ""
    echo "1. 【证书管理】安装 Acme.sh 并申请/续签证书"
    echo "2. 【伪装站点】安装 Nginx 并配置跳转"
    echo "3. 【核心服务】安装 Xray 并配置 VLESS + Vision"
    echo "4. 【一键卸载】清理本机部署环境"
    echo "5. 【退出脚本】"
    echo ""
    echo "-------------------------------------------------"
    
    read -p "请输入选项 [1-5]: " option
    case $option in
        1) manage_certificate; press_any_key ;;
        2) configure_nginx; press_any_key ;;
        3) install_xray; press_any_key ;;
        4) uninstall; press_any_key ;;
        5) exit 0 ;;
        *) echo -e "${RED}无效选项，请输入 1-5 之间的数字。${NC}"; sleep 2 ;;
    esac
}

# 脚本主入口
if [[ $(id -u) -ne 0 ]]; then
   error_exit "此脚本必须以 root 用户身份运行。"
fi

while true; do
    main_menu
done
