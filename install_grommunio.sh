#!/bin/bash

########## VARIABLES ##########
DBHOST='localhost'
DBUSER='grommunio'
DBPASSWD="$(openssl rand -base64 12)"
DBNAME='grommunio'
ADMINPASSWD="$(openssl rand -base64 12)"
[[ $- == *i* ]] && read -e -p " Enter Hostname:" -i "$HOSTNAME" DOMAINNAME
DOMAIN="${$(hostname -f):-$NAME}"
CREATE_SELF_SIGNED_SSL='true'
SSL_CERT_FILE_PATH='/etc/ssl/private/server.crt'
SSL_KEY_FILE_PATH='/etc/ssl/private/server.key'

########## INSTALL ##########
echo "## ADD GROMMUNIO APT REPO ##"
apt update
apt install -y gnupg2
wget -O - https://download.grommunio.com/RPM-GPG-KEY-grommunio | apt-key add -
echo "deb [trusted=yes] https://download.grommunio.com/community/Debian_11 Debian_11 main" > /etc/apt/sources.list.d/grommunio.list

echo "## INSTALL DEFAULT PACKAGES ##"
apt update
apt upgrade -y
echo "postfix	postfix/mailname string $DOMAIN" | debconf-set-selections
echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt install -y mariadb-server mariadb-client redis nginx postfix postfix-mysql php7.4-fpm curl fetchmail

echo "## SET HOSTNAME ##"
hostnamectl set-hostname $DOMAIN

echo "## CREATE USERS AND GROUPS ##"
useradd -r gromox
useradd -r system-user-groweb
useradd -r grommunio-web
groupadd -r grommunio

echo "## INSTALL GROMMUNIO PACKAGES ##"
apt install -y grommunio-common gromox grommunio-admin-api grommunio-admin-web system-user-groweb grommunio-web grommunio-admin-common

echo "## CREATE PHP-FPM RUN FOLDER ##"
echo "d /run/php-fpm 0755 www-data gromox - -" > /etc/tmpfiles.d/run-php-fpm.conf && systemd-tmpfiles --create

echo "## ACTIVATE PHP7.4-FPM ##"
systemctl enable --now php7.4-fpm

echo "## CREATE DB AND USER ##"
mysql -h $DBHOST -e "CREATE DATABASE IF NOT EXISTS grommunio;"
mysql -h $DBHOST -e "GRANT ALL ON $DBNAME.* TO '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASSWD';"

if [ "$CREATE_SELF_SIGNED_SSL" == "true" ]; then
  echo "## CREATE SELF-SIGNED SSL CERTIFICATE ##"
  openssl req -new -x509 -days 365 -nodes -keyout /etc/ssl/private/server.key -out /etc/ssl/private/server.crt -subj "/CN=$DOMAIN"
fi

echo "## FIX SSL FOLDER RIGHTS ##"
chmod 755 /etc/ssl/private
chmod 644 /etc/ssl/private/*

echo "## CREATE NGINX SSL CONFIG ##"
echo "ssl_certificate $SSL_CERT_FILE_PATH;" > /etc/grommunio-common/nginx/ssl_certificate.conf
echo "ssl_certificate_key $SSL_KEY_FILE_PATH;" >> /etc/grommunio-common/nginx/ssl_certificate.conf

echo "## REMOVE DEFAULT NGINX HOST ##"
rm -f /etc/nginx/sites-enabled/default

echo "## CREATE GROMOX DB CONFIG ##"
echo "mysql_username=$DBUSER" > /etc/gromox/mysql_adaptor.cfg
echo "mysql_password=$DBPASSWD" >> /etc/gromox/mysql_adaptor.cfg
echo "mysql_dbname=$DBNAME" >> /etc/gromox/mysql_adaptor.cfg
echo "schema_upgrade=host:$DBHOST" >> /etc/gromox/mysql_adaptor.cfg

echo "## CREATE GROMOX TABLES ##"
gromox-dbop -C

echo "## ACTIVATE GROMOX EVENT AND TIMER ##"
systemctl enable --now gromox-event gromox-timer

echo "## CREATE GROMOX HTTP CONFIG ##"
echo "listen_port=$GROMOX_HTTP_PORT" > /etc/gromox/http.cfg
echo "listen_ssl_port=$GROMOX_HTTP_SSL_PORT" >> /etc/gromox/http.cfg
echo "http_support_ssl=yes" >> /etc/gromox/http.cfg
echo "http_certificate_path=$SSL_CERT_FILE_PATH" >> /etc/gromox/http.cfg
echo "http_private_key_path=$SSL_KEY_FILE_PATH" >> /etc/gromox/http.cfg

echo "## CREATE GROMOX AUTODISCOVER CONFIG ##"
echo "[database]" > /etc/gromox/autodiscover.cfg
echo "host=$DBHOST" >> /etc/gromox/autodiscover.cfg
echo "username=$DBUSER" >> /etc/gromox/autodiscover.cfg
echo "password=$DBPASSWD" >> /etc/gromox/autodiscover.cfg
echo "dbname=$DBNAME" >> /etc/gromox/autodiscover.cfg
echo "hostname=$DOMAIN" >> /etc/gromox/autodiscover.cfg

echo "## ACTIVATE GROMOX HTTP SERVICE ##"
systemctl enable --now gromox-http

echo "## ACTIVATE GROMOX MIDB AND ZCORE ##"
systemctl enable --now gromox-midb gromox-zcore

echo "## CONFIGURE GROMOX IMAP ##"
echo "listen_ssl_port=993" > /etc/gromox/imap.cfg
echo "imap_support_starttls=true" >> /etc/gromox/imap.cfg
echo "imap_certificate_path=$SSL_CERT_FILE_PATH" >> /etc/gromox/imap.cfg
echo "imap_private_key_path=$SSL_KEY_FILE_PATH" >> /etc/gromox/imap.cfg
echo "imap_force_starttls=true" >> /etc/gromox/imap.cfg

echo "## CONFIGURE GROMOX POP3 ##"
echo "listen_ssl_port=995" > /etc/gromox/pop3.cfg
echo "pop3_support_stls=true" >> /etc/gromox/pop3.cfg
echo "pop3_certificate_path=$SSL_CERT_FILE_PATH" >> /etc/gromox/pop3.cfg
echo "pop3_private_key_path=$SSL_KEY_FILE_PATH" >> /etc/gromox/pop3.cfg
echo "pop3_force_stls=true" >> /etc/gromox/pop3.cfg

#echo "## ACTIVATE GROMOX IMAP AND POP3 ##"
# systemctl enable --now gromox-imap gromox-pop3

echo "## CONFIGURE GROMMUNIO ADMIN API ##"
echo "DB:" > /etc/grommunio-admin-api/conf.d/database.yaml
echo "  host: '$DBHOST'" >> /etc/grommunio-admin-api/conf.d/database.yaml
echo "  user: '$DBUSER'" >> /etc/grommunio-admin-api/conf.d/database.yaml
echo "  pass: '$DBPASSWD'" >> /etc/grommunio-admin-api/conf.d/database.yaml
echo "  database: '$DBNAME'" >> /etc/grommunio-admin-api/conf.d/database.yaml

echo "## SET GROMMUNIO ADMIN PASSWORD ##"
grommunio-admin passwd -p $ADMINPASSWD

echo "## SET CORRECT FOLDER RIGHTS FOR GROMMUNIO ADMIN API ##"
chown root:gromox /etc/gromox
chmod 755 /etc/gromox
chmod 666 /etc/gromox/*

echo "## ACTIVATE GROMMUNIO ADMIN API ##"
systemctl enable --now grommunio-admin-api

echo "## LINK NGINX SSL CONFIG FOR GROMMUNIO ADMIN ##"
if [ ! -f /etc/grommunio-admin-common/nginx-ssl.conf ]; then
  ln -s /etc/grommunio-common/nginx/ssl_certificate.conf /etc/grommunio-admin-common/nginx-ssl.conf
fi

echo "## RELOAD NGINX ##"
systemctl reload nginx

echo "## STOP POSTFIX AND ENABLE GROMOX DELIVERY AND DELIVERY QUEUE ##"
systemctl stop postfix
systemctl enable --now gromox-delivery gromox-delivery-queue

echo "## CONFIGURE GROMOX DELIVERY QUEUE ##"
echo "listen_port = 24" > /etc/gromox/smtp.cfg

echo "## CONFIGURE POSTFIX ##"
postconf -e virtual_alias_maps=mysql:/etc/postfix/g-alias.cf
postconf -e virtual_mailbox_domains=mysql:/etc/postfix/g-virt.cf
postconf -e virtual_transport="smtp:[localhost]:24"

echo "## CREATE GROMOX POSTFIX CONFIGS ##"
echo "user = $DBUSER" > /etc/postfix/g-alias.cf
echo "password = $DBPASSWD" >> /etc/postfix/g-alias.cf
echo "hosts = $DBHOST" >> /etc/postfix/g-alias.cf
echo "dbname = $DBNAME" >> /etc/postfix/g-alias.cf
echo "query = SELECT mainname FROM aliases WHERE aliasname='%s'" >> /etc/postfix/g-alias.cf

echo "user = $DBUSER" > /etc/postfix/g-virt.cf
echo "password = $DBPASSWD" >> /etc/postfix/g-virt.cf
echo "hosts = $DBHOST" >> /etc/postfix/g-virt.cf
echo "dbname = $DBNAME" >> /etc/postfix/g-virt.cf
echo "query = SELECT 1 FROM domains WHERE domain_status=0 AND domainname='%s'" >> /etc/postfix/g-virt.cf

echo "## ACTIVATE AND RESTART POSTFIX AND GROMOX DELIVERY AND GROMOX DELIVERY QUEUE ##"
systemctl enable --now gromox-delivery gromox-delivery-queue postfix
systemctl restart gromox-delivery-queue postfix

echo "## CONFIGURE AND ENABLE REDIS ##"
mkdir -p /var/lib/redis/default
chown redis.redis -R /var/lib/redis
systemctl disable --now redis-server.service

echo "[Unit]" > /etc/systemd/system/redis@grommunio.service
echo "Description=Redis instance: %i" >> /etc/systemd/system/redis@grommunio.service
echo "After=network.target" >> /etc/systemd/system/redis@grommunio.service
echo "PartOf=redis.target" >> /etc/systemd/system/redis@grommunio.service
echo "" >> /etc/systemd/system/redis@grommunio.service
echo "[Service]" >> /etc/systemd/system/redis@grommunio.service
echo "Type=notify" >> /etc/systemd/system/redis@grommunio.service
echo "User=redis" >> /etc/systemd/system/redis@grommunio.service
echo "Group=redis" >> /etc/systemd/system/redis@grommunio.service
echo "PrivateTmp=true" >> /etc/systemd/system/redis@grommunio.service
echo "PIDFile=/run/redis/%i.pid" >> /etc/systemd/system/redis@grommunio.service
echo "ExecStart=/usr/bin/redis-server /etc/redis/%i.conf" >> /etc/systemd/system/redis@grommunio.service
echo "LimitNOFILE=10240" >> /etc/systemd/system/redis@grommunio.service
echo "Restart=on-failure" >> /etc/systemd/system/redis@grommunio.service
echo "" >> /etc/systemd/system/redis@grommunio.service
echo "[Install]" >> /etc/systemd/system/redis@grommunio.service
echo "WantedBy=multi-user.target redis.target" >> /etc/systemd/system/redis@grommunio.service

systemctl daemon-reload
systemctl enable --now redis@grommunio.service
