#!/usr/bin/env python3
import requests
import struct
import dns.resolver
import json
import time
import os
import sys

token = ""
domains = ["", "", "", ""]

def daemonize_process(target, args=()):
    if os.name == 'posix':
        pid = os.fork()
        if pid > 0:
            return
        os.setsid()
        target(*args)
        sys.exit(0)
    else:
        import subprocess
        subprocess.Popen([sys.executable, sys.argv[0]], creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)

def is_ipv4(ipinput):
    octets = ipinput.split('.')
    if len(octets) != 4:
        return False
    for octet in octets:
        if not octet.isdigit() or (octet != "0" and octet.startswith("0")):
            return False
        octet = int(octet)
        if octet < 0 or octet > 255:
            return False
    return True

def dnsgetip(dnsreq, dnsserver):
    try:
        dnsans = dns.resolver.Resolver(configure=False)
        dnsans.nameservers = [dnsserver]
        answers = dnsans.resolve(dnsreq, 'A')
        return answers[0].to_text()
    except dns.exception.DNSException:
        return ""

def getzoneid(domain, token):
    url = f"https://api.cloudflare.com/client/v4/zones?name={domain}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    params = {
        "name": domain,
        "status": "active"
    }
    response = requests.get(url, headers=headers, params=params)
    if response.status_code == 200:
        zones = response.json().get("result", [])
        if zones:
            return zones[0]["id"]
        else:
            return ""
    else:
        return ""

def getdomainid(domain, recordtype, zoneid, token):
    url = f"https://api.cloudflare.com/client/v4/zones/{zoneid}/dns_records"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    params = {
        "type": recordtype,
        "name": domain
    }
    response = requests.get(url, headers=headers, params=params)
    if response.status_code == 200:
        domains = response.json().get("result", [])
        if domains:
            return domains[0]["id"]
        else:
            return ""
    else:
        return ""

def updatednsrecord(domain, domaintype, zoneid, domainid, wanip, token):
    url = f"https://api.cloudflare.com/client/v4/zones/{zoneid}/dns_records/{domainid}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    data = {
        "type": domaintype,
        "name": domain,
        "content": wanip,
        "ttl": 1,
        "proxied": False,
    }
    response = requests.patch(url, headers=headers, data=json.dumps(data))
    if response.status_code != 200 or not response.json().get("success", False):
        return False
    return True

def checkdnsagainstwanip(domain, zoneid, domainid, token):
    opendnsserverip = ""
    while True:
        if not is_ipv4(opendnsserverip):
            for index, dnsip in enumerate(dnsserverips):
                opendnsserverip = dnsgetip("resolver1.opendns.com", dnsip)
                if is_ipv4(opendnsserverip):
                    break
        wanip = dnsgetip("myip.opendns.com", opendnsserverip)
        if not is_ipv4(wanip):
            opendnsserverip = ""
            time.sleep(10)
            continue
        domainip = dnsgetip(domain, opendnsserverip)
        if not is_ipv4(domainip):
            opendnsserverip = ""
            time.sleep(10)
            continue
        waittime = 300
        if wanip != domainip:
            print(f"domainip != wanip ({domain})")
            if not updatednsrecord(domain, "A", zoneid, domainid, wanip, token):
                waittime = 10
        time.sleep(waittime)

dnsserverips = ["1.1.1.1", "8.8.8.8", "1.2.3.4"]
zoneids = [""] * len(domains)
rootdomainids = [""] * len(domains)
wilddomainids = [""] * len(domains)

for index, domain in enumerate(domains):
    zoneids[index] = getzoneid(domain, token)
    if not zoneids[index]:
        print(f"Could not get zone ID for domain ({domain})! Check CloudFlare, will not update!")
        continue
    rootdomainids[index] = getdomainid(domain, "A", zoneids[index], token)
    if not rootdomainids[index]:
        print(f"Root domain ({domain}) domain ID could not be found! Check CloudFlare, will not update!")
    else:
        daemonize_process(checkdnsagainstwanip, args=(domain, zoneids[index], rootdomainids[index], token))
    wilddomainids[index] = getdomainid(f"*.{domain}", "A", zoneids[index], token)
    if not wilddomainids[index]:
        print(f"Wildcard for domain (*.{domain}) domain ID could not be found! Check CloudFlare, will not update!")
    else:
        daemonize_process(checkdnsagainstwanip, args=(f"*.{domain}", zoneids[index], rootdomainids[index], token))
