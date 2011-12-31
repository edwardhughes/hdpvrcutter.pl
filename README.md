# hdpvrcutter.pl

Maintained by: Edward Hughes IV <edward ATSIGN edwardhughes DOT org>

Project spawned from reference at: http://monopedilos.com/dokuwiki/doku.php?id=hdpvrcutter.pl

## Purpose

This script is intended to be used to export recordings from MythTV, specifically those created by the Hauppauge HD-PVR, and/or are in H.264 format.  The script provides the best results of the many options that were tried up to the time of its discovery/creation, mainly in-sync audio/video.  While the results are great in that respect, the cutting is only reliably performed on keyframes.  If the cut-point specified is not explicitly on a keyframe, mkvmerge seems to choose the nearest keyframe to the specified position.  It seems that herein lies the difficulty working with H.264 recordings and with that said, the author still finds this to be the most effective method for removing unwanted portions of a recording made by MythTV.

## Execution

Several parameters are required at run-time.  Those required are --dest, the export destination directory, --recordings, the mythtv recordings directory, --tempdir, a temporary working directory, --passwd, the mythtv database password, and --title, the title of the recording to be exported.  If you want to get extra feedback in the MythTV job queue, you should also supply --jobid=%JOBID% in the user job setup.  Depending on your system configuration, the script might also require the hostname where the mythtv database resides, the database name, the database user, and possibly a subtitle (this will be necessary if exporting television episodes, not necessary for movies).  Run 'hdpvrcutter --help' for a complete list of options.
