### General Info
Installation script for Grommunio Groupware (https://www.grommunio.com) on Debian Trixie (13).

Please feel free to contribute either directly in Github or add your input [here](https://community.grommunio.com/d/2325-debian-trixie-13).

### Requirements
* enable ipv6 on your system before starting
* install git

### Usage

```
git clone https://github.com/eryx12o45/grommunio-setup.git /usr/local/share/grommunio-setup
/usr/local/share/grommunio-setup/grommunio-setup
```

* for Debian Bookworm(12) / checkout the branch named bookworm
* for Debian Bullseye(11) / checkout the branch named bullseye
  > note that this release isn't supported anymore

#### Supported Repository
If you have a valid license and want to directly install from that repository do the following steps before you run `grommunio-setup`.
```
# Fill in the username and password from your license
 USERNAME='username'
 PASSWORD='xxxxxxxx'
mkdir -vp /etc/grommunio-admin-common/license
printf '%s:%s\n' "$USERNAME" "$PASSWORD" |tee /etc/grommunio-admin-common/license/credentials.txt
```
Move the credentials.txt if you want to use the comminity release instead.
```
mv -v /etc/grommunio-admin-common/license/credentials.txt{,.bak}
```

#### Configure additional relay host
https://github.com/crpb/grommunio/tree/main/setup/postfix

#### Configure system mails
```
apt-get install postix-pcre
postconf smtp_generic_maps=pcre:/etc/postfix/generic

printf "/root(.*)/\tgrommunio@%s" "$(grommunio-admin domain query domainname|head -n1)" >> /etc/postfix/generic
# OR
printf "/root@$(postconf -h myhostname)/\tgrommunio@%s\n" "$(grommunio-admin domain query domainname|head -n1)" >> /etc/postfix/generic

printf "root:\tSERVERMAILS@SERVERMAILS.TLD\n" >> /etc/aliases
postalias /etc/aliases
postfix reload
usermod --comment "$(dnsdomainname |cut -d. -f1 |tr 'a-z' 'A-z')-GROMI-ROOT" root
```

### Known issues
* no chat
* no meet
* no files
* no archive

#### Special thanks to:
* [crpb](https://github.com/crpb) for your continuous support
* [budachst](https://github.com/budachst) for your support
