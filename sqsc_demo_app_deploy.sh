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
# ENDPOINT: target SquareScale platform endpoint (defaults to empty aka https://www.squarescale.io)
#
# DOCKER_DB: default to empty which means use RDS based Postgres. Setting this to anything will speed
# 	up the demo startup time because of the use of Postgres Docker container
#
# DONT_BUILD_WORKER: default to empty which means use sqsc-demo-worker GitHub repository. Setting this
#	to anything will use the Docker Hub image
# WORKER_BUILD_MODE: default to empty aka internal
#
# DONT_BUILD_APP: default to empty which means use sqsc-demo-app GitHub repository. Setting this
#	to anything will use the Docker Hub image
# APP_BUILD_MODE: default to empty aka travis
#
# DRY_RUN: default to empty. Setting this to anything will show calls to be made by sqsc instead of
#	running them
#

SCRIPT_VERSION="1.0-2018-08-16"

# Exit on errors
set -e

# Set project name according to 1st argument on command line or default
# Convert to lower-case to avoid later errors
PROJECT_NAME=$(echo ${1:-"sqsc-demo"} | tr '[A-Z]' '[a-z]')
REPO_BASE=${2:-"squarescale"}

# Look up for sqsc CLI binary in PATH
SQSC_BIN=$(command -v sqsc)
SQSC_BIN_CHECK=$SQSC_BIN
# Show calls to sqsc instead of executing them
if [ -n "$DRY_RUN" ]; then
	SQSC_BIN="echo $SQSC_BIN"
fi

# Set default enpoint (none => production aka http://www.squarescale.io)
if [ -n "$ENDPOINT" ]; then
	ENDPOINT_OPT="-endpoint $ENDPOINT"
fi

# Check current SquareScale endpoint status
$SQSC_BIN status $ENDPOINT_OPT || $SQSC_BIN login $ENDPOINT_OPT

# Function which creates a service
#
# Parameters:
# 1) GitHub repository URL
# 2) Docker Hub container image name
# 3) Container or repository based 1/0 (default 0 aka repository based)
# 4) Build service: internal/travis (defaults to travis)
#
function add_service() {
	repo_url=$1
	container_image=$2
	is_container=${3:-0}
	build_service=${4:-"travis"}
	cur_repos=$(show_repositories)
	cur_containers=$(show_containers)
	if [ "$is_container" -eq 1 ]; then
		if $(echo "$cur_containers" | grep -Eqw "$container_image"); then
			echo "$PROJECT_NAME already configured with service container $container_image. Skipping..."
		else
			echo "Adding container service $container_image"
			$SQSC_BIN image add $ENDPOINT_OPT -project "$PROJECT_NAME" -name "$container_image"
		fi
	else
		if $(echo "$cur_repos" | grep -Eqw "$repo_url"); then
			echo "$PROJECT_NAME already configured with service repository $repo_url. Skipping..."
		else
			echo "Adding service repository $repo_url"
			$SQSC_BIN repository add $ENDPOINT_OPT -project "$PROJECT_NAME" -build-service "$build_service" -url "$repo_url"
		fi
	fi
}

# Function which checks if environment variable already set
# if not, then set it to given value (2nd parameter)
function set_env_var(){
	# sqsc env get returns error if variable is not set already
	# and -e has been activated globally at the top of this script
	set +e
	v=$($SQSC_BIN_CHECK env get $ENDPOINT_OPT -project "$PROJECT_NAME" $1 2>/dev/null)
	# Error: aka variable not defined
	if [ $? -eq 0 ] && [ "$v" == "$2" ]; then
		echo "$1 already set to $2. Skipping..."
	else
		$SQSC_BIN env set $ENDPOINT_OPT -project "$PROJECT_NAME" "$1" "$2"
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
	add_service "" postgres 1
}

# Function creating the project
# this is the main entry point
function create_project(){
	projects=$($SQSC_BIN_CHECK project list $ENDPOINT_OPT)
	if $(echo "$projects" | grep -qw "$PROJECT_NAME"); then
		echo "$PROJECT_NAME already created. Skipping..."
	else
		if [ -z "$DOCKER_DB" ]; then
			$SQSC_BIN project create $ENDPOINT_OPT -db-engine postgres -db-size small -node-size small -name "$PROJECT_NAME"
		else
			$SQSC_BIN project create $ENDPOINT_OPT -no-db -node-size small -name "$PROJECT_NAME"
		fi
	fi
	# All variables are defined before container launch to avoid
	# un-necessary re-scheduling due to environment changes
	set_env_vars
	if [ -n "$DOCKER_DB" ]; then
		# sqsc env get returns error if variable is not set already
		# and -e has been activated globally at the top of this script
		set +e
		dbpasswd=$($SQSC_BIN_CHECK env get $ENDPOINT_OPT -project "$PROJECT_NAME" POSTGRES_PASSWORD 2>/dev/null)
		if [ $? -ne 0 ] && [ -z "$dbpasswd" ]; then
			dbpasswd=$(pwgen 32 1)
		fi
		# Restore script failure on further errors
		set -e
		add_docker_database
	fi
	# To send notifications on #demoapp SquareScale Slack channel
	if [ -n "$($SQSC_BIN_CHECK project slackbot $ENDPOINT_OPT "$PROJECT_NAME")" ]; then
		echo "$PROJECT_NAME already configured with Slack. Skipping..."
	else
		$SQSC_BIN project slackbot $ENDPOINT_OPT "$PROJECT_NAME" https://hooks.slack.com/services/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
	fi
}

function set_env_vars(){
	# No need to check here as this will overwrite current values if any (therefore unchanged if same)
	set_env_var NODE_ENV production
	set_env_var RABBITMQ_HOST rabbitmq.service.consul
}

function display_env_vars(){
	$SQSC_BIN_CHECK env get $ENDPOINT_OPT -project "$PROJECT_NAME"
}

function show_repositories(){
	$SQSC_BIN_CHECK repository list $ENDPOINT_OPT -project "$PROJECT_NAME"
}

function show_containers(){
	$SQSC_BIN_CHECK container list $ENDPOINT_OPT -project "$PROJECT_NAME"
}

function add_services(){
	add_service \
		https://github.com/${REPO_BASE}/sqsc-demo-worker \
		squarescale/sqsc-demo-worker \
		"$([ -z "$DONT_BUILD_WORKER" ] ; echo $?)" \
		"${WORKER_BUILD_MODE:-"internal"}"
	add_service \
		https://github.com/${REPO_BASE}/sqsc-demo-app \
		squarescale/sqsc-demo-app \
		"$([ -z "$DONT_BUILD_APP" ] ; echo $?)" \
		"${APP_BUILD_MODE:-"travis"}"
	add_service "" rabbitmq 1
}

function set_lb(){
	lb_url=$($SQSC_BIN_CHECK lb list $ENDPOINT_OPT -project "$PROJECT_NAME")
	if $(echo "$lb_url" | grep -Eq "\[ \] ${REPO_BASE}/sqsc-demo-app:") || $(echo "$lb_url" | grep -Eq "state: disabled"); then
		$SQSC_BIN lb set $ENDPOINT_OPT -project "$PROJECT_NAME" -container ${REPO_BASE}/sqsc-demo-app -port 3000
	else
		echo "Load balancer already configured. Skipping..."
	fi
}

function show_url(){
	$SQSC_BIN lb url $ENDPOINT_OPT -project "$PROJECT_NAME"
}

create_project
add_services
set_lb

# Show all
display_env_vars
show_repositories
show_containers
show_url
