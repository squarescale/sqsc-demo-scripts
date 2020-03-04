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
# APP_DOCKER_IMAGE:      default to squarescale/sqsc-demo-app

SCRIPT_VERSION="1.1-2020-03-04"

# Exit on errors
set -e

# Set project name according to 1st argument on command line or default
# Convert to lower-case to avoid later errors
PROJECT_NAME=$(echo ${1:-"sqsc-demo"} | tr '[A-Z]' '[a-z]')

# Look up for sqsc CLI binary in PATH
SQSC_BIN=$(command -v sqsc)
SQSC_BIN_CHECK=$SQSC_BIN
# Show calls to sqsc instead of executing them
if [ -n "$DRY_RUN" ]; then
	SQSC_BIN="echo $SQSC_BIN"
fi

if [ -z "$SQSC_TOKEN" ]; then
	echo "You need to set SQSC_TOKEN to an existing and active API key in your account"
	exit 1
fi

# Set default enpoint (none => production aka http://www.squarescale.io)
if [ -n "$ENDPOINT" ]; then
	if [ -n "$SQSC_ENDPOINT" ] && [ "$ENDPOINT" != "$SQSC_ENDPOINT" ]; then
		echo "ENDPOINT variable ($ENDPOINT) will superseed SQSC_ENDPOINT ($SQSC_ENDPOINT)"
		unset SQSC_ENDPOINT
	fi
	ENDPOINT_OPT="-endpoint $ENDPOINT"
fi

# Check current SquareScale endpoint status
$SQSC_BIN status $ENDPOINT_OPT || $SQSC_BIN login $ENDPOINT_OPT

# Function which creates a service
#
# Parameters:
# 1) Docker Hub container image name
#
function add_service() {
	container_image=$(echo "$1" | awk -F/ '{print $NF}')
	cur_containers=$(show_containers)
	if $(echo "$cur_containers" | grep -Eq "^${container_image}\s\s*"); then
		echo "$PROJECT_NAME already configured with service container $container_image. Skipping..."
	else
		echo "Adding container service $container_image"
		$SQSC_BIN image add $ENDPOINT_OPT -project "$PROJECT_NAME" -name "$1"
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
	add_service ${POSTGRES_DOCKER_IMAGE:-postgres}
}

# Function creating the project
# this is the main entry point
function create_project(){
	projects=$($SQSC_BIN_CHECK project list $ENDPOINT_OPT)
	if $(echo "$projects" | grep -Eq "^${PROJECT_NAME}\s\s*"); then
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

function show_containers(){
	$SQSC_BIN_CHECK container list $ENDPOINT_OPT -project "$PROJECT_NAME"
}

function add_services(){
	add_service ${WORKER_DOCKER_IMAGE:-squarescale/sqsc-demo-worker}
	add_service ${APP_DOCKER_IMAGE:-squarescale/sqsc-demo-app}
	add_service ${RABBITMQ_DOCKER_IMAGE:-rabbitmq}
}

function set_lb(){
	lb_url=$($SQSC_BIN_CHECK lb list $ENDPOINT_OPT -project "$PROJECT_NAME")
	if $(echo "$lb_url" | grep -Eq "\[ \] sqsc-demo-app:") || $(echo "$lb_url" | grep -Eq "state: disabled"); then
		$SQSC_BIN lb set $ENDPOINT_OPT -project "$PROJECT_NAME" -container sqsc-demo-app -port 3000
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
show_containers
show_url
