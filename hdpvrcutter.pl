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
use Data::Dumper;
 
## Set these before using!
 
$recordings_dir = '/mnt/media/mythtv/recordings/';
$temp_dir = '/mnt/media/temp/';
$output_dir = '/mnt/r2d2/MythTV_Exports';
 
$mysql_host = 'localhost';
$mysql_db = 'mythconverg';
$mysql_user = 'mythtv';
$mysql_password = 'mythtvIV';
 
## Leave everything below this line alone unless you know what you are doing!

print Dumper(@ARGV) . "\n";

@pname = "";
@subt = "";
$subtFlag = 0;
INPUTARG:
foreach (@ARGV) {
	print $_ . "\n";
	if ( $_ eq '----' ) {
		$subtFlag = 1;
		print "Changing to subtitle...\n";
		next INPUTARG;
	}
	if ( !$subtFlag ) {
		push(@pname,$_);
	} else {
		push(@subt,$_);
	}
}

$progname = join(" ",@pname);
$subtitle = join(" ",@subt);
# Trim whitespace
$progname =~ s/^\s+//;
$progname =~ s/\s+$//;
$subtitle =~ s/^\s+//;
$subtitle =~ s/\s+$//;
 
$apikey = "259FD33BA7C03A14";
$THETVDB = "www.thetvdb.com";
$global_user_agent = LWP::UserAgent->new;
#$progname = "$ARGV[0]";
print "Program Name: $progname\n";
#$subtitle = $ARGV[1];
print "Subtitle: $subtitle\n";
$progname =~ s/\'/\\'/g; # SQL doesn't like apostrophes
$subtitle =~ s /\'/\\'/g;

# Old MySQL data retrieval method
#$fileinfo = `mysql -h $mysql_host -D $mysql_db -u $mysql_user --password=$mysql_password -r -s --skip-column-names -e \"select chanid,starttime,endtime,originalairdate from recorded where title like \'$progname\' and subtitle like \'$subtitle\'\" | head -n 1`;

# Let's use perl's DBI module to access the database
# Connect to MySQL database
$dbh = DBI->connect("DBI:mysql:database=" . $mysql_db . ";host=" . $mysql_host, $mysql_user, $mysql_password);
# prepare the query (this is bad - dynamic query generation - but since this is local and not a web app we'll allow it)
$query_str = "SELECT chanid,starttime,endtime,originalairdate FROM recorded WHERE title LIKE '$progname' AND subtitle LIKE '$subtitle'";
print "Query: $query_str\n";
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
	print "Original airdate: $originalairdate\n";
	print "Recorded Date: $date3\n";
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
 
#print "Airdate: $airdate\n";
 
sub get_http_response_lwp
{
        my $request_url = $_[0];
        print "About to call GET HTTP url: '$request_url'\n";
        my $req = HTTP::Request->new(GET => $request_url);
 
        # Pass request to the user agent and get a response back
        my $res = $global_user_agent->request($req);
 
        # Check the outcome of the response
        if ($res->is_success)
        {
                my $response_content = $res->content;
                #print "Got HTTP response:\n".$response_content."\n";
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
 
	#print "s1: '$s1'. s2: '$s2'\n";
 
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
        print "Searching THE-TV-DB for series '$series'\n";
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
		print "Loop: $while_ctr\n";
                my $temp_series_id = $1;
                my $temp_series_name = $2;
                my $current_similarity = levenshtein($series, $temp_series_name);
                #print "++++++++++++++++++++++++++++++++++++++++++\n";
                #print "Best similarity: $best_similarity Current: $current_similarity\n";
                if ( ($current_similarity < $best_similarity) and !(exists {map { $_ => 1 } @bad_series_array}->{$temp_series_id}) )
                {
                        if ($series_id eq "")
                        {
                                print "Found a possible match for '$series' as '$temp_series_name' (ID $temp_series_id)\n";
                        }
                        else
                        {
                                print "Found a better possible match for '$series' as '$temp_series_name' (ID $temp_series_id)\n";
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
                #print "++++++++++++++++++++++++++++++++++++++++++\n";
		$while_ctr++;
        }
        if ((length $series_id) > 0)
        {
                print "Found ID '$series_id' for series '$series' at THE-TV-DB.\n";
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
	print Dumper(@series_search_resp);
	print "\n";
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
print "Season Number: $S\n";
print "Episode Number: $E\n";
 
$outfile = $progname;
if ($subtitle ne "")
{
#    $outfile = "$progname.S${S}E${E}.$subtitle";
    $outfile = "$progname.S${S}E${E}";
}

#####
# Start to create the avidemux project file - we will use a template
#####
# First, copy the template to the temp directory
copy("/usr/local/share/mythtv/avidemux.proj.template.py","$temp_dir/avidemux.proj");
$temp_filename = $filename;
$temp_filename =~ s/\//\\\//g; # use some regexp to clean the file path by replacing all forward slashes with ???
#print $temp_filename;

#####
# Begin placeholder substitution
#####
# Add the correct frame rate (fps*1000) by replacing the FPS1000 placeholder
### This might not be necessary with avidemux3 (Avidemux 2.6) ###
# (use an ffmpeg call to output the fps of the file in question to another file for reading...this is stupid, I know)
#print "\ntemp_filename: $temp_filename\n";
#system "ffmpeg -i $temp_filename -y /dev/null 2>&1 | grep \"Stream #0.0\" | awk '{print $12}' > $temp_dir/fps.out";
system "ffmpeg -i $temp_filename -y /dev/null 2>&1 | grep \"Stream #0.0\" > $temp_dir/fps.out";
open FILE, "$temp_dir/fps.out" or die $!;
$fps_line = <FILE>;
close(FILE);
# make sure the fps string isn't empty, otherwise exit
if ( length($fps_line) == 0 ) {
	exit 2;
}
#print "FPS line: $fps_line\n";
# now a little regexp to extract the fps...
# (using positive lookahead to select the value before the 'fps' identifier)
if ( $fps_line =~ m/(\d{2}\.\d{1,2})(?=\stbr)/ ) {
	$fps_val = $1;
} else {
	print "Error while trying to determine video FPS.\n";
	exit 10;
}
print "\nDetected FPS: $fps_val\n";
# at this point we can calculate the fps*1000 value...
$fps1000 = $fps_val * 1000;
print "FPS1000: $fps1000\n";
$fps1000 > 50000 ? $fpsmult = 2 : $fpsmult = 1;
$fpsmult = 1;
# and, finally the FPS1000 substitution...
#system "sed -i 's/FPS1000/$fps1000/' $temp_dir/avidemux.proj";
 
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
$segment_start = 0;
for ( $n=0; $n < $cutlist_segments; $n++ ) {
	$cutlist_array[$n] =~ m/(\d+)-(\d+)/;
	$comm_start = $1;
	$comm_end = $2;
	$cutlist_sub_str = $cutlist_sub_str . "app.addSegment(0," . $segment_start*$fpsmult . "," . ($comm_start-$segment_start)*$fpsmult .  ")\\n";
	$segment_start = $comm_end;
	if ($ n == $cutlist_segments ) {
		$cutlist_sub_str = $cutlist_sub_str . "app.addSegment(0," . $segment_start*$fpsmult . ",1000000)\\n";	
	}
}
system "sed -i 's/APPADDSEGMENT/$cutlist_sub_str/' $temp_dir/avidemux.proj";

# now replace the APPLOAD placeholder with the appropriate app.load() string
system "sed -i 's/APPLOAD/app.loadVideo\(\"$temp_filename\"\)/' $temp_dir/avidemux.proj";
#exit 99;

# Finally, the call to avidemux
#system "nice -n 9 avidemux2_cli --force-smart --nogui --run \"$temp_dir\"/avidemux.proj --save \"$temp_dir\"/\"$outfile\.avi\" --quit 2> /dev/null";
system "nice -n 9 avidemux3_cli --nogui --runpy \"$temp_dir\"/avidemux.proj --save \"$temp_dir\"/\"$outfile\.ts\" --quit 2> /dev/null";
 
# Move the AVI file into a Matroska.  
# Failure to do this will result in broken seeking.
system "mkvmerge -o  \"$output_dir\"/\"$outfile\.mkv\"  \"$temp_dir\"/\"$outfile\.avi\"";
 
# Do a little cleanup.
#system "rm $temp_dir/*";

