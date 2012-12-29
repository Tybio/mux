#!/bin/bash
#
# Features:
#  * Lock file 
#	Newznab does not protect the DB when it runs, having two scripts updating
#	the Database WILL cause corruption
#  * Logging
#	Normal update status is redirected to a configurable log file, can be used
#	with example logrotate.conf.
#  * Built for Cron
#	With only errors reported to the caller, the script is built to be run
#	from within cron
#  * Scheduled Optimization
#  * Advanced Newznab processing support
#	Enable/Disable nzb-importmodified.php and update_parsing.php
#
# Options:
#
#	-q:	Quiet Mode (Errors only to shell, all other messages to log)
#	-t:	Use threaded update_binaries
#       -h:	Help
#	-v:	Version
#	-o:	Force Opt to run
#	-p:	Enable enhanced post-processing
#	-i:	Run nzb-importmodified.php	
#
# Configuration
#
# Check if there is an unRAID plugin config file
#
if [ -f /boot/config/plugins/newznab_extras/newznab_extras.cfg ]; then
	[ -f /tmp/vars.tmp ] && rm /tmp/vars.tmp
	grep -v "^\\[" /boot/config/plugins/newznab_extras/newznab_extras.cfg | sed -e 's/ = /=/g' > /tmp/vars.tmp
	source /tmp/vars.tmp
	[ -f /tmp/vars.tmp ] && rm /tmp/vars.tmp
	NEWZNAB_BASE=$CRON_BASE
	IMPORT_DIR=$CRON_IMPDIR
	OPT_INT=$CRON_OINT
else
	#
	# If running manually, edit these values
	#
	# Set to the directory where Newznab is installed
	NEWZNAB_BASE="/mnt/cache/AppData/Newznab"
	#
	# Set to the directory where NZBs to import are located
	IMPORT_DIR="/mnt/cache/AppData/Newznab/tempnzbs"
	#
	# Interval to run optimization
	OPT_INT=43200
	#
	# Debugging, leave off unless you need it
	#set -xv
fi

# Don't edit below here unless you know what you are doing
###################################################################################################

while getopts :qthopi opt
do
	case $opt in
	v)  echo "`basename $0 .sh`: Newznab cron script by Tybio"
            exit 0;;
	q)  QUIET=1;;
	t)  THREAD=1;;
	h)  HELP=1;;
	p)  PP=1;;
	o)  DOOPT=1;;
	i)  IMP=1;;
	esac
done

[ "$HELP" ] && echo "`basename $0 .sh` [-q|h]"
[ "$HELP" ] && exit 1

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
			db "$data"
		done
	fi
}
#####################
#
# Check to see if the config file wants to enable options
#
[ "$CRON_THREAD" == "enable" ] && THREAD=1
[ "$CRON_PP" == "enable" ] && PP=1
[ "$CRON_IMP" == "enable" ] && IMP=1


CURRTIME=`date +%s`

LOCKFILE="/tmp/nn-cron.lock"
trap "rm -f ${LOCKFILE}; exit" INT TERM 

# If the lockfile exists, and the process is still running then exit
if [ -e ${LOCKFILE} ]; then
        LOCKFILE_AGE=$(find ${LOCKFILE} -mmin +119)
        if [ -n $LOCKFILE_AGE ];then
                log "ERROR: $LOCKFILE found, exiting"
                exit
        else
                log"ERROR: $LOCKFILE is $LOCKFILE_AGE, removing it and continuing"
                kill -TERM -`cat ${LOCKFILE}`
                echo $$ > ${LOCKFILE}
        fi
else
	log echo "INFO: Creating lock file"
	echo $$ > ${LOCKFILE}
fi

if [ $IMP ]; then
	if [ ! -d "$IMPORT_DIR" ]; then
		log "ERROR: $IMPORT_DIR does not exist, create or remove import option"
		exit 1
	fi
fi

log echo "INFO: Setting Variables"

NEWZNAB_PATH="$NEWZNAB_BASE/misc/update_scripts"
NEWZNAB_LAST_OPT="/tmp/nn-opt-last.txt"
PHPBIN="/usr/bin/php"

if [ ! -e $NEWZNAB_LAST_OPT ]; then
	log "INFO: $NEWZNAB_LAST_OPT not found, creating."
	echo "$CURRTIME" > /tmp/nn-opt-last.txt
	DOOPT=1
else
	LASTOPT=$(<$NEWZNAB_LAST_OPT)
	DIFF=$((CURRTIME - LASTOPT))
	if [ "$DIFF" -gt $OPT_INT ] || [ "$DIFF" -lt 1 ]; then
		DOOPT=1
		log "INFO: Timer expired, flagging to run Optimization."
	else
		NEXTOPT=$((OPT_INT - DIFF))
		NEXTOPTM=$(($NEXTOPT/60))
		log "INFO: Skipped Optimization, timer expires in $NEXTOPTM minutes"
	fi
		
fi

cd ${NEWZNAB_PATH}
if [ $THREAD ]; then
	log "INFO: Updating binaries (Threaded)"
	$PHPBIN ${NEWZNAB_PATH}/update_binaries_threaded.php | log
else
	log "INFO: Updating binaries"
	$PHPBIN ${NEWZNAB_PATH}/update_binaries.php | log
fi

[ ! "$QUIET" ] && echo "INFO: Updating releases"
$PHPBIN ${NEWZNAB_PATH}/update_releases.php | log
if [ $IMP ]; then
	IMP_NZB_C=`ls -alh ${IMPORT_DIR} | wc -l`
	log "INFO: Importing NZBs, $IMP_NZB_C waiting."
	$PHPBIN ${NEWZNAB_BASE}/www/admin/nzb-importmodified.php ${IMPORT_DIR} true | log
	IMP_NZB_P=`ls -alh ${IMPORT_DIR} | wc -l`
	log "INFO: Imported NZBs, $IMP_NZB_P left."
	log "INFO: Updating releases"
	$PHPBIN ${NEWZNAB_PATH}/update_releases.php | log
fi

if [ $DOOPT ]; then
	log "INFO: Starting optimization..."
	log "INFO: Optimizing DB"
	$PHPBIN ${NEWZNAB_PATH}/optimise_db.php | log
	log INFO: Getting TV Schedule"
	$PHPBIN ${NEWZNAB_PATH}/update_tvschedule.php | log
	log INFO: Getting Movie Times"
	$PHPBIN ${NEWZNAB_PATH}/update_theaters.php | log
	if [ $PP ]; then
		log "INFO: Updating Release Parsing"
		$PHPBIN ${NEWZNAB_BASE}/misc/testing/update_parsing.php | log
	fi
	log "INFO: Setting timestamp"
	echo "$CURRTIME" > /tmp/nn-opt-last.txt
fi

EDATE=`date`
ETIME=`date +%s`
RUNTIME=$(($ETIME - $CURRTIME))
RMIN=$(($RUNTIME/60))
echo "INFO: Finished at $EDATE, taking $RMIN minutes, exiting." | log
rm $LOCKFILE
