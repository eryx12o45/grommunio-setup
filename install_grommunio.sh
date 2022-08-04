#!/bin/bash

########## VARIABLES ##########
SSL_CERT_FILE_PATH='/etc/ssl/private/server.crt'
SSL_KEY_FILE_PATH='/etc/ssl/private/server.key'
GROMOX_HTTP_PORT=10080
GROMOX_HTTP_SSL_PORT=10443

########## VARIABLES INSTALLER QUESTIONS ##########
if [ "$UID" = "0" ]; then
  echo ""
  echo "+--------------------------------+"
  echo "| Hostname for Grommunio Server |"
  echo "+--------------------------------+"
  read -p " Subdomain Name (SUBDOMAIN.example.com) ? " SUBDOMAIN
  read -p " Domainname (subdomain.EXAMPLE.COM) ? " DOMAIN
  echo ""
  echo "+-------------------------------------------------+"
  echo "| SSL Self Signed, Let's Encrypt or other sources |"
  echo "+-------------------------------------------------+"
  read -p " self, lets, other ? [lets] " SSL
  if [ "$SSL" = "" ] || [ "$SSL" = "lets" ]; then
    SSL="lets"
    echo ""
    echo "+------------------------------------------------+"
    echo "| E-Mail Adresss for Let's Excrypt Notifications |"
    echo "+------------------------------------------------+"
    read -p " Mail-Adresss ? " MAIL
  fi
  echo ""
  echo "--------------------------------------------------"
  echo " FQDN: $SUBDOMAIN.$DOMAIN"
  echo " SSL: $SSL"
  if ! [ "$MAIL" = "" ]; then
    echo " Mail: $MAIL"
  fi
  echo "--------------------------------------------------"
  echo ""
  key=""
  while [ "$key" != "y" ] && [ "$key" != "n" ]; do
    read -n 1 -p "Correct ? [y/n]" key
  done
  if [ $key == "n" ]; then
    exit
  fi
  echo ""
  echo "+--------------------------+"
  echo "| Grommunio Admin Password |"
  echo "+--------------------------+"
  read -e -p " Enter admin password (empty for random password): " ADMINPASSWD
  if [ "$ADMINPASSWD" == "" ]; then
    ADMINPASSWD="$(openssl rand -base64 12)"
  fi
  echo ""
  echo "+-------------------------+"
  echo "| Grommunio Database Host |"
  echo "+-------------------------+"
  read -e -p " Enter database host (empty for localhost): " DBHOST
  if [ "$DBHOST" == "" ]; then
    DBHOST="localhost"
  fi
  echo ""
  echo "+-------------------------+"
  echo "| Grommunio Database User |"
  echo "+-------------------------+"
  read -e -p " Enter database user (empty for grommunio): " DBUSER
  if [ "$DBUSER" == "" ]; then
    DBUSER="grommunio"
  fi
  echo ""
  echo "+-------------------------------+"
  echo "| Grommunio Database Password |"
  echo "+-----------------------------+"
  read -e -p " Enter database password (empty for random password): " DBPASSWD
  if [ "$DBPASSWD" == "" ]; then
    DBPASSWD="$(openssl rand -base64 12)"
  fi
  echo ""
  echo "+-------------------------+"
  echo "| Grommunio Database Name |"
  echo "+-------------------------+"
  read -e -p " Enter database name (empty for grommunio): " DBNAME
  if [ "$DBNAME" == "" ]; then
    DBNAME="grommunio"
  fi
  echo ""

  ########## INSTALL ##########
  echo "## ADD GROMMUNIO APT REPO ##"
  apt update
  apt install -y gnupg2
  wget -O - https://download.grommunio.com/RPM-GPG-KEY-grommunio | apt-key add -
  echo "deb [trusted=yes] https://download.grommunio.com/community/Debian_11 Debian_11 main" >/etc/apt/sources.list.d/grommunio.list

  echo "## INSTALL DEFAULT PACKAGES ##"
  apt update
  apt upgrade -y
  echo "postfix	postfix/mailname string $DOMAIN" | debconf-set-selections
  echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt install -y mariadb-server mariadb-client redis nginx postfix postfix-mysql php php-igbinary php-redis php7.4 php7.4-fpm curl fetchmail rspamd certbot python3-certbot-nginx

  echo "## CREATE SSL ##"
  if [ "$SSL" == "lets" ]; then
    mkdir -p /etc/letsencrypt/live/$SUBDOMAIN.$DOMAIN
    echo ""
    echo " Let's Encrypt will request SSL for the following Names:"
    echo " $SUBDOMAIN.$DOMAIN + autodiscover.$DOMAIN "
    echo " Make sure the Firewall/NAT is open on Port 80 for US/CA IPs and DNS Records activ ?"
    echo ""
    echo "Continue <ENTER>"
    read
    certbot certonly --no-eff-email --agree-tos --nginx --deploy-hook "cp /etc/letsencrypt/live/$SUBDOMAIN.$DOMAIN/privkey.pem $SSL_KEY_FILE_PATH && cp /etc/letsencrypt/live/$SUBDOMAIN.$DOMAIN/fullchain.pem $SSL_CERT_FILE_PATH" -m $MAIL -d $SUBDOMAIN.$DOMAIN -d autodiscover.$DOMAIN
    while ! (test -f /etc/letsencrypt/live/$SUBDOMAIN.$DOMAIN/privkey.pem); do
      echo ""
      echo " Let's Encrypt request has FAILED:"
      echo " $SUBDOMAIN.$DOMAIN + autodiscover.$DOMAIN "
      echo " Make sure the Firewall/NAT is open on Port 80 for US/CA IPs and DNS Records activ ?"
      echo ""
      echo "Continue <ENTER>"
      read
      certbot certonly --no-eff-email --agree-tos --nginx --deploy-hook "cp /etc/letsencrypt/live/$SUBDOMAIN.$DOMAIN/privkey.pem $SSL_KEY_FILE_PATH && cp /etc/letsencrypt/live/$SUBDOMAIN.$DOMAIN/fullchain.pem $SSL_CERT_FILE_PATH" -m $MAIL -d $SUBDOMAIN.$DOMAIN -d autodiscover.$DOMAIN
    done
  elif [ "$SSL" == "self" ]; then
    echo "## CREATE SELF-SIGNED SSL CERTIFICATE ##"
    openssl req -new -x509 -days 365 -nodes -keyout $SSL_KEY_FILE_PATH -out $SSL_CERT_FILE_PATH -subj "/CN=$SUBDOMAIN.$DOMAIN"
  fi

  echo "## SET HOSTNAME ##"
  hostnamectl set-hostname $DOMAIN

  echo "## CREATE USERS AND GROUPS ##"
  useradd -r gromox
  useradd -r system-user-groweb
  useradd -r grommunio-web
  groupadd -r grommunio
  groupadd -r nginx
  usermod -a -G ssl-cert gromox
  usermod -a -G ssl-cert grodav
  usermod -a -G ssl-cert grosync
  usermod -a -G ssl-cert groweb

  echo "## INSTALL GROMMUNIO PACKAGES ##"
  apt install -y grommunio-common gromox grommunio-admin-api grommunio-admin-web system-user-groweb system-user-grosync system-user-grodav grommunio-web grommunio-admin-common grommunio-sync grommunio-dav

  echo "## CREATE PHP-FPM RUN FOLDER ##"
  echo "d /run/php-fpm 0755 www-data gromox - -" >/etc/tmpfiles.d/run-php-fpm.conf && systemd-tmpfiles --create

  echo "## ACTIVATE PHP7.4-FPM ##"
  systemctl enable --now php7.4-fpm

  echo "## ENABLE GROMMUNIO-WEB ##"
  ln -s /etc/php/7.4/fpm/php-fpm.d/pool-grommunio-web.conf /etc/php/7.4/fpm/pool.d/
  systemctl restart php7.4-fpm.service
  systemctl restart nginx.service

  echo "## CREATE DB AND USER ##"
  mysql -h $DBHOST -e "CREATE DATABASE IF NOT EXISTS grommunio;"
  mysql -h $DBHOST -e "GRANT ALL ON $DBNAME.* TO '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASSWD';"

  echo "## FIX SSL FOLDER RIGHTS ##"
  chmod 755 /etc/ssl/private
  chgrp ssl-cert /etc/ssl/private/*
  chmod 640 /etc/ssl/private/*

  echo "## CREATE NGINX SSL CONFIG ##"
  echo "ssl_certificate $SSL_CERT_FILE_PATH;" >/etc/grommunio-common/nginx/ssl_certificate.conf
  echo "ssl_certificate_key $SSL_KEY_FILE_PATH;" >>/etc/grommunio-common/nginx/ssl_certificate.conf

  echo "## REMOVE DEFAULT NGINX HOST ##"
  rm -f /etc/nginx/sites-enabled/default

  echo "## CREATE GROMOX DB CONFIG ##"
  OUTFILE="/etc/gromox/pop3.cfg"
  cat <<EOF >$OUTFILE
mysql_username=$DBUSER
mysql_password=$DBPASSWD
mysql_dbname=$DBNAME
schema_upgrade=host:$DBHOST
EOF

  echo "## CREATE GROMOX TABLES ##"
  gromox-dbop -C

  echo "## ACTIVATE GROMOX EVENT AND TIMER ##"
  systemctl enable --now gromox-event gromox-timer

  echo "## CREATE GROMOX HTTP CONFIG ##"
  OUTFILE="/etc/gromox/pop3.cfg"
  cat <<EOF >$OUTFILE
listen_port=$GROMOX_HTTP_PORT
listen_ssl_port=$GROMOX_HTTP_SSL_PORT
http_support_ssl=yes
http_certificate_path=$SSL_CERT_FILE_PATH
http_private_key_path=$SSL_KEY_FILE_PATH
EOF

  echo "## CREATE GROMOX AUTODISCOVER CONFIG ##"
  OUTFILE="/etc/gromox/pop3.cfg"
  cat <<EOF >$OUTFILE
[database]
host=$DBHOST
username=$DBUSER
password=$DBPASSWD
dbname=$DBNAME
hostname=$DOMAIN
EOF

  echo "## ACTIVATE GROMOX HTTP SERVICE ##"
  systemctl enable --now gromox-http

  echo "## ACTIVATE GROMOX MIDB AND ZCORE ##"
  systemctl enable --now gromox-midb gromox-zcore

  echo "## CONFIGURE GROMOX IMAP ##"
  OUTFILE="/etc/gromox/pop3.cfg"
  cat <<EOF >$OUTFILE
listen_ssl_port=993
imap_support_starttls=true
imap_certificate_path=$SSL_CERT_FILE_PATH
imap_private_key_path=$SSL_KEY_FILE_PATH
imap_force_starttls=true
EOF

  echo "## CONFIGURE GROMOX POP3 ##"
  OUTFILE="/etc/gromox/pop3.cfg"
  cat <<EOF >$OUTFILE
listen_ssl_port=995
pop3_support_stls=true
pop3_certificate_path=$SSL_CERT_FILE_PATH
pop3_private_key_path=$SSL_KEY_FILE_PATH
pop3_force_stls=true
EOF

  echo "## ACTIVATE GROMOX IMAP AND POP3 ##"
  systemctl enable --now gromox-imap gromox-pop3

  echo "## CONFIGURE GROMMUNIO ADMIN API ##"
  OUTFILE="/etc/grommunio-admin-api/conf.d/database.yaml"
  cat <<EOF >$OUTFILE
DB:
  host: '$DBHOST'
  user: '$DBUSER'
  pass: '$DBPASSWD'
  database: '$DBNAME'
EOF

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
  echo "listen_port = 24" >/etc/gromox/smtp.cfg

  echo "## CONFIGURE POSTFIX ##"
  postconf -e virtual_alias_maps=mysql:/etc/postfix/g-alias.cf
  postconf -e virtual_mailbox_domains=mysql:/etc/postfix/g-virt.cf
  postconf -e virtual_transport="smtp:[localhost]:24"

  echo "## CREATE GROMOX POSTFIX CONFIGS ##"
  OUTFILE="/etc/postfix/g-alias.cf"
  cat <<EOF >$OUTFILE
user = $DBUSER
password = $DBPASSWD
hosts = $DBHOST
dbname = $DBNAME
query = SELECT mainname FROM aliases WHERE aliasname='%s'
EOF

  OUTFILE="/etc/postfix/g-virt.cf"
  cat <<EOF >$OUTFILE
user = $DBUSER
password = $DBPASSWD
hosts = $DBHOST
dbname = $DBNAME
query = SELECT 1 FROM domains WHERE domain_status=0 AND domainname='%s'
EOF

  echo "## ACTIVATE AND RESTART POSTFIX AND GROMOX DELIVERY AND GROMOX DELIVERY QUEUE ##"
  systemctl enable --now gromox-delivery gromox-delivery-queue postfix
  systemctl restart gromox-delivery-queue postfix

  echo "## CONFIGURE AND ENABLE REDIS ##"
  mkdir -p /var/lib/redis/default
  chown redis.redis -R /var/lib/redis
  systemctl disable --now redis-server.service

  OUTFILE="/etc/systemd/system/redis@grommunio.service"
  cat <<EOF >$OUTFILE
[Unit]
Description=Redis instance: %i
After=network.target
PartOf=redis.target

[Service]
Type=notify
User=redis
Group=redis
PrivateTmp=true
PIDFile=/run/redis/%i.pid
ExecStart=/usr/bin/redis-server /etc/redis/%i.conf
LimitNOFILE=10240
Restart=on-failure

[Install]
WantedBy=multi-user.target redis.target
EOF

  systemctl daemon-reload
  systemctl enable --now redis@grommunio.service

  echo "## ENABLE GROMMUNIO-SYNC ##"
  ln -s /etc/php/7.4/fpm/php-fpm.d/pool-grommunio-sync.conf /etc/php/7.4/fpm/pool.d/
  systemctl restart php7.4-fpm.service
  systemctl restart nginx.service

  echo "## ENABLE GROMMUNIO-DAV ##"
  ln -s /etc/php/7.4/fpm/php-fpm.d/pool-grommunio-dav.conf /etc/php/7.4/fpm/pool.d/
  systemctl restart php7.4-fpm.service
  systemctl restart nginx.service

  ########## SHOW LOGINS ##########
  echo ""
  echo "+------------------------------------+"
  echo "| Grommunio Logins URL/User/Password |"
  echo "+------------------------------------+"
  echo ""
  echo "URL: https://$SUBDOMAIN.$DOMAIN:8443 (SSL-AdminPanel)"
  echo "URL: http://$SUBDOMAIN.$DOMAIN:8080 (NoSSL-AdminPanel)"
  echo "User: admin"
  echo "Password: $ADMINPASSWD"
  echo "SQLDB-PW: $DBPASSWD"
  echo ""
  echo "URL: https://$SUBDOMAIN.$DOMAIN (Webmail)"
  echo ""

########## END NOT ROOT ##########
else
  USER=$(whoami)
  echo "You are not ROOT user"
  echo ""
  echo "Your User is ${USER}"
fi
