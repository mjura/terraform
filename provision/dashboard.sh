#!/bin/sh

log()   { echo ">>> $1" ; }
warn()  { log "WARNING: $1" ; }
abort() { log "FATAL: $1" ; exit 1 ; }

DEBUG=
FINISH=
E2E=
INFRA="cloud"
DOCKER_REG=
CONTAINER_START_TIMEOUT=300
SALT_ORCH_FLAGS=
CONFIG_OUT_DIR=/root

# the hostname and port where the API server will be listening at
API_SERVER_DNS_NAME="master"
API_SERVER_PORT=6443

# an (optional) extra IP for the API server (usually a floating IP)
API_SERVER_IP=

# some ports we use for detecting a service is running
SALT_MASTER_PORT=4505
SALT_API_PORT=8000

# kubernetes manifests locations
K8S_MANIFESTS_IN="/usr/share/caasp-container-manifests"
K8S_MANIFESTS_OUT="/etc/kubernetes/manifests"

# rpms and services neccessary in the dashboard
DASHBOARD_RPMS="kubernetes-kubelet etcd"
DASHBOARD_SERVICES="docker container-feeder kubelet etcd"

# global args for running zypper and ssh/scp
ZYPPER_GLOBAL_ARGS="-n --no-gpg-checks --quiet --no-color"
SSH_GLOBAL_ARGS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# comma-separated list of pillar assignments (with ~ as =), like
# etcd.master~1,api.cluster_ip~172.21.0.1
PILLAR=

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
    --docker-reg)
      DOCKER_REG=$2
      shift
      ;;
    -i|--infra)
      INFRA=$2
      shift
      ;;
    -D|--dashboard)
      DASHBOARD_HOST=$2
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
    -P|--pillar)
      PILLAR=$2
      shift
      ;;
    *)
      abort "Unknown argument $1"
      ;;
  esac
  shift
done

###################################################################


# replacements to do in the etcd config
ETCD_REPL="s|#\?ETCD_LISTEN_PEER_URLS.*|ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380|g; \
           s|#\?ETCD_LISTEN_CLIENT_URLS.*|ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379|g; \
           s|#\?ETCD_ADVERTISE_CLIENT_URLS.*|ETCD_ADVERTISE_CLIENT_URLS=http://dashboard:2379|g"

get_container() {
  docker ps | grep $1 | awk '{print $1}'
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

exec_in_container() {
  local c=$(get_container $1)
  [ -n "$c" ] || abort "could not get $1 container"
  shift
  docker exec "$c" "$@" || abort "could not run in $c: $@"
}

copy_from_container() {
  local c=$(get_container $1)
  [ -n "$c" ] || abort "could not get $1 container"
  docker cp "$c:$2" "$3" || abort "could not copy file from $c:$2 to $3"
}

add_pillar() {
  log "Pillar: setting $1=\"$2\""
  exec_in_container "k8s_velum-dashboard" \
    bundle exec rails runner "Pillar.create pillar: \"$1\", value: \"$2\""
}

add_pillar_from_lst() {
  for x in `echo "$1" | tr ',' ' '` ; do
    add_pillar "${x%~*}" "${x#*~}"
  done
}

tcp_port_open() {
  netstat -aln | awk '$6 == "LISTEN" && $4 ~ "[\\.\\:]'$1'$"' | grep -q tcp &> /dev/null
}

wait_for_port() {
  local port=$1
  local count=0
  until tcp_port_open "$port" ; do
    log "(waiting for port $port to be open...)"
    sleep 5
    [ "$count" -gt "$CONTAINER_START_TIMEOUT" ] && abort "timeout waiting for port $port"
    count=$((count+5))
  done
}

wait_for_socket() {
  local socket=$1
  local count=0
  until [ -S $socket ] ; do
    log "(waiting for socket $socket to be created...)"
    sleep 5
    [ "$count" -gt "$CONTAINER_START_TIMEOUT" ] && abort "timeout waiting for socket $socket"
    count=$((count+5))
  done
}

get_ip_for() {
  getent hosts "$1" | cut -f1 -d" "
}

service_exist()   { systemctl list-unit-files | grep -q "$1.service" &> /dev/null ; }
service_running() { systemctl status $1 | grep -q running &> /dev/null ; }

copy_manifest() { cp "$1" "$2" ; }
copy_etcd_cfg() { sed -e "$ETCD_REPL"  "$1" > "$2" ; }

###################################################################

if [ -z "$FINISH" ] ; then
    log "Fixing the ssh keys permissions and setting the authorized keys"
    chmod 600 /root/.ssh/*
    cp -f /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys

    case $NAME in
      "CAASP")
        # do not try to install anything in CaaSP hosts
        log "Skipping installations"
        ;;
      *)
        log "Adding containers repository"
        zypper $ZYPPER_GLOBAL_ARGS ar -Gf "$CONTAINERS_REPO" containers || abort "could not enable containers repo"

        log "Installing kubernetes-node"
        zypper $ZYPPER_GLOBAL_ARGS in -y $DASHBOARD_RPMS || abort "could not install packages"
        ;;
    esac

    log "Copying kubelet manifests"
    service_running "kubelet" && systemctl stop kubelet
    for f in $K8S_MANIFESTS_IN/*.yaml ; do
      proc_manif="$K8S_MANIFESTS_OUT/$(basename $f)"
      log "... generating $proc_manif"
      copy_manifest "$f" "$proc_manif"
    done

    log "Tweaking etcd config"
    service_running "etcd" && systemctl stop etcd
    copy_etcd_cfg /etc/sysconfig/etcd /etc/sysconfig/etcd.new && mv /etc/sysconfig/etcd.new /etc/sysconfig/etcd

    log "Generate certificates for salt-api and velum"
    log "WARNING!!! This is part activate.sh script,"
    log "which is not run by terraform deployment"
    /usr/share/caasp-container-manifests/gen-certs.sh    

    log "Starting services..."
    for srv in $DASHBOARD_SERVICES ; do
      if service_exist "$srv" ; then
        log "... starting $srv"
        systemctl start "$srv.service"  || abort "could not start service $srv"
        systemctl enable "$srv.service" || abort "could not enable service $srv"
      else
        warn "could not enable & start $srv: not installed !!"
      fi
    done

    # some dependencies between containers:
    # salt-master REQUIRES mariadb
    # velum       REQUIRES mariadb
    # salt-ca     REQUIRES salt-master
    # salt-api    REQUIRES salt-master
    # velum       REQUIRES salt-api

    # Wait for containers to be ready
    wait_for_container "k8s_velum-mariadb"         "mariadb database"
    wait_for_socket "/var/run/mysql/mysql.sock"
    wait_for_container "k8s_salt-master"           "salt master"
    wait_for_port $SALT_MASTER_PORT
    wait_for_container "k8s_salt-minion-ca"        "certificate authority"
    wait_for_container "k8s_salt-api"              "API server"
    wait_for_port $SALT_API_PORT
    wait_for_container "k8s_velum-dashboard"       "velum dashboard"
    wait_for_container "k8s_velum-event-processor" "events processor"

    log "Setting up the database on velum container"
    exec_in_container "k8s_velum-dashboard" rake db:setup

    log "Removing all Salt keys in the master"
    exec_in_container "k8s_salt-master" salt-key -y --delete-all

    log "Setting some Pillars..."
    [ -n "$INFRA"          ] && add_pillar infrastructure "$INFRA"
    [ -n "$DASHBOARD_HOST" ] && add_pillar dashboard "$DASHBOARD_HOST"
    [ -n "$E2E"            ] && add_pillar e2e true
    [ -n "$DOCKER_REG"     ] && add_pillar docker:registry "$DOCKER_REG"
    add_pillar_from_lst "$PILLAR"
else
    log "Accept all Salt keys in the master"
    exec_in_container "k8s_salt-master" salt-key -A -y

    log "Running orchestration on salt master container"
    exec_in_container "k8s_salt-master" salt-run $SALT_ORCH_FLAGS state.orchestrate orch.kubernetes

    # we create a kubeconfig where the API server is specified with an IP
    # because maybe the clients using this kubeconfig will not be able
    # to resolve something like "master"...
    if [ -z "$API_SERVER_IP" ] ; then
        API_SERVER_IP=$(get_ip_for "$API_SERVER_DNS_NAME")
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
    scp $SSH_GLOBAL_ARGS $API_SERVER_IP:/etc/pki/minion.{crt,key} "$CONFIG_OUT_DIR" || abort "could not copy file from master"

    mv -f "$CONFIG_OUT_DIR/minion.crt" "$CONFIG_OUT_DIR/admin.crt"
    mv -f "$CONFIG_OUT_DIR/minion.key" "$CONFIG_OUT_DIR/admin.key"

    copy_from_container "k8s_salt-minion-ca" "/etc/pki/ca.crt" "$CONFIG_OUT_DIR/ca.crt"

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
