#!/usr/bin/perl -w
#
# HD-PVR Cutter
#
#	Modified by: Edward Hughes IV <edward@edwardhughes.org> starting 2011/03/16
#
#	Originally written by: Christopher Meredith (chmeredith {at} gmail)
#		(http://monopedilos.com/dokuwiki/doku.php?id=hdpvrcutter.pl)
#
#
# Lossless commercial cutting of HD-PVR recordings using avidemux
#
# Based on:
#
#    Fill MythVideo Metadata (http://ubuntuforums.org/showthread.php?t=1061733)
#	Written by Menny Even-Danan
#	(mennyed at the g mail thing)
#
#    h264cut (http://www.mythtv.org/wiki/User:Iamlindoro)
#       Written by Robert McNamara
#       (robert DOT mcnamara ATSIGN gmail DOT com)
#
#    cybertron's perl script (http://www.justlinux.com/forum/showpost.php?p=878967&postcount=4)
#
# Requires:
#    - mkvmerge to do the splitting AND the merging of the cut video
#    - ffmpeg to pre-process the recording into a Matroska container
#    - mediainfo for obtaining current recording information
#
# Type hdpvrcutter.pl --help for usage information.
#
#
# @todo: define exit codes

use LWP::UserAgent;
use DBI;
use File::Copy;
use POSIX;
use Getopt::Long;
use Pod::Usage;
use File::Which;
use Data::Dumper;

################################################################################
## Leave everything below this line alone unless you know what you are doing!
################################################################################

#First setup the sigint handler
use sigtrap 'handler' => \&sigint_exit, 'INT';

# Some variables
my $cutlist_sub_str = "";
my $ctr = 0;
my $vidstart;
my $now = time();

## Process command line arguments

# Declare variables with default values
my $verbose = '';
my $debug = '';
my $dryrun = 0;
my $title = '';
my $searchtitle = '';
my $subtitle = '';
my $mysql_host = 'localhost';
my $mysql_db = 'mythconverg';
my $mysql_user = 'mythtv';
my $mysql_password = '';
my $recordings_dir = '';
my $temp_dir = '';
my $output_dir = '';
my $jobid = 0;
my $help = 0;
my $man = 0;
my $basename;

# Use GetOpt::Long to handle the command line flags
GetOptions(
                                      'verbose' => \$verbose,
                                      'debug' => \$debug,
                                      'dryrun' => \$dryrun,
                                      'title:s' => \$title,
                                      'searchtitle:s' => \$searchtitle,
                                      'subtitle:s' => \$subtitle,
                                      'basename:s' => \$user_filename,
                                      'host:s' => \$mysql_host,
                                      'dbname:s' => \$mysql_db,
                                      'user:s' => \$mysql_user,
                                      'passwd:s' => \$mysql_password,
                                      'recordings=s' => \$recordings_dir,
                                      'tempdir=s' => \$temp_dir,
                                      'dest=s' => \$output_dir,
                                      'jobid:i' => \$jobid,
                                      'outfile:s' => \$user_outfile,
                                      'cutlist:s' => \$user_cutlist,
                                      'help|?|h' => \$help,
                                      'man' => \$man) or pod2usage(2);

# Pod::Usage calls to generate help text and a manpage.
pod2usage(-verbose => 1) if $help;
pod2usage(-verbose => 2) if $man;

# Checks and error messages for required flags
print "Must supply the password for the MySQL MythTV database [--passwd=PASSWORD] .\n" if ( !$mysql_password && !$user_cutlist );
print "Must supply the full path to the recordings directory [--recordings=RECORDINGS_DIR].\n" if ( !$recordings_dir );
print "Must supply the full path the the temporary working directory [--tempdir=TEMPORARY_DIR].\n" if ( !$temp_dir );
print "Must supply the full the path the to output destination directory [--dest=DESTINATION_DIR].\n" if ( !$output_dir );
print "No subtitle.  I will assume we are exporting a movie? [--subtitle=SUBTITLE]\n" if ( $title && !$subtitle );
print "You must specify either title OR basename, but not both.\n" if ( $user_filename && $title );
print "To supply your own cutlist, you must also supply --basename and --outfile\n" if ( $user_cutlist && !($user_filename && $user_outfile) );

# Conditional exits - these suck, but seem to work
# Exit if not all of the required parameters are supplied
if ( !$recordings_dir || !$temp_dir || !$output_dir || !($title || $user_filename) || !($mysql_password || $user_cutlist) ) {
    exit;
}
# Here is where we exit for conflicting filename options
if ( $title && $user_filename ) {
    exit;
}
# Exit if not all user-cutlist options are present
if ( $user_cutlist && !($user_filename && $user_outfile) ) {
    exit;
}

# Let's print some feedback about the supplied arguments
print "Here's what I understand we'll be doing:\n";
print "I'll be accessing the '$mysql_db' database on the host '$mysql_host'\n\tas the user '$mysql_user' (I'm not going to show you the password)\n" if ( $mysql_password );
print "I cannot update the MythTV jobqueue table because I was not supplied a jobid.\n" if ( $mysql_password && !$jobid );
print "The jobid supplied is: $jobid\n" if ( $mysql_password && $jobid );
print "Output filename specified - no details will be looked up online.\n" if ( $user_outfile );
if ($title) {
    print "I'll then export the recording: ";
    $subtitle ne "" ? print "$title - $subtitle" : print "$title";
} else {
    print "I'll export the recording stored in the file: ";
    print "$user_filename";
}
print "\n";
if ( $user_cutlist ) {
    print "I'll be using the user-supplied cutlist instead of querying the MythTV database.\n";
}
print "I'll be using the search string '$searchtitle'\n\tfor the tvdb query instead of '$title'.\n" if ( $searchtitle );
print "***** DRY RUN.  WILL NOT PRODUCE ANY OUTPUT FILES. *****\n\n" if ( $dryrun );

# Now print some confirmation of the verbosity selection
if ( $verbose && !$debug ) {
    print "Verbose mode\n\n";
    $debug = 1;
} elsif ( $debug && !$verbose ) {
    print "Debug mode\n\n";
    $debug = 2;
} else {
    $debug = 0;
}

# Check for ffmpeg executable
my $ffmpeg_path = which('ffmpeg');
if ( !defined $ffmpeg_path ) {
    print "ffmpeg not found in $ENV{'PATH'}\n";
    exit 1;
} else {
    print "ffmpeg found at $ffmpeg_path\n" if ( $debug >= 1 );
}
# Check for mkvmerge executable
my $mkvmerge_path = which('mkvmerge');
if ( !defined $mkvmerge_path ) {
    print "mkvmerge not found in $ENV{'PATH'}\n";
    exit 1;
} else {
    print "mkvmerge found at $mkvmerge_path\n" if ( $debug >= 1 );
}
# Check for mediainfo executable
my $mediainfo_path = which('mediainfo');
if ( !defined $mediainfo_path ) {
    print "mediainfo not found in $ENV{'PATH'}\n";
    exit 1;
} else {
    print "mediainfo found at $mediainfo_path\n" if ( $debug >= 1 );
}

## Proceed with the export
print "\n\n########## Start export output ##########\n\n";

# Stupid variable reassignment...too lazy to fix properly right now
$progname = $title;

if ( !$user_cutlist ) {
# Let's use perl's DBI module to access the database
# Connect to MySQL database
$dbh = DBI->connect("DBI:mysql:database=" . $mysql_db . ";host=" . $mysql_host, $mysql_user, $mysql_password);
# prepare the query
my @infoparts;

    if ( !$user_filename ) {
        $query_str = "SELECT chanid,starttime,endtime,originalairdate,basename,title,subtitle FROM recorded WHERE title LIKE ? AND subtitle LIKE ?";
        print "Query: $query_str\n\tprogname: $progname\n\tsubtitle: $subtitle\n" if ( $debug > 1 );
        $query = $dbh->prepare($query_str);
        # Retrieve program information
        # execute query ->
        $query->execute($progname,$subtitle);
        # fetch response
        @infoparts = $query->fetchrow_array();
        $debug > 1 ? print "Infoparts: " . Dumper(@infoparts) . "\n" : 0;
        $basename = $infoparts[4];
    } else {   # This query is for lookup based on the MythTV filename
        $query_str = "SELECT chanid,starttime,endtime,originalairdate,basename,title,subtitle FROM recorded WHERE basename = ?";
        print "Query: $query_str\n" if ( $debug > 1 );
        $query = $dbh->prepare($query_str);
        # Retrieve program information
        # execute query ->
        $query->execute($user_filename);
        # fetch response
        @infoparts = $query->fetchrow_array();
        $debug > 1 ? print "Infoparts: " . Dumper(@infoparts) . "\n" : 0;
        $basename = $user_filename;
        $title = $infoparts[5];
        $subtitle = $infoparts[6];
    }


# put the channel id and starttime into more intuitive variables
$chanid = $infoparts[0];
$starttime = $infoparts[1];
# release the query
$query->finish;

# Let's make sure that the response is not empty
if ( !@infoparts or length($infoparts[0]) == 0 or length($infoparts[1]) == 0 ) {
    print "Indicated program does not exist in the mythconverg.recorded table.\nPlease check your inputs and try again.\nExiting...\n";
    exit 1; # We'll exit with a non-zero exit code.  The '1' has no significance at this time.
}

$originalairdate = $infoparts[3];
@date_array = split /\s+/, "$infoparts[1]";
$recordedairdate = $date_array[0];

} else {
    $progname = $title;
    $basename = $user_filename;
}

# Add a trailing forward slash to the directories to be safe
$recordings_dir .= '/';
$temp_dir .= '/';
$output_dir .= '/';

# Trim whitespace from title(s)
$progname =~ s/^\s+//;          # leading
$progname =~ s/\s+$//;          # trailing
$subtitle =~ s/^\s+//;          # leading
$subtitle =~ s/\s+$//;          # trailing

# Set up for TheTVDB.com lookup
$apikey = "259FD33BA7C03A14";
$THETVDB = "www.thetvdb.com";
$global_user_agent = LWP::UserAgent->new;
print "Program Name: $progname\n";
print "Subtitle: $subtitle\n";
$progname =~ s/\'/\\'/g;        # SQL doesn't like apostrophes
$subtitle =~ s/\'/\\'/g;

# Be sure to override the MythTV program name with the alternate search-title, if supplied
$progname = $searchtitle if ( $searchtitle );

# cleanup for tvdb query
$progname =~ s/\\'//g;          # TVDB doesn't like apostrophes either
$subtitle =~ s/\\'//g;

# Compose the full-path filename
$filename = "$recordings_dir" . $basename;  # use value extracted from the database
print "Recording Filename: $filename\n";

# Get the frame rate from the video
my $fps = `mediainfo --Inform="Video;%FrameRate%" "$filename"`;
print "Detected frame-rate of input video: $fps\n" if ( $debug >= 1 );

if ( !$user_outfile ) {
    # if the user specified the output filename, the thetvdb.com lookup is
    # inhibited.
    if ( length($originalairdate) > 0 and length($recordedairdate) > 0 ) {
        print "Original airdate: $originalairdate\n" if ( $debug >= 1 );
        print "Recorded Date: $recordedairdate\n\n" if ( $debug >= 1 );
    } else {
        print "Zero length query strings for thetvdb.com. Exiting...\n";
        exit 1;
    }
    $airdate = $originalairdate ne '0000-00-00' ? $originalairdate : $recordedairdate;
}

if ( !$user_cutlist ) {
    # Cutlist retrieval directly from database
    # We want a cutlist if available (it is user created), so we'll query for that first.
    $query_str = "SELECT mark,type FROM recordedmarkup WHERE chanid=? AND starttime=? AND ( type=0 OR type=1 ) ORDER BY mark ASC";
    $debug > 1 ? print "Direct cutlist query string: $query_str\n" : 0;
    $query = $dbh->prepare($query_str) or die "Couldn't prepare statement: " . $dbh->errstr;
    $query->execute($chanid,$starttime);
    my @marks;
    my @types;
    my $secs;
    # Loop through each database response
    print "Cutlist/Skiplist query response:\n" if ( $debug >= 1 );
    while ( @markup = $query->fetchrow_array() ) {
        $secs = $markup[0] / $fps;
        print "\tmark: $markup[0] ($secs s) (" . sprintf("%02d",floor($secs/3600)) . ":" . sprintf("%02d",fmod(floor($secs/60),60)) . ":" . sprintf("%06.3f",fmod($secs,60)) . "s)\t\ttype: $markup[1]\n" if ( $debug >= 1 );
        # store the markup frame number and type for later use
        push(@marks,$markup[0]);
        push(@types,$markup[1]);
    }
    # release the query
    $query->finish;

    # A cutlist was not found.  Let's query for a commercial skip list.
    if ( !@marks ) {
        $query_str = "SELECT mark,type FROM recordedmarkup WHERE chanid=? AND starttime=? AND ( type=4 OR type=5 ) ORDER BY mark ASC";
        print "Direct skiplist query string: $query_str\n" if ( $debug > 1 );
        $query = $dbh->prepare($query_str) or die "Couldn't prepare statement: " . $dbh->errstr;
        $query->execute($chanid,$starttime);
        # loop through each database response
        while ( @markup = $query->fetchrow_array() ) {
            $secs = $markup[0] / $fps;
            print "\tmark: $markup[0] ($secs s) (" . sprintf("%02d",floor($secs/3600)) . ":" . sprintf("%02d",fmod(floor($secs/60),60)) . ":" . sprintf("%06.3f",fmod($secs,60)) . "s)\t\ttype: $markup[1]\n" if ( $debug >= 1 );
            # store for later use
            push(@marks,$markup[0]);
            push(@types,$markup[1]);
        }
        # release the query
        $query->finish;
    }
    if ( !@marks ) {
        print "No cutlist or commercial skiplist found for specified recording.\nPlease check your inputs and/or create a cutlist then try again.  Exiting...\n";
        exit 1;
    }
    foreach my $mark ( @marks ) {
        # running commands with backquotes (``) will return the command output to perl.
        $secs = $mark / $fps;
        $cutlist_sub_str .= sprintf("%02d",floor($secs/3600)) . ":" . sprintf("%02d",fmod(floor($secs/60),60)) . ":" . sprintf("%06.3f",fmod($secs,60)) . ",";
        $ctr++;
    }
    $ctr++;
    print "marks[0]: $marks[0]\n" if ( $debug > 1 );
    # We need to make sure that the first cut point is a cut-start, not a cut-end
    if ( $marks[0] == 0 or $types[0] == 0 or $types[0] == 5 ) {
        $vidstart = 2;
    } else {
        $vidstart = 1;
    }
} else {
    # The user supplied a cutlist
    # We should validate it before proceeding
    #    - the format is: vidstart::timecode_1,timecode_2,...,timecode_n
    #        - vidstart is an integer, 1 or 2, indicating which segment to be first
    #        - timecode_n is in the format HH:MM:SS.sss
    if ( $user_cutlist =~ m/(\d)::((\d{2}:\d{2}:\d{2}(\.\d{0,3})?,?)+)+/g ) {
        # First, we need to capture the 2 segments
        $vidstart = $1;
        $cutlist_sub_str = $2;
        print "User supplied vidstart: $vidstart\n";
        # ensure proper input of vidstart integer...
        if ( !($vidstart == 1 or $vidstart == 2) ) {
            print "The starting segment parameter must either be a 1 or 2.\n";
            exit 1;
        }
        $cutlist_sub_str =~ s/,$//g;
        print "User supplied cutlist_sub_str: $cutlist_sub_str\n";
        # We need to know how many segments there are to set the $ctr
        # variable.
        my @split_cutlist = split(/,/, $cutlist_sub_str);
        $ctr = scalar(@split_cutlist) + 1;
        print "Detected $ctr split segments.\n";
        # @NOTE: Should we check for increasing timecodes?  How does
        # mkvmerge handle non-increasing timecodes?
    } else {
        print "It seems that your supplied cutlist does not meet the required format: \n";
        print "\tvidstart::timecode_1,timecode_2,...,timecode_n\n";
        print "\twhere vidstart=(1,2) and\n\ttimecode_n=HH:MM:SS(.sss)\n\n";
        exit 1;
    }
}

#####
# Query thetvdb.com for program information
#####

$outfile = '';
if ( !$user_outfile ) {
    # only query if the user didn't specify the output filename.
    if ( $subtitle ne "" ) {
        print "Beginning thetvdb.com lookup...\n";
        @T = parse_episode_content($progname);
        $S = $T[0];             # series title
        $E = $T[1];             # episode title
        if ( length($S) == 0 or length($E) == 0 ) {
            print "Empty season or episode number returned from thetvdb.com.  Exiting...\n";
            exit 1;
        }
        # Print some useful information
        print "\tSeason Number: $S\n";
        print "\tEpisode Number: $E\n";
        # Generate the output filename
        $outfile = "$progname.S${S}E${E}";
    } else {
        print "Skipping thetvdb.com lookup...\n";
        $outfile = "$progname";
    }
    # Display the output filename
    print "The output file name is: \"$outfile.mkv\"\n";
} else {
    $outfile = $user_outfile;
}


#####
# Begin cutting procedure
#####

# Some error checking to ensure that we actually have a cutlist before proceding with the system calls
if ( $cutlist_sub_str eq "" ) {
    print "There seems to be no cutlist or skiplist present for this recording. EXITING!!!\n";
    # Update status and comment fields in the jobqueue table to inform the user of the exit reason
    updateStatus($dbh,$jobid,288,"There was no cut/skip list" . $user_cutlist ? "supplied" : "found"  . " for the recording.") if ( $jobid );
    exit;
} else {
    # Remove any trailing commas from the cutlist string
    $cutlist_sub_str =~ s/,$//g;
    print "mkvmerge timecodes: $cutlist_sub_str\n" if ( $debug >= 1 );
    print "\tctr: $ctr\n\tvidstart: $vidstart\n" if ( $debug > 1 );
}

if ( !$dryrun ) {
    updateStatus($dbh,$jobid,4,"($outfile): Starting ffmpeg conversion.");
    # First we need to run the MPEG-TS file through ffmpeg to mux it into a Matroska container
    my $ffmpeg_string = "ffmpeg -y -i \"$filename\" -vcodec copy -acodec copy -f matroska $temp_dir/temp_$now.mkv";
    print "Calling ffmpeg to repackage video file into Matroska (mkv) container.\n" if ( $debug >= 1 );
    print "ffmpeg call: $ffmpeg_string\n" if ( $debug > 1 );
    system $ffmpeg_string;
    if ( $? == -1 ) {
        print "($outfile): ERROR. Failed to execute ffmpeg system call -> $ffmpeg_string\n";
        cleanup_temp();
        exit 1;
    } elsif ( $? & 127 ) {
        printf "($outfile): ERROR. Child (ffmpeg) process died with signal %d, %s coredump\n", ($? & 127), ($? & 128) ? 'with' : 'without';
        cleanup_temp();
        exit 1;
    } else {
        $ffmpeg_exit_code = $? >> 8;
        if ( $ffmpeg_exit_code != 0 ) {
            # There was an error.  Update the jobqueue table appropriately and exit.
            updateStatus($dbh,$jobid,304,"($outfile): ffmpeg child process exited with error code $ffmpeg_exit_code.");
            exit 1;
        } else {
            # ffmpeg call exited normally - update jobqueue comment to indicate runtime status
            updateStatus($dbh,$jobid,4,"($outfile): ffmpeg conversion step completed, beginning mkvmerge split.");
        }
    }

    # Now we can call mkvmerge to split the file
    my $split_string = "mkvmerge -o $temp_dir/split_$now.mkv --split timecodes:$cutlist_sub_str $temp_dir/temp_$now.mkv";
    print "Calling mkvmerge to split video file.\n" if ( $debug >= 1 );
    print "mkvmerge split call: $split_string\n" if ( $debug > 1 );
    system $split_string;
    if ( $? == -1 ) {
        print "($outfile): ERROR. Failed to execute mkvmerge (split) system call -> $split_string\n";
        cleanup_temp();
        exit 1;
    } elsif ( $? & 127 ) {
        printf "($outfile): ERROR. Child (mkvmerge split) process died with signal %d, %s coredump\n", ($? & 127), ($? & 128) ? 'with' : 'without';
        cleanup_temp();
        exit 1;
    } else {
        $split_exit_code = $? >> 8;
        if ( $split_exit_code == 1 ) {
            # There was a warning during execution.  Update the jobqueue table, but continue.
            updateStatus($dbh,$jobid,304,"($outfile): mkvmerge (split) child process completed with warnings.  The output file(s) may have errors.");
        } elsif ( $split_exit_code == 2 ) {
            # There was an error during execution.  Update the jobqueue table and exit.
            updateStatus($dbh,$jobid,304,"($outfile): mkvmerge (split) child process exited with errors.  Stopping job.");
            exit 1;
        } else {
            # ffmpeg call exited normally - update jobqueue comment to indicate runtime status
            updateStatus($dbh,$jobid,4,"($outfile): mkvmerge (split) conversion step completed, beginning mkvmerge merge.");
        }
    }

    # build the merge string
    if ( $vidstart == 1 ) {
        $merge_string = "$temp_dir/split_$now-001.mkv";
    } else {
        $merge_string = "$temp_dir/split_$now-002.mkv";
    }
    for ( my $n=$vidstart+2; $n<=$ctr; $n+=2 ) {
        print "n: $n\n" if ( $debug > 1 );
        $merge_string = $merge_string . " +$temp_dir/split_$now-" . sprintf("%03d",$n) . ".mkv";
    }
    print "Calling mkvmerge to re-join the cut video files.\n" if ( $debug >= 1 );
    print "mkvmerge merge string: $merge_string\n" if ( $debug > 1 );
    # Now merge the proper files
    system "mkvmerge -o $output_dir/\"$outfile\".mkv $merge_string";
    if ( $? == -1 ) {
        print "($outfile): ERROR. Failed to execute mkvmerge (merge) system call -> $merge_string\n";
        cleanup_temp();
        exit 1;
    } elsif ( $? & 127 ) {
        printf "($outfile): ERROR. Child (mkvmerge merge) process died with signal %d, %s coredump\n", ($? & 127), ($? & 128) ? 'with' : 'without';
        cleanup_temp();
        exit 1;
    } else {
        $merge_exit_code = $? >> 8;
        if ( $merge_exit_code == 1 ) {
            # There was a warning during execution.  Update the jobqueue table, but continue.
            updateStatus($dbh,$jobid,304,"($outfile): mkvmerge (merge) child process completed with warnings.  The output file(s) may have errors.");
        } elsif ( $merge_exit_code == 2 ) {
            # There was an error during execution.  Update the jobqueue table and exit.
            updateStatus($dbh,$jobid,304,"($outfile): mkvmerge (merge) child process exited with errors.  Stopping job.");
            exit 1;
        } else {
            # ffmpeg call exited normally - update jobqueue comment to indicate runtime status
            updateStatus($dbh,$jobid,4,"($outfile): mkvmerge (merge) conversion step completed.");
        }
    }

    # cleanup
    cleanup_temp();
}

# let's set the exit status as successful
updateStatus($dbh,$jobid,272,"($outfile): Export finished.") if ( $jobid );

# disconnect from the database
$dbh->disconnect() if ( $mysql_password );

# Clean exit
exit 0;

#################### END OF PROGRAM ####################


#####
# Begin sub-functions
#####

# Most important -> ctrl-c trap to exit cleanly
sub sigint_exit {
    print "\n\nCaught Ctrl-c interrupt! Exiting...\n\n";
    cleanup_temp();
    exit 99;
}

sub cleanup_temp {
    # Do a little cleanup (don't if debug mode is in use)
    system "rm $temp_dir/*$now*" if ( $debug <= 1 );
}

sub updateStatus
        {
            my $dbh = 0;
            my $jobid = 0;
            my $status_code = 0;
            my $comment_str = 0;

            $dbh = $_[0];
            $jobid = $_[1];
            $status_code = $_[2];
            $comment_str = $_[3];

            if ( $dbh && $jobid && $status_code && $comment_str ) {
                $query_str = "UPDATE jobqueue SET status=?,comment=? WHERE id=?";
                print "Update jobqueue status query: $query_str\n" if ( $debug > 1 );
                $query = $dbh->prepare($query_str);
                # Retrieve program information
                # execute query ->
                $query->execute($status_code,$comment_str,$jobid);
            }
        }

sub get_http_response_lwp
        {
            my $request_url = $_[0];
            print "About to call GET HTTP url: '$request_url'\n" if ( $debug >= 1 );
            my $req = HTTP::Request->new(GET => $request_url);

            # Pass request to the user agent and get a response back
            my $res = $global_user_agent->request($req);

            # Check the outcome of the response
            if ($res->is_success) {
                my $response_content = $res->content;
                print "Got HTTP response.\n" if ( $debug >= 1 );
                print "$response_content\n" if ( $debug > 1 );
                return $response_content;
            } else {
                print "Failed to get response! Status '".$res->status_line."'\n";
                return "";
            }
        }

sub get_http_response
        {
            my $content = get_http_response_lwp($_[0]);
            $content =~ s/(\n|\r|\f)/ /gi;
            $content =~ s/&.{1,8}?;/ /gi;
            return $content;
        }

sub min
        {
            my @list = @{$_[0]};
            my $min = $list[0];

            foreach my $i (@list) {
                $min = $i if ($i < $min);
            }

            return $min;
        }

sub levenshtein
        {
            # $s1 and $s2 are the two strings
            # $len1 and $len2 are their respective lengths
            #
            my ($s1, $s2) = @_;
            #ofcourse, I want only letters and digits.
            $s1 =~ tr/[\.\_\-\[\]!\(\)\:]/ /;
            $s2 =~ tr/[\.\_\-\[\]!\(\)\:]/ /;
            #ofcourse, all should be lowercase.
            $s1 =~ tr/[A-Z]/[a-z]/;
            $s2 =~ tr/[A-Z]/[a-z]/;
            #no n-spaces.
            $s1 =~ s/\s+/ /g;
            $s2 =~ s/\s+/ /g;

            print "string1 (user supplied): '$s1'. string2 (nth tvdb response): '$s2'\n" if ( $debug > 1 );

            my ($len1, $len2) = (length $s1, length $s2);

            # If one of the strings is empty, the distance is the length
            # of the other string
            #
            return $len2 if ($len1 == 0);
            return $len1 if ($len2 == 0);

            my %mat;

            # Init the distance matrix
            #
            # The first row to 0..$len1
            # The first column to 0..$len2
            # The rest to 0
            #
            # The first row and column are initialized so to denote distance
            # from the empty string
            #
            for (my $i = 0; $i <= $len1; ++$i) {
                for (my $j = 0; $j <= $len2; ++$j) {
                    $mat{$i}{$j} = 0;
                    $mat{0}{$j} = $j;
                }

                $mat{$i}{0} = $i;
            }

            # Some char-by-char processing is ahead, so prepare
            # array of chars from the strings
            #
            my @ar1 = split(//, $s1);
            my @ar2 = split(//, $s2);

            for (my $i = 1; $i <= $len1; ++$i) {
                for (my $j = 1; $j <= $len2; ++$j) {
                    # Set the cost to 1 iff the ith char of $s1
                    # equals the jth of $s2
                    #
                    # Denotes a substitution cost. When the char are equal
                    # there is no need to substitute, so the cost is 0
                    #
                    my $cost = ($ar1[$i-1] eq $ar2[$j-1]) ? 0 : 1;

                    # Cell $mat{$i}{$j} equals the minimum of:
                    #
                    # - The cell immediately above plus 1
                    # - The cell immediately to the left plus 1
                    # - The cell diagonally above and to the left plus the cost
                    #
                    # We can either insert a new char, delete a char or
                    # substitute an existing char (with an associated cost)
                    #
                    $mat{$i}{$j} = min([$mat{$i-1}{$j} + 1,
                                        $mat{$i}{$j-1} + 1,
                                        $mat{$i-1}{$j-1} + $cost]);
                }
            }

            # Finally, the Levenshtein distance equals the rightmost bottom cell
            # of the matrix
            #
            # Note that $mat{$x}{$y} denotes the distance between the substrings
            # 1..$x and 1..$y
            #
            my $lev_result = $mat{$len1}{$len2};
            print "lev_result: $lev_result\n" if ( $debug > 1 );
            #Now, I want to soften it a bit
            #So, i'm taking the distance between the strings, but not the added letters.
            my $string_length_diff = abs($len1 - $len2);
            return abs($lev_result - $string_length_diff);
        }

sub search_the_tv_db_for_series
        {
            my $series = $_[0];
            my $bad_series_array = $_[1];
            my $series_for_url = $series;
            my $scontent = get_http_response("http://".$THETVDB."/api/GetSeries.php?seriesname=$series_for_url");
            my $series_id = "";
            my $poster = "";
            my $plot = "";
            my $tvdb_series_name = "";
            my $while_ctr = 0;

            print "Searching THE-TV-DB for series '$series'\n" if ( $debug > 1 );

            my $best_similarity = 1000000;
            #? marks the regexp as ungreedy (don't look for the longest, look for the first - which is actually IS a greedy algorithm...)
            #"gi" at the end makes it recursive
            #while ($scontent =~ m/<seriesid>(.+?)<\/seriesid>.*?<seriesname>(.+?)<\/seriesname>.*?<banner>(.+?)<\/banner>.*?<overview>(.+?)<\/overview>/gi)
            while ($scontent =~ m/<series>.*?<seriesid>(.+?)<\/seriesid>.*?<seriesname>(.+?)<\/seriesname>(.+?)<\/series>/gi) {
                print "Loop: $while_ctr\n" if ( $debug > 1 );
                my $temp_series_id = $1;
                my $temp_series_name = $2;
                print "temp_series_id: $temp_series_id, temp_series_name: $temp_series_name\n" if ( $debug > 1 );
                my $current_similarity = levenshtein($series, $temp_series_name);
                print "Best similarity: $best_similarity Current: $current_similarity\n" if ( $debug > 1 );
                my %map_hash = map { $_ => 1 } @$bad_series_array;
                if ( ($current_similarity < $best_similarity) and !(exists {map { $_ => 1 } @$bad_series_array}->{$temp_series_id}) ) {
                    if ($series_id eq "") {
                        print "Found a possible match for '$series' as '$temp_series_name' (ID $temp_series_id)\n" if ( $debug >= 1 );
                    } else {
                        print "Found a better possible match for '$series' as '$temp_series_name' (ID $temp_series_id)\n" if ( $debug >= 1 );
                    }
                    $best_similarity = $current_similarity;
                    $series_id = $1;
                    $tvdb_series_name = $2;
                    my $rest_of_the_data = $3;
                    if ($rest_of_the_data =~ m/<banner>(.+?)<\/banner>/i) {
                        $poster = "http://".$THETVDB."/banners/".$1;
                    } else {
                        $poster = "";
                    }

                    if ($rest_of_the_data =~ m/<overview>(.+?)<\/overview>/i) {
                        $plot = $1;
                    } else {
                        $plot = "";
                    }
                }
                print "++++++++++++++++++++++++++++++++++++++++++\n" if ( $debug > 1 );
                $while_ctr++;
            }
            if ((length $series_id) > 0) {
                print "Found ID '$series_id' for series '$tvdb_series_name' at THE-TV-DB.\n";
                # return both the selected series ID and the count of series in the response
                return ($series_id,$while_ctr);
            } else {
                print "Can not locate series '$series' in THE-TV-DB.\n";
                return ("", "", "", "", "");
            }
        }

sub parse_episode_season_numbers
        {
            my $content = $_[0];
            my $episode_number = "";
            my $season_number = "";
            if ($content =~ m/<EpisodeNumber>(.+)<\/EpisodeNumber>/i) {
                $episode_number = sprintf( "%02d", $1 );
            }
            if ($content =~ m/<SeasonNumber>(.+)<\/SeasonNumber>/i) {
                $season_number = sprintf( "%02d", $1 );
            }
            return ($season_number, $episode_number);
        }

sub parse_episode_content
        {
            my $series_name = $_[0];
            my $series_ctr = 1;
            my @bad_series_array = ("0");
            my @series_search_resp = search_the_tv_db_for_series($series_name,\@bad_series_array);
            print "series_search_resp: " . Dumper(@series_search_resp) if ( $debug > 1 );
            my $series_id = $series_search_resp[0];
            my $series_resp_count = $series_search_resp[1];
            # Now we compose a search url for THETVDB which uses the returned series ID and the original air date to lookup the episode name...
            my $content = get_http_response("http://".$THETVDB."/api/GetEpisodeByAirDate.php?apikey=$apikey&seriesid=$series_id&airdate=$airdate");
            # some crude parsing of the returned XML
            my @SEC = parse_episode_season_numbers($content);
            my $episode_number = $SEC[1];
            my $season_number = $SEC[0];

            # Now we need to test for empty responses, which would likely indicate that the wrong series was chosen
            while ( ( length($season_number) == 0 or length($episode_number) == 0 ) and $series_resp_count > 1 and $series_ctr < $series_resp_count ) {
                print "\n!!!!! No season/episode number match.  There were other series found.  Adding $series_id to the bad_series_array and trying the others...\n\n";
                $series_ctr++;
                push(@bad_series_array,$series_id);
                print "bad_series_array:\n" . Dumper(@bad_series_array) . "\n" if ( $debug > 1 );
                @series_search_resp = search_the_tv_db_for_series($series_name,\@bad_series_array);
                $series_id = $series_search_resp[0];
                $series_resp_count = $series_search_resp[1];
                # Again we search with the (hopefully) new series ID and original air date
                $content = get_http_response("http://".$THETVDB."/api/GetEpisodeByAirDate.php?apikey=$apikey&seriesid=$series_id&airdate=$airdate");
                # Again, some crude parsing of the returned XML
                @SEC = parse_episode_season_numbers($content);
                $episode_number = $SEC[1];
                $season_number = $SEC[0];
            }
            return ($season_number, $episode_number);
        }


__END__

=head1 NAME

hdpvrcutter.pl - Script to cut/edit Hauppauge HD PVR recordings made
with MythTV, exported to Matroska container.

=head1 SYNOPSIS

hdpvrcutter.pl --recordings=RECORDINGS_DIR --tempdir=TEMPORARY_DIR
--dest=DESTINATION_DIR {--title=TITLE --subtitle=SUBTITLE |
--basename=SRC_FILENAME} {--cutlist=CUTLIST_STRING | --passwd=PASSWORD
[--host=HOSTNAME --dbname=DBNAME --user=USER]}
[--outfile=DST_FILENAME] [--searchtitle=SEARCH_TITLE] [--jobid=JOBID]
[--verbose] [--debug] [--dryrun] [--help|-?] [--man]

=head1 DESCRIPTION

This script was created for the purpose of removing unwanted portions
of a video recording made by the powerful Open Source DVR MythTV when
using the Hauppauge HD PVR, component video, H.264 real-time video
encoder.

In the olden days, when a simple NTSC tuner card was all that was
required to make MPEG2 recordings of whatever came over that magical
copper wire, MythTV offered a built-in method to lossless-ly cut
unwanted portions of the recording.  As video codecs have increased in
complexity (for the sake of increased compression => space savings) it
became more difficult to make "lossless" cuts.  With the ubiquity of
h.264 recordings MythTV's lossless cut methods no longer functioned
properly.  This script provides what the author has found to be the
most reliable method of removing unwanted portions from a video
recorded in the h.264 format, specifically those produced by the
Hauppauge HD PVR.  As an aside, it has been found to work equally well
with h.264-in-MPEG2-container recordings obtained with an HDHomeRun
ATSC Over The Air (OTA) tuner.

=head1 EXTERNAL DEPENDENCIES

Aside from a handful of perl modules, there are three external
programs that the script relies on for the heavy lifting.  They
are ffmpeg, mkvmerge, and mediainfo.  As of 2012/02/05, the versions
in use by the author are: ffmpeg (git:cd2a27e1e5), mkvmerge (v5.2.1),
and mediainfo (v0.7.50).

=head1 OPTIONS

=over 8

=item B<--basename>

Basename of specific filename to be cut/edited.  The use of this
option disables the lookup with thetvdb.com, and also REQUIRES the use
of the --outfile option.  A potential use of this method of operation
is for exporting videos located within a MythVideo archive rather than
the main recordings directory.

=item B<--cutlist>

Allows user supplied cutlist instead of database lookup.  The format
of the input string is:

--cutlist=vidstart::timecode_1,timecode_2,...,timecode_n

Where:

- vidstart is an integer parameter, either 1 or 2, specifying which is
the first segment to use during the merge step.  For example, if the
recording starts with a segment that is not desired in the final
output, the correct value would be 2, indicating that the first
segment should be skipped.  The script assumes every other segment is
desired in the final output.

- timecode_n is a timecode of the format
HH:MM:SS(.sss).  Ensure that they are increasing in order.

=item B<--dbname>

MythTV MySQL database name.  Default is mythconverg.

=item B<--debug>

Provide useful debugging output during runtime (additional detail
over what --verbose provides).

=item B<--dest>

Path to destination directory.

=item B<--dryrun>

An optional debugging flag that allows the script to make all database
and TVDB queries but stop before generating any output.

=item B<--help, -h, -?>

Display this help message.

=item B<--host>

Hostname which hosts the MythTV MySQL database.  Default is localhost.

=item B<--jobid>

An optional parameter only useful when the script is run as a user-job
from within MythTV, allowing the script to update the status of
runtime or error in the MythTV Job Queue. In the user-job command
specification, this option should appear as --jobid=%JOBID%.

=item B<--man>

Display more detailed usage information.

=item B<--outfile>

User-overriding output file name.  Will be appended with .mkv extension.

=item B<--passwd>

Password for access to the MythTV MySQL database.

=item B<--recordings>

Path to folder containing input file, e.g., MythTV recordings
directory.

=item B<--searchtitle>

An optional string for extra "help" when querying thetvdb.com.  This
option is slowly becoming deprecated by tweaks to the automated
search-response processing; however, if you find that your series or
movie title is a bit obscure and is not being properly found by the
script, you can supply the desired title, exactly as found on
thetvdb.com, for more accurate results.

=item B<--subtitle>

Subtitle of recording to be exported from MythTV, e.g., episode
title. This serves as a lookup string for querying the MythTV
database.  It is NOT used when querying thetvdb.com.  Instead, the
original airdate that is returned from the MythTV database is used to
lookup specific episode information.

=item B<--tempdir>

Path to temporary working directory.

=item B<--title>

Title of recording to be exported from MythTV, e.g., series or movie
title.  This serves as a lookup string for querying the  MythTV
database as well as for searching thetvdb.com for episode information.

=item B<--verbose>

Provide some additional output during runtime.

=back

=head1 Author

Maintained by Edward Hughes IV <edward@edwardhughes.org>, with third
party contributions through github.com.  The project can be found at
http://github.com/edwardhughes/hdpvrcutter.pl

The script was inspired by the work of Christopher Meredith, found at
http://monopedilos.com/dokuwiki/doku.php?id=hdpvrcutter.pl

=cut
