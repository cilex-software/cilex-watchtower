/* Loopback-only counterpart to rtsp_fixture.py; no Python GI dependency. */
#include <gst/gst.h>
#include <gst/rtsp-server/rtsp-server.h>
#ifdef G_OS_UNIX
#include <glib-unix.h>
#endif
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>

static gboolean stop_loop(gpointer data)
{
    g_main_loop_quit((GMainLoop *)data);
    return G_SOURCE_REMOVE;
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: live-rtsp-fixture PORT\n");
        return 2;
    }
    char *end = NULL;
    const long port = strtol(argv[1], &end, 10);
    if (!end || *end || port < 1024 || port > 65535) return 2;
    gst_init(NULL, NULL);
    GstElementFactory *encoder = gst_element_factory_find("x264enc");
    if (!encoder) {
        fprintf(stderr, "fixture requires the local x264enc test plugin\n");
        return 2;
    }
    gst_object_unref(encoder);
    GstRTSPServer *server = gst_rtsp_server_new();
    gst_rtsp_server_set_address(server, "127.0.0.1");
    gst_rtsp_server_set_service(server, argv[1]);
    GstRTSPMountPoints *mounts = gst_rtsp_server_get_mount_points(server);
    const char *colours[] = {"red", "green", "blue"};
    for (unsigned i = 0; i < 3; ++i) {
        GstRTSPMediaFactory *factory = gst_rtsp_media_factory_new();
        gchar *pipeline = g_strdup_printf(
            "( videotestsrc is-live=true pattern=%s "
            "! video/x-raw,width=160,height=96,framerate=5/1 "
            /* Identity checks must not depend on software-decoder concealment
             * when warm/decode clients join a shared stream mid-GOP. */
            "! x264enc tune=zerolatency speed-preset=ultrafast threads=1 key-int-max=1 "
            "! rtph264pay name=pay0 pt=96 config-interval=1 )", colours[i]);
        gchar *mount = g_strdup_printf("/%s", colours[i]);
        gst_rtsp_media_factory_set_launch(factory, pipeline);
        gst_rtsp_media_factory_set_shared(factory, TRUE);
        gst_rtsp_mount_points_add_factory(mounts, mount, factory);
        g_free(pipeline);
        g_free(mount);
    }
    g_object_unref(mounts);
    const guint attached = gst_rtsp_server_attach(server, NULL);
    if (!attached) {
        fprintf(stderr, "could not bind loopback fixture port\n");
        g_object_unref(server);
        return 1;
    }
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
#ifdef G_OS_UNIX
    const guint term = g_unix_signal_add(SIGTERM, stop_loop, loop);
    const guint interrupt = g_unix_signal_add(SIGINT, stop_loop, loop);
#else
    /* Bound isolated fixtures even if the controlling test exits unexpectedly. */
    const guint deadline = g_timeout_add_seconds(90, stop_loop, loop);
#endif
    printf("{\"ready\":true,\"address\":\"127.0.0.1\",\"port\":%ld}\n", port);
    fflush(stdout);
    g_main_loop_run(loop);
    /* Signal sources remove themselves after firing; destroy any still alive. */
#ifdef G_OS_UNIX
    if (g_main_context_find_source_by_id(NULL, term)) g_source_remove(term);
    if (g_main_context_find_source_by_id(NULL, interrupt)) g_source_remove(interrupt);
#else
    if (g_main_context_find_source_by_id(NULL, deadline)) g_source_remove(deadline);
#endif
    g_source_remove(attached);
    g_main_loop_unref(loop);
    g_object_unref(server);
    return 0;
}
