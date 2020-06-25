#!/usr/bin/perl

#requires: fmpeg, sox, libsox-fmt-all, ffmpeg, libmp3lame

use strict;
use warnings;

use Data::Dumper;
use File::Basename;
use Term::ANSIColor qw(:constants);
use File::Copy;
use Cwd;
use Getopt::Long;
use IO::Handle;

STDOUT->autoflush(1);

my $env = 'export LD_LIBRARY_PATH=/usr/local/lib/i386-linux-gnu/;';
$env = '';

my $ffmpeg = '';

#-sample_fmt s16
my $encoder     = '-ac 2 -ar 44100 -codec:a libmp3lame -b:a 192k';
my $tempEncoder = '-acodec pcm_s24le -ac 2 -ar 44100';
my $tempDir     = '/var/tmp/convert';
my $tempFiles   = [];

my $inputFile  = '';
my $outputFile = '';
my $duration   = 0;

my $loudNormFilter = qq{loudnorm=I=-18:TP=-1.0:LRA=6};

my $fadeInDuration  = 0.5;
my $fadeOutDuration = 0.5;

sub info($) {
    my $message = shift;
    chomp $message;
    for my $line ( split( /\n/, $message ) ) {
        print STDERR "--INFO--- $$ " . BLUE . $line . RESET . "\n";
    }
}

sub error($) {
    my $message = shift;
    chomp $message;
    for my $line ( split( /\n/, $message ) ) {
        print STDERR "--ERROR-- $$ " . RED . $line . RESET . "\n";
    }
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

sub processFile {
    my $inFile   = shift;
    my $outFile  = shift;
    my $duration = shift;

    info("processFile $inFile");

    if ( ( -e $outFile ) && ( modifiedAt($inFile) < modifiedAt($outFile) ) ) {
        info("skip file, output file $outFile already exists");
        return;
    }

    unless ( -e $inFile ) {
        info("skip file, file $inFile does not exist");
        return;
    }

    if ( $inFile =~ /\.mp3/ ) {
        $inFile = decodeMp3($inFile);
    }
    return unless $inFile =~ /\.(wav|aiff)$/;
    return unless -e $inFile;

    my $stats = showStats($inFile);
    $duration = parseDuration($stats) if $duration == 0;
    $inFile = setDuration( $inFile, $duration ) if $duration > 0;
    return unless -e $inFile;

    $inFile = setEqualChannelVolume($inFile);
    return unless -e $inFile;

    #showStats($inFile);
    my $maxVolume = getPeakVolume($inFile);
    info "maxVolume:$maxVolume dB";
    my $removeInFile = 0;
    if ( $maxVolume < -10 ) {
        $inFile = setVolume( $inFile, -$maxVolume - 1 );
        return unless -e $inFile;
        #showStats($inFile);
        $removeInFile = 1;
    } else {
        info "peak normalization not necessary because peak level is high enough";
    }

    $inFile = twoPass($inFile);
    return unless -e $inFile;

    showStats($inFile);
    info "move '$inFile' to '$outFile'";
    File::Copy::move( $inFile, $outFile );
}

sub showStats {
    my $file = shift;

    info "\n### getStats '$file'";
    return execute qq{sox '$file' -n stats}, "verbose";
}

sub parseDuration {
    my $stats = shift || '';
    if ( $stats =~ /Length\s*s\s*([\d\.]+)/ ) {
        my $duration = $1;
        $duration /= 10 * 60;
        $duration = int( $duration + 0.5 );
        $duration *= 10 * 60;
        return $duration;
    }
    return 0;
}

sub decodeMp3 {
    my $inFile = shift;
    my $outFile = getTempFile( $inFile, 'conv.wav' );
    execute qq{$env sox '$inFile' -b 24 '$outFile'};
    return $outFile;
}

sub modifiedAt {
    my $file = shift;
    my @stat = stat $file;
    return 0 if scalar(@stat) < 9;
    return $stat[9];
}

sub setEqualChannelVolume {
    my $file = shift;

    my ( $l, $r ) = getVolumeDifference($file);
    if ( abs( $r - $l ) < 0.5 ) {
        info "channel volumes are nearly equal, no need to adopt";
        return $file;
    }
    if ( $r > $l ) {
        my $diff = $r - $l;
        return setChannelVolumes( $file, 0.0, -$diff );
    }
    if ( $l > $r ) {
        my $diff = $l - $r;
        return setChannelVolumes( $file, -$diff, 0.0 );
    }
}

sub setChannelVolumes {
    my $file        = shift;
    my $leftVolume  = shift;
    my $rightVolume = shift;

    return $file if ( $leftVolume == 0 ) && ( $rightVolume == 0 );
    my ( $leftFile, $rightFile ) = stereoToMono($file);
    $leftFile  = setVolume( $leftFile,  $leftVolume );
    $rightFile = setVolume( $rightFile, $rightVolume );
    my $stereoFile = monoToStereo( $file, $leftFile, $rightFile );
    return $stereoFile;
}

sub getVolumeDifference {
    my $file = shift;

    my $result = execute qq{sox '$file' -n stats};
    if ( $result =~ /RMS lev dB\s+([\-\.\d]+)\s+([\-\.\d]+)\s+([\-\.\d]+)\s/ ) {
        my $overall = $1;
        my $left    = $2;
        my $right   = $3;
        info "left:" . $left . "dB right:" . $right . "dB, difference:" . ( $left - $right ) . "dB";
        return ( $left, $right );
    }
    print "ERROR: cannot detect volume difference of $file!\n$result";
    exit 1;
}

sub stereoToMono {
    my $file = shift;

    my $leftFile  = getTempFile( $file, 'left.wav' );
    my $rightFile = getTempFile( $file, 'right.wav' );

    info "split stereo file $file to left: $leftFile and right: $rightFile";
    execute qq{$env $ffmpeg -i '$file' -map_channel 0.0.0 $tempEncoder '$leftFile' -map_channel 0.0.1 $tempEncoder '$rightFile'};
    return ( $leftFile, $rightFile );
}

sub monoToStereo {
    my $outFile   = shift;
    my $leftFile  = shift;
    my $rightFile = shift;

    $outFile = getTempFile( $outFile, 'stereo.wav' );
    info "join mono files left $leftFile and right $rightFile to stereo file $outFile";

    execute
qq{$env $ffmpeg -i '$leftFile' -i '$rightFile' -filter_complex "[0:a][1:a]amerge=inputs=2[aout]" -map "[aout]" $tempEncoder '$outFile'};
    return $outFile;
}

sub setDuration {
    my $file     = shift;
    my $duration = shift;

    my $outFile = getTempFile( $file, 'setDuration.wav' );
    info "set duration file=$file, duration=$duration";
    execute qq{$env sox '$file' '$outFile' trim 0.0 $duration.0};
    return $outFile;
}

#add volume to file and write to 24bit wav, return new filename
sub setVolume {
    my $file   = shift;
    my $volume = shift;

    if ( $volume == 0 ) {
        info "do not need to adjust volume for $file";
        return $file;
    }

    info "\n### setVolume '$file'";
    my $outFile = getTempFile( $file, 'vol.wav' );

    execute qq{$env $ffmpeg -i '$file' -af "volume=} . $volume . qq{dB" $tempEncoder '$outFile'};
    return $outFile;
}

sub twoPass {
    my $inFile = shift;

    my $outFile = getTempFile( $inFile, 'mp3' );

    info "\n### first pass : detect levels '$inFile'";

    my $json = execute qq{$env $ffmpeg -i '$inFile' -af '$loudNormFilter:print_format=json' -f null -};

    my $options = {};
    for my $line ( split( /\n/, $json ) ) {
        if ( $line =~ /\"([^\"]+)\"\s+\:\s+\"([^\"]+)\"/ ) {
            my $key   = $1;
            my $value = $2;
            $options->{$key} = $value;
        }
    }

    for my $key ( sort keys %$options ) {
        info "    " . $key . " = " . $options->{$key} . "";
    }

    my $filter = $loudNormFilter;
    $filter .= ":measured_I=" . $options->{input_i};
    $filter .= ":measured_LRA=" . $options->{input_lra};
    $filter .= ":measured_TP=" . $options->{input_tp};
    $filter .= ":measured_thresh=" . $options->{input_thresh};
    $filter .= ":offset=" . $options->{target_offset};
    $filter .= ":linear=true:print_format=summary";

    my $audioDuration = getDuration($inFile);
    my $fadeFilter = getFadeInFilter($fadeInDuration) . "," . getFadeOutFilter( $audioDuration, $fadeOutDuration );

    info "\n### second pass : apply levels '$inFile' -> '$outFile'";

    execute qq{$env $ffmpeg -i '$inFile' -af '$filter',$fadeFilter $encoder '$outFile'};
    return $outFile;
}

sub getPeakVolume {
    my $file = shift;

    info "\n### getPeakVolume '$file'";
    my $result        = execute qq{$env $ffmpeg -i '$file' -af "volumedetect" -f null /dev/null};
    my $peakVolumeRms = 0;
    if ( $result =~ /max_volume: ([\-\d\.]+) dB/ ) {
        $peakVolumeRms = $1;
    }

    info "detected peak volume: $peakVolumeRms dB";
    return $peakVolumeRms;
}

sub getDuration {
    my $file = shift;

    info "\n### getDuration '$file'";
    my $result = execute qq{$env $ffmpeg -i '$file' -f null /dev/null};

    my $duration = -1;
    if ( $result =~ /(Duration: (\d+)\:(\d+)\:(\d+)\.(\d+))/ ) {
        my $text     = $1;
        my $hour     = $2;
        my $minute   = $3;
        my $seconds  = $4;
        my $hundreds = $5;
        info $text. "";
        $duration = ( $hour * 3600 ) + ( $minute * 60 ) + $seconds + ( $hundreds / 100 );
    }
    info "detected duration: $duration seconds";
    return $duration;
}

sub getFadeOutFilter {
    my $audioDuration = shift;
    my $fadeDuration  = shift;
    return "afade=t=out:st=" . ( $audioDuration - $fadeDuration ) . ":d=" . $fadeDuration;
}

sub getFadeInFilter {
    my $fadeDuration = shift;
    return 'afade=t=in:ss=0:d=' . $fadeDuration;
}

# return temporary filename
sub getTempFile {
    my $file   = shift;
    my $suffix = shift;

    $file = $tempDir . '/' . basename($file) . '.' . $suffix;

    unlink $file if -e $file;
    push @$tempFiles, $file;
    return $file;
}

sub cleanUp {
    for my $file (@$tempFiles) {
        if ( -f $file ) {
            info "cleanup: delete '$file'";
            unlink $file;
        }
    }
    $tempFiles = [];
}

END {
    cleanUp();
}

{ # main
    my $help = 0;

    GetOptions(
        "input=s"    => \$inputFile,
        "output=s"   => \$outputFile,
        "duration=i" => \$duration,
        "ffmpeg=s"   => \$ffmpeg,
        "tempDir=s"  => \$tempDir,
        "help"       => \$help,
    ) or die("Error in command line arguments\n");

    if ($help) {
        print qq{$0 OPTION+
            
        OPTIONS

        --input PATH      source audio files
        --output PATH     target audio file
        --duration VALUE  target audio duration in seconds
        --ffmpeg PATH     path to ffmpeg (requires version>=3.1)
        --tempDir PATH    path to temporary directory, defaut is /tmp
        --verbose LEVEL   verbose level
        --help            this help
        };
        exit 0;
    }

    mkdir $tempDir unless -e $tempDir;
    die("could not create $tempDir")              unless -e $tempDir;
    die("cannot find ffmpeg at $ffmpeg")          unless -e $ffmpeg;
    die("cannot execute ffmpeg at $ffmpeg")       unless -x $ffmpeg;
    die("missing --input ")                       unless defined $inputFile;
    die("input file does not exist '$inputFile'") unless -e $inputFile;
    die("missing --output")                       unless defined $outputFile;
    die("missing --duration")                     unless defined $duration;

    # register clean-up handler
    $SIG{TERM} = $SIG{INT} = sub {
        info "caught TERM signal";
        cleanUp();
        exit;
    };

    processFile( $inputFile, $outputFile, $duration );
    cleanUp();
}
