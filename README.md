# DNS Connection Point (for Patroni)

![GitHub stars](https://img.shields.io/github/stars/IlgizMamyshev/dnscp)

---

### Bash script for multi-site PostgreSQL High-Availability Cluster based on Patroni

This script designed for deploying a PostgreSQL high availability cluster on dedicated servers for a production environment.
The script provides registration of the DNS entry and allows the use of one, two or more virtual addresses located in different networks.
The script uses the Patroni (https://github.com/zalando/patroni) callback (https://patroni.readthedocs.io/en/latest/SETTINGS.html) function.

###### Script features:
- Add VIP address to network interface if Patroni start Leader role
- Remove VIP address from network interface if Patroni stop or switch to non-Leader role
- Register\Update DNS A-record for PostgreSQL client access

> :heavy_exclamation_mark: Please test it in your test enviroment before using in a production.

---
## Compatibility
Debian based distros (x86_64)

###### Supported Linux Distributions:
- **Debian**: 9, 10, 11
- **Astra Linux**: CE, SE

:white_check_mark: tested, works fine: `Astra Linux CE 2.12, Astra Linux SE 1.7`

## Requirements
This script requires root privileges or sudo and run by Patroni service.

- **Linux (Operation System)**: 

Update your operating system on your target servers before deploying;

Patroni hosts must be joined to Active Directory Domain, if DNS authentication required.

- **PostgreSQL**: 

For any virtual IP based solutions to work in general with Postgres you need to make sure that it is configured to automatically scan and bind to all found network interfaces. So something like * or 0.0.0.0 (IPv4 only) is needed for the listen_addresses parameter to activate the automatic binding. This again might not be suitable for all use cases where security is paramount for example.

Nonlocal bind.  
If you can't set listen_addresses to a wildcard address, you can explicitly specify only those adresses that you want to listen to. However, if you add the virtual IP to those addresses, PostgreSQL will fail to start when that address is not yet registered on one of the interfaces of the machine. You need to configure the kernel to allow "nonlocal bind" of IP (v4) addresses:
- temporarily:
```
sysctl -w net.ipv4.ip_nonlocal_bind=1
```
- permanently:
```
echo "net.ipv4.ip_nonlocal_bind = 1"  >> /etc/sysctl.conf
sysctl -p
```

---

## Deployment: quick start
0. Before
Patroni cluster must be deployed
###### For example use this playbook https://github.com/vitabaks/postgresql_cluster.git

Patroni hosts must be joined to Active Directory Domain, if DNS authentication required, otherwise, anonymous access to the DNS server is used.
###### Example: Join Astra Linux to Active Directory https://wiki.astralinux.ru/pages/viewpage.action?pageId=27361515
```
sudo apt-get install astra-winbind
sudo astra-winbind -dc dc1.example.ru -u Administrator -px
```

1. Install nsupdate package: 
```
sudo apt-get install dnsutils
```

2. Install\check astra-winbind package: 
```
sudo apt-get install astra-winbind
```

3. Create Active Directory Computer Account (if authentication on DNS server required)
Create Active Directory Computer Account, for example (PowerShell):
```
New-ADComputer pgsql
```
  
Set new password for Computer Account, for example (PowerShell):
```
Get-ADComputer pgsql | Set-ADAccountPassword -Reset -NewPassword (ConvertTo-SecureString -AsPlainText "P@ssw0rd" -Force)
```
  
If anonymous authentication is used to access the DNS server, there is no need to create a computer account.

4. Put script to "/etc/patroni/dnscp.sh" and set executable (adds the execute permission for all users to the existing permissions):
```
sudo chmod ugo+x /etc/patroni/dnscp.sh
```

5. Variables
- VIP in DataCenter 1:
```VIP1="172.16.10.111"``` 
- VIP in DataCenter 2:
```VIP2="172.16.20.111"``` 
- Virtual Computer Name - Client Access Point:  
```VCompName="pgsql"```
- Virtual Computer Name account in Active Directory:  
   for authenticated access on the DNS server:  
   ```VCompPassword="P@ssw0rd"```  
   for anonimous access on the DNS server:  
   ```VCompPassword=""```
- AD Domain FQDN (empty is recommended for automatically detect):  
```DNSzoneFQDN=""```
- DNS Server FQDN or IP (empty is recommended for automatically detect) (used for register DNS name):  
```DNSserver=""```

See the [dnscp.sh](./dnscp.sh) file for more details.

6. Enable using callbacks in Patroni configuration (/etc/patroni/patroni.yml):
```
postgresql:
  callbacks:
    on_start: /etc/patroni/dnscp.sh
    on_stop: /etc/patroni/dnscp.sh
    on_role_change: /etc/patroni/dnscp.sh
```

7. Test run:
```
sudo /etc/patroni/dnscp.sh on_role_change master patroniclustername
```

---

## License
Licensed under the MIT License. See the [LICENSE](./LICENSE) file for details.

## Author
Ilgiz Mamyshev (Microsoft SQL Server, PostgreSQL DBA) \
https://imamyshev.wordpress.com

## Feedback, bug-reports, requests, ...
Are [welcome](https://github.com/IlgizMamyshev/dnscp/issues)!
