### General Info
Installation script for Grommunio Groupware (https://www.grommunio.com) on Debian 11.

Please feel free to contribute either directly in Github or add your input [here](https://community.grommunio.com/d/447-debian-11-clean-install-script).

Also containing a test-wise grommunio-antispam Debian 11 package.

### Requirements
* enable ipv6 on your system before starting
* install git

### Usage
```
git clone https://github.com/eryx12o45/grommunio-setup.git /usr/local/share/grommunio-setup
/usr/local/share/grommunio-setup/grommunio-setup
```

* iptables rules will be configured and persistent, enabling will require a reboot!

### Additions
#### Install grommunio-index
```
mkdir /root/rpmconv
cd /root/rpmconv
apt-get install -y alien
wget https://download.grommunio.com/community/openSUSE_Leap_15.3/grommunio-index-0.1.11.8787c3c-lp153.17.1.x86_64.rpm
alien grommunio-index-0.1.11.8787c3c-lp153.17.1.x86_64.rpm
dpkg -i grommunio-index_0.1.11.8787c3c-1_amd64.deb
systemctl enable --now grommunio-index.service
systemctl enable --now grommunio-index.timer
grommunio-index-run.sh
```

#### Use OCSP for ACME-CERT
https://github.com/crpb/grommunio/blob/main/setup/nginx-ocsp.sh

#### Configure additional relay host
https://github.com/crpb/grommunio/tree/main/setup/postfix

#### Configure system mails
```
apt-get install postix-pcre
postconf smtp_generic_maps=pcre:/etc/postfix/generic
printf "/root(.*)/\tgromi@%s\n" "$(grommunio-admin domain query --filter ID=1 domainname)" >> /etc/postfix/generic
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
