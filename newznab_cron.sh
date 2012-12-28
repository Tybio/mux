#!/bin/bash
# call this script from within screen to get binaries, processes releases and 
# every half day get tv/theatre info and optimise the database
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
if [ -f /boot/config/plugins/newznab_extras/newznab_cron.cfg ]; then
	source /boot/config/plugins/newznab_extras/newznab_cron.cfg
	NEWZNAB_BASE=CRON_BASE
	IMPORT_DIR=CRON_IMPDIR
	OPT_INT=CRON_OINT
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
	# Log file
	LOG="/var/log/cron_newznab.log"
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

#####################
#
# Check to see if the config file wants to enable options
#
[ "$CRON_THREAD" == "enable"] && THREAD=1
[ "$CRON_PP" == "enable"] && PP=1
[ "$CRON_IMP" == "enable"] && IMP=1


CURRTIME=`date +%s`

LOCKFILE="/tmp/nn-cron.lock"
trap "rm -f ${LOCKFILE}; exit" INT TERM 

# If the lockfile exists, and the process is still running then exit
if [ -e ${LOCKFILE} ]; then
        LOCKFILE_AGE=$(find ${LOCKFILE} -mmin +119)
        if [ -n $LOCKFILE_AGE ];then
                [ ! "$QUIET" ] && echo "ERROR: $LOCKFILE found, exiting"
                exit
        else
                echo "ERROR: $LOCKFILE is $LOCKFILE_AGE, removing it and continuing"
                kill -TERM -`cat ${LOCKFILE}`
                echo $$ > ${LOCKFILE}
        fi
else
	[ ! "$QUIET" ] && echo "INFO: Creating lock file"
	echo $$ > ${LOCKFILE}
fi

if [ $IMP ]; then
	if [ ! -d "$IMPORT_DIR" ]; then
		echo "ERROR: $IMPORT_DIR does not exist, create or remove import option"
		exit 1
	fi
fi

[ ! "$QUIET" ] && echo "INFO: Setting Variables"

NEWZNAB_PATH="$NEWZNAB_BASE/misc/update_scripts"
NEWZNAB_LAST_OPT="/tmp/nn-opt-last.txt"
PHPBIN="/usr/bin/php"

if [ ! -e $NEWZNAB_LAST_OPT ]; then
	[ ! "$QUIET" ] && echo "INFO: $NEWZNAB_LAST_OPT not found, creating."
	echo "$CURRTIME" > /tmp/nn-opt-last.txt
	DOOPT=1
else
	LASTOPT=$(<$NEWZNAB_LAST_OPT)
	DIFF=$((CURRTIME - LASTOPT))
	if [ "$DIFF" -gt $OPT_INT ] || [ "$DIFF" -lt 1 ]; then
		DOOPT=1
		[ ! "$QUIET" ] && echo "INFO: Timer expired, flagging to run Optimization."
	else
		NEXTOPT=$((OPT_INT - DIFF))
		NEXTOPTM=$(($NEXTOPT/60))
		[ ! "$QUIET" ] && echo "INFO: Skipped Optimization, timer expires in $NEXTOPTM minutes"
	fi
		
fi

cd ${NEWZNAB_PATH}
if [ $THREAD ]; then
	echo "INFO: Updating binaries (Threaded)"
	$PHPBIN ${NEWZNAB_PATH}/update_binaries_threaded.php >> $LOG 2>&1
else
	echo "INFO: Updating binaries"
	$PHPBIN ${NEWZNAB_PATH}/update_binaries.php >> $LOG 2>&1
fi

[ ! "$QUIET" ] && echo "INFO: Updating releases"
$PHPBIN ${NEWZNAB_PATH}/update_releases.php >> $LOG 2>&1
if [ $IMP ]; then
	IMP_NZB_C=`ls -alh ${IMPORT_DIR} | wc -l`
	[ ! "$QUIET" ] && echo "INFO: Importing NZBs, $IMP_NZB_C waiting."
	$PHPBIN ${NEWZNAB_BASE}/www/admin/nzb-importmodified.php ${IMPORT_DIR} true >> $LOG 2>&1
	IMP_NZB_P=`ls -alh ${IMPORT_DIR} | wc -l`
	[ ! "$QUIET" ] && echo "INFO: Imported NZBs, $IMP_NZB_P left."
	[ ! "$QUIET" ] && echo "INFO: Updating releases"
	$PHPBIN ${NEWZNAB_PATH}/update_releases.php >> $LOG 2>&1
fi

if [ $DOOPT ]; then
	echo "INFO: Starting optimization..." >> $LOG
	[ ! "$QUIET" ] && echo "INFO: Optimizing DB"
	$PHPBIN ${NEWZNAB_PATH}/optimise_db.php >> $LOG 2>&1
	[ ! "$QUIET" ] && echo "INFO: Getting TV Schedule"
	$PHPBIN ${NEWZNAB_PATH}/update_tvschedule.php >> $LOG 2>&1
	[ ! "$QUIET" ] && echo "INFO: Getting Movie Times"
	$PHPBIN ${NEWZNAB_PATH}/update_theaters.php >> $LOG 2>&1
	if [ $PP ]; then
		[ ! "$QUIET" ] && echo "INFO: Updating Release Parsing"
		$PHPBIN ${NEWZNAB_PATH}/../testing/update_parsing.php >> $LOG 2>&1
	fi
	[ ! "$QUIET" ] && echo "INFO: Setting timestamp"
	echo "$CURRTIME" > /tmp/nn-opt-last.txt
fi

[ ! "$QUIET" ] && echo "INFO: Finished, exiting."
EDATE=`date`
ETIME=`date +%s`
RUNTIME=$(($ETIME - $CURRTIME))
RMIN=$(($RUNTIME/60))
echo "INFO: Finished at $EDATE, taking $RMIN minutes, exiting." >> $LOG
rm $LOCKFILE
