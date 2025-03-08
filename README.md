# Vanderwall
*nix software firewall rule generator and associated network services manager

This is a set of bash scripts that I have written that collectively can work together to form a fully featured firewall that can run on a *nix distribution assuming your distribution is safe for being exposed directly to a DIA line. Eventually this will all be migrated into a single script, and I will at that point consider writing a simple web interface to control the firewall. I will need some help at that point. UI/UX experts and people familiar with secure web deployments with a focus on portability. Specifically, I dislike almost all the FOSS and propriatary interfaces that I have worked with for firewalls. Some do pretty okay, but there are glaring faults and inconsistencies across almost all firewall softwares available.

I do not wish to create "another fork" that will be ignored for firewalls this software will stand out as it will be produced in such a way as to focus on containerization and simple Lego brick style LANs that can be easily point and click interacted with for those who don't want to learn all the nuances of firewalling or specific firewall softwares.

The lack of containerization options for software firewalls seems a huge issue to me. An example I have personally experienced is getting OpenWRT running on PVE. This process is not a straightforward task. There are certainly other ready built solutions, though many revolve around "shipping my system". For instance, Docker, which is not as latency competitive (nor as easy to manage overall).

There are some examples that approach the end user easy experience Lego brick style concept, but none seem fully fleshed out. This genuinely is not that difficult in my opinion, and I will document how a basic small set of network types should be able to encompass everything 99% of users need. If you need/want something special you should also be able to break away from these predetermined networks at your leisure or create a basic empty network. Instead most firewalls seem to follow awkward partially free-form network creation that don't seem to have consistency within the industry and lead to an industry where the average user is stranded by confusion and gives up rather than waste their time.

# netmap.sh
I drop this into /usr/local/bin with 755 permissions and add a line to any Wireguard .conf files I have so that any network overlaps I have are taken care of. Just make sure to check /etc/wireguard for any new network translations after any up/downs.

`PostUp = /usr/local/bin/netmap.sh %i`

# mkiptables.sh
This is the current "dumb" version of the script that generates iptables rules. Since Debian and other distros often have scripts to interface with the superior nftables this hasn't needed to be modified for me personally yet. I will make this compatible with both iptables and nftables and will consider some other options to include to increase the portability of the overall firewall across various distributions.

# binder9.sh
This is a simplified way to configure a DNS server to do the things you want. Since this script is able to do so much regarding DNS, it's easier to list things it does not do:

1. Have a GUI
2. Domain blocking
3. Serve authoratative only answers on LAN ints that can utilize a function similar to LANHOSTS 'all,' function

To figure out what it CAN do, read the begining of the script.

Personally, I developed this script as `bind9`/`named` can be extremely complex involving a multiple file heirarchy which this script handles far more easily. This is specifically to work in conjunction with PiHole as PiHole does not deal with recursive resolution or split horizon DNS. The trick being to configure your DHCP server to distribute your `bind9` server as the first DNS server on each network (with the second being your PiHole), configure this script's DNSWANINTS to answer only authorative names across your various networks, add a DNSLANINTS on one specific interface for "remote network" with the IP of the PiHole (E.G. '10.0.0.2/32,eth4' in DNSLANINTS), and configure PiHole to forward to `bind9`. Not to say there aren't a lot of thoughts on how these files should be laid out (I am open to suggestions).

It contains BASH array variables with descriptions. This snippet contains some examples.
```
#	WANs or interfaces to serve only authoratative responses (E.G. 'eth1' will only work with 'public,' or LANHOSTS specifically naming DNSWANINTS below) - supersedes duplicates in DNSLANINTS
DNSWANINTS=('eth2' 'wg0')

#	interface names to serve general DNS requests on (E.G. 'eth0') - superseded by duplicates in DNSWANINTS
#	prepend CIDR network for non-local (VLANs?) or limited networks routing DNS requests here (E.G. '192.168.0.0/16,eth0'), assure non-local requests arrive on the default gateway interface
#	BE ABSOLUTELY TO NOT CREATE AN OPEN RESOLVER!! DO NOT RESOLVE REQUESTS TO "THE INTERNET"!!!
DNSLANINTS=('eth0' 'eth1' 'eth3' '10.16.0.0/24,eth0' '10.15.0.0/24,eth0')

#	to force requests to be forwarded to another domain name server for a specific interface list the DNS IP here
#	this array should match DNSLANINTS, blank entries treated as default resolver type unless RESOLVERS set, overides RESOLVERS
FORWARDERS=('10.18.0.2' '' '' '1.1.1.1' '')

#	to force recursive requests out specific interfaces when received on a specific interface enter the interface name or IP here
#	this array should match DNSLANINTS, blank entries treated as default resolver type, FORWARDERS will overide this option
RESOLVERS=('' '10.17.0.2' '' '' '' 'eth2')

#	hostnames to resolve as authorative server (this includes subdomains, such subdomains could be overiden with a new hostname entry)
HOSTNAMES=('1.tld' '2.tld' '3.4.tld' '4.tld' '5.tld')

#	the IP the HOSTNAMES entry will be resolved to for requests on all interfaces listed in DNSLANINTS
#	prepending 'all,' to an entry will take a host portion of an IP (E.G. 'all,.5') and attempt to apply that host to all DNSLANINTS listed interface networks
#	prepending an interface name listed in DNSLANINTS will make only that interface redirect hostname requests to the specified IP (E.G. 'eth0,192.168.8.5')
#	prepending 'public,' to the specified IP causes "WAN" connections to respond to requests only for listed hostnames (E.G. 'public,64.63.62.61')
LANHOSTS=('10.0.0.1' 'all,.3' 'eth2,69.68.67.66' 'public,69.68.67.65' 'eth0,10.0.0.3')
```
