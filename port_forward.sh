#!/bin/bash

# Port Forwarding Script using iptables DNAT/SNAT
# Usage: ./port_forward.sh {add|remove|list|flush} [args]

RULE_COMMENT_PREFIX="ez_tools_port_forward"

# Show usage without root check for help
case "$1" in
    -h|--help|help)
        echo "Usage: $0 {add|remove|list|flush} [args]"
        echo ""
        echo "Commands:"
        echo "  add <local_port> <target_ip> <target_port>"
        echo "      Add port forwarding rule (A -> B -> C)"
        echo "      Example: $0 add 8080 10.0.0.5 80"
        echo "        (Forward traffic from local port 8080 to 10.0.0.5:80)"
        echo ""
        echo "  remove <local_port>"
        echo "      Remove port forwarding rule for specified local port"
        echo "      Example: $0 remove 8080"
        echo ""
        echo "  list"
        echo "      List port forwarding rules managed by this script"
        echo ""
        echo "  flush"
        echo "      Remove all port forwarding rules managed by this script"
        echo ""
        echo "Note: This script must be run as root on the forwarding server (B)."
        exit 0
        ;;
esac

# Check root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# Check iptables availability
if ! command -v iptables &> /dev/null; then
    echo "Error: 'iptables' is not installed. Please install iptables to use this script."
    exit 1
fi

# Enable IP forwarding
enable_ip_forward() {
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" -ne 1 ]; then
        echo "Enabling IP forwarding..."
        echo 1 > /proc/sys/net/ipv4/ip_forward
        if grep -Eq '^[[:space:]]*#?[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' /etc/sysctl.conf; then
            sed -i -E 's/^[[:space:]]*#?[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
        else
            echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
        fi
        sysctl -p &> /dev/null
        echo "IP forwarding enabled."
    fi
}

usage() {
    echo "Usage: $0 {add|remove|list|flush} [args]"
    echo ""
    echo "Commands:"
    echo "  add <local_port> <target_ip> <target_port>"
    echo "      Add port forwarding rule (A -> B -> C)"
    echo "      Example: $0 add 8080 10.0.0.5 80"
    echo "        (Forward traffic from local port 8080 to 10.0.0.5:80)"
    echo ""
    echo "  remove <local_port>"
    echo "      Remove port forwarding rule for specified local port"
    echo "      Example: $0 remove 8080"
    echo ""
    echo "  list"
    echo "      List port forwarding rules managed by this script"
    echo ""
    echo "  flush"
    echo "      Remove all port forwarding rules managed by this script"
    echo ""
    echo "Note: This script must be run as root on the forwarding server (B)."
    exit 1
}

list_rules() {
    echo "Current Port Forwarding Rules:"
    echo "=================================================================="
    printf "%-15s %-20s %-20s\n" "Local Port" "Target IP" "Target Port"
    echo "=================================================================="

    iptables -t nat -S PREROUTING 2>/dev/null | grep -- "$RULE_COMMENT_PREFIX" | grep -- "-j DNAT" | while read -r line; do
        local_port=$(echo "$line" | sed -n 's/.*--dport \([0-9]\+\).*/\1/p')
        target=$(echo "$line" | sed -n 's/.*--to-destination \([0-9.]\+:[0-9]\+\).*/\1/p')
        [ -n "$local_port" ] || continue
        [ -n "$target" ] || continue

        target_ip=$(echo "$target" | cut -d':' -f1)
        target_port=$(echo "$target" | cut -d':' -f2)
        printf "%-15s %-20s %-20s\n" "$local_port" "$target_ip" "$target_port"
    done

    if ! iptables -t nat -S PREROUTING 2>/dev/null | grep -- "$RULE_COMMENT_PREFIX" | grep -q -- "-j DNAT"; then
        echo "No forwarding rules found."
    fi
}

add_rule() {
    if [ "$#" -ne 3 ]; then
        echo "Error: Invalid arguments."
        echo "Usage: $0 add <local_port> <target_ip> <target_port>"
        exit 1
    fi

    local_port=$1
    target_ip=$2
    target_port=$3

    # Validate port numbers
    if ! [[ "$local_port" =~ ^[0-9]+$ ]] || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo "Error: Invalid local port: $local_port"
        exit 1
    fi
    if ! [[ "$target_port" =~ ^[0-9]+$ ]] || [ "$target_port" -lt 1 ] || [ "$target_port" -gt 65535 ]; then
        echo "Error: Invalid target port: $target_port"
        exit 1
    fi

    # Validate IP address format
    if ! [[ "$target_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Error: Invalid IP address: $target_ip"
        exit 1
    fi

    # Check if this script already manages the local port.
    if iptables -t nat -S PREROUTING 2>/dev/null | grep -- "$RULE_COMMENT_PREFIX" | grep -q -- "--dport $local_port "; then
        echo "Error: Rule for local port $local_port already exists."
        exit 1
    fi

    enable_ip_forward

    rule_comment="$RULE_COMMENT_PREFIX local=$local_port target=$target_ip:$target_port"

    # Add DNAT rule (PREROUTING chain)
    iptables -t nat -A PREROUTING -p tcp --dport "$local_port" -m comment --comment "$rule_comment" -j DNAT --to-destination "$target_ip:$target_port"

    # Add SNAT rule (POSTROUTING chain) - use MASQUERADE for dynamic source NAT
    iptables -t nat -A POSTROUTING -p tcp -d "$target_ip" --dport "$target_port" -m comment --comment "$rule_comment" -j MASQUERADE

    # Allow forwarded traffic
    iptables -A FORWARD -p tcp -d "$target_ip" --dport "$target_port" -m comment --comment "$rule_comment" -j ACCEPT

    echo "Added forwarding rule: Local port $local_port -> $target_ip:$target_port"
    echo "Traffic to this server's port $local_port will be forwarded to $target_ip:$target_port"
}

remove_rule() {
    if [ "$#" -ne 1 ]; then
        echo "Error: Invalid arguments."
        echo "Usage: $0 remove <local_port>"
        exit 1
    fi

    local_port=$1

    if ! [[ "$local_port" =~ ^[0-9]+$ ]] || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo "Error: Invalid port: $local_port"
        exit 1
    fi

    # Get the target info before removing.
    target_info=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -- "$RULE_COMMENT_PREFIX" | grep -- "--dport $local_port " | grep -- "-j DNAT" | head -1)
    if [ -z "$target_info" ]; then
        echo "Error: No rule found for local port $local_port."
        exit 1
    fi

    target=$(echo "$target_info" | sed -n 's/.*--to-destination \([0-9.]\+:[0-9]\+\).*/\1/p')
    if [ -z "$target" ]; then
        echo "Error: Could not parse target for local port $local_port."
        exit 1
    fi

    target_ip=$(echo "$target" | cut -d':' -f1)
    target_port=$(echo "$target" | cut -d':' -f2)
    rule_comment="$RULE_COMMENT_PREFIX local=$local_port target=$target_ip:$target_port"

    # Remove DNAT rule
    iptables -t nat -D PREROUTING -p tcp --dport "$local_port" -m comment --comment "$rule_comment" -j DNAT --to-destination "$target_ip:$target_port" 2>/dev/null

    # Remove SNAT rule
    iptables -t nat -D POSTROUTING -p tcp -d "$target_ip" --dport "$target_port" -m comment --comment "$rule_comment" -j MASQUERADE 2>/dev/null

    # Remove FORWARD rule
    iptables -D FORWARD -p tcp -d "$target_ip" --dport "$target_port" -m comment --comment "$rule_comment" -j ACCEPT 2>/dev/null

    echo "Removed forwarding rule for local port $local_port"
}

flush_rules() {
    echo "Flushing port forwarding rules managed by this script..."

    # Remove only rules created by this script.
    iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep "$RULE_COMMENT_PREFIX" | awk '{print $1}' | sort -rn | while read -r line_num; do
        iptables -t nat -D PREROUTING "$line_num" 2>/dev/null
    done

    iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | grep "$RULE_COMMENT_PREFIX" | awk '{print $1}' | sort -rn | while read -r line_num; do
        iptables -t nat -D POSTROUTING "$line_num" 2>/dev/null
    done

    iptables -L FORWARD -n --line-numbers 2>/dev/null | grep "$RULE_COMMENT_PREFIX" | awk '{print $1}' | sort -rn | while read -r line_num; do
        iptables -D FORWARD "$line_num" 2>/dev/null
    done

    echo "Managed forwarding rules have been removed."
}

# Main logic
case "$1" in
    add)
        add_rule "$2" "$3" "$4"
        ;;
    remove)
        remove_rule "$2"
        ;;
    list)
        list_rules
        ;;
    flush)
        flush_rules
        ;;
    *)
        usage
        ;;
esac
