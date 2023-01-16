# DNS Connection Point for Patroni

![Banner](https://github.com/IlgizMamyshev/dnscp/blob/main/doc/dnscpBanner1600x400.png)

### Bash скрипт для поддержки DNS-имени высокодоступного PostgreSQL, основанного на Решении Patroni

DNS Connection Point for Patroni (DNSCP) - это скрипт, разработан для поддержки DNS-имени СУБД PostgreSQL, развернутой в высокодоступном кластере на основе Решения Patroni.  
DNSCP обеспечивает регистрацию DNS-записи для клиентского доступа к высокодоступной СУБД и позволяет использовать один или более виртуальных IP-адресов (VIP), соответственно принадлежащих одной или нескольким подсетям.  Эти подсети могут находиться в одном месте или на географически распределенных сайтах. Кластеры географически распределенных сайтов иногда называют растянутыми.  
Поддержка одного DNS-имени для высокодоступного сервера баз данных, размещённого в разных подсетях, обеспечивает простоту и удобство клиентского доступа. При перемещении Мастер реплики СУБД на любой другой узел такого кластера DNS-имя остаётся неизменным и разрешается в актуальный IP (VIP).  
DNSCP использует функцию обратных вызовов ([callback](https://patroni.readthedocs.io/en/latest/SETTINGS.html)) [Patroni](https://github.com/zalando/patroni).  

###### Возможности:
* Управляет VIP-адресом на сетевом интерфейсе.  
    + Добавляет виртуальный IP-адрес на сетевой интерфейс (использует ```ip addr add```), если Patroni запускается в роли Лидера (master).  
    + Удаляет виртуальный IP-адрес с сетевого интерфейса (использует ```ip addr delete```), если Patroni останавливается или переключается на роль не-Лидера.  
    + Поддерживается геораспределённый кластер (несколько VIP-адресов).  
- Управляет DNS-записью кластеризованного экземпляра PostgreSQL.  
    Регистрирует\Обновляет DNS-запись типа A для клиентского доступа к экземпляру PostgreSQL (использует ```dnsutils```), запущенному в роли Мастера (Patroni на таком узле СУБД - в роли Лидера).  
    Поддерживается аутентификация при доступе к DNS-зоне.  
    Поддерживается динамическая DNS-запись (обеспечивается автоматическая перерегистрация DNS-записи 1 раз в сутки).  

> :heavy_exclamation_mark: Пожалуйста, проведите тестирование, прежде чем использовать в производственной среде.

Данный скрипт используется в решении по организации [высокодоступного геораспределённого кластера PostgreSQL на базе Patroni с DNS точкой клиентского доступа](https://github.com/IlgizMamyshev/pgsql_cluster).

---
## Совместимость

#### Операционные Системы:
- **Debian**: 9, 10, 11
- **Astra Linux**: Common Edition (основан на Debian 9), Spetial Edition (основан на Debian 10)

#### Службы каталога:
- **Microsoft Active Directory**: :white_check_mark:
- **Astra Linux Directory**: ожидается..
- **РЕД СОФТ Samba DC**: ожидается..

## Требования
Скрипт требует привилегий root или sudo и запускается сервисом Patroni.

- **Linux (Операционная Система)**: 

Обновите операционные системы узлов кластера перед развёртыванием.

Узлы Patroni должны быть членами домена Microsoft Active Directory, если требуется аутентифицированный доступ на запись в DNS-зону.  
Поддержка домена Astra Linux Directory ([ALDPro](https://astralinux.ru/products/ald-pro)) в проработке.. и обязательно будет ;)

- **PostgreSQL**: 

Чтобы любые решения на основе виртуальных IP-адресов в целом работали с PostgreSQL, необходимо убедиться, что он настроен на автоматическое сканирование и привязку ко всем найденным сетевым интерфейсам. Например укажите ```*``` или ```0.0.0.0``` (только для IPv4) (или перечислите все потенциально возможные для этого интерфейса IPv4 адреса через запятую) в параметре ```listen_addresses``` конфигурации PostgreSQL, чтобы активировать автоматическую привязку.

Nonlocal bind.  
Если вы не можете установить ```listen_addresses``` в адрес с подстановочным знаком, вы можете явно указать только те адреса, которые вы хотите прослушивать. Однако если вы добавите виртуальный IP-адрес к этим адресам, PostgreSQL не запустится, если этот адрес ещё не зарегистрирован на одном из интерфейсов компьютера. Вам необходимо настроить ядро, чтобы разрешить "нелокальную привязку" IP-адресов (v4):
- временно:
```
sysctl -w net.ipv4.ip_nonlocal_bind=1
```
- постоянно:
```
echo "net.ipv4.ip_nonlocal_bind = 1"  >> /etc/sysctl.conf
sysctl -p
```

---

## Развёртывание (вариант)
0. Перед началом  
В данном варианте кластер Patroni уже должен быть развёрнут
###### Например, используйте следующий playbook - https://github.com/vitabaks/postgresql_cluster.git

Если вы хотите комплексное решение, которое уже включает в себя данный bash-скрипт, то вам сюда - https://github.com/IlgizMamyshev/pgsql_cluster , а инструкцию ниже воспринимайте для общего понимания работы данной подсистемы.

Узел кластера Patroni (он же узел кластера СУБД) должен быть членом домена Microsoft Active Directory, если требуется аутентифицированный доступ на запись в DNS-зону, иначе используется анонимный доступ к DNS-зоне.
###### Например: Присоединить Astra Linux к домену Active Directory https://wiki.astralinux.ru/pages/viewpage.action?pageId=27361515
```
sudo apt-get install astra-winbind
sudo astra-winbind -dc dc1.example.ru -u Administrator -px
```

1. Установить пакет nsupdate: 
```
sudo apt-get install dnsutils
```

2. Создать в Active Directory учётную запись Компьютера (если требуется аутентифицированный доступ на запись в DNS-зону), например (PowerShell):
```
New-ADComputer pgsql
```
  
Задать для учётной записи Компьютера новый пароль, например (PowerShell):
```
Get-ADComputer pgsql | Set-ADAccountPassword -Reset -NewPassword (ConvertTo-SecureString -AsPlainText "P@ssw0rd" -Force)
```
В среде домена Active Directory компьютеры-члены домена с операционной системой Windows и Windows Server регулярно меняют свой пароль учетной записи Компьютера.  
Компьютеры-члены домена с операционной системой Linux менять пароль своей учетной записи Компьютера "не умеют" и не меняют на протяжении всего времени членства в домене, поэтому вам не стоит переживать за срок истечения пароля учетной записи Компьютера.  
Рекомендуется задать сложный пароль, он будет храниться в открытом виде в файле конфигурации Patroni (/etc/patroni/patroni.yml).  
  
Если планируется испорльзование анонимного доступа на запись в DNS-зону, тогда вам нет необходимости создавать учётную запись Компьютера.  

3. Разместите файл скрипта [dnscp.sh](./dnscp.sh) в каталог "/etc/patroni" и сделайте его исполняемым (добавьте разрешения для запуска для всех пользователей, которые имеют доступ к данному файлу):
```
sudo chmod ugo+x /etc/patroni/dnscp.sh
```

4. Переменные:
- Один VIP (если все узлы кластера СУБД в одной подсети) или несколько VIP (узлы кластера СУБД в разных подсетях (разных Дата Центрах)):
   ```VIPs="172.16.10.10,172.16.20.10,172.16.30.10"``` 
VIP адреса (IPv4) в разных подсетях пишутся в одну строчку, с разделением запятой. Клиентские подключения будут выполняться на один из этих адресов (DNS-имя клиентского доступа будет разрешаться в один из этих адресов).
- Виртуальное имя Компьютера - это точка клиентского доступа, имя для A-записи в DNS-зоне:  
   ```VCompName="pgsql"```
- Пароль для учётной записи Компьютера (если создавалась):  
   ```VCompPassword="P@ssw0rd"```  
   , задайте переменную пустой ```VCompPassword=""```, если планируется использование анонимной аутентификации.
- Полное доменное имя (FQDN) DNS-зоны:  
   ```DNSzoneFQDN=""```  
Для домена Microsoft Active Directory это FQDN домена. Оставьте переменную пустой для автоматического определения имени домена.  
- FQDN или IP-адрес сервера DNS:  
   ```DNSserver=""```  
   Этот DNS-сервер используется для регистрации A-записи в DNS-зоне.  
   Оставьте переменную пустой для автоматического определения DNS-сервера (рекомендуется).

5. Включить использование callbacks в файле конфигурации Patroni (/etc/patroni/patroni.yml):
```
postgresql:
  callbacks:
    on_start: /etc/patroni/dnscp.sh
    on_stop: /etc/patroni/dnscp.sh
    on_role_change: /etc/patroni/dnscp.sh
```

6. Тестовый запуск:
Вы можете запускать скрипт, самостоятельно вручную, в тестовых целях, имитируя запуск от Patroni следующей командой:
```
sudo /etc/patroni/dnscp.sh on_role_change master patroniclustername
```
Скрипт принимает на вход 3 параметра.  
Подробнее о работе скрипта смотрите в комментариях к коду в файле [dnscp.sh](./dnscp.sh).  
[Подробнее о Patroni callback](https://patroni.readthedocs.io/en/latest/SETTINGS.html)

---

## Лицензия
Под лицензией MIT License. Подробнее см. в файле [LICENSE](./LICENSE) .

## Автор
Илгиз Мамышев (Microsoft SQL Server, PostgreSQL DBA) \
[https://imamyshev.wordpress.com](https://imamyshev.wordpress.com/2022/05/29/dns-connection-point-for-patroni/)

## Обратная связь, отчеты об ошибках, запросы и т.п.
[Добро пожаловать](https://github.com/IlgizMamyshev/dnscp/issues)!
