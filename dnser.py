#!/usr/bin/env python3
import os
import sys
import json
import time
import string
import requests
import dns.resolver

token = ""
domains = ["", "", ""]
recordtypes = ["", "", ""]
contents = ["", "", ""]
continuous = ["", "", ""]

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

def dnsgetrecord(record, type, dnsserver):
    try:
        dnsans = dns.resolver.Resolver(configure=False)
        dnsans.nameservers = [dnsserver]
        answers = dnsans.resolve(record, type)
        return answers[0].to_text()
    except dns.exception.DNSException:
        return ""

def getipof(domainrequest, dnsserverips):
    if not dnsserverips:
        print(f"Function getipof not passed DNS server IPs ({dnsserverips})!")
    returnip = ''
    while True:
        for dnsserverip in dnsserverips:
            if not is_ipv4(dnsserverip):
                print(f"Function getipof passed bad DNS server IP ({dnsserverip})!")
                continue
            returnip = dnsgetrecord(domainrequest, 'A', dnsserverip)
            if is_ipv4(returnip):
                break
            else:
                returnip = ''
        if not returnip:
            time.sleep(10)
        else:
            break
    return returnip

def getwanip(dnsserverips):
    if not dnsserverips:
        print(f"Function getwanip not passed DNS server IPs ({dnsserverips})!")
    returnip = ''
    while True:
        for dnsserverip in dnsserverips:
            if not is_ipv4(dnsserverip):
                print(f"Function getwanip passed bad DNS server IP ({dnsserverip})!")
                continue
            opendnsserverip = dnsgetrecord("resolver1.opendns.com", 'A', dnsserverip)
            if not is_ipv4(opendnsserverip):
                continue
            returnip = dnsgetrecord("myip.opendns.com", 'A', opendnsserverip)
            if is_ipv4(returnip):
                break
            else:
                returnip = ''
        if not returnip:
            time.sleep(10)
        else:
            break
    return returnip

def getzoneid(token, domain):
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

def getdomainid(token, zoneid, domain, recordtype):
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

def updatednsrecord(token, zoneid, domainid, domain, recordtype, content):
    url = f"https://api.cloudflare.com/client/v4/zones/{zoneid}/dns_records/{domainid}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    data = {
        "type": recordtype,
        "name": domain,
        "content": content,
        "ttl": 1,
        "proxied": False,
    }
    response = requests.patch(url, headers=headers, data=json.dumps(data))
    if response.status_code != 200 or not response.json().get("success", False):
        return False
    return True

def verify_and_update_dns(token, zoneid, domainid, domain, recordtype, content='', runloop=False):
    if any(x in (None, "") for x in (token, zoneid, domainid, domain, recordtype)):
        print(f"Function \'verify_and_update_dns\' was called improperly ({token}, {zoneid}, {domainid}, {domain}, {recordtype})!")
        return False
    if runloop:
        runonce = False
    else
        runonce = True
    if recordtype.lower() == 'a':
        if not content:
            while runloop or runonce:
                wanip = getwanip(dnsserverips)
                domainip = getipof(domain, dnsserverips)
                if wanip == domainip:
                    waittime = 300
                else:
                    print(f"Domain ({domain}) IP ({domainip}) is not WAN IP ({wanip})! Updating!")
                    while not updatednsrecord(token, zoneid, domainid, domain, recordtype, wanip):
                        waittime = 10
                if runonce:
                    return True
                time.sleep(waittime)
        elif is_ipv4(content):
            while runloop or runonce:
                domainip = getipof(domain, dnsserverips)
                if content == domainip:
                    waittime = 300
                else:
                    print(f"Domain ({domain}) IP ({domainip}) is not requested content ({content})! Updating!")
                    while not updatednsrecord(token, zoneid, domainid, domain, recordtype, content):
                        waittime = 10
                if runonce:
                    return True
                time.sleep(waittime)
        else:
            print(f"Function \'verify_and_update_dns\' provided \'A\' recordtype and bad IP ({content}! Can not continue!")
            return False
    elif recordtype.lower() == 'txt':
        content = content.replace('"', r'\"')
        if len(content) > 255 or not all(char in string.printable for char in content):
            print(f"Function \'verify_and_update_dns\' provided \'TXT\' recordtype and bad content ({content})! Quotes are escaped, verify length! String must conform to ASCII characters with total length less than 255 characters! Can not continue!")
            return False
        while runloop or runonce:
            domainstring = dnsgetrecord(domain, 'TXT', dnsserverips)
            if content == domainstring:
                waittime = 300
            else:
                print(f"Domain ({domain}) string ({domainstring}) is not requested content ({content})! Updating!")
                while not updatednsrecord(token, zoneid, domainid, domain, recordtype, domainstring):
                    waittime = 10
            if runonce:
                return True
            time.sleep(waittime)
    else:
        print(f"Function \'verify_and_update_dns\' provided bad record type ({recordtype})! Must be \'A\' or \'TXT\'! Can not continue!")
        return False

def main()
    if sys.argv[0]:
        del token, domains, recordtypes, contents, continuous
        if sys.argv[0] == '-c':
            indexstart = 2
        else:
            indexstart = 1
        for arguement in sys.argv[indexstart:]:
            if not token:
                token = arguement
            elif not domains[0]:
                domains[0] = arguement
            elif not recordtypes[0]:
                if arguement.lower() == 'none':
                    recordtypes[0] = ''
                else:
                    recordtypes[0] = arguement
            elif not contents[0]:
                contents[0] = arguement
            elif not continuous[0]:
                continuous[0] = arguement
                break
    if not token:
        print("No token provided! Can not continue!")
        sys.exit()
    dnsserverips = ["1.1.1.1", "8.8.8.8", "1.2.3.4"]
    zoneids = [""] * len(domains)
    domainids = [""] * len(domains)
    emptyrecords = [""] * len(domains)
    wilddomainids = [""] * len(domains)
    for index, domain in enumerate(domains):
        if continuous[index]:
            continuous[index] = True
        else:
            continuous[index] = False
        if not recordtypes[index]:
            recordtypes[index] = 'A'
            emptyrecords[index] = True
        else:
            emptyrecords[index] = False
        zoneids[index] = getzoneid(domain, token)
        if not zoneids[index]:
            print(f"Could not get zone ID for domain ({domain})! Check CloudFlare to ensure record exists, will not update!")
            continue
        domainids[index] = getdomainid(token, zoneids[index], domain, recordtypes[index])
        if not domainids[index]:
            print(f"Domain ({domain}) domain ID could not be found! Check CloudFlare to ensure record exists, will not update!")
        elif continuous[index]:
            daemonize_process(verify_and_update_dns, args=(token, zoneids[index], domainids[index], domain, recordtypes[index], contents[index], continuous[index]))
        elif verify_and_update_dns(token, zoneids[index], domainids[index], domain, recordtypes[index], contents[index], continuous[index])):
            print(f"Updated domain ({domain}) successfully!")
        if emptyrecords[index]:
            wilddomainids[index] = getdomainid(token, zoneids[index], f"*.{domain}", recordtypes[index])
            if not wilddomainids[index]:
                print(f"Wildcard for domain (*.{domain}) domain ID could not be found! Check CloudFlare to ensure record exists, will not update!")
            elif continuous[index]:
                daemonize_process(verify_and_update_dns, args=(token, zoneids[index], wilddomainids[index], domain, recordtypes[index], contents[index], continuous[index]))
            elif verify_and_update_dns(token, zoneids[index], wilddomainids[index], domain, recordtypes[index], contents[index], continuous[index])):
                print(f"Updated wildcard for domain (*.{domain}) successfully!")
