#PY  <- Needed to identify//

app=Avidemux()

#** Video **
# 01 videos source 
APPLOAD
#04 segments
app.clearSegments()
APPADDSEGMENT
#** Postproc **
app.setPostProc(3,3,0)
#** Filters **
#** Video Codec conf **
app.videoCodec("copy")
#** Audio **
app.audioReset()
app.audioCodec("copy",0)
#** Container **
app.setContainer("AVI")

#End of script
