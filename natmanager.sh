#!/bin/bash

TARGET_NETWORK="10.5.0.0/24"
SOURCE_IP="XXX.XXX.XXX.XXX"
INTERFACE="eth0"

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

usage() {
    echo "Usage: $0 {add|delete|list|backup|restore} [parameters]"
    echo "  add [protocol] [port] [to-address] [to-port]"
    echo "  delete [protocol] [port] [to-address] [to-port]"
    echo "  list"
    echo "  backup [file]"
    echo "  restore [file]"
    echo ""
    echo "Example:"
    echo "  $0 add tcp 10100 10.5.0.100 22"
    echo ""
    exit 1
}

check_protocol() {
    if [[ "$protocol" != "tcp" && "$protocol" != "udp" ]]; then
        echo "Unsupported protocol: $protocol"
        exit 1
    fi
}

add_rule() {
    local protocol=$1
    local port=$2
    local to_address=$3
    local to_port=$4

    if [[ -z "$protocol" || -z "$port" || -z "$to_address" || -z "$to_port" ]]; then
        usage
    fi

    check_protocol

    if rule_exists "$protocol" "$port" "$to_address" "$to_port"; then
        echo "NAT rule already exists: $protocol $port -> $to_address:$to_port"
        exit 1
    fi

    iptables -t nat -A PREROUTING -i $INTERFACE -p "$protocol" -m "$protocol" --dport "$port" -j DNAT --to-destination "$to_address:$to_port"
    echo "Added NAT rule: $protocol $port -> $to_address:$to_port"

    update_script "post-up.sh" "add" "$protocol" "$port" "$to_address" "$to_port"
    update_script "pre-down.sh" "add" "$protocol" "$port" "$to_address" "$to_port"
}

delete_rule() {
    local protocol=$1
    local port=$2
    local to_address=$3
    local to_port=$4

    if [[ -z "$protocol" || -z "$port" || -z "$to_address" || -z "$to_port" ]]; then
        usage
    fi

    check_protocol

    if rule_exists "$protocol" "$port" "$to_address" "$to_port"; then
        iptables -t nat -D PREROUTING -i $INTERFACE -p "$protocol" -m "$protocol" --dport "$port" -j DNAT --to-destination "$to_address:$to_port"
        echo "Deleted NAT rule: $protocol $port -> $to_address:$to_port"

        update_script "post-up.sh" "delete" "$protocol" "$port" "$to_address" "$to_port"
        update_script "pre-down.sh" "delete" "$protocol" "$port" "$to_address" "$to_port"
    else
        echo "No such NAT rule found: $protocol $port -> $to_address:$to_port"
    fi
}

rule_exists() {
    local protocol=$1
    local port=$2
    local to_address=$3
    local to_port=$4

    iptables -t nat -L PREROUTING -n --line-numbers | grep -q "$protocol.*dpt:$port .*to:$to_address:$to_port"
}

list_rules() {
    echo "Listing all NAT rules:"
    iptables -t nat -L PREROUTING -n --line-numbers
}

backup_rules() {
    local file=$1
    if [[ -z "$file" ]]; then
        echo "Please specify a file name to backup the rules."
        exit 1
    fi

    iptables-save -t nat > "$file"
    echo "NAT rules backed up to $file"
}

restore_rules() {
    local file=$1
    if [[ -z "$file" || ! -f "$file" ]]; then
        echo "Please specify a valid backup file to restore the rules."
        exit 1
    fi

    iptables-restore -t nat < "$file"
    echo "NAT rules restored from $file"
}

update_script() {
    local file=$1
    local action=$2
    local protocol=$3
    local port=$4
    local to_address=$5
    local to_port=$6

    check_protocol

    declare -A tmp_dnat_tcp_rules=()
    declare -A tmp_dnat_udp_rules=()

    if [[ -f "$file" ]]; then
        while IFS= read -r line; do
            if [[ $line == "declare -A dnat_tcp_rules="* ]]; then
                eval "$line"
                for rule in "${!dnat_tcp_rules[@]}"; do
                    tmp_dnat_tcp_rules["$rule"]="${dnat_tcp_rules[$rule]}"
                done
            elif [[ $line == "declare -A dnat_udp_rules="* ]]; then
                eval "$line"
                for rule in "${!dnat_udp_rules[@]}"; do
                    tmp_dnat_udp_rules["$rule"]="${dnat_udp_rules[$rule]}"
                done
            fi
        done < "$file"
    fi

    if [[ "$action" == "add" ]]; then
        if [[ "$protocol" == "tcp" ]]; then
            tmp_dnat_tcp_rules["$port"]="$to_address:$to_port"
        elif [[ "$protocol" == "udp" ]]; then
            tmp_dnat_udp_rules["$port"]="$to_address:$to_port"
        fi
    elif [[ "$action" == "delete" ]]; then
        if [[ "$protocol" == "tcp" ]]; then
            unset tmp_dnat_tcp_rules["$port"]
        elif [[ "$protocol" == "udp" ]]; then
            unset tmp_dnat_udp_rules["$port"]
        fi
    fi

    if [[ -f "$file" ]]; then
        cp "$file" "$file.bak"
    fi

    {
        echo '#!/bin/bash'
        echo ''
        echo "TARGET_NETWORK=\"$TARGET_NETWORK\""
        echo "SOURCE_IP=\"$SOURCE_IP\""
        echo "INTERFACE=\"$INTERFACE\""
        echo ''
        if [[ "$file" == "post-up.sh" ]]; then
            echo 'iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1'
            echo 'iptables -t nat -A POSTROUTING -s $TARGET_NETWORK -o $INTERFACE -j MASQUERADE'
            echo 'iptables -t nat -A POSTROUTING -s $TARGET_NETWORK -o $INTERFACE -j SNAT --to-source $SOURCE_IP'
            echo ''
        fi
        echo -n 'declare -A dnat_tcp_rules=( '
        for key in "${!tmp_dnat_tcp_rules[@]}"; do
            echo -n "[$key]=\"${tmp_dnat_tcp_rules[$key]}\" "
        done
        echo ')'
        echo ''
        echo -n 'declare -A dnat_udp_rules=( '
        for key in "${!tmp_dnat_udp_rules[@]}"; do
            echo -n "[$key]=\"${tmp_dnat_udp_rules[$key]}\" "
        done
        echo ')'
        echo ''
        echo 'for port in "${!dnat_tcp_rules[@]}"; do'
        if [[ "$file" == "post-up.sh" ]]; then
            echo '    iptables -t nat -A PREROUTING -i $INTERFACE -p tcp -m tcp --dport "$port" -j DNAT --to-destination "${dnat_tcp_rules[$port]}"'
        else
            echo '    iptables -t nat -D PREROUTING -i $INTERFACE -p tcp -m tcp --dport "$port" -j DNAT --to-destination "${dnat_tcp_rules[$port]}"'
        fi
        echo 'done'
        echo ''
        echo 'for port in "${!dnat_udp_rules[@]}"; do'
        if [[ "$file" == "post-up.sh" ]]; then
            echo '    iptables -t nat -A PREROUTING -i $INTERFACE -p udp -m udp --dport "$port" -j DNAT --to-destination "${dnat_udp_rules[$port]}"'
        else
            echo '    iptables -t nat -D PREROUTING -i $INTERFACE -p udp -m udp --dport "$port" -j DNAT --to-destination "${dnat_udp_rules[$port]}"'
        fi
        echo 'done'
        if [[ "$file" == "pre-down.sh" ]]; then
            echo ''
            echo 'iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1'
            echo 'iptables -t nat -D POSTROUTING -s $TARGET_NETWORK -o $INTERFACE -j MASQUERADE'
            echo 'iptables -t nat -D POSTROUTING -s $TARGET_NETWORK -o $INTERFACE -j SNAT --to-source $SOURCE_IP'
        fi
    } > "$file"

    chmod +x "$file"

    echo "Updated $file"
}

case "$1" in
    add)
        shift
        add_rule "$@"
        ;;
    delete)
        shift
        delete_rule "$@"
        ;;
    list)
        list_rules
        ;;
    backup)
        shift
        backup_rules "$@"
        ;;
    restore)
        shift
        restore_rules "$@"
        ;;
    *)
        usage
        ;;
esac
