#!/usr/bin/perl

use strict;
use warnings;

use Data::Dumper;
use File::Basename qw(basename dirname);
use Term::ANSIColor qw(:constants);
use IO::Socket();
use File::Copy;
use Cwd          ();
use Getopt::Long ();
use IO::Handle;

use lib '../calcms';
use config;
use db;
use audio_recordings;
use events;

STDOUT->autoflush(1);

my $config = config::get('../../piradio.de/agenda/config/config.cgi');

my $dir     = '/home/radio/recordings/';
my $help    = undef;
my $logFile = undef;
my $ffmpeg  = undef;

Getopt::Long::GetOptions(
    "dir=s"    => \$dir,
    "h|help"   => \$help,
    "ffmpeg=s" => \$ffmpeg,
    "log=s"    => \$logFile
);

if ( defined $help ) {
    print qq{
usage $0 OPTIONS

files in dir are ignored if file name contains ".master." or ends with ".off"
start: nohup /home/radio/calcms/tools/masterAudioDaemon.pl &
--dir     path to recordings
--ffmpeg  path to ffmpeg
--log     log file
--help    show this help
};
}

reopenLogFile($logFile) if defined $logFile;

my $socket = makeSingleInstance(60000);

my $SECOND = 1;
my $MINUTE = 60 * $SECOND;
my $sleep  = 5 * $MINUTE;

my $dbh = undef;
while (1) {
    $dbh = db::connect($config);

    for my $file ( sort glob("$dir/*.mp3") ) {
        processAudio( $dbh, $config, $file );
    }

    $dbh->disconnect;

    info("wait $sleep seconds");
    sleep $sleep;
    reopenLogFile($logFile) if defined $logFile;
}

sub execute($;$) {
    my $command      = shift;
    my $outputResult = shift;

    print STDERR "--EXEC--- $$ " . YELLOW . $command . RESET . "\n";
    my $result   = `$command 2>&1`;
    my $exitCode = $? >> 8;
    print STDERR "OUTPUT:" . $result if $outputResult || ( $exitCode > 0 );
    return $result;
}

sub getFileModifiedAt {
    my $file       = shift;
    my @stats      = stat($file);
    my $modifiedAt = $stats[9];
    $modifiedAt = time::time_to_datetime($modifiedAt);
    return $modifiedAt;
}

sub processAudio {
    my $dbh    = shift;
    my $config = shift;
    my $source = shift;

    my $start = time();
    info("process audio '$source");

    #return if $source =~ /\.master\./;
    return if $source =~ /\.off$/;

    my $target = $source;
    $target =~ s/(\.master)?\.mp3$//;
    $target .= '.master.mp3';

    my $recording = getRecording( $config, $source );
    unless ( defined $recording ) {
        info("skip, due to event not found in database");
        return;
    }

    fixDate( $config, $source, $recording );

    if ( -f $target ) {
        info("skip, due to target '$target' already exists");
        return;
    }

    if ( $recording->{mastered} == 1 ) {
        info("skip, due to file been mastered before");
        return;
    }

    if ( $recording->{processed} == 1 ) {
        info( "skip, due to file needs no processing, [" . inspect($recording) . "]" );
        return;
    }

    my $eventDuration = getEventDuration( $config, $recording, $source );
    info( "eventDuration=" . $eventDuration );
    $recording = analyseAudio( $config, $source, $recording, $eventDuration );

    if ( $recording->{processed} == 1 ) {
        info( "skip, due to file needs no processing, [" . inspect($recording) . "]" );
        return;
    }

    my $dir     = dirname( Cwd::abs_path($0) );
    my $command = "$dir/masterAudio.pl";
    $command .= " --duration '$eventDuration'" if $eventDuration > 0;
    $command .= " --input '$source'";
    $command .= " --output '$target'";
    $command .= " --ffmpeg '$ffmpeg'";

    info( "execute: " . $command );
    system($command);
    if ( $? != 0 ) {
        error("error on executing command $command");
        return;
    }

    unless ( -f $target ) {
        error("do not update database due to target file does not exist");
        return;
    }

    if ( -f $target ) {
        my $stats = getStats($target);
        my $entry = {
            audioDuration => parseDuration($stats),
            rmsLeft       => parseRmsLeft($stats),
            rmsRight      => parseRmsRight($stats)
        };

        $recording->{size}        = getFileSize($target);
        $recording->{modified_at} = getFileModifiedAt($target);
        $recording->{path}        = basename($target);

        $recording->{rmsLeft}       = $entry->{rmsLeft};
        $recording->{rmsRight}      = $entry->{rmsRight};
        $recording->{audioDuration} = $entry->{audioDuration};
        $recording->{eventDuration} = $eventDuration;
        $recording->{processed}     = isFine( $entry, $eventDuration );
        $recording->{mastered}      = 1;

        info( "update entry, [" . inspect($recording) . "]" );

        $dbh = db::connect($config) unless defined $dbh;
        audio_recordings::update( $config, $dbh, $recording );
    }

    info( sprintf( "processAudio took %d seconds for file='%s'", ( time() - $start ), $target ) );
}

sub fixDate {
    my $config = shift;
    my $file   = shift;
    my $entry  = shift;

    my $modifiedAt = getFileModifiedAt($file);
    info( "fixDate(): file='$file', modifiedAt='$modifiedAt', entryDate='$entry->{modified_at}'", Dumper($entry) );
    return if $entry->{modified_at} eq $modifiedAt;
    info("update modified_at due to date differs");
    $entry->{modified_at} = getFileModifiedAt($file);
    $dbh = db::connect($config) unless defined $dbh;
    audio_recordings::update( $config, $dbh, $entry );
}

sub inspect {
    my $entry = shift;
    return join( ", ", ( map { "$_='$entry->{$_}'" } sort keys %$entry ) );
}

sub isFine {
    my $recording     = shift;
    my $eventDuration = shift;

    my $flag = 1;
    if ( diff( $recording->{rmsLeft}, -21 ) > 2.5 ) {
        $flag = 0;
        info("left channel is out of target $recording->{rmsLeft} db and needs processing");
    }
    if ( diff( $recording->{rmsRight}, -21 ) > 2.5 ) {
        $flag = 0;
        info("right channel is out of target $recording->{rmsRight} db and needs processing");
    }
    if ( ( defined $eventDuration ) && ( diff( $eventDuration, $recording->{audioDuration} ) >= 0.1 ) ) {

        # TODO: support file enlargenment
        if ( $recording->{audioDuration} ) {
            $flag = 0;
            info("eventDuration=$eventDuration is out of target $recording->{audioDuration} and needs processing");
        }
    }

    info(
        sprintf(
            "isProcessed=%s, eventDuration=%s, audioDuration=%s, rmsLeft=%.02f, rmsRight=%.02f",
            $flag, $eventDuration, $recording->{audioDuration},
            $recording->{rmsLeft}, $recording->{rmsRight}
        )
    );
    return $flag;
}

# return diffenrence between 2 values
# return high number in case of
sub diff {
    my $a = shift;
    my $b = shift;
    return 9999 unless defined $a;
    return 9999 unless defined $b;
    return $a - $b if $a > $b;
    return $b - $a if $b > $a;
    return 0       if $a == $b;
}

sub getStats {
    my $file = shift;

    info( sprintf( "analyze audio '%s'", $file ) );
    my $stats = execute qq{sox '$file' -n stats}, "verbose";
    return $stats;
}

# get audio duration from sox
sub parseDuration {
    my $stats = shift;

    if ( $stats =~ /Length\s*s\s*([\d\.]+)/ ) {
        my $duration = $1;
        return $duration;
    }
    return 0;
}

sub parseRmsLeft {
    my $stats = shift;

    if ( $stats =~ /RMS lev dB\s+([\-\.\d]+)\s+([\-\.\d]+)\s+([\-\.\d]+)\s/ ) {
        my $rms      = $1;
        my $rmsLeft  = $2;
        my $rmsRight = $3;
        return $rmsLeft;
    }
    return 0;
}

sub parseRmsRight {
    my $stats = shift;

    if ( $stats =~ /RMS lev dB\s+([\-\.\d]+)\s+([\-\.\d]+)\s+([\-\.\d]+)\s/ ) {
        my $rms      = $1;
        my $rmsLeft  = $2;
        my $rmsRight = $3;
        return $rmsRight;
    }
    return 0;
}

sub getFileSize {
    my $file  = shift;
    my @stats = stat $file;
    return $stats[7];
}

# get recording from database
sub getRecording {
    my $config = shift;
    my $source = shift;

    my $filename = basename($source);
    info( sprintf( "get audio metadata from database, file='%s'", $filename ) );
    my $recordings = audio_recordings::get(
        $config,
        {
            project_id => 1,
            studio_id  => 1,
            path       => $filename
        }
    );

    unless ( scalar @$recordings == 1 ) {
        error( sprintf( "could not find recording in database with path='%s'", $filename ) );

        if ( $filename =~ /\.master\.mp3/ ) {
            return undef;
        }

        # if master file is in database, but source on disk, take the master record and convert to unprocessed
        $filename =~ s/\.mp3$/\.master\.mp3/;
        info(qq{try $filename});
        $recordings = audio_recordings::get(
            $config,
            {
                project_id => 1,
                studio_id  => 1,
                path       => $filename
            }
        );
        return undef unless scalar @$recordings == 1;
        $recordings->[0]->{mastered} = 0;
        #print STDERR Dumper $recordings;

    }

    return $recordings->[0];
}

# analyse audio values and cache in database
sub analyseAudio {
    my $config        = shift;
    my $file          = shift;
    my $recording     = shift;
    my $eventDuration = shift;

    info( sprintf( "analyse audio file '%s'", $file ) );

    $recording = getRecording( $config, $file ) unless defined $recording;
    return undef unless defined $recording;

    if (   ( $recording->{audioDuration} == 0 )
        || ( $recording->{rmsLeft} == 0 )
        || ( $recording->{rmsRight} == 0 )
        || ( $recording->{processed} == 0 ) )
    {
        my $stats = getStats($file);
        $recording->{audioDuration} = parseDuration($stats);
        $recording->{rmsLeft}       = parseRmsLeft($stats);
        $recording->{rmsRight}      = parseRmsRight($stats);
        $recording->{processed}     = isFine( $recording, $eventDuration ) if defined $eventDuration;

        $dbh = db::connect($config) unless defined $dbh;
        audio_recordings::update( $config, $dbh, $recording );
    }

    return $recording;
}

sub info {
    my $message = shift;
    chomp $message;
    my $date = time::time_to_datetime();
    for my $line ( split( /\n/, $message ) ) {
        print STDERR $date . " --INFO--- $$ " . $line . "\n";
    }
}

sub error {
    my $message = shift;
    chomp $message;
    my $date = time::time_to_datetime();
    for my $line ( split( /\n/, $message ) ) {
        print STDERR $date . " --ERROR-- $$ " . $line . "\n";
    }
}

sub getEventDuration {
    my $config    = shift;
    my $recording = shift;
    my $file      = shift;

    if ( defined $recording->{duration} ) {
        return $recording->{duration} if $recording->{duration} != 0;
    }

    info( sprintf( "get event duration for path='%s'", $file ) );
    my $eventId = -1;
    if ( $file =~ /id(\d+)/ ) {
        $eventId = $1;
    }

    if ( $eventId <= 0 ) {
        error(qq{could not find eventId in path '$file'});
        return 0;
    }

    my $request = {
        params => {
            checked => events::check_params(
                $config,
                {
                    event_id => $eventId,
                    template => 'no',
                    limit    => 1,
                }
            )
        },
        config => $config
    };

    my $events = events::get( $config, $request );
    if ( scalar @$events == 0 ) {
        print STDERR "getEventDuration: no event found with event_id=$eventId\n";
        return 0;
    }

    my $event = $events->[0];
    my $duration = time::get_duration_seconds( $event->{start}, $event->{end}, $config->{date}->{time_zone} );

    info( sprintf( "got audio duration='%s' for '%s', eventId='%s'", $duration, $file, $eventId ) );

    # update recording
    if ( $duration > 0 ) {
        $recording->{eventDuration} = $duration;
        $dbh = db::connect($config) unless defined $dbh;
        audio_recordings::update( $config, $dbh, $recording );
        info( inspect($recording) );
    }
    return $duration;
}

# it is important to have listen=1 and return the socket, as it becomes closed on end of lifetime
sub makeSingleInstance {
    my $port   = shift;
    my $server = 'localhost';
    info("try to lock $server:$port to make sure only one instance is running");
    my $socket = IO::Socket::INET->new(
        LocalHost => $server,
        LocalPort => $port,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
    );
    die "$0: cannot bin to localhost:60000. Another instance is running." unless $socket;
    info("bound to port");
    return $socket;
}

sub reopenLogFile{
    my $logFile=shift;
    return unless defined $logFile;

    if ( -e $logFile ) {
        my @stats = stat $logFile;
        if ( scalar @stats != 0 ) {
            my $size = $stats[7];
            unlink $logFile if $size > 1000 * 1000 * 1000;
        }
    }

    close STDOUT;
    open( STDOUT, ">>", $logFile ) or die "Cannot open STDOUT: $!";

    close STDERR;
    open( STDERR, ">>", $logFile ) or die "Cannot open STDERR: $!";
}

