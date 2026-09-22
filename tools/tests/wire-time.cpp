// Tests the wire-timestamp SHAPE detector (src/models/WireTime.h).
//
// WHAT IT IS FOR. A naive ISO string — no 'Z', no ±HH:MM — is read as LOCAL time
// by both our parsers (Qt::ISODate yields timeSpec=0; QV4's Date.parse agrees;
// both measured 2026-09-22 on Qt 6.12). The instant is then wrong by this
// machine's UTC offset — 3 h on the MSK dev box, 0 in a UTC container — and
// every freshness comparison downstream is wrong with it, silently. The instant
// cannot be recovered; the wrong SHAPE can be recognised, and that is all this
// does. An alarm, not a repair.
//
// Two properties are as important as "it fires":
//   * it must NOT fire on the healthy shapes, or the warning trains the reader
//     to ignore it (a bare date legitimately has no offset, and so must pass);
//   * it must say each field ONCE — these sites run on every /streams poll.
//
// Build + run (Qt 6.12):
//   g++ -std=c++17 -fPIC -o /tmp/wiretime tools/tests/wire-time.cpp -Isrc/models \
//       -I$QT/include -I$QT/include/QtCore -L$QT/lib -lQt6Core && LD_LIBRARY_PATH=$QT/lib /tmp/wiretime
#include "WireTime.h"
#include <QCoreApplication>
#include <QDebug>
#include <QStringList>

static QStringList warnings;
static void capture(QtMsgType type, const QMessageLogContext &, const QString &msg)
{
    if (type == QtWarningMsg) warnings << msg;
}

static int fails = 0;
static void ok(bool cond, const QString &what)
{
    if (!cond) ++fails;
    // printed through the real handler, not the capture one
    fprintf(stderr, "%s %s\n", cond ? "PASS" : "FAIL", qPrintable(what));
}

// each case gets its own field name, so the once-per-field latch never hides a case
static int warnCount(const char *iso, const char *field)
{
    const int before = warnings.size();
    const QString out = wt::wireInstant(QJsonValue(QString::fromUtf8(iso)), field);
    if (out != QString::fromUtf8(iso)) { ++fails; fprintf(stderr, "FAIL value mangled: %s\n", iso); }
    return warnings.size() - before;
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    qInstallMessageHandler(capture);

    // ---- healthy shapes: silent
    ok(warnCount("2026-09-22T07:02:08.873+00:00", "f1") == 0, "iso_ms() output is silent (+00:00)");
    ok(warnCount("2026-09-22T07:02:08.873+03:00", "f2") == 0, "a non-UTC offset is silent");
    ok(warnCount("2026-09-22T07:02:08Z", "f3") == 0,          "'Z' is silent");
    ok(warnCount("2026-09-22T07:02:08-05:00", "f4") == 0,     "a negative offset is silent");
    ok(warnCount("2026-09-22T07:02:08+0300", "f5") == 0,      "offset without a colon is silent");
    ok(warnCount("2026-09-22", "f6") == 0,       "a bare DATE is silent — it cannot carry an offset");
    ok(warnCount("", "f7") == 0,                 "absent is silent — that is the -1 sentinel's job");
    ok(warnCount("never", "f8") == 0,   "a non-timestamp string is silent (not this detector's job)");

    // ---- the shape this exists for
    ok(warnCount("2026-09-22T07:02:08", "last_segment_at") == 1,
       "REGRESSION: a naive date-time WARNS");
    ok(warnCount("2026-09-22T07:02:08.873", "motion.last_vmd_at") == 1,
       "REGRESSION: naive with milliseconds WARNS");
    ok(warnCount("2026-09-22T07:02:08.873977", "status_since") == 1,
       "naive with microseconds WARNS");

    // ---- once per FIELD, not once per value: these run on every poll
    ok(warnCount("2026-09-22T07:02:09", "last_segment_at") == 0,
       "the same field says it once, however many polls");
    ok(warnCount("2026-09-22T07:02:08", "recording_since") == 1,
       "...but a DIFFERENT field still gets its own line");

    // ---- the value must never reach the log (mobile's rule, adopted)
    bool leaked = false;
    for (const QString &w : warnings)
        if (w.contains(QStringLiteral("07:02:0"))) leaked = true;
    ok(!leaked, "no warning contains the timestamp VALUE — field names only");
    ok(!warnings.isEmpty() && warnings.first().contains(QStringLiteral("last_segment_at")),
       "the warning NAMES the field");

    qInstallMessageHandler(nullptr);
    fprintf(stderr, "%s\n", fails ? qPrintable(QStringLiteral("%1 FAILED").arg(fails)) : "all passed");
    return fails ? 1 : 0;
}
