#!/usr/bin/env bash
#
# See http://docs.squarescale.com/CLI.html for more informations about sqsc CLI
#
# This script is used to deploy the SquareScale fake service demo
# based on HashiCorp demos
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
# Default Docker hub images for all services can be customized/changed by
# using the appropriate variable
#
# FAKESERVICE_DOCKER_IMAGE: default to obourdon/fake-service:v0.22.10
#
# VM_SIZE: (small, medium, large, dev, xsmall) Default is empty aka small
#
# INFRA_TYPE: (high-availability, single-node) Default is empty aka single-node
#
# Since version 1.4 of this script, multi-cloud providers support has been added
# and therefore the following environment variables have been added
#
# CLOUD_PROVIDER: default to aws (can be switched to azure)
# CLOUD_REGION: default to eu-west-3
# CLOUD_CREDENTIALS: default to ""
#
# Monitoring via netdata can be activated on project deployment
# MONITORING=netdata # default to ""
#
SCRIPT_VERSION="1.2-2023-05-06"

# Originally nicholasjackson/fake-service:v0.22.9
FAKESERVICE_DOCKER_IMAGE="${FAKESERVICE_DOCKER_IMAGE:-obourdon/fake-service:0.23.2-test}"

# Original port is 9090 (fake-service) but it does not work for the UI part so it can be changed to 80 (Nginx)
FAKESERVICE_PORT="${FAKESERVICE_PORT:-9090}"
FAKESERVICE_UI_PORT="${FAKESERVICE_UI_PORT:-80}"

# Do not ask interactive user confirmation when creating resources
NO_CONFIRM=${NO_CONFIRM:-"-yes"}

echo -e "\nRunning $(basename "${BASH_SOURCE[0]}") version ${SCRIPT_VERSION}\n"

# Exit on errors
set -e

# Set infrastructure instances size (small, medium, large, dev, xsmall).
# Default is medium because of RabbitMQ requirements
#
INFRA_NODE_SIZE=${VM_SIZE:-"small"}

# Set infrastructure type to single-node (can also be high-availability)
#
INFRA_TYPE=${INFRA_TYPE:-"single-node"}

# Set project name according to 1st argument on command line or default
# Convert to lower-case to avoid later errors
# Remove non printable chars
PROJECT_NAME=$(echo "${1:-"sqsc-fake-svc-demo"}" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]')

if [ -z "${PROJECT_NAME}" ]; then
	echo "${1:-"sqsc-fake-svc-demo"} is not a valid project name (non-printable characters)"
	exit 1
fi

FULL_PROJECT_NAME="${PROJECT_NAME}"
if [ -n "${ORGANIZATION}" ]; then
	FULL_PROJECT_NAME="${ORGANIZATION}/${PROJECT_NAME}"
fi

# Look up for sqsc CLI binary in PATH
SQSC_BIN=$(command -v sqsc)
SQSC_VERSION=$(${SQSC_BIN} version | awk '{print $3}')
REQUIRED_SQSC_VERSION="1.1.5"
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
CLOUD_REGION=${CLOUD_REGION:-"eu-west-3"}
CLOUD_CREDENTIALS=${CLOUD_CREDENTIALS:-""}

if [[ -z "${CLOUD_PROVIDER}" || ( "${CLOUD_PROVIDER}" != "aws" && "${CLOUD_PROVIDER}" != "azure"  && "${CLOUD_PROVIDER}" != "outscale" ) ]]; then
	echo "CLOUD_PROVIDER=${CLOUD_PROVIDER} unsupported (only aws/azure/outscale)"
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

# Function which checks if environment variable already set
# if not, then set it to given value
#
# Parameters:
# 1) Service name
# 2) Environment variable name
# 3) Environment variable value
#
function set_svc_env_var(){
	evs=$(${SQSC_BIN} env get -project-uuid "${PROJECT_UUID}" -service "$1" 2>/dev/null | awk 'NF>0{print}' | sed -e 's/=/="/' -e 's/$/"/')
	eval $(echo "$evs")
	ev=$2
	v=${!ev}
	if [ "$v" == "$3" ]; then
		echo "$2 already set to $3 for service $1. Skipping..."
	else
		${SQSC_BIN} env set -project-uuid "${PROJECT_UUID}" -service "$1" "$2" "$3"
	fi
	# reset all vars previously defined
	eval $(echo "$evs" | awk -F= '{printf "unset %s\n",$1}')
}

# Function which creates a service
#
# Parameters:
# 1) Service name
# 2) Docker Hub container image name
#
function add_service() {
	wait_for_project_scheduling
	container_image=$(echo "$2" | awk -F/ '{print $NF}' | awk -F: '{print $1}')
	cur_containers=$(show_containers)
	if echo "$cur_containers" | grep -Eq "^${1}\s\s*"; then
		echo "${PROJECT_NAME} already configured with service $1 container $container_image. Skipping..."
	else
		echo "Adding container service $container_image as job ${1}"
		${SQSC_BIN} service add -project-uuid "${PROJECT_UUID}" -docker-image "$2" -service "$1" -instances 1
	fi
	set_svc_env_var "$1" NAME "$1"
	set_svc_env_var "$1" MESSAGE "Hello from $1"
	set_svc_env_var "$1" SERVER_TYPE "http"
	set_svc_env_var "$1" TIMING_VARIANCE 10
	set_svc_env_var "$1" ALLOW_CLOUD_METADATA "true"
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
		if echo "$projects" | grep -Eq "^${PROJECT_NAME}\s\s*.*\s\s*no_infra\s\s*"; then
			echo "${PROJECT_NAME} starting provisionning..."
			${SQSC_BIN} project provision -project-name "${FULL_PROJECT_NAME}"
		elif echo "$projects" | grep -Eq "^${PROJECT_NAME}\s\s*.*\s\s*error\s\s*"; then
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
		eval "${SQSC_BIN} project create ${ORG_OPTIONS} ${SLACK_OPTIONS} ${NO_CONFIRM} ${MONITORING_OPTIONS} -provider \"${CLOUD_PROVIDER}\" -region \"${CLOUD_REGION}\" -credential \"${CLOUD_CREDENTIALS}\" -infra-type \"${INFRA_TYPE}\" -node-size \"${INFRA_NODE_SIZE}\" -project-name \"${PROJECT_NAME}\""
		projects=$(${SQSC_BIN} project list)
	fi
	PROJECT_UUID=$(echo "$projects" | grep -E "^${PROJECT_NAME}\s\s*" | awk '{print $2}')

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

function wait_containers(){
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
            echo "Service container ${c} not ready"
            sleep 5
        else
            echo -e 'All containers ready\n'
            break
        fi
	done
}

function add_services(){
	add_service web "${FAKESERVICE_DOCKER_IMAGE}"
	set_svc_env_var web TIMING_50_PERCENTILE 30ms
	set_svc_env_var web TIMING_90_PERCENTILE 60ms
	set_svc_env_var web TIMING_99_PERCENTILE 90ms
	set_svc_env_var web UPSTREAM_URIS "http://api.service.consul:${FAKESERVICE_PORT}"
	#set_svc_env_var web TRACING_ZIPKIN "http://jaeger.service.consul:9411"
	#set_svc_env_var web LOG_LEVEL debug
	add_service api "${FAKESERVICE_DOCKER_IMAGE}"
	set_svc_env_var api TIMING_50_PERCENTILE 20ms
	set_svc_env_var api TIMING_90_PERCENTILE 30ms
	set_svc_env_var api TIMING_99_PERCENTILE 40ms
	set_svc_env_var api UPSTREAM_URIS "grpc://currency.service.consul:${FAKESERVICE_PORT}, http://cache.service.consul:${FAKESERVICE_PORT}/abc/123123, http://payments.service.consul:${FAKESERVICE_PORT}"
	set_svc_env_var api UPSTREAM_WORKERS 2
	set_svc_env_var api HTTP_CLIENT_APPEND_REQUEST "true"
	#set_svc_env_var api TRACING_ZIPKIN "http://jaeger.service.consul:9411"
	add_service cache "${FAKESERVICE_DOCKER_IMAGE}"
	set_svc_env_var cache TIMING_50_PERCENTILE 1ms
	set_svc_env_var cache TIMING_90_PERCENTILE 2ms
	set_svc_env_var cache TIMING_99_PERCENTILE 3ms
	#set_svc_env_var cache TRACING_ZIPKIN "http://jaeger.service.consul:9411"
	add_service payments "${FAKESERVICE_DOCKER_IMAGE}"
	set_svc_env_var payments HTTP_CLIENT_APPEND_REQUEST "true"
	set_svc_env_var payments UPSTREAM_URIS "grpc://currency.service.consul:${FAKESERVICE_PORT}"
	#set_svc_env_var payments TRACING_ZIPKIN "http://jaeger.service.consul:9411"
	add_service currency "${FAKESERVICE_DOCKER_IMAGE}"
	set_svc_env_var currency SERVER_TYPE "grpc"
	set_svc_env_var currency ERROR_RATE 0.2
	set_svc_env_var currency ERROR_CODE 14
	set_svc_env_var currency ERROR_TYPE "http_error"
	#set_svc_env_var currency TRACING_ZIPKIN "http://jaeger.service.consul:9411"
}

function set_network_rule(){
	net_rule=$(${SQSC_BIN} network-rule list -project-uuid "${PROJECT_UUID}" -service-name web)
	if echo "$net_rule" | grep -Eq "^web\s*http/${FAKESERVICE_UI_PORT}\s*http/80\s*"; then
		echo "Network rule already configured. Skipping..."
	else
		# TODO: see if this needs to be parametrized (duplicate/resource already exist)
		echo "Adding network rule"
		${SQSC_BIN} network-rule create -project-uuid "${PROJECT_UUID}" -name "web" -internal-protocol "http" -internal-port ${FAKESERVICE_UI_PORT} -external-protocol "http" -service-name "web"
	fi
}

function show_url(){
    echo -e 'Front load balancer informations\n'
	${SQSC_BIN} lb list -project-uuid "${PROJECT_UUID}"
}

create_project
add_services
set_network_rule

wait_containers
show_url
