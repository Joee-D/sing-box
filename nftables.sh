#!/bin/bash

INTERFACE='lo'
TPROXY_PORT=7895 ## 和 sing-box 中定义的一致
ROUTING_MARK=666 ## 和 sing-box 中定义的一致
PROXY_FWMARK=1
PROXY_ROUTE_TABLE=100

# https://en.wikipedia.org/wiki/Reserved_IP_addresses
LocalNetworkBypass()
{
    nft add rule inet $1 $2 ip daddr 127.0.0.0/8 accept
    nft add rule inet $1 $2 ip daddr 100.64.0.0/10 accept
    nft add rule inet $1 $2 ip daddr 169.254.0.0/16 accept
    nft add rule inet $1 $2 ip daddr 172.16.0.0/12 accept
    nft add rule inet $1 $2 ip daddr 224.0.0.0/4 accept
    nft add rule inet $1 $2 ip daddr 240.0.0.0/4 accept
    nft add rule inet $1 $2 ip daddr 255.255.255.255/32 accept

    nft add rule inet $1 $2 ip daddr 10.0.0.0/16 accept
    nft add rule inet $1 $2 ip daddr 192.168.0.0/16 accept
}

ProxyAddrBypass()
{
    # 改成你的代理ip
    #nft add rule inet $1 $2 ip daddr x.x.x.x/32 accept
}

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
        local handles=$(nft -a list chain inet fw4 ${nft} 2>/dev/null | grep -E "singbox_" | awk -F '# handle ' '{print$2}')
		for handle in $handles; do
			nft delete rule inet fw4 ${nft} handle ${handle} 2>/dev/null
		done
	done

	for handle in $(nft -a list chains | grep -E "chain singbox_" | awk -F '# handle ' '{print$2}'); do
		nft delete chain inet fw4 handle ${handle} 2>/dev/null
	done
 
    echo "clear nftables"
}

if [ $1 = 'set' ]
then

    clearFirewallRules

    ip -f inet rule add fwmark $PROXY_FWMARK lookup $PROXY_ROUTE_TABLE
    ip -f inet route add local default dev $INTERFACE table $PROXY_ROUTE_TABLE

    # ----- prerouting 局域网设备透明代理 -----
    nft add chain inet sing-box prerouting_tproxy { type filter hook prerouting priority -150\; policy accept\; }
    nft add rule inet sing-box prerouting_tproxy meta l4proto {tcp,udp} th dport 53 tproxy to :$TPROXY_PORT accept ## DNS透明代理
    ProxyAddrBypass 'sing-box' 'prerouting_tproxy' ## 代理地址绕过
    nft add rule inet sing-box prerouting_tproxy fib daddr type local accept ## 本机地址绕过
    LocalNetworkBypass 'sing-box' 'prerouting_tproxy' ## 局域网地址绕过
    nft add rule inet sing-box prerouting_tproxy meta l4proto udp accept ## UDP绕过
    nft add rule inet sing-box prerouting_tproxy meta l4proto {tcp,udp} socket transparent 1 meta mark set $PROXY_FWMARK accept ## 绕过已经建立的tproxy连接
    nft add rule inet sing-box prerouting_tproxy meta l4proto {tcp,udp} tproxy to :$TPROXY_PORT meta mark set $PROXY_FWMARK ## 其他流量透明代理

    # ----- output 网关本机透明代理 -----
    nft add chain inet sing-box output_tproxy { type route hook output priority -150\; policy accept\; }
    nft add rule inet sing-box output_tproxy meta oifname != $INTERFACE accept ## 绕过本机内部通信的流量(接口lo)
    nft add rule inet sing-box output_tproxy meta mark $ROUTING_MARK accept ## 绕过本机sing-box发出的流量
    nft add rule inet sing-box output_tproxy meta l4proto {tcp,udp} th dport 53 meta mark set $PROXY_FWMARK accept ## DNS重路由到prerouting
    nft add rule inet sing-box output_tproxy udp dport {123,137} accept ## 绕过NTP、NBNS流量
    ProxyAddrBypass 'sing-box' 'output_tproxy' ## 代理地址绕过
    nft add rule inet sing-box output_tproxy fib daddr type local accept ## 本机地址绕过
    LocalNetworkBypass 'sing-box' 'output_tproxy' ## 局域网地址绕过
    nft add rule inet sing-box output_tproxy meta l4proto {tcp,udp} meta mark set $PROXY_FWMARK ## 其他流量重路由到prerouting
    
    # ----- output quic拒绝 -----
    # 防止 YouTube 等使用 QUIC 导致速度不佳, 慎用
    nft add chain inet sing-box output_quic_reject { type filter hook output priority 0\; policy accept\; }
    nft add rule inet sing-box output_quic_reject udp dport 443 reject with icmpx type host-unreachable

    # ----- forward quic拒绝 -----
    # 防止 YouTube 等使用 QUIC 导致速度不佳, 慎用
    nft add chain inet sing-box forward_quic_reject { type filter hook forward priority 0\; policy accept\; }
    nft add rule inet sing-box forward_quic_reject udp dport 443 reject with icmpx type host-unreachable
    
    echo "set nftables"

elif [ $1 = 'clear' ]
then
    clearFirewallRules
fi

