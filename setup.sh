#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2021 grommunio GmbH
# Interactive grommunio setup

apt update
apt install -y dialog

DATADIR="${0%/*}"
if [ "${DATADIR}" = "$0" ]; then
  DATADIR="/usr/share/grommunio-setup"
else
  DATADIR="$(readlink -f "$0")"
  DATADIR="${DATADIR%/*}"
  DATADIR="$(readlink -f "${DATADIR}")"
fi
LOGFILE="/var/log/grommunio-setup.log"
if ! test -e "$LOGFILE"; then
  true >"$LOGFILE"
  chmod 0600 "$LOGFILE"
fi
# shellcheck source=common/helpers
. "${DATADIR}/common/helpers"
# shellcheck source=common/dialogs
. "${DATADIR}/common/dialogs"
TMPF=$(mktemp /tmp/setup.sh.XXXXXXXX)

# make sure necessary packages are installed
apt update 2>&1 | tee -a "$LOGFILE"
apt upgrade -y 2>&1 | tee -a "$LOGFILE"
echo "postfix	postfix/mailname string $DOMAIN" | debconf-set-selections
echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections
SYSTEM_PACKAGES="mariadb-server mariadb-client redis nginx postfix postfix-mysql php php-igbinary php-redis \
php7.4 php7.4-fpm curl fetchmail rspamd certbot python3-certbot-nginx libsasl2-2 libsasl2-modules sasl2-bin jq gnupg2"
DEBIAN_FRONTEND=noninteractive apt install -y ${SYSTEM_PACKAGES} 2>&1 | tee -a "$LOGFILE"

writelog "Welcome dialog"
dialog_welcome

if [ -e "/etc/grommunio-common/setup_done" ]; then
  DELCONFIRM=$(dialog --no-mouse --colors --backtitle "grommunio Setup" --title "grommunio Setup already completed" --cr-wrap --inputbox \
    'grommunio Setup was already run.

You can abort or delete all data and setup everything from scratch. If so, confirm this operation by typing "removealldata" to continue.

\Z1If you continue, ALL data wil be removed!\Z1' \
    0 0 3>&1 1>&2 2>&3)
  dialog_exit $?

  if [ "${DELCONFIRM}" != "removealldata" ]; then
    writelog "Aborted deletion after detected existing installation"
    exit 0
  else
    writelog "Deleting existing installation after confirmation"
    echo "drop database grommunio;" | mysql
    rm -rf /var/lib/gromox/user/* /var/lib/gromox/domain/* /var/lib/gromox/queue/* /etc/grommunio-common/ssl/* /etc/grommunio-common/setup_done
  fi
fi

memory_check() {

  local HAVE=$(perl -lne 'print $1 if m{^MemTotal:\s*(\d+)}i' </proc/meminfo)
  # Install the threshold a little lower than what we ask, to account for
  # FW/OS (Vbox with 4194304 KB ends up with MemTotal of about 4020752 KB)
  local THRES=4000000
  local ASK=4096000
  if [ -z "${HAVE}" ] || [ "${HAVE}" -ge "${THRES}" ]; then
    return 0
  fi
  writelog "Memory check"
  memory_notice $((HAVE / 1024)) $((ASK / 1024))

}

memory_check

unset MYSQL_DB
unset MYSQL_HOST
unset MYSQL_USER
unset MYSQL_PASS
unset ADMIN_PASS
unset FQDN
unset DOMAIN
unset X500
unset SSL_BUNDLE
unset SSL_KEY

writelog "Installation / update of packages"
# shellcheck source=common/repo
PACKAGES="gromox grommunio-admin-api grommunio-admin-web grommunio-admin-common \
  grommunio-common grommunio-web grommunio-sync grommunio-dav \
  system-user-groweb system-user-grosync system-user-grodav"
. "${DATADIR}/common/repo"
setup_repo

user_management () {
    useradd -r gromox 2>&1 | tee -a "$LOGFILE"
    useradd -r system-user-groweb 2>&1 | tee -a "$LOGFILE"
    useradd -r grommunio-web 2>&1 | tee -a "$LOGFILE"
    groupadd -r grommunio 2>&1 | tee -a "$LOGFILE"
    groupadd -r nginx 2>&1 | tee -a "$LOGFILE"
    usermod -a -G ssl-cert gromox 2>&1 | tee -a "$LOGFILE"
    usermod -a -G ssl-cert grodav 2>&1 | tee -a "$LOGFILE"
    usermod -a -G ssl-cert grosync 2>&1 | tee -a "$LOGFILE"
    usermod -a -G ssl-cert groweb 2>&1 | tee -a "$LOGFILE"
}
user_management

MYSQL_HOST="localhost"
MYSQL_USER="grommunio"
MYSQL_PASS=$(randpw)
MYSQL_DB="grommunio"

set_mysql_param() {

  writelog "Dialog: mysql configuration"
  dialog --no-mouse --colors --backtitle "grommunio Setup" --title "MariaDB/MySQL database credentials" --ok-label "Submit" \
    --form "Enter the database credentials." 0 0 0 \
    "Host:    " 1 1 "${MYSQL_HOST}" 1 17 25 0 \
    "User:    " 2 1 "${MYSQL_USER}" 2 17 25 0 \
    "Password:" 3 1 "${MYSQL_PASS}" 3 17 25 0 \
    "Database:" 4 1 "${MYSQL_DB}" 4 17 25 0 2>"${TMPF}"
  dialog_exit $?

}

writelog "Dialog: mysql installation type"
MYSQL_INSTALL_TYPE=$(dialog --no-mouse --colors --backtitle "grommunio Setup" --title "grommunio Setup: Database" \
  --menu "Choose database setup type" 0 0 0 \
  "1" "Create database locally (default)" \
  "2" "Connect to existing database (advanced users)" 3>&1 1>&2 2>&3)
dialog_exit $?

writelog "Selected MySQL installation type: ${MYSQL_INSTALL_TYPE}"

RETCMD=1
if [ "${MYSQL_INSTALL_TYPE}" = "2" ]; then
  while [ ${RETCMD} -ne 0 ]; do
    set_mysql_param "Existing database"
    MYSQL_HOST=$(sed -n '1{p;q}' "${TMPF}")
    MYSQL_USER=$(sed -n '2{p;q}' "${TMPF}")
    MYSQL_PASS=$(sed -n '3{p;q}' "${TMPF}")
    MYSQL_DB=$(sed -n '4{p;q}' "${TMPF}")
    if [ -n "${MYSQL_HOST}" ] && [ -n "${MYSQL_USER}" ] && [ -z "${MYSQL_PASS}" ] && [ -n "${MYSQL_DB}" ]; then
      echo "show tables;" | mysql -h"${MYSQL_HOST}" -u"${MYSQL_USER}" "${MYSQL_DB}" >/dev/null 2>&1
      writelog "mysql -h${MYSQL_HOST} -u${MYSQL_USER} ${MYSQL_DB}"
    elif [ -n "${MYSQL_HOST}" ] && [ -n "${MYSQL_USER}" ] && [ -n "${MYSQL_PASS}" ] && [ -n "${MYSQL_DB}" ]; then
      echo "show tables;" | mysql -h"${MYSQL_HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" "${MYSQL_DB}" >/dev/null 2>&1
      writelog "mysql -h${MYSQL_HOST} -u${MYSQL_USER} -p${MYSQL_PASS} ${MYSQL_DB}"
    else
      failonme 1
    fi
    RETCMD=$?
    if [ ${RETCMD} -ne 0 ]; then
      dialog --no-mouse --clear --colors --backtitle "grommunio Setup" --title "MySQL database credentials" --msgbox 'No connection could be established with the database using the provided credentials. Verify that the credentials are correct and that a connection to the database is possible from this system.' 0 0
      dialog_exit $?
    fi
  done
else
  while [ ${RETCMD} -ne 0 ]; do
    set_mysql_param "Create database"
    MYSQL_HOST=$(sed -n '1{p;q}' "${TMPF}")
    MYSQL_USER=$(sed -n '2{p;q}' "${TMPF}")
    MYSQL_PASS=$(sed -n '3{p;q}' "${TMPF}")
    MYSQL_DB=$(sed -n '4{p;q}' "${TMPF}")
    if [ -n "${MYSQL_HOST}" ] && [ -n "${MYSQL_USER}" ] && [ -n "${MYSQL_PASS}" ] && [ -n "${MYSQL_DB}" ]; then
      echo "drop database if exists ${MYSQL_DB}; create database ${MYSQL_DB}; grant all on ${MYSQL_DB}.* to '${MYSQL_USER}'@'${MYSQL_HOST}' identified by '${MYSQL_PASS}';" | mysql >/dev/null 2>&1
    else
      failonme 1
    fi
    RETCMD=$?
    if [ ${RETCMD} -ne 0 ]; then
      dialog --no-mouse --clear --colors --backtitle "grommunio Setup" --title "MySQL connection failed" --msgbox 'Could not set up the database. Make sure it is reachable and re-run the creation process.' 0 0
      dialog_exit $?
    fi
  done
fi
writelog "MySQL configuration: Host: ${MYSQL_HOST}, User: ${MYSQL_USER}, Password: ${MYSQL_PASS}, Database: ${MYSQL_DB}"

dialog_adminpass

set_fqdn() {

  writelog "Dialog: FQDN"
  dialog --no-mouse --clear --colors --backtitle "grommunio Setup" --title "Fully Qualified Domain Name (FQDN)" --cr-wrap --inputbox \
    "Tell us this system's fully qualified domain name (FQDN). This is used, for example, by Outlook clients to connect.

Example: grommunio.example.com

This name will be part of the certificates later generated. / This name will have to be present in imported certificates." 0 0 "$(hostname -f)" 3>&1 1>&2 2>&3
  dialog_exit $?

}

ORIGFQDN=$(set_fqdn)
FQDN="${ORIGFQDN,,}"

while [[ ${FQDN} =~ / ]]; do
  dialog --no-mouse --clear --colors --backtitle "grommunio Setup" --title "Fully Qualified Domain Name (FQDN)" --msgbox 'The FQDN is invalid. Enter a valid FQDN.' 0 0
  FQDN=$(set_fqdn)
  dialog_exit $?
done
writelog "Configured FQDN: ${FQDN}"

set_maildomain() {

  DFL=$(hostname -d)
  if [ -z "${DFL}" ]; then
    DFL="${FQDN}"
  fi
  writelog "Dialog: mail domain"
  dialog --no-mouse --clear --colors --backtitle "grommunio Setup" --title "Mail domain" --cr-wrap --inputbox \
    "Tell us the default mail domain this system serves up. This is used, for example, for Non-Delivery Reports and for generation of some simple TLS certificates. Specify ONLY ONE domain here.

Example: example.com" 0 0 "${DFL}" 3>&1 1>&2 2>&3
  dialog_exit $?

}

ORIGDOMAIN=$(set_maildomain)
DOMAIN=${ORIGDOMAIN,,}

while [[ ${DOMAIN} =~ / ]]; do
  dialog --no-mouse --clear --colors --backtitle "grommunio Setup" --title "Mail domain" --msgbox 'The entered mail domain is invalid. Enter a valid mail domain.' 0 0
  dialog_exit $?
  ORIGDOMAIN=$(set_maildomain)
  DOMAIN=${ORIGDOMAIN,,}
done
writelog "Configured mail domain: ${FQDN}"

RELAYHOST=$(get_relayhost)
writelog "Got relayhost: ${RELAYHOST}"

X500="i$(printf "%llx" "$(date +%s)")"

[ -e "/etc/grommunio-common/ssl" ] || mkdir -p "/etc/grommunio-common/ssl"

# Configure config.json of admin-web
cat >/etc/grommunio-admin-common/nginx.d/web-config.conf <<EOF
location /config.json {
  alias /etc/grommunio-admin-common/config.json;
}
EOF

choose_ssl_install_type() {

  writelog "Dialog: ssl installation type"
  SSL_INSTALL_TYPE=$(dialog --no-mouse --colors --backtitle "grommunio Setup" --title "grommunio Setup: TLS" \
    --menu "Choose your TLS setup type" 0 0 0 \
    "0" "Create self-signed certificate" \
    "1" "Create own CA and certificate" \
    "2" "Import an existing TLS certificate from files" \
    "3" "Automatically generate Let's Encrypt certificate" 3>&1 1>&2 2>&3)
  dialog_exit $?

}

choose_ssl_install_type
writelog "Selected TLS installation type: ${SSL_INSTALL_TYPE}"

SSL_COUNTRY="XX"
SSL_STATE="XX"
SSL_LOCALITY="X"
SSL_ORG="grommunio Appliance"
SSL_OU="IT"
SSL_EMAIL="admin@${DOMAIN}"
SSL_DAYS=30
SSL_PASS=$(randpw)

choose_ssl_fullca() {

  writelog "Dialog: data for Full CA"
  dialog --no-mouse --colors --backtitle "grommunio Setup" --title "TLS certificate (Full CA)" --ok-label "Submit" \
    --form "Enter TLS related data" 0 0 0 \
    "Country:        " 1 1 "${SSL_COUNTRY}" 1 17 25 0 \
    "State:          " 2 1 "${SSL_STATE}" 2 17 25 0 \
    "Locality:       " 3 1 "${SSL_LOCALITY}" 3 17 25 0 \
    "Organization:   " 4 1 "${SSL_ORG}" 4 17 25 0 \
    "Org Unit:       " 5 1 "${SSL_OU}" 5 17 25 0 \
    "E-Mail:         " 6 1 "${SSL_EMAIL}" 6 17 25 0 \
    "Validity (days):" 7 1 "${SSL_DAYS}" 7 17 25 0 2>"${TMPF}"
  dialog_exit $?

}

choose_ssl_selfprovided() {

  writelog "Dialog: data for self-provided TLS cert"
  dialog --no-mouse --colors --backtitle "grommunio Setup" --title "TLS certificate (self-provided)" --ok-label "Submit" \
    --form "Enter the paths to the TLS certificates" 0 0 0 \
    "PEM encoded certificate bundle:  " 1 1 "${SSL_BUNDLE}" 1 35 35 0 \
    "PEM encoded private key:         " 2 1 "${SSL_KEY}" 2 35 35 0 2>"${TMPF}"
  dialog_exit $?

}

set_letsencryptmail() {

  writelog "Dialog: Let's Encrypt"
  dialog --no-mouse --clear --colors --backtitle "grommunio Setup" --title "TLS certificate (Let's Encrypt)" --cr-wrap --inputbox \
    "Specify an email adress that Let's Encrypt can contact for when there is an issue with the certificates

Example: ${SSL_EMAIL}" 0 0 "${SSL_EMAIL}" 3>&1 1>&2 2>&3
  dialog_exit $?

}

choose_ssl_letsencrypt() {

  writelog "Dialog: Let's Encrypt domains"
  LE_TERMS_URL=$(curl -Lsk https://acme-v02.api.letsencrypt.org/directory | grep termsOfService | sed 's#\(.*\)\(https://.*\)\",#\2#')
  if [ "${FQDN}" = "${DOMAIN}" ]; then
    dialog --no-mouse --colors --backtitle "grommunio Setup" --title "TLS certificate (Let's Encrypt)" --ok-label "Submit" \
      --checklist "Choose the Let's Encrypt certificates to request.\nBy requesting certificates from Let's Encrypt, you agree to the terms of service at ${LE_TERMS_URL}.\nThe DNS records should be set accordingly before proceeding." 0 0 0 \
      "${DOMAIN}" "recommended" on \
      "autodiscover.${DOMAIN}" "recommended" on \
      "mail.${DOMAIN}" "optional" off 2>"${TMPF}"
  else
    if [ "${FQDN}" = "mail.${DOMAIN}" ]; then
      dialog --no-mouse --colors --backtitle "grommunio Setup" --title "TLS certificate (Let's Encrypt)" --ok-label "Submit" \
        --checklist "Choose the Let's Encrypt certificates to request.\nBy requesting certificates from Let's Encrypt, you agree to the terms of service at ${LE_TERMS_URL}.\nThe DNS records should be set accordingly before proceeding." 0 0 0 \
        "${DOMAIN}" "recommended" on \
        "${FQDN}" "recommended" on \
        "autodiscover.${DOMAIN}" "recommended" off 2>"${TMPF}"
    else
      dialog --no-mouse --colors --backtitle "grommunio Setup" --title "TLS certificate (Let's Encrypt)" --ok-label "Submit" \
        --checklist "Choose the Let's Encrypt certificates to request.\nBy requesting certificates from Let's Encrypt, you agree to the terms of service at ${LE_TERMS_URL}.\nThe DNS records should be set accordingly before proceeding." 0 0 0 \
        "${DOMAIN}" "recommended" on \
        "autodiscover.${DOMAIN}" "recommended" on \
        "${FQDN}" "recommended" on \
        "mail.${DOMAIN}" "optional" off 2>"${TMPF}"
    fi
  fi
  dialog_exit $?

}

# shellcheck source=common/ssl_setup
. "${DATADIR}/common/ssl_setup"
RETCMD=1
if [ "${SSL_INSTALL_TYPE}" = "0" ]; then
  clear
  if ! selfcert; then
    dialog --no-mouse --clear --colors --backtitle "grommunio Setup" --title "TLS certificate (self-signed)" --msgbox "Certificate generation not successful. See ${LOGFILE}.\nContinue installation or press ESC to abort setup." 0 0
    dialog_exit $?
  fi
elif [ "${SSL_INSTALL_TYPE}" = "1" ]; then
  while [ -z "${SSL_COUNTRY}" ] || [ -z "${SSL_STATE}" ] || [ -z "${SSL_LOCALITY}" ] || [ -z "${SSL_ORG}" ] || [ -z "${SSL_OU}" ] || [ -z "${SSL_EMAIL}" ] || [ -z "${SSL_DAYS}" ] || [ "${RETCMD}" = "1" ]; do
    choose_ssl_fullca
    RETCMD=0
  done
  SSL_COUNTRY=$(sed -n '1{p;q}' "${TMPF}")
  SSL_STATE=$(sed -n '2{p;q}' "${TMPF}")
  SSL_LOCALITY=$(sed -n '3{p;q}' "${TMPF}")
  SSL_ORG=$(sed -n '4{p;q}' "${TMPF}")
  SSL_OU=$(sed -n '5{p;q}' "${TMPF}")
  SSL_EMAIL=$(sed -n '6{p;q}' "${TMPF}")
  SSL_DAYS=$(sed -n '7{p;q}' "${TMPF}")
  fullca
  writelog "TLS configuration: Country: ${SSL_COUNTRY} State: ${SSL_STATE} Locality: ${SSL_LOCALITY} Organization: ${SSL_ORG} Org Unit: ${SSL_OU} E-Mail: ${SSL_EMAIL} Validity (days): ${SSL_DAYS}"
elif [ "${SSL_INSTALL_TYPE}" = "2" ]; then
  choose_ssl_selfprovided
  SSL_BUNDLE=$(sed -n '1{p;q}' "${TMPF}")
  SSL_KEY=$(sed -n '2{p;q}' "${TMPF}")
  while [ ${RETCMD} -ne 0 ]; do
    owncert
    RETCMD=$?
  done
  writelog "TLS configuration: Bundle: ${SSL_BUNDLE} Key: ${SSL_KEY}"
elif [ "${SSL_INSTALL_TYPE}" = "3" ]; then
  choose_ssl_letsencrypt
  SSL_DOMAINS=$(sed 's# #,#g' "${TMPF}" | tr '[:upper:]' '[:lower:]')
  while [ -z "${SSL_DOMAINS}" ]; do
    dialog --no-mouse --clear --colors --backtitle "grommunio Setup" --title "TLS certificate (Let's encrypt)" --msgbox "No valid domains have been chosen for the TLS certificates. Select valid domains." 0 0
    dialog_exit $?
    choose_ssl_letsencrypt
    SSL_DOMAINS=$(sed 's# #,#g' "${TMPF}" | tr '[:upper:]' '[:lower:]')
  done

  SSL_EMAIL=$(set_letsencryptmail)
  while ! [[ ${SSL_EMAIL} =~ ^.*\@.*$ ]]; do
    dialog --no-mouse --clear --colors --backtitle "grommunio Setup" --title "TLS certificate (Let's Encrypt)" --msgbox "The provided email address is invalid. Enter a valid email address." 0 0
    SSL_EMAIL=$(set_letsencryptmail)
    dialog_exit $?
  done
  letsencrypt
  writelog "TLS configuration: Let's Encrypt ${SSL_EMAIL}"
fi

echo "{ \"mailWebAddress\": \"https://${FQDN}/web\" }" | jq >/tmp/config.json

progress 0

progress 10
writelog "Config stage: enable all services"
systemctl enable redis@grommunio.service gromox-delivery.service gromox-event.service \
  gromox-http.service gromox-imap.service gromox-midb.service gromox-pop3.service \
  gromox-delivery-queue.service gromox-timer.service gromox-zcore.service grommunio-antispam.service\
  php7.4-fpm.service nginx.service grommunio-admin-api.service saslauthd.service mariadb >>"${LOGFILE}" 2>&1

progress 20
writelog "Config stage: start db"
systemctl start mariadb >>"${LOGFILE}" 2>&1

writelog "Config stage: put php files into place"
if [ -e "/etc/php/7.4/fpm/php-fpm.conf.default" ]; then
  mv /etc/php/7.4/fpm/php-fpm.conf.default /etc/php/7.4/fpm/php-fpm.conf 2>&1 | tee -a "$LOGFILE"
fi
if [ ! -e "/etc/php/7.4/fpm/pool.d/gromox.conf" ]; then
  cp -f /usr/share/gromox/fpm-gromox.conf.sample /etc/php/7.4/fpm/pool.d/gromox.conf 2>&1 | tee -a "$LOGFILE"
fi
if [ ! -e "/etc/php/7.4/fpm/pool.d/pool-grommunio-web.conf" ]; then
  ln -s /etc/php/7.4/fpm/php-fpm.d/pool-grommunio-web.conf /etc/php/7.4/fpm/pool.d/ 2>&1 | tee -a "$LOGFILE"
fi
if [ ! -e "/etc/php/7.4/fpm/pool.d/pool-grommunio-sync.conf" ]; then
  ln -s /etc/php/7.4/fpm/php-fpm.d/pool-grommunio-sync.conf /etc/php/7.4/fpm/pool.d/ 2>&1 | tee -a "$LOGFILE"
fi
if [ ! -e "/etc/php/7.4/fpm/pool.d/pool-grommunio-dav.conf" ]; then
  ln -s /etc/php/7.4/fpm/php-fpm.d/pool-grommunio-dav.conf /etc/php/7.4/fpm/pool.d/ 2>&1 | tee -a "$LOGFILE"
fi
echo "d /run/php-fpm 0755 www-data gromox - -" >/etc/tmpfiles.d/run-php-fpm.conf && systemd-tmpfiles --create 2>&1 | tee -a "$LOGFILE"

writelog "Remove default nginx host config"
rm -f /etc/nginx/sites-enabled/default 2>&1 | tee -a "$LOGFILE"

writelog "Config stage: gromox config"
setconf /etc/gromox/http.cfg listen_port 10080
setconf /etc/gromox/http.cfg http_support_ssl true
setconf /etc/gromox/http.cfg listen_ssl_port 10443
setconf /etc/gromox/http.cfg host_id "${FQDN}"

setconf /etc/gromox/smtp.cfg listen_port 24

writelog "Config stage: pam config"
progress 30
cp /etc/pam.d/smtp /etc/pam.d/smtp.save
cat >/etc/pam.d/smtp <<EOF
#%PAM-1.0
auth required pam_gromox.so
account required pam_permit.so service=smtp
EOF

writelog "Config stage: database creation"
progress 40
echo "create database grommunio; grant all on grommunio.* to 'grommunio'@'localhost' identified by '${MYSQL_PASS}';" | mysql
echo "# Do not delete this file unless you know what you do!" >/etc/grommunio-common/setup_done

writelog "Config stage: database configuration"
setconf /etc/gromox/mysql_adaptor.cfg mysql_username "${MYSQL_USER}"
setconf /etc/gromox/mysql_adaptor.cfg mysql_password "${MYSQL_PASS}"
setconf /etc/gromox/mysql_adaptor.cfg mysql_dbname "${MYSQL_DB}"
setconf /etc/gromox/mysql_adaptor.cfg schema_upgrade "host:${FQDN}"

cp -f /etc/gromox/mysql_adaptor.cfg /etc/gromox/adaptor.cfg >>"${LOGFILE}" 2>&1

writelog "Config stage: autodiscover configuration"
progress 50
cat >/etc/gromox/autodiscover.ini <<EOF
[database]
host = ${MYSQL_HOST}
username = '${MYSQL_USER}'
password = '${MYSQL_PASS}'
dbname = '${MYSQL_DB}'

[exchange]
organization = '${X500}'
hostname = ${FQDN}
mapihttp = 1

[default]
timezone = 'Europe/Vienna'

[system]

[http-proxy]
/var/lib/gromox/user = ${FQDN}
/var/lib/gromox/domain = ${FQDN}
EOF

writelog "Config redis fro Grommunio"
mkdir -p /var/lib/redis/default 2>&1 | tee -a "$LOGFILE"
chown redis.redis -R /var/lib/redis 2>&1 | tee -a "$LOGFILE"
systemctl disable --now redis-server.service 2>&1 | tee -a "$LOGFILE"

cat >"/etc/systemd/system/redis@grommunio.service" <<EOF
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
systemctl daemon-reload 2>&1 | tee -a "$LOGFILE"

writelog "Config stage: database initialization"
gromox-dbop -C >>"${LOGFILE}" 2>&1

cat >/etc/grommunio-admin-api/conf.d/database.yaml <<EOF
DB:
  host: '${MYSQL_HOST}'
  user: '${MYSQL_USER}'
  pass: '${MYSQL_PASS}'
  database: '${MYSQL_DB}'
EOF

writelog "Config stage: admin password set"
progress 60
grommunio-admin passwd --password "${ADMIN_PASS}" >>"${LOGFILE}" 2>&1

rspamadm pw -p "${ADMIN_PASS}" | sed -e 's#^#password = "#' -e 's#$#";#' >/etc/grommunio-antispam/local.d/worker-controller.inc

writelog "Config stage: gromox tls configuration"
setconf /etc/gromox/http.cfg http_certificate_path "${SSL_BUNDLE_T}"
setconf /etc/gromox/http.cfg http_private_key_path "${SSL_KEY_T}"

setconf /etc/gromox/imap.cfg imap_support_starttls true
setconf /etc/gromox/imap.cfg listen_ssl_port 993
setconf /etc/gromox/imap.cfg imap_certificate_path "${SSL_BUNDLE_T}"
setconf /etc/gromox/imap.cfg imap_private_key_path "${SSL_KEY_T}"

setconf /etc/gromox/pop3.cfg pop3_support_stls true
setconf /etc/gromox/pop3.cfg listen_ssl_port 995
setconf /etc/gromox/pop3.cfg pop3_certificate_path "${SSL_BUNDLE_T}"
setconf /etc/gromox/pop3.cfg pop3_private_key_path "${SSL_KEY_T}"

cat >/etc/grommunio-common/nginx/ssl_certificate.conf <<EOF
ssl_certificate ${SSL_BUNDLE_T};
ssl_certificate_key ${SSL_KEY_T};
EOF
ln -s /etc/grommunio-common/nginx/ssl_certificate.conf /etc/grommunio-admin-common/nginx-ssl.conf
chown gromox:gromox /etc/grommunio-common/ssl/*

# Domain and X500
writelog "Config stage: gromox domain and x500 configuration"
for SERVICE in http midb zcore imap pop3 smtp delivery; do
  setconf /etc/gromox/${SERVICE}.cfg default_domain "${DOMAIN}"
done
for CFG in midb.cfg zcore.cfg exmdb_local.cfg exmdb_provider.cfg exchange_emsmdb.cfg exchange_nsp.cfg; do
  setconf "/etc/gromox/${CFG}" x500_org_name "${X500}"
done

writelog "Config stage: postfix configuration"
progress 80

cat >/etc/postfix/grommunio-virtual-mailbox-domains.cf <<EOF
user = ${MYSQL_USER}
password = ${MYSQL_PASS}
hosts = ${MYSQL_HOST}
dbname = ${MYSQL_DB}
query = SELECT 1 FROM domains WHERE domain_status=0 AND domainname='%s'
EOF

cat >/etc/postfix/grommunio-virtual-mailbox-alias-maps.cf <<EOF
user = ${MYSQL_USER}
password = ${MYSQL_PASS}
hosts = ${MYSQL_HOST}
dbname = ${MYSQL_DB}
query = SELECT mainname FROM aliases WHERE aliasname='%s'
EOF

postconf -e \
  myhostname="${FQDN}" \
  virtual_mailbox_domains="mysql:/etc/postfix/grommunio-virtual-mailbox-domains.cf" \
  virtual_alias_maps="mysql:/etc/postfix/grommunio-virtual-mailbox-alias-maps.cf" \
  virtual_transport="smtp:[::1]:24" \
  relayhost="${RELAYHOST}" \
  inet_interfaces=all \
  smtpd_helo_restrictions=permit_mynetworks,permit_sasl_authenticated,reject_invalid_hostname,reject_non_fqdn_hostname \
  smtpd_sender_restrictions=reject_non_fqdn_sender,permit_sasl_authenticated,permit_mynetworks \
  smtpd_recipient_restrictions=permit_sasl_authenticated,permit_mynetworks,reject_unknown_recipient_domain,reject_non_fqdn_hostname,reject_non_fqdn_sender,reject_non_fqdn_recipient,reject_unauth_destination,reject_unauth_pipelining \
  smtpd_data_restrictions=reject_unauth_pipelining \
  smtpd_tls_security_level=may \
  smtpd_tls_auth_only=no \
  smtpd_tls_cert_file="${SSL_BUNDLE_T}" \
  smtpd_tls_key_file="${SSL_KEY_T}" \
  smtpd_tls_received_header=yes \
  smtpd_tls_session_cache_timeout=3600s \
  smtpd_use_tls=yes \
  tls_random_source=dev:/dev/urandom \
  smtpd_sasl_auth_enable=yes \
  broken_sasl_auth_clients=yes \
  smtpd_sasl_security_options=noanonymous \
  smtpd_sasl_local_domain= smtpd_milters=inet:localhost:11332 \
  milter_default_action=accept \
  milter_protocol=6
postconf -M tlsmgr/unix="tlsmgr unix - - n 1000? 1 tlsmgr"
postconf -M submission/inet="submission inet n - n - - smtpd"
postconf -P submission/inet/syslog_name="postfix/submission"
postconf -P submission/inet/smtpd_tls_security_level=encrypt
postconf -P submission/inet/smtpd_sasl_auth_enable=yes
postconf -P submission/inet/smtpd_relay_restrictions=permit_sasl_authenticated,reject
postconf -P submission/inet/milter_macro_daemon_name=ORIGINATING

writelog "Config stage: postfix enable and restart"
systemctl enable --now postfix.service >>"${LOGFILE}" 2>&1
systemctl restart postfix.service >>"${LOGFILE}" 2>&1

systemctl enable --now grommunio-fetchmail.timer >>"${LOGFILE}" 2>&1

writelog "Config stage: open required firewall ports"
{
  firewall-cmd --add-service=https --zone=public --permanent
  firewall-cmd --add-port=25/tcp --zone=public --permanent
  firewall-cmd --add-port=80/tcp --zone=public --permanent
  firewall-cmd --add-port=110/tcp --zone=public --permanent
  firewall-cmd --add-port=143/tcp --zone=public --permanent
  firewall-cmd --add-port=587/tcp --zone=public --permanent
  firewall-cmd --add-port=993/tcp --zone=public --permanent
  firewall-cmd --add-port=8080/tcp --zone=public --permanent
  firewall-cmd --add-port=8443/tcp --zone=public --permanent
  firewall-cmd --reload
} >>"${LOGFILE}" 2>&1

progress 90
writelog "Config stage: restart all required services"
systemctl restart redis@grommunio.service nginx.service php7.4-fpm.service gromox-delivery.service \
  gromox-event.service gromox-http.service gromox-imap.service gromox-midb.service grommunio-antispam.service\
  gromox-pop3.service gromox-delivery-queue.service gromox-timer.service gromox-zcore.service \
  grommunio-admin-api.service saslauthd.service >>"${LOGFILE}" 2>&1

mv /tmp/config.json /etc/grommunio-admin-common/config.json
systemctl restart grommunio-admin-api.service

progress 100
writelog "Config stage: completed"
setup_done

exit 0
