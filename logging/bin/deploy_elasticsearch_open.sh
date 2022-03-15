#! /bin/bash

# Copyright © 2020, SAS Institute Inc., Cary, NC, USA.  All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

cd "$(dirname $BASH_SOURCE)/../.."
source logging/bin/common.sh
source logging/bin/secrets-include.sh
source bin/tls-include.sh
source logging/bin/apiaccess-include.sh

this_script=`basename "$0"`

log_debug "Script [$this_script] has started [$(date)]"

ELASTICSEARCH_ENABLE=${ELASTICSEARCH_ENABLE:-true}

if [ "$ELASTICSEARCH_ENABLE" != "true" ]; then
  log_verbose "Environment variable [ELASTICSEARCH_ENABLE] is not set to 'true'; exiting WITHOUT deploying Open Distro for Elasticsearch"
  exit 0
fi

set -e

#
# check for pre-reqs
#

checkDefaultStorageClass

# Confirm namespace exists
if [ "$(kubectl get ns $LOG_NS -o name 2>/dev/null)" == "" ]; then
  log_error "Namespace [$LOG_NS] does NOT exist."
  exit 1
fi

# get credentials
export ES_ADMIN_PASSWD=${ES_ADMIN_PASSWD}
export ES_KIBANASERVER_PASSWD=${ES_KIBANASERVER_PASSWD}
export ES_LOGCOLLECTOR_PASSWD=${ES_LOGCOLLECTOR_PASSWD}
export ES_METRICGETTER_PASSWD=${ES_METRICGETTER_PASSWD}

# Create secrets containing internal user credentials
create_user_secret internal-user-admin        admin        "$ES_ADMIN_PASSWD"         managed-by=v4m-es-script
create_user_secret internal-user-kibanaserver kibanaserver "$ES_KIBANASERVER_PASSWD"  managed-by=v4m-es-script
create_user_secret internal-user-logcollector logcollector "$ES_LOGCOLLECTOR_PASSWD"  managed-by=v4m-es-script
create_user_secret internal-user-metricgetter metricgetter "$ES_METRICGETTER_PASSWD"  managed-by=v4m-es-script

# Verify cert-manager is available (if necessary)
if verify_cert_manager $LOG_NS es-transport es-rest es-admin kibana; then
  log_debug "cert-manager check OK"
else
  log_error "One or more required TLS certs do not exist and cert-manager is not available to create the missing certs"
  exit 1
fi

# Create/Get necessary TLS certs
apps=( es-transport es-rest es-admin kibana )
create_tls_certs $LOG_NS logging ${apps[@]}

# Create ConfigMap for securityadmin script
if [ -z "$(kubectl -n $LOG_NS get configmap run-securityadmin.sh -o name 2>/dev/null)" ]; then
  kubectl -n $LOG_NS create configmap run-securityadmin.sh --from-file logging/es/odfe/bin/run_securityadmin.sh
  kubectl -n $LOG_NS label  configmap run-securityadmin.sh managed-by=v4m-es-script
else
  log_verbose "Using existing ConfigMap [run-securityadmin.sh]"
fi

# Need to retrieve these from secrets in case secrets pre-existed
export ES_ADMIN_USER=$(kubectl -n $LOG_NS get secret internal-user-admin -o=jsonpath="{.data.username}" |base64 --decode)
export ES_ADMIN_PASSWD=$(kubectl -n $LOG_NS get secret internal-user-admin -o=jsonpath="{.data.password}" |base64 --decode)
export ES_METRICGETTER_USER=$(kubectl -n $LOG_NS get secret internal-user-metricgetter -o=jsonpath="{.data.username}" |base64 --decode)
export ES_METRICGETTER_PASSWD=$(kubectl -n $LOG_NS get secret internal-user-metricgetter -o=jsonpath="{.data.password}" |base64 --decode)

# Generate message about autogenerated admin password
adminpwd_autogenerated=$(kubectl -n $LOG_NS get secret internal-user-admin   -o jsonpath='{.metadata.labels.autogenerated_password}')
if [ ! -z "$adminpwd_autogenerated"  ]; then
   # Print info about how to obtain admin password

   add_notice "                                                                    "
   add_notice "**The Kibana 'admin' Account**"
   add_notice "Generated 'admin' password:  $ES_ADMIN_PASSWD                       "
   add_notice "To change the password for the 'admin' account at any time, run the "
   add_notice "following command:                                                  "
   add_notice "                                                                    "
   add_notice "    logging/bin/change_internal_password.sh admin newPassword       "
   add_notice "                                                                    "
   add_notice "NOTE: *NEVER* change the password for the 'admin' account from within the"
   add_notice "Kibana web-interface.  The 'admin' password should *ONLY* be changed via "
   add_notice "the change_internal_password.sh script in the logging/bin sub-directory."
   add_notice "                                                                    "

   LOGGING_DRIVER=${LOGGING_DRIVER:-false}
   if [ "$LOGGING_DRIVER" != "true" ]; then
      echo ""
      display_notices
      echo ""
   fi
fi


# enable debug on Helm via env var
export HELM_DEBUG="${HELM_DEBUG:-false}"

if [ "$HELM_DEBUG" == "true" ]; then
  helmDebug="--debug"
fi

helm2ReleaseCheck odfe-$LOG_NS

# Check for existing Open Distro helm release
if [ "$(helm -n $LOG_NS list --filter 'odfe' -q)" == "odfe" ]; then
   log_debug "A Helm release [odfe] exists; upgrading the release."
   existingODFE="true"

   #Migrate Kibana content if upgrading from ODFE 1.7.0 to 1.13.x
   if [ "$(helm -n $LOG_NS list -o yaml --filter odfe |grep app_version)" == "- app_version: 1.8.0" ]; then

      # Prior to 1.1.0 we used ODFE 1.7.0
      log_info "Migrating from Open Distro for Elasticsearch 1.7.0"

      #export exisiting content from global tenant
      #KB_GLOBAL_EXPORT_FILE="$TMP_DIR/kibana_global_content.ndjson"

      log_debug "Exporting exisiting content from global tenant to temporary file [$KB_GLOBAL_EXPORT_FILE]."

      set +e
      get_kb_api_url
      #set -e

      content2export='{"type": ["config", "url","visualization", "dashboard", "search", "index-pattern"],"excludeExportDetails": false}'

      response=$(curl -s -o $KB_GLOBAL_EXPORT_FILE  -w  "%{http_code}" -XPOST "${kb_api_url}/api/saved_objects/_export" -d "$content2export"  -H "kbn-xsrf: true" -H 'Content-Type: application/json' -u $ES_ADMIN_USER:$ES_ADMIN_PASSWD -k)

      if [[ $response != 2* ]]; then
         log_warn "There was an issue exporting the existing content from Kibana [$response]"
         log_debug "Failed response details: $(tail -n1 $KB_GLOBAL_EXPORT_FILE)"
         #TODO: Exit here?  Display messages as shown?  Add BIG MESSAGE about potential loss of content?
      else
         log_info "Existing Kibana content cached for migration. [$response]"
         log_debug "Export details: $(tail -n1 $KB_GLOBAL_EXPORT_FILE)"
      fi

      # ODFE 1.13.x uses a different name for Kibana ingress object,
      # Helm update will fail if original ingress resource exists
      kubectl -n $LOG_NS delete ingress v4m-es-kibana --ignore-not-found

   fi


   # Check to see if Nodeport for Elasticsearch API has been enabled
   # If so, Will be re-enabled at end of script
   ES_PORT=$(kubectl -n $LOG_NS get service v4m-es-client-service -o=jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null)
   if [ -n "$ES_PORT" ]; then
      log_debug "NodePort for Elasticsearch detected [$ES_PORT]"
      logging/bin/es_nodeport_disable_open.sh
      ES_NODEPORT_ENABLE=true
      export ES_PORT
   fi
else
   log_debug "A Helm release [odfe] do NOT exist; deploying a new release."
   existingODFE="false"
fi

# Elasticsearch user customizations
ES_OPEN_USER_YAML="${ES_OPEN_USER_YAML:-$USER_DIR/logging/user-values-elasticsearch-open.yaml}"
if [ ! -f "$ES_OPEN_USER_YAML" ]; then
  log_debug "[$ES_OPEN_USER_YAML] not found. Using $TMP_DIR/empty.yaml"
  ES_OPEN_USER_YAML=$TMP_DIR/empty.yaml
fi

# Kibana user customizations
# NOTE: There is not KIBANA_OPEN_USER_YAML equivalent because
# Kibana is deployed as part of the Elasticsearch Helm chart
# User values for Kibana should be included in the ES_OPEN_USER_YAML


# Require TLS into Kibana?
LOG_KB_TLS_ENABLE=${LOG_KB_TLS_ENABLE:-false}

# Enable TLS for East/West Kibana traffic (inc. requiring HTTPS from browser if using NodePorts)
if [ "$LOG_KB_TLS_ENABLE" == "true" ]; then
   # Kibana TLS-specific Helm chart values currently maintained in separate YAML file
   KB_OPEN_TLS_YAML=logging/es/odfe/es_helm_values_kb_tls_open.yaml
   # w/TLS: use HTTPS in curl commands
   KB_CURL_PROTOCOL=https
   log_debug "TLS enabled for Kibana"
else
   # point to an empty yaml file
   KB_OPEN_TLS_YAML=$TMP_DIR/empty.yaml
   # w/o TLS: use HTTP in curl commands
   KB_CURL_PROTOCOL=http
   log_debug "TLS not enabled for Kibana"
fi


# Create secrets containing SecurityConfig files
create_secret_from_file securityconfig/action_groups.yml   security-action-groups   managed-by=v4m-es-script
create_secret_from_file securityconfig/config.yml          security-config          managed-by=v4m-es-script
create_secret_from_file securityconfig/internal_users.yml  security-internal-users  managed-by=v4m-es-script
create_secret_from_file securityconfig/roles.yml           security-roles           managed-by=v4m-es-script
create_secret_from_file securityconfig/roles_mapping.yml   security-roles-mapping   managed-by=v4m-es-script
create_secret_from_file securityconfig/tenants.yml         security-tenants         managed-by=v4m-es-script


# Open Distro for Elasticsearch
log_info "Deploying Open Distro for Elasticsearch"

odfe_tgz_file=opendistro-es-1.13.3.tgz

baseDir=$(pwd)
if [ ! -f "$TMP_DIR/$odfe_tgz_file" ]; then
   cd $TMP_DIR

   rm -rf $TMP_DIR/opendistro-build
   log_verbose "Cloning Open Distro for Elasticsearch repo"
   git clone https://github.com/opendistro-for-elasticsearch/opendistro-build

   cd opendistro-build
   git checkout b8f35fe


   # Patch ingress objects to networking.k8s.io/v1 for 1.22 compatibility
   log_debug "Updating ODFE ingress templates"
   cp $baseDir/logging/es/odfe/ingress-patch/kibana-ingress.yml helm/opendistro-es/templates/kibana/kibana-ingress.yml
   cp $baseDir/logging/es/odfe/ingress-patch/es-client-ingress.yaml helm/opendistro-es/templates/elasticsearch/es-client-ingress.yaml

   # Update old Kubernetes role versions to support 1.22+
   log_debug "Patching OpenDistro helm chart resource versions"
   roleFiles=( \
      "helm/opendistro-es/templates/elasticsearch/role.yaml" \
      "helm/opendistro-es/templates/kibana/role.yaml" \
   )
   for f in ${roleFiles[@]}; do
      log_debug "Updating Role template file [$f]"
      if echo "$OSTYPE" | grep 'darwin' > /dev/null 2>&1; then
         sed -i '' "s/apiVersion: rbac.authorization.k8s.io\/v1beta1/apiVersion: rbac.authorization.k8s.io\/v1/g" $f
      else
         sed -i "s/apiVersion: rbac.authorization.k8s.io\/v1beta1/apiVersion: rbac.authorization.k8s.io\/v1/g" $f
      fi
   done

   # build package
   log_debug "Packaging Helm Chart for Elasticsearch"

   cd helm/opendistro-es/
   helm package .

   # move .tgz file to $TMP_DIR
   mv $odfe_tgz_file $TMP_DIR/$odfe_tgz_file

   # return to working dir
   cd $baseDir

   # remove repo directories
   rm -rf $TMP_DIR/opendistro-build
fi

# Enable workload node placement?
LOG_NODE_PLACEMENT_ENABLE=${LOG_NODE_PLACEMENT_ENABLE:-${NODE_PLACEMENT_ENABLE:-false}}

# Optional workload node placement support
if [ "$LOG_NODE_PLACEMENT_ENABLE" == "true" ]; then
  log_verbose "Enabling elasticsearch for workload node placement"
  wnpValuesFile="logging/node-placement/values-elasticsearch-open-wnp.yaml"
else
  log_debug "Workload node placement support is disabled for elasticsearch"
  wnpValuesFile="$TMP_DIR/empty.yaml"
fi

ES_PATH_INGRESS_YAML=$TMP_DIR/empty.yaml
if [ "$OPENSHIFT_CLUSTER:$OPENSHIFT_PATH_ROUTES" == "true:true" ]; then
    ES_PATH_INGRESS_YAML=logging/openshift/values-elasticsearch-path-route-openshift.yaml
fi

# Deploy Elasticsearch via Helm chart
helm $helmDebug upgrade --install odfe \
    --namespace $LOG_NS \
    --values logging/es/odfe/es_helm_values_open.yaml \
    --values "$KB_OPEN_TLS_YAML" \
    --values "$wnpValuesFile" \
    --values "$ES_OPEN_USER_YAML" \
    --values "$ES_PATH_INGRESS_YAML" \
    --set fullnameOverride=v4m-es $TMP_DIR/$odfe_tgz_file

# Use multi-purpose Elasticsearch nodes?
ES_MULTIROLE_NODES=${ES_MULTIROLE_NODES:-false}

# switch to multi-role ES nodes (if enabled)
if [ "$ES_MULTIROLE_NODES" == "true" ]; then

   sleep 10
   log_debug "Configuring Elasticsearch to use multi-role nodes"

   # Reconfigure 'master' nodes to be 'multi-role' nodes (i.e. support master, data and client roles)
   log_debug "Patching statefulset [v4m-es-master]"
   kubectl -n $LOG_NS patch statefulset v4m-es-master --patch "$(cat logging/es/odfe/es_multirole_nodes_patch.yml)"

   # Delete existing (unpatched) master pod
   kubectl -n $LOG_NS delete pod v4m-es-master-0 --ignore-not-found

   # By default, there will be no single-role 'client' or 'data' nodes; but patching corresponding
   # K8s objects to ensure proper labels are used in case user chooses to configure additional single-role nodes
   log_debug "Patching deployment [v4m-es-client]"
   kubectl -n $LOG_NS patch deployment v4m-es-client --type=json --patch '[{"op": "add","path": "/spec/template/metadata/labels/esclient","value": "true" }]'

   log_debug "Patching statefulset [v4m-es-data]"
   kubectl -n $LOG_NS patch statefulset v4m-es-data  --type=json --patch '[{"op": "add","path": "/spec/template/metadata/labels/esdata","value": "true" }]'

   # patching 'client' and 'data' _services_ to use new multi-role labels for node selection
   log_debug "Patching  service [v4m-es-client-service]"
   kubectl -n $LOG_NS patch service v4m-es-client-service --type=json --patch '[{"op": "remove","path": "/spec/selector/role"},{"op": "add","path": "/spec/selector/esclient","value": "true" }]'

   log_debug "Patching  service [v4m-es-data-service]"
   kubectl -n $LOG_NS patch service v4m-es-data-svc --type=json --patch '[{"op": "remove","path": "/spec/selector/role"},{"op": "add","path": "/spec/selector/esdata","value": "true" }]'
else
   log_debug "**********************************>Multirole Flag: $ES_MULTIROLE_NODES"
fi

# waiting for PVCs to be bound
declare -i pvcCounter=0
pvc_status=$(kubectl -n $LOG_NS get pvc  data-v4m-es-master-0  -o=jsonpath="{.status.phase}")
until [ "$pvc_status" == "Bound" ] || (( $pvcCounter>90 )); 
do 
   sleep 5
   pvcCounter=$((pvcCounter+5))
   pvc_status=$(kubectl -n $LOG_NS get pvc data-v4m-es-master-0 -o=jsonpath="{.status.phase}")
done

# Confirm PVC is "bound" (matched) to PV

if [ "$pvc_status" != "Bound" ];  then
      log_error "It appears that the PVC [data-v4m-es-master-0] associated with the [v4m-es-master-0] node has not been bound to a PV."
      log_error "The status of the PVC is [$pvc_status]"
      log_error "After ensuring all claims shown as Pending can be satisfied; run the remove_elasticsearch_open.sh script and try again."
      exit 1
fi
log_verbose "The PVC [data-v4m-es-master-0] have been bound to PVs"

log_info "Waiting on Elasticsearch pods to be Ready ($(date) - timeout 10m)"
kubectl -n $LOG_NS wait pods v4m-es-master-0 --for=condition=Ready --timeout=10m

# TO DO: Convert to curl command to detect ES is up?
# hitting https:/host:port -u adminuser:adminpwd --insecure 
# returns "Open Distro Security not initialized." and 503 when up

log_verbose "Waiting [2] minutes to allow Elasticsearch to initialize [$(date)]"
sleep 120

set +e

# Run the security admin script on the pod
# Add some logic to find ES release
if [ "$existingODFE" == "false" ]; then
  kubectl -n $LOG_NS exec v4m-es-master-0 -- config/run_securityadmin.sh

  # Retrieve log file from security admin script
  kubectl -n $LOG_NS cp v4m-es-master-0:config/run_securityadmin.log $TMP_DIR/run_securityadmin.log
  
  if [ "$(tail -n1  $TMP_DIR/run_securityadmin.log)" == "Done with success" ]; then
    log_verbose "The run_securityadmin.log script appears to have run successfully; you can review its output below:"
  else
    log_warn "There may have been a problem with the run_securityadmin.log script; review the output below:"
  fi
  # show output from run_securityadmin.sh script
  sed 's/^/   | /' $TMP_DIR/run_securityadmin.log
else
  log_verbose "Existing Open Distro release found. Skipping Elasticsearh security initialization."
fi


# (Re-)Enable Nodeport for Elasticsearch API?
ES_NODEPORT_ENABLE=${ES_NODEPORT_ENABLE:-false}
if [ "$ES_NODEPORT_ENABLE" == "true" ]; then
   log_debug "(Re)Enabling NodePort for Elasticsearch"
   SHOW_ES_URL=false logging/bin/es_nodeport_enable_open.sh
fi

set -e

log_info "Open Distro for Elasticsearch has been deployed"

log_debug "Script [$this_script] has completed [$(date)]"
echo ""
