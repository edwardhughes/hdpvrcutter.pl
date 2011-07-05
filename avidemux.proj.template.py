//PY  <- Needed to identify//

app = Avidemux()

CUTLIST

//** Video **
// 01 videos source 
APPLOAD
//04 segments
app.clearSegments()
APPADDSEGMENT
//** Postproc **
app.setPostProc(3,3,0)
//app.video.fps1000 = FPS1000
//** Filters **
//** Video Codec conf **
app.videoCodec("copy")
//** Audio **
app.audioReset()
app.audioCodec("copy",0)
app.setContainer("AVI")

//End of script
