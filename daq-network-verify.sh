#!/usr/bin/env bash
# Script to ping out a series of networks and then dump the results

# This is the list of networks to ping
networks=(192.168.1.0/24 192.168.2.0/24)

# First we need to ping the networks so that they appear in the arp table
# Use nmap to ping the networks

for network in "${networks[@]}"; do
    nmap -sP "$network"
done

# Now we can dump the arp table
arp -a | sort > arp_table.txt

# Now we can dump the routing table
route -n > routing_table.txt    
