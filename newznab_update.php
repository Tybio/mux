#!/usr/bin/php
<?php
/*
	Features:
	* Lock file 
	* Logging
	* Cofiguration used if no arguments given
	* Built to be called various ways
  		* Cron script
  		* Screen/tmux script (with --loop option)
  		* Daemon (with --loop option)
	* Handles POSIX signals properly (SIGTERM, SIGKILL, SIGHUP)
	* Reread config file without restarting
	* Scheduled Optimization
	* Advanced Newznab processing support

Quick Start:

	Mirror current screen script: newznab_update.php --loop=10

	For a LOT more information, use --help
*/

// Uncomment for debugging
// ini_set('display_errors', 1);
// error_reporting(-1);

// Import needed items
include("Console/Getopt.php");
require_once("Log.php");
require(dirname(__FILE__)."/../../www/config.php");
require("nnstats/lib/stats.php");
require_once(WWW_DIR."/lib/releases.php");
require_once(WWW_DIR."/lib/framework/db.php");
require_once(WWW_DIR."/lib/postprocess.php");

// Setup to catch posix signals
declare(ticks = 1);
pcntl_signal(SIGTERM, "sigHandler");
pcntl_signal(SIGINT, "sigHandler");
pcntl_signal(SIGHUP, "sigHandler");

// Parse Options;
$ini = parseOpts();

// Setup;
list($daemon, $logger) = init($ini);

// Main Loop
if ( $ini['loop'] > 0 || $ini['enh-loop'] > 0) {
	$cycle = '0';
	while(1) {
		if ( $daemon['new-signal'] ) { sigCheck($daemon, $ini, $logger); }
		$cycle++;
		$logger->info("Starting Loop $cycle");
		process($ini, $logger);
		doStats($logger);
		$logger->info("Loop finished, waiting $ini[loop] minutes....");
		if ( $ini['enh-loop'] > 0 ) {
			doPostprocess($ini, $logger);
		} else {
			sleep($ini['loop'] * 60);
		}
	}
} elseif ( $ini['catchup'] ) {
	$logger->info("Starting infinant postprocessing loop");
	doPostprocess($ini, $logger);
} else {
	$logger->info('Start single pass');
	process($ini, $logger);
}

// Clean shutdown
$logger->info('Sucessful, starting shutdown');
shutdown($ini, $logger);

// Functions

function process($ini, $logger) {
	$oldid = $logger->getIdent();
	$logger->setIdent('proc');
	$logger->debug('Entering Process function');
	$logger->debug('Checking for binary update');
	doBinaries($ini, $logger);
	$logger->debug('Starting releases update');
	doCmd($logger, $ini, '../update_scripts/update_releases.php');
	$logger->info('Checking optimisation timers');
	doOpt($ini, $logger);
	$logger->debug('Checking for import');
	doImport($ini, $logger);
	$logger->debug('Exiting Process function');
	$logger->setIdent($oldid);
}

function doStats($logger) {
	$oldid = $logger->getIdent();
	$logger->setIdent('stats');
	$stat = new Stats();
	if ( !$stat ) { 
		$logger->err("Stats DB failure.");
		return;
	}
	$all = $stat->getAllStats();
	$table = $stat->statTable($all);
	foreach ($table as $line) {
		$logger->info("$line");
	}
	$stat->saveStats($all);
	$logger->setIdent($oldid);
	return;
}
function doCmd($logger, $ini, $cmd, $opts='') {
	$basename = basename($cmd, ".php");
	$oldid = $logger->getIdent();
	$logger->setIdent($basename);
	$logger->debug("Running command -> $cmd $opts");
	$start = time();
	$out = popen("php $cmd $opts", "r");
	while ( ($line = fgets($out)) !== false) {
		if ( !$ini['quiet'] ) {
			$str = trim($line);
			$logger->info("$str");
		}
	}
	$end = time();
	$run = cnvSec($end - $start);
	$logger->info("Finished $cmd -> $run");
	$logger->setIdent($oldid);
}

function doBinaries($ini, $logger) {
	if ( $ini['skipbin'] ) {
		$logger->info('Skipping update_binaries');
		return;
	}
	if ( $ini['threads'] > '1' ) {
		$logger->debug('Starting threaded binary update');
		doCmd($logger, $ini, '../update_scripts/update_binaries_threaded.php');
	} else {
		$logger->debug('Starting binary update');
		doCmd($logger, $ini, '../update_scripts/update_binaries.php'); 
	}
}

function doOpt($ini, $logger) {
	$oldid = $logger->getIdent();
	$logger->setIdent('opt ');
	$runOpt = false;
	$logger->debug("Checking if optimisation needed");
	if ( file_exists($ini['optfilepath']) ) { 
		$lastopt = file_get_contents($ini['optfilepath']);
		$delta = time() - $lastopt;
		$logger->debug("Loaded last opt calc -> $lastopt | $delta | $ini[optint]");
		if ( $delta < $ini['optint'] ) { 
			$logger->info("Opt timer has not expired");
			return;
		}
	}	
	doCmd($logger, $ini, '../update_scripts/optimise_db.php');
	doCmd($logger, $ini, '../update_scripts/update_tvschedule.php');
	doCmd($logger, $ini, '../update_scripts/update_theaters.php');
	if ( $ini['parsing'] ) { doCmd($logger, $ini, '../update_scripts/update_parsing.php'); }
	if ( $ini['clean'] ) { doCmd($logger, $ini, '../update_scripts/update_cleanup.php'); }
	$logger->debug("Checking for backfill");
	doBackfill($ini, $logger);
	file_put_contents($ini['optfilepath'], time());
	$logger->setIdent($oldid);
}

function doImport($ini, $logger) {
	$oldid = $logger->getIdent();
	$logger->setIdent('imp ');
	if ( !$ini['import'] ) {
		$logger->debug("Import not requested");
		$logger->setIdent($oldid);
		return;
	}
	if ( !is_dir($ini['import']) ) {
		$logger->err("Import directory does not exist: $ini[import]");
		$logger->setIdent($oldid);
		return;
	}
	$impcmd = WWW_DIR."admin/nzb-import.php";
	$impopt = $ini['import']." true ".$ini['impnum'];
	$logger->debug("Cmd: $impcmd -> Opts: $impopt");
	$logger->info("Importing from $ini[import]");
	doCmd($logger, $ini, $impcmd, $impopt);
	$impdir = $ini['import'];
	$Directory = new RecursiveDirectoryIterator($ini['import']);
	$Iterator = new RecursiveIteratorIterator($Directory);
	$Regex = new RegexIterator($Iterator, '/^.+\.nzb$/i', RecursiveRegexIterator::GET_MATCH);
	$filecount = iterator_count($Regex);
	$logger->info("$filecount left to import from $ini[import].");
	$logger->setIdent($oldid);
}

function doBackfill($ini, $logger) {
	$oldid = $logger->getIdent();
	$logger->setIdent('bkfl');
	if ( !$ini['backfill'] ) { 
		$logger->debug("Backfill not requested");
		$logger->setIdent($oldid);
		return;
	}
	if ( !preg_match('/\d{4}-\d{2}-\d{2}/', $ini['backfill']) ) {
		$logger->err("Date format for backfill wrong, please use YYYY-MM-DD");
		$logger->setIdent($oldid);
		return;
	}
	$goal = strtotime($ini['backfill']);
	$now = time();
	$days = ceil(abs($now - $goal) / 86400);
	$logger->debug("Goal: $goal -> now: $now -> Backfill Target: $days");
	$logger->info("Backfill goal is $ini[backfill], $days days ago");
	$logger->debug("Incrimenting active groups with less than $days days configured by 1");
	$bkIncDay = "UPDATE groups set backfill_target=backfill_target+1 where active=1 and backfill_target<$days;";
	$logger->debug("Query: $bkIncDay");
	if(defined('DB_PORT')){
		$db = new mysqli(DB_HOST, DB_USER, DB_PASSWORD, DB_NAME, DB_PORT);
	}else{
		$db = new mysqli(DB_HOST, DB_USER, DB_PASSWORD, DB_NAME);
	}
        $db->query($bkIncDay);
	$db->close();
	if ( $ini['threads'] > '1' ) {
		$logger->debug('Starting threaded backfill');
		doCmd($logger, $ini, '../update_scripts/backfill_threaded.php');
	} else {
		$logger->debug('Starting backfill');
		doCmd($logger, $ini, '../update_scripts/backfill.php'); 
	}
	$logger->setIdent($oldid);
	return;
}

function doPostprocess($ini, $logger) {
	$oldid = $logger->getIdent();
	$logger->setIdent('pp  ');
	$logger->info("Starting Postprocessing (Direct)");
	if ( !$ini['catchup'] ) { 
		$logger->debug("Doing $loops"); 
		$start = time();
	}
	while ( $c < $ini['enh-loop'] || $ini['catchup'] ) {
		$logger->info("Staring postprocessing loop $c");
		$postprocess = new PostProcess();
		$postprocess->processAll();
		$logger->info("Finished loop $c");
		$c++;
	}
	$end = time();
	$run = cnvSec($end - $start);
	$logger->info("Finished Postprocessing -> $run");
	$logger->setIdent($oldid);
}

function cnvSec($ss) {
	$s = $ss%60;
	$m = floor(($ss%3600)/60);
	$h = floor(($ss%86400)/3600);
	$d = floor(($ss%2592000)/86400);
	$M = floor($ss/2592000);
	$val = "$m:$s";
	if ( $h > '0' ) { $val = $h.":".$val; } else { $val = '00:'.$val; }
	if ( $d > '0' ) { $val = $d."-".$val; } else { $val = '00-'.$val; }
	if ( $M > '0') { $val = $M."-".$val; } else { $val = '00-'.$val; }
	return($val);
}

function sigHandler($signal) {
	global $daemon, $logger;
	$daemon['new-signal'] = true;
	switch ($signal) {
		case SIGTERM:
			$logger->emerg("Caught SIGTERM, will exit cleanly after current loop");
			$daemon['cleanexit'] = true;
			break;
		case SIGINT:
			$logger->emerg("Caught SIGINT, exiting after current loop");
			$daemon['cleanexit'] = true;
			break;
		case SIGHUP:
			break;
		default:
			$logger->alert("Caught $signal, not sure what to do...ignoring.");
	}
}

function sigCheck($daemon, $ini, $logger) {
	if ( $daemon['cleanexit'] ) {
		$logger->crit('Caught exit signal (SIGTERM/SIGINIT), exiting cleanly');
		shutdown($ini, $logger);
	}
	// Way way too much for the first version
	if ( $daemon['reloadcfg'] ) {
		$logger->alert('Caught SIGHUP, rereading configuration file');
		unset($ini);
		$ini = parse_ini_file($ini['configfilepath']);
		$daemon['reloadcfg'] = false;
	}
	
	$daemon['new-signal'] = false;
	return($daemon);
}

function getLock($ini, $logger) {
	$logger->info("Getting lock file");
	if ( file_exists($ini['lockfilepath']) ) {
		$pid = file_get_contents($ini['lockfilepath']);
		if( posix_getsid($pid) === false ) {
			$logger->err("Old process not running, removing lock and continuing");
		} else {
			$lockage = ($ini['starttime'] - filemtime($ini['lockfilepath'])) / 60;
			if ( $lockage > $maxage ) {
				$logger->err("Lockfile Age is over $maxage minutes ($lockage)");
				$pgroup = "-".posix_getpgid($pid);
				posix_kill($pgroup, "9");
				$logger->err("Attempted to kill $pgroup, continuing");
			} else {
				$logger->crit("Lock found for running process");
				exit(1);
			}
		}
	}
	$size = file_put_contents($ini['lockfilepath'] , getmypid());
	if ( $size < '1' ) {
		$logger->err('Unable to create lockfile');
		shutdown($ini, $logger);
	}
	$logger->debug('Got Lock');
	return;
}

function shutdown($ini, $logger) {
	$logger->debug("Removing $ini[lockfilepath]");
	unlink($ini['lockfilepath']);
	if ( file_exists($ini['lockfilepath']) ) {
		$logger->err('Dirty exit, lockfile still exists');
		exit(1);
	} else {
		$logger->info('Clean exit');
	}
	exit;
}

function init($ini) { 
	// Check if rundir is writable
	if ( is_dir($ini['rundir']) ) {
		if ( !is_writable($ini['rundir']) ) {
			echo "Failed to start -> $ini[rundir] is not writable\n";
			echo "Modify permissions or change directory in configuration flie\n";
			exit(1);
		}
	} else {
			echo "Failed to start -> $ini[rundir] does not exist\n";
			echo "Create directory or modify in configuration flie\n";
			exit(1);
	}

	$file = Log::singleton('file', $ini['logfilepath'], 'init');
	$logger = Log::singleton('composite');
	$logger->addChild($file); 

	if ( $ini['verbose'] ) { 
		$console = Log::singleton('console', '', 'init');
		$logger->addChild($console); 
	}

	$mask = Log::MAX($ini['loglevel']);
	$logger->setMask($mask); 

	if ( $ini['write'] ) { saveconfig($ini, $logger); }

	getLock($ini, $logger);

	$daemon = array(
		'cleanexit' => false,
		'reloadcfg' => false,
		'new-signal'=> false,
	);

	$logger->setIdent('nnup');
	return array($daemon, $logger);
}

function parseOpts() {
	// Help Text
	$help_short = 'Usage: newznab_update.php [-hv] [-l<minutes> | --loop=<minutes>]';
	$help_long = <<<STR
Use: newznab_update.php [-opts] 

 Control Options:
    -w                     Write options to configuration file and exit
    -v                     Echo all log to STDOUT
    -q                     Just log status messages, not output from NN
    -h                     Help
    --loop=<Minutes>       Loop the script so it runs every # Minutes
    --enh-loop=<Cycles>    This is a more complex version of a --loop where time is not used
                              In this version, you will loop <Cycles> of postprocessing between
                              full updates. (See Examples)
    --loglevel=<level>     Messages to log (Default: info)

 Optimisation Options:
    -p                     Enhanced postprocessing (Testing)
    -c                     Cleanup unusable releases (Testing)
    --optint=<Number>      <Number> of seconds between opt runs (Default: 43200)

 Newznab Options:
 	-s                     Skip update_binaries (For importing)
    --threads=<threads>    Use threading where supported with <threads> number of threads
    --import=<Directory>   Import NZBs from <directory>
    --impnum=<Number>      Import <Number> of nzbs per loop (Default: 100)
    --catchup              Skip import binaries and post processing 
    --backfill=<Date>      Backfill active groups to <date>
                              Format: YYYY-MM-DD

 Examples:
    Basic update loop, pause for 10 minutes:
        newznab_update.php --loop=10

    Enhanced loop and postprocess
        newznab_update.php -p --enh-loop=2
             Loop: update_binaries, update_releases, postprocess, postprocess, update_binaries...
             Will break in after update_releases to preform optimisation when timer expires

    Loop, import and postprocess:
        newznab_update.php -p --loop=10 --import=/tmp/nzbs

    Loop, import, postprocess and backfill
        newznab_update.php -p --loop=10 --import=/tmp/nzbs --backfill=2012-08-01

    Screen mode (Same process as newznab_cron, with enhancements):
        screen newznab_update.php -v --loop=10
STR;
	// Get commandline options
	$cg = new Console_Getopt();
	$allowedShortOptions = "hvpcwsdq";
	$allowedLongOptions = array("loop==", "enh-loop==", "backfill==", "import==", "impnum==", "threads==", "optint==", "loglevel==", "catchup", "skipbin");
	$args = $cg->readPHPArgv();
	$ret = $cg->getopt($args, $allowedShortOptions, $allowedLongOptions);

	if (PEAR::isError($ret)) {
		die ("Error in command line: " . $ret->getMessage() . "\n$help_short\n");
	}
	$options = $ret[0];
	$array = array(
		'config'   => WWW_DIR."update.ini",
		'rundir'   => "/tmp/nn",
		'optfile'  => 'newznab_update.opt',
		'lockfile' => 'newznab_update.lock',
		'logfile'  => 'newznab_update.log',
		'statfile' => 'newznab_update.stats',
		'maxlocka' => '120',
		'starttime'=> false,
		'write'    => false,
		'loglevel' => 'info',
		'verbose'  => false,
		'quiet'    => false,
		'daemon'   => false,
		'parsing'  => false,		
		'clean'    => false,
		'loop'     => false,
		'enh-loop' => false,
		'backfill' => false,
		'threads'  => '1',
		'import'   => false,
		'impnum'   => '100',
		'optint'   => '43200',
		'daemon'   => false,
		'skipbin'  => false,
		'catchup'  => false
	);
	
	if (sizeof($options) > 0 ) {
		foreach ($options as $o) {
			switch ($o[0]) {
				case 'h':
					echo "$help_long\n";
					exit;
				case 'v':
					$array['verbose'] = true;
					break;
				case 'q':
					$array['quiet'] = true;
					break;
				case 'd':
					$array['daemon'] = true;
					break;
				case 'p':
					$array['parsing'] = true;
					break;
				case 'c':
					$array['clean'] = true;
					break;
				case 'w':
					$array['write'] = true;
				case '--loop':
					$array['loop'] = $o[1];
					break;
				case '--enh-loop':
					$array['enh-loop'] = $o[1];
					break;
				case '--backfill':
					$array['backfill'] = $o[1];
					break;
				case '--threads':
					$array['threads'] = $o[1];
					break;
				case '--import':
					$array['import'] = $o[1];
					break;
				case '--impnum':
					$array['impnum'] = $o[1];
					break;
				case '--optint':
					$array['optint'] = $o[1];
					break;
				case '--daemon':
					$array['daemon'] = $o[1];
					break;
				case '--loglevel':
					$array['loglevel'] = $o[1];
					break;
				case '--catchup':
					$array['catchup'] = true;
					break;
				case '--skipbin':
					$array['skipbin'] = true;
					break;
			}
		}
	} else {
		$array = parse_ini_file($file);
	}
	$array['starttime'] = time();
	$array['loglevel'] = Log::stringToPriority(strtolower($array['loglevel']));
	if ( "/" !== substr($array['rundir'], -1) ) { $array['rundir'] = $array['rundir']."/"; }
	$array['optfilepath'] = $array['rundir'] . $array['optfile'];
	$array['lockfilepath'] = $array['rundir'] . $array['lockfile'];
	$array['logfilepath'] = $array['rundir'] . $array['logfile'];
	$array['statfilepath'] = $array['rundir'] . $array['statfile'];
	return($array);
}

function saveconfig($ini, $logger, $has_sections=FALSE) {
	// This function should never return, every exit should be to 'shutdown'
	$logger->setIdent('cfg ');
	$cfg_help=<<<STR
; Configuration Options
;   (Option)     (Default)                   (Definition)
;   config     = "WWW_DIR."update.ini"       Location of this configuration file (Not variable at this time)
;   rundir     = "/tmp"                      Directory to store runtime files in 
;   optfile    = "newznab_update.opt"        Stores the time of the last optimisation run
;   lockfile   = "newznab_update.lock"       Lock file
;   logfile    = "newznab_update.log"        Log File
;   maxlocka   = "120"                       Kill processes over 120 minutes and start again
;   loglevel   = "info"                      Log messages up to this level
;   verbose    = "false"                     Copy log messages to STDOUT (Console)
;   quiet      = "false"                     Don't report output from newznab commands (update_binaries.php output blocked)
;   daemon     = "false"                     (Unused) Control daemon functionality
;   parsing    = "false"		              During optimisation cycle, include update_parsing.php
;   clean      = "false"                     During uptimisation cycle, include update_cleanup.php
;   loop       = "false"                     Minutes to wait between runs (Used to emulate current screen script)
;   enh-loop   = "false"                     Loop, but don't wait..run "#" of postprocessing cycles between updates
;   backfill   = "false"                     Date to backfile active groups too (YYYY-MM-DD)
;   threads    = "1"                         Number of threads to use (Greater than 1 calls threaded update scripts)
;   import     = "false"                     Directory to import nzbs from
;   impnum     = "100"                       Number of nzbs to import per cycle
;   optint     = "43200"                     Interval between optimisation runs
STR;
	$logger->info('Writing configuration');
	$clear = array('write', 'starttime', 'optfilepath', 'lockfilepath', 'statfstilepath', 'daemon', 'statfile', );

	foreach ( $clear as $i ) {
		$logger->debug("Unsetting $i");
		unset($ini["$i"]);
	}
	
	$content = "$cfg_help\n"; 
	if ($has_sections) { 
		foreach ($ini as $key=>$elem) { 
			$content .= "[".$key."]\n"; 
			foreach ($elem as $key2=>$elem2) { 
				if(is_array($elem2)) { 
					for($i=0;$i<count($elem2);$i++) { 
						$content .= $key2."[] = \"".$elem2[$i]."\"\n"; 
					} 
				} 
				else if($elem2=="") $content .= $key2." = \n"; 
				else $content .= $key2." = \"".$elem2."\"\n"; 
			} 
		} 
	} else { 
		foreach ($ini as $key=>$elem) { 
			if(is_array($elem)) { 
				for($i=0;$i<count($elem);$i++) { 
					$content .= $key."[] = \"".$elem[$i]."\"\n"; 
				} 
			} 
			else if($elem=="") $content .= $key." = \n"; 
			else $content .= $key." = \"".$elem."\"\n"; 
		} 
	} 
	if (!$handle = fopen($ini['config'], 'w')) { 
		$logger-err('Failed to open config file');
		shutdown($ini, $logger); 
	} 
	if (!fwrite($handle, $content)) { 
		$logger-err('Failed to write to config file');
		shutdown($ini, $logger); 
	} 
	fclose($handle); 
	$logger->info('Wrote configuration');
	shutdown($ini, $logger);
}

?>
