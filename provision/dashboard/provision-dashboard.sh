#!/bin/sh

log()   { echo ">>> $1" ; }
warn()  { log "WARNING: $1" ; }
abort() { log "FATAL: $1" ; exit 1 ; }

DEBUG=
FINISH=
E2E=
INFRA="cloud"
DOCKER_REG_MIRROR=
CONTAINER_START_TIMEOUT=300
SALT_ROOT=/tmp
SALT_ORCH_FLAGS=
CONFIG_OUT_DIR=/root

# the hostname and port where the API server will be listening at
API_SERVER_DNS_NAME="master"
API_SERVER_PORT=6443

# an (optional) extra IP for the API server (usually a floating IP)
API_SERVER_IP=

# kubernetes manifests location for the kubelet
K8S_MANIFESTS=/etc/kubernetes/manifests

# rpms and services neccessary in the dashboard
DASHBOARD_RPMS="kubernetes-node etcd"
DASHBOARD_SERVICES="docker kubelet etcd"

# global args for running zypper and ssh/scp
ZYPPER_GLOBAL_ARGS="-n --no-gpg-checks --quiet --no-color"
SSH_GLOBAL_ARGS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

########################################################################

# repository information
source /etc/os-release
case $NAME in
  "CAASP")
    CONTAINERS_REPO="http://download.opensuse.org/repositories/Virtualization:/containers/SLE_12_SP1/"
    ;;
  *)
    CONTAINERS_REPO="http://download.opensuse.org/repositories/Virtualization:/containers/$(echo -n $PRETTY_NAME | tr " " "_")"
    ;;
esac


while [ $# -gt 0 ] ; do
  case $1 in
    --debug)
      set -x
      DEBUG=1
      SALT_ORCH_FLAGS="$SALT_ORCH_FLAGS -l debug"
      ;;
    --color)
      SALT_ORCH_FLAGS="$SALT_ORCH_FLAGS --force-color"
      ;;
    -r|--root)
      SALT_ROOT=$2
      shift
      ;;
    -F|--finish)
      FINISH=1
      ;;
    --e2e)
      E2E=1
      ;;
    --config-out-dir)
      CONFIG_OUT_DIR=$2
      shift
      ;;
    --docker-reg-mirror)
      DOCKER_REG_MIRROR=$2
      shift
      ;;
    -i|--infra)
      INFRA=$2
      shift
      ;;
    -D|--dashboard)
      DASHBOARD_REF=$2
      shift
      ;;
    --api-server-ip)
      API_SERVER_IP=$2
      shift
      ;;
    --api-server-name)
      API_SERVER_DNS_NAME=$2
      shift
      ;;
    *)
      abort "Unknown argument $1"
      ;;
  esac
  shift
done

###################################################################

PILLAR_PARAMS_FILE=$SALT_ROOT/salt/pillar/params.sls

add_pillar() {
    log "Pillar: setting $1=\"$2\""
    mkdir -p $(dirname $PILLAR_PARAMS_FILE)
    cat <<-PARAM_SETTING >> "$PILLAR_PARAMS_FILE"

# parameter set by $0
$1: '$2'

PARAM_SETTING
}

wait_for_container() {
  local count=0
  until docker ps | grep -v pause | grep "$1" &> /dev/null ; do
      log "Waiting for $2 container to start"
      if [ "$count" -gt "$CONTAINER_START_TIMEOUT" ] ; then
          [ -n "$DEBUG" ] && docker ps
          abort "Container $2 didn't start, giving up..."
      fi
      sleep 5
      count=$((count+5))
  done
  log "$2 container is up"
}

if [ -z "$FINISH" ] ; then
    log "Fixing the ssh keys permissions and setting the authorized keys"
    chmod 600 /root/.ssh/*
    cp -f /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys

    log "Setting some Pillars..."
    [ -n "$INFRA"             ] && add_pillar infrastructure "$INFRA"
    [ -n "$DASHBOARD_REF"     ] && add_pillar dashboard "$DASHBOARD_REF"
    [ -n "$E2E"               ] && add_pillar e2e true
    [ -n "$DOCKER_REG_MIRROR" ] && add_pillar docker_registry_mirror "$DOCKER_REG_MIRROR"

    log "Adding containers repository"
    zypper $ZYPPER_GLOBAL_ARGS ar -Gf "$CONTAINERS_REPO" containers || abort "could not enable containers repo"

    log "Installing kubernetes-node"
    zypper $ZYPPER_GLOBAL_ARGS in -y $DASHBOARD_RPMS || abort "could not install packages"

    # TODO: this would have to be removed...
    mkdir -p "$K8S_MANIFESTS"
    echo "KUBELET_ARGS=\"--config=$K8S_MANIFESTS\"" > /etc/kubernetes/kubelet

    sed -i 's@#\?ETCD_LISTEN_PEER_URLS.*@ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380@' /etc/sysconfig/etcd
    sed -i 's@#\?ETCD_LISTEN_CLIENT_URLS.*@ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379@' /etc/sysconfig/etcd
    sed -i 's@#\?ETCD_ADVERTISE_CLIENT_URLS.*@ETCD_ADVERTISE_CLIENT_URLS=http://dashboard:2379@' /etc/sysconfig/etcd

    systemctl restart etcd
    [ $? -eq 0 ] || abort "could not restart etcd"

    # Set persistent storage for salt master container
    mkdir -p /tmp/salt/master-pki
    # Set persistent storage for salt minion certificate authority container
    mkdir -p /tmp/salt/minion-ca-pki && touch /tmp/salt/minion-ca-id

    for srv in $DASHBOARD_SERVICES ; do
      systemctl start "$srv.service"  || abort "could not start service $srv"
      systemctl enable "$srv.service" || abort "could not enable service $srv"
    done

    # Wait for containers to be ready
    wait_for_container "k8s_salt-master"     "salt master"
    wait_for_container "k8s_salt-minion-ca"  "certificate authority"
    wait_for_container "k8s_velum-mariadb"   "mariadb database"
    wait_for_container "k8s_velum-dashboard" "velum dashboard"
else
    VELUM_CONTAINER=`docker ps | grep k8s_velum-dashboard | awk '{print $1}'`
    SALT_MASTER_CONTAINER=`docker ps | grep k8s_salt-master | awk '{print $1}'`
    CA_CONTAINER=`docker ps | grep k8s_salt-minion-ca | awk '{print $1}'`

    [ -n "$VELUM_CONTAINER" ]       || abort "could not get velum container"
    [ -n "$SALT_MASTER_CONTAINER" ] || abort "could not get salt master container"
    [ -n "$CA_CONTAINER" ]          || abort "could not get certificate authority container"

    log "Setting up the database on velum container ($VELUM_CONTAINER)"
    docker exec "$VELUM_CONTAINER" rake db:setup
    [ $? -eq 0 ] || abort "database could not be setup"

    log "Running orchestration on salt master container ($SALT_MASTER_CONTAINER)"
    docker exec "$SALT_MASTER_CONTAINER" salt-run $SALT_ORCH_FLAGS state.orchestrate orch.kubernetes
    [ $? -eq 0 ] || abort "salt-run did not succeed"

    if [ -z "$API_SERVER_IP" ] ; then
        API_SERVER_IP=$(host "$API_SERVER_DNS_NAME" | grep "has address" | awk '{print $NF}')
        [ -n "$API_SERVER_IP" ] || abort "could not determine the IP of the API server by resolving $API_SERVER_DNS_NAME: you must provide it with --api-server-ip"
    fi

    log "Generating a 'kubeconfig' file"
    cat <<EOF > "$CONFIG_OUT_DIR/kubeconfig"
apiVersion: v1
clusters:
- cluster:
    certificate-authority: ca.crt
    server: https://${API_SERVER_IP}:${API_SERVER_PORT}/
  name: default-cluster
contexts:
- context:
    cluster: default-cluster
    user: default-admin
  name: default-system
current-context: default-system
kind: Config
preferences: {}
users:
- name: default-admin
  user:
    client-certificate: admin.crt
    client-key: admin.key
EOF

    log "Creating admin.tar with config files and certificates"
    scp $SSH_GLOBAL_ARGS $API_SERVER_IP:/etc/pki/minion.{crt,key} "$CONFIG_OUT_DIR"
    [ $? -eq 0 ] || abort "could not copy file from master"

    mv -f "$CONFIG_OUT_DIR/minion.crt" "$CONFIG_OUT_DIR/admin.crt"
    mv -f "$CONFIG_OUT_DIR/minion.key" "$CONFIG_OUT_DIR/admin.key"

    docker cp "$CA_CONTAINER:/etc/pki/ca.crt" "$CONFIG_OUT_DIR/ca.crt"
    [ $? -eq 0 ] || abort "could not copy file from $CA_CONTAINER"

    cd "$CONFIG_OUT_DIR" && tar cvpf admin.tar admin.crt admin.key ca.crt kubeconfig
    [ -f admin.tar ] || abort "admin.tar not generated"

    log "'kubeconfig' file with certificates left at dashboard:$CONFIG_OUT_DIR/admin.tar"
    log "Now you can"
    log "* copy $CONFIG_OUT_DIR/admin.tar to your machine"
    log "* tar -xvpf admin.tar"
    log "* KUBECONFIG=kubeconfig kubectl get nodes"
    log ""
    log "note: we assumed the API server is at https://${API_SERVER_IP}:${API_SERVER_PORT},"
    log "      so check 'kubeconfig' configuration before using it..."
fi

exit 0
