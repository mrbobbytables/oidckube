#!/bin/bash
set -e
set -o pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
[[ ! -f "$DIR/config" ]] && cp "$DIR/config.example" "$DIR/config" 
# shellcheck source=config
source "$DIR/config"

CFSSL_RELEASE="1.2"
BIN_DIR="$DIR/bin"
PKI_DIR="$DIR/pki"
PKI_PROFILE_DIR="$DIR/pki-profiles"
TEMPLATE_DIR="$DIR/templates"
MANIFEST_DIR="$DIR/manifests"
PATH=$PATH:$BIN_DIR

install_cfssl() {
  command -v cfssljson >/dev/null 2>&1 && { echo "[$(date)][INFO] cfssl found."; return 0; }
  echo "[$(date)][WARNING] cfssl and cfssljson not found in path."
  if echo "$OSTYPE" | grep -q "darwin"; then
    echo "[$(date)][ERROR] cfssl not found. Please install with brew or 'go-get' See: https://github.com/cloudflare/cfssl/issues/813 for more information."
    return 1
  elif echo "$OSTYPE" | grep -q "linux"; then
    curl -SL "https://pkg.cfssl.org/R$CFSSL_RELEASE/cfssl_linux-amd64" -o "$BIN_DIR/cfssl"
    curl -SL "https://pkg.cfssl.org/R$CFSSL_RELEASE/cfssljson_linux-amd64" -o "$BIN_DIR/cfssljson"
    chmod +x "$BIN_DIR/"{cfssl,cfssljson}
  else
    echo "[$(date)][ERROR] Unsupported OS for dependency resolution. Please install cfssl manually."
    return 1
  fi
}

init_pki() {
  echo "[$(date)][INFO] Generating Certificates."
  sed -e "s|__KEYCLOAK_ADDRESS__|$KEYCLOAK_ADDRESS|g" \
    "$TEMPLATE_DIR/keycloak.json.tmplt" > "$PKI_PROFILE_DIR/keycloak.json"

  cfssl gencert -initca "$PKI_PROFILE_DIR/ca-csr.json" | cfssljson -bare "$PKI_DIR/keycloak-ca" -
  cfssl gencert \
    -ca="$PKI_DIR/keycloak-ca.pem" \
    -ca-key="$PKI_DIR/keycloak-ca-key.pem" \
    -config="$PKI_PROFILE_DIR/ca-config.json" \
    -profile=server \
    "$PKI_PROFILE_DIR/keycloak.json" | cfssljson -bare "$PKI_DIR/keycloak"
}

init_minikube() {
  echo "[$(date)][INFO] Initializing minikube."
  minikube start
  minikube addons enable ingress
  inject_keycloak_certs
  init_keycloak
  local instance_ip
  instance_ip="$(minikube ip)"
  while [ "$(kubectl get statefulset keycloak --template='{{.status.readyReplicas}}')" != "1" ]; do
    echo "[$(date)][INFO] Waiting for Keycloak to become ready."
    sleep 10
  done
  echo "[$(date)][INFO] Keycloak Deployed."
  echo "[$(date)][INFO] Add entry in /etc/hosts file before starting."
  echo "[$(date)][INFO] $instance_ip  $KEYCLOAK_ADDRESS"
}

inject_keycloak_certs() {
  tar -c -C "$PKI_DIR" keycloak-ca.pem | ssh -t -q -o StrictHostKeyChecking=no \
    -i "$(minikube ssh-key)" "docker@$(minikube ip)" 'sudo tar -x --no-same-owner -C /var/lib/localkube/certs'

}

init_keycloak() {
  sed -e "s|__KEYCLOAK_ADDRESS__|$KEYCLOAK_ADDRESS|g" \
    "$TEMPLATE_DIR/ing-keycloak.yaml.tmplt" > "$MANIFEST_DIR/ing-keycloak.yaml"
  kubectl create secret tls keycloak-cert --cert="$PKI_DIR/keycloak.pem" --key="$PKI_DIR/keycloak-key.pem"
  kubectl create -f manifests/
}

start_minikube() {
  VBoxManage modifyvm minikube --natdnshostresolver1 on
  minikube start \
    --extra-config=kubelet.serialize-image-pulls=false \
    --extra-config=apiserver.oidc-issuer-url=https://$KEYCLOAK_ADDRESS/auth/realms/$KEYCLOAK_AUTH_REALM \
    --extra-config=apiserver.oidc-client-id=$KEYCLOAK_CLIENT_ID \
    --extra-config=apiserver.oidc-username-claim=email \
    --extra-config=apiserver.oidc-username-prefix="oidc:" \
    --extra-config=apiserver.oidc-groups-claim=groups \
    --extra-config=apiserver.oidc-groups-prefix="oidc:" \
    --extra-config=apiserver.oidc-ca-file=/var/lib/localkube/certs/keycloak-ca.pem
}

main() {
  case "$1" in
    "init")
      install_cfssl
      init_pki
      init_minikube
      ;;
    "start")
      start_minikube
      ;;
    *)
      minikube "$@"
      ;;
  esac
}

main "$@"
