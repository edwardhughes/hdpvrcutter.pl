#!/usr/bin/perl -w
#
# HD-PVR Cutter
#
#	Modified by: Edward Hughes IV (edward ATSIGN edwardhughes DOT org) starting 2011/03/16
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
#    MKVtoolnix  - specifically mkvmerge to do the splitting AND the merging of the cut video >= 5.0.0
#    ffmpeg to pre-process the recording into a Matroska container (no longer a dependency...still deciding its fate)
#    Working MythTV database and access to the recordings directory
#
# Type hdpvrcutter.pl --help for usage information.
#
#
# @todo: define exit codes
# @todo: add mkvtoolnix version check for conditional ffmpeg system call
#


use LWP::UserAgent;
use DBI;
use File::Copy;
use POSIX;
use Getopt::Long;

# Debugging modules
use Data::Dumper;

################################################################################
## Leave everything below this line alone unless you know what you are doing!
################################################################################

#First setup the sigint handler
use sigtrap 'handler' => \&sigint_exit, 'INT';

# Some variables
my $fps = 29.97;
my $cutlist_sub_str = "";
my $ctr = 0;
my $vidstart;
my $now = time();

## Process command line arguments

# Delcare variables with default values
my $verbose = '';
my $debug = '';
my $dryrun = 0;
my $direct_db_cutlist = '';
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
my $help = '';

# Print the help if requested or no arguments are used
usage() if ( @ARGV < 1 or ! GetOptions(
                                       'verbose' => \$verbose,
                                       'debug' => \$debug,
                                       'dryrun' => \$dryrun,
                                       'title=s' => \$title,
                                       'searchtitle=s' => \$searchtitle,
                                       'subtitle:s' => \$subtitle, # optional string - empty string is used to assume a movie
                                       'host=s' => \$mysql_host,
                                       'dbname=s' => \$mysql_db,
                                       'user=s' => \$mysql_user,
                                       'passwd=s' => \$mysql_password,
                                       'recordings=s' => \$recordings_dir,
                                       'tempdir=s' => \$temp_dir,
                                       'dest=s' => \$output_dir,
                                       'help|?' => \$help)
           );

sub usage
        {
            print "Unknown option: @_\n" if ( @_ );
            print "usage: hdpvrcutter.pl --passwd=PASSWORD --recordings=RECORDINGS_DIR --tempdir=TEMPORARY_DIR --dest=DESTINATION_DIR --title=TITLE --subtitle=SUBTITLE [--verbose] [--debug] [--dryrun] [--host=HOSTNAME] [--dbname=DBNAME] [--user=USER] [--searchtitle SEARCH_TITLE] [--help|-?]\n";
            exit;
        }

# Trim whitespace from title(s)
$progname = $title;
$progname =~ s/^\s+//;          # leading
$progname =~ s/\s+$//;          # trailing
$subtitle =~ s/^\s+//;          # leading
$subtitle =~ s/\s+$//;          # trailing

# Checks and error messages for required flags
print "Must supply the password for the MySQL MythTV database [--passwd=PASSWORD] .\n" if ( !$mysql_password );
print "Must supply the full path to the MythTV recordings directory [--recordings=RECORDINGS_DIR].\n" if ( !$recordings_dir );
print "Must supply the full path the the temporary working directory [--tempdir=TEMPORARY_DIR].\n" if ( !$temp_dir );
print "Must supply the full the path the to output destination directory [--dest=DESTINATION_DIR].\n" if ( !$output_dir );
print "How can you export a show without a title?  [--title=TITLE]\n" if ( !$title );
print "No subtitle.  I will assume we are exporting a movie? [--subtitle=SUBTITLE]\n" if ( !$subtitle );

# Exit if not all of the required parameters are supplied
if ( !$mysql_password or !$recordings_dir or !$temp_dir or !$output_dir or !$title ) {
    exit;
}

# Let's print some feedback about the supplied arguments
print "Here's what I understand we'll be doing:\n";
print "I'll be accessing the '$mysql_db' database on the host '$mysql_host'\n\tas the user '$mysql_user' (I'm not going to show you the password)\n";
print "I'll then export the recording: ";
$subtitle ne "" ? print "$title - $subtitle" : print "$title";
print "\n";
print "One more thing...I'll be using the search string '$searchtitle'\n\tfor the tvdb query instead of '$title'.\n" if ( $searchtitle );
print "\n***** DIRECT DB ACCESS FOR CUTLIST/SKIPLIST RETRIEVAL.  NOT AS RELIABLE AS 'mythcommflag'! *****\n\n" if ( $direct_db_cutlist );
print "***** DRY RUN.  WILL NOT PRODUCE ANY OUTPUT FILES. *****\n\n" if ( $dryrun );
if ( $debug ) {
    $debug = 2;
} else {
    $debug = 0;
}
if ( $verbose and $debug == 0 ) {
    print "Verbose mode\n";
    $debug = 1;
}


## Proceed with the export

# Add a trailing forward slash to the directories to be safe
$recordings_dir .= '/';
$temp_dir .= '/';
$output_dir .= '/';

$apikey = "259FD33BA7C03A14";
$THETVDB = "www.thetvdb.com";
$global_user_agent = LWP::UserAgent->new;
print "Program Name: $progname\n";
print "Subtitle: $subtitle\n";
$progname =~ s/\'/\\'/g;        # SQL doesn't like apostrophes
$subtitle =~ s /\'/\\'/g;


# Let's use perl's DBI module to access the database
# Connect to MySQL database
$dbh = DBI->connect("DBI:mysql:database=" . $mysql_db . ";host=" . $mysql_host, $mysql_user, $mysql_password);
# prepare the query (this is bad - dynamic query generation - but since this is local and not a web app we'll allow it)
$query_str = "SELECT chanid,starttime,endtime,originalairdate FROM recorded WHERE title LIKE ? AND subtitle LIKE ?";
$debug > 1 ? print "Query: $query_str\n" : 0;
$query = $dbh->prepare($query_str);
# Retrieve program information
# execute query ->
$query->execute($progname,$subtitle);
# fetch response
@infoparts = $query->fetchrow_array();
$debug > 1 ? print "Infoparts: " . Dumper(@infoparts) . "\n" : 0;
# put the channel id and starttime into more intuitive variables
$chanid = $infoparts[0];
$starttime = $infoparts[1];

# Let's make sure that the response is not empty
if ( !@infoparts or length($infoparts[0]) == 0 or length($infoparts[1]) == 0 ) {
    print "Indicated program does not exist in the mythconverg.recorded table.\nPlease check your inputs and try again.\nExiting...\n";
    exit 1; # We'll exit with a non-zero exit code.  The '1' has no significance at this time.
}

# Cutlist retrieval directly from database
# We want a cutlist if available (it is user created), so we'll query for that first.
$query_str = "SELECT mark,type FROM recordedmarkup WHERE chanid=? AND starttime=? AND ( type=0 OR type=1 ) ORDER BY mark ASC";
$debug > 1 ? print "Direct cutlist query string: $query_str\n" : 0;
$query = $dbh->prepare($query_str) or die "Couldn't prepare statement: " . $dbh->errstr;
$query->execute($chanid,$starttime);
my @marks;
my @types;
my $secs;
while ( @markup = $query->fetchrow_array() ) {
    $secs = $markup[0] / $fps;
    print "\tmark: $markup[0] ($secs s) (" . sprintf("%02d",floor($secs/3600)) . ":" . sprintf("%02d",fmod(floor($secs/60),60)) . ":" . sprintf("%06.3f",fmod($secs,60)) . "s)\t\ttype: $markup[1]\n" if ( $debug >= 1 );
    push(@marks,$markup[0]);
    push(@types,$markup[1]);
}
# A cutlist was not found.  Let's query for a commercial skip list.
if ( !@marks ) {
    $query_str = "SELECT mark,type FROM recordedmarkup WHERE chanid=? AND starttime=? AND ( type=4 OR type=5 ) ORDER BY mark ASC";
    print "Direct skiplist query string: $query_str\n" if ( $debug > 1 );
    $query = $dbh->prepare($query_str) or die "Couldn't prepare statement: " . $dbh->errstr;
    $query->execute($chanid,$starttime);
    while ( @markup = $query->fetchrow_array() ) {
        $secs = $markup[0] / $fps;
        print "\tmark: $markup[0] ($secs s) (" . sprintf("%02d",floor($secs/3600)) . ":" . sprintf("%02d",fmod(floor($secs/60),60)) . ":" . sprintf("%06.3f",fmod($secs,60)) . "s)\t\ttype: $markup[1]\n" if ( $debug >= 1 );
        push(@marks,$markup[0]);
        push(@types,$markup[1]);
    }
}
if ( !@marks ) {
    print "No cutlist or commercial skiplist found for specified recording.\nPlease check your inputs and/or create a cutlist then try again.  Exiting...\n";
    exit 1;
}
foreach my $mark ( @marks ) {
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

# release the query
$query->finish;
# disconnect from the database
$dbh->disconnect();

# Be sure to override the MythTV program name with the alternate search-title, if supplied
$progname = $searchtitle if ( $searchtitle );

# cleanup for tvdb query
$progname =~ s/\\'//g;          # TVDB doesn't like apostrophes either
$subtitle =~ s/\\'//g;

# create the recording filename
$filename = $chanid . "_" . $starttime;

# some regex to make the filename play nice with the file system
$filename =~ s/\ //g;
$filename =~ s/://g;
$filename =~ s/-//g;
$filename .= ".mpg";
$filename = "$recordings_dir" . $filename;
print "Recording Filename: $filename\n";

$originalairdate = $infoparts[3];
@date_array = split /\s+/, "$infoparts[1]";
$recordedairdate = $date_array[0];

if ( length($originalairdate) > 0 and length($recordedairdate) > 0 ) {
    print "Original airdate: $originalairdate\n" if ( $debug >= 1 );
    print "Recorded Date: $recordedairdate\n" if ( $debug >= 1 );
} else {
    print "Zero length query strings for thetvdb.com. Exiting...\n";
    exit 1;
}

$airdate = $originalairdate ne '0000-00-00' ? $originalairdate : $recordedairdate;

#####
# Query thetvdb.com for program information
#####

if ( $subtitle ne "" ) {
    print "Beginning thetvdb.com lookup...\n";
    @T = parse_episode_content($progname);
    $S = $T[0];
    $E = $T[1];
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


#####
# Begin cutting procedure
#####

# Some error checking to ensure that we actually have a cutlist before proceding with the system calls
if ( $cutlist_sub_str eq "" ) {
    print "There seems to be no cutlist or skiplist present for this recording. EXITING!!!\n";
    exit;
} else {
    # Remove any trailing commas from the culist string
    $cutlist_sub_str =~ s/^(.+),$//;
    $cutlist_sub_str = $1;
    print "mkvmerge timecodes: $cutlist_sub_str\n" if ( $debug >= 1 );
    print "\tctr: $ctr\n\tvidstart: $vidstart\n" if ( $debug > 1 );
}

if ( !$dryrun ) {
    # First we need to run the MPEG-TS file through ffmpeg to mux it into a Matroska container
    #  my $ffmpeg_string = "ffmpeg -y -i $filename -vcodec copy -acodec copy -f matroska $temp_dir/temp_$now.mkv";
    #  print "Calling ffmpeg to repackage video file into Matroska (mkv) container.\n" if ( $debug >= 1 );
    #  print "ffmpeg call: $ffmpeg_string\n" if ( $debug > 1 );
    #  system $ffmpeg_string;

    # Now we can call mkvmerge to split the file
    #  my $split_string = "mkvmerge -o $temp_dir/split_$now.mkv --split timecodes:$cutlist_sub_str $temp_dir/temp_$now.mkv";
    ##### mkvmerge >= 5.0.0 can handle MPEG-TS files.  Should I remove the ffmpeg conversion above absolutely, or do some kind
    ##### of version check on mkvmerge, conditionally converting if the version is too old?
    my $split_string = "mkvmerge -o $temp_dir/split_$now.mkv --split timecodes:$cutlist_sub_str $filename";
    print "Calling mkvmerge to split video file.\n" if ( $debug >= 1 );
    print "mkvmerge split call: $split_string\n" if ( $debug > 1 );
    system $split_string;

    # build the merge string
    if ( $vidstart == 1 ) {
        $merge_string = "$temp_dir/split_$now-001.mkv";
    } else {
        $merge_string = "$temp_dir/split_$now-002.mkv";
    }
    for ( $n=$vidstart+2; $n<=$ctr; $n+=2 ) {
        print "n: $n\n" if ( $debug > 1 );
        $merge_string = $merge_string . " +$temp_dir/split_$now-" . sprintf("%03d",$n) . ".mkv";
    }
    print "Calling mkvmerge to re-join the cut video files.\n" if ( $debug >= 1 );
    print "mkvmerge merge string: $merge_string\n" if ( $debug > 1 );
    # Now merge the proper files
    system "mkvmerge -o $output_dir/\"$outfile\".mkv $merge_string";

    # cleanup
    cleanup_temp();
}

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

            $debug > 1 ? print "s1: '$s1'. s2: '$s2'\n" : 0;

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
            #Now, I want to soften it a bit
            #So, i'm taking the distance between the strings, but not the added letters.
            my $string_length_diff = abs($len1 - $len2);
            return abs($lev_result - $string_length_diff);
        }

sub search_the_tv_db_for_series
        {
            my $series = $_[0];
            my @bad_series_array = $_[1];
            $debug >= 1 ? print "Searching THE-TV-DB for series '$series'\n" : 0;
            my $series_for_url = $series;
            my $scontent = get_http_response("http://".$THETVDB."/api/GetSeries.php?seriesname=$series_for_url");
            my $series_id = "";
            my $poster = "";
            my $plot = "";
            my $tvdb_series_name = "";
            my $while_ctr = 0;

            my $best_similarity = 1000000;
            #? marks the regexp as ungreedy (don't look for the longest, look for the first - which is actually IS a greedy algorithm...)
            #"gi" at the end makes it recursive
            #while ($scontent =~ m/<seriesid>(.+?)<\/seriesid>.*?<seriesname>(.+?)<\/seriesname>.*?<banner>(.+?)<\/banner>.*?<overview>(.+?)<\/overview>/gi)
            while ($scontent =~ m/<series>.*?<seriesid>(.+?)<\/seriesid>.*?<seriesname>(.+?)<\/seriesname>(.+?)<\/series>/gi) {
                print "Loop: $while_ctr\n" if ( $debug > 1 );
                my $temp_series_id = $1;
                my $temp_series_name = $2;
                my $current_similarity = levenshtein($series, $temp_series_name);
                print "++++++++++++++++++++++++++++++++++++++++++\n" if ( $debug > 1 );
                print "Best similarity: $best_similarity Current: $current_similarity\n" if ( $debug > 1 );
                if ( ($current_similarity < $best_similarity) and !(exists {map { $_ => 1 } @bad_series_array}->{$temp_series_id}) ) {
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
            my @bad_series_array;
            my @series_search_resp = search_the_tv_db_for_series($series_name,@bad_series_array);
            print Dumper(@series_search_resp) if ( $debug > 1 );
            my $series_id = $series_search_resp[0];
            my $series_resp_count = $series_search_resp[1];
            my $content = get_http_response("http://".$THETVDB."/api/GetEpisodeByAirDate.php?apikey=$apikey&seriesid=$series_id&airdate=$airdate");
            my @SEC = parse_episode_season_numbers($content);
            my $episode_number = $SEC[1];
            my $season_number = $SEC[0];

            # Now we need to test for empty responses, which would likely indicate that the wrong series was chosen
            while ( ( length($season_number) == 0 or length($episode_number) == 0 ) and $series_resp_count > 1 and $series_ctr < $series_resp_count ) {
                print "No season/episode number match.  There were other series found, trying the others...\n";
                $series_ctr++;
                push(@bad_series_array,$series_id);
                @series_search_resp = search_the_tv_db_for_series($series_name,@bad_series_array);
                $series_id = $series_search_resp[0];
                $series_resp_count = $series_search_resp[1];
                $content = get_http_response("http://".$THETVDB."/api/GetEpisodeByAirDate.php?apikey=$apikey&seriesid=$series_id&airdate=$airdate");
                @SEC = parse_episode_season_numbers($content);
                $episode_number = $SEC[1];
                $season_number = $SEC[0];
            }
            return ($season_number, $episode_number);
        }
