#include "MockData.h"

#include <QStringList>
#include <QDateTime>

using namespace wt;

QVector<GroupData> mock::groups()
{
    // Site -> Building -> Floor -> Area hierarchy (design §8).
    return {
        { "site-hq",       "HQ Campus",      "",          0, 96 },
        { "g-ext",         "Exterior",       "site-hq",   1, 24 },
        { "g-park",        "Parking",        "g-ext",     2, 12 },
        { "g-perim",       "Perimeter",      "g-ext",     2, 12 },
        { "g-bldg-a",      "Building A",     "site-hq",   1, 36 },
        { "g-bldg-a-lob",  "Ground / Lobby", "g-bldg-a",  2, 8  },
        { "g-bldg-a-f1",   "First Floor",    "g-bldg-a",  2, 16 },
        { "g-bldg-a-f2",   "Second Floor",   "g-bldg-a",  2, 12 },
        { "g-bldg-b",      "Building B",     "site-hq",   1, 22 },
        { "g-bldg-c",      "Warehouse C",    "site-hq",   1, 14 },
        { "site-2",        "North Site",     "",          0, 41 },
        { "g-n-yard",      "Yard",           "site-2",    1, 22 },
        { "g-n-office",    "Offices",        "site-2",    1, 19 },
    };
}

QVector<CameraData> mock::cameras()
{
    struct Leaf {
        QString gid;
        QString gname;
        QString idPrefix;
        QStringList names;   // empty -> synthesize "<group> NN"
        int n;
    };

    const QVector<Leaf> leaves = {
        { "g-bldg-a-lob", "Ground / Lobby", "A-1",
          { "Lobby Main", "Lobby East", "Reception", "Elevators NW", "Mail Room",
            "Stair A", "Stair B", "Service Door" }, 8 },
        { "g-bldg-a-f1", "First Floor", "A-2",
          { "F1 Corridor N", "F1 Corridor S", "F1 Open Plan", "F1 Meeting 4A",
            "F1 Reception", "F1 Print Bay", "F1 Kitchen", "F1 Server Room",
            "F1 Breakout", "F1 Lockers", "F1 East Wing", "F1 West Wing",
            "F1 Balcony", "F1 Fire Exit", "F1 Store", "F1 Comms" }, 16 },
        { "g-bldg-a-f2", "Second Floor", "A-3",
          { "F2 Corridor N", "F2 Corridor S", "F2 Open Plan", "F2 Boardroom",
            "F2 Kitchen", "F2 Lift Lobby", "F2 East Wing", "F2 West Wing",
            "F2 Store", "F2 Print Bay", "F2 Balcony", "F2 Fire Exit" }, 12 },
        { "g-park", "Parking", "P-G",
          { "Parking Gate N", "Parking Gate S", "Parking Lvl 1 Ramp", "Parking Lvl 2",
            "Loading Dock", "Parking Lvl 1 A", "Parking Lvl 1 B", "Parking Lvl 2 A",
            "Parking Lvl 2 B", "Parking Stair", "Parking Pay", "Parking Exit" }, 12 },
        { "g-perim", "Perimeter", "X-P",
          { "Perimeter NW", "Perimeter NE", "Perimeter SW", "Perimeter SE",
            "Fence Line N", "Fence Line E", "Fence Line S", "Fence Line W",
            "Gatehouse", "North Approach", "East Approach", "South Approach" }, 12 },
        { "g-bldg-b",   "Building B",   "B-", {}, 22 },
        { "g-bldg-c",   "Warehouse C",  "C-", {}, 14 },
        { "g-n-yard",   "Yard",         "Y-", {}, 22 },
        { "g-n-office", "Offices",      "O-", {}, 19 },
    };

    QVector<CameraData> out;
    int g = 0;
    for (const Leaf &L : leaves) {
        for (int i = 1; i <= L.n; ++i) {
            CameraData c;
            c.id = L.idPrefix + QString::number(i).rightJustified(2, QLatin1Char('0'));
            c.name = (i <= L.names.size())
                         ? L.names[i - 1]
                         : QStringLiteral("%1 %2").arg(L.gname).arg(i, 2, 10, QLatin1Char('0'));
            c.groupId = L.gid;
            c.groupName = L.gname;
            c.live = CameraStatus::Live;
            c.recording = CameraStatus::Recording;
            c.pattern = g % 4;
            c.hasAudio = (g % 7 == 0);
            c.favorite = false;
            c.timestamp = QStringLiteral("17:42:%1").arg((8 + g * 7) % 60, 2, 10, QLatin1Char('0'));
            c.lastSeen = QStringLiteral("14:22");
            out.push_back(c);
            ++g;
        }
    }

    auto set = [&out](const QString &id, int live, int rec) {
        for (CameraData &c : out)
            if (c.id == id) { c.live = live; c.recording = rec; return; }
    };
    // Offline (4) — recording unknown while the camera is unreachable.
    set("A-107", CameraStatus::Offline, CameraStatus::RecUnknown);
    set("X-P02", CameraStatus::Offline, CameraStatus::RecUnknown);
    set("B-09",  CameraStatus::Offline, CameraStatus::RecUnknown);
    set("Y-14",  CameraStatus::Offline, CameraStatus::RecUnknown);
    // Live but NOT recording (3) — the critical operational state.
    set("P-G05", CameraStatus::Live, CameraStatus::NotRecording);
    set("A-203", CameraStatus::Live, CameraStatus::NotRecording);
    set("C-06",  CameraStatus::Live, CameraStatus::NotRecording);
    // Degraded but still recording (3).
    set("A-301", CameraStatus::Degraded, CameraStatus::Recording);
    set("X-P07", CameraStatus::Degraded, CameraStatus::Recording);
    set("O-11",  CameraStatus::Degraded, CameraStatus::Recording);
    // Recording gap (2).
    set("X-P01", CameraStatus::Live, CameraStatus::RecordingGap);
    set("C-10",  CameraStatus::Live, CameraStatus::RecordingGap);

    const QStringList favs = { "A-101", "A-103", "P-G01", "X-P01" };
    for (CameraData &c : out)
        if (favs.contains(c.id)) c.favorite = true;

    return out;
}

QVector<EventData> mock::events()
{
    return {
        // Types use cilex-vision's authoritative EventType vocab (entered_scene,
        // exited_scene, stopped, loitering, motion_started, motion_ended).
        { "e1", "motion_started", "P-G01", "Parking Gate N", "Parking",     "17:38:12",
          "Motion started — vehicle entering", false, {}, {} },
        { "e2", "loitering",      "A-107", "Stair B",        "Lobby",       "17:31:02",
          "Loitering detected — stairwell", false, {}, {} },
        { "e3", "exited_scene",   "X-P02", "Perimeter NE",   "Perimeter",   "17:14:00",
          "Object exited scene", true, "m.osei", "17:19" },
        { "e4", "entered_scene",  "A-201", "F1 Corridor N",  "First Floor", "16:58:45",
          "Person entered — corridor", false, {}, {} },
        { "e5", "motion_started", "P-G05", "Loading Dock",   "Parking",     "16:42:11",
          "Motion started — after hours", true, "j.chen", "16:44" },
        { "e6", "stopped",        "A-204", "F1 Meeting 4A",  "First Floor", "15:51:09",
          "Object stopped — meeting room", true, "m.osei", "15:52" },
        { "e7", "motion_ended",   "X-P03", "Perimeter SW",   "Perimeter",   "15:22:48",
          "Motion ended — fence line", false, {}, {} },
    };
}

QVector<SavedViewData> mock::savedViews()
{
    const QString now = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
    auto ago = [](int days) { return QDateTime::currentDateTimeUtc().addDays(-days).toString(Qt::ISODate); };
    // id, name, shared, favorite, layoutSize, statusFilter, sortMode, groupId, groupLabel, lastUsedIso
    return {
        { "v1", "Lobby Wall",             false, true,  16, "",          "default", "", "All cameras", now },
        { "v2", "Parking + Perimeter",    true,  false, 16, "",          "status",  "", "All cameras", now },
        { "v3", "Night Shift — Critical", true,  true,  9,  "issues",    "status",  "", "All cameras", ago(1) },
        { "v4", "My Favorites",           false, true,  4,  "favorites", "default", "", "All cameras", ago(3) },
        { "v5", "Warehouse C",            true,  false, 9,  "",          "default", "", "All cameras", ago(2) },
        { "v6", "After Hours Patrol",     true,  false, 16, "offline",   "status",  "", "All cameras", ago(6) },
    };
}
