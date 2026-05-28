#pragma once

#include <QString>
#include "CameraStatus.h"

// Plain data structs shared by the mock-data layer and the list models. These
// are intentionally backend-agnostic so a real ONVIF/NVR source can populate
// the same shapes later.
namespace wt {

struct GroupData {
    QString id;
    QString name;
    QString parentId;
    int level = 0;
    int count = 0;
};

struct CameraData {
    QString id;
    QString name;
    QString groupId;
    QString groupName;
    int live = CameraStatus::Live;        // CameraStatus::LiveState
    int recording = CameraStatus::Recording;  // CameraStatus::RecState
    bool hasAudio = false;
    bool favorite = false;
    QString timestamp;   // live time label, e.g. "17:42:08"
    QString lastSeen;    // e.g. "14:22" (shown when offline)
    int pattern = 0;     // 0..3 placeholder video pattern (fallback when no stream)

    // Real-camera metadata (populated by the provisioning importer; empty for mock).
    QString rtspUrl;     // main stream URL (higher res; on-demand HD only)
    QString rtspSubUrl;  // substream URL — the DEFAULT for monitoring (lighter)
    QString ip;
    QString mac;
    QString model;
    QString vendor;
    QString firmware;
    QString serial;
};

struct EventData {
    QString id;
    QString type;        // "motion" | "offline" | "online" | "gap" | "bookmark"
    QString camId;
    QString camName;
    QString group;
    QString time;
    QString desc;
    bool ack = false;
    QString ackBy;
    QString ackTime;
};

// A reusable Live Monitor layout. Stores the *restorable* state (so opening a
// view reapplies it); per-view camera counts are computed live from CameraModel,
// not stored. lastUsedIso is an ISO timestamp; the screen shows it relatively.
struct SavedViewData {
    QString id;
    QString name;
    bool shared = false;
    bool favorite = false;
    QString layout = QStringLiteral("16");        // "1"/"4"/"9"/"16"/"25"/"plus4"/"center13"/"NxM"
    QString statusFilter;                         // "" | "online" | "offline" | ...
    QString sortMode = QStringLiteral("default"); // "default" | "status" | "alpha"
    QString groupId;                              // "" = all cameras
    QString groupLabel = QStringLiteral("All cameras");
    QString lastUsedIso;
};

} // namespace wt
