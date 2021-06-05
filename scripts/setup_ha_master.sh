#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(realpath "$(dirname "$(dirname "$0")")")"

if test -f "$PROJECT_DIR/.env.local"; then
  source "$PROJECT_DIR/.env.local"
fi

master_name="$1"

if test -z "$PROJECT_DIR" ; then
  echo "error: env: PROJECT_DIR not set"
  exit 1
fi

if test -z "$master_name" ; then
  echo "error: provide worker name (e.g. master1)"
  exit 1
fi

if test "$master_name" = 'master0'; then
  echo "error: do not use with master0"
  exit 1
fi

if [[ ! "$master_name" =~ ^master ]]; then
  echo "error: do not use with worker nodes"
  exit 1
fi

HOST_V4_LIST="$(terraform -chdir="$PROJECT_DIR/terraform" output -json host_v4_list)"

ssh \
  -i "$SSH_PRIVATE_KEY_PATH" \
  "work@$(echo "$HOST_V4_LIST" | jq -r ".$master_name")" \
  'sudo rm -rf /etc/kubernetes/pki'

ssh \
  -i "$SSH_PRIVATE_KEY_PATH" \
  "work@$(echo "$HOST_V4_LIST" | jq -r .master0)" \
  '
    cd /etc/kubernetes \
    && sudo tar czf - \
      pki/ca.crt \
      pki/ca.key \
      pki/sa.pub \
      pki/sa.key \
      pki/front-proxy-ca.crt \
      pki/front-proxy-ca.key \
      pki/etcd/ca.crt \
      pki/etcd/ca.key \
  ' \
| ssh \
  -i "$SSH_PRIVATE_KEY_PATH" \
  "work@$(echo "$HOST_V4_LIST" | jq -r ".$master_name")" \
  'sudo tar xzf - -C /etc/kubernetes'
