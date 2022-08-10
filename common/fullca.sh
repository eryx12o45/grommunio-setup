#!/bin/bash -ex
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2021 grommunio GmbH

pushd /etc/grommunio-common/ssl/

  openssl genrsa -aes256 -passout "pass:${SSL_PASS}" -out rootCA.key 4096
  openssl req -x509 -new -nodes -key rootCA.key -sha256 -days "${SSL_DAYS}" -out rootCA.crt -passin "pass:${SSL_PASS}" \
              -subj "/C=${SSL_COUNTRY}/ST=${SSL_STATE}/L=${SSL_LOCALITY}/O=${SSL_ORG}/OU=${SSL_OU}/CN=grommunio CA/emailAddress=${SSL_EMAIL}"

  openssl genrsa -out "${DOMAIN}.key" 2048
  openssl req -new -sha256 \
              -key "${DOMAIN}.key" \
              -subj "/C=${SSL_COUNTRY}/ST=${SSL_STATE}/L=${SSL_LOCALITY}/O=${SSL_ORG}/OU=${SSL_OU}/CN=${DOMAIN}/emailAddress=${SSL_EMAIL}" \
              -out "${DOMAIN}.csr" \
              -passout "pass:${SSL_PASS}"

  if [ "${FQDN}" != "${DOMAIN}" ]; then
    SUBJECTALTNAMES="subjectAltName=DNS:${DOMAIN},DNS:www.${DOMAIN},DNS:mail.${DOMAIN},DNS:autodiscover.${DOMAIN},DNS:meet.${DOMAIN},DNS:files.${DOMAIN},DNS:archive.${DOMAIN},DNS:${FQDN}"
else
    SUBJECTALTNAMES="subjectAltName=DNS:${DOMAIN},DNS:www.${DOMAIN},DNS:mail.${DOMAIN},DNS:autodiscover.${DOMAIN},DNS:meet.${DOMAIN},DNS:files.${DOMAIN},DNS:archive.${DOMAIN},DNS:${FQDN},DNS:www.${FQDN},DNS:mail.${FQDN},DNS:autodiscover.${FQDN},DNS:meet.${FQDN},DNS:files.${FQDN},DNS:archive.${FQDN},DNS:${FQDN}"
  fi

  openssl x509 -req \
               -in "${DOMAIN}.csr" -CA rootCA.crt -CAkey rootCA.key -CAcreateserial \
               -extfile <(printf "${SUBJECTALTNAMES}") \
               -out "${DOMAIN}.crt" -days "${SSL_DAYS}" -sha256 -passin "pass:${SSL_PASS}"

  openssl rsa -in "${DOMAIN}.key" -passin "pass:${SSL_PASS}" -out "${DOMAIN}.key"

  cat "${DOMAIN}.crt" "rootCA.crt" >>"${SSL_BUNDLE_T}"
  cp -f "${DOMAIN}.key" "${SSL_KEY_T}"
  cp -f "rootCA.crt" /usr/share/grommunio-admin-web/rootCA.crt

popd
