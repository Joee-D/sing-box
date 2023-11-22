#!/bin/bash

INTERFACE='lo'
TPROXY_PORT=7895 ## 和 sing-box 中定义的一致
ROUTING_MARK=666 ## 和 sing-box 中定义的一致
PROXY_FWMARK=1
PROXY_ROUTE_TABLE=100

clearFirewallRules()
{
    IPRULE=$(ip rule show | grep $PROXY_ROUTE_TABLE)
    if [ -n "$IPRULE" ]
    then
        ip -f inet rule del fwmark $PROXY_FWMARK lookup $PROXY_ROUTE_TABLE
        ip -f inet route del local default dev $INTERFACE table $PROXY_ROUTE_TABLE
        echo "clear ip rule"
    fi

	for nft in "mangle_prerouting" "mangle_output"; do
        local handles=$(nft -a list chain inet fw4 ${nft} 2>/dev/null | grep -E "prerouting_tproxy" | grep -E "output_tproxy" | awk -F '# handle ' '{print$2}')
		for handle in $handles; do
			nft delete rule inet fw4 ${nft} handle ${handle} 2>/dev/null
		done
	done

	for handle in $(nft -a list chains | grep -E "chain prerouting_tproxy" | grep -E "chain output_tproxy" | awk -F '# handle ' '{print$2}'); do
		nft delete chain inet fw4 handle ${handle} 2>/dev/null
	done
 
    echo "clear nftables"
}

if [ $1 = 'set' ]
then

    clearFirewallRules

    ip -f inet rule add fwmark $PROXY_FWMARK lookup $PROXY_ROUTE_TABLE
    ip -f inet route add local default dev $INTERFACE table $PROXY_ROUTE_TABLE

    nft add set inet fw4 localnetwork { type ipv4_addr \; flags interval \; }
    nft add set inet fw4 direct { type ipv4_addr \; flags interval \; }
    nft add element inet fw4 localnetwork { 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 224.0.0.0/4, 240.0.0.0/4, 255.255.255.255/32 }
    nft add element inet fw4 direct { 192.168.1.1-192.168.1.100 }

    # ----- prerouting 局域网设备透明代理 -----
    nft add chain inet fw4 prerouting_tproxy
    #nft add rule inet fw4 prerouting_tproxy meta l4proto {tcp,udp} th dport 53 tproxy to :$TPROXY_PORT accept ## DNS透明代理
    nft add rule inet fw4 prerouting_tproxy ip daddr @localnetwork return ## 局域网地址绕过
    nft add rule inet fw4 prerouting_tproxy ip saddr @direct return ## 直连地址绕过
    nft add rule inet fw4 prerouting_tproxy meta l4proto {tcp,udp} socket transparent 1 meta mark set $PROXY_FWMARK return ## 绕过已经建立的tproxy连接
    nft add rule inet fw4 prerouting_tproxy meta l4proto {tcp,udp} tproxy to :$TPROXY_PORT meta mark set $PROXY_FWMARK accept## 其他流量透明代理

    # ----- output 网关本机透明代理 -----
    nft add chain inet fw4 output_tproxy
    nft add rule inet fw4 output_tproxy meta oifname != $INTERFACE return ## 绕过本机内部通信的流量(接口lo)
    nft add rule inet fw4 output_tproxy meta mark $ROUTING_MARK return ## 绕过本机sing-box发出的流量
    nft add rule inet fw4 prerouting_tproxy ip daddr @localnetwork return ## 局域网地址绕过
    nft add rule inet fw4 prerouting_tproxy ip saddr @direct return ## 直连地址绕过
    nft add rule inet fw4 output_tproxy meta l4proto {tcp,udp} meta mark set $PROXY_FWMARK ## 其他流量重路由到prerouting
    
    echo "set nftables"

elif [ $1 = 'clear' ]
then
    clearFirewallRules
fi

