#!/bin/bash

INTERFACE='lo'
TPROXY_PORT=7895 ## 和 sing-box 中定义的一致
ROUTING_MARK=666 ## 和 sing-box 中定义的一致
PROXY_FWMARK=1
PROXY_ROUTE_TABLE=100

clearFirewallRules()
{
    # ----- 删除路由表 -----
    IPRULE=$(ip rule show | grep $PROXY_ROUTE_TABLE)
    if [ -n "$IPRULE" ]
    then
        ip -f inet rule del fwmark $PROXY_FWMARK lookup $PROXY_ROUTE_TABLE
        ip -f inet route del local default dev $INTERFACE table $PROXY_ROUTE_TABLE
        echo "clear ip rule"
    fi
    # ----- 删除防火墙规则 -----
    for nft in "mangle_prerouting" "mangle_output"; do
        local handles=$(nft -a list chain inet fw4 ${nft} 2>/dev/null | grep -E "_tproxy" | awk -F '# handle ' '{print$2}')
            for handle in $handles; do
            nft "delete rule inet fw4 ${nft} handle ${handle}" 2>/dev/null
        done
    done
    # ----- 删除防火墙链 -----
    for handle in $(nft -a list chains | grep -E "_tproxy" | awk -F '# handle ' '{print$2}'); do
        nft "delete chain inet fw4 handle ${handle}" 2>/dev/null
    done
    # ----- 删除防火墙集合 -----
    nft "delete set inet fw4 localnetwork"
    nft "delete set inet fw4 direct"

    echo "clear nftables"
}

setFirewallRules()
{
    # ----- 添加路由表 -----
    ip -f inet rule add fwmark $PROXY_FWMARK lookup $PROXY_ROUTE_TABLE
    ip -f inet route add local default dev $INTERFACE table $PROXY_ROUTE_TABLE
	
	echo "set ip rule"
	
    # ----- 防火墙ip地址集合 -----
    nft add set inet fw4 localnetwork { type ipv4_addr \; flags interval \; }
    nft add element inet fw4 localnetwork { 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 224.0.0.0/4, 192.168.0.0/16 }
    nft add set inet fw4 direct { type ipv4_addr \; flags interval \; }
    nft add element inet fw4 direct { 192.168.1.1-192.168.1.100 }

    # ----- prerouting 局域网设备透明代理 -----
    nft "add chain inet fw4 prerouting_tproxy"
    nft "add rule inet fw4 prerouting_tproxy ip daddr @localnetwork return" ## 绕过局域网地址
	nft "add rule inet fw4 prerouting_tproxy fib daddr type local return" ## 绕过本机地址
    nft "add rule inet fw4 prerouting_tproxy ip saddr @direct return" ## 绕过直连地址
    nft "add rule inet fw4 prerouting_tproxy meta l4proto {tcp,udp} socket transparent 1 meta mark set $PROXY_FWMARK return" ## 绕过已经建立的tproxy连接
    nft "add rule inet fw4 prerouting_tproxy meta l4proto {tcp,udp} tproxy to :$TPROXY_PORT meta mark set $PROXY_FWMARK" accept ## 其他流量透明代理

    # ----- output 网关本机透明代理 -----
    nft "add chain inet fw4 output_tproxy"
    nft "add rule inet fw4 output_tproxy meta oifname != $INTERFACE return" ## 绕过本机内部通信的流量(接口lo)
    nft "add rule inet fw4 output_tproxy meta mark $ROUTING_MARK return" ## 绕过本机sing-box发出的流量
    nft "add rule inet fw4 output_tproxy ip daddr @localnetwork return" ## 绕过局域网地址
	nft "add rule inet fw4 output_tproxy fib daddr type local return" ## 绕过本机地址
    nft "add rule inet fw4 output_tproxy ip saddr @direct return" ## 绕过直连地址
    nft "add rule inet fw4 output_tproxy meta l4proto {tcp,udp} meta mark set $PROXY_FWMARK" ## 其他流量重路由到prerouting

	nft "add rule inet fw4 mangle_prerouting meta nfproto {ipv4} counter jump prerouting_tproxy"
	nft "add rule inet fw4 mangle_output meta nfproto {ipv4} counter jump output_tproxy"

    echo "set nftables"
}

if [ $1 = 'start' ]
then
    setFirewallRules
elif [ $1 = 'stop' ]
then
    clearFirewallRules
fi
