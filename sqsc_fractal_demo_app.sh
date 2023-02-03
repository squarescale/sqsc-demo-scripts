#!/usr/bin/env bash
#
# See http://docs.squarescale.com/CLI.html for more informations about sqsc CLI
#
# This script is used to deploy the SquareScale fractal demo
#
# If a parameter is passed on the command line, it is taken as the name of the project
# to be created
#
# If a second parameter is passed, it is used as the base GitHub account of the cloned sqsc-demo-*
# (instead of squarescale organization)
#
# It can also be customized via a set of environment variables
#
# SQSC_ENDPOINT: target SquareScale platform endpoint (defaults to empty aka https://www.squarescale.io)
#
# SQSC_TOKEN: security token generated via API Keys menu on platform endpoint
# and used to run `sqsc login` successfully
#
# DOCKER_DB: default to empty which means use RDS based Postgres. Setting this to anything will speed
# 	up the demo startup time because of the use of Postgres Docker container
#
# DRY_RUN: default to empty. Setting this to anything will show calls to be made by sqsc instead of
#	running them
#
# Default Docker hub images for all services can be customized/changed by
# using the appropriate variable
#
# POSTGRES_DOCKER_IMAGE: default to postgres
# RABBITMQ_DOCKER_IMAGE: default to rabbitmq
# WORKER_DOCKER_IMAGE:   default to squarescale/sqsc-demo-worker
# APP_DOCKER_IMAGE:	 default to squarescale/sqsc-demo-app
#
# VM_SIZE: (small, medium, large, dev, xsmall) Default is empty aka small
#
# RABBITMQ_RAM_SIZE: memory used by RabbitMQ container. Default is 4096
#
# Since version 1.4 of this script, multi-cloud providers support has been added
# and therefore the following environment variables have been added
#
# CLOUD_PROVIDER: default to aws (can be switched to azure)
# CLOUD_REGION: default to eu-west-1
# CLOUD_CREDENTIALS: default to ""
#
# Support for multiple databases version has also been added
# DEFAULT_PG_VERSION: default to 10
#
# Monitoring via netdata can be activated on project deployment
# MONITORING=netdata # default to ""
#
# Select multi node or single node deployment
# INFRA_TYPE can be high-availability (default) or single-node

SCRIPT_VERSION="2.0-2022-09-09"

# Do not ask interactive user confirmation when creating resources
NO_CONFIRM=${NO_CONFIRM:-"-yes"}

echo -e "\nRunning $(basename "${BASH_SOURCE[0]}") version ${SCRIPT_VERSION}\n"

# Exit on errors
set -e

# Set infra instances size (small, medium, large, dev, xsmall).
# Default is medium because of RabbitMQ requirements
#
INFRA_NODE_SIZE=${VM_SIZE:-"medium"}
INFRA_TYPE=${INFRA_TYPE:-"high-availability"}

# Set memory used by RabbitMQ container
# Default is 4096 because of RabbitMQ requirements
#
RABBITMQ_RAM_SIZE=${RABBITMQ_RAM_SIZE:-"4096"}

# Default Postgres RDS version
DEFAULT_PG_VERSION=${DEFAULT_PG_VERSION:-"10"}

# Set project name according to 1st argument on command line or default
# Convert to lower-case to avoid later errors
# Remove non printable chars
PROJECT_NAME=$(echo "${1:-"sqsc-fractal-demo"}" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]')

if [ -z "${PROJECT_NAME}" ]; then
	echo "${1:-"sqsc-fractal-demo"} is not a valid project name (non-printable characters)"
	exit 1
fi

FULL_PROJECT_NAME="${PROJECT_NAME}"
if [ -n "${ORGANIZATION}" ]; then
	FULL_PROJECT_NAME="${ORGANIZATION}/${PROJECT_NAME}"
fi

# Look up for sqsc CLI binary in PATH
SQSC_BIN=$(command -v sqsc)
SQSC_VERSION=$(${SQSC_BIN} version | awk '{print $3}')
REQUIRED_SQSC_VERSION="1.1.3"
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

if [[ -z "${CLOUD_PROVIDER}" || ( "${CLOUD_PROVIDER}" != "aws" && "${CLOUD_PROVIDER}" != "azure" ) ]]; then
	echo "CLOUD_PROVIDER=${CLOUD_PROVIDER} unsupported (only aws/azure)"
	exit 1
fi

# Add monitoring to deployment
MONITORING=${MONITORING:-""}
if [ -n "${MONITORING}" ]; then
	if [ "${MONITORING}" != "netdata" ]; then
		echo "MONITORING=${MONITORING} unsupported (only netdata)"
		exit 1
	fi
	MONITORING_OPTIONS="-monitoring ${MONITORING}"
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
		eval "$(${SQSC_BIN} project get -project-name "${FULL_PROJECT_NAME}" | grep -Ev '^Slack|^Age' | awk 'NF>1{print}' | sed -e 's/: /="/' -e 's/$/"/')"
		# shellcheck disable=SC2154
		if [ "${Status}" == "error" ]; then
			echo "${PROJECT_NAME} provisionning has encountered an error"
			exit 1
		fi
		# shellcheck disable=SC2207,SC2001
		available=($(echo "${Nodes}" | sed -e 's?/? ?'))
		if [ "${Status}" != "ok" ] || [ "${available[0]}" == "0" ] || [ -z "${available[0]}" ]; then
			echo "Project ${PROJECT_NAME} is not ready to schedule any containers yet"
			sleep 5
		else
			break
		fi
	done
}

# Function which creates a service
#
# Parameters:
# 1) Docker Hub container image name
# 2) Memory size required (optional)
#
function add_service() {
	wait_for_project_scheduling
	container_image=$(echo "$1" | awk -F/ '{print $NF}' | awk -F: '{print $1}')
	cur_containers=$(show_containers)
	if echo "$cur_containers" | grep -Eq "^${container_image}\s\s*"; then
		echo "${PROJECT_NAME} already configured with service container $container_image. Skipping..."
	else
		echo "Adding container service $container_image"
		${SQSC_BIN} service add -project-uuid "${PROJECT_UUID}" -image "$1"
	fi
	if [ -n "$2" ]; then
		echo "Increasing $1 container memory to $2"
		${SQSC_BIN} service set -project-uuid "${PROJECT_UUID}" -service "$1" -memory "$2"
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

# Function which creates containerized database
# (as opposed to using RDS based version)
function add_docker_database(){
	# Container variables for launch
	set_env_var POSTGRES_PASSWORD "$dbpasswd"
	set_env_var POSTGRES_USER "dbadmin"
	set_env_var POSTGRES_DB "dbmain"
	# Environment variables
	set_env_var DB_ENGINE postgres
	set_env_var DB_HOST postgres.service.consul
	set_env_var DB_PORT 5432
	set_env_var DB_PASSWORD "$dbpasswd"
	set_env_var DB_USERNAME "dbadmin"
	set_env_var DB_NAME "dbmain"
	set_env_var PROJECT_DB_PASSWORD "$dbpasswd"
	set_env_var PROJECT_DB_USERNAME "dbadmin"
	set_env_var PROJECT_DB_NAME "dbmain"
	# All variables are defined before container launch to avoid
	# un-necessary re-scheduling due to environment changes
	add_service "${POSTGRES_DOCKER_IMAGE:-postgres:10}"
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
			${SQSC_BIN} project provision "${ORG_OPTIONS}" -project-name "${FULL_PROJECT_NAME}"
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
		if [ -z "${DOCKER_DB}" ]; then
			eval "${SQSC_BIN} project create ${ORG_OPTIONS} ${SLACK_OPTIONS} ${NO_CONFIRM} ${MONITORING_OPTIONS} -provider \"${CLOUD_PROVIDER}\" -region \"${CLOUD_REGION}\" -credential \"${CLOUD_CREDENTIALS}\" -db-engine postgres -db-size small -db-version \"${DEFAULT_PG_VERSION}\" -infra-type \"${INFRA_TYPE}\" -node-size \"${INFRA_NODE_SIZE}\" -name \"${PROJECT_NAME}\""
		else
			eval "${SQSC_BIN} project create ${ORG_OPTIONS} ${SLACK_OPTIONS} ${NO_CONFIRM} ${MONITORING_OPTIONS} -provider \"${CLOUD_PROVIDER}\" -region \"${CLOUD_REGION}\" -credential \"${CLOUD_CREDENTIALS}\" -infra-type \"${INFRA_TYPE}\" -node-size \"${INFRA_NODE_SIZE}\" -name \"${PROJECT_NAME}\""
		fi
		projects=$(${SQSC_BIN} project list)
	fi
	PROJECT_UUID=$(echo "$projects" | grep -E "${search_pattern}" | awk '{print $2}')

	# All variables are defined before container launch to avoid
	# un-necessary re-scheduling due to environment changes
	set_env_vars
	if [ -n "${DOCKER_DB}" ]; then
		# sqsc env get returns error if variable is not set already
		# and -e has been activated globally at the top of this script
		set +e
		dbpasswd=$(${SQSC_BIN} env get -project-uuid "${PROJECT_UUID}" POSTGRES_PASSWORD 2>/dev/null)
		# shellcheck disable=SC2181
		if [ $? -ne 0 ] && [ -z "$dbpasswd" ]; then
			dbpasswd=$(pwgen 32 1)
		fi
		# Restore script failure on further errors
		set -e
		add_docker_database
	fi
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

function set_env_vars(){
	# No need to check here as this will overwrite current values if any (therefore unchanged if same)
	set_env_var NODE_ENV production
	set_env_var RABBITMQ_HOST rabbitmq.service.consul
}

function display_env_vars(){
	${SQSC_BIN} env get -project-uuid "${PROJECT_UUID}"
}

function show_containers(){
	${SQSC_BIN} service list -project-uuid "${PROJECT_UUID}"
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
	add_service "${WORKER_DOCKER_IMAGE:-squarescale/sqsc-demo-worker}"
	add_service "${APP_DOCKER_IMAGE:-squarescale/sqsc-demo-app}"
	add_service "${RABBITMQ_DOCKER_IMAGE:-rabbitmq}" "${RABBITMQ_RAM_SIZE}"
}

function set_network_rule(){
	net_rule=$(${SQSC_BIN} network-rule list -project-uuid "${PROJECT_UUID}" -service-name sqsc-demo-app)
	if echo "$net_rule" | grep -Eq '^sqsc-demo-app\s*http/3000\s*http/80\s*'; then
		echo "Network rule already configured. Skipping..."
	else
		# TODO: see if this needs to be parametrized (duplicate/resource already exist)
		echo "Adding network rule"
		${SQSC_BIN} network-rule create -project-uuid "${PROJECT_UUID}" -name "sqsc-demo-app" -internal-protocol "http" -internal-port 3000 -external-protocol "http" -service-name "sqsc-demo-app"
	fi
}

function show_url(){
	echo -e 'Front load balancer informations\n'
	${SQSC_BIN} lb list -project-uuid "${PROJECT_UUID}"
}

create_project
add_services
set_network_rule

# Show all
display_env_vars
wait_containers
show_url
