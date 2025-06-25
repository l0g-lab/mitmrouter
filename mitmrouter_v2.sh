#!/bin/bash
# author: l0g
# This allows you to use either a wireless access point or a wired connection for MITM IoT devices

# Network Information
WIFI_SSID="mitm.io"
WIFI_PASSWORD="1234567890"
LAN_IP="192.168.150.1"
LAN_DNS_SERVER="1.1.1.1"

# Logging Setup
DATE_NOW=$(date +%F)
LOG_FILE="log-$DATE_NOW.mitmrouter.txt"
echo "" > $LOG_FILE

# Config Files
DHCPD_CONF="tmp_dhcpd.conf"
HOSTAPD_CONF="tmp_hostapd.conf"

# Usage function
usage() {
    echo "AP MODE: $0 ap <wireless_interface> <out_interface>"
    echo "WIRED MODE: $0 wired <wired_interface> <out_interface>"
    exit 0
}

# Check script runs as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "Error: This script must be run as root"
        exit 0
    fi
}

# Check for required tools
check_requirements() {
    local tools=("ip" "iptables" "systemctl" "hostapd" "dhcpd")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            log "Error: Required tool '$tool' not found"
            exit 0
        fi
    done
}

# Check network interfaces exist
validate_interface() {
    local iface=$1
    if ! ip link show "$iface" &>/dev/null; then
        log "Error: Interface $iface does not exist"
        exit 0
    fi
}

# Network Calculator
generate_network_config() {
    local ip="$1"
    IFS='.' read -r i1 i2 i3 i4 <<< "$ip"
    LAN_NETWORK="${i1}.${i2}.${i3}.0"
    LAN_GATEWAY="${i1}.${i2}.${i3}.1"
    LAN_DHCP_START="${i1}.${i2}.${i3}.100"
    LAN_DHCP_END="${i1}.${i2}.${i3}.200"
    LAN_BROADCAST="${i1}.${i2}.${i3}.255"
    LAN_SUBNET="255.255.255.0"
}

# Logging function
log() {
    local timestamp
    timestamp=$(date +'%F %T')
    echo "$timestamp: $1"
    echo "$timestamp: $1" >> "$LOG_FILE"
}

# Cleanup function
cleanup() {
    local mode=$1
    local in_interface=$2

    log "[*] Cleanup started"

    log "[*] Cleaning up $in_interface and IP assignments"
    sudo ip link set dev $in_interface down
    sudo ip addr flush dev $in_interface

    log "[*] Stopping dhcpd"
    sudo systemctl stop isc-dhcp-server
    sudo mv /etc/dhcp/dhcpd.conf.bak /etc/dhcp/dhcpd.conf

    if [[ "$mode" == 'wireless' ]]; then
        log "[*] Stopping hostapd"
        sudo pkill hostapd
    fi

    log "[*] Removing temporary files"
    rm -f $DHCPD_CONF $HOSTAPD_CONF &>/dev/null

    log "[*] Cleanup complete"
    exit 0
}

# Clean and setup IP address on interface
clean_setup_ip() {
    local mode=$1
    local in_interface=$2
    log "[*] Setting up IP addresses"
    if [[ "$mode" == 'wireless' ]]; then
        # Clean
        sudo ip link set dev $in_interface down
        sudo ip addr flush dev $in_interface
        # Setup
        sudo ip link set dev $in_interface up
        sudo ip addr add $LAN_IP/24 dev $in_interface
        sleep 1
    elif [[ "$mode" == 'wired' ]]; then
        # Clean
        sudo ip link set $in_interface down
        sudo ip addr flush dev $in_interface

        # Setup
        sudo ip link set dev $in_interface up
        sudo ip addr add $LAN_IP/24 dev $in_interface
    fi
}

# Build dhcpd config and run
build_run_dhcpd() {
    local in_interface=$1
    log "[*] Building dhcpd config"
    generate_network_config $LAN_IP
    echo "option domain-name \"$WIFI_SSID\";" > $DHCPD_CONF
    echo "option domain-name-servers $LAN_DNS_SERVER;" >> $DHCPD_CONF
    echo "default-lease-time 600;" >> $DHCPD_CONF
    echo "max-lease-time 7200;" >> $DHCPD_CONF
    echo "authoritative;" >> $DHCPD_CONF
    echo "subnet $LAN_NETWORK netmask $LAN_SUBNET {" >> $DHCPD_CONF
    echo "  range $LAN_DHCP_START $LAN_DHCP_END;" >> $DHCPD_CONF
    echo "  option routers $LAN_GATEWAY;" >> $DHCPD_CONF
    echo "  option broadcast-address $LAN_BROADCAST;" >> $DHCPD_CONF
    echo "}" >> $DHCPD_CONF
    sudo cp /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf.bak
    sudo cp $DHCPD_CONF /etc/dhcp/dhcpd.conf
    sudo sed -i "/INTERFACESv4/ s/.*/INTERFACESv4=$in_interface/" /etc/default/isc-dhcp-server

    # Stop and start dhcpd
    log "[*] Running dhcp server now...."
    sudo systemctl stop isc-dhcp-server
    sudo systemctl start isc-dhcp-server
    if [ $? -eq 0 ]; then
        log "[*] dhcpd started successfully."
    else
        log "[*] dhcpd startup failed. Exiting."
        exit 0
    fi
}

# Flush iptables rules and configure for routing
clean_setup_firewall() {
    local in_interface=$1
    local out_interface=$2
    log "[*] Adding firewall rules"
    sudo iptables -F
    sudo iptables -t nat -F
    sudo iptables -t nat -A POSTROUTING -o $out_interface -j MASQUERADE
    sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    sudo iptables -A FORWARD -i $in_interface -o $out_interface -j ACCEPT

    # option additional mitm rules
    #sudo iptables -t nat -A PREROUTING -i $in_interface -p tcp -d 1.2.3.4 --dport 443 -j REDIRECT --to-ports 8080
}

# Configuring OS to be a router
setup_forwarding() {
    log "[*] Setting up forwarding"
    sudo sysctl -w net.ipv4.ip_forward=1 &>/dev/null
}

# Check for no args
if [ -z "$1" ]; then 
    usage
fi

# Main function
main() {
    check_root
    check_requirements

    # Check number of arguments
    [[ $# -ne 3 ]] && usage

    local mode=$1
    local in_interface=$2
    local out_interface=$3

    # Make sure interfaces exist
    validate_interface "$in_interface"
    validate_interface "$out_interface"

    # Setup Signal Handler
    trap 'cleanup "$mode" "$in_interface"' SIGINT SIGTERM

    if [[ "$mode" == 'ap' && "$in_interface" == wl* && ("$out_interface" == e* || "$out_interface" == wl*) ]]; then
        # Wireless Setup
        log "[*] mitmrouter_v2 - AP mode starting"

        clean_setup_ip wireless $in_interface
        build_run_dhcpd $in_interface
        clean_setup_firewall $in_interface $out_interface
        setup_forwarding

        log "[*] Running hostapd now....."
        echo "interface=$in_interface" > $HOSTAPD_CONF
        echo "driver=nl80211" >> $HOSTAPD_CONF
        echo "country_code=US" >> $HOSTAPD_CONF
        echo "ssid=$WIFI_SSID" >> $HOSTAPD_CONF
        echo "hw_mode=g" >> $HOSTAPD_CONF
        echo "channel=6" >> $HOSTAPD_CONF
        echo "wpa=2" >> $HOSTAPD_CONF
        echo "wpa_passphrase=$WIFI_PASSWORD" >> $HOSTAPD_CONF
        echo "wpa_key_mgmt=WPA-PSK" >> $HOSTAPD_CONF
        echo "wpa_pairwise=TKIP" >> $HOSTAPD_CONF
        echo "rsn_pairwise=CCMP" >> $HOSTAPD_CONF
        echo "auth_algs=1" >> $HOSTAPD_CONF
        echo "macaddr_acl=0" >> $HOSTAPD_CONF
        sudo hostapd -t $HOSTAPD_CONF

        # Cleanup
        cleanup wireless $in_interface

    elif [[ "$mode" == 'wired' && "$in_interface" == e* && ("$out_interface" == e* || "$out_interface" == wl*) ]]; then
        # Wired Setup
        log "[*] mitmrouter_v2 - WIRED mode starting"
        clean_setup_ip wired $in_interface
        build_run_dhcpd $in_interface
        clean_setup_firewall $in_interface $out_interface
        setup_forwarding

        # Keep the program open
        log "[*] mitmrouter_v2 - WIRED mode running..."
        sleep infinity

        # Cleanup
        cleanup wireless $in_interface

    else
        usage
    fi
}

main "$@"
