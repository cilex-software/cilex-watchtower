# Station live-session checks

This isolated Qt loopback fixture checks display-session renewal, temporary
server failures, expiry without stopping video, rate limits, redirects,
operator sign-in, logout and delayed-response isolation. It uses disposable
credentials and temporary settings; it never contacts a real station/server.

```sh
cmake -S tools/tests/station-session -B build/station-session -DCMAKE_PREFIX_PATH=/path/to/Qt
cmake --build build/station-session
ctest --test-dir build/station-session --output-on-failure
```

Use a fresh build folder when validating changes to class layouts. The tests
cover the actual AuthController and network requests; they do not establish
physical camera playback, Windows startup or successful station deployment.
