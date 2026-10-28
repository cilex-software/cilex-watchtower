/* Loopback-only: first session silently stops after 30 raw frames; later
 * sessions use blue pixels and continue. No EOS/error/restart triggers. */
#include <gst/gst.h>
#include <gst/rtsp-server/rtsp-server.h>
#ifdef G_OS_UNIX
#include <glib-unix.h>
#endif
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>

static guint generation = 0;
static GstPadProbeReturn silent_stall(GstPad *pad, GstPadProbeInfo *info, gpointer data)
{
    (void)pad; (void)info;
    guint *frames = data;
    ++*frames;
    if (*frames == 31) {
        printf("{\"event\":\"silent_stall\",\"generation\":1,\"delivered_raw_frames\":30}\n");
        fflush(stdout);
    }
    return *frames > 30 ? GST_PAD_PROBE_DROP : GST_PAD_PROBE_OK;
}
static void configure(GstRTSPMediaFactory *factory, GstRTSPMedia *media, gpointer unused)
{
    (void)factory; (void)unused;
    const guint current = ++generation;
    GstElement *pipeline = gst_rtsp_media_get_element(media);
    GstElement *source = gst_bin_get_by_name_recurse_up(GST_BIN(pipeline), "testsrc");
    /* GstVideoTestSrcPattern: red=4, blue=6. */
    g_object_set(source, "pattern", current == 1 ? 4 : 6, NULL);
    gst_object_unref(source);
    if (current == 1) {
        GstElement *gate = gst_bin_get_by_name_recurse_up(GST_BIN(pipeline), "gate");
        GstPad *pad = gst_element_get_static_pad(gate, "src");
        gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER, silent_stall, g_new0(guint, 1), g_free);
        gst_object_unref(pad);
        gst_object_unref(gate);
    }
    gst_object_unref(pipeline);
    printf("{\"event\":\"connection\",\"generation\":%u}\n", current);
    fflush(stdout);
}
static gboolean quit(gpointer data) { g_main_loop_quit(data); return G_SOURCE_REMOVE; }
int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    char *end = NULL;
    long port = strtol(argv[1], &end, 10);
    if (!end || *end || port < 1024 || port > 65535) return 2;
    gst_init(NULL, NULL);
    GstElementFactory *encoder = gst_element_factory_find("x264enc");
    if (!encoder) { fprintf(stderr, "local fixture requires x264enc\n"); return 2; }
    gst_object_unref(encoder);
    GstRTSPServer *server = gst_rtsp_server_new();
    gst_rtsp_server_set_address(server, "127.0.0.1");
    gst_rtsp_server_set_service(server, argv[1]);
    GstRTSPMountPoints *mounts = gst_rtsp_server_get_mount_points(server);
    GstRTSPMediaFactory *factory = gst_rtsp_media_factory_new();
    gst_rtsp_media_factory_set_launch(factory,
        "( videotestsrc name=testsrc is-live=true pattern=red "
        "! video/x-raw,width=160,height=96,framerate=15/1 ! identity name=gate "
        "! x264enc tune=zerolatency speed-preset=ultrafast threads=1 key-int-max=15 "
        "! rtph264pay name=pay0 pt=96 config-interval=1 )");
    gst_rtsp_media_factory_set_shared(factory, FALSE);
    g_signal_connect(factory, "media-configure", G_CALLBACK(configure), NULL);
    gst_rtsp_mount_points_add_factory(mounts, "/silent-stall", factory);
    g_object_unref(mounts);
    guint attached = gst_rtsp_server_attach(server, NULL);
    if (!attached) return 1;
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
#ifdef G_OS_UNIX
    guint term = g_unix_signal_add(SIGTERM, quit, loop);
    guint interrupt = g_unix_signal_add(SIGINT, quit, loop);
#else
    guint deadline = g_timeout_add_seconds(90, quit, loop);
#endif
    printf("{\"ready\":true,\"address\":\"127.0.0.1\",\"port\":%ld}\n", port);
    fflush(stdout);
    g_main_loop_run(loop);
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
