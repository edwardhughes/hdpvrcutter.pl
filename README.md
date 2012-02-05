# hdpvrcutter.pl

Maintained by: Edward Hughes IV <edward ATSIGN edwardhughes DOT org>

Project spawned from reference at: http://monopedilos.com/dokuwiki/doku.php?id=hdpvrcutter.pl

## Purpose

This script is intended to be used to export recordings from MythTV,
specifically those created by the Hauppauge HD-PVR, and/or are in
H.264 format.  The script provides the best results of the many
options that were tried up to the time of its discovery/creation,
mainly in-sync audio/video.  While the results are great in that
respect, the cutting is only reliably performed on keyframes.  If the
cut-point specified is not explicitly on a keyframe, mkvmerge seems to
choose the nearest keyframe to the specified position.  It seems that
herein lies the difficulty working with H.264 recordings and with that
said, the author still finds this to be the most effective method for
removing unwanted portions of a recording made by MythTV.

Update 2012/02/05: Much more usage and an update to the latest
version of mkvmerge (v5.2.1) has shown promising results with
non-keyframe cut-points.  Additional testing with the 'nomyth' branch,
which is aimed at allowing the user to supply the cutlist to edit
non-MythTV stored videos, has worked quite well with arbitrarily
specified cut-points.  As usual, YMMV.

## Execution

Several parameters are required at run-time.  The minimum are:

    --dest, the export destination directory
    --recordings, the mythtv recordings directory
    --tempdir, a temporary working directory
    --title or --basename, to select the recording to be     edited/exported
    --cutlist or --passwd, to provide the cutlist

If you are using the script as a MythTV user job, you will need
the database password for access. There is a --jobid option to provide additional feedback in the MythTV job queue. Depending on your system configuration, the script might also require the hostname where the mythtv database resides, the database name, the database user, and possibly a subtitle (this will be necessary if exporting television episodes, not necessary for movies).  Run 'hdpvrcutter --help' for a complete list of options.

## MythTV User Job Setup

To run the script from within MythTV you must setup a user job.  See the MythTV wiki for help on the method(s) for doing so.  The command you will need to enter will need to be something like this:

/path/to/hdpvrcutter.pl --passwd=myMythTVpassword --jobid=%JOBID% --title="%TITLE%" --subtitle="%SUBTITLE%" --tempdir=/path/to/temp --dest=/path/to/dest/ --recordings=/path/to/mythtv/recordings

