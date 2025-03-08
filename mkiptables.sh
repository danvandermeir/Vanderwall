#!/bin/bash
unset IFS
######        USER MODIFICATION AREA        ######
#       Expected array format
#X=('' 'X' '' 'Y' '' '' 'Z' '')

#       Output configuration warning messages
WARNING=true

#       State WAN/gateway interface names in array format
WANINTS=('' '')
#       State default (first) WAN interface open ports (E.G. 80/443 for HTTP/HTTPS servers) in array format or a single 'all' for completely open (NOT RECOMMENDED!)
WANPRTS=('' '' '' '')
#       Open default WAN ports on all WAN interfaces
WANSPRT=false

#       State LAN interface names in array format, unstated interfaces may have undefined behaviors
LANINTS=('' '' '')
#       State WAN interface name each LAN will use as gateway in array format, if gateway not required use blank entry ('')
LANOUTS=('' '' '')

#       State default WAN interface ports to forward in array format
PRTFWDS=('' '' '' '' '')
#       Forward default WAN ports on all WAN interfaces
PRTSWAN=false
#       Forward default WAN ports on all LAN interfaces
PRTSLAN=false
#       State LAN interface name each port forward should go to in array format
PRTLANS=('' '' '' '' '')
#       State LAN IP each port should forward to in array format
PRTSIPS=('' '' '' '' '')
#       State LAN destination ports in array format, blank ('') entries won't be translated
PRTPRTS=('' '' '' '' '')

######        NEEDED FUNCTIONS        ######
err() {
	[ -n "$1" ] && printf -- "$1\n" 1>&2 && return 0
	return 1
}
errout() {
	err "$1"
	exit 1
}
isip() {
	if [ -z "$1" ] || [[ ! $1 =~ ^[0-9/.]+$ ]]; then
		$WARNING && err "$1 is not a valid IPv4 address!"
		return 1
	fi
	local a1 a2 a3 a4 v
	a4="$1"
	a1=${a4//.}
	if [ $((${#a4} - ${#a1})) -ne 3 ]; then
		$WARNING && err "$1 is not a valid IPv4 address!"
		return 1
	fi
	for y in {1..4}; do
		declare a$y="${a4%%.*}"
		v="a$y"
		if [ -z "${!v}" ] || [ ${!v} -gt 255 ]; then
			$WARNING && err "$1 is not a valid IPv4 address!"
			return 1
		fi
		a4="${a4#*.}"
	done
	return 0
}
iscidr() {
	if [ -z "$1" ] || [[ ! $1 =~ ^[0-9/./\/]+$ ]] || ! isip "${1%/*}"; then
		$WARNING && err "$1 is not a valid CIDR address!"
		return 1
	fi
	local m1
	m1="${1#*/}"
	if [ -z "$m1" ] || [[ "$m1" = *'.'* ]] || [[ "$m1" = *'/'* ]] || [ $m1 -gt 32 ]; then
		$WARNING && err "$1 is not a valid CIDR address!"
		return 1
	fi
	return 0
}
cidrtomask() {
	[ -z "$1" ] || [[ ! $1 =~ ^[0-9]+$ ]] || [ $1 -lt 8 ] || [ $1 -gt 32 ] && errout "CIDR bit length not provided to cidrtomask function (expected 8-32, got '$1')!"
	local i mask full part
	full=$(($1/8))
	part=$(($1%8))
	for ((i=0;i<4;i+=1)); do
		if [ $i -lt $full ]; then
			mask+=255
		elif [ $i -eq $full ]; then
			mask+=$((256 - 2**(8-$part)))
		else
			mask+=0
		fi
		test $i -lt 3 && mask+=.
	done
	printf "$mask"
	return 0
}
networkmin() {
	 [ -z "$1" ] || ! iscidr "$1" && errout "CIDR address not provided to networkmin function ($1)!"
	local a1 a2 a3 a4 m1 m2 m3 m4
	IFS=. read -r a1 a2 a3 a4<<<"${1%/*}"
	IFS=. read -r m1 m2 m3 m4<<<"$(cidrtomask ${1#*/})"
	a1=$((a1 & m1))
	a2=$((a2 & m2))
	a3=$((a3 & m3))
	a4=$((a4 & m4))
	printf "$a1.$a2.$a3.$a4"
	return 0
}
inntwrk() {
	[ -z "$1" ] || ! isip "$1" && return 1
	[ -z "$2" ] || ! iscidr "$2" && return 1
	[ "$(networkmin $1/${2#*/})" = "$(networkmin $2)" ] && return 0
	return 1
}
isport() {
	if [ -z "$1" ] || [[ ! $1 =~ ^[0-9]+$ ]] || [ $1 -lt 0 ] || [ $1 -gt 65535 ]; then
		$WARNING && err "$1 is not a valid port!"
		return 1
	fi
	return 0
}
BINARIES=('iptables' 'ip')
for x in "${!BINARIES[@]}"; do
	BINARIES[$x]="$(command -v ${BINARIES[$x]})" || errout "Required binaries (applications) not available!"
done

######        VERIFY INTERFACES, NETWORKS, PORT FORWARDS, AND IPv4 FORWARDING        ######

#       Verify all interfaces and get addresses/networks
[ -z "${WANINTS[*]}" ] && errout 'No WANs specified, nothing to do! Exiting!'
for x in "${!WANINTS[@]}"; do
	WANCIDRS[$x]=$(ip a show ${WANINTS[$x]} 2>/dev/null|grep -w 'inet')
	if [ -z "${WANCIDRS[$x]}" ]; then
		ERRMESS="WAN interface ${WANINTS[$x]} (array # $x) does not have a valid IPv4 address, will not configure this interface!"
		[ $x = 0 ] && errout "$ERRMESS Exiting!"
		$WARNING && err "$ERRMESS"
		unset WANINTS[$x] WANOUTS[$x] WANCIDRS[$x]
		continue 1
	fi
	WANCIDRS[$x]=${WANCIDRS[$x]#*inet }
	WANCIDRS[$x]=${WANCIDRS[$x]%% *}
	if ! iscidr "${WANCIDRS[$x]}"; then
		ERRMESS="WAN interface ${WANINTS[$x]} (array # $x) will not be configured!"
		[ $x = 0 ] && errout "$ERRMESS Exiting!"
		$WARNING && err "$ERRMESS"
		unset WANINTS[$x] WANOUTS[$x] WANCIDRS[$x]
		continue 1
	fi
	WANIPS[$x]=${WANCIDRS[$x]%/*}
	WANCIDRS[$x]="$(networkmin ${WANCIDRS[$x]})/${WANCIDRS[$x]#*/}"
done
$WARNING && [ -z "${LANINTS[*]}" ] && err 'No LANs specified!'
for x in "${!LANINTS[@]}"; do
	if [ -n "${LANOUTS[$x]}" ]; then
		y=true
		for z in "${!WANINTS[@]}"; do
			[ "${LANOUTS[$x]}" = "${WANINTS[$z]}" ] && y=false && break
		done
		$y && LANOUTS[$x]='' && $WARNING && err "LAN interface ${LANINTS[$x]} (array # $x) has invalid WAN/gateway interface, removing gateway from this LAN!"
	fi
	LANCIDRS[$x]=$(ip a show ${LANINTS[$x]} 2>/dev/null|grep -w 'inet')
	if [ -z "${LANCIDRS[$x]}" ]; then
		$WARNING && err "LAN interface ${LANINTS[$x]} (array # $x) does not have a valid IPv4 adress, will not configure this interface!"
				unset LANINTS[$x] LANOUTS[$x] LANCIDRS[$x]
		continue 1
	fi
	LANCIDRS[$x]=${LANCIDRS[$x]#*inet }
	LANCIDRS[$x]=${LANCIDRS[$x]%% *}
	if ! iscidr "${LANCIDRS[$x]}"; then
		$WARNING && err "LAN interface ${LANINTS[$x]} (array # $x) will not be configured!"
		unset LANINTS[$x] LANOUTS[$x] LANCIDRS[$x]
		continue 1
	fi
	LANIPS[$x]=${LANCIDRS[$x]%/*}
	LANCIDRS[$x]="$(networkmin ${LANCIDRS[$x]})/${LANCIDRS[$x]#*/}"
done

#       Verify all open ports and port forwards
for x in "${!PRTFWDS[@]}"; do
	if ! isport "${PRTFWDS[$x]}"; then
		$WARNING && err "Port forward (${PRTFWDS[$x]}) will not be used!"
		unset PRTFWDS[$x] PRTLANS[$x] PRTSIPS[$x] PRTPRTS[$x]
		continue 1
	fi
	if [ "${WANPRTS[0]}" != 'all' ]; then
		y=false
		for z in "${!WANPRTS[@]}"; do
			if [ "${PRTFWDS[$x]}" = "${WANPRTS[$z]}" ]; then
				$WARNING && err "Port forward (${PRTFWDS[$x]}) conflicts with open WAN port, will not forward this port!"
				y=true
				unset PRTFWDS[$x] PRTLANS[$x] PRTSIPS[$x] PRTPRTS[$x]
				break 1
			fi
		done
		$y && continue 1
	fi
	y=true
	for z in "${!LANINTS[@]}"; do
		if [ "${LANINTS[$z]}" = "${PRTLANS[$x]}" ]; then
			$WARNING && ! inntwrk "${PRTSIPS[$x]}" "${LANCIDRS[$z]}" && err "Port forward (${PRTFWDS[$x]}) destination LAN IP (${PRTSIPS[$x]}) is not in LAN interface (${LANINTS[$z]}) network (${LANCIDRS[$z]})!"
			y=false
			break 1
		fi
	done
	if [ "$y" = true ]; then
		$WARNING && err "Port ${PRTFWDS[$x]} forward (array # $x) LAN interface does not exist, will not forward this port!"
		unset PRTFWDS[$x] PRTLANS[$x] PRTSIPS[$x] PRTPRTS[$x]
		continue 1
	fi
	if ! isport "${PRTFWDS[$x]}"; then
		$WARNING && err "Port ${PRTFWDS[$x]} forward (array # $x) destination port invalid, will not forward this port!"
		unset PRTFWDS[$x] PRTLANS[$x] PRTSIPS[$x] PRTPRTS[$x]
	fi
done

#       IPv4 FORWARDING
echo "1" > /proc/sys/net/ipv4/ip_forward
sysctl net.ipv4.ip_forward=1

######        CLEAR POLICIES AND RULES AND ADD NEW POLICIES AND RULES        ######

#       POLICY + FLUSH
iptables -F INPUT
iptables -F OUTPUT
iptables -F FORWARD
iptables -F -t nat
iptables -F -t raw
iptables -F -t mangle
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

#       INPUT RULES
echo "allow in from broadcast"
iptables -A INPUT -d 255.255.255.255 -j ACCEPT
echo " drop in from different LAN* on LAN*"
for x in "${!LANINTS[@]}"; do
	for y in "${!LANINTS[@]}"; do
		[ $x -eq $y ] && continue 1
		iptables -A INPUT -i ${LANINTS[$x]} -d ${LANCIDRS[$y]} -j DROP
	done
done
echo "allow in from LAN* on same LAN*"
for x in "${!LANINTS[@]}"; do
	iptables -A INPUT -i "${LANINTS[$x]}" -s "${LANCIDRS[$x]}" -j ACCEPT
done
echo " drop in from localhost and LAN* on WANs (spoofers)"
for x in "${!WANINTS[@]}"; do
	iptables -A INPUT -i "${WANINTS[$x]}" -s 127.0.0.0/8 -j DROP
	for y in "${!LANINTS[@]}"; do
	      iptables -A INPUT -i "${WANINTS[$x]}" -s "${LANCIDRS[$y]}" -j DROP
	done
done
echo "allow in to WAN on WAN"
if [ "$WANPRTS" = 'all' ]; then
	for x in "${!WANINTS[@]}"; do
		iptables -A INPUT -i "${WANINTS[$x]}" -d "${WANIPS[$x]}" -j ACCEPT
		$WANSPRT || break 1
	done
else
	for x in "${!WANINTS[@]}"; do
		for y in "${!WANPRTS[@]}"; do
			iptables -A INPUT -i "${WANINTS[$x]}" -d "${WANIPS[$x]}" -p tcp --dport "${WANPRTS[$y]}" -j ACCEPT
			iptables -A INPUT -i "${WANINTS[$x]}" -d "${WANIPS[$x]}" -p udp --dport "${WANPRTS[$y]}" -j ACCEPT
		done
		$WANSPRT || break 1
	done
fi
echo "allow in on localhost"
iptables -A INPUT -i lo -j ACCEPT

#       OUTPUT RULES
echo "allow out to broadcast"
iptables -A OUTPUT -d 255.255.255.255 -j ACCEPT
echo "allow out from LAN* from same LAN*"
for x in "${!LANINTS[@]}"; do
	iptables -A OUTPUT -o "${LANINTS[$x]}" -s "${LANCIDRS[$x]}" -d "${LANCIDRS[$x]}" -j ACCEPT
done
echo "allow out from LAN* from WAN"
for x in "${!WANINTS[@]}"; do
	for y in "${!LANINTS[@]}"; do
	       [ "${WANINTS[$x]}" = "${LANOUTS[$y]}" ] && iptables -A OUTPUT -o "${LANINTS[$y]}" -s "${WANIPS[$x]}" -j ACCEPT
	done
done
echo " drop out from WAN from LAN*"
for x in "${!WANINTS[@]}"; do
	for y in "${!LANINTS[@]}"; do
		iptables -A OUTPUT -o "${WANINTS[$x]}" -s "${LANCIDRS[$y]}" -j DROP
	done
done
echo "allow out from WAN from WAN"
for x in "${!WANINTS[@]}"; do
	iptables -A OUTPUT -o "${WANINTS[$x]}" -s "${WANIPS[$x]}" -j ACCEPT
done
echo "allow out from local"
iptables -A OUTPUT -o lo -s 127.0.0.0/8 -j ACCEPT

#       FORWARD RULES
echo "allow forward to WAN on LAN*"
for x in "${!LANINTS[@]}"; do
	[ -z "${LANOUTS[$x]}" ] && continue 1
	iptables -A FORWARD -i "${LANINTS[$x]}" -o "${LANOUTS[$x]}" -j ACCEPT
done
echo "allow forward for established/related to LAN* on WAN"
for x in "${!LANINTS[@]}"; do
	[ -z "${LANOUTS[$x]}" ] && continue 1
	iptables -A FORWARD -i "${LANOUTS[$x]}" -o "${LANINTS[$x]}" -m state --state ESTABLISHED,RELATED -j ACCEPT
done

#       POSTROUTING RULES
echo "allow masquerade NAT on WAN"
for x in "${!WANINTS[@]}"; do
	iptables -t nat -A POSTROUTING -o "${WANINTS[$x]}" -j MASQUERADE
done

#       PREROUTING/FORWARD RULES FOR PORT FORWARDS
echo "change destination IP for designated ports, and allow forwarding to LAN* for designated ports"
for x in "${!PRTFWDS[@]}"; do
	iptables -I FORWARD -o "${PRTLANS[$x]}" -p tcp --dport "${PRTFWDS[$x]}" -j ACCEPT
	iptables -I FORWARD -o "${PRTLANS[$x]}" -p udp --dport "${PRTFWDS[$x]}" -j ACCEPT
	for y in "${!WANINTS[@]}"; do
		iptables -t nat -I PREROUTING -i "${WANINTS[$y]}" -p tcp --dport "${PRTFWDS[$x]}" -j DNAT --to "${PRTSIPS[$x]}"
		iptables -t nat -I PREROUTING -i "${WANINTS[$y]}" -p udp --dport "${PRTFWDS[$x]}" -j DNAT --to "${PRTSIPS[$x]}"
		$PRTSWAN || break 1
	done
	if [ "$PRTSLAN" = true ]; then
		for y in "${!LANINTS[@]}"; do
			iptables -t nat -I PREROUTING -i "${LANINTS[$y]}" -p tcp --dport "${PRTFWDS[$x]}" -j DNAT --to "${PRTSIPS[$x]}"
			iptables -t nat -I PREROUTING -i "${LANINTS[$y]}" -p udp --dport "${PRTFWDS[$x]}" -j DNAT --to "${PRTSIPS[$x]}"
		done
	fi
done
exit 0
