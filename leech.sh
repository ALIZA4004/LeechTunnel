#!/usr/bin/env bash
# NOTE: the shebang is REQUIRED — acme.sh registers this file as a renewal reloadcmd and execs
# it directly; without a shebang the kernel ENOEXECs and /bin/sh (dash) would choke on the
# bash-only syntax (herestrings, process substitution) before reaching the --ssl-reload dispatch.
SCRIPT_VERSION="v1.0.0"
service_dir="/etc/systemd/system"
config_dir="/root/leech"
CERT_DIR="/root/leech/cert_files"
CERT_FILE="$CERT_DIR/cert.crt"
KEY_FILE="$CERT_DIR/cert.key"
mkdir -p "$CERT_DIR"
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    sleep 1
    exit 1
fi
colorize() {
    local color="$1"
    local text="$2"
    local style="${3:-normal}"
    local black="\033[30m" red="\033[31m" green="\033[32m" yellow="\033[33m"
    local blue="\033[34m" magenta="\033[35m" cyan="\033[36m" white="\033[37m"
    local reset="\033[0m" normal="\033[0m" bold="\033[1m" underline="\033[4m"
    local color_code
    case $color in
        black) color_code=$black ;; red) color_code=$red ;;
        green) color_code=$green ;; yellow) color_code=$yellow ;;
        blue) color_code=$blue ;; magenta) color_code=$magenta ;;
        cyan) color_code=$cyan ;; white) color_code=$white ;;
        *) color_code=$reset ;;
    esac
    local style_code
    case $style in
        bold) style_code=$bold ;; underline) style_code=$underline ;;
        normal | *) style_code=$normal ;;
    esac
    echo -e "${style_code}${color_code}${text}${reset}"
}
press_key() {
    read -r -p "Press any key to continue..."
}
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local input
    echo -ne "[-] $prompt (default: $default): "
    read -r input
    eval "$var_name=\"${input:-$default}\""
}
prompt_boolean() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    while true; do
        prompt_with_default "$prompt [true/false]" "$default" "$var_name"
        local value="${!var_name}"
        if [[ "$value" == "true" || "$value" == "false" ]]; then
            break
        fi
        colorize red "Invalid input. Please enter 'true' or 'false'."
    done
}
validate_cidr() {
    local cidr="$1"
    if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; then
        return 1
    fi
    IFS='/' read -r ip mask <<< "$cidr"
    IFS='.' read -r a b c d <<< "$ip"
    if (( a<0 || a>255 || b<0 || b>255 || c<0 || c>255 || d<0 || d>255 )); then
        return 1
    fi
    if (( mask < 1 || mask > 32 )); then
        return 1
    fi
    local ip_int=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    local mask_int
    if (( mask == 32 )); then
        mask_int=0xFFFFFFFF
    else
        mask_int=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
    fi
    local net_int=$(( ip_int & mask_int ))
    local broadcast_int=$(( net_int | (~mask_int & 0xFFFFFFFF) ))
    if (( ip_int == net_int )); then
        return 1
    fi
    if (( ip_int == broadcast_int )); then
        return 1
    fi
    return 0
}
install_jq() {
    if ! command -v jq &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            colorize yellow "Installing jq..."
            sudo apt-get update && sudo apt-get install -y jq
        else
            colorize red "Error: Unsupported package manager. Please install jq manually."
            press_key
            exit 1
        fi
    fi
}
# The quantum (forged-TCP) and ipx (raw-packet) engines link libpcap at runtime
# (ldd: libpcap.so.0.8). Provision it so those transports don't fail to start.
install_libpcap() {
    if ! ldconfig -p 2>/dev/null | grep -q 'libpcap\.so\.0\.8'; then
        if command -v apt-get &> /dev/null; then
            colorize yellow "Installing libpcap0.8 (quantum/ipx raw engine dependency)..."
            # bounded so a held dpkg lock can't hang a non-interactive panel --create
            timeout 300 sudo apt-get update && timeout 180 sudo apt-get install -y libpcap0.8
        fi
    fi
}
download_and_extract_leech() {
    if [[ "$1" == "menu" ]]; then
        colorize cyan "Reinstalling / updating the LEECH core..." bold
        rm -f "${config_dir}/leech" >/dev/null 2>&1
    fi
    mkdir -p "$config_dir"
    install_libpcap
    # 1) Already installed -> use it. We build LEECH ourselves; no download needed.
    if [[ -f "${config_dir}/leech" ]]; then
        chmod u+x "${config_dir}/leech" 2>/dev/null
        return 0
    fi
    # 2) Prefer a binary bundled next to this script (e.g. a cloned LeechTunnel repo).
    local sdir cand
    sdir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" 2>/dev/null && pwd)"
    for cand in "$sdir/leech" "$sdir/leech.bin" "/root/leech.bin" "$PWD/leech"; do
        if [[ -f "$cand" && "$cand" != "${config_dir}/leech" ]]; then
            cp -f "$cand" "${config_dir}/leech"; chmod u+x "${config_dir}/leech"
            colorize green "LEECH core installed from $cand"
            return 0
        fi
    done
    # 3) Download the obfuscated core — always the LATEST published release
    #    (/releases/latest/download redirects to the newest release's asset).
    local URL="https://github.com/ALIZA4004/LeechTunnel/releases/latest/download/leech"
    echo "Downloading LEECH core (latest release)..."
    if curl -fL --progress-bar --max-time 180 -o "${config_dir}/leech" "$URL" && [[ -s "${config_dir}/leech" ]]; then
        chmod u+x "${config_dir}/leech"
        colorize green "LEECH installation completed."
        return 0
    fi
    rm -f "${config_dir}/leech"
    colorize red "Could not download the LEECH core."
    colorize yellow "Place the binary manually at ${config_dir}/leech and re-run:"
    colorize yellow "    mkdir -p ${config_dir} && cp /path/to/leech ${config_dir}/leech"
    exit 1
}
# install a `leech` launcher so the operator can just type `leech` (from anywhere, incl. /root) to
# open this configurator menu — instead of `bash /root/leech/leech.sh`. Idempotent.
install_leech_cmd() {
    local self; self="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null)"
    [ -n "$self" ] && [ -f "$self" ] || self="$config_dir/leech.sh"
    printf '#!/usr/bin/env bash\nexec bash %q "$@"\n' "$self" > /usr/local/bin/leech 2>/dev/null && chmod +x /usr/local/bin/leech 2>/dev/null
}
# Non-interactive flag modes (--gen/--create/--rm/--list/--stats, used by the
# leech-panel) skip the interactive load-time side effects (jq install, binary
# download, ipwhois lookups, backup reconcile) — they add latency and can hang.
if [[ "${1:-}" != --* ]]; then
    install_jq
    download_and_extract_leech
    install_leech_cmd
fi
declare -A CONFIG
reset_config() {
    CONFIG=()
}
prompt_connection_section() {
    local mode="$1"  # server or client
    colorize blue "━━━ Connection Configuration ━━━" bold
    if [[ "$mode" == "server" ]]; then
        prompt_with_default "Bind Address" ":8443" CONFIG[bind_addr]
        if [[ -n "${CONFIG[bind_addr]}" && "${CONFIG[bind_addr]}" != *:* ]]; then
            CONFIG[bind_addr]=":${CONFIG[bind_addr]}"
        fi
    else
        while true; do
            echo -ne "[*] IRAN Server Address [IP:Port] or [Domain:Port]: "
            read -r CONFIG[remote_addr]
            if [[ -z "${CONFIG[remote_addr]}" ]]; then
                colorize red "Server address cannot be empty."
                continue
            fi
            if [[ "${CONFIG[remote_addr]}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ || \
            "${CONFIG[remote_addr]}" =~ ^[a-zA-Z0-9.-]+:[0-9]{1,5}$ ]]; then
                break
            else
                colorize red "Invalid format. Use IP:Port or Domain:Port."
            fi
        done
        if [[ "${CONFIG[transport_type]}" == "ws" || "${CONFIG[transport_type]}" == "wss" || "${CONFIG[transport_type]}" == "wsmux" || "${CONFIG[transport_type]}" == "wssmux" || "${CONFIG[transport_type]}" == "xwsmux" ]]; then
            echo -ne "[-] Edge IP/Domain (optional, press Enter to skip): "
            read -r CONFIG[edge_ip]
        fi
        CONFIG[dial_timeout]="10"
        CONFIG[retry_interval]="3"
    fi
    echo ""
}
VALID_ALGORITHMS=("aes-256-gcm" "chacha20-poly1305" "aes-128-gcm")
is_valid_algorithm() {
    local input="$1"
    for alg in "${VALID_ALGORITHMS[@]}"; do
        if [[ "$input" == "$alg" ]]; then
            return 0
        fi
    done
    return 1
}
prompt_security_section() {
    local is_ipx="$1"
    colorize blue "━━━ Security Configuration ━━━" bold
    if [[ "$is_ipx" == "true" ]]; then
        prompt_boolean "Enable Encryption" "true" CONFIG[enable_encryption]
        if [[ "${CONFIG[enable_encryption]}" == "true" ]]; then
            echo
            while true; do
                colorize magenta "Available algorithms: aes-256-gcm, chacha20-poly1305, aes-128-gcm"
                prompt_with_default "Algorithm" "aes-256-gcm" CONFIG[algorithm]
                if is_valid_algorithm "${CONFIG[algorithm]}"; then
                    break
                else
                    colorize red "Invalid algorithm selected. Please choose one from the list."
                    echo
                fi
            done
            prompt_with_default "PSK (32-char base64)" "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4=" CONFIG[psk]
            prompt_with_default "KDF Iterations" "100000" CONFIG[kdf_iterations]
        fi
    else
        prompt_with_default "Security Token" "your_token" CONFIG[token]
        CONFIG[enable_encryption]="false"
    fi
    echo ""
}
prompt_transport_section() {
    local mode="$1"
    local is_ipx="false"
    colorize blue "━━━ Transport Configuration ━━━" bold
    local valid_transports=(tcp tcpmux xtcpmux ws wss wsmux wssmux xwsmux anytls kcp http https quantum tun)
    echo "Available transports:"
    printf '  • %s\n' "${valid_transports[@]}"
    while true; do
        echo -ne "Select transport: "
        read -r CONFIG[transport_type]
        [[ " ${valid_transports[*]} " =~ " ${CONFIG[transport_type]} " ]] && break
        colorize red "Invalid transport."
    done
    if [[ "${CONFIG[transport_type]}" == "tun" ]]; then
        echo
        local encapsulations=(tcp ipx)
        echo "Available encapsulations:"
        printf '  • %s\n' "${encapsulations[@]}"
        while true; do
            echo -ne "Select encapsulation: "
            read -r CONFIG[tun_encapsulation]
            [[ " ${encapsulations[*]} " =~ " ${CONFIG[tun_encapsulation]} " ]] && break
            colorize red "Invalid encapsulation."
        done
    fi
    echo
    if [[ "${CONFIG[tun_encapsulation]}" == "ipx" ]]; then
        is_ipx="true"
    fi
    if [[ "$is_ipx" != "true" ]]; then
        prompt_boolean "Enable TCP_NODELAY" "true" CONFIG[nodelay]
    fi
    if [[ "$mode" == "server" ]]; then
        if [[ "${CONFIG[transport_type]}" == "tcp" ]]; then
            prompt_boolean "Accept UDP over TCP" "false" CONFIG[accept_udp]
        fi
        if [[ ! "${CONFIG[transport_type]}" =~ ^(tun|ws)$ ]] && [[ "$is_ipx" != "true" ]]; then
            prompt_boolean "Enable Proxy Protocol" "false" CONFIG[proxy_protocol]
        fi
    else
        if [[ "${CONFIG[transport_type]}" != "tun" ]]; then
            prompt_with_default "Connection Pool" "8" CONFIG[connection_pool]
        fi
    fi
    CONFIG[heartbeat_interval]="10"
    CONFIG[heartbeat_timeout]="25"
    if [[ "$is_ipx" != "true" ]]; then
        CONFIG[keepalive_period]="40"
    fi
    # DPI/perf acceleration — ONE master switch, default ON, overridable.
    # ipx is the raw-packet engine (no TCP socket) so acceleration doesn't apply there.
    if [[ "$is_ipx" != "true" ]]; then
        colorize magenta "Acceleration = BBR congestion (DPI-invisible; ~55x faster under packet loss," normal
        colorize magenta "neutral on a clean link) + token obfuscation on raw-TCP carriers. Recommended ON for Iran." normal
        prompt_boolean "Enable acceleration" "true" CONFIG[acceleration]
        if [[ "${CONFIG[acceleration]}" != "false" ]]; then
            # advanced overrides — press Enter to accept the smart defaults
            prompt_with_default "  ↳ Congestion Control [bbr / cubic / empty=kernel]" "bbr" CONFIG[congestion]
            if [[ "${CONFIG[transport_type]}" =~ ^(tcp|tcpmux)$ ]]; then
                colorize yellow "  note: obfuscation trades ~15% clean-link speed for hiding the plaintext token." normal
                prompt_with_default "  ↳ Obfuscation [noise / empty=off]" "noise" CONFIG[obfuscation]
            fi
        else
            CONFIG[congestion]=""
            CONFIG[obfuscation]=""
        fi
    fi
    echo ""
}
prompt_mux_section() {
    local transport="$1"
    if [[ ! "$transport" =~ mux$ ]]; then
        return
    fi
    colorize blue "━━━ Mux Configuration ━━━" bold
    prompt_with_default "Mux Version [1 or 2]" "2" CONFIG[mux_version]
    prompt_with_default "Mux Concurrency" "8" CONFIG[mux_concurrency]
    CONFIG[mux_framesize]="32768"
    CONFIG[mux_recievebuffer]="4194304"
    CONFIG[mux_streambuffer]="2097152"
    echo ""
}
prompt_tun_section() {
    local transport="$1"
    local mode="$2"
    local is_ipx="$3"
    [[ "$transport" != "tun" ]] && return
    colorize blue "━━━ TUN Configuration ━━━" bold
    prompt_with_default "TUN Device Name" "leech" CONFIG[tun_name]
    local default_local default_remote
    if [[ "$mode" == "server" ]]; then
        default_local="10.10.10.1/24"
        default_remote="10.10.10.2/24"
    else
        default_local="10.10.10.2/24"
        default_remote="10.10.10.1/24"
    fi
    while true; do
        prompt_with_default "TUN Local Address (CIDR)" "$default_local" CONFIG[tun_local_addr]
        if validate_cidr "${CONFIG[tun_local_addr]}"; then
            break
        fi
        local suggested=$(validate_cidr "${CONFIG[tun_local_addr]}" 2>&1)
        colorize red "Invalid CIDR. Network address should be: $suggested"
    done
    while true; do
        prompt_with_default "TUN Remote Address (CIDR)" "$default_remote" CONFIG[tun_remote_addr]
        if validate_cidr "${CONFIG[tun_remote_addr]}"; then
            break
        fi
        colorize red "Invalid CIDR format."
    done
    prompt_with_default "Health Port" "1234" CONFIG[tun_health_port]
    if [[ "$is_ipx" == "true" ]]; then
        prompt_with_default "MTU" "1320" CONFIG[tun_mtu]
    else
        prompt_with_default "MTU" "1500" CONFIG[tun_mtu]
        # Stage-4: tun/tcp outer-stream token handshake (tun/ipx has no outer stream). Set on BOTH ends.
        prompt_boolean "Outer-stream token auth (outer_auth) [set on BOTH ends]" "false" CONFIG[tun_outer_auth]
    fi
    echo ""
}
prompt_tls_section() {
    local mode="$1"
    local transport="$2"
    if [[ ! "$transport" =~ ^(anytls|wss|wssmux)$ ]]; then
        return
    fi
    colorize blue "━━━ TLS Configuration ━━━" bold
    if [[ "$transport" == "anytls" ]]; then
        prompt_with_default "SNI" "www.digikala.com" CONFIG[tls_sni]
    fi
    if [[ "$mode" == "client" ]]; then
        echo
        return
    fi
    if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
        colorize red "[*] TLS certificate or key missing, generating self-signed Ed25519 cert..."
        openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -x509 -days 365 -sha256 -keyout "$KEY_FILE" -out  "$CERT_FILE" -subj "/CN=leech.com"
        colorize green "[*] Generated $CERT_FILE and $KEY_FILE"
        echo
    fi
    prompt_with_default "TLS Certificate Path" "$CERT_FILE" CONFIG[tls_cert]
    prompt_with_default "TLS Key Path" "$KEY_FILE" CONFIG[tls_key]
    echo ""
}
prompt_tuning_section() {
    local is_ipx="$1"
    local is_tun="$2"
    colorize blue "━━━ Tuning Configuration ━━━" bold
    prompt_boolean "Enable Auto Tuning" "true" CONFIG[auto_tuning]
    echo
    colorize magenta "Profiles: balanced, fast, latency, resource" normal
    prompt_with_default "Kernel Tuning Profile" "balanced" CONFIG[tuning_profile]
    prompt_with_default "Workers (0 = auto)" "0" CONFIG[workers]
    if [[ "$is_tun" != "true" ]]; then
        prompt_with_default "Channel Size" "4096" CONFIG[channel_size]
    fi
    if [[ "$is_tun" == "true" ]]; then
        # a layer-3 device sees far more packets per second than a stream carrier
        CONFIG[channel_size]="10000"
    fi
    if [[ "$is_ipx" == "true" ]]; then
        prompt_with_default "Batch Size" "2048" CONFIG[batch_size]
        prompt_with_default "SO_SNDBUF (0 = auto)" "0" CONFIG[so_sndbuf]
        prompt_with_default "TPACKET profile (blank = default)" "" CONFIG[tpacket_profile]
    else
        prompt_with_default "TCP MSS (0 = auto)" "0" CONFIG[tcp_mss]
        prompt_with_default "SO_RCVBUF (0 = auto)" "0" CONFIG[so_rcvbuf]
        prompt_with_default "SO_SNDBUF (0 = auto)" "0" CONFIG[so_sndbuf]
    fi
    if [[ "$is_tun" != "true" ]] && [[ "$is_ipx" != "true" ]]; then
        echo
        colorize magenta "Buffer Profiles: extreme_low_cpu, ultra_low_cpu, low_cpu, balanced, low_memory" normal
        prompt_with_default "Buffer Profile" "balanced" CONFIG[buffer_profile]
        prompt_with_default "Read Timeout" "120" CONFIG[read_timeout]
    fi
    echo ""
}
prompt_logging_section() {
    colorize blue "━━━ Logging Configuration ━━━" bold
    colorize magenta "Levels: panic, fatal, error, warn, info, debug, trace"
    prompt_with_default "Log Level" "info" CONFIG[log_level]
    echo ""
}
prompt_accept_udp_section() {
    local accept_udp="$1"
    [[ "$accept_udp" != "true" ]] && return
    CONFIG[ring_size]="64"
    CONFIG[frame_size]="2048"
    CONFIG[peer_idle_timeout_s]="120"
    CONFIG[write_timeout_ms]="3"
}
prompt_ports_section() {
    local mode="$1"
    local is_tun="$2"
    [[ "$mode" != "server" ]] && return
    if [[ "$is_tun" != "true" ]]; then
        colorize blue "━━━ Port Mapping Configuration ━━━" bold
        colorize green "Supported formats:"
        echo "  1. 443           - Listen on 443, forward to 443"
        echo "  2. 443=5000      - Listen on 443, forward to 5000"
        echo "  3. 443-600       - Listen on range 443-600"
        echo "  4. 443-600:5201  - Range forwarding to 5201"
        echo ""
        echo -ne "Enter port mappings (comma-separated): "
        read -r CONFIG[ports_mapping]
        echo ""
    else
        colorize blue "━━━ Port Mapping Configuration (tun helper) ━━━" bold
        colorize magenta "Forwarder: use 'leech' for TCP support only, or 'iptables' for TCP + UDP support"
        prompt_with_default "Forwarder (leech/iptables)" "leech" CONFIG[forwarder]
        echo ""
        colorize green "Supported formats:"
        echo "  1. 443           - Listen on 443, forward to 443"
        echo "  2. 443=5000      - Listen on 443, forward to 5000"
        echo ""
        echo -ne "Enter port mappings (comma-separated): "
        read -r CONFIG[ports_mapping]
        echo ""
    fi
}
prompt_ipx_section() {
    local is_ipx="$1"
    local mode="$2"
    [[ "$is_ipx" != "true" ]] && return
    colorize blue "━━━ IPX Configuration ━━━" bold
    CONFIG[ipx_mode]="$mode"
    AVAILABLE_PROFILES=("icmp" "ipip" "udp" "tcp" "gre" "bip")
    colorize magenta "Available profiles: ${AVAILABLE_PROFILES[*]}"
    while true; do
        prompt_with_default "Profile" "tcp" CONFIG[ipx_profile]
        CONFIG[ipx_profile]="${CONFIG[ipx_profile],,}"
        for profile in "${AVAILABLE_PROFILES[@]}"; do
            if [[ "${CONFIG[ipx_profile]}" == "$profile" ]]; then
                break 2
            fi
        done
        colorize red "Invalid profile: ${CONFIG[ipx_profile]}"
        echo
        colorize yellow "Please choose one of: ${AVAILABLE_PROFILES[*]}"
    done
    prompt_with_default "Listen IP" "$SERVER_IP" CONFIG[ipx_listen_ip]
    while :; do
        prompt_with_default "Destination IP" "" CONFIG[ipx_dst_ip]
        if [[ -n "${CONFIG[ipx_dst_ip]}" ]]; then
            break
        fi
        colorize red "Destination IP cannot be empty."
    done
    interface=$(ip route show default | awk '{print $5}')
    prompt_with_default "Network Interface" "$interface" CONFIG[ipx_interface]
    if [[ "${CONFIG[ipx_profile]}" == "icmp" ]]; then
        prompt_with_default "ICMP Type" "0" CONFIG[ipx_icmp_type]
        prompt_with_default "ICMP Code" "0" CONFIG[ipx_icmp_code]
    fi
    # Stage-4: raw-engine controls (blank = profile/faithful default)
    prompt_with_default "Raw IP protocol number override (blank = profile default)" "" CONFIG[ipx_protocol]
    prompt_with_default "Spoof source IP (blank = none)" "" CONFIG[ipx_spoof_src]
    prompt_with_default "Spoof destination IP (blank = none)" "" CONFIG[ipx_spoof_dst]
    prompt_boolean "Custom packet mode" "false" CONFIG[ipx_custom_packet]
    # proto58 (ENHANCEMENT): wrap the crafted IPv4 in an OUTER IPv6/next-header-58 shell
    # and L2-inject it (needs global IPv6 that reaches both ends). Composes with the
    # profile (use tcp); this is NOT the same as profile=bip (that only changes the inner proto).
    prompt_boolean "proto58 outer IPv6 shell (wrap+L2-inject; needs IPv6 both ends) — not profile=bip" "false" CONFIG[ipx_proto58]
    if [[ "${CONFIG[ipx_proto58]}" == "true" ]]; then
        prompt_with_default "  proto58 source IPv6 (THIS box's GLOBAL v6)" "" CONFIG[ipx_proto58_src6]
        prompt_with_default "  proto58 dest IPv6 (PEER box's GLOBAL v6)" "" CONFIG[ipx_proto58_dst6]
        prompt_with_default "  proto58 gateway MAC override (blank = auto via IPv4 ARP)" "" CONFIG[ipx_proto58_gwmac]
    fi
    prompt_with_default "Allowed client IPs (comma-separated, blank = any)" "" CONFIG[ipx_allowed_raw]
    [[ -n "${CONFIG[ipx_allowed_raw]}" ]] && CONFIG[ipx_allowed_client_ips]="$(csv_to_toml_array "${CONFIG[ipx_allowed_raw]}")"
    echo ""
}
generate_toml_config() {
    local mode="$1"
    local output_file="$2"
    local is_tun="$3"
    local is_ipx="$4"
    {
        if [[ "$mode" == "server" ]] && [[ "$is_ipx" == "false" ]]; then
            echo "[listener]"
            echo "bind_addr = \"${CONFIG[bind_addr]}\""
            echo ""
        elif [[ "$is_ipx" == "false" ]]; then
            echo "[dialer]"
            if [[ -n "${CONFIG[remote_addrs]}" ]]; then
                echo "remote_addrs = ${CONFIG[remote_addrs]}"
            else
                echo "remote_addr = \"${CONFIG[remote_addr]}\""
            fi
            [[ -n "${CONFIG[edge_ip]}" ]] && echo "edge_ip = \"${CONFIG[edge_ip]}\""
            echo "dial_timeout = ${CONFIG[dial_timeout]}"
            echo "retry_interval = ${CONFIG[retry_interval]}"
            echo ""
        fi
        echo "[transport]"
        echo "type = \"${CONFIG[transport_type]}\""
        [[ -n "${CONFIG[nodelay]}" ]] && echo "nodelay = ${CONFIG[nodelay]}"
        [[ -n "${CONFIG[keepalive_period]}" ]] && echo "keepalive_period = ${CONFIG[keepalive_period]}"
        if [[ "$mode" == "server" ]]; then
            [[ -n "${CONFIG[accept_udp]}" ]] && echo "accept_udp = ${CONFIG[accept_udp]}"
            [[ -n "${CONFIG[proxy_protocol]}" ]] && echo "proxy_protocol = ${CONFIG[proxy_protocol]}"
        else
            [[ -n "${CONFIG[connection_pool]}" ]] && [[ "${CONFIG[connection_pool]}" != "0" ]] && \
            echo "connection_pool = ${CONFIG[connection_pool]}"
        fi
        [[ -n "${CONFIG[heartbeat_interval]}" ]] && echo "heartbeat_interval = ${CONFIG[heartbeat_interval]}"
        [[ -n "${CONFIG[heartbeat_timeout]}" ]] && echo "heartbeat_timeout = ${CONFIG[heartbeat_timeout]}"
        # --- DPI/perf acceleration (reconstruction; original defaults it OFF) ---
        # ONE master switch CONFIG[acceleration], default ON. OFF => faithful plain config.
        local accel="${CONFIG[acceleration]:-true}"
        if [[ "$accel" != "false" ]]; then
            # BBR: DPI-invisible congestion control (~55x faster under loss, neutral on a
            # clean link). Every TCP-family carrier — NOT the raw ipx engine. Empty => skip.
            if [[ "$is_ipx" != "true" ]]; then
                local cc="${CONFIG[congestion]-bbr}"
                [[ -n "$cc" ]] && echo "congestion = \"$cc\""
            fi
            # Noise: hides the plaintext token on the raw-TCP carriers (tcp/tcpmux) only —
            # TLS carriers already hide it. Trades ~15% clean speed for concealment. Empty => skip.
            if [[ "${CONFIG[transport_type]}" =~ ^(tcp|tcpmux)$ ]]; then
                local ob="${CONFIG[obfuscation]-noise}"
                [[ -n "$ob" ]] && echo "obfuscation = \"$ob\""
            fi
        fi
        # --- Phase-2 DPI-hardening molecules (reconstruction; all opt-in, faithful default) ---
        [[ -n "${CONFIG[ws_path_secret]}" ]]    && echo "ws_path_secret = ${CONFIG[ws_path_secret]}"
        [[ -n "${CONFIG[ws_host]}" ]]           && echo "ws_host = \"${CONFIG[ws_host]}\""
        [[ -n "${CONFIG[fake_site_upstream]}" ]] && echo "fake_site_upstream = \"${CONFIG[fake_site_upstream]}\""
        [[ -n "${CONFIG[fake_site_file]}" ]]    && echo "fake_site_file = \"${CONFIG[fake_site_file]}\""
        [[ -n "${CONFIG[obfs_rotate_magic]}" ]] && echo "obfs_rotate_magic = ${CONFIG[obfs_rotate_magic]}"
        [[ -n "${CONFIG[obfs_junk_count]}" ]]   && echo "obfs_junk_count = ${CONFIG[obfs_junk_count]}"
        [[ -n "${CONFIG[obfs_junk_min]}" ]]     && echo "obfs_junk_min = ${CONFIG[obfs_junk_min]}"
        [[ -n "${CONFIG[obfs_junk_max]}" ]]     && echo "obfs_junk_max = ${CONFIG[obfs_junk_max]}"
        [[ -n "${CONFIG[adaptive]}" ]]          && echo "adaptive = ${CONFIG[adaptive]}"
        [[ -n "${CONFIG[adaptive_failures]}" ]] && echo "adaptive_failures = ${CONFIG[adaptive_failures]}"
        [[ -n "${CONFIG[adaptive_carriers]}" ]] && echo "adaptive_carriers = ${CONFIG[adaptive_carriers]}"
        # ENHANCEMENT — active pre-probe: check the live carrier out-of-band and switch BEFORE
        # user traffic drops (empty => key omitted => reactive-only, faithful default).
        [[ -n "${CONFIG[adaptive_probe]}" ]]          && echo "adaptive_probe = ${CONFIG[adaptive_probe]}"
        [[ -n "${CONFIG[adaptive_probe_interval]}" ]] && echo "adaptive_probe_interval = ${CONFIG[adaptive_probe_interval]}"
        [[ -n "${CONFIG[adaptive_probe_fails]}" ]]    && echo "adaptive_probe_fails = ${CONFIG[adaptive_probe_fails]}"
        # --- Dagger-fusion Stage-1 ENHANCEMENTS (opt-in; empty => key omitted, faithful default) ---
        # tls_fragment: split the ClientHello across TCP segments (anti-SNI-reassembly; wss/wssmux/anytls).
        # probe_decoy: unauth prober of a raw tcp/kcp port gets a fake nginx 200 instead of a tunnel tell.
        # runtime_tune: runtime kcp/quantum band retuner + low-RAM governor (SPEED).
        [[ -n "${CONFIG[tls_fragment]}" ]] && echo "tls_fragment = ${CONFIG[tls_fragment]}"
        [[ -n "${CONFIG[probe_decoy]}" ]]  && echo "probe_decoy = ${CONFIG[probe_decoy]}"
        [[ -n "${CONFIG[runtime_tune]}" ]] && echo "runtime_tune = ${CONFIG[runtime_tune]}"
        # Stage-4: obfs_padding (noise record padding, tcp/tcpmux) + tls_fingerprint (anytls uTLS
        # profile: empty=browser utls, "go"=stock crypto/tls). Both are [transport] fields.
        [[ -n "${CONFIG[obfs_padding]}" ]]    && echo "obfs_padding = ${CONFIG[obfs_padding]}"
        [[ -n "${CONFIG[tls_fingerprint]}" ]] && echo "tls_fingerprint = \"${CONFIG[tls_fingerprint]}\""
        echo ""
        if [[ "$is_tun" == "true" ]]; then
            echo "[tun]"
            echo "encapsulation = \"${CONFIG[tun_encapsulation]}\""
            echo "name = \"${CONFIG[tun_name]}\""
            echo "local_addr = \"${CONFIG[tun_local_addr]}\""
            echo "remote_addr = \"${CONFIG[tun_remote_addr]}\""
            echo "health_port = ${CONFIG[tun_health_port]}"
            echo "mtu = ${CONFIG[tun_mtu]}"
            # Stage-4: outer_auth (tun/tcp ONLY — tun/ipx has no outer stream). Token handshake on
            # the outer conn; must be set on BOTH ends. Default off omits the key (faithful raw relay).
            [[ "${CONFIG[tun_encapsulation]}" != "ipx" && -n "${CONFIG[tun_outer_auth]}" ]] && echo "outer_auth = ${CONFIG[tun_outer_auth]}"
            echo ""
        fi
        if [[ "$is_ipx" == "true" ]]; then
            echo "[ipx]"
            echo "mode = \"${CONFIG[ipx_mode]}\""
            echo "profile = \"${CONFIG[ipx_profile]}\""
            echo "listen_ip = \"${CONFIG[ipx_listen_ip]}\""
            echo "dst_ip = \"${CONFIG[ipx_dst_ip]}\""
            echo "interface = \"${CONFIG[ipx_interface]}\""
            [[ -n "${CONFIG[ipx_icmp_type]}" ]] && echo "icmp_type = ${CONFIG[ipx_icmp_type]}"
            [[ -n "${CONFIG[ipx_icmp_code]}" ]] && echo "icmp_code = ${CONFIG[ipx_icmp_code]}"
            # Stage-4: raw-engine controls. protocol overrides the profile's outer IP proto;
            # spoof_src/dst forge the outer addresses; custom_packet toggles the custom crafter;
            # allowed_client_ips restricts accepted peers (already a TOML array from the gen reader).
            [[ -n "${CONFIG[ipx_protocol]}" ]]           && echo "protocol = ${CONFIG[ipx_protocol]}"
            [[ -n "${CONFIG[ipx_spoof_src]}" ]]          && echo "spoof_src_ip = \"${CONFIG[ipx_spoof_src]}\""
            [[ -n "${CONFIG[ipx_spoof_dst]}" ]]          && echo "spoof_dst_ip = \"${CONFIG[ipx_spoof_dst]}\""
            [[ -n "${CONFIG[ipx_custom_packet]}" ]]      && echo "custom_packet = ${CONFIG[ipx_custom_packet]}"
            # proto58: outer IPv6/NH-58 shell (bool) + the two global v6 endpoints + optional gw-MAC override.
            [[ -n "${CONFIG[ipx_proto58]}" ]]            && echo "proto58 = ${CONFIG[ipx_proto58]}"
            [[ -n "${CONFIG[ipx_proto58_src6]}" ]]       && echo "proto58_src_ipv6 = \"${CONFIG[ipx_proto58_src6]}\""
            [[ -n "${CONFIG[ipx_proto58_dst6]}" ]]       && echo "proto58_dst_ipv6 = \"${CONFIG[ipx_proto58_dst6]}\""
            [[ -n "${CONFIG[ipx_proto58_gwmac]}" ]]      && echo "proto58_gw_mac = \"${CONFIG[ipx_proto58_gwmac]}\""
            [[ -n "${CONFIG[ipx_allowed_client_ips]}" ]] && echo "allowed_client_ips = ${CONFIG[ipx_allowed_client_ips]}"
            echo ""
        fi
        if [[ "${CONFIG[transport_type]}" =~ mux$ ]]; then
            echo "[mux]"
            echo "mux_version = ${CONFIG[mux_version]}"
            echo "mux_framesize = ${CONFIG[mux_framesize]}"
            echo "mux_recievebuffer = ${CONFIG[mux_recievebuffer]}"
            echo "mux_streambuffer = ${CONFIG[mux_streambuffer]}"
            [[ -n "${CONFIG[mux_concurrency]}" ]] && echo "mux_concurrency = ${CONFIG[mux_concurrency]}"
            echo ""
        fi
        if [[ "${CONFIG[transport_type]}" == "kcp" ]]; then
            echo "[kcp]"
            echo "mode = \"${CONFIG[kcp_mode]:-fast2}\""
            echo "data_shards = ${CONFIG[kcp_data_shards]:-10}"
            echo "parity_shards = ${CONFIG[kcp_parity_shards]:-3}"
            echo "mtu = ${CONFIG[kcp_mtu]:-1350}"
            [[ -n "${CONFIG[kcp_snd_wnd]}" ]] && echo "snd_wnd = ${CONFIG[kcp_snd_wnd]}"
            [[ -n "${CONFIG[kcp_rcv_wnd]}" ]] && echo "rcv_wnd = ${CONFIG[kcp_rcv_wnd]}"
            echo ""
        fi
        if [[ "${CONFIG[transport_type]}" =~ ^(http|https)$ ]]; then
            echo "[http_settings]"
            [[ -n "${CONFIG[http_fake_domain]}" ]]    && echo "fake_domain = \"${CONFIG[http_fake_domain]}\""
            [[ -n "${CONFIG[http_fake_ua]}" ]]        && echo "fake_ua = \"${CONFIG[http_fake_ua]}\""
            [[ -n "${CONFIG[http_path]}" ]]           && echo "path = \"${CONFIG[http_path]}\""
            [[ -n "${CONFIG[http_session_cookie]}" ]] && echo "session_cookie = \"${CONFIG[http_session_cookie]}\""
            echo ""
        fi
        if [[ "${CONFIG[transport_type]}" == "quantum" ]]; then
            echo "[quantum]"
            echo "mtu = ${CONFIG[quantum_mtu]:-1350}"
            echo "block = \"${CONFIG[quantum_block]:-aes}\""
            echo "data_shards = ${CONFIG[quantum_data_shards]:-10}"
            echo "parity_shards = ${CONFIG[quantum_parity_shards]:-1}"
            [[ -n "${CONFIG[quantum_flags]}" ]]     && echo "flags = \"${CONFIG[quantum_flags]}\""
            [[ -n "${CONFIG[quantum_interface]}" ]] && echo "interface = \"${CONFIG[quantum_interface]}\""
            [[ -n "${CONFIG[quantum_local_ip]}" ]]  && echo "local_ip = \"${CONFIG[quantum_local_ip]}\""
            [[ -n "${CONFIG[quantum_snd_wnd]}" ]]   && echo "snd_wnd = ${CONFIG[quantum_snd_wnd]}"
            [[ -n "${CONFIG[quantum_rcv_wnd]}" ]]   && echo "rcv_wnd = ${CONFIG[quantum_rcv_wnd]}"
            # Stage-4: ipv6 (fake-TCP IPv6 src), router (next-hop gateway MAC override), read_buffer (pcap ring).
            [[ -n "${CONFIG[quantum_ipv6]}" ]]        && echo "ipv6 = \"${CONFIG[quantum_ipv6]}\""
            [[ -n "${CONFIG[quantum_router]}" ]]      && echo "router = \"${CONFIG[quantum_router]}\""
            [[ -n "${CONFIG[quantum_read_buffer]}" ]] && echo "read_buffer = ${CONFIG[quantum_read_buffer]}"
            echo ""
        fi
        echo "[security]"
        if [[ "$is_ipx" == "true" ]]; then
            echo "enable_encryption = ${CONFIG[enable_encryption]}"
            [[ "${CONFIG[enable_encryption]}" == "true" ]] && {
                echo "algorithm = \"${CONFIG[algorithm]}\""
                echo "psk = \"${CONFIG[psk]}\""
                echo "kdf_iterations = ${CONFIG[kdf_iterations]}"
            }
        else
            echo "token = \"${CONFIG[token]}\""
            # ENHANCEMENT: optional payload AEAD on a stream carrier (default off = faithful). Needed
            # for pad_frames, and usable as a double-encryption layer under TLS/Noise if wanted.
            if [[ "${CONFIG[enable_encryption]}" == "true" ]]; then
                echo "enable_encryption = true"
                echo "algorithm = \"${CONFIG[algorithm]}\""
                echo "psk = \"${CONFIG[psk]}\""
                echo "kdf_iterations = ${CONFIG[kdf_iterations]}"
            fi
        fi
        # Stage-1 length-padding (Dagger fusion) — size-classed, 1 MiB-budget-capped random pad on the
        # crypto.Conn AEAD frames; effective only when enable_encryption is on. Set on BOTH ends.
        [[ -n "${CONFIG[pad_frames]}" ]] && echo "pad_frames = ${CONFIG[pad_frames]}"
        [[ -n "${CONFIG[pad_min]}" ]]    && echo "pad_min = ${CONFIG[pad_min]}"
        [[ -n "${CONFIG[pad_max]}" ]]    && echo "pad_max = ${CONFIG[pad_max]}"
        echo ""
        if [[ -n "${CONFIG[tls_sni]}" || -n "${CONFIG[tls_cert]}" || -n "${CONFIG[tls_sni_list]}" ]]; then
            echo "[tls]"
            [[ -n "${CONFIG[tls_sni]}" ]]      && echo "sni = \"${CONFIG[tls_sni]}\""
            [[ -n "${CONFIG[tls_sni_list]}" ]] && echo "sni_list = ${CONFIG[tls_sni_list]}"
            [[ -n "${CONFIG[tls_cert]}" ]] && echo "tls_cert = \"${CONFIG[tls_cert]}\""
            [[ -n "${CONFIG[tls_key]}" ]]  && echo "tls_key = \"${CONFIG[tls_key]}\""
            echo ""
        fi
        echo "[tuning]"
        [[ -n "${CONFIG[auto_tuning]}" ]]     && echo "auto_tuning = ${CONFIG[auto_tuning]}"
        [[ -n "${CONFIG[tuning_profile]}" ]]  && echo "tuning_profile = \"${CONFIG[tuning_profile]}\""
        [[ -n "${CONFIG[workers]}" ]]         && echo "workers = ${CONFIG[workers]}"
        [[ -n "${CONFIG[channel_size]}" ]]    && echo "channel_size = ${CONFIG[channel_size]}"
        [[ -n "${CONFIG[tcp_mss]}" ]]         && echo "tcp_mss = ${CONFIG[tcp_mss]}"
        [[ -n "${CONFIG[so_rcvbuf]}" ]]       && echo "so_rcvbuf = ${CONFIG[so_rcvbuf]}"
        [[ -n "${CONFIG[so_sndbuf]}" ]]       && echo "so_sndbuf = ${CONFIG[so_sndbuf]}"
        [[ -n "${CONFIG[buffer_profile]}" ]]  && echo "buffer_profile = \"${CONFIG[buffer_profile]}\""
        [[ -n "${CONFIG[batch_size]}" ]]      && echo "batch_size = ${CONFIG[batch_size]}"
        [[ -n "${CONFIG[read_timeout]}" ]]    && echo "read_timeout = ${CONFIG[read_timeout]}"
        # Stage-4: tpacket_profile (ipx afpacket ring geometry), max_connections, write_timeout (seconds).
        [[ -n "${CONFIG[tpacket_profile]}" ]] && echo "tpacket_profile = \"${CONFIG[tpacket_profile]}\""
        [[ -n "${CONFIG[max_connections]}" ]] && echo "max_connections = ${CONFIG[max_connections]}"
        [[ -n "${CONFIG[write_timeout_sec]}" ]] && echo "write_timeout = ${CONFIG[write_timeout_sec]}"
        echo ""
        if [[ "${CONFIG[accept_udp]}" == "true" ]]; then
            echo "[accept_udp]"
            echo "ring_size = ${CONFIG[ring_size]}"
            echo "frame_size = ${CONFIG[frame_size]}"
            echo "peer_idle_timeout_s = ${CONFIG[peer_idle_timeout_s]}"
            echo "write_timeout_ms = ${CONFIG[write_timeout_ms]}"
            echo ""
        fi
        echo "[logging]"
        echo "log_level = \"${CONFIG[log_level]}\""
        echo ""
        if [[ "$mode" == "server" ]] ; then
            echo "[ports]"
            [[ -n "${CONFIG[forwarder]}" ]]  && echo "forwarder = \"${CONFIG[forwarder]}\""
            echo "mapping = ["
            IFS=',' read -r -a ports <<< "${CONFIG[ports_mapping]}"
            for port in "${ports[@]}"; do
                [[ -n "$port" ]] && echo "    \"${port// /}\","
            done
            echo "]"
        fi
        if [[ -n "${CONFIG[license_key]}" ]]; then
            echo ""
            echo "[license]"
            echo "key = \"${CONFIG[license_key]}\""
            # NOTE: recheck cadence + offline-grace window are intentionally NOT written here.
            # They are carried in the validator's signed payload (owner-controlled, tamper-proof)
            # so a customer cannot widen the recheck interval to dodge a revoke.
        fi
    } > "$output_file"
}
# csv_to_toml_array "a, b ,c" -> ["a","b","c"]
csv_to_toml_array() {
    local IFS=',' item out=""
    for item in $1; do
        item="${item// /}"; [[ -z "$item" ]] && continue
        out="$out\"$item\","
    done
    echo "[${out%,}]"
}
prompt_kcp_section() {
    [[ "$1" != "kcp" ]] && return
    colorize blue "━━━ KCP+FEC Configuration ━━━" bold
    colorize magenta "KCP over UDP with Reed-Solomon FEC — reads as QUIC on UDP/443; FEC recovers loss without a retransmit RTT." normal
    prompt_with_default "KCP mode [normal/fast/fast2/fast3]" "fast2" CONFIG[kcp_mode]
    prompt_with_default "FEC data shards" "10" CONFIG[kcp_data_shards]
    prompt_with_default "FEC parity shards (0 = FEC off)" "3" CONFIG[kcp_parity_shards]
    prompt_with_default "MTU" "1350" CONFIG[kcp_mtu]
    # Stage-4: KCP flow windows in packets (blank = 1024 each).
    prompt_with_default "KCP send window (packets, blank = 1024)" "" CONFIG[kcp_snd_wnd]
    prompt_with_default "KCP recv window (packets, blank = 1024)" "" CONFIG[kcp_rcv_wnd]
    echo ""
}
prompt_http_section() {
    [[ ! "$1" =~ ^(http|https)$ ]] && return
    colorize blue "━━━ HTTP Mimicry Configuration ━━━" bold
    colorize magenta "The tunnel looks like ordinary web browsing (realistic GET + nginx 200; https adds a real TLS session)." normal
    prompt_with_default "Fake domain (Host header / TLS SNI)" "www.google.com" CONFIG[http_fake_domain]
    prompt_with_default "GET path" "/search" CONFIG[http_path]
    prompt_with_default "Fake User-Agent (empty = default Chrome)" "" CONFIG[http_fake_ua]
    prompt_with_default "Session cookie name (empty = none)" "" CONFIG[http_session_cookie]
    echo ""
}
prompt_quantum_section() {
    [[ "$1" != "quantum" ]] && return
    colorize blue "━━━ Quantum (forged-TCP) Configuration ━━━" bold
    colorize magenta "KCP inside FORGED TCP segments — zero UDP on the wire; survives UDP blocking + stateful-TCP fingerprinting. Linux + root only." normal
    prompt_with_default "MTU" "1350" CONFIG[quantum_mtu]
    prompt_with_default "KCP mask cipher [aes/salsa20/none]" "aes" CONFIG[quantum_block]
    prompt_with_default "FEC data shards" "10" CONFIG[quantum_data_shards]
    prompt_with_default "FEC parity shards (0 = off)" "1" CONFIG[quantum_parity_shards]
    prompt_with_default "Forged TCP flags [PA/SA/FA/...]" "PA" CONFIG[quantum_flags]
    echo ""
}
prompt_dpi_section() {
    local mode="$1" transport="$2"
    colorize blue "━━━ DPI Hardening (Phase-2, opt-in) ━━━" bold
    if [[ "$transport" =~ ^(ws|wss|wsmux|wssmux)$ ]]; then
        prompt_boolean "Secret WS path (hide /channel,/tunnel via HMAC(token)) [set on BOTH ends]" "true" CONFIG[ws_path_secret]
        prompt_with_default "  ↳ Fronting Host header (empty = use SNI under acceleration)" "" CONFIG[ws_host]
        [[ "$mode" == "server" ]] && prompt_with_default "  ↳ Fake-site reverse-proxy upstream (empty = built-in decoy page)" "" CONFIG[fake_site_upstream]
        [[ "$mode" == "server" ]] && prompt_with_default "  ↳ Fake-site local HTML file (empty = upstream / built-in decoy)" "" CONFIG[fake_site_file]
    fi
    if [[ "$transport" == "xtcpmux" ]]; then
        prompt_boolean "Rotate xtcpmux obfs magic per-deployment (from token) [BOTH ends]" "true" CONFIG[obfs_rotate_magic]
    fi
    if [[ "$transport" =~ ^(tcp|tcpmux)$ || "$transport" == "tun" ]]; then
        prompt_with_default "AmneziaWG junk packets before Noise handshake (0 = off) [BOTH ends]" "0" CONFIG[obfs_junk_count]
        if [[ -n "${CONFIG[obfs_junk_count]}" && "${CONFIG[obfs_junk_count]}" != "0" ]]; then
            CONFIG[obfs_junk_min]="40"; CONFIG[obfs_junk_max]="1000"
        fi
    fi
    # Stage-4: Noise record padding max (tcp/tcpmux; needs obfuscation=noise). Blank = carrier default 256.
    if [[ "$transport" =~ ^(tcp|tcpmux)$ ]]; then
        prompt_with_default "Noise record padding max bytes (blank = 256; needs obfuscation=noise)" "" CONFIG[obfs_padding]
    fi
    if [[ "$transport" =~ ^(wss|wssmux|anytls)$ ]]; then
        prompt_with_default "SNI rotation list (comma-separated; empty = single SNI)" "" CONFIG[dpi_sni_list_raw]
        [[ -n "${CONFIG[dpi_sni_list_raw]}" ]] && CONFIG[tls_sni_list]="$(csv_to_toml_array "${CONFIG[dpi_sni_list_raw]}")"
    fi
    if [[ "$mode" == "client" ]]; then
        prompt_boolean "Adaptive failover (auto-switch carrier when one is blocked)" "false" CONFIG[adaptive]
        if [[ "${CONFIG[adaptive]}" == "true" ]]; then
            prompt_with_default "  ↳ Carriers (comma-sep 'type@host:port')" "" CONFIG[dpi_adaptive_raw]
            CONFIG[adaptive_carriers]="$(csv_to_toml_array "${CONFIG[dpi_adaptive_raw]}")"
            prompt_with_default "  ↳ Consecutive failures before switching" "3" CONFIG[adaptive_failures]
            # ENHANCEMENT — active pre-probe: an out-of-band check of the live carrier that
            # switches BEFORE user traffic drops (vs waiting for the data path to fail).
            prompt_boolean "  ↳ Active pre-probe (switch early on an out-of-band block)" "true" CONFIG[adaptive_probe]
            if [[ "${CONFIG[adaptive_probe]}" == "true" ]]; then
                prompt_with_default "    ↳ Probe interval seconds (how often to check the carrier)" "20" CONFIG[adaptive_probe_interval]
                prompt_with_default "    ↳ Consecutive probe failures before switching early" "2" CONFIG[adaptive_probe_fails]
            fi
        fi
    fi
    # --- Dagger-fusion Stage-1 toggles (opt-in; set on BOTH ends where noted) ---
    if [[ "$transport" =~ ^(wss|wssmux|anytls)$ ]]; then
        prompt_boolean "Split ClientHello across TCP segments (anti-SNI-reassembly)" "true" CONFIG[tls_fragment]
    fi
    # Stage-4: anytls uTLS fingerprint (blank = randomized browser uTLS; "go" = stock crypto/tls).
    if [[ "$transport" == "anytls" ]]; then
        prompt_with_default "uTLS fingerprint [blank = browser utls / go = stock]" "" CONFIG[tls_fingerprint]
    fi
    if [[ "$mode" == "server" && "$transport" =~ ^(tcp|tcpmux|kcp)$ ]]; then
        prompt_boolean "Active-probe decoy (an unauth prober sees a fake nginx 200)" "true" CONFIG[probe_decoy]
    fi
    if [[ "$transport" == "kcp" ]]; then
        prompt_boolean "Runtime adaptive tuner (kcp band retune + low-RAM governor)" "true" CONFIG[runtime_tune]
    fi
    echo ""
}
# Non-interactive config generation for scripted / multi-transport deploys:
#   leech.sh --gen <server|client> <output.toml>
# reads BH_* env vars into CONFIG then writes the TOML (no prompts).
gen_noninteractive() {
    local mode="$1" out="$2"
    declare -gA CONFIG=()
    CONFIG[license_key]="${BH_LICENSE_KEY:-LEECH-H34M-CLUX-3PMU-2REK}"
    CONFIG[transport_type]="${BH_TYPE:-tcp}"
    CONFIG[bind_addr]="${BH_BIND}"
    CONFIG[remote_addr]="${BH_REMOTE}"
    # Multi-IP failover (ENHANCEMENT): BH_REMOTE_ADDRS is the COMPLETE comma-separated
    # target list (include the primary, ideally first). When set it REPLACES remote_addr
    # in the TOML — a non-empty remote_addr would make remote_addrs inert (CurrentRemote
    # precedence). BH_REMOTE stays set for port derivation (tun name / unit name).
    CONFIG[remote_addrs]="${BH_REMOTE_ADDRS:+$(csv_to_toml_array "$BH_REMOTE_ADDRS")}"
    CONFIG[edge_ip]="${BH_EDGE_IP}"
    CONFIG[dial_timeout]="${BH_DIAL_TIMEOUT:-10}"
    CONFIG[retry_interval]="${BH_RETRY:-3}"
    # No silent fallback: an empty token would install the well-known default on
    # both ends, which is an open door — fail loudly instead. The ipx raw engine
    # has no token handshake at all (it authenticates with the PSK), so it is exempt.
    if [[ "${BH_TUN_ENCAP}" == "ipx" ]]; then
        CONFIG[token]="${BH_TOKEN}"
    else
        CONFIG[token]="${BH_TOKEN:?BH_TOKEN is required}"
    fi
    CONFIG[nodelay]="${BH_NODELAY:-true}"
    CONFIG[keepalive_period]="${BH_KEEPALIVE:-40}"
    # a layer-3 device has no pool of tunnel connections to pre-open
    if [[ "${BH_TYPE:-tcp}" == "tun" ]]; then CONFIG[connection_pool]="${BH_POOL}"; else CONFIG[connection_pool]="${BH_POOL:-8}"; fi
    CONFIG[heartbeat_interval]="${BH_HB_INT:-10}"
    CONFIG[heartbeat_timeout]="${BH_HB_TO:-25}"
    CONFIG[acceleration]="${BH_ACCEL:-true}"
    CONFIG[congestion]="${BH_CONGESTION-bbr}"
    CONFIG[obfuscation]="${BH_OBFS-}"
    CONFIG[mux_version]="${BH_MUX_VERSION:-2}"
    CONFIG[mux_framesize]="${BH_MUX_FRAME:-32768}"; CONFIG[mux_recievebuffer]="${BH_MUX_RCVBUF:-4194304}"
    CONFIG[mux_streambuffer]="${BH_MUX_STREAMBUF:-2097152}"; CONFIG[mux_concurrency]="${BH_MUX_CONC:-8}"
    # anytls is the one transport the interactive path asks an SNI for (and so always
    # writes); the others take the core's own default unless one is given
    if [[ "${BH_TYPE}" == "anytls" ]]; then CONFIG[tls_sni]="${BH_SNI:-www.digikala.com}"; else CONFIG[tls_sni]="${BH_SNI}"; fi
    CONFIG[tls_sni_list]="${BH_SNI_LIST:+$(csv_to_toml_array "$BH_SNI_LIST")}"
    # A server with no cert on disk falls back to an in-memory self-signed one that
    # is regenerated on every restart, i.e. a fingerprint that changes each bounce.
    # Mint the same stable pair the interactive path does instead.
    if [[ "$mode" == "server" && "${BH_TYPE}" =~ ^(wss|wssmux|anytls|https)$ ]]; then
        if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
            mkdir -p "$(dirname "$CERT_FILE")"
            openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -x509 \
                -days 365 -sha256 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=leech.com" >/dev/null 2>&1
        fi
        CONFIG[tls_cert]="${BH_TLS_CERT:-$CERT_FILE}"; CONFIG[tls_key]="${BH_TLS_KEY:-$KEY_FILE}"
    else
        CONFIG[tls_cert]="${BH_TLS_CERT}"; CONFIG[tls_key]="${BH_TLS_KEY}"
    fi
    CONFIG[ws_path_secret]="${BH_WS_PATH_SECRET}"; CONFIG[ws_host]="${BH_WS_HOST}"
    CONFIG[fake_site_upstream]="${BH_FAKE_UPSTREAM}"; CONFIG[fake_site_file]="${BH_FAKE_FILE}"
    CONFIG[obfs_rotate_magic]="${BH_OBFS_ROTATE}"
    # junk is prompted (and so written, even as 0) on the Noise-capable carriers
    CONFIG[obfs_junk_count]="${BH_JUNK_COUNT}"
    [[ "${BH_TYPE:-tcp}" =~ ^(tcp|tcpmux|tun)$ ]] && CONFIG[obfs_junk_count]="${BH_JUNK_COUNT:-0}"
    CONFIG[obfs_junk_min]="${BH_JUNK_MIN}"; CONFIG[obfs_junk_max]="${BH_JUNK_MAX}"
    # the interactive path hardcodes junk min/max = 40/1000 whenever junk is ON (line ~661);
    # mirror it so a panel tunnel with junk>0 carries the same range instead of omitting it.
    if [[ -n "${CONFIG[obfs_junk_count]}" && "${CONFIG[obfs_junk_count]}" != "0" ]]; then
        CONFIG[obfs_junk_min]="${BH_JUNK_MIN:-40}"; CONFIG[obfs_junk_max]="${BH_JUNK_MAX:-1000}"
    fi
    # adaptive is a client-side prompt, written even when off
    CONFIG[adaptive]="${BH_ADAPTIVE}"
    [[ "$mode" == "client" ]] && CONFIG[adaptive]="${BH_ADAPTIVE:-false}"
    CONFIG[adaptive_failures]="${BH_ADAPTIVE_FAILURES}"; CONFIG[adaptive_carriers]="${BH_ADAPTIVE_CARRIERS:+$(csv_to_toml_array "$BH_ADAPTIVE_CARRIERS")}"
    # ENHANCEMENT — active pre-probe (client-side; empty BH_* => key omitted => reactive-only default)
    CONFIG[adaptive_probe]="${BH_ADAPTIVE_PROBE}"; CONFIG[adaptive_probe_interval]="${BH_ADAPTIVE_PROBE_INTERVAL}"; CONFIG[adaptive_probe_fails]="${BH_ADAPTIVE_PROBE_FAILS}"
    # Dagger-fusion Stage-1 toggles (empty => key omitted => faithful default off)
    CONFIG[tls_fragment]="${BH_TLS_FRAGMENT}"; CONFIG[probe_decoy]="${BH_PROBE_DECOY}"; CONFIG[runtime_tune]="${BH_RUNTIME_TUNE}"
    # Stage-4: obfs_padding (tcp/tcpmux noise padding) + tls_fingerprint (anytls uTLS) — both [transport].
    CONFIG[obfs_padding]="${BH_OBFS_PADDING}"; CONFIG[tls_fingerprint]="${BH_TLS_FINGERPRINT}"
    CONFIG[pad_frames]="${BH_PAD_FRAMES}"; CONFIG[pad_min]="${BH_PAD_MIN}"; CONFIG[pad_max]="${BH_PAD_MAX}"
    CONFIG[kcp_mode]="${BH_KCP_MODE:-fast2}"; CONFIG[kcp_data_shards]="${BH_KCP_DATA:-10}"
    CONFIG[kcp_parity_shards]="${BH_KCP_PARITY:-3}"; CONFIG[kcp_mtu]="${BH_KCP_MTU:-1350}"
    CONFIG[tun_encapsulation]="${BH_TUN_ENCAP}"
    # tun device name: default to a UNIQUE per-port name (leech<port>) so two tun endpoints
    # co-hosted on one node never share the "leech" device — otherwise Fix 3's delete-by-name
    # cleanup (ExecStartPre / panel_rm) on one tunnel could tear down another's live device.
    # Panel/non-interactive path only; the interactive prompt keeps the plain "leech" default.
    local _tun_port="${BH_BIND##*:}${BH_REMOTE##*:}"; _tun_port="${_tun_port//[^0-9]/}"
    local _tun_nm="${BH_TUN_NAME:-leech${_tun_port:-0}}"
    # the legacy default "leech" is SHARED by every tun tunnel → two tun tunnels (or an edit of
    # one while it still holds the device) collide on it and the create fails. Force it unique
    # per port even when the panel/env passes a bare "leech".
    [[ "$_tun_nm" == "leech" ]] && _tun_nm="leech${_tun_port:-0}"
    CONFIG[tun_name]="$_tun_nm"
    CONFIG[tun_local_addr]="${BH_TUN_LOCAL:-10.10.10.1/24}"; CONFIG[tun_remote_addr]="${BH_TUN_REMOTE:-10.10.10.2/24}"
    CONFIG[tun_health_port]="${BH_TUN_HEALTH:-1234}"
    # Stage-4: tun/tcp outer-stream token auth (the writer emits it only when encap != ipx).
    CONFIG[tun_outer_auth]="${BH_TUN_AUTH}"
    # the raw engine adds outer headers, so it needs the smaller MTU the
    # interactive path offers (1320 vs 1500) — the panel has one field for both
    local _def_mtu=1500; [[ "${BH_TUN_ENCAP}" == "ipx" ]] && _def_mtu=1320
    CONFIG[tun_mtu]="${BH_TUN_MTU:-$_def_mtu}"
    CONFIG[ipx_mode]="${BH_IPX_MODE}"; CONFIG[ipx_profile]="${BH_IPX_PROFILE:-tcp}"
    CONFIG[ipx_listen_ip]="${BH_IPX_LISTEN}"; CONFIG[ipx_dst_ip]="${BH_IPX_DST}"
    # the NIC name is per-box, so it must be resolved here and not by the panel
    CONFIG[ipx_interface]="${BH_IPX_IFACE:-$(ip route show default 2>/dev/null | awk '{print $5; exit}')}"
    # Stage-4: raw-engine ipx controls (empty => key omitted => profile/faithful default).
    CONFIG[ipx_protocol]="${BH_IPX_PROTOCOL}"
    CONFIG[ipx_spoof_src]="${BH_IPX_SPOOF_SRC}"; CONFIG[ipx_spoof_dst]="${BH_IPX_SPOOF_DST}"
    CONFIG[ipx_custom_packet]="${BH_IPX_CUSTOM}"
    CONFIG[ipx_proto58]="${BH_IPX_PROTO58}"
    CONFIG[ipx_proto58_src6]="${BH_IPX_PROTO58_SRC6}"; CONFIG[ipx_proto58_dst6]="${BH_IPX_PROTO58_DST6}"
    CONFIG[ipx_proto58_gwmac]="${BH_IPX_PROTO58_GWMAC}"
    CONFIG[ipx_allowed_client_ips]="${BH_IPX_ALLOWED:+$(csv_to_toml_array "$BH_IPX_ALLOWED")}"
    CONFIG[auto_tuning]="${BH_AUTO_TUNING:-true}"; CONFIG[tuning_profile]="${BH_TUNING_PROFILE:-balanced}"
    CONFIG[workers]="${BH_WORKERS:-0}"
    # a layer-3 device sees far more packets per second than a stream carrier, so
    # the interactive path gives tun a much deeper channel
    local _def_chan=4096; [[ "${BH_TYPE}" == "tun" ]] && _def_chan=10000
    CONFIG[channel_size]="${BH_CHANNEL:-$_def_chan}"
    # batch_size default 2048 to MATCH the interactive path (prompt_with_default "Batch Size" "2048").
    # The ipx engine's validatePerformanceSection REQUIRES batch_size>0, so a panel/--gen tunnel that
    # omitted it (empty BH_BATCH) FATAL'd "batch_size must be > 0" — every ipx tunnel from the panel
    # failed to start. Defaulting it here fixes ipx; harmless for the stream transports (unused).
    CONFIG[batch_size]="${BH_BATCH:-2048}"; CONFIG[read_timeout]="${BH_READ_TIMEOUT}"
    # Stage-4: [tuning] extras — tpacket_profile (ipx ring geometry), max_connections, write_timeout (sec).
    CONFIG[tpacket_profile]="${BH_TPACKET_PROFILE}"; CONFIG[max_connections]="${BH_MAX_CONN}"; CONFIG[write_timeout_sec]="${BH_WRITE_TIMEOUT_SEC}"
    CONFIG[log_level]="${BH_LOG:-info}"
    # the forwarder choice is a tun-only helper (the interactive path only asks for
    # it there); on a stream transport the core's own default applies
    if [[ "${BH_TYPE}" == "tun" ]]; then CONFIG[forwarder]="${BH_FORWARDER:-leech}"; else CONFIG[forwarder]="${BH_FORWARDER}"; fi
    CONFIG[ports_mapping]="${BH_PORTS}"; CONFIG[enable_encryption]="${BH_ENC:-false}"
    # The interactive path answers these prompts (and therefore writes them, even at
    # their zero value) under exactly the conditions below. Mirror the same gates, or
    # the two entry points produce configs that differ only on paper — or, worse,
    # carry a key on a transport the interactive path never writes it for.
    CONFIG[accept_udp]="${BH_ACCEPT_UDP}"
    [[ "$mode" == "server" && "${BH_TYPE:-tcp}" == "tcp" ]] && CONFIG[accept_udp]="${BH_ACCEPT_UDP:-false}"
    CONFIG[proxy_protocol]="${BH_PROXY_PROTO}"
    [[ "$mode" == "server" && ! "${BH_TYPE:-tcp}" =~ ^(tun|ws)$ && "${BH_TUN_ENCAP}" != "ipx" ]] && CONFIG[proxy_protocol]="${BH_PROXY_PROTO:-false}"
    if [[ "${BH_TUN_ENCAP}" == "ipx" ]]; then
        CONFIG[tcp_mss]="${BH_TCP_MSS}"; CONFIG[so_rcvbuf]="${BH_SO_RCVBUF}"
        CONFIG[so_sndbuf]="${BH_SO_SNDBUF:-0}"; CONFIG[buffer_profile]="${BH_BUFFER_PROFILE}"
    else
        CONFIG[tcp_mss]="${BH_TCP_MSS:-0}"; CONFIG[so_rcvbuf]="${BH_SO_RCVBUF:-0}"
        CONFIG[so_sndbuf]="${BH_SO_SNDBUF:-0}"
        # buffer_profile + read_timeout are stream-only prompts
        if [[ "${BH_TYPE:-tcp}" == "tun" ]]; then CONFIG[buffer_profile]="${BH_BUFFER_PROFILE}"
        else CONFIG[buffer_profile]="${BH_BUFFER_PROFILE:-balanced}"; fi
    fi
    CONFIG[kcp_snd_wnd]="${BH_KCP_SND_WND}"; CONFIG[kcp_rcv_wnd]="${BH_KCP_RCV_WND}"
    # http/https mimicry ([http_settings]) — all optional (carrier applies browser-realistic defaults)
    CONFIG[http_fake_domain]="${BH_HTTP_FAKE_DOMAIN}"; CONFIG[http_fake_ua]="${BH_HTTP_FAKE_UA}"
    CONFIG[http_path]="${BH_HTTP_PATH}"; CONFIG[http_session_cookie]="${BH_HTTP_COOKIE}"
    # quantum forged-TCP ([quantum]) — mtu/block/shards default in the writer; iface/local_ip auto if empty
    CONFIG[quantum_mtu]="${BH_QUANTUM_MTU:-1350}"; CONFIG[quantum_block]="${BH_QUANTUM_BLOCK:-aes}"
    CONFIG[quantum_data_shards]="${BH_QUANTUM_DATA:-10}"; CONFIG[quantum_parity_shards]="${BH_QUANTUM_PARITY:-1}"
    CONFIG[quantum_flags]="${BH_QUANTUM_FLAGS}"; CONFIG[quantum_interface]="${BH_QUANTUM_IFACE}"; CONFIG[quantum_local_ip]="${BH_QUANTUM_LOCAL_IP}"
    CONFIG[quantum_snd_wnd]="${BH_QUANTUM_SND_WND}"; CONFIG[quantum_rcv_wnd]="${BH_QUANTUM_RCV_WND}"
    # Stage-4: quantum ipv6 (fake-TCP IPv6 src), router (gateway MAC override), read_buffer (pcap ring).
    CONFIG[quantum_ipv6]="${BH_QUANTUM_IPV6}"; CONFIG[quantum_router]="${BH_QUANTUM_ROUTER}"; CONFIG[quantum_read_buffer]="${BH_QUANTUM_READ_BUFFER}"
    # icmp type/code are prompted (default 0) ONLY for the icmp profile — mirror that gate
    # so the generated TOML matches the interactive path (icmp_type=0/icmp_code=0), and
    # they are never written for other profiles.
    if [[ "${CONFIG[ipx_profile]}" == "icmp" ]]; then
        CONFIG[ipx_icmp_type]="${BH_IPX_ICMP_TYPE:-0}"; CONFIG[ipx_icmp_code]="${BH_IPX_ICMP_CODE:-0}"
    else
        CONFIG[ipx_icmp_type]="${BH_IPX_ICMP_TYPE}"; CONFIG[ipx_icmp_code]="${BH_IPX_ICMP_CODE}"
    fi
    # these are written UNCONDITIONALLY inside their blocks when enabled, so default
    # them (empty would emit invalid TOML like 'kdf_iterations = ')
    CONFIG[algorithm]="${BH_ALGORITHM:-aes-256-gcm}"; CONFIG[kdf_iterations]="${BH_KDF_ITER:-100000}"
    # an empty PSK with encryption on is a config that looks encrypted and is not. Guard it
    # with a real error message on STDERR (the old ${BH_PSK:?...} aborted the whole shell
    # BEFORE any echo, and panel_create suppressed stderr → the panel saw an empty exit 1).
    if [[ "${CONFIG[enable_encryption]}" == "true" ]]; then
        if [[ -z "${BH_PSK:-}" ]]; then
            echo "PSK is required when encryption is enabled" >&2; return 1
        fi
        CONFIG[psk]="${BH_PSK}"
    else
        CONFIG[psk]="${BH_PSK}"
    fi
    CONFIG[ring_size]="${BH_RING_SIZE:-64}"; CONFIG[frame_size]="${BH_FRAME_SIZE:-2048}"
    CONFIG[peer_idle_timeout_s]="${BH_PEER_IDLE:-120}"; CONFIG[write_timeout_ms]="${BH_WRITE_TIMEOUT:-3}"
    local is_tun=false is_ipx=false
    [[ "${CONFIG[transport_type]}" == "tun" ]] && is_tun=true
    [[ "${CONFIG[tun_encapsulation]}" == "ipx" ]] && is_ipx=true
    # The ipx raw-packet engine has no TCP socket, so the interactive path never
    # asks for (and never emits) these. Blank them here too, or a panel-created ipx
    # tunnel would carry socket knobs the configurator's own output does not have.
    if [[ "$is_ipx" == "true" ]]; then
        CONFIG[nodelay]=""; CONFIG[keepalive_period]=""
        CONFIG[dial_timeout]=""; CONFIG[retry_interval]=""
        CONFIG[connection_pool]=""; CONFIG[congestion]=""; CONFIG[obfuscation]=""
    fi
    generate_toml_config "$mode" "$out" "$is_tun" "$is_ipx"
    echo "generated $out (type=${CONFIG[transport_type]} mode=$mode)"
}
# The default LEECH license key baked into the configurator + panel. Pressing Enter
# uses it; a customer can paste their own key. Controlled from the license panel
# (revoke this key to cut off every default install).
DEFAULT_LICENSE_KEY="LEECH-H34M-CLUX-3PMU-2REK"
prompt_license_section() {
    colorize blue "━━━ License ━━━" bold
    colorize magenta "Your LEECH license key (from the license panel). Press Enter to use the default." normal
    prompt_with_default "License key" "$DEFAULT_LICENSE_KEY" "CONFIG[license_key]"
    echo ""
}
configure_server() {
    local mode="$1"  # server or client
    local mode_name
    if [[ "$mode" == "server" ]]; then
        mode_name="IRAN (Server)"
    else
        mode_name="KHAREJ (Client)"
    fi
    clear
    colorize cyan "Configuring $mode_name" bold
    echo ""
    reset_config
    prompt_license_section
    prompt_transport_section "$mode"
    local is_tun="false"
    local is_ipx="false"
    [[ "${CONFIG[transport_type]}" == "tun" ]] && is_tun="true"
    [[ "${CONFIG[tun_encapsulation]}" == "ipx" ]] && is_ipx="true"
    prompt_tun_section "${CONFIG[transport_type]}" "$mode" "$is_ipx"
    prompt_ipx_section "$is_ipx" "$mode"
    if [[ "$is_ipx" != "true" ]]; then
        prompt_connection_section "$mode"
    fi
    prompt_security_section "$is_ipx"
    prompt_accept_udp_section "${CONFIG[accept_udp]}"
    prompt_mux_section "${CONFIG[transport_type]}"
    prompt_tls_section "$mode" "${CONFIG[transport_type]}"
    prompt_kcp_section "${CONFIG[transport_type]}"
    prompt_http_section "${CONFIG[transport_type]}"
    prompt_quantum_section "${CONFIG[transport_type]}"
    prompt_dpi_section "$mode" "${CONFIG[transport_type]}"
    prompt_tuning_section "$is_ipx" "$is_tun"
    prompt_logging_section
    prompt_ports_section "$mode" "$is_tun"
    local tunnel_port
    if [[ "$mode" == "server" ]]; then
        tunnel_port=$(echo "${CONFIG[bind_addr]}" | grep -oP ':\K[0-9]+$')
    else
        tunnel_port=$(echo "${CONFIG[remote_addr]}" | grep -oP ':\K[0-9]+$')
    fi
    if [[ -z "$tunnel_port" ]]; then
        tunnel_port=$(echo "${CONFIG[tun_health_port]}")
    fi
    local config_file
    if [[ "$mode" == "server" ]]; then
        config_file="${config_dir}/iran${tunnel_port}.toml"
    else
        config_file="${config_dir}/kharej${tunnel_port}.toml"
    fi
    generate_toml_config "$mode" "$config_file" "$is_tun" "$is_ipx"
    local service_type
    [[ "$mode" == "server" ]] && service_type="iran" || service_type="kharej"
    create_systemd_service "$service_type" "$tunnel_port" "$config_file"
    echo ""
    colorize green "✔ Configuration completed successfully!" bold
    echo ""
    press_key
}
create_systemd_service() {
    local type="$1"
    local port="$2"
    local config_file="$3"
    local service_file="${service_dir}/leech-${type}${port}.service"
    local desc_type="$(tr '[:lower:]' '[:upper:]' <<< "${type:0:1}")${type:1}"
    # Fix 3: tun/ipx endpoints name a tun device in their [tun] section. A crashed or
    # killed core can leave that device behind, and the next start then fails with
    # "exit status 1". Bake a best-effort delete (leading '-' → ignore failure) so a
    # leftover device never blocks a restart/recreate.
    # Guarded via --tun-cleanup so the device is deleted ONLY when no OTHER config still
    # claims the same name — a co-hosted tun tunnel that shares the name (legacy "leech"
    # default) is never torn out from under. New tunnels get a unique leech<port> name, so
    # this is belt-and-braces. Leading '-' → systemd ignores any failure.
    local pre_cleanup="" svc_tun_dev
    svc_tun_dev=$(awk -F'"' '/^name = /{print $2; exit}' "$config_file" 2>/dev/null)
    [[ -n "$svc_tun_dev" ]] && pre_cleanup="ExecStartPre=-${config_dir}/leech.sh --tun-cleanup ${svc_tun_dev}"
    # Health-status toggle: when the panel/operator turned "precise health monitoring" off,
    # bake it into the unit env so the core skips writing /run/leech-<name>.status → --stats
    # falls back to its socket/active heuristic. Default (unset/true) leaves it ON.
    local health_env=""
    [[ "${BH_HEALTH_STATUS:-}" =~ ^(0|false|no|off)$ ]] && health_env="Environment=BH_HEALTH_STATUS=0"
    cat > "$service_file" <<EOF
[Unit]
Description=LEECH $desc_type Port $port
After=network.target
[Service]
Type=simple
User=root
${pre_cleanup}
${health_env}
ExecStart=${config_dir}/leech -c $config_file
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
IPAccounting=yes
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "leech-${type}${port}.service" >/dev/null 2>&1
    colorize green "✔ Service leech-${type}${port} created and started" bold
}
SERVER_IP=$(hostname -I | awk '{print $1}')
if [[ "${1:-}" != --* ]]; then
    SERVER_COUNTRY=$(curl -sS --max-time 1 "http://ipwhois.app/json/$SERVER_IP" 2>/dev/null | jq -r '.country')
    SERVER_ISP=$(curl -sS --max-time 1 "http://ipwhois.app/json/$SERVER_IP" 2>/dev/null | jq -r '.isp')
fi
display_logo() {
    echo -e "\033[36m"
    cat << "EOF"
██╗     ███████╗███████╗ ██████╗██╗  ██╗
██║     ██╔════╝██╔════╝██╔════╝██║  ██║
██║     █████╗  █████╗  ██║     ███████║
██║     ██╔══╝  ██╔══╝  ██║     ██╔══██║
███████╗███████╗███████╗╚██████╗██║  ██║
╚══════╝╚══════╝╚══════╝ ╚═════╝╚═╝  ╚═╝
Lightning-fast reverse tunneling solution
EOF
    echo -e "\033[0m\033[32m"
    echo -e "Script Version: \033[33m${SCRIPT_VERSION}\033[32m"
    [[ -f "${config_dir}/leech" ]] && \
    echo -e "Core Version: \033[33m$($config_dir/leech -v)\033[32m"
}
display_server_info() {
    echo -e "\e[93m═══════════════════════════════════════════\e[0m"
    echo -e "\033[36mIP Address:\033[0m $SERVER_IP"
    echo -e "\033[36mLocation:\033[0m $SERVER_COUNTRY"
    echo -e "\033[36mDatacenter:\033[0m $SERVER_ISP"
}
display_leech_core_status() {
    if [[ -f "${config_dir}/leech" ]]; then
        echo -e "\033[36mLEECH Core:\033[0m \033[32mInstalled\033[0m"
    else
        echo -e "\033[36mLEECH Core:\033[0m \033[31mNot installed\033[0m"
    fi
    echo -e "\e[93m═══════════════════════════════════════════\e[0m"
}
check_config_backup() {
    missing_services=()
    for config in "${config_dir}"/iran*.toml "${config_dir}"/kharej*.toml; do
        [ -e "$config" ] || continue
        fname=$(basename "$config")
        if [[ "$fname" =~ ^(iran|kharej)([0-9]+)\.toml$ ]]; then
            location="${BASH_REMATCH[1]}"
            tunnel_port="${BASH_REMATCH[2]}"
            service_file="${service_dir}/leech-${location}${tunnel_port}.service"
            if [[ ! -f "$service_file" ]]; then
                missing_services+=("$service_file:$location:$tunnel_port")
            fi
        fi
    done
    [[ ${#missing_services[@]} -eq 0 ]] && return 0
    echo
    colorize red "Missing service files:" bold
    for entry in "${missing_services[@]}"; do
        service_file="${entry%%:*}"
        location="${entry#*:}"; location="${location%%:*}"
        tunnel_port="${entry##*:}"
        echo "- $service_file (type: $location, port: $tunnel_port)"
    done
    echo
    read -r -p "Do you want to create missing service files? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for entry in "${missing_services[@]}"; do
            service_file="${entry%%:*}"
            location="${entry#*:}"; location="${location%%:*}"
            tunnel_port="${entry##*:}"
            config_file="${config_dir}/${location}${tunnel_port}.toml"
            desc_loc="$(tr '[:lower:]' '[:upper:]' <<< "${location:0:1}")${location:1}"
            cat > "$service_file" <<EOF
[Unit]
Description=LEECH $desc_loc Port $tunnel_port
After=network.target
[Service]
Type=simple
User=root
ExecStart=${config_dir}/leech -c $config_file
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
IPAccounting=yes
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
            sudo systemctl daemon-reload
            sudo systemctl enable --now "$(basename "$service_file")"
            echo "Created and started $(basename "$service_file")"
        done
    fi
    sleep 2
}
[[ "${1:-}" != --* ]] && check_config_backup
check_tunnel_status() {
    if ! ls "$config_dir"/*.toml 1> /dev/null 2>&1; then
        colorize red "No config files found." bold
        press_key
        return 1
    fi
    clear
    colorize yellow "Checking all services status..." bold
    sleep 1
    echo
    for config_path in "$config_dir"/{iran,kharej}*.toml; do
        [ -f "$config_path" ] || continue
        config_name=$(basename "$config_path")
        config_name="${config_name%.toml}"
        service_name="leech-${config_name}.service"
        if [[ "$config_name" =~ ^iran([0-9]+)$ ]]; then
            port="${BASH_REMATCH[1]}"
            if systemctl is-active --quiet "$service_name"; then
                colorize green "Iran service (port $port) is running"
            else
                colorize red "Iran service (port $port) is not running"
            fi
        elif [[ "$config_name" =~ ^kharej([0-9]+)$ ]]; then
            port="${BASH_REMATCH[1]}"
            if systemctl is-active --quiet "$service_name"; then
                colorize green "Kharej service (port $port) is running"
            else
                colorize red "Kharej service (port $port) is not running"
            fi
        fi
    done
    echo
    press_key
}
tunnel_management() {
    if ! ls "$config_dir"/*.toml 1> /dev/null 2>&1; then
        colorize red "No config files found." bold
        press_key
        return 1
    fi
    clear
    colorize cyan "Existing services:" bold
    echo
    local index=1
    declare -a configs
    for config_path in "$config_dir"/{iran,kharej}*.toml; do
        [ -f "$config_path" ] || continue
        config_name=$(basename "$config_path")
        if [[ "$config_name" =~ ^iran([0-9]+)\.toml$ ]]; then
            port="${BASH_REMATCH[1]}"
            configs+=("$config_path")
            echo -e "\033[35m${index}\033[0m) \033[32mIran\033[0m (port: \033[33m$port\033[0m)"
            ((index++))
        elif [[ "$config_name" =~ ^kharej([0-9]+)\.toml$ ]]; then
            port="${BASH_REMATCH[1]}"
            configs+=("$config_path")
            echo -e "\033[35m${index}\033[0m) \033[32mKharej\033[0m (port: \033[33m$port\033[0m)"
            ((index++))
        fi
    done
    echo
    echo -ne "Enter your choice (0 to return): "
    read -r choice
    [[ "$choice" == "0" ]] && return
    while ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#configs[@]} )); do
        colorize red "Invalid choice."
        echo -ne "Enter your choice (0 to return): "
        read -r choice
        [[ "$choice" == "0" ]] && return
    done
    selected_config="${configs[$((choice - 1))]}"
    config_name=$(basename "${selected_config%.toml}")
    service_name="leech-${config_name}.service"
    clear
    colorize cyan "Manage $config_name:" bold
    echo
    colorize red "1) Remove this tunnel"
    colorize yellow "2) Restart this tunnel"
    echo "3) View service logs"
    echo "4) View service status"
    echo
    read -r -p "Enter your choice (0 to return): " choice
    case $choice in
        1) destroy_tunnel "$selected_config" ;;
        2) restart_service "$service_name" ;;
        3) view_service_logs "$service_name" ;;
        4) view_service_status "$service_name" ;;
        0) return ;;
        *) colorize red "Invalid option!" && sleep 1 ;;
    esac
}
destroy_tunnel() {
    config_path="$1"
    config_name=$(basename "${config_path%.toml}")
    service_name="leech-${config_name}.service"
    service_path="$service_dir/$service_name"
    [ -f "$config_path" ] && rm -f "$config_path"
    if [[ -f "$service_path" ]]; then
        systemctl is-active --quiet "$service_name" && systemctl disable --now "$service_name" >/dev/null 2>&1
        rm -f "$service_path"
    fi
    systemctl daemon-reload
    echo
    colorize green "Tunnel destroyed successfully!" bold
    echo
    press_key
}
restart_service() {
    echo
    colorize yellow "Restarting $1" bold
    if systemctl list-units --type=service | grep -q "$1"; then
        systemctl restart "$1"
        colorize green "Service restarted successfully" bold
        echo
    else
        colorize red "Service not found"
    fi
    press_key
}
view_service_logs() {
    clear
    journalctl -eu "$1" -f -o cat
}
view_service_status() {
    clear
    systemctl status "$1"
    press_key
}
remove_core() {
    if find "$config_dir" -type f -name "*.toml" | grep -q .; then
        colorize red "Delete all services first."
        sleep 3
        return 1
    fi
    colorize yellow "Remove LEECH-Core? (y/n)"
    read -r confirm
    if [[ $confirm == [yY] ]]; then
        [[ -d "$config_dir" ]] && rm -rf "$config_dir"
        colorize green "LEECH-Core removed." bold
    fi
    press_key
}
update_script() {
    return
    DEST_DIR="/usr/bin/"
    LEECH_SCRIPT="leech"
    SCRIPT_URL="http://ir.leech-dev.com:2095/leech.sh"
    [ -f "$DEST_DIR/$LEECH_SCRIPT" ] && rm "$DEST_DIR/$LEECH_SCRIPT"
    if curl -s -L -o "$DEST_DIR/$LEECH_SCRIPT" "$SCRIPT_URL"; then
        chmod +x "$DEST_DIR/$LEECH_SCRIPT"
        colorize yellow "Type 'leech' to run the script." bold
        exit 0
    else
        colorize red "Download failed."
    fi
    press_key
}
configure_tunnel() {
    [[ ! -d "$config_dir" ]] && {
        colorize red "Install LEECH-Core first."
        press_key
        return 1
    }
    clear
    echo ""
    colorize green "1) Configure IRAN (Server)" bold
    colorize magenta "2) Configure KHAREJ (Client)" bold
    echo ""
    read -r -p "Enter your choice: " configure_choice
    case "$configure_choice" in
        1) configure_server "server" ;;
        2) configure_server "client" ;;
        *) colorize red "Invalid option!" && sleep 1 ;;
    esac
}
# ===== Web panel (GUI) =====
PANEL_BIN_URL="https://raw.githubusercontent.com/ALIZA4004/LeechTunnel/main/leech-panel"

install_panel() {
    clear; colorize cyan "Install the LEECH web panel (this server becomes the control hub)" bold; echo
    local port pw pw2
    prompt_with_default "Panel port" "8443" port
    [[ "$port" =~ ^[0-9]+$ ]] || { colorize red "invalid port"; press_key; return; }
    read -rsp "Set an admin password: " pw; echo
    read -rsp "Confirm password: " pw2; echo
    [ "$pw" != "$pw2" ] && { colorize red "passwords do not match"; press_key; return; }
    [ ${#pw} -lt 6 ] && { colorize red "password too short (min 6)"; press_key; return; }
    mkdir -p /etc/leech-panel "$config_dir"
    if [ ! -f "$config_dir/leech-panel" ]; then
        colorize yellow "Downloading panel binary…"
        curl -fL --progress-bar -o "$config_dir/leech-panel" "$PANEL_BIN_URL" || {
            colorize red "download failed — place the binary at $config_dir/leech-panel and re-run"; press_key; return; }
    fi
    chmod +x "$config_dir/leech-panel"
    [ -f /etc/leech-panel/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f /etc/leech-panel/id_ed25519 -q
    local sha tok myip hn
    sha=$(printf '%s' "$pw" | sha256sum | awk '{print $1}')
    tok=$(openssl rand -hex 24)
    myip=$(hostname -I | awk '{print $1}'); hn=$(hostname)
    cat > /etc/leech-panel/config.json <<EOF
{
  "port": $port,
  "admin_password_sha256": "$sha",
  "api_token": "$tok",
  "ssh_key_path": "/etc/leech-panel/id_ed25519",
  "nodes": [{"id":"local","name":"$hn","role":"both","host":"$myip","ssh_user":"root","ssh_port":22,"local":true}],
  "tunnels": []
}
EOF
    chmod 600 /etc/leech-panel/config.json
    cat > /etc/systemd/system/leech-panel.service <<EOF
[Unit]
Description=LEECH Web Panel
After=network.target
[Service]
Type=simple
ExecStart=$config_dir/leech-panel --config /etc/leech-panel/config.json
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now leech-panel >/dev/null 2>&1
    echo
    if systemctl is-active --quiet leech-panel; then
        colorize green "✔ Panel is running:  http://${myip}:${port}" bold
    else
        colorize red "panel failed to start — check: journalctl -u leech-panel -n 30"
    fi
    echo
    colorize cyan "To add a node: in the panel open Nodes → Enroll, fill name + IP, and copy the"
    colorize cyan "per-node token it shows. On the node run this script → 'Connect to panel' and"
    colorize cyan "paste the token with this panel's URL — the node authorizes itself. The token is"
    colorize cyan "single-use and only valid from that node's own IP; no password is ever sent."
    echo
    colorize yellow "Manual fallback — the panel's SSH public key (only needed if you skip the token flow):"
    cat /etc/leech-panel/id_ed25519.pub
    press_key
}

# Replace the panel binary in place. The running binary's file is busy, so the new
# one lands under a temp name and is swapped while the service is stopped; the old
# build is kept as .bak so a bad download can be rolled back.
update_panel() {
    if [ ! -f "$config_dir/leech-panel" ]; then
        colorize red "panel is not installed here"; press_key; return
    fi
    colorize cyan "downloading the latest panel build…"
    if ! curl -fL --progress-bar -o "$config_dir/leech-panel.new" "$PANEL_BIN_URL"; then
        colorize red "download failed — nothing was changed"; rm -f "$config_dir/leech-panel.new"; press_key; return
    fi
    chmod +x "$config_dir/leech-panel.new"
    if ! "$config_dir/leech-panel.new" --help >/dev/null 2>&1; then
        colorize red "the downloaded file is not a working panel binary — nothing was changed"
        rm -f "$config_dir/leech-panel.new"; press_key; return
    fi
    systemctl stop leech-panel 2>/dev/null
    cp -f "$config_dir/leech-panel" "$config_dir/leech-panel.bak" 2>/dev/null
    mv -f "$config_dir/leech-panel.new" "$config_dir/leech-panel"
    chmod +x "$config_dir/leech-panel"
    systemctl start leech-panel 2>/dev/null
    sleep 1.5
    if systemctl is-active --quiet leech-panel; then
        colorize green "panel updated and running (previous build kept at leech-panel.bak)"
    else
        colorize red "the new build failed to start — rolling back"
        mv -f "$config_dir/leech-panel.bak" "$config_dir/leech-panel" 2>/dev/null
        systemctl start leech-panel 2>/dev/null
        journalctl -u leech-panel -n 15 --no-pager 2>/dev/null
    fi
    press_key
}
change_panel_password() {
    if [ ! -f /etc/leech-panel/config.json ]; then colorize red "no panel is installed on this server"; press_key; return; fi
    local pw pw2
    read -rsp " New panel password: " pw; echo
    read -rsp " Confirm password: " pw2; echo
    if [ "$pw" != "$pw2" ]; then colorize red "passwords do not match"; press_key; return; fi
    if [ ${#pw} -lt 6 ]; then colorize red "password too short (min 6)"; press_key; return; fi
    local sha; sha=$(printf '%s' "$pw" | sha256sum | awk '{print $1}')
    install_jq
    if jq --arg s "$sha" '.admin_password_sha256=$s' /etc/leech-panel/config.json > /etc/leech-panel/config.json.tmp 2>/dev/null && [ -s /etc/leech-panel/config.json.tmp ]; then
        mv -f /etc/leech-panel/config.json.tmp /etc/leech-panel/config.json; chmod 600 /etc/leech-panel/config.json
        systemctl restart leech-panel 2>/dev/null
        colorize green "✔ panel password updated"
    else
        rm -f /etc/leech-panel/config.json.tmp; colorize red "failed to update the config"
    fi
    press_key
}
configure_panel() {
    while true; do
        clear; display_logo; echo
        colorize cyan " Web Panel (GUI)" bold; echo
        local st; systemctl is-active --quiet leech-panel 2>/dev/null && st="\033[32mrunning\033[0m" || st="\033[31mnot installed\033[0m"
        echo -e " Status: $st"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        colorize green " 1. Install panel (become the control hub)" bold
        colorize magenta " 2. Change panel password" bold
        echo " 3. Panel status / logs"
        echo " 4. Update panel to the latest build"
        echo " 5. Remove panel"
        echo " 0. Back"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        local ch; read -r -p "Choice [0-5]: " ch
        case $ch in
            1) install_panel ;;
            2) change_panel_password ;;
            3) systemctl status leech-panel --no-pager 2>&1 | head -12; echo; journalctl -u leech-panel -n 15 --no-pager 2>/dev/null; press_key ;;
            4) update_panel ;;
            5) systemctl disable --now leech-panel 2>/dev/null; rm -f /etc/systemd/system/leech-panel.service; systemctl daemon-reload 2>/dev/null; colorize green "panel removed"; press_key ;;
            0) return ;;
            *) colorize red "invalid"; sleep 1 ;;
        esac
    done
}

display_menu() {
    clear
    display_logo
    display_server_info
    display_leech_core_status
    echo
    colorize green " 1. Configure a new tunnel" bold
    colorize red " 2. Tunnel management" bold
    colorize cyan " 3. Check tunnel status" bold
    colorize magenta " 4. Web panel (GUI)" bold
    echo " 5. Update LEECH Core"
    echo " 6. Update script"
    echo " 7. Remove LEECH Core"
    echo " 0. Exit"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
read_option() {
    read -r -p "Enter your choice [0-7]: " choice
    case $choice in
        1) configure_tunnel ;;
        2) tunnel_management ;;
        3) check_tunnel_status ;;
        4) configure_panel ;;
        5) download_and_extract_leech "menu" ;;
        6) update_script ;;
        7) remove_core ;;
        0) exit 0 ;;
        *) colorize red "Invalid option!" && sleep 1 ;;
    esac
}
# Non-interactive entrypoint for scripted deploys / multi-transport testing.
if [[ "${1:-}" == "--gen" ]]; then
    gen_noninteractive "${2:?usage: --gen <server|client> <out.toml>}" "${3:?usage: --gen <server|client> <out.toml>}"
    exit $?
fi

# ===== non-interactive panel API (driven by leech-panel over SSH/local exec) =====
# JSON in, JSON out. All input comes from BH_* env (already validated by the panel)
# or a strict <type><port> id; nothing is interpolated from free-form user text.

# --create <server|client> : BH_* env -> TOML -> systemd unit -> start.  emits JSON
# --tun-cleanup <dev> : delete a leftover tun device, but ONLY if no OTHER endpoint config
# still claims that device name. Baked as an ExecStartPre so a leftover device never blocks a
# start, without ever tearing down a co-hosted tunnel that legitimately shares the name.
tun_cleanup() {
    local dev="$1" used=0 f
    [[ -n "$dev" ]] || return 0
    for f in "${config_dir}"/{iran,kharej}*.toml; do
        [[ -f "$f" ]] || continue
        [[ "$(awk -F'"' '/^name = /{print $2; exit}' "$f" 2>/dev/null)" == "$dev" ]] && used=$((used+1))
    done
    [[ "$used" -le 1 ]] && ip link del "$dev" >/dev/null 2>&1
    return 0
}

panel_create() {
    # NOTE: gen_noninteractive/generate_toml_config assign to a non-local `port`,
    # which would clobber a `local port` here via bash dynamic scoping — so use
    # uniquely-named locals captured BEFORE calling gen.
    local mode="$1" pc_typ pc_port pc_out pc_svc pc_act
    # Fix 3: raw-packet transports (quantum, tun/ipx) link libpcap at runtime; a freshly
    # panel-provisioned node may lack it because the non-interactive path skips the normal
    # install. Ensure it now — a cheap ldconfig no-op when already present.
    case "${BH_TYPE:-}" in quantum|tun) install_libpcap >/dev/null 2>&1 ;; esac
    if [[ "$mode" == "server" ]]; then pc_typ=iran;   pc_port="${BH_BIND##*:}"
    else                               pc_typ=kharej; pc_port="${BH_REMOTE##*:}"; fi
    [[ "$pc_port" =~ ^[0-9]+$ ]] || { echo '{"ok":false,"error":"could not derive port from BH_BIND/BH_REMOTE"}'; return 1; }
    pc_out="${config_dir}/${pc_typ}${pc_port}.toml"
    pc_svc="leech-${pc_typ}${pc_port}"
    local gen_out
    if ! gen_out=$(gen_noninteractive "$mode" "$pc_out" 2>&1); then
        # surface gen's own last line (its real reason) instead of a bare generic — otherwise
        # a gen abort is an invisible empty exit-1 to the panel.
        local msg; msg=$(printf '%s' "$gen_out" | tail -1 | tr -cd '[:alnum:] .:/_-')
        echo "{\"ok\":false,\"error\":\"config generation failed: ${msg}\"}"; return 1
    fi
    create_systemd_service "$pc_typ" "$pc_port" "$pc_out" >/dev/null 2>&1
    systemctl is-active --quiet "$pc_svc" && pc_act=true || pc_act=false
    echo "{\"ok\":true,\"type\":\"${pc_typ}\",\"port\":${pc_port},\"service\":\"${pc_svc}\",\"active\":${pc_act}}"
}

# --rm <type><port> : stop+remove one tunnel endpoint.  emits JSON
panel_rm() {
    local id="$1"
    [[ "$id" =~ ^(iran|kharej)[0-9]+$ ]] || { echo '{"ok":false,"error":"bad id"}'; return 1; }
    # Fix 3: capture the tun device name (if any) from the [tun] section BEFORE we delete
    # the config, so we can drop a leftover device and never orphan it.
    local rm_cfg="${config_dir}/${id}.toml" rm_dev=""
    [[ -f "$rm_cfg" ]] && rm_dev=$(awk -F'"' '/^name = /{print $2; exit}' "$rm_cfg" 2>/dev/null)
    systemctl disable --now "leech-${id}.service" >/dev/null 2>&1
    # defensively reap a core still bound to this exact config (orphan case: unit file
    # already gone but the process lingers). The space after "leech" guarantees this
    # never matches the "leech.sh" that invoked us.
    pkill -f "leech -c ${rm_cfg}" >/dev/null 2>&1
    # remove the leftover tun device a killed/crashed core may have left behind — but ONLY if
    # no OTHER endpoint's config still claims this device name, so a co-hosted tun tunnel that
    # happens to share the name (legacy "leech" default) is never torn out from under.
    if [[ -n "$rm_dev" ]]; then
        local rm_used=0 rm_f
        for rm_f in "${config_dir}"/{iran,kharej}*.toml; do
            [[ -f "$rm_f" && "$rm_f" != "$rm_cfg" ]] || continue
            [[ "$(awk -F'"' '/^name = /{print $2; exit}' "$rm_f" 2>/dev/null)" == "$rm_dev" ]] && { rm_used=1; break; }
        done
        [[ "$rm_used" -eq 0 ]] && ip link del "$rm_dev" >/dev/null 2>&1
    fi
    rm -f "${service_dir}/leech-${id}.service" "$rm_cfg"
    systemctl daemon-reload 2>/dev/null
    echo "{\"ok\":true,\"removed\":\"${id}\"}"
}

# --list : enumerate local tunnel endpoints.  emits {"tunnels":[...]}
panel_list() {
    local first=1 f name typ port active transport token remote
    printf '{"tunnels":['
    for f in "${config_dir}"/{iran,kharej}*.toml; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .toml)
        [[ "$name" =~ ^(iran|kharej)([0-9]+)$ ]] || continue
        typ="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
        # transport + (client's) remote let the panel auto-discover tunnels across nodes
        local transport remote
        transport=$(awk -F'"' '/^type = /{print $2; exit}' "$f" 2>/dev/null)
        remote=""; [[ "$typ" == kharej ]] && remote=$(awk -F'"' '/^remote_addr = /{print $2; exit}' "$f" 2>/dev/null)
        systemctl is-active --quiet "leech-${name}" && active=true || active=false
        transport=$(grep -oP 'type\s*=\s*"\K[^"]+' "$f" | head -1)
        token=$(grep -oP 'token\s*=\s*"\K[^"]+' "$f" | head -1)
        remote=$(grep -oP 'remote_addr\s*=\s*"\K[^"]+' "$f" | head -1)
        [ $first -eq 1 ] || printf ','; first=0
        printf '{"type":"%s","port":%s,"active":%s,"transport":"%s","token":"%s","remote":"%s"}' \
            "$typ" "$port" "$active" "${transport:-}" "${token:-}" "${remote:-}"
    done
    printf ']}\n'
}

# --stats : host + per-tunnel cumulative counters (panel computes rates).
panel_stats() {
    local ncpu cput cpui memt mema memu upt hrx htx
    ncpu=$(nproc 2>/dev/null || echo 1)
    read -r cput cpui < <(awk '/^cpu /{t=0;for(i=2;i<=NF;i++)t+=$i;print t,($5+$6);exit}' /proc/stat)
    memt=$(awk '/^MemTotal/{print $2*1024}' /proc/meminfo)
    mema=$(awk '/^MemAvailable/{print $2*1024}' /proc/meminfo)
    memu=$((memt-mema))
    upt=$(awk '{print int($1)}' /proc/uptime)
    read -r hrx htx < <(awk 'NR>2{sub(/:/," ");if($1!="lo"){rx+=$2;tx+=$10}}END{print rx+0,tx+0}' /proc/net/dev)
    local cver=""
    [[ -x "${config_dir}/leech" ]] && cver=$("${config_dir}/leech" -v 2>/dev/null | head -1 | tr -d '"\\')
    printf '{"host":{"cpu_total":%s,"cpu_idle":%s,"mem_used":%s,"mem_total":%s,"rx_bytes":%s,"tx_bytes":%s,"uptime":%s,"ncpu":%s,"core":"%s"},"tunnels":[' \
        "${cput:-0}" "${cpui:-0}" "${memu:-0}" "${memt:-0}" "${hrx:-0}" "${htx:-0}" "${upt:-0}" "${ncpu:-1}" "${cver}"
    local first=1 f name typ port active pid mem cpuns rx tx conns dir transport remote
    for f in "${config_dir}"/{iran,kharej}*.toml; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .toml)
        [[ "$name" =~ ^(iran|kharej)([0-9]+)$ ]] || continue
        typ="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
        # transport + (client's) remote let the panel auto-discover tunnels across nodes
        # and detect a re-tunnel to a different server made outside the panel.
        transport=$(awk -F'"' '/^type = /{print $2; exit}' "$f" 2>/dev/null)
        remote=""; [[ "$typ" == kharej ]] && remote=$(awk -F'"' '/^remote_addr = /{print $2; exit}' "$f" 2>/dev/null)
        systemctl is-active --quiet "leech-${name}" && active=true || active=false
        mem=$(systemctl show "leech-${name}" -p MemoryCurrent --value 2>/dev/null)
        cpuns=$(systemctl show "leech-${name}" -p CPUUsageNSec --value 2>/dev/null)
        [[ "$mem" =~ ^[0-9]+$ ]] || mem=0
        [[ "$cpuns" =~ ^[0-9]+$ ]] || cpuns=0
        # tunnel-port sockets: server listens (sport), client dials (dport)
        dir=sport; [[ "$typ" == kharej ]] && dir=dport
        # Throughput: prefer systemd per-unit IP accounting — it counts ALL of the
        # unit's traffic (TCP, UDP/kcp, raw/ipx) so it works for every transport, unlike
        # ss which only sees TCP. Enable it once if it's off (live, no restart).
        rx=""; tx=""
        if [[ "$(systemctl show "leech-${name}" -p IPAccounting --value 2>/dev/null)" != "yes" ]]; then
            systemctl set-property "leech-${name}" IPAccounting=yes 2>/dev/null || true
        fi
        local ing egr
        ing=$(systemctl show "leech-${name}" -p IPIngressBytes --value 2>/dev/null)
        egr=$(systemctl show "leech-${name}" -p IPEgressBytes --value 2>/dev/null)
        if [[ "$ing" =~ ^[0-9]+$ && "$egr" =~ ^[0-9]+$ ]]; then
            rx=$ing; tx=$egr   # ingress = download (rx), egress = upload (tx)
        else
            # fallback for TCP transports before accounting has warmed up
            read -r rx tx < <(ss -Htni "$dir = :$port" 2>/dev/null | awk '
                match($0,/bytes_received:[0-9]+/){r+=substr($0,RSTART+15,RLENGTH-15)}
                match($0,/bytes_sent:[0-9]+/){s+=substr($0,RSTART+11,RLENGTH-11)}
                END{print r+0,s+0}')
        fi
        # connections / connected-state.
        # PREFERRED (new core, health-checker): the core writes its REAL per-tunnel
        # connected state to /run/leech-<name>.status and refreshes it every heartbeat.
        # Trust that value when fresh (mtime within HEALTH_STALE) — it is accurate for
        # EVERY transport including the socketless raw/forged ones, and it reflects an
        # actual PEER drop (not just "service active"). A crashed core leaves a stale
        # file, which the freshness check rejects → we fall back below. Absent file
        # (older core, or the health toggle is off) also falls back → no regression.
        # The file is exactly three bare integers: "<conns> <flaps> <since>". flaps is a
        # monotonic drop counter (catches a sub-poll self-healing drop even after conns
        # recovers); since is the connected-since unix time (exact uptime, no poll quantize).
        local sf="/run/leech-${name}.status" s_conns s_flaps s_since sage now_s
        conns=""; hflaps=0; hage=0
        if [[ -r "$sf" ]]; then
            read -r s_conns s_flaps s_since _ < "$sf" 2>/dev/null
            now_s=$(date +%s)
            sage=$(( now_s - $(stat -c %Y "$sf" 2>/dev/null || echo 0) ))
            if [[ "$s_conns" =~ ^[0-9]+$ && "$sage" -ge 0 && "$sage" -lt "${HEALTH_STALE:-15}" ]]; then
                conns="$s_conns"
                [[ "$s_flaps" =~ ^[0-9]+$ ]] && hflaps="$s_flaps"
                # emit the AGE (seconds since the peer connected), computed on THIS node — a
                # duration, so the panel anchors to its own poll clock and is immune to any
                # node↔panel wall-clock skew (an absolute timestamp would make the timer wrong).
                if [[ "$s_since" =~ ^[0-9]+$ && "$s_since" -gt 0 ]]; then
                    hage=$(( now_s - s_since )); (( hage < 0 )) && hage=0
                fi
            fi
        fi
        if [[ -z "$conns" ]]; then
            # FALLBACK: TCP established on the tunnel port, plus the raw UDP socket for
            # connectionless carriers (kcp) so an active UDP tunnel shows its session.
            conns=$(ss -Htn "$dir = :$port" 2>/dev/null | grep -c ESTAB)
            [[ "${conns:-0}" -eq 0 ]] && [[ -n "$(ss -Huan "$dir = :$port" 2>/dev/null)" ]] && conns=1
            # raw / forged-TCP transports (quantum, and tun/ipx which report type=tun) hold
            # NO kernel socket on the tunnel port, so the ss checks read 0 even when the link
            # is up and passing traffic. Treat an ACTIVE service as one live connection so the
            # panel shows "connected" (matching the green dot) instead of a false "قطع".
            [[ "${conns:-0}" -eq 0 && "$active" == true ]] && case "$transport" in quantum|tun) conns=1 ;; esac
        fi
        # precise uptime + disconnect tracking straight from systemd — poll-independent, so
        # even a sub-poll restart (a 1-second blip) is caught: NRestarts counts every
        # (re)start; ActiveEnterTimestampMonotonic gives the EXACT current up-duration.
        nrestarts=$(systemctl show "leech-${name}" -p NRestarts --value 2>/dev/null); [[ "$nrestarts" =~ ^[0-9]+$ ]] || nrestarts=0
        up_secs=0
        if [[ "$active" == true ]]; then
            aetm=$(systemctl show "leech-${name}" -p ActiveEnterTimestampMonotonic --value 2>/dev/null)
            if [[ "$aetm" =~ ^[0-9]+$ && "$aetm" -gt 0 ]]; then
                now_us=$(awk '{printf "%d", $1*1000000}' /proc/uptime 2>/dev/null)
                [[ "$now_us" =~ ^[0-9]+$ ]] && up_secs=$(( (now_us - aetm) / 1000000 ))
                (( up_secs < 0 )) && up_secs=0
            fi
        fi
        [ $first -eq 1 ] || printf ','; first=0
        printf '{"type":"%s","port":%s,"active":%s,"cpu_ns":%s,"mem":%s,"rx_bytes":%s,"tx_bytes":%s,"conns":%s,"transport":"%s","remote":"%s","restarts":%s,"up_secs":%s,"hflaps":%s,"hage":%s}' \
            "$typ" "$port" "$active" "$cpuns" "$mem" "${rx:-0}" "${tx:-0}" "${conns:-0}" "${transport}" "${remote}" "${nrestarts}" "${up_secs}" "${hflaps:-0}" "${hage:-0}"
    done
    printf ']}\n'
}

# ===== SSL / TLS certificate acquisition (acme.sh) — driven by the panel "SSL" tab =====
# Input via SSL_* env (validated by the panel). Emits JSON. Issued certs live under
# $CERT_DIR/acme/<name>/{cert.crt,cert.key}; when SSL_MOVE_CORE=1 they are copied to the
# pair the LEECH TLS transports read: $CERT_FILE (cert.crt) + $KEY_FILE (cert.key).
ACME_HOME="/root/.acme.sh"; ACME="${ACME_HOME}/acme.sh"
# marker holding the single cert name that is currently copied into the core path
# ($CERT_FILE/$KEY_FILE). Only this cert re-copies to core on acme renewal, so multiple
# certs can coexist on the node without a renewal fighting over the one served pair.
ACTIVE_FILE="${CERT_DIR}/active"
# acme.sh derives its store location from $HOME; the panel may exec this script locally with
# HOME unset, which makes acme.sh --issue/--list look in the wrong place (empty results). This
# script is root-only and always operates under /root, so pin HOME.
export HOME="${HOME:-/root}"
ssl_json_err() { echo "{\"ok\":false,\"error\":\"$1\"}"; }
# classify a cert dir name → its method for display (ip-<addr> or a bare IPv4/IPv6 → ip; else domain)
ssl_method_of() {
    case "$1" in ip-*) echo ip; return 0 ;; esac
    if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$1" == *:*:* ]]; then echo ip; else echo domain; fi
}

ssl_install_acme() {
    [[ -x "$ACME" ]] && return 0
    # standalone HTTP-01 needs socat
    if ! command -v socat >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
        timeout 180 sudo apt-get install -y socat >/dev/null 2>&1
    fi
    timeout 120 bash -c "curl -fsSL https://get.acme.sh | sh -s email=${SSL_EMAIL:-admin@leech.local}" >/dev/null 2>&1
    [[ -x "$ACME" ]]
}

# copy an issued cert/key pair into the core's cert_files path, then restart ONLY the TLS
# endpoints (wss/wssmux/anytls/https) so they pick up the new pair.
ssl_move_to_core() {
    local crt="$1" key="$2" u id2 t2
    [[ -s "$crt" && -s "$key" ]] || return 1
    mkdir -p "$CERT_DIR"
    cp -f "$crt" "$CERT_FILE" && cp -f "$key" "$KEY_FILE" && chmod 600 "$KEY_FILE" || return 1
    for u in $(systemctl list-units --plain --no-legend 'leech-iran*.service' 'leech-kharej*.service' 2>/dev/null | awk '{print $1}'); do
        id2=$(sed -E 's/^leech-(.+)\.service$/\1/' <<< "$u")
        t2=$(awk -F'"' '/^type = /{print $2; exit}' "${config_dir}/${id2}.toml" 2>/dev/null)
        case "$t2" in wss|wssmux|anytls|https) systemctl restart "$u" >/dev/null 2>&1 ;; esac
    done
    return 0
}

# --ssl : issue a certificate. SSL_METHOD=http|dns|ip
panel_ssl_issue() {
    local method="${SSL_METHOD:-}" dom="${SSL_DOMAIN:-}" dir_acme crt key
    case "$method" in
        ip)
            # REAL cert for a bare IP via acme.sh HTTP-01 standalone on a port (Let's Encrypt
            # now issues short-lived IP certs), mirroring the http branch. Like 3x-ui.
            local ip="${SSL_IP:-$SERVER_IP}"
            [[ -n "$ip" ]] || { ssl_json_err "no IP address"; return 1; }
            ssl_install_acme || { ssl_json_err "acme.sh install failed"; return 1; }
            "$ACME" --set-default-ca --server "${SSL_CA:-letsencrypt}" >/dev/null 2>&1
            dir_acme="${CERT_DIR}/acme/${ip}"; mkdir -p "$dir_acme"   # bare-IP name matches acme's <ip>_ecc store
            crt="${dir_acme}/cert.crt"; key="${dir_acme}/cert.key"
            local acmelog; acmelog=$(mktemp /tmp/leech-acme.XXXXXX 2>/dev/null || echo /tmp/leech-acme.$$)
            timeout 200 "$ACME" --issue -d "$ip" --standalone --httpport "${SSL_PORT:-80}" --cert-profile shortlived --force >"$acmelog" 2>&1 \
                || { ssl_json_err "IP issue failed: $(tail -n1 "$acmelog" 2>/dev/null | tr -cd '[:alnum:] .:_-')"; rm -f "$acmelog"; return 1; }
            rm -f "$acmelog"
            "$ACME" --install-cert -d "$ip" --key-file "$key" --fullchain-file "$crt" \
                --reloadcmd "bash /root/leech/leech.sh --ssl-reload ${ip}" >/dev/null 2>&1 \
                || { ssl_json_err "install-cert failed"; return 1; }
            dom="$ip"
            ;;
        selfsigned)
            # explicit fallback: a self-signed (browser-untrusted) cert for the IP, no CA / no port.
            local ip="${SSL_IP:-$SERVER_IP}"
            [[ -n "$ip" ]] || { ssl_json_err "no IP for self-signed cert"; return 1; }
            dir_acme="${CERT_DIR}/acme/ip-${ip}"; mkdir -p "$dir_acme"
            crt="${dir_acme}/cert.crt"; key="${dir_acme}/cert.key"
            openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -x509 \
                -days 3650 -sha256 -keyout "$key" -out "$crt" \
                -subj "/CN=${ip}" -addext "subjectAltName=IP:${ip}" >/dev/null 2>&1 \
                || { ssl_json_err "openssl self-sign failed"; return 1; }
            dom="$ip"
            ;;
        http|dns)
            [[ -n "$dom" ]] || { ssl_json_err "no domain for ${method} method"; return 1; }
            ssl_install_acme || { ssl_json_err "acme.sh install failed"; return 1; }
            "$ACME" --set-default-ca --server "${SSL_CA:-letsencrypt}" >/dev/null 2>&1
            dir_acme="${CERT_DIR}/acme/${dom}"; mkdir -p "$dir_acme"
            crt="${dir_acme}/cert.crt"; key="${dir_acme}/cert.key"
            local acmelog; acmelog=$(mktemp /tmp/leech-acme.XXXXXX 2>/dev/null || echo /tmp/leech-acme.$$)
            if [[ "$method" == "http" ]]; then
                timeout 200 "$ACME" --issue -d "$dom" --standalone --httpport "${SSL_PORT:-80}" --force >"$acmelog" 2>&1 \
                    || { ssl_json_err "issue failed: $(tail -n1 "$acmelog" 2>/dev/null | tr -cd '[:alnum:] .:_-')"; rm -f "$acmelog"; return 1; }
            else
                # provider creds (e.g. CF_Token) are already in the env, passed by the panel
                timeout 200 "$ACME" --issue --dns "${SSL_DNS_PROVIDER:-dns_cf}" -d "$dom" --force >"$acmelog" 2>&1 \
                    || { ssl_json_err "dns issue failed: $(tail -n1 "$acmelog" 2>/dev/null | tr -cd '[:alnum:] .:_-')"; rm -f "$acmelog"; return 1; }
            fi
            rm -f "$acmelog"
            "$ACME" --install-cert -d "$dom" --key-file "$key" --fullchain-file "$crt" \
                --reloadcmd "bash /root/leech/leech.sh --ssl-reload ${dom}" >/dev/null 2>&1 \
                || { ssl_json_err "install-cert failed"; return 1; }
            ;;
        *) ssl_json_err "unknown SSL_METHOD (use http|dns|ip|selfsigned)"; return 1 ;;
    esac
    local moved=false exp name
    name=$(basename "$dir_acme")
    if [[ "${SSL_MOVE_CORE:-0}" == "1" ]] && ssl_move_to_core "$crt" "$key"; then
        moved=true
        printf '%s' "$name" > "$ACTIVE_FILE" 2>/dev/null   # this cert is now the single core-active one
    fi
    exp=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)
    echo "{\"ok\":true,\"method\":\"${method}\",\"domain\":\"${dom}\",\"name\":\"${name}\",\"cert\":\"${crt}\",\"key\":\"${key}\",\"moved_to_core\":${moved},\"expires\":\"${exp}\"}"
}

# --ssl-list : enumerate ALL certs on this node (panel-installed copies + acme.sh's own store)
# with on-disk cert/key paths, expiry, method and which one is core-active. emits {"certs":[...]}
panel_ssl_list() {
    local first=1 d name crt key exp method dom active="" md adir
    declare -A seen
    [[ -s "$ACTIVE_FILE" ]] && active=$(cat "$ACTIVE_FILE" 2>/dev/null)
    printf '{"certs":['
    shopt -s nullglob
    # (a) certs the panel installed under cert_files/acme/<name>/
    for d in "${CERT_DIR}"/acme/*/; do
        name=$(basename "$d"); crt="${d}cert.crt"; key="${d}cert.key"
        [[ -s "$crt" ]] || continue
        seen[$name]=1
        exp=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)
        method=$(ssl_method_of "$name"); case "$name" in ip-*) dom="${name#ip-}" ;; *) dom="$name" ;; esac
        [ $first -eq 1 ] || printf ','; first=0
        printf '{"name":"%s","domain":"%s","method":"%s","cert":"%s","key":"%s","expires":"%s","active":%s}' \
            "$name" "$dom" "$method" "$crt" "$key" "$exp" "$([ "$name" = "$active" ] && echo true || echo false)"
    done
    shopt -u nullglob
    # (b) certs in acme.sh's own ECC store that were NOT installed into cert_files (issued
    # outside the panel) — read the dirs directly. HOME-independent, unlike acme.sh --list.
    shopt -s nullglob
    for adir in "${ACME_HOME}"/*_ecc/; do
        md=$(basename "$adir"); md="${md%_ecc}"
        [[ -n "$md" && -z "${seen[$md]:-}" ]] || continue
        crt="${adir}fullchain.cer"; key="${adir}${md}.key"
        [[ -s "$crt" ]] || continue
        exp=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)
        method=$(ssl_method_of "$md")
        [ $first -eq 1 ] || printf ','; first=0
        printf '{"name":"%s","domain":"%s","method":"%s","cert":"%s","key":"%s","expires":"%s","active":%s}' \
            "$md" "$md" "$method" "$crt" "$key" "$exp" "$([ "$md" = "$active" ] && echo true || echo false)"
    done
    shopt -u nullglob
    printf ']}\n'
}

# --ssl-reload <name> : acme.sh reloadcmd target. Only the core-ACTIVE cert re-copies into the
# served core pair; any other renewing cert just keeps its own acme/<name>/ copy (which acme
# --install-cert already refreshed), so renewals never fight over the single served pair.
panel_ssl_reload() {
    local dom="${1:-}" active=""
    [[ -n "$dom" ]] || { ssl_json_err "no domain"; return 1; }
    [[ -s "$ACTIVE_FILE" ]] && active=$(cat "$ACTIVE_FILE" 2>/dev/null)
    if [[ "$dom" == "$active" ]]; then
        ssl_move_to_core "${CERT_DIR}/acme/${dom}/cert.crt" "${CERT_DIR}/acme/${dom}/cert.key" \
            && echo "{\"ok\":true,\"reloaded\":\"${dom}\",\"core\":true}" || ssl_json_err "reload failed"
    else
        echo "{\"ok\":true,\"reloaded\":\"${dom}\",\"core\":false}"
    fi
}

# --ssl-activate <name> : make an already-issued cert the SINGLE core-active one (no re-issue).
# If the cert lives only in acme.sh's store (issued outside the panel), install it into
# cert_files/acme/<name>/ first, then copy it into the core pair.
panel_ssl_activate() {
    local name="${1:-}" crt key adir
    [[ -n "$name" ]] || { ssl_json_err "no cert name"; return 1; }
    crt="${CERT_DIR}/acme/${name}/cert.crt"; key="${CERT_DIR}/acme/${name}/cert.key"
    if [[ ! -s "$crt" && -x "$ACME" ]]; then
        adir="${ACME_HOME}/${name}_ecc"
        if [[ -s "${adir}/fullchain.cer" ]]; then
            mkdir -p "${CERT_DIR}/acme/${name}"
            "$ACME" --install-cert -d "$name" --key-file "$key" --fullchain-file "$crt" \
                --reloadcmd "bash /root/leech/leech.sh --ssl-reload ${name}" >/dev/null 2>&1
        fi
    fi
    [[ -s "$crt" && -s "$key" ]] || { ssl_json_err "cert not found: ${name}"; return 1; }
    # write the marker ONLY after the copy succeeds, else the marker could point at a cert that
    # isn't actually in the core pair and the next renewal would silently swap the served cert.
    if ssl_move_to_core "$crt" "$key"; then
        printf '%s' "$name" > "$ACTIVE_FILE" 2>/dev/null
        echo "{\"ok\":true,\"active\":\"${name}\"}"
    else
        ssl_json_err "activate failed"
    fi
}

# --ssl-delete <name> : remove an issued cert from the node (installed copy + acme renewal +
# acme store). Refuses the core-active cert — deactivate/replace it first. name is allow-listed
# by the panel (reCertName) before it ever reaches here.
panel_ssl_delete() {
    local name="${1:-}" active=""
    [[ -n "$name" ]] || { ssl_json_err "no cert name"; return 1; }
    [[ -s "$ACTIVE_FILE" ]] && active=$(cat "$ACTIVE_FILE" 2>/dev/null)
    [[ "$name" == "$active" ]] && { ssl_json_err "cert is in use by the core; activate another first"; return 1; }
    rm -rf "${CERT_DIR}/acme/${name}"
    if [[ "$name" != ip-* && -x "$ACME" ]]; then
        "$ACME" --remove -d "$name" >/dev/null 2>&1      # stop auto-renewal
        rm -rf "${ACME_HOME}/${name}_ecc" "${ACME_HOME}/${name}"
    fi
    echo "{\"ok\":true,\"deleted\":\"${name}\"}"
}

case "${1:-}" in
    --create) panel_create "${2:?usage: --create <server|client>}"; exit $? ;;
    --rm)     panel_rm     "${2:?usage: --rm <type><port>}";        exit $? ;;
    --list)   panel_list;   exit $? ;;
    --stats)  panel_stats;  exit $? ;;
    --tun-cleanup) tun_cleanup "${2:-}"; exit 0 ;;
    --ssl)         panel_ssl_issue;          exit $? ;;
    --ssl-list)    panel_ssl_list;           exit $? ;;
    --ssl-reload)  panel_ssl_reload "${2:-}"; exit $? ;;
    --ssl-activate) panel_ssl_activate "${2:-}"; exit $? ;;
    --ssl-delete)  panel_ssl_delete "${2:-}"; exit $? ;;
esac

while true; do
    display_menu
    read_option
done

