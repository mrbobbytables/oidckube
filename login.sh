#!/bin/bash

set -e
set -o pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
[[ ! -f "$DIR/config" ]] && cp "$DIR/config.example" "$DIR/config" 

# shellcheck source=config
source "$DIR/config"

JQ_RELEASE="1.5"
BIN_DIR="$DIR/bin"
PATH=$PATH:$BIN_DIR

install_jq() {
 command -v jq >/dev/null 2>&1 && return 0
  echo "[$(date)][WARNING] jq not found in path. Attempting to fetch."
  local jq_url="https://github.com/stedolan/jq/releases/download/jq-$JQ_RELEASE/"
  if echo "$OSTYPE" | grep -q "darwin"; then
    jq_url+="jq-osx-amd64"
  elif echo "$OSTYPE" | grep -q "linux"; then
    jq_url+="jq-linux64"
  else
    echo "[$(date)][ERROR] Unsupported OS for dependency resolution. Please install jq manually."
    return 1
  fi
  curl -SL "$jq_url" -o "$BIN_DIR/jq"
  chmod +x "$BIN_DIR/jq"
}

get_creds() {
  echo "Please input your credentials for https://$KEYCLOAK_ADDRESS/auth/realms/$KEYCLOAK_AUTH_REALM"
  if [ "$KEYCLOAK_USERNAME" = "" ];then
	  read -rp "email: " KEYCLOAK_USERNAME
  fi
  if [ "$KEYCLOAK_PASSWORD" = "" ];then
	  read -rsp "password: " KEYCLOAK_PASSWORD
    echo
  fi
  if [ "$KEYCLOAK_TOTP" = "" ]; then
    read -rp "TOTP [enter to skip]: " KEYCLOAK_TOTP
  fi
}

get_token() {
  local keycloak_token_url="https://$KEYCLOAK_ADDRESS/auth/realms/$KEYCLOAK_AUTH_REALM/protocol/openid-connect/token"
  echo "[$(date)][INFO] Requesting token from $keycloak_token_url"
  
  TOKEN=$(curl -k -s "$keycloak_token_url" \
    -d grant_type=password \
    -d response_type=id_token \
    -d scope=openid \
    -d client_id="$KEYCLOAK_CLIENT_ID" \
    -d client_secret="$KEYCLOAK_CLIENT_SECRET" \
    -d username="$KEYCLOAK_USERNAME" \
    -d password="$KEYCLOAK_PASSWORD" \
    -d totp="$KEYCLOAK_TOTP")

  ERROR=$(echo "$TOKEN" | jq .error -r)
  if [ "$ERROR" != "null" ];then
	  echo "[$(date)][ERROR]  $TOKEN" >&2
	  return 1
  fi
}

set_creds() {
  local id_token refresh_token
  id_token=$(echo "$TOKEN" | jq .id_token -r)
  refresh_token=$(echo "$TOKEN" | jq .refresh_token -r)
  
  echo "[$(date)][INFO] Adding user $KEYCLOAK_USERNAME to kube config"
  
  kubectl config set-credentials "$KEYCLOAK_USERNAME" \
    --auth-provider=oidc \
    --auth-provider-arg=idp-certificate-authority="$DIR/pki/keycloak-ca.pem" \
    --auth-provider-arg=idp-issuer-url="https://$KEYCLOAK_ADDRESS/auth/realms/$KEYCLOAK_AUTH_REALM" \
  	--auth-provider-arg=client-id="$KEYCLOAK_CLIENT_ID" \
  	--auth-provider-arg=client-secret="$KEYCLOAK_CLIENT_SECRET" \
  	--auth-provider-arg=id-token="$id_token" \
  	--auth-provider-arg=refresh-token="$refresh_token"
}

main() {
  install_jq
  get_creds
  get_token
  set_creds
}

main "$@"