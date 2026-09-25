#!/bin/bash
#
# 订阅中枢一键部署/管理脚本
# 组件: sing-box-subscribe(本机5000) + cloudflared隧道(出站连接, 公网可达)
# 状态: /etc/sing-box/hub.conf (转移/重装只需备份此文件)
#
# 用法: hub.sh            # 交互式部署(已有hub.conf则进入管理)
#       hub.sh add-peer   # 添加WG peer(生成密钥+输出ROS CLI+同步Seafile)
#       hub.sh list-peers # 列出所有WG peer
#       hub.sh del-peer <名称>  # 删除WG peer
#       hub.sh ros-export  # 批量输出所有peer的ROS CLI(重装ROS时粘贴)
#       hub.sh links      # 输出四平台订阅链接
#       hub.sh status     # 组件运行状态
#       hub.sh update     # 更新 sing-box-subscribe
#       hub.sh uninstall  # 卸载全部组件(保留hub.conf)
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

HUB_CONF="/etc/sing-box/hub.conf"
DEFAULTS_FILE="/etc/sing-box/defaults.conf"
SBS_DIR="/opt/sing-box-subscribe"
SBS_SERVICE="sing-box-subscribe"
CFD_SERVICE="cloudflared"
SBS_URL="http://127.0.0.1:5000"
WG_DETOUR_DEFAULT="direct"
WG_MTU_DEFAULT=1280
WG_SUBNET_PREFIX="10.10.10"    # 隧道地址前缀, 自动分配时用

# 模板默认指向本fork(1.13协议); macos.json 需先推送到fork
GITHUB_RAW="https://gh-proxy.com/https://raw.githubusercontent.com/jasondingy2k/sbshell/refs/heads/main"
DEFAULT_TEMPLATE_DEBIAN_TPROXY="${GITHUB_RAW}/config_template/debian.json"
DEFAULT_TEMPLATE_WINDOWS="${GITHUB_RAW}/config_template/windows.json"
DEFAULT_TEMPLATE_MAC="${GITHUB_RAW}/config_template/macos.json"
DEFAULT_TEMPLATE_MOBILE="${GITHUB_RAW}/config_template/mobile.json"
SBS_GIT="https://ghfast.top/https://github.com/Toperlock/sing-box-subscribe"

# --- 状态读写 ---
load_conf() {
    if [ -f "$HUB_CONF" ]; then
        # 只 source key=value 行, 跳过 peer 段(| 分隔)和注释
        grep -E '^[A-Z_]+=' "$HUB_CONF" | source /dev/stdin
        return 0
    fi
    return 1
}

save_conf() {
    # 保留已有的 WG peer 段 (| 分隔行), 只重写 key=value 段
    local peers_section=""
    if [ -f "$HUB_CONF" ]; then
        peers_section=$(grep '^[^#H][^=]*|' "$HUB_CONF" 2>/dev/null || true)
    fi
    sudo tee "$HUB_CONF" > /dev/null <<EOF
# 订阅中枢配置 (重装/转移: 备份此一个文件 + hub.sh 脚本即可)
# --- 核心配置 (key=value) ---
HUB_SUB_URL="$HUB_SUB_URL"
HUB_DOMAIN="$HUB_DOMAIN"
HUB_TUNNEL_TOKEN="$HUB_TUNNEL_TOKEN"
HUB_TEMPLATE_DEBIAN_TPROXY="$HUB_TEMPLATE_DEBIAN_TPROXY"
HUB_TEMPLATE_WINDOWS="$HUB_TEMPLATE_WINDOWS"
HUB_TEMPLATE_MAC="$HUB_TEMPLATE_MAC"
# Seafile 分发 (双轨: 设备可直连转换器, 也可拉 Seafile 静态链接)
SEAFILE_URL="$SEAFILE_URL"
SEAFILE_TOKEN="$SEAFILE_TOKEN"
SEAFILE_REPO="$SEAFILE_REPO"
SEAFILE_DIR="$SEAFILE_DIR"

# --- WG peers (| 分隔, hub.sh add-peer 追加; 勿手动编辑格式) ---
# name|tmpl|addr|server|port|priv|pub|psk|allowed
${peers_section}
EOF
    sudo chmod 600 "$HUB_CONF"
    echo -e "${GREEN}配置已写入 $HUB_CONF${NC}"
}

prompt_conf() {
    echo -e "${CYAN}--- 订阅中枢核心配置 ---${NC}"
    read -rp "请输入CF聚合订阅链接: " HUB_SUB_URL
    while [ -z "$HUB_SUB_URL" ]; do
        echo -e "${RED}订阅链接不能为空${NC}"
        read -rp "请输入CF聚合订阅链接: " HUB_SUB_URL
    done

    read -rp "请输入隧道公共域名 (如 sub.example.com, 回车稍后配置): " HUB_DOMAIN

    echo -e "${CYAN}cloudflared 隧道 token (Cloudflare Zero Trust -> Networks -> Tunnels -> 创建后复制):${NC}"
    read -rp "粘贴 token (无域名/暂不部署隧道可留空): " HUB_TUNNEL_TOKEN

    echo -e "${YELLOW}模板URL直接回车使用默认(fork仓库1.13版):${NC}"
    read -rp "Debian TProxy模板 [$DEFAULT_TEMPLATE_DEBIAN_TPROXY]: " v
    HUB_TEMPLATE_DEBIAN_TPROXY="${v:-$DEFAULT_TEMPLATE_DEBIAN_TPROXY}"
    read -rp "Windows模板 [$DEFAULT_TEMPLATE_WINDOWS]: " v
    HUB_TEMPLATE_WINDOWS="${v:-$DEFAULT_TEMPLATE_WINDOWS}"
    read -rp "macOS模板 [$DEFAULT_TEMPLATE_MAC]: " v
    HUB_TEMPLATE_MAC="${v:-$DEFAULT_TEMPLATE_MAC}"
    read -rp "Mobile模板 [$DEFAULT_TEMPLATE_MOBILE]: " v
    HUB_TEMPLATE_MOBILE="${v:-$DEFAULT_TEMPLATE_MOBILE}"
    echo -e "${YELLOW}WG peer 配置请用 hub.sh add-peer 单独管理${NC}"

    echo -e "${CYAN}--- Seafile 分发 (可选, 回车跳过则仅用cloudflared直连) ---${NC}"
    read -rp "Seafile 地址 (如 https://seafile.example.com:8016, 留空跳过): " SEAFILE_URL
    if [ -n "$SEAFILE_URL" ]; then
        read -rp "Seafile Token: " SEAFILE_TOKEN
        read -rp "Seafile 库ID: " SEAFILE_REPO
        read -rp "Seafile 目标目录 [/singbox]: " SEAFILE_DIR; SEAFILE_DIR="${SEAFILE_DIR:-/singbox}"
    fi
}

# --- 组件部署 ---
install_deps() {
    echo -e "${CYAN}安装基础依赖(python3-venv git curl)...${NC}"
    sudo apt-get update -qq
    sudo apt-get install -yq python3-venv git curl
}

install_sbs() {
    if systemctl is-active --quiet "$SBS_SERVICE"; then
        echo -e "${YELLOW}sing-box-subscribe 已在运行，跳过安装${NC}"
        return 0
    fi
    echo -e "${CYAN}部署 sing-box-subscribe 到 $SBS_DIR ...${NC}"
    if [ ! -d "$SBS_DIR" ]; then
        sudo git clone --depth 1 "$SBS_GIT" "$SBS_DIR" || {
            echo -e "${RED}克隆失败，尝试直连...${NC}"
            sudo git clone --depth 1 "https://github.com/Toperlock/sing-box-subscribe" "$SBS_DIR"
        }
    fi
    sudo python3 -m venv "${SBS_DIR}/venv"
    sudo "${SBS_DIR}/venv/bin/pip" install --quiet -r "${SBS_DIR}/requirements.txt" || {
        echo -e "${YELLOW}默认源失败，使用清华镜像重试...${NC}"
        sudo "${SBS_DIR}/venv/bin/pip" install --quiet -i https://pypi.tuna.tsinghua.edu.cn/simple -r "${SBS_DIR}/requirements.txt"
    }

    sudo tee /etc/systemd/system/${SBS_SERVICE}.service > /dev/null <<EOF
[Unit]
Description=sing-box-subscribe converter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SBS_DIR
ExecStart=$SBS_DIR/venv/bin/python api/app.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SBS_SERVICE"
    sleep 2
    if curl -sf --max-time 5 "$SBS_URL/" > /dev/null; then
        echo -e "${GREEN}sing-box-subscribe 运行正常 ($SBS_URL)${NC}"
    else
        echo -e "${RED}sing-box-subscribe 启动异常，请查 journalctl -u $SBS_SERVICE${NC}"
        return 1
    fi
}

install_cloudflared() {
    if systemctl is-active --quiet "$CFD_SERVICE"; then
        echo -e "${YELLOW}cloudflared 已在运行，跳过安装${NC}"
        return 0
    fi
    if [ -z "$HUB_TUNNEL_TOKEN" ]; then
        echo -e "${YELLOW}未提供隧道token，跳过 cloudflared (可用 hub.sh 重新配置)${NC}"
        return 0
    fi
    echo -e "${CYAN}安装 cloudflared ...${NC}"
    if ! command -v cloudflared &> /dev/null; then
        sudo mkdir -p --mode=0755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg > /dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list > /dev/null
        sudo apt-get update -qq
        sudo apt-get install -yq cloudflared
    fi
    echo -e "${CYAN}注册隧道服务...${NC}"
    sudo cloudflared service install "$HUB_TUNNEL_TOKEN"
    sleep 3
    if systemctl is-active --quiet "$CFD_SERVICE"; then
        echo -e "${GREEN}cloudflared 隧道已连接${NC}"
    else
        echo -e "${RED}cloudflared 启动异常，请检查 token 与 journalctl -u $CFD_SERVICE${NC}"
        return 1
    fi
}

# --- 链接生成 ---
build_url() {  # $1=模板URL
    echo "https://${HUB_DOMAIN}/config/${HUB_SUB_URL}&file=${1}"
}

show_links() {
    if ! load_conf; then
        echo -e "${RED}尚未配置，请先运行 hub.sh 完成部署${NC}"
        exit 1
    fi
    echo ""
    echo -e "${CYAN}================= 订阅链接 =================${NC}"
    echo -e "${GREEN}Debian(TProxy, 本机sbshell后端): ${NC}$SBS_URL/config/${HUB_SUB_URL}&file=${HUB_TEMPLATE_DEBIAN_TPROXY}"
    [ -n "$HUB_DOMAIN" ] && {
        echo -e "${GREEN}Windows: ${NC}$(build_url "$HUB_TEMPLATE_WINDOWS")"
        echo -e "${GREEN}macOS(SFM): ${NC}$(build_url "$HUB_TEMPLATE_MAC")"
        echo -e "${GREEN}Mobile(SFA): ${NC}$(build_url "$HUB_TEMPLATE_MOBILE")"
    } || echo -e "${YELLOW}未配置域名，仅生成局域网链接${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo -e "${YELLOW}提示: Debian 本机已自动写入 defaults.conf 后端地址${NC}"
}

# --- 生成与同步 (吸收 update_sb_config.sh 的 jq 注入, 修掉6个问题) ---
# 把逗号分隔字符串转为 jq 数组: "a,b" -> ["a","b"]
csv_to_jq_array() {
    local s="$1"
    if [ -z "$s" ]; then echo "[]"; return; fi
    echo "$s" | awk -F',' 'BEGIN{OFS="\",\""} {for(i=1;i<=NF;i++){$i=$i}; print "[\"" $0 "\"]"}' | sed 's/","/","/g'
}

# 注入 WG endpoint: $1=输入文件 $2=addr $3=server $4=port $5=priv $6=pub $7=psk $8=allowed_ips
inject_wg_endpoint() {
    local infile="$1" addr="$2" server="$3" port="$4" priv="$5" pub="$6" psk="$7" allowed="$8"
    [ -z "$addr" ] && { cp "$infile" "${infile}.wg"; return 0; }

    local allowed_arr
    allowed_arr=$(csv_to_jq_array "$allowed")

    local peer
    peer=$(jq -n \
        --arg addr "$server" --arg port "$port" --arg pub "$pub" --arg psk "$psk" \
        --argjson allowed "$allowed_arr" '
        {
            "address": $addr,
            "port": ($port|tonumber),
            "public_key": $pub,
            "allowed_ips": $allowed,
            "persistent_keepalive_interval": 25
        }
        + (if $psk != "" then {"pre_shared_key": $psk} else {} end)
    ')

    jq --arg addr "$addr" --arg priv "$priv" --arg detour "${WG_DETOUR:-$WG_DETOUR_DEFAULT}" \
       --arg wgport "$port" --argjson allowed "$allowed_arr" --argjson peer "$peer" '
        .route.rules = ([
            {"network":"udp","port":($wgport|tonumber),"outbound":"direct"},
            {"ip_cidr":$allowed,"outbound":"🛡️ wg-ep"}
        ] + (.route.rules // []))
        | .endpoints = ([{
            "type": "wireguard",
            "tag": "🛡️ wg-ep",
            "detour": $detour,
            "mtu": '"$WG_MTU_DEFAULT"',
            "address": [$addr],
            "private_key": $priv,
            "peers": [$peer]
        }] + (.endpoints // []))
        | .outbounds = ([{
            "type": "direct",
            "tag": "direct",
            "network_strategy": "default"
        }] + (.outbounds // []))
    ' "$infile" > "${infile}.wg"
}

# 只输出 peer 行 (| 分隔, 排除 key=value 和注释)
peers_lines() {
    [ -f "$HUB_CONF" ] && grep -E '^[a-zA-Z0-9_-]+\|' "$HUB_CONF" 2>/dev/null || true
}

# Seafile 覆盖上传: $1=本地文件 $2=远端文件名
upload_seafile() {
    local file="$1" name="$2"
    [ -z "$SEAFILE_URL" ] && return 0   # 未配置Seafile则跳过
    # 每次现取上传链接 (修: 不复用, 避免时效bug)
    local upload_link
    upload_link=$(curl -sf --max-time 15 -H "Authorization: Token $SEAFILE_TOKEN" \
        "${SEAFILE_URL}/api2/repos/${SEAFILE_REPO}/upload-link/?p=${SEAFILE_DIR}" | tr -d '"')
    if [ -z "$upload_link" ]; then
        echo -e "${RED}  ❌ Seafile 上传链接获取失败 ($name)${NC}"
        return 1
    fi
    if curl -sf --max-time 30 -H "Authorization: Token $SEAFILE_TOKEN" \
         -F file=@"$file" -F parent_dir="$SEAFILE_DIR" -F replace=1 \
         "$upload_link" > /dev/null; then
        echo -e "${GREEN}  ✅ $name → Seafile 同步完成${NC}"
    else
        echo -e "${RED}  ❌ $name Seafile 上传失败${NC}"
        return 1
    fi
}

# --- WG peer 管理 (wg-peers.conf: name|tmpl|addr|server|port|priv|pub|psk|allowed) ---

ensure_wg_tools() {
    command -v wg >/dev/null 2>&1 || {
        echo -e "${CYAN}安装 wireguard-tools (用于生成密钥)...${NC}"
        sudo apt-get install -yq wireguard-tools
    }
}

gen_wg_keypair() {
    ensure_wg_tools
    local priv pub
    priv=$(wg genkey)
    pub=$(echo "$priv" | wg pubkey)
    echo "$priv $pub"
}

gen_wg_psk() {
    ensure_wg_tools
    wg genpsk
}

next_tunnel_ip() {
    local max=1   # 从 .2 起步, .1 留给 RouterOS 接口
    local found
    found=$(peers_lines | awk -F'|' '{n=split($3,a,"."); split(a[n],b,"/"); print b[1]}' | sort -n | tail -1)
    [ -n "$found" ] && [ "$found" -ge "$max" ] && max="$found"
    echo "${WG_SUBNET_PREFIX}.$((max + 1))/32"
}

# 从旧 hub.conf 的 WG_MOBILE_*/WG_WINDOWS_* 迁移为 peer 段 (追加到同文件)
migrate_wg_conf() {
    # 已有 peer 段则跳过
    [ -n "$(peers_lines)" ] && return 0
    load_conf || return 0
    [ -z "$WG_MOBILE_ADDRESS" ] && [ -z "$WG_WINDOWS_ADDRESS" ] && return 0
    echo -e "${CYAN}迁移旧 WG 配置为 peer 段...${NC}"
    {
        echo "mobile|${HUB_TEMPLATE_MOBILE}|${WG_MOBILE_ADDRESS}|${WG_MOBILE_SERVER}|${WG_MOBILE_PORT}|${WG_MOBILE_PRIVATE_KEY}|${WG_MOBILE_PUBLIC_KEY}|${WG_MOBILE_PSK}|${WG_MOBILE_ALLOWED_IPS}"
        echo "windows|${HUB_TEMPLATE_WINDOWS}|${WG_WINDOWS_ADDRESS}|${WG_WINDOWS_SERVER}|${WG_WINDOWS_PORT}|${WG_WINDOWS_PRIVATE_KEY}|${WG_WINDOWS_PUBLIC_KEY}|${WG_WINDOWS_PSK}|${WG_WINDOWS_ALLOWED_IPS}"
    } | sudo tee -a "$HUB_CONF" > /dev/null
    echo -e "${GREEN}迁移完成${NC}"
}

do_add_peer() {
    load_conf || { echo -e "${RED}请先 hub.sh 完成核心配置${NC}"; exit 1; }
    migrate_wg_conf

    echo -e "${CYAN}========== 添加 WG Peer ==========${NC}"
    local name addr server port priv pub psk allowed tmpl
    read -rp "Peer 名称 (如 jason-tablet): " name
    [ -z "$name" ] && { echo -e "${RED}名称不能为空${NC}"; exit 1; }

    peers_lines | grep -q "^${name}|" && { echo -e "${RED}已存在同名 peer${NC}"; exit 1; }
    echo -e "${YELLOW}选择 sing-box 模板:${NC}"
    echo "  1) Mobile  [$DEFAULT_TEMPLATE_MOBILE]"
    echo "  2) Windows [$DEFAULT_TEMPLATE_WINDOWS]"
    echo "  3) macOS   [$DEFAULT_TEMPLATE_MAC]"
    read -rp "选择 [1-3, 默认1]: " tmpl_choice
    case "${tmpl_choice:-1}" in
        2) tmpl="$DEFAULT_TEMPLATE_WINDOWS" ;;
        3) tmpl="$DEFAULT_TEMPLATE_MAC" ;;
        *) tmpl="$DEFAULT_TEMPLATE_MOBILE" ;;
    esac

    # 自动分配隧道地址
    addr=$(next_tunnel_ip)
    echo -e "${CYAN}自动分配隧道地址: ${addr}${NC}"
    read -rp "回车确认或手动输入: " addr_override; addr="${addr_override:-$addr}"

    # WG 服务器 (ROS 接口的公网入口)
    read -rp "WG 服务器地址 [728966.xyz]: " server; server="${server:-728966.xyz}"
    read -rp "WG 端口 [58008]: " port; port="${port:-58008}"

    # 密钥: 生成新密钥对 或 导入已有 peer
    echo -e "${YELLOW}密钥方式: 1) 生成新密钥对(新设备)  2) 导入已有密钥(ROS已配的peer)${NC}"
    read -rp "选择 [1/2, 默认1]: " key_mode
    case "${key_mode:-1}" in
        2)
            echo -e "${CYAN}导入已有 peer (从 ROS 侧获取)${NC}"
            read -rp "  Private Key (设备私钥): " priv
            read -rp "  Public Key  (设备公钥, 即 ROS peer 的 public-key): " pub
            read -rp "  PresharedKey (ROS peer 的 preshared-key, 无则留空): " psk
            ;;
        *)
            echo -e "${CYAN}生成 WG 密钥对...${NC}"
            local keypair
            keypair=$(gen_wg_keypair)
            priv=$(echo "$keypair" | awk '{print $1}')
            pub=$(echo "$keypair" | awk '{print $2}')
            psk=$(gen_wg_psk)
            echo -e "${GREEN}  Private Key: ${priv}${NC}"
            echo -e "${GREEN}  Public Key:  ${pub}${NC}"
            echo -e "${GREEN}  PresharedKey: ${psk}${NC}"
            ;;
    esac
    read -rp "WG allowed_ips [192.168.1.0/24]: " allowed; allowed="${allowed:-192.168.1.0/24}"

    # 保存到 wg-peers.conf
    echo "${name}|${tmpl}|${addr}|${server}|${port}|${priv}|${pub}|${psk}|${allowed}" | sudo tee -a "$HUB_CONF" > /dev/null
    sudo chmod 600 "$HUB_CONF"
    echo -e "${GREEN}✅ Peer ${name} 已保存到 hub.conf${NC}"

    # 导入模式跳过 ROS CLI (ROS 侧已配); 新建模式输出供粘贴
    if [ "${key_mode:-1}" = "1" ]; then
        echo ""
        echo -e "${CYAN}========== RouterOS CLI (复制粘贴到 ROS 终端) ==========${NC}"
        echo "/interface/wireguard/peers add \\"
        echo "  name=${name} \\"
        echo "  interface=wireguard \\"
        echo "  public-key=\"${pub}\" \\"
        echo "  preshared-key=\"${psk}\" \\"
        echo "  allowed-address=${addr} \\"
        echo "  client-address=${addr} \\"
        echo "  responder=yes"
        echo -e "${CYAN}========================================================${NC}"
    fi
    # 立即生成并同步该 peer 的配置
    echo ""
    read -rp "立即生成并同步到 Seafile? (Y/n): " sync_now
    [[ "${sync_now:-Y}" =~ ^[Yy]$ ]] && gen_and_sync_peer "$name"
}

do_list_peers() {
    migrate_wg_conf
    if [ -z "$(peers_lines)" ]; then
        echo -e "${YELLOW}暂无 WG peer${NC}"; return
    fi
    echo -e "${CYAN}========== WG Peers ==========${NC}"
    peers_lines | awk -F'|' 'BEGIN{printf "%-16s %-18s %-20s %-8s\n","名称","隧道地址","服务器","端口"}
    {printf "%-16s %-18s %-20s %-8s\n", $1,$3,$4,$5}'
    echo -e "${CYAN}==============================${NC}"
}

do_del_peer() {
    local name="$1"
    [ -z "$name" ] && { echo -e "${RED}用法: hub.sh del-peer <名称>${NC}"; exit 1; }
    [ -f "$HUB_CONF" ] || { echo -e "${RED}无 hub.conf${NC}"; exit 1; }
    if peers_lines | grep -q "^${name}|"; then
        sudo sed -i "/^${name}|/d" "$HUB_CONF"
        echo -e "${GREEN}✅ 已删除 peer: ${name}${NC}"
        echo -e "${YELLOW}提示: RouterOS 侧的 peer 需手动删除${NC}"
    else
        echo -e "${RED}未找到 peer: ${name}${NC}"
    fi
}

# 批量导出所有 peer 的 ROS CLI (重装ROS时粘贴用)
do_ros_export() {
    migrate_wg_conf
    if [ -z "$(peers_lines)" ]; then
        echo -e "${YELLOW}暂无 WG peer${NC}"; return
    fi
    echo ""
    echo -e "${CYAN}========== RouterOS CLI (全量导出, 粘贴到 ROS 终端) ==========${NC}"
    echo "# 先删除旧 peers (如需):"
    echo "/interface/wireguard/peers remove [find interface=wireguard]"
    echo ""
    echo "# 添加 peers:"
    while IFS='|' read -r name tmpl addr server port priv pub psk allowed; do
        echo "/interface/wireguard/peers add \\"
        echo "  name=${name} \\"
        echo "  interface=wireguard \\"
        echo "  public-key=\"${pub}\" \\"
        if [ -n "$psk" ]; then
            echo "  preshared-key=\"${psk}\" \\"
        fi
        echo "  allowed-address=${addr} \\"
        echo "  client-address=${addr} \\"
        echo "  responder=yes"
        echo ""
    done < <(peers_lines)
    echo "# 防火墙放行 (如尚未配置):"
    echo "/ip/firewall/filter/add chain=input action=accept protocol=udp dst-port=${port:-58008} comment=\"WireGuard UDP\" place-before=0"
    echo -e "${CYAN}==============================================================${NC}"
}

# --- 生成与同步 ---

# 生成并同步单个 peer: $1=peer名
gen_and_sync_peer() {
    local name="$1"
    local line
    line=$(peers_lines | grep "^${name}|") || { echo -e "${RED}未找到 peer: ${name}${NC}"; return 1; }
    IFS='|' read -r p_name p_tmpl p_addr p_server p_port p_priv p_pub p_psk p_allowed <<< "$line"

    echo -e "${CYAN}[${p_name}] 转换中...${NC}"
    if ! curl -sf --max-time 60 "${SBS_URL}/config/${HUB_SUB_URL}&file=${p_tmpl}" -o "$out" || [ ! -s "$out" ]; then
        echo -e "${RED}  ❌ 转换请求失败${NC}"; return 1
    fi
    inject_wg_endpoint "$out" "$p_addr" "$p_server" "$p_port" "$p_priv" "$p_pub" "$p_psk" "$p_allowed"
    if ! sing-box check -c "${out}.wg" 2>/dev/null; then
        echo -e "${YELLOW}  ⚠️ 校验未通过, 跳过上传保留旧版${NC}"
        sing-box check -c "${out}.wg" 2>&1 | head -3
        return 1
    fi
    upload_seafile "${out}.wg" "${p_name}.json"
    rm -f "$out" "${out}.wg"
}

do_sync() {
    if ! load_conf; then
        echo -e "${RED}尚未配置，请先运行 hub.sh 完成部署${NC}"; exit 1
    fi
    migrate_wg_conf
    echo -e "${CYAN}========== 生成并同步 (VPS/模板变化即生效, 无定时器) ==========${NC}"
    if [ -z "$(peers_lines)" ]; then
        echo -e "${YELLOW}无 WG peer, 跳过 (用 hub.sh add-peer 添加)${NC}"
    else
        while IFS='|' read -r name rest; do
            gen_and_sync_peer "$name"
        done < <(peers_lines)
    fi
    echo -e "${CYAN}==============================================================${NC}"
    [ -n "$HUB_DOMAIN" ] && show_links
}

# --- 主流程 ---
main() {
    local action="${1:-install}"

    case "$action" in
        add-peer)  do_add_peer; exit 0 ;;
        list-peers) do_list_peers; exit 0 ;;
        del-peer)  do_del_peer "${2:-}"; exit 0 ;;
        ros-export) do_ros_export; exit 0 ;;
        status)
            systemctl status "$SBS_SERVICE" --no-pager 2>/dev/null | head -5
            systemctl status "$CFD_SERVICE" --no-pager 2>/dev/null | head -5
            exit 0 ;;
        update)
            sudo systemctl stop "$SBS_SERVICE"
            sudo git -C "$SBS_DIR" pull
            sudo "${SBS_DIR}/venv/bin/pip" install --quiet -r "${SBS_DIR}/requirements.txt"
            sudo systemctl start "$SBS_SERVICE"
            echo -e "${GREEN}更新完成${NC}"
            exit 0 ;;
        uninstall)
            sudo systemctl disable --now "$SBS_SERVICE" "$CFD_SERVICE" 2>/dev/null
            sudo rm -f /etc/systemd/system/${SBS_SERVICE}.service
            sudo cloudflared service uninstall 2>/dev/null
            sudo rm -rf "$SBS_DIR"
            echo -e "${GREEN}已卸载组件 (hub.conf 保留)${NC}"
            exit 0 ;;
    esac

    # install 流程
    if load_conf; then
        echo -e "${YELLOW}检测到已有配置 $HUB_CONF${NC}"
        read -rp "是否重新配置? (y/N): " reconf
        [[ "$reconf" =~ ^[Yy]$ ]] && { prompt_conf; save_conf; }
    else
        prompt_conf
        save_conf
    fi

    install_deps
    install_sbs
    install_cloudflared

    # Debian 本机后端指向转换器, sbshell 配置更新走同一链路
    if [ -f "$DEFAULTS_FILE" ]; then
        sudo sed -i "s|^BACKEND_URL=.*|BACKEND_URL=$SBS_URL|" "$DEFAULTS_FILE"
        echo -e "${GREEN}defaults.conf 后端已指向 $SBS_URL${NC}"
    else
        echo -e "${YELLOW}defaults.conf 不存在，sbshell 初始化后再次运行本脚本即可自动写入${NC}"
    fi

    # 端到端自检: 本机实时转换一次
    echo -e "${CYAN}端到端自检(实时转换一次 TProxy 模板)...${NC}"
    if curl -sf --max-time 60 "$SBS_URL/config/${HUB_SUB_URL}&file=${HUB_TEMPLATE_DEBIAN_TPROXY}" -o /tmp/hub_check.json; then
        if sing-box check -c /tmp/hub_check.json 2>/dev/null; then
            echo -e "${GREEN}转换产物校验通过${NC}"
        else
            echo -e "${YELLOW}转换产物语法告警(可能缺少订阅节点, 属正常空订阅现象)${NC}"
        fi
        rm -f /tmp/hub_check.json
    else
        echo -e "${YELLOW}自检请求失败: 检查订阅链接可达性${NC}"
    fi

    [ -n "$HUB_DOMAIN" ] && echo -e "${YELLOW}别忘了在 CF Tunnel 的 Public Hostname 把 ${HUB_DOMAIN} 指到 http://localhost:5000${NC}"
    [ -n "$SEAFILE_URL" ] && echo -e "${YELLOW}如需生成mobile/windows配置并同步Seafile: hub.sh sync${NC}"
    show_links
}

main "$@"
