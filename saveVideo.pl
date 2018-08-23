#!/usr/bin/env perl

use strict;
use warnings;

use Config::IniFiles;
use Log::Log4perl qw(:easy);
use Net::Ping;

my $HOME = $ENV{'HOME'};

my $basedir = "$HOME/perl";

# need date/time to create file with timestamp, choose log file and check if concatenate video
my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
my $data = sprintf "%d.%02d.%02d-%02d.%02d", $year + 1900, $mon + 1, $mday, $hour, $min;

Log::Log4perl::init("$basedir/log4perl.conf") or die "log4perl initialization error: $!";
# script is launched from cron every 10 min and run longer, so logger need to be distinct 
#  for each launch to avoid concurrency
my $logmm = sprintf "%02d", $min;
$logmm =~ s/\d{1}$/0/;
my $logger = Log::Log4perl->get_logger("min" . $logmm);

$logger->info("loaded log4perl configuration");

my $cfg = new Config::IniFiles( -file => "$basedir/config.properties" ) or $logger->logdie("Failed to open config file:$!");

$logger->info("loaded config.properties");

my $interval	= getConfigVal("global","interval");
my $savepath	= getConfigVal("global","savepath");
my $tcp_timeout	= getConfigVal("global","tcp_timeout");
my $videopath	= getConfigVal("global","videopath");
my $binpath	= getConfigVal("global","binpath");
my $rundir	= getConfigVal("global","rundir");

my $ffmpeg_verbose  = getConfigVal("ffmpeg","verbose");
my $ffmpeg_in_parms = getConfigVal("ffmpeg","in_parms");
my $ffmped_out_parms= getConfigVal("ffmpeg","out_parms");

my $camera_list= getConfigVal("global", "camera_list");
my @camera_list 	= split /[,;]/,$camera_list;

my $num_cams = scalar @camera_list;
$logger->info("number of camera(s) to collect video: $num_cams");

my $hora = scalar localtime;
$logger->warn("[$$] starting recordVideo() at $hora");

# launch record video process for each camera
$logger->debug("Parent PID is $$");
my $forks = 0;
foreach my $camera (@camera_list) {
    my $pid = fork;
    if (not defined $pid) {
	$logger->error("[$$] failed to fork for $camera");
	notify_error("failed to fork for $camera");
    }
    $forks++ if $pid;
    recordVideo($camera, $data) unless $pid;
}

# now wait record to finish
for (1 .. $forks) {
    my $pid = wait();
    $logger->debug("[$$] child $pid finished recording");
}
$hora = scalar localtime;
$logger->info("[$$]finished recordVideo() at $hora");

# now generate short videos
my $sttime = time;
foreach my $camera (@camera_list) {
    genShortVideo($camera, $data);
}
my $elapsed = time - $sttime ;
notify_error("Short video generation taking too long") if ( $interval < $elapsed + 120 );
$logger->info("All short videos generated in $elapsed secs");

# now if min is 50, it's the last video for this hour and we generate a new concatenated one 
if ($min == 50) {
    $logger->debug("$min : concatenate videos");
    foreach my $camera (@camera_list) {
        genConcatenatedVideo($camera, $data);
    }
}

$logger->warn("program finished");
exit 0;


sub genConcatenatedVideo {
    my $camera = shift;
    my $data   = shift;

    my ($location,$IP, $URI) = getCameraData($camera);

    $logger->info("starting concatenated video generation for $location/$IP");

    (my $hourly = $data) =~ s/\.\d{2}$//;
    my $out_file = $location . "_" . $IP . "_" . $hourly . ".mp4";

    $logger->debug("$location/$IP : video filename to generate: $out_file");
    my @files = glob($videopath . "/" . $location . "_" . $IP . "_" . $hourly . ".*.mp4");
    unless (scalar @files) {
	notify_error("$location/$IP : failed to generate list of files to concatenate");
    	exit 1;
    }

    my $filename = "/tmp/videoList." . $hourly . ".txt";
    $logger->debug("$location/$IP : video list file : $filename");
    open(FH, '>', $filename) or die $!;
    foreach my $str (@files) {
	$logger->debug("$location/$IP : put in the list: $str");
	printf FH "file %s\n", $str;
    }
    close(FH);
    my $ret = `$binpath/ffmpeg -f concat -v 16 $ffmpeg_in_parms -safe 0 -i $filename -c copy $videopath/$out_file 2>&1`;
    $ret =~ s/\n/ /gs;
    $logger->error("$location/$IP: " . $ret) if length($ret) > 0;

    unlink @files or $logger->error("$location/$IP: failed to remove file: $!");
    unlink $filename or $logger->error("$location/$IP: failed to remove file: $!");;
    $logger->info("finished concatenated video generation for $location/$IP");
}

sub genShortVideo {
    my $camera = shift;
    my $data   = shift;

    my ($location,$IP, $URI) = getCameraData($camera);

    $logger->info("starting small/short video generation for $location/$IP - $data");

    my $in_file  = $location . "_" . $IP . "_" . $data . ".mkv";

    $logger->warn("input file not found for $in_file") unless -e "$savepath/$IP/$in_file";
    return 1 unless -e "$savepath/$IP/$in_file";

    (my $out_file = $in_file ) =~ s/mkv$/mp4/;
    my $ret = `$binpath/ffmpeg -v 16 $ffmpeg_in_parms -i $savepath/$IP/$in_file -filter:v "setpts=0.05*PTS" -s 640x480 -an $videopath/$out_file 2>&1`;
    $ret =~ s/\n/ /gs;
    $logger->error("$location/$IP: " . $ret) if length($ret) > 0;

    $logger->info("finished small/short video generation for $location/$IP - $data");
   return 0;
}

# this function is invoked by fork, so must exit at the end
sub recordVideo {
    my $camera = shift;
    my $data   = shift;

    my ($location,$IP, $URI) = getCameraData($camera);

    $logger->info("[$$] starting recordVideo for $location/$IP");

    # create folder to save video if don't exist
    if (! -e "$savepath/$IP" )
    {
	system("mkdir -p $savepath/$IP");
    }

    my $alive = isAlive($IP);
    if ($alive) {
	set_alarm(0,"$IP" . ".ping", "$IP reachable");
    } else {
	set_alarm(1,"$IP" . ".ping", "$IP unreachable");
        return 1;
    }

    my $elapsed = 0;
    eval {
	local $SIG{ALRM} = sub { die "[$$] recordVideo()for $IP timed out."; };
	alarm ($interval + 60);

	my $sttime = time;
	my $file = $location . "_" . $IP . "_" . $data . ".mkv";
        $logger->info("[$$] Recording $interval secs video of $location");
	my $ret = `$binpath/ffmpeg -v $ffmpeg_verbose $ffmpeg_in_parms -rtsp_transport tcp -t $interval  -stimeout $tcp_timeout -i "rtsp://$IP/$URI" $ffmped_out_parms -metadata title="$camera,$IP,$data" $savepath/$IP/$file 2>&1`;
	$elapsed = time - $sttime + 1;

	$ret =~ s/\n/ /gs;
	$logger->debug("[$$]" . $ret);

	alarm(0);
    };
    notify_error("[$$] recordVideo()for $IP timed out.") if $@;

    notify_error("$IP : probably ffmpeg failed to run, cmd terminated in $elapsed secs") if ($elapsed < 10);
    notify_error("$IP : capture interrupted after $elapsed secs") if ($elapsed < $interval);

    $logger->info("[$$] finished recordVideo for $location/$IP");
    exit 0;
}


sub isAlive {
    my $host = shift;

    my $p = Net::Ping->new();
    return $p->ping($host, 2);
}

sub set_alarm {
    my $status = shift;         # 0 = alarm off, 1 = alarm on
    my $ctrlfile = shift;
    my $msg = shift;

    if ( $status )      # alarm ON
    {
	system("mkdir $rundir") unless -e "$rundir";
        if ( -e "$rundir/$ctrlfile")
        {
            $logger->debug("$msg, already notified");
        }
        else
        {
            $logger->error("$msg");
            notify_error ("ALARM: $msg");
            $logger->info("created $rundir/$ctrlfile");
            system("touch $rundir/$ctrlfile");
        }
    }
    else        # alarm oFF
    {
        $logger->debug("$msg");
        if( -e "$rundir/$ctrlfile" )
        {
            $logger->warn("$msg");
            notify_error("Info: $msg");
            $logger->info("removed $rundir/$ctrlfile");
            unlink "$rundir/$ctrlfile";
        }
    }
}       # set_alarm() common sub_routine

sub notify_error {
    my ($text) = @_;

    my $email    = getConfigVal("global","email_to");
    my $acct    = getConfigVal("global","email_acct");
    $logger->error("$text") unless $text =~ /^(Info|ALARM)/;
    $logger->error("Failed to send email notification") 
	if system("echo \"Subject: $text\" | msmtp -a $acct $email ");
}

# strip blanks and comments
sub getConfigVal {
    my $section = shift;
    my $value = shift;

    # trim left and right
    $section =~ s/^\s+|\s+$//g;
    $value   =~ s/^\s+|\s+$//g;
    if(! $cfg->exists("$section", "$value")) {
        notify_error("Config missing: $value not defined at $section");
        $logger->logdie("Config missing: $value not defined at $section");
    }

    my $var = $cfg->val("$section", "$value");
    $var =~ s/\s+#.*//g ;

    return $var;
}

sub getCameraData {
   my $camera = shift;

   my $location = getConfigVal("$camera","location");
   my $IP       = getConfigVal("$camera","IP");
   my $URI      = getConfigVal("$camera","URI");

   return ( $location, $IP , $URI);
}

