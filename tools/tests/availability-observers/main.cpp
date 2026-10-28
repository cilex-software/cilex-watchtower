#include "AvailabilityObservation.h"
#include <QCoreApplication>
#include <cstdio>

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    int passed = 0, failed = 0;
    const auto check = [&](const char *name, bool value) {
        std::fprintf(stderr, "%s %s\n", value ? "PASS" : "FAIL", name);
        value ? ++passed : ++failed;
    };
    using namespace wt::availability;
    check("cached sink adoption has no incoming stamp", !freshDecoded(-1, 1000));
    check("recent real incoming sample is evidence", freshDecoded(1000, 6000));
    check("delayed mailbox sample cannot establish recovery", !freshDecoded(1000, 6001));
    check("future or reversed frame clock cannot establish recovery", !freshDecoded(1001, 1000));
    check("pre-suspend mailbox is stale even if monotonic clock paused", !freshDecoded(1000, 1100, 100000, 160000));
    check("fresh post-resume decoded evidence has two recent clocks", freshDecoded(1000, 1100, 100000, 100100));
    check("cold connect is not an outage before 75 seconds", !confirmedMissingFrame(1000, -1, 75999));
    check("cold connect confirms at 75 seconds", confirmedMissingFrame(1000, -1, 76000));
    check("last decoded arrival owns silent-stall timeout", !confirmedMissingFrame(0, 70000, 144999));
    check("silent-stall confirms after 75 seconds", confirmedMissingFrame(0, 70000, 145000));
    check("ordinary timer jitter is observed continuously", !schedulingGap(1000, 26000));
    check("suspend or long event-loop pause is an observation gap", schedulingGap(1000, 26001));
    check("reversed monotonic clock invalidates continuous observation", schedulingGap(1000, 999));
    check("sleep gaps when monotonic clock excludes suspended time", observationClockGap(1000, 1100, 100000, 160000));
    check("forward wall-clock step conservatively interrupts observation", observationClockGap(1000, 1100, 100000, 200000));
    check("backward wall-clock step conservatively interrupts observation", observationClockGap(1000, 1100, 100000, 99999));
    check("matching clock progress remains continuous", !observationClockGap(1000, 1100, 100000, 100100));
    check("new gap baseline prevents immediate false camera outage", !confirmedMissingFrame(100000, -1, 100000));
    check("snapshot HTTP200 without age is unknown", snapshot(200, true, -1, "live") == "unknown");
    check("snapshot HTTP200 without source is unknown", snapshot(200, true, 0, "") == "unknown");
    check("recorded fallback cannot establish fresh live delivery", snapshot(200, true, 0, "recording") == "unknown");
    check("current explicitly-live snapshot is available", snapshot(200, true, 15000, "live") == "available");
    check("old snapshot is degraded rather than current", snapshot(200, true, 15001, "live") == "degraded");
    check("decoded JPEG is necessary", snapshot(200, false, 0, "live") == "unavailable");
    check("snapshot authorization failure is not camera loss", snapshot(401, false, -1, "") == "unknown");
    check("snapshot permission failure is not camera loss", snapshot(403, false, -1, "") == "unknown");
    check("snapshot API outage is not camera loss", snapshot(503, false, -1, "") == "unknown");
    check("snapshot network failure is not camera loss", snapshot(0, false, -1, "") == "unknown");
    check("snapshot endpoint absence is delivery failure", snapshot(404, false, -1, "") == "unavailable");
    check("reported offline remains reported reachability", reachability("offline") == "unavailable");
    check("unknown backend status is never healthy", reachability("") == "unknown");
    check("maintenance is intentionally unmonitored", reachability("maintenance") == "not_monitored");
    check("motion-idle recording is not recording loss", catalogue("armed", "online", true) == "not_monitored");
    check("disabled recording is not recording loss", catalogue("disabled", "online", true) == "not_monitored");
    check("global recording disabled is not recording loss", catalogue("stalled", "online", false) == "not_monitored");
    check("maintenance recording is not recording loss", catalogue("stalled", "maintenance", true) == "not_monitored");
    check("legacy capture stop does not prove archive loss", catalogue("stalled", "online", true) == "unknown");
    check("legacy capture progress does not prove archive coverage", catalogue("recording", "online", true) == "unknown");
    std::printf("{\"passed\":%d,\"failed\":%d}\n", passed, failed);
    return failed ? 1 : 0;
}
