#!/bin/bash

# Copyright © 2022 Ilgiz Mamyshev https://github.com/IlgizMamyshev
# This file is free software; as a special exception the author gives
# unlimited permission to copy and/or distribute it, with or without
# modifications, as long as this notice is preserved.

### v14012023
# https://github.com/IlgizMamyshev/dnscp

### Script for Patroni clusters
# Script Features:
# * Add VIP address to network interface if Patroni start Leader role
# * Remove VIP address from network interface if Patroni stop or switch to non-Leader role
# * Register\Update DNS A-record for PostgreSQL client access

### Installing script
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
#   sudo /etc/patroni/dnscp.sh on_schedule registerdns patroniclustername

### Operation System prerequisites
# * Astra Linux (Debian or compatible)

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
#   * Patroni hosts must be joined to Active Directory Domain
#       For expample: Join Astra Linux to Active Directory https://wiki.astralinux.ru/pages/viewpage.action?pageId=27361515
#           sudo apt-get install astra-winbind && sudo astra-winbind -dc dc1.example.ru -u Administrator -px
#   * Create Active Directory Computer Account (will be used as Client Access Point) in any way, for example (PowerShell, from domain joined Windows Server): New-ADComputer pgsql
#   * Set new password for Computer Account, for example (PowerShell): Get-ADComputer pgsql | Set-ADAccountPassword -Reset -NewPassword (ConvertTo-SecureString -AsPlainText "P@ssw0rd" -Force)
# Scenario 2 (Non-secure DNS update):
#   * Microsoft DNS Server and DNS-zone with allow non-secure DNS update.
# Common:
#   * Install nsupdate utility: sudo apt-get install dnsutils

#####################################################
# Change only this variables
#####################################################
readonly VIPs="10.10.0.10" # VIP addresses (IPv4) in different subnets separated by commas, for client access to databases in the cluster
readonly VCompName="pgsql" # Virtual Computer Name - Client Access Point
readonly VCompPassword="P@ssw0rd" # Blank for non-secure update or set password for Virtual Computer Name account in Active Directory\SAMBA
DNSzoneFQDN="demo.ru" # Set DNS zone FQDN (for example Microsoft AD DS Domain FQDN). Empty for automatically detect.

#####################################################
# Other variables
#####################################################
DNSserver="" # Set FQDN or IP or empty (recommended for automatically detect). Used for register DNS name.
readonly SCRIPTNAME=$(echo $0 | awk -F"/" '{print $NF}')
readonly SCRIPTPATH=$(dirname $0)
readonly TTL=1200 # DNS record TTL in seconds. TTL=1200 - default. TTL=30 - recommended for multi-site clusters.
readonly CB_NAME=$1
readonly ROLE=$2
readonly SCOPE=$3
readonly LOGHEADER="Patroni Callback"
MSG="[$LOGHEADER] Called: $0 <CB_NAME=$CB_NAME> <ROLE=$ROLE> <SCOPE=$SCOPE>"
echo $MSG

#####################################################
# Check prerequisites
#####################################################
## VIPs defined?
if [[ "" == "$VIPs" ]]; then
    MSG="[$LOGHEADER] INFO: Check prerequisites: VIPs not defined. Nothing to do."
    echo $MSG
    exit 0; # Exit without error
fi

## Active Directory\SAMBA Domain joined?
JOINED_OK=""
if [[ ! -z $VCompPassword ]]; then
    JOINED_OK=$(sudo net ads testjoin | awk '{print $NF}')
    if [[ "OK" == "$JOINED_OK" ]]; then
        # Detect DNS zone FQDN
        if [[ "" == "$DNSzoneFQDN" ]]; then
            DNSzoneFQDN=$(sudo net ads info | awk -F": " '{if ($1 == "Realm") print $2}')
            #MSG="[$LOGHEADER] INFO: Detected DNS zone FQDN is $DNSzoneFQDN"
            #echo $MSG
        fi
    else
        MSG="[$LOGHEADER] WARNING: Check prerequisites: Not joined to Active Directory\SAMBA Domain!"
        echo $MSG
    fi
    # $VCompPassword is empty. Script configured for non-secure DNS update.
fi

## package is installed?
REQUIRED_PKG="dnsutils"
PKG_OK=$(dpkg-query -W --showformat='${Status}\n' $REQUIRED_PKG|grep "install ok installed")
if [[ "" == "$PKG_OK" ]]; then
    MSG="[$LOGHEADER] WARNING: Check prerequisites: No $REQUIRED_PKG."
    echo $MSG
    #sudo apt-get --yes install $REQUIRED_PKG #Setting up $REQUIRED_PKG
    exit 1; # Exit with error
else
    # Detect DNS Server
    if [[ "" == "$DNSserver" ]] && [[ "OK" == "$JOINED_OK" ]]; then
        DNSserver=$(sudo net ads info | awk -F": " '{if ($1 == "LDAP server name") print $2}') # AD DS logon DC
        #MSG="[$LOGHEADER] INFO: Detected DNS Server is $DNSserver"
        #echo $MSG
    fi
fi

# Set failsafe value
if [[ "" == "$DNSserver" ]] && [[ "" != "$DNSzoneFQDN" ]]; then
    DNSserver=$DNSzoneFQDN
fi

# Last check
if [[ "" == "$DNSzoneFQDN" ]] || [[ "" == "$DNSserver" ]] || [[ "" == "$VCompName" ]]; then
    MSG=""; MSGSEPARATOR="";
    if [[ "" == "$DNSzoneFQDN" ]]; then MSG="$MSG${MSGSEPARATOR}DNSzoneFQDN"; MSGSEPARATOR=", "; fi
    if [[ "" == "$DNSserver" ]]; then MSG="$MSG${MSGSEPARATOR}DNSserver"; MSGSEPARATOR=", "; fi
    if [[ "" == "$VCompName" ]]; then MSG="$MSG${MSGSEPARATOR}$MSGVCompName"; MSGSEPARATOR=", "; fi
    MSG="[$LOGHEADER] INFO: DNSCP does not know about $MSG. Only VIPs wil be managed."
    echo $MSG
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
IFNAME=$(ip --oneline addr show | awk '$3 == "inet" && $2 != "lo" { print $2; exit}') # or "eth0"

#####################################################
# Get network
#####################################################
NETWORK=$(ip --oneline addr show | awk '$3 == "inet" && $2 != "lo" { print $4; exit}') # 123.123.123.123/24
# Get network prefix
PREFIX=$(echo $NETWORK | awk -F"/" '{print $2}')

#####################################################
# Check witch IP is in network range
#####################################################
for IP in $(echo $VIPs | awk '{gsub(","," "); print $0}'); do
    (( $(in_subnet "$NETWORK" "$IP") )) && VIP=$IP
done

if [[ -z $VIP ]]; then
    MSG="[$LOGHEADER] WARNING: No suitable VIP ($VIPs) for $NETWORK"
    echo $MSG
else
    #####################################################
    # VIP
    #####################################################
    #MSG="[$LOGHEADER] INFO: VIP $VIP is candidate for current network"
    #echo $MSG
    case $CB_NAME in
        on_stop )
            #####################################################
            # Remove service_ip if exists
            #####################################################
            if [[ ! -z $(ip address | awk '/'$VIP'/{print $0}') ]]; then
                sudo ip address del $VIP/$PREFIX dev $IFNAME;
                EXITCODE=$?;
                if [[ $EXITCODE -eq 0 ]]; then
                    MSG="[$LOGHEADER] INFO: Deleting VIP '$VIP/$PREFIX dev $IFNAME' by Patroni $CB_NAME callback SUCCEEDED"
                    echo $MSG
                else
                    MSG="[$LOGHEADER] ERROR: Deleting VIP '$VIP/$PREFIX dev $IFNAME' by Patroni $CB_NAME callback is FAILED with error code $EXITCODE."
                    echo $MSG
                fi

                # Remove cron task
                sudo crontab -u $(whoami) -l | grep -v "$0" | sudo crontab -u $(whoami) -
            else
                MSG="[$LOGHEADER] INFO: VIP $VIP not exist, no action required.";
                #echo $MSG
            fi
            ;;
        on_start|on_role_change|on_schedule )
            if [[ $ROLE == 'master' ]]; then
                #####################################################
                # Add service_ip if not exists
                #####################################################
                if [[ -z $(ip address | awk '/'$VIP'/{print $0}') ]]; then
                    sudo ip address add $VIP/$PREFIX dev $IFNAME;
                    EXITCODE=$?;
                    if [[ $EXITCODE -eq 0 ]]; then
                        MSG="[$LOGHEADER] INFO: Adding VIP '$VIP/$PREFIX dev $IFNAME' by Patroni $CB_NAME callback SUCCEEDED"
                        echo $MSG
                    else
                        MSG="[$LOGHEADER] ERROR: Adding VIP '$VIP/$PREFIX dev $IFNAME' by Patroni $CB_NAME callback is FAILED with error code $EXITCODE."
                        echo $MSG
                    fi
                else
                    MSG="[$LOGHEADER] INFO: VIP $VIP already present, no action required.";
                    #echo $MSG
                fi
            fi

            if [[ $ROLE == 'replica' ]]; then
                #####################################################
                # Remove service_ip if exists
                #####################################################
                if [[ ! -z $(ip address | awk '/'$VIP'/{print $0}') ]]; then
                    sudo ip address del $VIP/$PREFIX dev $IFNAME;
                    EXITCODE=$?;
                    if [[ $EXITCODE -eq 0 ]]; then
                        MSG="[$LOGHEADER] INFO: Deleting VIP '$VIP/$PREFIX dev $IFNAME' by Patroni $CB_NAME callback SUCCEEDED"
                        echo $MSG
                    else
                        MSG="[$LOGHEADER] ERROR: Deleting VIP '$VIP/$PREFIX dev $IFNAME' by Patroni $CB_NAME callback is FAILED with error code $EXITCODE."
                        echo $MSG
                    fi

                    # Remove cron task
                    sudo crontab -u $(whoami) -l | grep -v "$0" | sudo crontab -u $(whoami) -
                else
                    MSG="[$LOGHEADER] INFO: VIP $VIP not exist, no action required.";
                    #echo $MSG
                fi
            fi

            if [[ $ROLE == 'master' ]] || ( [[ $ROLE == 'registerdns' ]] && [[ "" != "$(ip address | awk '/'$VIP'/{print $0}')" ]] ); then
            #####################################################
            # Register DNS
            #####################################################
            if [[ "" != "$DNSzoneFQDN" ]] && [[ "" != "$DNSserver" ]] && [[ "" != "$VCompName" ]]; then
                MSG="[$LOGHEADER] INFO: Detected DNS zone FQDN is $DNSzoneFQDN"
                echo $MSG
                MSG="[$LOGHEADER] INFO: Detected DNS Server is $DNSserver"
                echo $MSG

                # Authentication by $VCompName Computer account
                KINITEXITCODE=-1
                if [[ "OK" == "$JOINED_OK" ]]; then
                    echo "$VCompPassword" | kinit $VCompName$ >/dev/null && KINITEXITCODE=$?
                fi

                # AddOrUpdateDNSRecord
                if [[ ! -z $VCompPassword ]] && [[ $KINITEXITCODE -eq 0 ]]; then
                    # Active Directory\SAMBA authentication under Computer Account is success.
                    (echo "server $DNSserver"; echo "zone $DNSzoneFQDN"; echo "update delete $VCompNameFQDN A"; echo send; echo "update add $VCompNameFQDN $TTL A $VIP"; echo send) | nsupdate -g -v
                    EXITCODE=$?;
                    if [[ $EXITCODE -eq 0 ]]; then
                        MSG="[$LOGHEADER] INFO: Registering $VCompNameFQDN on $DNSserver with secure DNS update SUCCEEDED"
                        echo $MSG
                    else
                        MSG="[$LOGHEADER] ERROR: Registering $VCompNameFQDN on $DNSserver with secure DNS update FAILED with error code $EXITCODE."
                        echo $MSG
                    fi
                else
                    # Active Directory\SAMBA authentication is failed. Try to non-secure DNS-update.
                    (echo "server $DNSserver"; echo "zone $DNSzoneFQDN"; echo "update delete $VCompNameFQDN A"; echo send; echo "update add $VCompNameFQDN $TTL A $VIP"; echo send) | nsupdate -v
                    EXITCODE=$?;
                    if [[ $EXITCODE -eq 0 ]]; then
                        MSG="[$LOGHEADER] INFO: Registering $VCompNameFQDN on $DNSserver with non-secure DNS update SUCCEEDED"
                        echo $MSG
                    else
                        MSG="[$LOGHEADER] ERROR: Registering $VCompNameFQDN on $DNSserver with non-secure DNS update FAILED with error code $EXITCODE."
                        echo $MSG
                    fi
                fi
            fi

            fi
            #####################################################
            # Enable DNS Update cron task if service_ip exists
            #####################################################
            # Remove cron task
            sudo crontab -u $(whoami) -l | grep -v "$0" | sudo crontab -u $(whoami) -
            if [[ -z $(ip address | awk '/'$VIP'/{print $0}') ]]; then
                # service_ip not exists
                MSG="[$LOGHEADER] INFO: service_ip not exists."
                #echo $MSG
                MSG="[$LOGHEADER] INFO: 'Dynamic DNS Update' cron task for $(whoami) user removed."
                echo $MSG
            else
                # service_ip exists - Add cron task for Dynamic DNS Updates
                sudo crontab -u $(whoami) -l 2>/dev/null; echo "53 00 * * * sudo $0 on_schedule registerdns $VCompName" | sudo crontab -u $(whoami) -
                MSG="[$LOGHEADER] INFO: 'Dynamic DNS Update' cron task for $(whoami) user (re)enabled."
                echo $MSG
            fi
            ;;
        * )
            usage
            ;;
    esac
fi
