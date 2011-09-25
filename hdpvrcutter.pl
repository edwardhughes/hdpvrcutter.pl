#!/usr/bin/perl -w
#
# HD-PVR Cutter
#
#	Modified by: Edward Hughes IV (edward ATSIGN edwardhughes DOT org)
#
#	Originally written by: Christopher Meredith (chmeredith {at} gmail)
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
#    
#    AVIDemux 2.4 SVN revision 4445 or later (current 10/7/08)
#    Working MythTV setup (To steal the cutlist from)
#    MKVtoolnix (to fix indexing and drop into an MKV)
#
# Basic user job setup is:
#
#    hdpvrcutter %TITLE% ---- %SUBTITLE% 
#

### Version 0.4 - 2011/06/19
#   - Added frame rate detection through use of ffmpeg system call
#   - Added additional error handling and fallback to commercial skip-list if no cutlist is found

### Version 0.3 - 2011/03/16
#   - Removed dependency on mythcommflag patch.
#   - Use perl DBI interface for MySQL queries
#   - Hack used to properly parse input arguments
 
### Version 0.2 - 5/30/09
#   - Strip apostrophes when querying TVDB
 
### VERSION 0.1
#   - Initial release
 
use LWP::UserAgent;
use DBI;
use File::Copy;
use POSIX;
use Getopt::Long;

# Debugging modules
use Data::Dumper;

## Set these before using!
 
# $recordings_dir = '/mnt/media/mythtv/recordings/';
# $temp_dir = '/mnt/media/temp/';
# $output_dir = '/mnt/media/output';
#  
# $mysql_host = 'localhost';
# $mysql_db = 'mythconverg';
# $mysql_user = 'mythtv';
# $mysql_password = 'mythtvIV';
 
################################################################################
## Leave everything below this line alone unless you know what you are doing!
################################################################################

## Process command line arguments

# Delcare variables with default values
my $verbose = '';
my $debug = '';
my $dryrun = 0;
my $direct_db_cutlist = '';
my $title = '';
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
	    'direct-db-cutlist' => \$direct_db_cutlist,
	    'title=s' => \$title,
	    'subtitle=s' => \$subtitle,
	    'host=s' => \$mysql_host,
	    'dbname=s' => \$mysql_db,
	    'user=s' => \$mysql_user,
	    'passwd=s' => \$mysql_password,
	    'recordings=s' => \$recordings_dir,
	    'tempdir=s' => \$temp_dir,
	    'dest=s' => \$output_dir,
	    'help|?' => \$help) );

sub usage
{
  print "Unknown option: @_\n" if ( @_ );
  print "usage: hdpvrcutter.pl --passwd=PASSWORD --recordings=RECORDINGS_DIR --tempdir=TEMPORARY_DIR --dest=DESTINATION_DIR --title=TITLE --subtitle=SUBTITLE [--verbose] [--debug] [--dryrun] [--direct-db-cutlist] [--host=HOSTNAME] [--dbname=DBNAME] [--user=USER] [--help|-?]\n";
  exit;
}

# Checks and error messages for required flags
!$mysql_password ? print "Must supply the password for the MySQL MythTV database [--passwd=PASSWORD] .\n" : 0;
!$recordings_dir ? print "Must supply the full path to the MythTV recordings directory [--recordings=RECORDINGS_DIR].\n" : 0;
!$temp_dir ? print "Must supply the full path the the temporary working directory [--tempdir=TEMPORARY_DIR].\n" : 0;
!$output_dir ? print "Must supply the full the path the to output destination directory [--dest=DESTINATION_DIR].\n" : 0;
!$title ? print "How can you export a show without a title?  [--title=TITLE]\n" : 0;
!$subtitle ? print "You need a subtitle to specify the exact show to export. [--subtitle=SUBTITLE]\n" : 0;

# Exit if not all of the required parameters are supplied
if ( !$mysql_password or !$recordings_dir or !$temp_dir or !$output_dir or !$title or !$subtitle ) {
  exit;
}

# Let's print some feedback about the supplied arguments
print "Here's what I understand we'll be doing:\n";
print "I'll be accessing the '$mysql_db' database on the host '$mysql_host' as the user '$mysql_user' (I'm not going to show you the password)\n";
print "I'll then export the recording: $title - $subtitle\n";
$direct_db_cutlist ? print "\n***** I will be accessing the database directly to obtain the cutlist, instead of calling mythcommflag.  THIS IS EXPERIMENTAL! *****\n\n" : 0;
$dryrun ? print "***** DRY RUN.  WILL NOT PRODUCE ANY OUTPUT FILES. *****\n\n" : 0;
if ( $debug ) {
  $debug = 2;
} else {
  $debug = 0;
}
if ( $verbose ) {
  print "Verbose mode\n";
  $debug = 1;
}


## Proceed with the export
# Trim whitespace from title(s)
$progname = $title;
$progname =~ s/^\s+//; # leading
$progname =~ s/\s+$//; # trailing
$subtitle =~ s/^\s+//; # leading
$subtitle =~ s/\s+$//; # trailing

# Add a trailing forward slash to the directories to be safe
$recordings_dir .= '/';
$temp_dir .= '/';
$output_dir .= '/';
 
$apikey = "259FD33BA7C03A14";
$THETVDB = "www.thetvdb.com";
$global_user_agent = LWP::UserAgent->new;
#$progname = "$ARGV[0]";
print "Program Name: $progname\n";
#$subtitle = $ARGV[1];
print "Subtitle: $subtitle\n";
$progname =~ s/\'/\\'/g; # SQL doesn't like apostrophes
$subtitle =~ s /\'/\\'/g;


# Let's use perl's DBI module to access the database
# Connect to MySQL database
$dbh = DBI->connect("DBI:mysql:database=" . $mysql_db . ";host=" . $mysql_host, $mysql_user, $mysql_password);
# prepare the query (this is bad - dynamic query generation - but since this is local and not a web app we'll allow it)
$query_str = "SELECT chanid,starttime,endtime,originalairdate FROM recorded WHERE title LIKE '$progname' AND subtitle LIKE '$subtitle'";
$debug > 1 ? print "Query: $query_str\n" : 0;
$query = $dbh->prepare($query_str);
# Retrieve program information
# execute query ->
$query->execute();
# fetch response
@infoparts = $query->fetchrow_array();
# release the query
$query->finish;

# Let's make sure that the response is not empty
if ( !@infoparts or length($infoparts[0]) == 0 or length($infoparts[1]) == 0 ) {
	print "Empty response from database...exiting!\n";
	exit 1;  # We'll exit with a non-zero exit code.  The '1' has no significance at this time.
}
 
$progname =~ s/\\'//g; # TVDB doesn't like apostrophes either
$subtitle =~ s/\\'//g;

#print "Infoparts: " . Dumper(@infoparts) . "\n";
 
#@infoparts = split(/\t/, $fileinfo);

# put the channel id and starttime into more intuitive variables
$chanid = $infoparts[0];
$starttime = $infoparts[1];

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
#chop $originalairdate;
$date1 = $infoparts[1];
#print "$date1";
@date2=split /\s+/, "$date1";
$date3 = $date2[0];
 
#print "@date2[0] \n";
#print "$date3\n";


##### before we destroy the statement handle, let's use MySQL to query the cut-list/skip-list
#$query_str = "SELECT cutlist FROM recorded WHERE chanid=$chanid AND starttime=$starttime";
#$query = $dbh->prepare($query_str);
#$query->execute || Die "Unable to query recorded table\n";
#$querydata = $query->fetchrow_hashref;


##### now destroy the MySQL handle
# destroy the statement handle
$query->finish();
# disconnect from the database
$dbh->disconnect();


if ( length($originalairdate) > 0 and length($date3) > 0 ) {
	$debug >= 1 ? print "Original airdate: $originalairdate\n" : 0;
	$debug >= 1 ? print "Recorded Date: $date3\n" : 0;
} else {
	print "Zero length query strings for thetvdb.com...exiting!\n";
	exit 1; # Same here...the '1' indicates exit with error without specifics
}
#exit;

if ($originalairdate ne '0000-00-00')
{
   $airdate = $originalairdate;
}
else
{
   $airdate = "$date3";
}
 
sub get_http_response_lwp
{
        my $request_url = $_[0];
        $debug >= 1 ? print "About to call GET HTTP url: '$request_url'\n" : 0;
        my $req = HTTP::Request->new(GET => $request_url);
 
        # Pass request to the user agent and get a response back
        my $res = $global_user_agent->request($req);
 
        # Check the outcome of the response
        if ($res->is_success)
        {
                my $response_content = $res->content;
                $debug >= 1 ? print "Got HTTP response.\n" : 0;
		$debug > 1 ? print "$response_content\n" : 0;
                return $response_content;
        }
        else
        {
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
 
    foreach my $i (@list)
    {
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
    for (my $i = 0; $i <= $len1; ++$i)
    {
        for (my $j = 0; $j <= $len2; ++$j)
        {
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
 
    for (my $i = 1; $i <= $len1; ++$i)
    {
        for (my $j = 1; $j <= $len2; ++$j)
        {
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
        while ($scontent =~ m/<series>.*?<seriesid>(.+?)<\/seriesid>.*?<seriesname>(.+?)<\/seriesname>(.+?)<\/series>/gi)
        {
		$debug > 1 ? print "Loop: $while_ctr\n" : 0;
                my $temp_series_id = $1;
                my $temp_series_name = $2;
                my $current_similarity = levenshtein($series, $temp_series_name);
                $debug > 1 ? print "++++++++++++++++++++++++++++++++++++++++++\n" : 0;
                $debug > 1 ? print "Best similarity: $best_similarity Current: $current_similarity\n" : 0;
                if ( ($current_similarity < $best_similarity) and !(exists {map { $_ => 1 } @bad_series_array}->{$temp_series_id}) )
                {
                        if ($series_id eq "")
                        {
                                $debug >= 1 ? print "Found a possible match for '$series' as '$temp_series_name' (ID $temp_series_id)\n" : 0;
                        }
                        else
                        {
                                $debug >= 1 ? print "Found a better possible match for '$series' as '$temp_series_name' (ID $temp_series_id)\n" : 0;
                        }
                        $best_similarity = $current_similarity;
                        $series_id = $1;
                        $tvdb_series_name = $2;
                        my $rest_of_the_data = $3;
                        if ($rest_of_the_data =~ m/<banner>(.+?)<\/banner>/i){$poster = "http://".$THETVDB."/banners/".$1;}
                        else {$poster = "";}
 
                        if ($rest_of_the_data =~ m/<overview>(.+?)<\/overview>/i){$plot = $1;}
                        else {$plot = "";}
                }
                $debug > 1 ? print "++++++++++++++++++++++++++++++++++++++++++\n": 0;
		$while_ctr++;
        }
        if ((length $series_id) > 0)
        {
                print "Found ID '$series_id' for series '$tvdb_series_name' at THE-TV-DB.\n";
		# return both the selected series ID and the count of series in the response
                return ($series_id,$while_ctr);
        }
        else
        {
                print "Can not locate series '$series' in THE-TV-DB.\n";
                return ("", "", "", "", "");
        }
}

sub parse_episode_season_numbers
{
	my $content = $_[0];
	my $episode_number = "";
	my $season_number = "";
	if ($content =~ m/<EpisodeNumber>(.+)<\/EpisodeNumber>/i)
	{
		$episode_number = sprintf( "%02d", $1 );
	}
	if ($content =~ m/<SeasonNumber>(.+)<\/SeasonNumber>/i)
	{
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
	$debug > 1 ? print Dumper(@series_search_resp) : 0;
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
 
@T = parse_episode_content($progname);
$S = $T[0];
$E = $T[1];
if ( length($S) == 0 or length($E) == 0 ) {
	print "Empty season or episode number returned from thetvdb.com...exiting!\n";
	exit 1;
}
print "\tSeason Number: $S\n";
print "\tEpisode Number: $E\n";
 
$outfile = $progname;
if ($subtitle ne "")
{
#    $outfile = "$progname.S${S}E${E}.$subtitle";
    $outfile = "$progname.S${S}E${E}";
}

#####
# Begin cutting procedure
#####

# Original exec line used a patched version of mythcommflag - instead, I have implemented some simple Javascript in the avidemux project file
#exec "mythcommflag --getcutlist-avidemux -f \"$filename\" --outputfile \"$recordings_dir\"/temp.proj;
system "mythcommflag --getcutlist -f $filename --very-quiet > $temp_dir/temp.proj";

# Now we need to read the cutlist from the file
open FILE, "$temp_dir/temp.proj" or die $!;
$cutlist_line = <FILE>;
close(FILE);
# Make sure there is a cutlist or exit with error message
if ( $cutlist_line =~ m/Cutlist:\s*$/i ) {
	print "No cutlist present for selected recording...trying commercial skip list...\n";
	# now we check for a commercial skip list...
	system "mythcommflag --getskiplist -f $filename --very-quiet > $temp_dir/temp.proj";
	# read file, again
	open FILE, "$temp_dir/temp.proj" or die $!;
	$cutlist_line = <FILE>;
	close(FILE);
	if ( $cutlist_line =~ m/Commercial Skip List:\w*$/i ) {
		print "No commercial skip list present either!  Exiting!!\n\n";
		exit 10;
	}
	print "Using commercial skip list.  Results may vary...\n";
}	
# Now extract the cutlist array
$cutlist_line =~ s/[^-0-9,]//g;
#$cutlist_line = '"' . $cutlist_line . '"';
#$cutlist_line =~ s/,/","/g;
print "Cutlist: $cutlist_line\n";
# move the addSegment line creation to here...not the tinypy script
@cutlist_array = split(',', $cutlist_line);
$cutlist_segments = scalar(@cutlist_array);
print "There are $cutlist_segments video segments to be spliced.\n";
$cutlist_sub_str = "";
$fpsmult = 29.97;
$ctr=0;
for ( $n=0; $n < $cutlist_segments; $n++ ) {
	$cutlist_array[$n] =~ m/(\d+)-(\d+)/;
	$comm_start = $1 / $fpsmult;
	$comm_end = $2 / $fpsmult;
	$cutlist_sub_str = $cutlist_sub_str . floor($comm_start/3600) . ":" . floor($comm_start/60) . ":" . $comm_start % 60 . ",";
	$cutlist_sub_str = $cutlist_sub_str . floor($comm_end/3600) . ":" . floor($comm_end/60) . ":" . $comm_end % 60 . ",";
	if ( $n == 1 ) {
		$comm_start == 0 ? $vidstart = 2 : $vidstart = 1;
	}
	$ctr+=2;
}
$ctr++;
print "$cutlist_sub_str\nctr: $ctr\nvidstart: $vidstart\n";

if ( !$dryrun ) {
	# First we need to run the MPEG-TS file through ffmpeg to mux it into a Matroska container
	system "ffmpeg -y -i $filename -vcodec copy -acodec copy -f matroska $temp_dir/temp.mkv";

	# Now we can call mkvmerge to split the file
	system "mkvmerge -o $temp_dir/split.mkv --split timecodes:$cutlist_sub_str $temp_dir/temp.mkv";

	# build the merge string
	if ( $vidstart == 1 ) {
		$merge_string = "$temp_dir/split-001.mkv";
	} else {
		$merge_string = "$temp_dir/split-002.mkv";
	}
	for ( $n=$vidstart+2; $n<=$ctr; $n+=2 ) {
		print "n: $n\n";
		$merge_string = $merge_string . " +$temp_dir/split-" . sprintf("%03d",$n) . ".mkv";	
	}
	print "merge string: $merge_string\n";
	# Now merge the proper files
	system "mkvmerge -o $output_dir/\"$outfile\".mkv $merge_string";

	# Do a little cleanup.
	system "rm $temp_dir/*";
}
