#!/bin/bash
err() {
		[ -n "$1" ] && printf -- "$1\n" 1>&2 && return 0
		return 1
}
errout() {
		err "$1"
		exit 1
}
appexist() {
	command -v $1 > /dev/null && return 0
	return 1
}
if [[ $EUID -ne 0 ]]; then
	if appexist 'sudo'; then
        err 'Not root! Rerunning with sudo!\n'
        exec sudo /bin/bash "$0" "$@"
        echo "$?"
        [ $? -eq 0 ] && exit 0
    fi
    err 'Not root! Rerunning with su!\n'
    exec su -c "/bin/bash $0 $@" root
	exit 0
fi
ip a show dev "$1" &>/dev/null || errout "Interface $1 does not exist!"
isnum() {
	[ -z "$1" ] || ! [[ $1 =~ ^[0-9]+$ ]] && return 1
	return 0
}
isip() {
	[ -z "$1" ] || [[ ! $1 =~ ^[0-9/.]+$ ]] && return 1
	local a1 a2 a3 a4 v
	a4="$1"
	a1=${a4//.}
	[ $((${#a4} - ${#a1})) -ne 3 ] && return 1
	for y in {1..4}; do
		declare a$y="${a4%%.*}"
		v="a$y"
		[ -z "${!v}" ] || [ ${!v} -gt 255 ] && return 1
		a4="${a4#*.}"
	done
	return 0
}
iscidr() {
	[ -z "$1" ] || [[ ! $1 =~ ^[0-9/./\/]+$ ]] || ! isip "${1%/*}" && return 1
	local m1
	m1="${1#*/}"
	[ -z "$m1" ] || ! isnum "$m1" || [ $m1 -lt 8 ] || [ $m1 -gt 32 ] && return 1
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
	 [ -z $1 ] || ! iscidr "$1" && errout 'CIDR address not provided to networkmin function!'
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
	[ "$(networkmin $1/${2#*/})" != "$(networkmin $2)" ] && return 1
	return 0
}
getnextnetwork() {
	[ -z $1 ] || ! iscidr "$1" && errout "CIDR network not provided to getnextnetwork function!"
	local a1 a2 a3 a4 a5 a6 h1 h2 h3 h4 m1 m2 m3 m4 address
	IFS=. read -r a1 a2 a3 a4<<<"${1%/*}"
	a5=${1#*/}
	a6=$((32 - a5))
	h1=$a1
	h2=$a2
	h3=$a3
	h4=$a4
	IFS=. read -r m1 m2 m3 m4<<<"$(cidrtomask $a5)"
	address=$((((((((((a1 << 8) | a2) << 8) | a3) << 8) | a4) >> a6) + 1) << a6 ))
	a4=$(( ((255 & address) & m4) | (h4 & (255 ^ m4)) ))
	address=$((address >> 8))
	a3=$(( ((255 & address) & m3) | (h3 & (255 ^ m3)) ))
	address=$((address >> 8))
	a2=$(( ((255 & address) & m2) | (h2 & (255 ^ m2)) ))
	address=$((address >> 8))
	a1=$(( ((255 & address) & m1) | (h1 & (255 ^ m1)) ))
	[ $h1 -eq 10 ] && [ $a1 -ne 10 ] && a1=10
	[ "$h1$h2" = "192168" ] && [ "$a1$a2" != "192168" ] && a1=192 && a2=168
	[ "$h1$h2" = "169254" ] && [ "$a1$a2" != "169254" ] && a1=169 && a2=254
	[ $a1 -eq 172 ] && [ $a2 -gt 31 ] && a2=16
	printf "$a1.$a2.$a3.$a4/$a5"
	return 0
}
#remove any preexisting iptables rules, routes, and redirect descriptions
[ -f "/etc/wireguard/redirects-$1" ] && rm -f "/etc/wireguard/redirects-$1"
while iptables -t nat -L OUTPUT --line-numbers -v|grep -qw "$1"; do
	x="$(iptables -t nat -L OUTPUT --line-numbers -v|grep -w $1)"
    iptables -t nat -D OUTPUT "${x%% *}"
done
#get all wireguard nets
netd="$(wg show $1|grep 'allowed ips: ')"
if [ -z "$netd" ]; then
	[ -f /etc/wireguard/"$1".conf ] || errout "No such interface or interface file matching '$1'! Exiting!"
	while IFS= read -r x || [[ -n $x ]]; do
		x="${x#*=}"
		x="${x//$'\t'/}"
		x="${x// /}"
		netd="$netd${x//,/$'\n'}"$'\n'
	done < <(grep -e AllowedIPs -e Address "/etc/wireguard/$1"'.conf')
else
	netd="${netd#*:}"
	netd="${netd//$'\t'/}"
	netd="${netd// /}"
	netd="${netd//,/$'\n'}"$'\n'
	while IFS= read -r x || [[ -n $x ]]; do
		x="${x#*inet }"
		netd="$netd${x%% *}"$'\n'
	done < <(ip address show dev $1|grep -w inet)
fi
netd="${netd//$'\n'$'\n'/$'\n'}"
#get all current nets
nets=''
while IFS= read -r x || [[ -n $x ]]; do
	x="${x//$'\t'/ }"
	while [[ $x == *"  "* ]]; do
		x="${x//  / }"
	done
	x="${x#* }"
	x="${x#* }"
	nets="$nets${x// /$'\n'}"$'\n'
done < <(ip -4 -brief address show|grep -v "$1")
nets="${nets//$'\n'$'\n'/$'\n'}"
#check if any specified wireguard networks have overlap with existing networks, find and create new network redirect without overlap
while IFS= read -r x || [[ -n $x ]]; do
    [[ "$x" = 0.0.0.0/* ]] && continue 1
	z="$x"
    while IFS= read -r y || [[ -n $y ]]; do
		while inntwrk "${z%%/*}" "$y" || inntwrk "${y%%/*}" "$z"; do
			z="$(getnextnetwork $z)"
		done
		if [ "$z" != "$x" ]; then
			ip route show|grep -q "$x dev $1" && ip route del "$x" dev "$1"
			break 1
		fi
    done < <(printf '%s' "$nets")
    [ "$z" = "$x" ] && continue 1
    iptables -t nat -I OUTPUT -o "$1" -d "$z" -j NETMAP --to "$x"
    ip route show|grep -q "$z dev $1" || ip route add "$z" dev "$1"
    echo "$z"'>'"$x" >> "/etc/wireguard/redirects-$1"
done < <(printf '%s' "$netd")
[ -f "/etc/wireguard/redirects-$1" ] && echo -e "Network overlaps detected! Use newly created network translations under /etc/wireguard/redirects-$1 instead!\n\n/etc/wireguard/redirects-$1:\n" && cat "/etc/wireguard/redirects-$1"
