#PY  <- Needed to identify//

app=Avidemux()

#** Video **
# 01 videos source 
APPLOAD
#04 segments
app.clearSegments()
APPADDSEGMENT
#** Postproc **
#app.setPostProc(3,3,0)
#** Filters **
#** Video Codec conf **
app.videoCodec("Copy")
#** Audio **
app.audioReset()
app.audioCodec("Copy",0)
#** Container **
app.setContainer("MKV")

#End of script
