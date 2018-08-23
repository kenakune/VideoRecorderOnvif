perl script to record video from camera that support onvif protocol

The idea is to have some old notebook or raspberry PI with usb storage and run ffmpeg to record de video from IP camera.

Then the camera can save the video in the local memory card if available and have a backup of the video somewhere else.

It use ffmpeg to record the video.

It use oher perl modules that can be installed like:
perl -MCPAN -e shell
install Config::IniFiles
install Net::Ping
install Log::Log4perl

t should run from contab like:
*/10 * * * * $HOME/perl/saveVideo.pl >> ~/logs/saveVideo.log 2>&1

It record video every 10 min using RTSP to connect to camera.

It also generate a compacted version to make visible from a web browser. This video will have 640x480 resolution.

Every hour the 6 generated video is compacted to generate a single video having 3 min.

It use mmstp to send notification when error happens.
