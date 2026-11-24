#!/usr/bin/env bash
# portalctl.sh - manage the PS Portal high-bitrate bidirectional NAT relay (Docker macvlan + systemd).
# Run as a user in the docker group; commands that need root call sudo themselves.
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$DIR"

BIN_LINK=/usr/local/bin/portalctl
ME=$0
[ "$(readlink -f "$(command -v portalctl 2>/dev/null || true)")" = "$DIR/portalctl.sh" ] && ME=portalctl

UNIT=portal-nat-relay
UNIT_FILE=/etc/systemd/system/$UNIT.service
PROJECT=portal-nat
STATUS_JSON=/run/portal-linux-native/status.json

die()  { echo "portalctl: $*" >&2; exit 1; }
info() { echo "==> $*"; }

confirm() {   # $1 question, $2 default y|n
    local a hint=y/N
    [ "${2:-n}" = y ] && hint=Y/n
    read -r -p "$1 [$hint] " a
    a=${a:-${2:-n}}
    [[ $a =~ ^[Yy] ]]
}

is_ipv4() { python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$1" 2>/dev/null; }

ask_ip() {    # $1 prompt, $2 default; prompts until a valid IPv4 is entered
    local v
    while :; do
        read -r -p "$1${2:+ [$2]}: " v || die "输入已中断"
        v=${v:-${2:-}}
        is_ipv4 "$v" && { echo "$v"; return 0; }
        echo "  请输入有效的 IPv4 地址，例如 192.168.1.20" >&2
    done
}

load_env() {
    [ -f .env ] || die ".env 不存在，请先运行: $ME configure"
    set -a; . ./.env; set +a
    : "${LAN_PARENT:?LAN_PARENT 未设置}" "${RELAY_IP:?RELAY_IP 未设置}"
    GRO_FEATURES=${GRO_FEATURES:-"gro rx-gro-hw"}
    ETHTOOL=$(command -v ethtool || echo /usr/sbin/ethtool)
}

dc() { docker compose "$@"; }

running_ids() { docker ps -q --filter "label=com.docker.compose.project=$PROJECT"; }

need_stopped() {
    [ -z "$(running_ids)" ] || die "中继容器正在运行（常驻服务或其他测试）。先执行: $ME stop"
}

# ethtool -k uses long names; map the short aliases we accept in GRO_FEATURES.
long_name() { case "$1" in gro) echo generic-receive-offload ;; lro) echo large-receive-offload ;; *) echo "$1" ;; esac; }

gro_check() {
    local f state bad=0
    for f in $GRO_FEATURES; do
        state=$("$ETHTOOL" -k "$LAN_PARENT" | awk -v k="$(long_name "$f"):" '$1==k {print $2}')
        if [ "$state" != off ]; then echo "  $LAN_PARENT $f = ${state:-unknown}"; bad=1; fi
    done
    [ "$bad" = 0 ] || die "宿主网卡接收卸载未关闭，中继会拒绝启动。请先运行: $ME gro off"
}

gro_set() {
    local args=() f
    for f in $GRO_FEATURES; do args+=("$f" "$1"); done
    info "sudo ethtool -K $LAN_PARENT ${args[*]}"
    sudo "$ETHTOOL" -K "$LAN_PARENT" "${args[@]}"
}

print_status_line() {
    python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    sys.exit(0)
c, t = s["counts"], s["ps5_telemetry"]
tgt = t.get("last_target_bps")
print(s["time"][11:19], s["state"], s.get("mode"), "profile", s.get("profile"),
      "| in %.1f Mbps out %.2f Mbps" % (s["forwarded_mbps"]["in"], s["forwarded_mbps"]["out"]),
      "| PS5 target", ("%.1f Mbps" % (tgt / 1e6)) if tgt else "-",
      "| startups modified", c.get("unique_modified_startups", 0),
      "| drops", s["capture_loss"]["socket_drops"], "errors", len(s.get("errors", [])), flush=True)
'
}

print_summary() {
    python3 -c '
import json, sys
raw = sys.stdin.read()
start = raw.find("{")
if start < 0:
    print(raw); sys.exit(0)
s = json.loads(raw[start:])
c, t = s.get("counts", {}), s.get("ps5_telemetry", {})
print("state:", s.get("state"), "| mode:", s.get("mode"), "| uptime: %.0fs" % s.get("uptime_seconds", 0))
print("forwarded in/out bytes:", c.get("forwarded_bytes_in", 0), "/", c.get("forwarded_bytes_out", 0))
print("BANG:", c.get("ps5_BANG", 0), "STREAMINFO:", c.get("ps5_STREAMINFO", 0), "startups modified:", c.get("unique_modified_startups", 0))
print("PS5 last target bps:", t.get("last_target_bps"), "| high target confirmed:", t.get("ps5_high_target_confirmed"))
print("drops:", s.get("drop_and_send_errors"), s.get("capture_loss", {}).get("socket_drops"))
print("recovery:", s.get("recovery", {}).get("state"), "| errors:", s.get("errors"))
'
}

cmd_configure() {
    local def_if def_gw def_subnet relay_ip ps5_ip portal_ip profile relay_mac ps5_mac portal_mac ip
    [ -f .env ] && { set -a; . ./.env; set +a; }
    need_stopped
    def_if=${LAN_PARENT:-$(ip route show default | awk '{print $5; exit}')}
    def_gw=${LAN_GATEWAY:-$(ip route show default | awk '{print $3; exit}')}
    def_subnet=${LAN_SUBNET:-$(python3 -c "import ipaddress,sys;print(ipaddress.ip_interface(sys.argv[1]).network)" \
        "$(ip -o -f inet addr show "$def_if" | awk '{print $4; exit}')")}
    read -r -p "宿主有线网卡 [$def_if]: " ip; LAN_PARENT=${ip:-$def_if}
    read -r -p "局域网网段 [$def_subnet]: " ip; LAN_SUBNET=${ip:-$def_subnet}
    read -r -p "网关 [$def_gw]: " ip; LAN_GATEWAY=${ip:-$def_gw}
    ps5_ip=$(ask_ip "PS5 的 IP（建议在路由器里固定）" "${PS5_IP:-}")
    portal_ip=$(ask_ip "PS Portal 的 IP（建议在路由器里固定）" "${PORTAL_IP:-}")
    relay_ip=$(ask_ip "中继容器使用的固定 IP（DHCP 池外的空闲地址）" "${RELAY_IP:-}")
    profile=${PORTAL_PROFILE:-100}
    case "$profile" in 65|100|150|200) ;; *) profile=100 ;; esac
    python3 - "$LAN_SUBNET" "$ps5_ip" "$portal_ip" "$relay_ip" <<'PY' || die "IP 设置有误"
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
ips = sys.argv[2:]
bad = [ip for ip in ips if ipaddress.ip_address(ip) not in net]
if bad:
    sys.exit("不在网段 %s 内: %s" % (net, ", ".join(bad)))
if len(set(ips)) != len(ips):
    sys.exit("PS5、Portal、中继的 IP 不能重复")
PY
    echo "  码率档位: $profile Mbps（安装后可用 portalctl profile 切换）"

    if ping -c2 -W1 "$relay_ip" >/dev/null 2>&1; then die "$relay_ip 已有设备响应，请换一个空闲 IP"; fi
    # Locally administered, deterministic MAC derived from the relay IP (the baseline receipt is bound to it).
    relay_mac=$(python3 -c "import sys;print('02:42:'+':'.join('%02x'%int(o) for o in sys.argv[1].split('.')))" "$relay_ip")

    info "解析 PS5 / Portal 的 MAC（两台设备都必须处于唤醒并联网状态）"
    resolve_mac() {
        local m
        for _ in 1 2 3 4 5; do
            ping -c1 -W1 "$1" >/dev/null 2>&1 || true
            m=$(ip neigh show "$1" dev "$LAN_PARENT" | awk '/lladdr/ {print $5; exit}')
            [ -n "$m" ] && { echo "$m"; return 0; }
            sleep 1
        done
        return 1
    }
    ps5_mac=$(resolve_mac "$ps5_ip") || die "无法解析 PS5 ($ps5_ip) 的 MAC，请确认 PS5 已开机"
    portal_mac=$(resolve_mac "$portal_ip") || die "无法解析 Portal ($portal_ip) 的 MAC，请唤醒 Portal 并连上 Wi-Fi"
    echo "  PS5    $ps5_ip  $ps5_mac"
    echo "  Portal $portal_ip  $portal_mac"
    echo "  Relay  $relay_ip  $relay_mac"

    cat > .env <<EOF
LAN_PARENT=$LAN_PARENT
LAN_SUBNET=$LAN_SUBNET
LAN_GATEWAY=$LAN_GATEWAY
RELAY_IP=$relay_ip
RELAY_MAC=$relay_mac
PS5_IP=$ps5_ip
PORTAL_IP=$portal_ip
PORTAL_PROFILE=$profile
GRO_FEATURES="${GRO_FEATURES:-gro rx-gro-hw}"
EOF
    mkdir -p data/config data/state
    chmod 700 data
    cat > data/config/config.json <<EOF
{
  "network": {"interface": "eth0", "ps5_ip": "$ps5_ip", "portal_ip": "$portal_ip"},
  "profile": "$profile",
  "ps5_mac": "$ps5_mac",
  "portal_mac": "$portal_mac"
}
EOF
    chmod 600 data/config/config.json
    info "已写入 .env 和 data/config/config.json"
    echo "如果 IP/MAC/网卡有变化，需要重新执行 baseline 和 accept（档位变化不需要）。"
    if systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then
        echo "已安装 systemd 服务：网卡名变化时请重新运行 $ME install。"
    fi
}

cmd_install() {
    [ -f .env ] || die "尚未配置。首次部署请运行: $ME setup"
    load_env
    [ -f data/state/baseline-accepted.json ] || die "还没有 baseline 确认记录。首次部署请运行: $ME setup"
    local tmp
    tmp=$(mktemp)
    local off_args="" on_args="" f
    for f in $GRO_FEATURES; do off_args+=" $f off"; on_args+=" $f on"; done
    cat > "$tmp" <<EOF
[Unit]
Description=PS Portal high-bitrate bidirectional NAT relay (Docker macvlan)
Documentation=file://$DIR/README.md
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$DIR
# The relay refuses to start while receive offloads are on; macvlan inherits them from the parent NIC.
ExecStartPre=$ETHTOOL -K $LAN_PARENT$off_args
ExecStart=/usr/bin/docker compose up -d --wait --wait-timeout 90
# 'down' gives the relay up to 45 s to repair the Portal's ARP entry before removal.
ExecStop=/usr/bin/docker compose down
ExecStopPost=-$ETHTOOL -K $LAN_PARENT$on_args
TimeoutStartSec=180
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF
    info "安装 $UNIT_FILE"
    sudo install -m 0644 "$tmp" "$UNIT_FILE"
    rm -f "$tmp"
    sudo systemctl daemon-reload
    if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
        sudo systemctl enable "$UNIT"
        echo "服务已在运行，未重启（unit 改动在下次 restart 或开机时生效）。"
    else
        need_stopped
        sudo systemctl enable --now "$UNIT"
    fi
    install_cli
    ME=portalctl
    cmd_status
    print_usage_hints
}

cmd_uninstall() {
    info "停止并移除 systemd 服务（会执行 docker compose down 并恢复网卡 GRO）"
    sudo systemctl disable --now "$UNIT" 2>/dev/null || true
    sudo rm -f "$UNIT_FILE"
    sudo systemctl daemon-reload
    if [ "$(readlink -f "$BIN_LINK" 2>/dev/null)" = "$DIR/portalctl.sh" ]; then sudo rm -f "$BIN_LINK"; fi
    sudo rm -f /usr/share/bash-completion/completions/portalctl /etc/bash_completion.d/portalctl
    echo "已卸载（服务、portalctl 命令和补全）。配置、baseline 记录和镜像保留在 $DIR 与本地 Docker 中。"
}

cmd_status() {
    load_env
    echo "--- systemd"
    echo "enabled: $(systemctl is-enabled "$UNIT" 2>/dev/null || true)"
    systemctl is-active "$UNIT" 2>/dev/null | sed 's/^/active:  /' || true
    echo "--- 网卡 $LAN_PARENT"
    "$ETHTOOL" -k "$LAN_PARENT" | grep -E '^(generic-receive-offload|large-receive-offload|rx-gro-hw|rx-gro-list):' | sed 's/^/  /'
    echo "--- 容器"
    docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '  {{.Names}}  {{.Status}}'
    local id
    id=$(running_ids | head -1)
    if [ -n "$id" ]; then
        echo "--- 中继"
        docker exec "$id" cat "$STATUS_JSON" 2>/dev/null | print_status_line || echo "  (status.json 尚未生成)"
    fi
}

cmd_monitor() {
    local secs=${1:-0} id end
    id=$(running_ids | head -1)
    [ -n "$id" ] || die "没有正在运行的中继容器"
    info "每 2 秒采样一次（Ctrl+C 退出）。in = PS5→Portal 实际视频码率"
    end=$(( $(date +%s) + secs ))
    while [ "$secs" = 0 ] || [ "$(date +%s)" -lt "$end" ]; do
        docker exec "$id" cat "$STATUS_JSON" 2>/dev/null | print_status_line || break
        sleep 2
    done
}

foreground() {
    # $1 = mode, rest = args. Foreground runs share the service's fixed IP, so the service must be stopped.
    load_env; need_stopped; gro_check
    local out
    out=$(mktemp)
    trap 'echo; info "正在停止，等待中继修复 ARP..."; docker ps -q --filter "label=com.docker.compose.project=$PROJECT" | xargs -r docker stop -t 45 >/dev/null' INT
    dc run --rm -T relay "$@" < /dev/null | tee "$out" | grep -v '^[ {}\[\]"]' || true
    trap - INT
    print_summary < "$out"
    rm -f "$out"
}

cmd_accept() {
    load_env; need_stopped
    dc run --rm -T relay accept-baseline \
        "${1:-User verified clean Portal picture and controls during macvlan NAT baseline on $(date -I).}" < /dev/null
}

completion_dir() {
    if [ -d /usr/share/bash-completion/completions ]; then echo /usr/share/bash-completion/completions
    else echo /etc/bash_completion.d; fi
}

print_completion() {
    cat <<'EOF'
# bash completion for portalctl (PS Portal high-bitrate NAT relay)
_portalctl() {
    local cur=${COMP_WORDS[COMP_CWORD]}
    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=($(compgen -W "setup configure build gro preflight baseline accept try install uninstall start stop restart status profile monitor logs repair-arp completion help" -- "$cur"))
    elif [ "$COMP_CWORD" -eq 2 ]; then
        case ${COMP_WORDS[1]} in
            gro)      COMPREPLY=($(compgen -W "off on status" -- "$cur")) ;;
            profile)  COMPREPLY=($(compgen -W "65 100 150 200" -- "$cur")) ;;
            baseline) COMPREPLY=($(compgen -W "180" -- "$cur")) ;;
            try)      COMPREPLY=($(compgen -W "300" -- "$cur")) ;;
        esac
    fi
}
complete -F _portalctl portalctl portalctl.sh ./portalctl.sh
EOF
}

install_cli() {
    local tmp dir
    dir=$(completion_dir)
    info "安装命令 $BIN_LINK → $DIR/portalctl.sh"
    sudo ln -sfn "$DIR/portalctl.sh" "$BIN_LINK"
    tmp=$(mktemp)
    print_completion > "$tmp"
    info "安装 bash 补全 $dir/portalctl"
    sudo install -D -m 0644 "$tmp" "$dir/portalctl"
    rm -f "$tmp"
}

print_usage_hints() {
    cat <<EOF

==> 安装完成。中继已作为 systemd 服务 $UNIT 运行，开机自动启动。
    命令: portalctl（新开终端后 Tab 补全生效，或执行: source $(completion_dir)/portalctl）
    当前档位: ${PORTAL_PROFILE:-100} Mbps

切换码率档位（立即生效，当前串流会断开，在 Portal 上重新连接即可）:
    portalctl profile          ↑/↓ 或 1-4 选择，回车确认，q 取消
    portalctl profile 65       直接指定：65 / 100 / 150 / 200

查看实时码率:
    portalctl monitor          每 2 秒一行，Ctrl+C 退出
                               in = PS5→Portal 实际视频码率；PS5 target = PS5 接受的目标码率
其他:
    portalctl status           服务 / 网卡 GRO / 容器 / 中继状态
    portalctl logs             容器日志
    portalctl stop|start|restart
    portalctl uninstall        移除服务、命令和补全（配置与记录保留）
EOF
}

cmd_setup() {
    if [ -n "$(running_ids)" ]; then
        confirm "中继正在运行，setup 需要先停止它。现在停止？" y || die "已取消"
        if systemctl is-active --quiet "$UNIT" 2>/dev/null; then sudo systemctl stop "$UNIT"; else dc down; fi
    fi
    info "步骤 1/6：配置（PS5、Portal 必须开机/唤醒，用于读取 MAC）"
    cmd_configure
    load_env
    info "步骤 2/6：构建镜像"
    dc build
    info "步骤 3/6：关闭宿主网卡 $LAN_PARENT 的 GRO（需要 sudo）"
    gro_set off
    info "步骤 4/6：预检"
    local out
    out=$(dc run --rm -T relay preflight < /dev/null 2>&1) || { echo "$out"; die "预检失败"; }
    echo "  预检通过"
    info "步骤 5/6：baseline（只转发、不改码率，180 秒）"
    if [ -f data/state/baseline-accepted.json ] && confirm "已有 baseline 确认记录。IP/MAC/代码都没变时可跳过，跳过？" n; then
        echo "  跳过 baseline"
    else
        echo "  开始后请先在 Portal 上结束当前远程游玩，看到 running 后重新连接 PS5，正常操作约 3 分钟。"
        read -r -p "  准备好后按回车开始..." _
        foreground baseline 180
        confirm "baseline 期间 Portal 能连上，画面和操作都正常？" n || die "未确认，已中止。排查后重新运行: $ME setup"
        cmd_accept ""
    fi
    info "步骤 6/6：安装常驻服务"
    cmd_install
}

PROFILES=(65 100 150 200)
PROFILE_NOTES=("稳定，推荐" "已实测验证" "未验证，可能卡顿" "未验证，可能卡顿")

# Arrow-key menu on /dev/tty; prints the chosen profile on stdout, returns 1 on cancel.
choose_profile() {
    local cur=$1 sel=0 i key rest n=${#PROFILES[@]}
    for i in "${!PROFILES[@]}"; do [ "${PROFILES[$i]}" = "$cur" ] && sel=$i; done
    exec 3<>/dev/tty
    printf '选择码率档位（↑/↓ 或 1-4 选择，回车确认，q 取消）：\n' >&3
    printf '\033[?25l' >&3
    trap 'printf "\033[?25h" >&3' RETURN
    while :; do
        for i in "${!PROFILES[@]}"; do
            local mark="  " now=""
            [ "${PROFILES[$i]}" = "$cur" ] && now=" (当前)"
            if [ "$i" = "$sel" ]; then
                printf '\033[2K\033[7m> %3s Mbps  %s%s\033[0m\n' "${PROFILES[$i]}" "${PROFILE_NOTES[$i]}" "$now" >&3
            else
                printf '\033[2K%s%3s Mbps  %s%s\n' "$mark" "${PROFILES[$i]}" "${PROFILE_NOTES[$i]}" "$now" >&3
            fi
        done
        IFS= read -rsn1 key <&3 || return 1
        if [ "$key" = $'\033' ]; then
            IFS= read -rsn2 -t 0.05 rest <&3 || rest=""
            case "$rest" in
                '[A'|OA) sel=$(( (sel + n - 1) % n )) ;;
                '[B'|OB) sel=$(( (sel + 1) % n )) ;;
                '') return 1 ;;
            esac
        else
            case "$key" in
                '') break ;;
                k) sel=$(( (sel + n - 1) % n )) ;;
                j) sel=$(( (sel + 1) % n )) ;;
                [1-4]) sel=$(( key - 1 )); printf '\033[%dA' "$n" >&3; continue ;;
                q|Q) return 1 ;;
            esac
        fi
        printf '\033[%dA' "$n" >&3
    done
    echo "${PROFILES[$sel]}"
}

cmd_profile() {
    load_env
    local cur=${PORTAL_PROFILE:-100} new=${1:-}
    if [ -z "$new" ]; then
        [ -r /dev/tty ] || die "非交互环境请直接指定: $ME profile 65|100|150|200"
        new=$(choose_profile "$cur") || { echo "已取消"; return 0; }
    fi
    case "$new" in 65|100|150|200) ;; *) die "无效档位: $new（可选 65/100/150/200）" ;; esac

    if [ "$new" != "$cur" ]; then
        if grep -q '^PORTAL_PROFILE=' .env; then
            sed -i "s/^PORTAL_PROFILE=.*/PORTAL_PROFILE=$new/" .env
        else
            echo "PORTAL_PROFILE=$new" >> .env
        fi
        [ -w data/config/config.json ] && sed -i "s/\"profile\": *\"[0-9]*\"/\"profile\": \"$new\"/" data/config/config.json
        info "档位: $cur → $new Mbps"
        export PORTAL_PROFILE=$new
    else
        info "档位仍为 $new Mbps"
    fi

    if [ -n "$(running_ids)" ]; then
        local running
        running=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(running_ids | head -1)" | sed -n 's/^PORTAL_PROFILE=//p')
        if [ "$running" = "$new" ]; then
            echo "中继已在 $new Mbps 档位运行，无需重启。"
            return 0
        fi
        gro_check
        info "重建中继容器（当前经过中继的串流会断开，请在 Portal 上重新连接）"
        dc up -d --wait --wait-timeout 90
        cmd_status
    elif systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then
        echo "常驻服务当前未运行，下次 $ME start 或开机时生效。"
    else
        echo "中继未运行，下次 try / start 时生效。"
    fi
}

case "${1:-help}" in
    setup)     cmd_setup ;;
    configure) cmd_configure ;;
    build)     load_env; dc build ;;
    gro)
        load_env
        case "${2:-status}" in
            off) gro_set off ;;
            on)  gro_set on ;;
            status) gro_check && echo "GRO 已关闭" ;;
            *) die "用法: $ME gro off|on|status" ;;
        esac ;;
    preflight) load_env; need_stopped; gro_check; dc run --rm -T relay preflight < /dev/null ;;
    baseline)
        load_env
        info "baseline：只做 NAT 转发、不改码率，持续 ${2:-180} 秒。看到 running 后在 Portal 上发起全新连接。"
        ( sleep 8; id=$(running_ids | head -1); [ -n "$id" ] && docker exec "$id" cat "$STATUS_JSON" 2>/dev/null | print_status_line ) &
        foreground baseline "${2:-180}" ;;
    accept)    cmd_accept "${2:-}" ;;
    try)
        load_env
        info "限时主动模式 ${2:-300} 秒，档位 ${PORTAL_PROFILE:-100}。看到 running 后在 Portal 上发起全新连接；Ctrl+C 提前结束。"
        ( sleep 8; id=$(running_ids | head -1); [ -n "$id" ] && docker exec "$id" cat "$STATUS_JSON" 2>/dev/null | print_status_line ) &
        foreground try "${2:-300}" ;;
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    start|stop|restart) sudo systemctl "$1" "$UNIT"; [ "$1" = stop ] || cmd_status ;;
    profile)   cmd_profile "${2:-}" ;;
    status)    cmd_status ;;
    monitor)   cmd_monitor "${2:-0}" ;;
    logs)      dc logs -f --tail "${2:-100}" ;;
    completion) print_completion ;;
    repair-arp) load_env; need_stopped; dc run --rm -T relay repair-arp < /dev/null ;;
    *)
        cat <<EOF
用法: $ME <命令>
  setup              首次部署向导：输入 PS5/Portal IP → 构建 → baseline 确认 → 安装服务
  configure          交互式生成 .env 和 data/config/config.json（PS5、Portal 需唤醒）
  build              构建镜像 portal-relay-nat:local
  gro off|on|status  关闭/恢复/检查宿主网卡接收卸载（需要 sudo）
  preflight          只读预检
  baseline [秒]      不改码率的 NAT 转发测试（默认 180 秒）
  accept [说明]      人工确认 baseline 画面和操作正常，写入确认记录
  try [秒]           限时主动模式测试（默认 300 秒）
  install            安装 systemd 服务、portalctl 命令和 bash 补全（需要 sudo）
  uninstall          移除 systemd 服务、portalctl 命令和补全
  start|stop|restart 控制常驻服务
  profile [档位]     切换码率档位（不带参数时用方向键选择），运行中自动重建容器
  status             查看服务、网卡、容器和中继状态
  monitor [秒]       每 2 秒打印实时码率（默认一直运行）
  logs [行数]        跟踪容器日志
  repair-arp         中继异常退出后，向 Portal 发送 ARP 修复帧
  completion         输出 bash 补全脚本
EOF
        ;;
esac
