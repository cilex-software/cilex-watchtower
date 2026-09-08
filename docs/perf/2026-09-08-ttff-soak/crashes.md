# Crash evidence — wall (mosaic) runs, 2026-09-08

Extracted from the kept run logs (full logs on the dev box, not committed: ~0.5 MB each).
Per crashed run: the 12 log lines before the fatal handler, the handler line, and the backtrace.


## baseline-logs/c1-wall.log — killed by signal 6 (Aborted)

```
[mpegts @ 0x7fed9c6ef940] Packet corrupt (stream = 0, dts = 532500).
[hls @ 0x7fed9c3c8ec0] Packet corrupt (stream = 0, dts = 525000).
[http @ 0x7fed9c6f8600] Stream ends prematurely at 1217676, should be 18446744073709551615
[hls @ 0x7fed9c3c8ec0] Opening 'http://127.0.0.1:45933/review/mosaic-sessions/89d5f9b7-a170-4e9a-9ab0-d46bb4ec54ca/seg/42.ts' for reading
2026-09-08 14:34:43.509 vaSyncSurface failed: 1 - not importing the surface
2026-09-08 14:34:43.510     failed to get textures for frame; format: 44
[AVHWFramesContext @ 0x5e5cea8e9e00] Failed to sync surface 0x6: 1 (operation failed).
2026-09-08 14:34:43.510 Error transferring the data to system memory: -5
2026-09-08 14:34:43.510 Cannot map a video frame in ReadOnly mode!
2026-09-08 14:34:43.601 [WT-MEM] rss=493MB live_pipelines=0 parked=0 frames=69
free(): invalid next size (fast)

[WT-FATAL] t=1788867283s (unix; compare `date +%s`) uptime=100s — killed by signal 6 (Aborted); RSS=493 MB. SIGSEGV(11)/SIGABRT(6)/SIGBUS(7) = code crash, backtrace follows.
/home/cilex-vision/projects/cilex-watchtower/build/watchtower(+0x4da5d)[0x5e5ccbd84a5d]
/lib/x86_64-linux-gnu/libc.so.6(+0x45330)[0x7feda6e45330]
/lib/x86_64-linux-gnu/libc.so.6(pthread_kill+0x11c)[0x7feda6e9ec0c]
/lib/x86_64-linux-gnu/libc.so.6(gsignal+0x1e)[0x7feda6e4527e]
/lib/x86_64-linux-gnu/libc.so.6(abort+0xdf)[0x7feda6e288ff]
/lib/x86_64-linux-gnu/libc.so.6(+0x297b6)[0x7feda6e297b6]
/lib/x86_64-linux-gnu/libc.so.6(+0xa90d5)[0x7feda6ea90d5]
/lib/x86_64-linux-gnu/libc.so.6(+0xab4cc)[0x7feda6eab4cc]
/lib/x86_64-linux-gnu/libc.so.6(__libc_free+0x7e)[0x7feda6eadeae]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Qml.so.6(+0x2e0208)[0x7feda90e0208]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Qml.so.6(+0x2e0d83)[0x7feda90e0d83]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Qml.so.6(+0x2e16c1)[0x7feda90e16c1]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Qml.so.6(_ZN3QV414GCStateMachine10transitionEv+0x2a8)[0x7feda90dcf38]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN7QObject5eventEP6QEvent+0x265)[0x7feda77fa9d5]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN16QCoreApplication15notifyInternal2EP7QObjectP6QEvent+0x168)[0x7feda77a0468]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN23QCoreApplicationPrivate16sendPostedEventsEP7QObjectiP11QThreadData+0x41a)[0x7feda77a495a]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(+0x4d29d7)[0x7feda7ad29d7]
/lib/x86_64-linux-gnu/libglib-2.0.so.0(+0x5d585)[0x7feda80b1585]
/lib/x86_64-linux-gnu/libglib-2.0.so.0(+0xbc977)[0x7feda8110977]
/lib/x86_64-linux-gnu/libglib-2.0.so.0(g_main_context_iteration+0x33)[0x7feda80b0a23]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN20QEventDispatcherGlib13processEventsE6QFlagsIN10QEventLoop17ProcessEventsFlagEE+0x70)[0x7feda7ad1f40]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN10QEventLoop4execE6QFlagsINS_17ProcessEventsFlagEE+0x29b)[0x7feda77ace3b]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN16QCoreApplication4execEv+0x9a)[0x7feda77a857a]
/home/cilex-vision/projects/cilex-watchtower/build/watchtower(main+0x34af)[0x5e5ccbd73e0f]
/lib/x86_64-linux-gnu/libc.so.6(+0x2a1ca)[0x7feda6e2a1ca]
/lib/x86_64-linux-gnu/libc.so.6(__libc_start_main+0x8b)[0x7feda6e2a28b]
/home/cilex-vision/projects/cilex-watchtower/build/watchtower(+0x3e595)[0x5e5ccbd75595]
```

## baseline-logs/c3-wall.log — killed by signal 6 (Aborted)

```
[hls @ 0x7759f4b03880] Opening 'http://127.0.0.1:34737/review/mosaic-sessions/691a7dc8-0c11-4f1b-90ec-d394b23e689c/seg/97.ts' for reading
[mpegts @ 0x7759f4538600] Packet corrupt (stream = 0, dts = 532500).
[hls @ 0x7759f4b03880] Packet corrupt (stream = 0, dts = 525000).
[http @ 0x7759f4539240] Stream ends prematurely at 1272760, should be 18446744073709551615
[hls @ 0x7759f4b03880] Opening 'http://127.0.0.1:34737/review/mosaic-sessions/691a7dc8-0c11-4f1b-90ec-d394b23e689c/seg/98.ts' for reading
2026-09-08 14:43:19.519 vaSyncSurface failed: 1 - not importing the surface
[AVHWFramesContext @ 0x5d771fe92ec0] Failed to sync surface 0xa: 1 (operation failed).
2026-09-08 14:43:19.519 Error transferring the data to system memory: -5
2026-09-08 14:43:19.519 Cannot map a video frame in ReadOnly mode!
2026-09-08 14:43:19.600 [WT-MEM] rss=568MB live_pipelines=0 parked=0 frames=246
free(): invalid next size (fast)

[WT-FATAL] t=1788867800s (unix; compare `date +%s`) uptime=149s — killed by signal 6 (Aborted); RSS=568 MB. SIGSEGV(11)/SIGABRT(6)/SIGBUS(7) = code crash, backtrace follows.
/home/cilex-vision/projects/cilex-watchtower/build/watchtower(+0x4da5d)[0x5d76fc73da5d]
/lib/x86_64-linux-gnu/libc.so.6(+0x45330)[0x7759fd645330]
/lib/x86_64-linux-gnu/libc.so.6(pthread_kill+0x11c)[0x7759fd69ec0c]
/lib/x86_64-linux-gnu/libc.so.6(gsignal+0x1e)[0x7759fd64527e]
/lib/x86_64-linux-gnu/libc.so.6(abort+0xdf)[0x7759fd6288ff]
/lib/x86_64-linux-gnu/libc.so.6(+0x297b6)[0x7759fd6297b6]
/lib/x86_64-linux-gnu/libc.so.6(+0xa90d5)[0x7759fd6a90d5]
/lib/x86_64-linux-gnu/libc.so.6(+0xab4cc)[0x7759fd6ab4cc]
/lib/x86_64-linux-gnu/libc.so.6(__libc_free+0x7e)[0x7759fd6adeae]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Qml.so.6(+0x2e0208)[0x7759ff8e0208]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Qml.so.6(+0x2e0d83)[0x7759ff8e0d83]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Qml.so.6(+0x2e16c1)[0x7759ff8e16c1]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Qml.so.6(_ZN3QV414GCStateMachine10transitionEv+0x2a8)[0x7759ff8dcf38]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN7QObject5eventEP6QEvent+0x265)[0x7759fdffa9d5]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN16QCoreApplication15notifyInternal2EP7QObjectP6QEvent+0x168)[0x7759fdfa0468]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN23QCoreApplicationPrivate16sendPostedEventsEP7QObjectiP11QThreadData+0x41a)[0x7759fdfa495a]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(+0x4d29d7)[0x7759fe2d29d7]
/lib/x86_64-linux-gnu/libglib-2.0.so.0(+0x5d585)[0x7759fe914585]
/lib/x86_64-linux-gnu/libglib-2.0.so.0(+0xbc977)[0x7759fe973977]
/lib/x86_64-linux-gnu/libglib-2.0.so.0(g_main_context_iteration+0x33)[0x7759fe913a23]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN20QEventDispatcherGlib13processEventsE6QFlagsIN10QEventLoop17ProcessEventsFlagEE+0x70)[0x7759fe2d1f40]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN10QEventLoop4execE6QFlagsINS_17ProcessEventsFlagEE+0x29b)[0x7759fdface3b]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN16QCoreApplication4execEv+0x9a)[0x7759fdfa857a]
/home/cilex-vision/projects/cilex-watchtower/build/watchtower(main+0x34af)[0x5d76fc72ce0f]
/lib/x86_64-linux-gnu/libc.so.6(+0x2a1ca)[0x7759fd62a1ca]
/lib/x86_64-linux-gnu/libc.so.6(__libc_start_main+0x8b)[0x7759fd62a28b]
/home/cilex-vision/projects/cilex-watchtower/build/watchtower(+0x3e595)[0x5d76fc72e595]
```

## baseline-logs/c4-wall.log — killed by signal 11 (Segmentation fault)

```
[http @ 0x5563f32d0800] Stream ends prematurely at 1273324, should be 18446744073709551615
[hls @ 0x5563f53c8780] Opening 'http://127.0.0.1:42927/review/mosaic-sessions/3798f7ba-713c-4ee8-9c33-808a676ff431/seg/35.ts' for reading
[mpegts @ 0x5563f0d17bc0] Packet corrupt (stream = 0, dts = 532500).
[hls @ 0x5563f53c8780] Packet corrupt (stream = 0, dts = 525000).
[http @ 0x5563f254ea00] Stream ends prematurely at 1233468, should be 18446744073709551615
[hls @ 0x5563f53c8780] Opening 'http://127.0.0.1:42927/review/mosaic-sessions/3798f7ba-713c-4ee8-9c33-808a676ff431/seg/36.ts' for reading
(previous message repeated x1 more)
2026-09-08 14:46:19.020 vaSyncSurface failed: 1 - not importing the surface
[AVHWFramesContext @ 0x768f1d645840] Failed to sync surface 0xc: 1 (operation failed).
2026-09-08 14:46:19.020 Error transferring the data to system memory: -5
2026-09-08 14:46:19.020 Cannot map a video frame in ReadOnly mode!

[WT-FATAL] t=1788867979s (unix; compare `date +%s`) uptime=70s — killed by signal 11 (Segmentation fault); RSS=495 MB. SIGSEGV(11)/SIGABRT(6)/SIGBUS(7) = code crash, backtrace follows.
/home/cilex-vision/projects/cilex-watchtower/build/watchtower(+0x4da5d)[0x5563c43bfa5d]
/lib/x86_64-linux-gnu/libc.so.6(+0x45330)[0x768f26445330]
/lib/x86_64-linux-gnu/libc.so.6(__libc_free+0x25)[0x768f264ade55]
/lib/x86_64-linux-gnu/libgallium-25.2.8-0ubuntu0.24.04.2.so(+0x123a9be)[0x768f17a3a9be]
/lib/x86_64-linux-gnu/libgallium-25.2.8-0ubuntu0.24.04.2.so(+0x75fcb5)[0x768f16f5fcb5]
/lib/x86_64-linux-gnu/libgallium-25.2.8-0ubuntu0.24.04.2.so(+0x123c430)[0x768f17a3c430]
/lib/x86_64-linux-gnu/libgallium-25.2.8-0ubuntu0.24.04.2.so(+0x779c38)[0x768f16f79c38]
/lib/x86_64-linux-gnu/libgallium-25.2.8-0ubuntu0.24.04.2.so(+0x566091)[0x768f16d66091]
/lib/x86_64-linux-gnu/libgallium-25.2.8-0ubuntu0.24.04.2.so(+0x599e0c)[0x768f16d99e0c]
/lib/x86_64-linux-gnu/libc.so.6(+0x9cb84)[0x768f2649cb84]
/lib/x86_64-linux-gnu/libc.so.6(+0x129d6c)[0x768f26529d6c]
```

## baseline-logs/c5-wall.log — killed by signal 11 (Segmentation fault)

```
[hls @ 0x578d392f1680] Packet corrupt (stream = 0, dts = 525000).
[http @ 0x578d390bfcc0] Stream ends prematurely at 1228016, should be 18446744073709551615
[hls @ 0x578d392f1680] Opening 'http://127.0.0.1:34271/review/mosaic-sessions/a7411a4d-8854-44a4-90f0-060e372609a0/seg/11.ts' for reading
2026-09-08 14:49:04.100 [WT-MEM] rss=446MB live_pipelines=0 parked=0 frames=1
[http @ 0x578d392f0e00] Stream ends prematurely at 1263924, should be 18446744073709551615
[hls @ 0x578d392f1680] Opening 'http://127.0.0.1:34271/review/mosaic-sessions/a7411a4d-8854-44a4-90f0-060e372609a0/seg/12.ts' for reading
2026-09-08 14:49:05.194 vaSyncSurface failed: 1 - not importing the surface
2026-09-08 14:49:05.194     failed to get textures for frame; format: 44
[AVHWFramesContext @ 0x578d3b091580] Failed to sync surface 0x11: 1 (operation failed).
2026-09-08 14:49:05.194 Error transferring the data to system memory: -5
2026-09-08 14:49:05.194 Cannot map a video frame in ReadOnly mode!

[WT-FATAL] t=1788868145s (unix; compare `date +%s`) uptime=58s — killed by signal 11 (Segmentation fault); RSS=447 MB. SIGSEGV(11)/SIGABRT(6)/SIGBUS(7) = code crash, backtrace follows.
/home/cilex-vision/projects/cilex-watchtower/build/watchtower(+0x4da5d)[0x578d2ead1a5d]
/lib/x86_64-linux-gnu/libc.so.6(+0x45330)[0x7d13d0445330]
/lib/x86_64-linux-gnu/libc.so.6(+0xa9ce0)[0x7d13d04a9ce0]
/lib/x86_64-linux-gnu/libc.so.6(+0xabb70)[0x7d13d04abb70]
/lib/x86_64-linux-gnu/libc.so.6(malloc+0xa4)[0x7d13d04ad7f4]
/lib/x86_64-linux-gnu/libgallium-25.2.8-0ubuntu0.24.04.2.so(+0x119d2f7)[0x7d13c179d2f7]
/lib/x86_64-linux-gnu/libgallium-25.2.8-0ubuntu0.24.04.2.so(+0x11a01ff)[0x7d13c17a01ff]
/lib/x86_64-linux-gnu/libgallium-25.2.8-0ubuntu0.24.04.2.so(+0x1189087)[0x7d13c1789087]
/lib/x86_64-linux-gnu/libgallium-25.2.8-0ubuntu0.24.04.2.so(+0x77b4c5)[0x7d13c0d7b4c5]
/lib/x86_64-linux-gnu/libgallium-25.2.8-0ubuntu0.24.04.2.so(+0x1814ec)[0x7d13c07814ec]
/home/cilex-vision/Qt/6.12.0-patched-beta1/plugins/wayland-graphics-integration-client/libqt-plugin-wayland-egl.so(_ZN15QtWaylandClient17QWaylandGLContext11swapBuffersEP16QPlatformSurface+0x1d0)[0x7d1
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Gui.so.6(+0x5ef4bc)[0x7d13d1def4bc]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Gui.so.6(_ZN4QRhi8endFrameEP13QRhiSwapChain6QFlagsINS_12EndFrameFlagEE+0x3f)[0x7d13d1c5875f]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Quick.so.6(+0x5142d3)[0x7d13d31142d3]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Quick.so.6(+0x5174eb)[0x7d13d31174eb]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(+0x37583e)[0x7d13d0f7583e]
/lib/x86_64-linux-gnu/libc.so.6(+0x9cb84)[0x7d13d049cb84]
/lib/x86_64-linux-gnu/libc.so.6(+0x129d6c)[0x7d13d0529d6c]
```

## validate2-logs/c1-wall.log — killed by signal 6 (Aborted)

```
[mpegts @ 0x5f37ec1d60c0] Packet corrupt (stream = 0, dts = 532500).
[hls @ 0x5f37efd19940] Packet corrupt (stream = 0, dts = 525000).
[http @ 0x5f37ed3c2780] Stream ends prematurely at 1251328, should be 18446744073709551615
[hls @ 0x5f37efd19940] Opening 'http://127.0.0.1:33253/review/mosaic-sessions/86aa7b69-26b0-4de7-b159-dd5c70db3a18/seg/28.ts' for reading
(previous message repeated x2 more)
2026-09-08 15:01:40.608 vaSyncSurface failed: 1 - not importing the surface
2026-09-08 15:01:40.608     failed to get textures for frame; format: 44
[AVHWFramesContext @ 0x7f8f2cc2b7c0] Failed to sync surface 0x11: 1 (operation failed).
2026-09-08 15:01:40.608 Error transferring the data to system memory: -5
2026-09-08 15:01:40.608 Cannot map a video frame in ReadOnly mode!
free(): invalid next size (fast)

[WT-FATAL] t=1788868900s (unix; compare `date +%s`) uptime=86s — killed by signal 6 (Aborted); RSS=489 MB. SIGSEGV(11)/SIGABRT(6)/SIGBUS(7) = code crash, backtrace follows.
/home/cilex-vision/projects/cilex-watchtower/build/watchtower(+0x4da1d)[0x5f37b7037a1d]
/lib/x86_64-linux-gnu/libc.so.6(+0x45330)[0x7f8f34e45330]
/lib/x86_64-linux-gnu/libc.so.6(pthread_kill+0x11c)[0x7f8f34e9ec0c]
/lib/x86_64-linux-gnu/libc.so.6(gsignal+0x1e)[0x7f8f34e4527e]
/lib/x86_64-linux-gnu/libc.so.6(abort+0xdf)[0x7f8f34e288ff]
/lib/x86_64-linux-gnu/libc.so.6(+0x297b6)[0x7f8f34e297b6]
/lib/x86_64-linux-gnu/libc.so.6(+0xa90d5)[0x7f8f34ea90d5]
/lib/x86_64-linux-gnu/libc.so.6(+0xab4cc)[0x7f8f34eab4cc]
/lib/x86_64-linux-gnu/libc.so.6(__libc_free+0x7e)[0x7f8f34eadeae]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Qml.so.6(+0x2e0208)[0x7f8f370e0208]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Qml.so.6(+0x2e0d83)[0x7f8f370e0d83]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Qml.so.6(+0x2e16c1)[0x7f8f370e16c1]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Qml.so.6(_ZN3QV414GCStateMachine10transitionEv+0x2a8)[0x7f8f370dcf38]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN7QObject5eventEP6QEvent+0x265)[0x7f8f357fa9d5]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN16QCoreApplication15notifyInternal2EP7QObjectP6QEvent+0x168)[0x7f8f357a0468]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN23QCoreApplicationPrivate16sendPostedEventsEP7QObjectiP11QThreadData+0x41a)[0x7f8f357a495a]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(+0x4d29d7)[0x7f8f35ad29d7]
/lib/x86_64-linux-gnu/libglib-2.0.so.0(+0x5d585)[0x7f8f36d14585]
/lib/x86_64-linux-gnu/libglib-2.0.so.0(+0xbc977)[0x7f8f36d73977]
/lib/x86_64-linux-gnu/libglib-2.0.so.0(g_main_context_iteration+0x33)[0x7f8f36d13a23]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN20QEventDispatcherGlib13processEventsE6QFlagsIN10QEventLoop17ProcessEventsFlagEE+0x70)[0x7f8f35ad1f40]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN10QEventLoop4execE6QFlagsINS_17ProcessEventsFlagEE+0x29b)[0x7f8f357ace3b]
/home/cilex-vision/Qt/6.12.0-patched-beta1/lib/libQt6Core.so.6(_ZN16QCoreApplication4execEv+0x9a)[0x7f8f357a857a]
/home/cilex-vision/projects/cilex-watchtower/build/watchtower(main+0x34af)[0x5f37b7026dcf]
/lib/x86_64-linux-gnu/libc.so.6(+0x2a1ca)[0x7f8f34e2a1ca]
/lib/x86_64-linux-gnu/libc.so.6(__libc_start_main+0x8b)[0x7f8f34e2a28b]
/home/cilex-vision/projects/cilex-watchtower/build/watchtower(+0x3e555)[0x5f37b7028555]
```
