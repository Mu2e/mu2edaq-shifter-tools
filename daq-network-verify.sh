#!/usr/bin/env bash
# Script to ping out a series of networks and then dump the results

# This is the list of networks to ping
ctrlnet="192.168.6.0/24"
datanet="192.168.7.0/24"
impinet="192.168.157.0/24"
networks=($ctrlnet $datanet $impinet)

# First we need to ping the networks so that they appear in the arp table
# Use nmap to ping the networks

for network in "${networks[@]}"; do
    nmap -sP "$network"
done

# Now we can dump the arp table
arp -a | sort > arp_table.txt

# Now we can dump the routing table
route -n > routing_table.txt    

# We want to filter this and also add the network name to the output
cat arp_table.txt | while read -r line; do
    for network in "${networks[@]}"; do
        if [[ "$line" == *"$network"* ]]; then
            echo "$line $network" >> filtered_arp_table.txt
        fi
    done
done

# Now list out the nodes up on each network
echo "----------------Control Network----------------"
cat arp_table.txt | grep mu2e |grep "fnal.gov" |sort

echo -e "\n\n\n"
echo "----------------Data Network----------------"
cat arp_table.txt | grep mu2e |grep data |sort

echo -e "\n\n\n"
echo "----------------IPMI Network----------------"
cat arp_table.txt | grep mu2e |grep ipmi |sort
