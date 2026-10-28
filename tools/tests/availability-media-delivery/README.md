# QtMultimedia delivery evidence

This fixture runs the shipping C++ observer with a real QtMultimedia decoder and
a loopback-only HTTP MP4 source. It does not use cameras, station credentials,
application settings or production ingestion.

Generate a two-second H.264 test clip with the approved LGPL FFmpeg build:

```powershell
ffmpeg -hide_banner -nostdin -loglevel error -f lavfi -i testsrc=size=320x180:rate=10 -t 2 -vf format=yuv420p -c:v libopenh264 -b:v 600k -an -movflags +faststart C:/wt/availability-media-clip.mp4
```

In an MSVC developer shell:

```powershell
cmake -S tools/tests/availability-media-delivery -B C:/wt/availability-media-test -G Ninja -DCMAKE_PREFIX_PATH=C:/wt/Qt/6.12.0/msvc2022_64 -DCMAKE_BUILD_TYPE=Release
cmake --build C:/wt/availability-media-test --clean-first --parallel 2
$env:PATH = "C:/wt/Qt/6.12.0/msvc2022_64/bin;$env:SystemRoot/System32;$env:SystemRoot"
$env:QT_PLUGIN_PATH = 'C:/wt/Qt/6.12.0/msvc2022_64/plugins'
$env:QT_QPA_PLATFORM = 'offscreen'
$env:QT_MEDIA_BACKEND = 'ffmpeg'
$env:QT_FFMPEG_DECODING_HW_DEVICE_TYPES = ','
& C:/wt/availability-media-test/availability-media-delivery.exe C:/wt/availability-media-clip.mp4 > C:/wt/availability-media-result.json
```

The run takes about 85 seconds because it waits for the real, fixed 75-second
confirmation threshold. It checks actual decoded delivery, cached-frame refusal,
hidden observers, confirmed missing media, fresh recovery and metadata privacy.
The companion shipping-QML media test in `live-stream-reconnect` verifies the
QML `MediaPlayer` binding and missing-timestamp behavior.

On this Booth toolchain, CMake's detected Russian MSVC include prefix is encoded
incorrectly and Ninja can record zero header dependencies. Use a new build
directory or `--clean-first` after header changes; an incremental success alone
does not establish that callers and their class layouts match.
