#!/bin/bash

# Copyright © 2022 Ilgiz Mamyshev https://github.com/IlgizMamyshev
# This file is free software; as a special exception the author gives
# unlimited permission to copy and/or distribute it, with or without
# modifications, as long as this notice is preserved.
#
# Thanks for the help Nikolay Mishchenko https://github.com/NickNeoOne

### Script for multi-site Patroni clusters (version 30.05.2022)
# * Uses Patroni callback
# * VIP addresses can be from different subnets - one VIP address per subnet.
# * Microsoft DNS Server and Active Directory Domain Services needed
#
# Script Features:
# * Add VIP address to network interface if Patroni start Leader role
# * Remove VIP address from network interface if Patroni stop or switch to non-Leader role
# * Register\Update DNS A-record for PostgreSQL client access

### Installing script
# * Add VIPs to PGBouncer config (listen addresses), if needed.
# * Enable using callbacks in Patroni configuration (/etc/patroni/patroni.yml):
#postgresql:
#  callbacks:
#    on_start: /etc/patroni/dnscp.sh
#    on_stop: /etc/patroni/dnscp.sh
#    on_role_change: /etc/patroni/dnscp.sh
# * Put script to "/etc/patroni/dnscp.sh" and set executable (adds the execute permission for all users to the existing permissions.):
#   sudo mv /home/user/scripts/dnscp.sh /etc/patroni/dnscp.sh && sudo chmod ugo+x /etc/patroni/dnscp.sh
# * Test run:
#   sudo /etc/patroni/dnscp.sh on_role_change master patroniclustername

### Operation System prerequisites
# * Astra Linux OS (or compatible)

### PostgreSQL prerequisites
# For any virtual IP based solutions to work in general with Postgres you need to make sure that it is configured to automatically scan and bind to all found network interfaces. So something like * or 0.0.0.0 (IPv4 only) is needed for the listen_addresses parameter to activate the automatic binding. This again might not be suitable for all use cases where security is paramount for example.
## nonlocal bind
# If you can't set listen_addresses to a wildcard address, you can explicitly specify only those adresses that you want to listen to. However, if you add the virtual IP to those addresses, PostgreSQL will fail to start when that address is not yet registered on one of the interfaces of the machine. You need to configure the kernel to allow "nonlocal bind" of IP (v4) addresses:
# * temporarily:
# sysctl -w net.ipv4.ip_nonlocal_bind=1
# * permanently:
# echo "net.ipv4.ip_nonlocal_bind = 1"  >> /etc/sysctl.conf
# sysctl -p

### DNS Name as Client Access Point prerequisites
# Scenario 1 (AD DNS ans secure DNS update):
# 	* Patroni hosts must be joined to Active Directory Domain
# 		For expample: Join Astra Linux to Active Directory https://wiki.astralinux.ru/pages/viewpage.action?pageId=27361515
#			sudo apt-get install astra-winbind
#			sudo astra-winbind -dc dc1.example.ru -u Administrator -px
# 	* Create Active Directory Computer Account (will be used as Client Access Point) in any way, for example (PowerShell, from domain joined Windows Server): New-ADComputer pgsql
# 	* Set new password for Computer Account, for example (PowerShell): Get-ADComputer pgsql | Set-ADAccountPassword -Reset -NewPassword (ConvertTo-SecureString -AsPlainText "P@ssw0rd" -Force)
# Scenario 2 (Non-secure DNS update):
#	* Microsoft DNS Server and DNS-zone with allow non-secure DNS update.
# Common:
# 	* Install nsupdate utility: sudo apt-get install dnsutils


#####################################################
# Change only this variables
#####################################################
readonly VIP1="172.16.10.111" # VIP in DataCenter 1
readonly VIP2="172.16.20.111" # VIP in DataCenter 2
readonly VCompName="pgsql" # Virtual Computer Name - Client Access Point
readonly VCompPassword="P@ssw0rd" # Blank for non-secure update or set password for Virtual Computer Name account in Active Directory
DNSzoneFQDN="" # Set AD Domain FQDN or empty (recommended for automatically detect).

#####################################################
# Other variables
#####################################################
DNSserver="" # Set FQDN or IP or empty (recommended for automatically detect). Used for register DNS name.
readonly SCRIPTNAME=$(echo $0 | awk -F"/" '{print $NF}')
readonly SCRIPTPATH=$(dirname $0)
readonly TTL=30 # DNS record TTL
readonly CB_NAME=$1
readonly ROLE=$2
readonly SCOPE=$3
readonly LOGHEADER="Patroni Callback"
MSG="[$LOGHEADER] Called: $0 <CB_NAME=$CB_NAME> <ROLE=$ROLE> <SCOPE=$SCOPE>"
echo $MSG
#logger $MSG

#####################################################
# Check prerequisites
#####################################################
##  Active Directory Domain joined? (check inf password is set and astra-winbind command exist)
REQUIRED_PKG="astra-winbind"
if [[ ! -z $VCompPassword ]] && [[ "" != "$(dpkg-query -W --showformat='${Status}\n' $REQUIRED_PKG|grep "install ok installed")" ]]; then
    JOINED_OK=$(astra-winbind -i | awk '{print $NF}')
    if [[ "succeeded" == "$JOINED_OK" ]]; then
        # detect Domain DNS zone FQDN
        if [[ "" == "$DNSzoneFQDN" ]]; then
            DNSzoneFQDN=$(astra-winbind -i | awk -F\" '{print $2}' | cut --complement --delimiter "." --fields 1)
            MSG="[$LOGHEADER] Detected DNS zone FQDN is $DNSzoneFQDN"
            echo $MSG
            #logger $MSG
        fi
    else
        MSG="[$LOGHEADER] Check prerequisites: Not joined to Active Directory Domain."
        echo $MSG
        #logger $MSG
        exit 1; # Exit with error
    fi
    # $VCompPassword is empty. Script configured for non-secure DNS update.
fi

##  package is installed?
REQUIRED_PKG="dnsutils"
PKG_OK=$(dpkg-query -W --showformat='${Status}\n' $REQUIRED_PKG|grep "install ok installed")
if [[ "" == "$PKG_OK" ]]; then
    MSG="[$LOGHEADER] Check prerequisites: No $REQUIRED_PKG."
    echo $MSG
    #logger $MSG
    #sudo apt-get --yes install $REQUIRED_PKG #Setting up $REQUIRED_PKG
    exit 1; # Exit with error
else
    # Detect DNS Server
    if [[ "" == "$DNSserver" ]]; then
        # DNSserver=$(nslookup $(hostname).$DNSzoneFQDN | awk '/Server:/{gsub(/\/.*$/, "", $2); print $2}') # This is Primary DNS on network interface
        DNSserver=$(astra-winbind -i | awk -F\" '{print $2}') # AD DS logon DC
        MSG="[$LOGHEADER] Detected DNS Server is $DNSserver"
        echo $MSG
        #logger $MSG
    fi
fi

if [[ "" == "$DNSzoneFQDN" ]] || [[ "" == "$DNSserver" ]] || [[ "" == "$VCompName" ]]; then
    MSG="[$LOGHEADER] Check prerequisites: DNS server or VCompName not set."
    echo $MSG
    #logger $MSG
    exit 1; # Exit with error
fi

readonly VCompNameFQDN=$VCompName.$DNSzoneFQDN

#####################################################
# Funtions
#####################################################
function usage() { echo "Usage: $0 <on_start|on_stop|on_role_change> <role> <scope>"; 
exit 1; }

function in_subnet {
    # Determine whether IP address is in the specified subnet.
    #
    # Args:
    #   sub: Subnet, in CIDR notation.
    #   ip: IP address to check.
    #
    # Returns:
    #   1|0
    #
    local ip ip_a mask netmask sub sub_ip rval start end

    # Define bitmask.
    local readonly BITMASK=0xFFFFFFFF

    # Set DEBUG status if not already defined in the script.
    [[ "${DEBUG}" == "" ]] && DEBUG=0

    # Read arguments.
    IFS=/ read sub mask <<< "${1}"
    IFS=. read -a sub_ip <<< "${sub}"
    IFS=. read -a ip_a <<< "${2}"

    # Calculate netmask.
    netmask=$(($BITMASK<<$((32-$mask)) & $BITMASK))

    # Determine address range.
    start=0
    for o in "${sub_ip[@]}"
    do
        start=$(($start<<8 | $o))
    done

    start=$(($start & $netmask))
    end=$(($start | ~$netmask & $BITMASK))

    # Convert IP address to 32-bit number.
    ip=0
    for o in "${ip_a[@]}"
    do
        ip=$(($ip<<8 | $o))
    done

    # Determine if IP in range.
    (( $ip >= $start )) && (( $ip <= $end )) && rval=1 || rval=0

    (( $DEBUG )) &&
        printf "ip=0x%08X; start=0x%08X; end=0x%08X; in_subnet=%u\n" $ip $start $end $rval 1>&2
    echo "${rval}"
}

#####################################################
# Network interface name
#####################################################
IFNAME=$(ip route | awk '/default/{print $5}') # or "eth0"

#####################################################
# Get network
#####################################################
NETWORK=$(ip route | awk '!/default/&&/'$IFNAME'/{print $1}')
# Get network prefix
PREFIX=$(echo $NETWORK | awk -F"/" '{print $2}')

#####################################################
# Check witch IP is in network range
#####################################################
for IP in $VIP1 $VIP2; do
	(( $(in_subnet "$NETWORK" "$IP") )) && VIP=$IP
done

if [[ -z $VIP ]]; then
	MSG="[$LOGHEADER] WARNING: No suitable VIP ($VIP1, $VIP2) for $NETWORK"
	echo $MSG
	#logger $MSG
else
	#####################################################
	# VIP
	#####################################################
	MSG="[$LOGHEADER] INFO: VIP $VIP is candidate for current network"
	echo $MSG
	#logger $MSG
	case $CB_NAME in
		on_stop )
			#####################################################
			# Remove_service_ip if exists
			#####################################################
			if [[ ! -z $(ip address | awk '/'$VIP'/{print $0}') ]]; then
				sudo ip address del $VIP/$PREFIX dev $IFNAME;
				EXITCODE=$?;
				if [[ $EXITCODE -eq 0 ]]; then
					MSG="[$LOGHEADER] Deleting VIP $VIP by Patroni $CB_NAME callback SUCCEEDED"
					echo $MSG
					#logger $MSG
				else
					MSG="[$LOGHEADER] Deleting VIP $VIP by Patroni $CB_NAME callback is FAILED with error code $EXITCODE."
					echo $MSG
					#logger $MSG
				fi
			else
				MSG="[$LOGHEADER] VIP $VIP not exist, no action required.";
				#echo $MSG
				#logger $MSG
			fi
			;;
		on_start|on_role_change )
			if [[ $ROLE == 'master' ]]; then
				#####################################################
				# Add_service_ip if not exists
				#####################################################
				if [[ -z $(ip address | awk '/'$VIP'/{print $0}') ]]; then
					sudo ip address add $VIP/$PREFIX dev $IFNAME;
					EXITCODE=$?;
					if [[ $EXITCODE -eq 0 ]]; then
						MSG="[$LOGHEADER] Adding VIP $VIP by Patroni $CB_NAME callback SUCCEEDED"
						echo $MSG
						#logger $MSG
					else
						MSG="[$LOGHEADER] Adding VIP $VIP by Patroni $CB_NAME callback is FAILED with error code $EXITCODE."
						echo $MSG
						#logger $MSG
					fi    
				else
					MSG="[$LOGHEADER] VIP $VIP already present, no action required.";
					#echo $MSG
					#logger $MSG
				fi
				
				#####################################################
				# Register DNS (set in every case)
				#####################################################
				# Prepare parameters for nsupdate (operator <<- used for use tab symbols)
				NSDATA=$(cat <<-EOF
				server $DNSserver
				zone $DNSzoneFQDN
				update delete $VCompNameFQDN A
				update add $VCompNameFQDN $TTL A $VIP
				send
				EOF
				)
				
				# Authentication by $VCompName Computer account
				echo "$VCompPassword" | kinit $VCompName$ >/dev/null && KINITEXITCODE=$?
				
				# AddOrUpdateDNSRecord
				if [[ ! -z $VCompPassword ]] && [[ $KINITEXITCODE -eq 0 ]]; then
					# Active Directory authentication under Computer Account is success
					# View received Kerberos tickets: klist
					nsupdate -g -v <(echo "$NSDATA")
					EXITCODE=$?;
					if [[ $EXITCODE -eq 0 ]]; then
						MSG="[$LOGHEADER] Registering $VCompNameFQDN on $DNSserver with secure DNS update SUCCEEDED"
						echo $MSG
						#logger $MSG
					else
						MSG="[$LOGHEADER] Registering $VCompNameFQDN on $DNSserver with secure DNS update FAILED with error code $EXITCODE"
						echo $MSG
						#logger $MSG
					fi
				else
					# Active Directory authentication is failed. Try to non-secure DNS-update.
					nsupdate -v <(echo "$NSDATA")
					EXITCODE=$?;
					if [[ $EXITCODE -eq 0 ]]; then
						MSG="[$LOGHEADER] Registering $VCompNameFQDN on $DNSserver with non-secure DNS update SUCCEEDED"
						echo $MSG
						#logger $MSG
					else
						MSG="[$LOGHEADER] Registering $VCompNameFQDN on $DNSserver with non-secure DNS update FAILED with error code $EXITCODE."
						echo $MSG
						#logger $MSG
					fi
				fi
			else
				#####################################################
				# Remove_service_ip if exists
				#####################################################
				if [[ ! -z $(ip address | awk '/'$VIP'/{print $0}') ]]; then
					sudo ip address del $VIP/$PREFIX dev $IFNAME;
					EXITCODE=$?;
					if [[ $EXITCODE -eq 0 ]]; then
						MSG="[$LOGHEADER] Deleting VIP $VIP by Patroni $CB_NAME callback SUCCEEDED"
						echo $MSG
						#logger $MSG
					else
						MSG="[$LOGHEADER] Deleting VIP $VIP by Patroni $CB_NAME callback is FAILED with error code $EXITCODE."
						echo $MSG
						#logger $MSG
					fi
				else
					MSG="[$LOGHEADER] VIP $VIP not exist, no action required.";
					#echo $MSG
					#logger $MSG
				fi
			fi
			;;
	   * )
			usage
			;;
	esac
fi
