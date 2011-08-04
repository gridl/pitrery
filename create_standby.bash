#!@BASH@
#
# Copyright 2011 Nicolas Thauvin. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE AUTHORS ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#

# Hardcoded Configuration
remote_pgdata=
local_pgdata=
remote_psql="/usr/bin/psql"
archive_store=/var/lib/pgsql/archived_xlog
pg_standby="/usr/bin/pg_standby -d -k 64"
pg_standby_trigger="$local_pgdata/stop_standby"
pg_standby_append="2>&1 | logger -t pg_standby -p local1.info"

# Functions 
stop_backup() {

    # Block signals, this is a signal handler
    trap '' INT TERM EXIT

    # Run pg_stop_backup() on the master
    echo "INFO: stop backup"
    ssh ${master} "${remote_psql} -Atc \"SELECT pg_stop_backup();\" postgres"
    if [ $? != 0 ]; then
	# TODO: retry ??
        echo "ERROR: could not stop backup process" 1>&2
        exit 1
    fi

    # Reset the signal handler
    trap - INT TERM KILL EXIT
}

start_backup() {
    slave=`hostname`

    # Run pg_start_backup() on the master
    echo "INFO: start backup"
    current_xlog=`ssh ${master} "${remote_psql} -Atc \"SELECT pg_xlogfile_name(pg_start_backup('init_${slave}'));\" postgres"`
    if [ $? != 0 ]; then
	echo "ERROR: could not start backup process" 1>&2
	exit 1
    fi

    echo "INFO: WAL segment $current_xlog and following must be properly archived"

    # Run stop_backup when script is interrupted, terminated, killed or the script exits during
    # the backup process
    trap stop_backup INT TERM KILL EXIT

}

usage() {
    echo "usage: `basename $0` [options] master"
    echo "options:"
    echo "    -C config        Path to the configuration file"
    echo
    echo "    -h               Print help"
    echo
    exit $1
}

# CLI options
args=`getopt "C:h" $*`
if [ $? -ne 0 ]
then
    usage 2
fi

set -- $args
for i in $*
do
    case "$i" in
	-C) config_file=$2; shift 2;;
	-h) usage 1;;
	--) shift; break;;
    esac
done

if [ $# != 1 -o -z "$1" ]; then
    echo "ERROR: missing primary hostname or IP address" 1>&2
    usage 1
fi

master=$1

# Load configuration file
if [ -n "$config_file" ]; then
    if [ -f $config_file ]; then
    . $config_file
    else
	echo "ERROR: could not find configuration file: $config_file" 1>&2
	exit 1
    fi
fi

# first check if the target is not running
if [ -f $local_pgdata/postmaster.pid ]; then
    echo "ERROR: $local_pgdata/postmaster.pid exists. The target instance maybe running" 1>&2
    exit 1
fi

# start the backup process and get the xlogfilename to check if archiving is working
start_backup

# save other node
echo "INFO: rsync of ${master}:${remote_pgdata} to $local_pgdata"
rsync -a --exclude=postmaster.* --exclude=pg_xlog/* --exclude=recovery.* ${master}:${remote_pgdata}/ $local_pgdata

# copy any tablespaces
tblspc_list=`ssh ${master} "find $remote_pgdata/pg_tblspc -type l -exec readlink '{}' ';'"`
if [ $? != 0 ]; then
    echo "ERROR: could not get the list of tablespaces" 1>&2
else
    for tblspc in $tblspc_list; do
	if [ ! -d $tblspc ]; then
	    mkdir -p $tblspc
	    if [ $? != 0 ]; then
		echo "ERROR: could not create tablespace location: $tblspc" 1>&2
		stop_backup
		exit 1
	    fi
	fi
	echo "INFO: rsync of tablespace ${master}:$tblspc to $tblspc"
	rsync -a ${master}:$tblspc/ $tblspc
    done
fi

# stop the backup process
stop_backup

# check if pg_xlog is a symlink and create/empty dir if needed
echo "INFO: creation of pg_xlog directory if needed"
if [ -L $local_pgdata/pg_xlog ]; then
    target=`readlink $local_pgdata/pg_xlog`
    if [ ! -d $target ]; then
	mkdir -p $target
	if [ $? != 0 ]; then
	    echo "ERROR: could not create pg_xlog target directory: $target" 1>&2
	    exit 1
	fi
    fi
fi

# Empty pg_xlog directory
echo "INFO: remove contents of pg_xlog"
rm -f $local_pgdata/pg_xlog/*

# check if pg_xlog/archive_status exists
if [ ! -d $local_pgdata/pg_xlog/archive_status ]; then
    echo "INFO: creation of $local_pgdata/pg_xlog/archive_status"
    mkdir $local_pgdata/pg_xlog/archive_status
    if [ $? != 0 ]; then
	echo "ERROR: could not create $local_pgdata/pg_xlog/archive_status" 1>&2
    fi
fi

# create recovery.conf
if [ -f "$pg_standby_trigger" ]; then
    echo "INFO: found a standby trigger file, remove it"
    rm $pg_standby_trigger
fi

echo "INFO: creation of $local_pgdata/recovery.conf"
echo "restore_command = '$pg_standby -t $pg_standby_trigger $archive_store %f %p $pg_standby_append'" > $local_pgdata/recovery.conf