#!/bin/bash

# Port Forwarding Script using iptables DNAT/SNAT
# Usage: ./port_forward.sh {add|remove|list|flush} [args]

RULE_COMMENT_PREFIX="ez_tools_port_forward"

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
    local exit_status=${1:-1}

    echo "Usage: $0 {add|remove|list|flush} [args]"
    echo ""
    echo "Commands:"
    echo "  add <local_port> <target_host> <target_port>"
    echo "      Add port forwarding rule (A -> B -> C)"
    echo "      Example: $0 add 8080 10.0.0.5 80"
    echo "        (Forward traffic from local port 8080 to 10.0.0.5:80)"
    echo "      Example: $0 add 8080 ms5090 80"
    echo "        (Resolve SSH Host ms5090, then forward to its port 80)"
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
    exit "$exit_status"
}

effective_uid() {
    printf '%s\n' "$EUID"
}

is_valid_ipv4() {
    local address=$1 octet
    local -a octets

    [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

get_ssh_config() {
    local target_host=$1 initiator_user passwd_record initiator_home resolved_user

    if [ "$(effective_uid)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        initiator_user=$SUDO_USER
        passwd_record=$(getent passwd "$initiator_user") || {
            echo "Error: Cannot resolve initiating user: $initiator_user" >&2
            return 1
        }
        IFS=: read -r resolved_user _ _ _ _ initiator_home _ <<< "$passwd_record"
        if [ "$resolved_user" != "$initiator_user" ] || [[ "$initiator_home" != /* ]]; then
            echo "Error: Invalid account information for initiating user: $initiator_user" >&2
            return 1
        fi
        runuser -u "$initiator_user" -- env HOME="$initiator_home" USER="$initiator_user" LOGNAME="$initiator_user" \
            ssh -G -- "$target_host" 2>/dev/null
    else
        ssh -G -- "$target_host" 2>/dev/null
    fi
}

resolve_ipv4_address() {
    local hostname=$1

    getent ahostsv4 "$hostname" | awk '$2 == "STREAM" { print $1; exit }'
}

resolve_target_host() {
    local target_host=$1 ssh_config hostname proxy_jump proxy_command resolved_ip

    if is_valid_ipv4 "$target_host"; then
        printf '%s\n' "$target_host"
        return 0
    fi

    if ! [[ "$target_host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo "Error: Invalid target host: $target_host" >&2
        return 1
    fi

    if ! ssh_config=$(get_ssh_config "$target_host"); then
        echo "Error: Could not read SSH configuration for target host: $target_host" >&2
        return 1
    fi

    hostname=$(awk '$1 == "hostname" { print $2; exit }' <<< "$ssh_config")
    proxy_jump=$(awk '$1 == "proxyjump" { print $2; exit }' <<< "$ssh_config")
    proxy_command=$(awk '$1 == "proxycommand" {$1=""; sub(/^ /, ""); print; exit}' <<< "$ssh_config")

    if [ -z "$hostname" ]; then
        echo "Error: SSH configuration did not provide a HostName for: $target_host" >&2
        return 1
    fi
    if { [ -n "$proxy_jump" ] && [ "$proxy_jump" != none ]; } || \
       { [ -n "$proxy_command" ] && [ "$proxy_command" != none ]; }; then
        echo "Error: SSH host '$target_host' uses ProxyJump or ProxyCommand, which iptables forwarding cannot use." >&2
        return 1
    fi

    if is_valid_ipv4 "$hostname"; then
        resolved_ip=$hostname
    else
        resolved_ip=$(resolve_ipv4_address "$hostname")
    fi
    if [ -z "$resolved_ip" ] || ! is_valid_ipv4 "$resolved_ip"; then
        echo "Error: Could not resolve an IPv4 address for SSH host '$target_host' (HostName: $hostname)." >&2
        return 1
    fi

    printf '%s\n' "$resolved_ip"
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
        echo "Usage: $0 add <local_port> <target_host> <target_port>"
        exit 1
    fi

    local_port=$1
    target_host=$2
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

    if ! target_ip=$(resolve_target_host "$target_host"); then
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

    if [ "$target_host" = "$target_ip" ]; then
        echo "Added forwarding rule: Local port $local_port -> $target_ip:$target_port"
    else
        echo "Added forwarding rule: Local port $local_port -> $target_host ($target_ip):$target_port"
    fi
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

main() {
    case "${1:-}" in
        -h|--help|help)
            usage 0
            ;;
    esac

    if [ "$EUID" -ne 0 ]; then
        echo "Error: This script must be run as root."
        exit 1
    fi

    if ! command -v iptables &> /dev/null; then
        echo "Error: 'iptables' is not installed. Please install iptables to use this script."
        exit 1
    fi

    case "${1:-}" in
        add)
            add_rule "${2:-}" "${3:-}" "${4:-}"
            ;;
        remove)
            remove_rule "${2:-}"
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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
