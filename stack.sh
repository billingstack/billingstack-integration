#!/bin/bash

set -x

SCRIPT_DIR=$(cd $(dirname $0) && pwd)
TOP_DIR=$SCRIPT_DIR/devstack


[[ ! -d $TOP_DIR ]] && {
    echo "You're missing Devstack as a submodule."
    exit 0
}


function log_error() {
    echo "ERROR -> $LINENO $@"
    exit 0
}


function load_sources() {
    for f in $@; do
        [ ! -r "$f" ] && log_error "Missing $f"
        source $f
    done
}


unset GREP_OPTIONS

# Import common functions
source $TOP_DIR/functions

# Determine what system we are running on.  This provides ``os_VENDOR``,
# ``os_RELEASE``, ``os_UPDATE``, ``os_PACKAGE``, ``os_CODENAME``
# and ``DISTRO``
GetDistro


# Global Settings
# ===============

# ``stack.sh`` is customizable through setting environment variables.  If you
# want to override a setting you can set and export it::
#
#     export DATABASE_PASSWORD=anothersecret
#     ./stack.sh
#
# You can also pass options on a single line ``DATABASE_PASSWORD=simple ./stack.sh``
#
# Additionally, you can put any local variables into a ``localrc`` file::
#
#     DATABASE_PASSWORD=anothersecret
#     DATABASE_USER=hellaroot
#
# We try to have sensible defaults, so you should be able to run ``./stack.sh``
# in most cases.  ``localrc`` is not distributed with DevStack and will never
# be overwritten by a DevStack update.
#
# DevStack distributes ``stackrc`` which contains locations for the OpenStack
# repositories, branches to configure, and other configuration defaults.
# ``stackrc`` sources ``localrc`` to allow you to safely override those settings.
load_sources $TOP_DIR/stackrc $SCRIPT_DIR/stackrc


echo "python-dev" >> $TOP_DIR/files/apts/billingstack


# Local Settings
# --------------

# Make sure the proxy config is visible to sub-processes
export_proxy_variables

# Destination path for installation ``DEST``
DEST=${DEST:-/opt/billingstack}


# Sanity Check
# ------------

# Clean up last environment var cache
if [[ -r $TOP_DIR/.stackenv ]]; then
    rm $TOP_DIR/.stackenv
fi

# ``stack.sh`` keeps the list of ``apt`` and ``rpm`` dependencies and config
# templates and other useful files in the ``files`` subdirectory
FILES=$TOP_DIR/files
if [ ! -d $FILES ]; then
    log_error $LINENO "missing devstack/files"
fi

# ``stack.sh`` keeps function libraries here
# Make sure ``$TOP_DIR/lib`` directory is present
if [ ! -d $TOP_DIR/lib ]; then
    log_error $LINENO "missing devstack/lib"
fi

# Import common services (database, message queue) configuration
source $TOP_DIR/lib/database
source $TOP_DIR/lib/rpc_backend

# Remove services which were negated in ENABLED_SERVICES
# using the "-" prefix (e.g., "-rabbit") instead of
# calling disable_service().
disable_negated_services

# Warn users who aren't on an explicitly supported distro, but allow them to
# override check and attempt installation with ``FORCE=yes ./stack``
if [[ ! ${DISTRO} =~ (oneiric|precise|quantal|raring|saucy|7.0|wheezy|sid|testing|jessie|f16|f17|f18|opensuse-12.2|rhel6) ]]; then
    echo "WARNING: this script has not been tested on $DISTRO"
    if [[ "$FORCE" != "yes" ]]; then
        die $LINENO "If you wish to run this script anyway run with FORCE=yes"
    fi
fi

# Make sure we only have one rpc backend enabled,
# and the specified rpc backend is available on your platform.
check_rpc_backend

# Set up logging level
VERBOSE=$(trueorfalse True $VERBOSE)


# root Access
# -----------

# OpenStack is designed to be run as a non-root user; Horizon will fail to run
# as **root** since Apache will not serve content from **root** user).  If
# ``stack.sh`` is run as **root**, it automatically creates a **stack** user with
# sudo privileges and runs as that user.

if [[ $EUID -eq 0 ]]; then
    ROOTSLEEP=${ROOTSLEEP:-10}
    echo "You are running this script as root."
    echo "In $ROOTSLEEP seconds, we will create a user '$STACK_USER' and run as that user"
    sleep $ROOTSLEEP

    # Give the non-root user the ability to run as **root** via ``sudo``
    is_package_installed sudo || install_package sudo
    if ! getent group $STACK_USER >/dev/null; then
        echo "Creating a group called $STACK_USER"
        groupadd $STACK_USER
    fi
    if ! getent passwd $STACK_USER >/dev/null; then
        echo "Creating a user called $STACK_USER"
        useradd -g $STACK_USER -s /bin/bash -d $DEST -m $STACK_USER
    fi

    echo "Giving stack user passwordless sudo privileges"
    # UEC images ``/etc/sudoers`` does not have a ``#includedir``, add one
    grep -q "^#includedir.*/etc/sudoers.d" /etc/sudoers ||
        echo "#includedir /etc/sudoers.d" >> /etc/sudoers
    ( umask 226 && echo "$STACK_USER ALL=(ALL) NOPASSWD:ALL" \
        > /etc/sudoers.d/50_stack_sh )

    echo "Copying files to $STACK_USER user"
    STACK_DIR="$DEST/${TOP_DIR##*/}"
    cp -r -f -T "$TOP_DIR" "$STACK_DIR"
    chown -R $STACK_USER "$STACK_DIR"
    cd "$STACK_DIR"
    if [[ "$SHELL_AFTER_RUN" != "no" ]]; then
        exec sudo -u $STACK_USER  bash -l -c "set -e; bash stack.sh; bash"
    else
        exec sudo -u $STACK_USER bash -l -c "set -e; source stack.sh"
    fi
    exit 1
else
    # We're not **root**, make sure ``sudo`` is available
    is_package_installed sudo || die "Sudo is required.  Re-run stack.sh as root ONE TIME ONLY to set up sudo."

    # UEC images ``/etc/sudoers`` does not have a ``#includedir``, add one
    sudo grep -q "^#includedir.*/etc/sudoers.d" /etc/sudoers ||
        echo "#includedir /etc/sudoers.d" | sudo tee -a /etc/sudoers

    # Set up devstack sudoers
    TEMPFILE=`mktemp`
    echo "$STACK_USER ALL=(root) NOPASSWD:ALL" >$TEMPFILE
    # Some binaries might be under /sbin or /usr/sbin, so make sure sudo will
    # see them by forcing PATH
    echo "Defaults:$STACK_USER secure_path=/sbin:/usr/sbin:/usr/bin:/bin:/usr/local/sbin:/usr/local/bin" >> $TEMPFILE
    chmod 0440 $TEMPFILE
    sudo chown root:root $TEMPFILE
    sudo mv $TEMPFILE /etc/sudoers.d/50_stack_sh

    # Remove old file
    sudo rm -f /etc/sudoers.d/stack_sh_nova
fi

# Create the destination directory and ensure it is writable by the user
sudo mkdir -p $DEST
sudo chown -R $STACK_USER $DEST

# a basic test for $DEST path permissions (fatal on error unless skipped)
check_path_perm_sanity ${DEST}

# Set ``OFFLINE`` to ``True`` to configure ``stack.sh`` to run cleanly without
# Internet access. ``stack.sh`` must have been previously run with Internet
# access to install prerequisites and fetch repositories.
OFFLINE=`trueorfalse False $OFFLINE`

# Set ``ERROR_ON_CLONE`` to ``True`` to configure ``stack.sh`` to exit if
# the destination git repository does not exist during the ``git_clone``
# operation.
ERROR_ON_CLONE=`trueorfalse False $ERROR_ON_CLONE`

# Destination path for service data
DATA_DIR=${DATA_DIR:-${DEST}/data}
sudo mkdir -p $DATA_DIR
sudo chown -R $STACK_USER $DATA_DIR


# Use color for logging output (only available if syslog is not used)
LOG_COLOR=`trueorfalse True $LOG_COLOR`

# Service startup timeout
SERVICE_TIMEOUT=${SERVICE_TIMEOUT:-60}


PBR_DIR=$DEST/pbr


# Configure Projects
# ==================

# Get project function libraries
source $TOP_DIR/lib/tls
source $SCRIPT_DIR/billingstack


# Interactive Configuration
# -------------------------

# Do all interactive config up front before the logging spew begins

# Generic helper to configure passwords
function read_password {
    XTRACE=$(set +o | grep xtrace)
    set +o xtrace
    var=$1; msg=$2
    pw=${!var}

    localrc=$TOP_DIR/localrc

    # If the password is not defined yet, proceed to prompt user for a password.
    if [ ! $pw ]; then
        # If there is no localrc file, create one
        if [ ! -e $localrc ]; then
            touch $localrc
        fi

        # Presumably if we got this far it can only be that our localrc is missing
        # the required password.  Prompt user for a password and write to localrc.
        echo ''
        echo '################################################################################'
        echo $msg
        echo '################################################################################'
        echo "This value will be written to your localrc file so you don't have to enter it "
        echo "again.  Use only alphanumeric characters."
        echo "If you leave this blank, a random default value will be used."
        pw=" "
        while true; do
            echo "Enter a password now:"
            read -e $var
            pw=${!var}
            [[ "$pw" = "`echo $pw | tr -cd [:alnum:]`" ]] && break
            echo "Invalid chars in password.  Try again:"
        done
        if [ ! $pw ]; then
            pw=`openssl rand -hex 10`
        fi
        eval "$var=$pw"
        echo "$var=$pw" >> $localrc
    fi
    $XTRACE
}



# Database Configuration

# To select between database backends, add the following to ``localrc``:
#
#    disable_service mysql
#    enable_service postgresql
#
# The available database backends are listed in ``DATABASE_BACKENDS`` after
# ``lib/database`` is sourced. ``mysql`` is the default.

initialize_database_backends && echo "Using $DATABASE_TYPE database backend" || echo "No database enabled"


# Queue Configuration

# Rabbit connection info
if is_service_enabled rabbit; then
    RABBIT_HOST=${RABBIT_HOST:-localhost}
    read_password RABBIT_PASSWORD "ENTER A PASSWORD TO USE FOR RABBIT."
fi


# Configure logging
# -----------------

# Draw a spinner so the user knows something is happening
function spinner() {
    local delay=0.75
    local spinstr='/-\|'
    printf "..." >&3
    while [ true ]; do
        local temp=${spinstr#?}
        printf "[%c]" "$spinstr" >&3
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b" >&3
    done
}

# Echo text to the log file, summary log file and stdout
# echo_summary "something to say"
function echo_summary() {
    if [[ -t 3 && "$VERBOSE" != "True" ]]; then
        kill >/dev/null 2>&1 $LAST_SPINNER_PID
        if [ ! -z "$LAST_SPINNER_PID" ]; then
            printf "\b\b\bdone\n" >&3
        fi
        echo -n -e $@ >&6
        spinner &
        LAST_SPINNER_PID=$!
    else
        echo -e $@ >&6
    fi
}

# Echo text only to stdout, no log files
# echo_nolog "something not for the logs"
function echo_nolog() {
    echo $@ >&3
}

# Set up logging for ``stack.sh``
# Set ``LOGFILE`` to turn on logging
# Append '.xxxxxxxx' to the given name to maintain history
# where 'xxxxxxxx' is a representation of the date the file was created
TIMESTAMP_FORMAT=${TIMESTAMP_FORMAT:-"%F-%H%M%S"}
if [[ -n "$LOGFILE" || -n "$SCREEN_LOGDIR" ]]; then
    LOGDAYS=${LOGDAYS:-7}
    CURRENT_LOG_TIME=$(date "+$TIMESTAMP_FORMAT")
fi

if [[ -n "$LOGFILE" ]]; then
    # First clean up old log files.  Use the user-specified ``LOGFILE``
    # as the template to search for, appending '.*' to match the date
    # we added on earlier runs.
    LOGDIR=$(dirname "$LOGFILE")
    LOGFILENAME=$(basename "$LOGFILE")
    mkdir -p $LOGDIR
    find $LOGDIR -maxdepth 1 -name $LOGFILENAME.\* -mtime +$LOGDAYS -exec rm {} \;
    LOGFILE=$LOGFILE.${CURRENT_LOG_TIME}
    SUMFILE=$LOGFILE.${CURRENT_LOG_TIME}.summary

    # Redirect output according to config

    # Copy stdout to fd 3
    exec 3>&1
    if [[ "$VERBOSE" == "True" ]]; then
        # Redirect stdout/stderr to tee to write the log file
        exec 1> >( awk '
                {
                    cmd ="date +\"%Y-%m-%d %H:%M:%S \""
                    cmd | getline now
                    close("date +\"%Y-%m-%d %H:%M:%S \"")
                    sub(/^/, now)
                    print
                    fflush()
                }' | tee "${LOGFILE}" ) 2>&1
        # Set up a second fd for output
        exec 6> >( tee "${SUMFILE}" )
    else
        # Set fd 1 and 2 to primary logfile
        exec 1> "${LOGFILE}" 2>&1
        # Set fd 6 to summary logfile and stdout
        exec 6> >( tee "${SUMFILE}" /dev/fd/3 )
    fi

    echo_summary "stack.sh log $LOGFILE"
    # Specified logfile name always links to the most recent log
    ln -sf $LOGFILE $LOGDIR/$LOGFILENAME
    ln -sf $SUMFILE $LOGDIR/$LOGFILENAME.summary
else
    # Set up output redirection without log files
    # Copy stdout to fd 3
    exec 3>&1
    if [[ "$VERBOSE" != "True" ]]; then
        # Throw away stdout and stderr
        exec 1>/dev/null 2>&1
    fi
    # Always send summary fd to original stdout
    exec 6>&3
fi

# Set up logging of screen windows
# Set ``SCREEN_LOGDIR`` to turn on logging of screen windows to the
# directory specified in ``SCREEN_LOGDIR``, we will log to the the file
# ``screen-$SERVICE_NAME-$TIMESTAMP.log`` in that dir and have a link
# ``screen-$SERVICE_NAME.log`` to the latest log file.
# Logs are kept for as long specified in ``LOGDAYS``.
if [[ -n "$SCREEN_LOGDIR" ]]; then

    # We make sure the directory is created.
    if [[ -d "$SCREEN_LOGDIR" ]]; then
        # We cleanup the old logs
        find $SCREEN_LOGDIR -maxdepth 1 -name screen-\*.log -mtime +$LOGDAYS -exec rm {} \;
    else
        mkdir -p $SCREEN_LOGDIR
    fi
fi


# Set Up Script Execution
# -----------------------

# Kill background processes on exit
trap clean EXIT
clean() {
    local r=$?
    kill >/dev/null 2>&1 $(jobs -p)
    exit $r
}


# Exit on any errors so that errors don't compound
trap failed ERR
failed() {
    local r=$?
    kill >/dev/null 2>&1 $(jobs -p)
    set +o xtrace
    [ -n "$LOGFILE" ] && echo "${0##*/} failed: full log in $LOGFILE"
    exit $r
}

# Print the commands being run so that we can see the command that triggers
# an error.  It is also useful for following along as the install occurs.
set -o xtrace


# Install Packages
# ================

# OpenStack uses a fair number of other projects.

# Install package requirements
# Source it so the entire environment is available
echo_summary "Installing package prerequisites"
source $TOP_DIR/tools/install_prereqs.sh

install_rpc_backend

echo "$DATABASE_BACKENDS"
if is_service_enabled $DATABASE_BACKENDS; then
    install_database
fi


TRACK_DEPENDS=${TRACK_DEPENDS:-False}

# Install python packages into a virtualenv so that we can track them
if [[ $TRACK_DEPENDS = True ]]; then
    echo_summary "Installing Python packages into a virtualenv $DEST/.venv"
    install_package python-virtualenv

    rm -rf $DEST/.venv
    virtualenv --system-site-packages $DEST/.venv
    source $DEST/.venv/bin/activate
    $DEST/.venv/bin/pip freeze > $DEST/requires-pre-pip
fi



echo_summary "Installing BS"

# Install pbr
git_clone $PBR_REPO $PBR_DIR $PBR_BRANCH
setup_develop $PBR_DIR


if is_service_enabled billingstack; then
    install_bs
    configure_bs
fi


if [[ $TRACK_DEPENDS = True ]]; then
    $DEST/.venv/bin/pip freeze > $DEST/requires-post-pip
    if ! diff -Nru $DEST/requires-pre-pip $DEST/requires-post-pip > $DEST/requires.diff; then
        cat $DEST/requires.diff
    fi
    echo "Ran stack.sh in depend tracking mode, bailing out now"
    exit 0
fi


# Syslog
# ------

if [[ $SYSLOG != "False" ]]; then
    if [[ "$SYSLOG_HOST" = "$HOST_IP" ]]; then
        # Configure the master host to receive
        cat <<EOF >/tmp/90-stack-m.conf
\$ModLoad imrelp
\$InputRELPServerRun $SYSLOG_PORT
EOF
        sudo mv /tmp/90-stack-m.conf /etc/rsyslog.d
    else
        # Set rsyslog to send to remote host
        cat <<EOF >/tmp/90-stack-s.conf
*.*		:omrelp:$SYSLOG_HOST:$SYSLOG_PORT
EOF
        sudo mv /tmp/90-stack-s.conf /etc/rsyslog.d
    fi

    RSYSLOGCONF="/etc/rsyslog.conf"
    if [ -f $RSYSLOGCONF ]; then
        sudo cp -b $RSYSLOGCONF $RSYSLOGCONF.bak
        if [[ $(grep '$SystemLogRateLimitBurst' $RSYSLOGCONF)  ]]; then
            sudo sed -i 's/$SystemLogRateLimitBurst\ .*/$SystemLogRateLimitBurst\ 0/' $RSYSLOGCONF
        else
            sudo sed -i '$ i $SystemLogRateLimitBurst\ 0' $RSYSLOGCONF
        fi
        if [[ $(grep '$SystemLogRateLimitInterval' $RSYSLOGCONF)  ]]; then
            sudo sed -i 's/$SystemLogRateLimitInterval\ .*/$SystemLogRateLimitInterval\ 0/' $RSYSLOGCONF
        else
            sudo sed -i '$ i $SystemLogRateLimitInterval\ 0' $RSYSLOGCONF
        fi
    fi

    echo_summary "Starting rsyslog"
    restart_service rsyslog
fi


# Finalize queue installation
# ----------------------------
restart_rpc_backend


# Configure database
# ------------------

if is_service_enabled $DATABASE_BACKENDS; then
    configure_database
fi


# Initialize the directory for service status check
init_service_check


if is_service_enabled zeromq; then
    echo_summary "Starting zermomq receiver"
    screen_it zeromq "cd $NOVA_DIR && $NOVA_BIN_DIR/nova-rpc-zmq-receiver"
fi


if is_service_enabled billingstack; then
    echo_summary "Configuring BS"
    init_bs
    echo_summary "Starting BS"
    start_bs
fi


# Save some values we generated for later use
CURRENT_RUN_TIME=$(date "+$TIMESTAMP_FORMAT")
echo "# $CURRENT_RUN_TIME" >$TOP_DIR/.stackenv
for i in BASE_SQL_CONN ENABLED_SERVICES HOST_IP LOGFILE \
      SERVICE_HOST SERVICE_PROTOCOL STACK_USER TLS_IP; do
    echo $i=${!i} >>$TOP_DIR/.stackenv
done


service_check


# Fin
# ===

set +o xtrace

if [[ -n "$LOGFILE" ]]; then
    exec 1>&3
    # Force all output to stdout and logs now
    exec 1> >( tee -a "${LOGFILE}" ) 2>&1
else
    # Force all output to stdout now
    exec 1>&3
fi


# Using the cloud
# ---------------

echo ""
echo ""
echo ""
