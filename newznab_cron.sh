#!/bin/bash
#
# Features:
#  * Lock file 
#  * Logging
#  * Built for Cron
#  * Scheduled Optimization
#  * Advanced Newznab processing support
#	
###################################
#  Use:
#
#  This script can be called from the command line, or via cron.  There are a great
#     many options, but to start the defaults should work well enough.
#
#  If you are not running via the unRAID plugin, edit the variables:
#
#	  CRON_BASE:    directory where Newznab is installed (eg: /var/www/nnplus )
#	  CRON_IMPDIR:  Directory containing nzb files to import (Only needed if -i passed)
#    
#   The other variables are optional, they are set to solid defaults.  You control what
#      the script does from here with flags:
#
#   Examples:
#
#     newznab_cron.sh -t -i             Threaded, Import NZBs
#     newznab_cron.sh -p -c -t          Update Parsing, Cleanup, Threaded
#
#  To add to cron, make sure you are the user who normally runs the update process
#     and enter 'crontab -e' at the prompt.  Then add the following line to the bottom
#
#  */5 * * * * /<PATH>/newznab_cron.sh
#
# #################################
#
# Options:
#  (All credit to overbyrn on the unRAID forums for creating the help section)
#
shorthelp='Usage: '"$(basename "${0}")"' [--help] [-v] [-t] [-p] [-c] [-o] [-i]'
longhelp='This script is designed to control the running of serveral Newznab scripts
helping to protect the database as Newznab does not protect the DB when it runs.

Explanation of the options:

    -v                  version of this script.
						
    -t                  Use threaded version of update_binaries.php
												
    -p                  Enable additional post-processing script;				
			update_parsing.php
			This script updates release names for releases in 
			"TV > Other" (5050), "Movie > Other" (2020), and 
			"Other > Misc" (7010) categories.
			
    -c                  Enable additional release clean-up script;
			update_cleanup.php
			This script removes releases based on a preset list of
			criteria in the last 24 hours.
			
			ATTENTION: as standard, update_cleanup.php is configured
			to only echo proposed changes.  Script must be edited
			before changes are made to the database.  See comments in
			the script for what changes are required.
			
    -o                  Force Optimization to run.
	
    -i                  Run nzb-importmodified.php'
	
# Is the user asking for extensive help?
if [[ "$*" == *--help* ]]; then
	echo -e "$shorthelp""\n""$longhelp"
	exit
fi

# Configuration
#
# Check if there is an unRAID plugin config file
#
if [ -f /boot/config/plugins/newznab_extras/newznab_extras.cfg ]; then
	[ -f /tmp/vars.tmp ] && rm /tmp/vars.tmp
	grep -v "^\\[" /boot/config/plugins/newznab_extras/newznab_extras.cfg | sed -e 's/ = /=/g' > /tmp/vars.tmp
	source /tmp/vars.tmp
	[ -f /tmp/vars.tmp ] && rm /tmp/vars.tmp
else
	#
	# If running manually, edit these values
	#
	# Set to the directory where Newznab is installed
	CRON_BASE="/mnt/cache/AppData/Newznab"
	#
	# Set to the directory where NZBs to import are located
	CRON_IMPDIR="/mnt/cache/AppData/Newznab/tempnzbs"
	#
	# Interval to run optimization
	CRON_OINT=43200
	#
	# Number of nzbs to import each cycle
	CRON_IMPNUM=100
	# Debugging, leave off unless you need it
	#set -xv
fi

# Don't edit below here unless you know what you are doing
###################################################################################################

while getopts :qthopci? opt
do
	case $opt in
	v)  echo "`basename $0 .sh`: Newznab cron script by Tybio"
            exit 0;;
	t)  CRON_THREAD="enable";;
	p)  CRON_PP="enable";;
	o)  DOOPT="enable";;
	c)	CRON_CLEAN="enable";;
	i)  CRON_IMP="enable";;
	?)  echo $shorthelp; exit 2;;
	h)  echo $shorthelp; exit 2;;
	esac
done

# Log file
LOG_FILE="/var/log/newznab_cron.log"

function log {
	# If there are parameters read from parameters
	if [ $# -gt 0 ]; then
		echo "[$(date +"%D %T")] $@" >> $LOG_FILE
		[ $DEBUG ] && echo "[$(date +"%D %T")] $@"
	else 
    # If there are no parameters read from stdin
	while read data
		do
			echo "[$(date +"%D %T")] $data" >> $LOG_FILE 
			[ $DEBUG ] && echo "$data"
		done
	fi
}

CURRTIME=`date +%s`

LOCKFILE="/tmp/newznab_cron.pid"
trap "rm -f ${LOCKFILE}; exit" INT TERM 

# If the lockfile exists, and the process is still running then exit
if [ -e ${LOCKFILE} ]; then
	if test `find ${LOCKFILE} -mmin +119`; then
		log "ERROR: $LOCKFILE is stale, removing it and continuing"
		kill -TERM -`cat ${LOCKFILE}`
		echo $$ > ${LOCKFILE}
	else
		log "ERROR: $LOCKFILE found, exiting"
		exit
	fi
else
	log "INFO: Creating lock file"
	echo $$ > ${LOCKFILE}
fi

if [ $IMP ]; then
	if [ ! -d "$CRON_IMPDIR" ]; then
		log "ERROR: $CRON_IMPDIR does not exist, create or remove import option"
		exit 1
	fi
fi

log "INFO: Setting Variables"

NEWZNAB_PATH="$CRON_BASE/misc/update_scripts"
NEWZNAB_LAST_OPT="/tmp/nn-opt-last.txt"
PHPBIN="/usr/bin/php"

if [ ! -e $NEWZNAB_LAST_OPT ]; then
	log "INFO: $NEWZNAB_LAST_OPT not found, creating."
	echo "$CURRTIME" > /tmp/nn-opt-last.txt
	DOOPT="enable"
else
	LASTOPT=$(<$NEWZNAB_LAST_OPT)
	DIFF=$((CURRTIME - LASTOPT))
	if [ "$DIFF" -gt "$CRON_OINT" ] || [ "$DIFF" -lt 1 ]; then
		DOOPT="enable"
		log "INFO: Timer expired, flagging to run Optimization."
	else
		NEXTOPT=$((OPT_INT - DIFF))
		NEXTOPTM=$(($NEXTOPT/60))
		log "INFO: Skipped Optimization, timer expires in $NEXTOPTM minutes"
	fi
		
fi

cd ${NEWZNAB_PATH}
if [ "$CRON_THREAD" = "enable" ]; then
	log "INFO: Updating binaries (Threaded)"
	$PHPBIN ${NEWZNAB_PATH}/update_binaries_threaded.php | log
else
	log "INFO: Updating binaries"
	$PHPBIN ${NEWZNAB_PATH}/update_binaries.php | log
fi

log "INFO: Updating releases"
$PHPBIN ${NEWZNAB_PATH}/update_releases.php 2> /dev/null | log
if [ "$CRON_IMP" = "enable" ]; then
	IMP_NZB_C=`ls -alh ${CRON_IMPDIR} | wc -l`
	log "INFO: Importing NZBs, $IMP_NZB_C waiting."
	$PHPBIN ${CRON_BASE}/www/admin/nzb-import.php ${CRON_IMPDIR} true ${CRON_IMPNUM} 10000 | log 
	IMP_NZB_P=`ls -alh ${CRON_IMPDIR} | wc -l`
	log "INFO: Imported NZBs, $IMP_NZB_P left."
	log "INFO: Updating releases"
	$PHPBIN ${NEWZNAB_PATH}/update_releases.php 2> /dev/null | log
fi

if [ "$DOOPT" = "enable" ]; then
	log "INFO: Starting optimization..."
	# Need to find a quick check for Inno DBs here so we can skip this.
	# Leaving it in right now as most DBs are still default
	log "INFO: Optimizing DB"
	$PHPBIN ${NEWZNAB_PATH}/optimise_db.php | log
	log "INFO: Getting TV Schedule"
	$PHPBIN ${NEWZNAB_PATH}/update_tvschedule.php | log
	log "INFO: Getting Movie Times"
	$PHPBIN ${NEWZNAB_PATH}/update_theaters.php | log
	if [ "$CRON_PP" = "enable" ]; then
		log "INFO: Updating Release Parsing"
		$PHPBIN ${CRON_BASE}/misc/testing/update_parsing.php | log
	fi
	if [ "$CRON_CLEAN" = "enable" ]; then
		log "INFO: Cleaning up useless releases (Be sure you have edited update_cleanup.php or it will not actually do anything)"
		$PHPBIN ${CRON_BASE}/misc/testing/update_cleanup.php | log
	fi
	log "INFO: Setting timestamp"
	echo "$CURRTIME" > /tmp/nn-opt-last.txt
fi

EDATE=`date`
ETIME=`date +%s`
RUNTIME=$(($ETIME - $CURRTIME))
RMIN=$(($RUNTIME/60))
log "INFO: Finished at $EDATE, taking $RMIN minutes, exiting." | log
rm $LOCKFILE
