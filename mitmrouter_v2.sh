#!/bin/bash
# author: l0g
# This allows you to use either a wireless access point or a wired connection for MITM IoT devices

# Script Global Constants
## Network Information
WIFI_SSID="mitm.io"
WIFI_PASSWORD="1234567890"
BR_IFACE="br0" # Used for WIRED mode only
LAN_IP="192.168.150.1"
LAN_DNS_SERVER="1.1.1.1"

## Logging Setup
DATE_NOW=$(date +%F)
LOG_FILE="mitm-log-$DATE_NOW.txt"
echo "" > $LOG_FILE

## Config Files
DHCPD_CONF="tmp_dhcpd.conf"
HOSTAPD_CONF="tmp_hostapd.conf"

# Function Declarations
## Network Calculator
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

## Usage function
usage() {
    echo 'AP MODE: ./mitmrouter.sh ap ${WIRELESS_INTERFACE} ${GATEWAY_INTERFACE}'
    echo 'WIRED MODE: ./mitmrouter.sh wired ${WIRED_INTERFACE} ${GATEWAY_INTERFACE}'
    exit 0
}

## Print time function
log_time() {
    date +'%F %T'
}

## Logging function
log() {
    echo "$(log_time): $1"
    echo "$(log_time): $1" >> "$LOG_FILE"
}

## Cleanup function
cleanup() {
    if [[ "$1" == 'wireless' ]]; then
        WIFI_INTERFACE=$2
        log "[*] Cleanup started" 
        log "[*] Cleaning up interfaces and IP assignments"
        sudo ip link set dev $WIFI_INTERFACE down
        sudo ip addr flush dev $WIFI_INTERFACE

        log "[*] Stopping dhcpd"
        sudo systemctl stop isc-dhcp-server

        log "[*] Stopping hostapd"
        sudo pkill hostapd

        log "[*] Removing temporary files"
        rm -rf $DHCPD_CONF $HOSTAPD_CONF
        sudo mv /etc/dhcp/dhcpd.conf.bak /etc/dhcp/dhcpd.conf

        log "[*] Cleanup complete"
        exit 0
    
    elif [[ "$1" == 'wired' ]]; then
        IN_INTERFACE=$2
        log "[*] Cleanup started" 
        log "[*] Cleaning up interfaces and IP assignments"
        sudo ip link set dev $IN_INTERFACE down
        sudo ip addr flush dev $IN_INTERFACE

        # Bridge Stuff
        #sudo ip link set $BR_IFACE down
        #sudo ip addr flush dev $BR_IFACE
        #sudo brctl delbr $BR_IFACE

        log "[*] Stopping dhcpd"
        sudo systemctl stop isc-dhcp-server
        
        log "[*] Removing temporary files"
        rm -rf $DHCPD_CONF
        sudo mv /etc/dhcp/dhcpd.conf.bak /etc/dhcp/dhcpd.conf
    
        log "[*] Cleanup complete"
        exit 0
    fi
}

## Clean and setup IP address on interface
clean_setup_ip() {
    IN_INTERFACE=$2
    if [[ "$1" == 'wireless' ]]; then
        # Clean
        sudo ip link set dev $IN_INTERFACE down
        sudo ip addr flush dev $IN_INTERFACE
        # Setup
        sudo ip link set dev $IN_INTERFACE up
        sudo ip addr add $LAN_IP/24 dev $IN_INTERFACE
        sleep 1
    elif [[ "$1" == 'wired' ]]; then
        # Clean
        sudo ip link set $IN_INTERFACE down
        sudo ip addr flush dev $IN_INTERFACE

        # Bridge Stuff
        #sudo ip link set $BR_IFACE down
        #sudo ip addr flush dev $BR_IFACE
        #sudo brctl delbr $BR_IFACE

        # Setup
        sudo ip link set dev $IN_INTERFACE up
        sudo ip addr add $LAN_IP/24 dev $IN_INTERFACE

        # Bridge Stuff
        #sudo brctl addbr $BR_IFACE
        #sudo brctl addbif $BR_IFACE $IN_INTERFACE
        #sudo ip link set $BR_IFACE up
        #sudo ip addr add $LAN_IP/24 dev $BR_IFACE
    fi
}

## Build dhcpd config and run
build_run_dhcpd() {
    IN_INTERFACE=$1
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
    sudo sed -i "/INTERFACESv4/ s/.*/INTERFACESv4=$IN_INTERFACE/" /etc/default/isc-dhcp-server

    # Stop and start dhcpd
    log "[*] Running dhcp server now...."
    sudo systemctl stop isc-dhcp-server
    sudo systemctl start isc-dhcp-server
    if [ $? -eq 0 ]; then
        log "[*] dhcpd started successfully."
    else
        log "[*] dhcpd startup failed. Exiting."
    fi
}

## Flush iptables rules and configure for routing
clean_setup_firewall() {
    IN_INTERFACE=$1
    OUT_INTERFACE=$2
    sudo iptables -F
    sudo iptables -t nat -F
    sudo iptables -t nat -A POSTROUTING -o $2 -j MASQUERADE
    sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    sudo iptables -A FORWARD -i $IN_INTERFACE -o $OUT_INTERFACE -j ACCEPT
}

## Configuring OS to be a router
setup_forwarding() {
    sudo sysctl -w net.ipv4.ip_forward=1
}

# Check for no args
if [ -z "$1" ]; then 
    usage
fi

if [[ "$1" == 'ap' ]] && [[ "$2" == wl* ]] && ([[ "$3" == e* ]] || [[ "$3" == wl* ]]); then
    # Wireless Setup
    WIFI_INTERFACE=$2
    GATEWAY_INTERFACE=$3
    #AUTO_WIFI_INTERFACE=$(ip link show | grep -E 'wlan[0-9]+|wlx[a-f0-9]+' | awk '{print $2}' | tr -d ':')

    log "[*] mitmrouter_v2 - AP mode starting"

    log "[*] Setting up IP addresses"
    clean_setup_ip wireless $WIFI_INTERFACE
 
    log "[*] Building dhcpd config"
    build_run_dhcpd $WIFI_INTERFACE
 
    log "[*] Adding firewall rules"
    clean_setup_firewall $WIFI_INTERFACE $GATEWAY_INTERFACE

    log "[*] Setting up forwarding"
    setup_forwarding
 
    log "[*] Running hostapd now....."
    echo "interface=$WIFI_INTERFACE" > $HOSTAPD_CONF
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
    cleanup wireless $WIFI_INTERFACE

elif [[ "$1" == 'wired' ]] && [[ "$2" == e* ]] && ([[ "$3" == e* ]] || [[ "$3" == wl* ]]); then
    # Wired Setup
    IN_INTERFACE=$2
    GATEWAY_INTERFACE=$3

    trap cleanup SIGINT

    log "[*] mitmrouter_v2 - WIRED mode starting"

    log "[*] Setting up IP addresses"
    clean_setup_ip wired $IN_INTERFACE

    log "[*] Building dhcpd config"
    build_run_dhcpd $IN_INTERFACE

    log "[*] Adding firewall rules"
    clean_setup_firewall $IN_INTERFACE $GATEWAY_INTERFACE

    log "[*] Setting up forwarding"
    setup_forwarding

    # Keep the program open
    sleep infinity

    # Cleanup
    cleanup wired $IN_INTERFACE

else
    usage
fi
