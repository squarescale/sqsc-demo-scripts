#!/usr/bin/env bash
#
# See http://docs.squarescale.com/CLI.html for more informations about sqsc CLI
#
# This script is used to deploy the SquareScale Edge demo
#
# If a parameter is passed on the command line, it is taken as the name of the project
# to be created
#
# It can also be customized via a set of environment variables
#
# SQSC_ENDPOINT: target SquareScale platform endpoint (defaults to empty aka https://www.squarescale.io)
#
# SQSC_TOKEN: security token generated via API Keys menu on platform endpoint
# and used to run `sqsc login` successfully
#
# DRY_RUN: default to empty. Setting this to anything will show calls to be made by sqsc instead of
#	running them
#
# VM_SIZE: (small, medium, large, dev, xsmall) Default is empty aka large
# DISK_SIZE: Default is 60Gb
#
# RAM_SIZE: memory used by containers. Default is 4096
# CPU_SIZE: CPU used by containers. Default is 1000Mhz
#
# Since version 1.4 of this script, multi-cloud providers support has been added
# and therefore the following environment variables have been added
#
# CLOUD_PROVIDER: default to aws (can be switched to azure)
# CLOUD_REGION: default to eu-west-1
# CLOUD_CREDENTIALS: default to ""
#
# Select multi node or single node deployment
# INFRA_TYPE can be high-availability or single-node (default)
# INFRA_NODES_COUNT can be over 3 for high-availability (default 3) or 1 for single-node

SCRIPT_VERSION="1.1-2023-10-11"

# Do not ask interactive user confirmation when creating resources
NO_CONFIRM=${NO_CONFIRM:-"-yes"}

echo -e "\nRunning $(basename "${BASH_SOURCE[0]}") version ${SCRIPT_VERSION}\n"

# Exit on errors
set -e

# Set infra instances size (small, medium, large, dev, xsmall).
#

ORGANIZATION=${ORGANIZATION:-"Edge-demo"}
INFRA_NODE_SIZE=${VM_SIZE:-"medium"}
INFRA_NODE_DISK_SIZE=${DISK_SIZE:-"60"}
INFRA_TYPE=${INFRA_TYPE:-"single-node"}
INFRA_NODES_COUNT=${INFRA_NODES_COUNT:-""}
INFRA_OPTIONS=""
if [ -z "${INFRA_NODES_COUNT}" ]; then
	if [ "${INFRA_TYPE}" != "high-availability" ]; then
		INFRA_OPTIONS="-node-count 1"
	fi
fi

HYBRID_CLUSTER=${HYBRID_CLUSTER:-"-hybrid-cluster-enabled"}
IS_SVCS=${IS_SVCS:-"-monitoring netdata -nomad-enabled -nomad-prefix n-ui -consul-enabled -consul-prefix c-ui -vault-enabled -vault-prefix v-ui -elasticsearch-enabled -elasticsearch-prefix es"}
EXTERNAL_NODES=${EXTERNAL_NODES:-"edge1:10.10.10.10 edge2:10.10.10.10"}

# Set memory used by containers
#
RAM_SIZE=${RAM_SIZE:-"4096"}
CPU_SIZE=${CPU_SIZE:-"1000"}

# Set project name according to 1st argument on command line or default
# Convert to lower-case to avoid later errors
# Remove non printable chars
PROJECT_NAME=$(echo "${1:-"sqsc-edge-demo"}" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]')

if [ -z "${PROJECT_NAME}" ]; then
	echo "${1:-"sqsc-edge-demo"} is not a valid project name (non-printable characters)"
	exit 1
fi

FULL_PROJECT_NAME="${PROJECT_NAME}"
if [ -n "${ORGANIZATION}" ]; then
	FULL_PROJECT_NAME="${ORGANIZATION}/${PROJECT_NAME}"
fi

# Look up for sqsc CLI binary in PATH
SQSC_BIN=$(command -v sqsc)
SQSC_VERSION=$(${SQSC_BIN} version | awk '{print $3}')
REQUIRED_SQSC_VERSION="1.1.7"
if [ "${SQSC_VERSION}" != "${REQUIRED_SQSC_VERSION}" ]; then
	echo "sqsc CLI version ${REQUIRED_SQSC_VERSION} required (${SQSC_VERSION} detected)"
	exit 1
fi

# Show calls to sqsc instead of executing them
if [ -n "${DRY_RUN}" ]; then
	SQSC_BIN="echo ${SQSC_BIN}"
fi

if [ -z "${SQSC_TOKEN}" ]; then
	echo "You need to set SQSC_TOKEN to an existing and active API key in your account profile"
	exit 1
fi

# Set default endpoint (none => production aka https://www.squarescale.io)
if [ -z "${SQSC_ENDPOINT}" ]; then
	export SQSC_ENDPOINT="https://www.squarescale.io"
	echo "Using default for SQSC_ENDPOINT: ${SQSC_ENDPOINT}"
fi

# Check current SquareScale endpoint status
${SQSC_BIN} status || ${SQSC_BIN} login

# Cloud related environment variables
CLOUD_PROVIDER=${CLOUD_PROVIDER:-"aws"}
CLOUD_REGION=${CLOUD_REGION:-"eu-west-1"}
CLOUD_CREDENTIALS=${CLOUD_CREDENTIALS:-""}

if [[ -z "${CLOUD_PROVIDER}" || ( "${CLOUD_PROVIDER}" != "aws" && "${CLOUD_PROVIDER}" != "azure"  && "${CLOUD_PROVIDER}" != "outscale" ) ]]; then
	echo "CLOUD_PROVIDER=${CLOUD_PROVIDER} unsupported (only aws/azure/outscale)"
	exit 1
fi

# Function which wait for project cluster to
# be able to schedule containers
#
function wait_for_project_scheduling() {
	echo "Waiting for project to be able to schedule containers"
	if [ -n "${DRY_RUN}" ]; then
		return
	fi
	while true; do
		# shellcheck disable=SC2207
		eval "$(${SQSC_BIN} project get -project-name "${FULL_PROJECT_NAME}" | grep -Ev '^Slack|^Age|^External' | awk '/Network policies/{exit}NF>1{print}' | sed -e 's/: /="/' -e 's/$/"/')"
		# shellcheck disable=SC2154
		if [ "${Status}" == "error" ]; then
			echo "${PROJECT_NAME} provisionning has encountered an error"
			exit 1
		fi
		# shellcheck disable=SC2207,SC2001
		available=($(echo "${Cluster}" | sed -e 's?/? ?'))
		if [ "${Status}" != "ok" ] || [ "${available[0]}" == "0" ] || [ -z "${available[0]}" ]; then
			echo "Project ${PROJECT_NAME} is not ready to schedule any containers yet"
			sleep 5
		else
			echo "Project ${PROJECT_NAME} READY to schedule containers"
			break
		fi
	done
}

# Function which creates an external node
#
# Parameters:
# 1) 
#
function add_external_node() {
	wait_for_project_scheduling
	cur_ext_nodes=$(show_external_nodes)
	if echo "$cur_ext_nodes" | grep -Eq "^$1\s\s*"; then
		if echo "$cur_ext_nodes" | grep -Eq "^$1\s\s*$2\s\s*"; then
			echo "${PROJECT_NAME} already configured with $1 IP $2 as external node. Skipping..."
		else
			echo "${PROJECT_NAME} already configured with $1 as external node but IP $2 does not match. Please check your configuration..."
			echo "$cur_ext_nodes" | grep -E "^$1\s\s*"
			exit 1
		fi
	else
		echo "Creating external node $1 with IP $2 in ${PROJECT_NAME}..."
		${SQSC_BIN} external-node add -nowait -project-uuid "${PROJECT_UUID}" -public-ip "$2" "$1"
	fi
}

# Function which creates a scheduling group
#
# Parameters:
# 1) scheduling group name
#
function add_scheduling_group() {
	wait_for_project_scheduling
	cur_sched_groups=$(show_scheduling_groups)
	if echo "$cur_sched_groups" | grep -Eq "^\[$1\]"; then
		echo "${PROJECT_NAME} already configured with $1 scheduling-group. Skipping..."
	else
		echo "Creating scheduling-group $1 in ${PROJECT_NAME}..."
		${SQSC_BIN} scheduling-group add -project-uuid "${PROJECT_UUID}" "$1"
	fi
}

# Function which creates a service
#
# Parameters:
# 1) Docker Hub container image name
# 2) Scheduling group(s) (optional)
# 3) Memory size required (optional)
# 4) CPU size required (optional)
#
function add_service() {
	wait_for_project_scheduling
	container_image=$(echo "$1" | awk -F/ '{print $NF}' | awk -F: '{print $1}')
	cur_containers=$(show_containers)
	if echo "$cur_containers" | grep -Eq "^${container_image}\s\s*"; then
		echo "${PROJECT_NAME} already configured with service container $container_image. Skipping..."
	else
		SCHED_GROUPS_OPTS=""
		if [ -n "$2" ]; then
			SCHED_GROUPS_OPTS="-scheduling-groups $2"
		fi
		echo "Adding container service $container_image"
		eval "${SQSC_BIN}" service add -project-uuid "${PROJECT_UUID}" -docker-image "$1" -instances 1 "${SCHED_GROUPS_OPTS}"
	fi
	if [ -n "$3" ]; then
		cur_val=$(${SQSC_BIN} service show -project-uuid "${PROJECT_UUID}" -service "$container_image" | grep ^Mem | awk '{print $(NF-1)}')
		if [ "$cur_val" != "$3" ]; then
			echo "Updating $1 container memory to $3 (was $cur_val)"
			${SQSC_BIN} service set -project-uuid "${PROJECT_UUID}" -service "$container_image" -memory "$3"
		else
			echo "$1 container memory already set to $3"
		fi
	fi
	if [ -n "$4" ]; then
		cur_val=$(${SQSC_BIN} service show -project-uuid "${PROJECT_UUID}" -service "$container_image" | grep ^CPU | awk '{print $(NF-1)}')
		if [ "$cur_val" != "$4" ]; then
			echo "Updating $1 container CPU to $4 (was $cur_val)"
			${SQSC_BIN} service set -project-uuid "${PROJECT_UUID}" -service "$container_image" -cpu "$4"
		else
			echo "$1 container CPU already set to $4"
		fi
	fi
}

# Function which checks if environment variable already set
# if not, then set it to given value (2nd parameter)
function set_env_var(){
	# sqsc env get returns error if variable is not set already
	# and -e has been activated globally at the top of this script
	set +e
	v=$(${SQSC_BIN} env get -project-uuid "${PROJECT_UUID}" "$1" 2>/dev/null)
	# Error: aka variable not defined
	# shellcheck disable=SC2181
	if [ $? -eq 0 ] && [ "$v" == "$2" ]; then
		echo "$1 already set to $2. Skipping..."
	else
		${SQSC_BIN} env set -project-uuid "${PROJECT_UUID}" "$1" "$2"
	fi
	# Restore script failure on further errors
	set -e
}

# Function creating the project
# this is the main entry point
function create_project(){
	projects=$(${SQSC_BIN} project list)
	# take organization into account for proper retrieval (creation OK)
	# in case project with same name but no org or not same org
	search_pattern="^${PROJECT_NAME}\s\s*.*\s\s*${ORGANIZATION}\s\s*"
	if echo "$projects" | grep -Eq "${search_pattern}"; then
		echo "${PROJECT_NAME} already created. Skipping..."
		if echo "$projects" | grep -Eq "${search_pattern}no_infra\s\s*"; then
			echo "${PROJECT_NAME} starting provisionning..."
			${SQSC_BIN} project provision -project-name "${FULL_PROJECT_NAME}"
		elif echo "$projects" | grep -Eq "${search_pattern}error\s\s*"; then
			echo "${PROJECT_NAME} provisionning has encountered an error"
			exit 1
		else
			echo "${PROJECT_NAME} already provisionning. Skipping..."
		fi
	else
		if [ -n "${ORGANIZATION}" ]; then
			ORG_OPTIONS="-organization ${ORGANIZATION}"
		fi
		if [ -n "${SLACK_WEB_HOOK}" ]; then
			SLACK_OPTIONS="-slackbot ${SLACK_WEB_HOOK}"
		fi
		if [ -z "${CLOUD_CREDENTIALS}" ]; then
			echo "You need to set CLOUD_CREDENTIALS to an existing IaaS credential in your account profile"
			exit 1
		fi
		eval "${SQSC_BIN} project create ${HYBRID_CLUSTER} ${IS_SVCS} ${ORG_OPTIONS} ${SLACK_OPTIONS} ${NO_CONFIRM} -provider \"${CLOUD_PROVIDER}\" -region \"${CLOUD_REGION}\" -credential \"${CLOUD_CREDENTIALS}\" -infra-type \"${INFRA_TYPE}\" ${INFRA_OPTIONS} -root-disk-size \"${INFRA_NODE_DISK_SIZE}\" -node-size \"${INFRA_NODE_SIZE}\" -project-name \"${PROJECT_NAME}\""
		projects=$(${SQSC_BIN} project list)
	fi
	PROJECT_UUID=$(echo "$projects" | grep -E "${search_pattern}" | awk '{print $2}')

	# To send notifications on #demoapp SquareScale Slack channel
	if [ -n "${SLACK_WEB_HOOK}" ]; then
		slackwebhook="$(${SQSC_BIN} project slackbot -project-uuid "${PROJECT_UUID}")"
		tobeupdated=true
		if [ -n "$slackwebhook" ]; then
			if [ "$slackwebhook" == "${SLACK_WEB_HOOK}" ]; then
				echo "${PROJECT_NAME} already configured with Slack. Skipping..."
				tobeupdated=false
			fi
		fi
		if $tobeupdated; then
			${SQSC_BIN} project slackbot -project-uuid "${PROJECT_UUID}" "${SLACK_WEB_HOOK}"
		fi
	else
		echo "SLACK_WEB_HOOK not set: ignoring ..."
	fi
}

function show_containers(){
	${SQSC_BIN} service list -project-uuid "${PROJECT_UUID}"
}

function show_scheduling_groups(){
	${SQSC_BIN} scheduling-group list -project-uuid "${PROJECT_UUID}"
}

function show_external_nodes(){
	${SQSC_BIN} external-node list -project-uuid "${PROJECT_UUID}"
}

function wait_containers(){
	echo "Waiting for containers to be running"
	if [ -n "${DRY_RUN}" ]; then
		return
	fi
	while true; do
		c=$(show_containers | while read -r -a container; do
			if [ "${container[0]}" != "Name" ]; then
				r=$(echo "${container[1]}" | awk -F/ '$1==$2{print 1}')
				if [ -z "${r}" ]; then
					echo "${container[0]}"
					break
				fi
			fi
		done)
		if [ -n "${c}" ]; then
			echo "${c} not ready"
			sleep 5
		else
			echo -e 'All containers ready\n'
			break
		fi
	done
}

function add_services(){
	add_service "${IREFLEX_DEMO_DOCKER_IMAGE:-squarescale/demo-ireflex-js}" edge
}

function set_network_rules(){
	echo -e 'Adding network rules\n'
	net_rule=$(${SQSC_BIN} network-rule list -project-uuid "${PROJECT_UUID}" -service-name demo-ireflex-js)
	if echo "$net_rule" | grep -Eq '^demo-ireflex-js\s*http/80\s*http/80\s*'; then
		echo "Network rule already configured. Skipping..."
	else
		# TODO: see if this needs to be parametrized (duplicate/resource already exist)
		echo "Adding network rule"
		${SQSC_BIN} network-rule create -project-uuid "${PROJECT_UUID}" -name "demo-ireflex-js" -internal-protocol "http" -internal-port 80 -external-protocol "http" -service-name "demo-ireflex-js" -path "/"
	fi
}

function show_url(){
	lb_url=$(${SQSC_BIN} lb list -project-uuid "${PROJECT_UUID}" | grep '://' | awk '{print $NF}')
	echo -e "Load Balancer and service URL:\t${lb_url}/\n"
}

function add_scheduling_groups() {
	echo -e 'Adding scheduling groups\n'
	for s in "cloud" "vpn" "edge"; do add_scheduling_group "$s"; done
}

function assign_scheduling_groups() {
	echo -e 'Populating scheduling groups\n'
	cur_sched_groups=$(${SQSC_BIN} project details -project-uuid "${PROJECT_UUID}" -no-summary -no-external-nodes -no-compute-resources | awk 'BEGIN{n=0}/Scheduling groups/{n=1;next}n==1&&!/NAME/&&length($0)>0{print}')
	cur_compute_resources=$(${SQSC_BIN} project details -project-uuid "${PROJECT_UUID}" -no-summary -no-external-nodes -no-scheduling-groups | awk 'BEGIN{n=0}/Compute resources/{n=1;next}n==1&&!/NAME/&&length($0)>0{print}')
	cur_edge_nodes=$(${SQSC_BIN} project details -project-uuid "${PROJECT_UUID}" -no-summary -no-compute-resources -no-scheduling-groups | awk 'BEGIN{n=0}/External nodes/{n=1;next}n==1&&!/NAME/&&length($0)>0{print}')
	for n in $(echo "${cur_compute_resources}" | grep -E '\s\s*Cluster\s\s*' | grep -v t3a.micro | awk '{print $1}'); do
		if echo "${cur_sched_groups}" | grep -Eq "^cloud\s\s*.*$n"; then
			echo "$n already configured in cloud scheduling group"
		else
			echo "Assigning $n to cloud scheduling group"
			${SQSC_BIN} scheduling-group assign -project-uuid "${PROJECT_UUID}" cloud "$n"
		fi
	done
	for n in $(echo "${cur_compute_resources}" | grep -E '\s\s*Cluster\s\s*' | grep t3a.micro | awk '{print $1}'); do
		if echo "${cur_sched_groups}" | grep -Eq "^vpn\s\s*.*$n"; then
			echo "$n already configured in vpn scheduling group"
		else
			echo "Assigning $n to vpn scheduling group"
			${SQSC_BIN} scheduling-group assign -project-uuid "${PROJECT_UUID}" vpn "$n"
		fi
	done
	for n in $(echo "${cur_edge_nodes}" | awk '{print $1}'); do
		if echo "${cur_sched_groups}" | grep -Eq "^edge\s\s*.*$n"; then
			echo "$n already configured in edge scheduling group"
		else
			echo "Assigning $n to edge scheduling group"
			#${SQSC_BIN} scheduling-group assign -project-uuid "${PROJECT_UUID}" edge "$n"
		fi
	done
}

create_project
wait_for_project_scheduling
add_scheduling_groups
echo -e 'Adding external nodes\n'
# shellcheck disable=SC2068,SC2086
for n in ${EXTERNAL_NODES[@]}; do add_external_node ${n//:/ }; done
assign_scheduling_groups
add_services
set_network_rules

# Show all
wait_containers
show_url
