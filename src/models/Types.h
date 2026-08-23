#pragma once

#include <QString>
#include <QVariantList>
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
    bool hasAudio = false;          // audio SUPPORTED (mic present; backend `audio.supported`)
    bool audioRecording = false;    // audio track recorded (backend `audio.recording_enabled`)
    bool favorite = false;
    QString timestamp;   // live time label, e.g. "17:42:08"
    QString lastSeen;    // e.g. "14:22" (shown when offline)
    QString lastSegmentAt;  // ISO instant of the last recorded segment from /streams ("" if none)
    int pattern = 0;     // 0..3 placeholder video pattern (fallback when no stream)

    // Real-camera metadata (populated by the provisioning importer; empty for mock).
    QString rtspUrl;     // main stream URL (higher res; on-demand HD only)
    QString rtspSubUrl;  // substream URL — the DEFAULT for monitoring (lighter)
    QString snapshotUrl; // backend-provided still-frame URL (go2rtc frame.jpeg) for thumbnails
    // Motion readiness truth (backend `motion` object, P1 thread ask-4, e841f1c):
    // known=false when the key is ABSENT (unknown must never render healthy).
    bool motionKnown = false;
    bool motionReady = false;
    // Sticky proof (1cc987d): confirmed = >=1 real VMD since config last
    // provably broken; last_vmd_at is monotone (never regresses/nulls).
    bool motionConfirmed = false;
    QString motionStatus;      // preflight verdict, e.g. NOT_READY_ZERO_SENSITIVITY
    QString motionLastVmdAt;   // ISO, "" = never
    // Effective recording profile (backend `recording_profile`, da3be8e):
    // absent = NO profile assigned (unknown, not "continuous").
    QString recProfileMode;    // "motion" | "continuous" | "" = unknown
    int recPreRollMs = -1;     // -1 = unknown
    int recPostRollMs = -1;
    // Tri-state per-camera "Standard rendition exists" (CV d690e52, observed-not-
    // declared): -1 = server did not say (old server / degraded probe — behave as
    // before), 0 = sub never recorded (motion cameras: High only), 1 = sub present.
    int hasSubRecording = -1;
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
    qint64 tsMs = 0;     // start_time as epoch ms — for chronological Time sort (0 = unknown/mock)
    qint64 durationMs = 0;  // duration_ms from /events (0 = instantaneous / unknown)
    QString recordingId;    // metadata.recording_id — clip/still semantics (mode-dependent: continuous cameras are honestly null)
    QString rawMotionEventId; // metadata.raw_motion_event_id — the episode JOIN key, all camera modes (CV bf49af6)

    // Events redesign contract (cilex-vision 2026-06-18; see docs/letters/).
    QString severity;           // critical|high|medium|low (server-computed)
    bool zoneRestricted = false;
    QString triageState;        // new|acknowledged|in_progress|resolved|dismissed (NOT `state`)
    QString disposition;        // verified|dispatched|authorized|false_alarm|dismissed | ""
    QString dispositionNote;
    QString assignedTo;         // operator username, or "" (unassigned)
    QString assignedAt;         // ISO instant, or ""
    bool bookmarked = false;
    QString clipUrl;            // signed playback URL (optional)
    // AI detection (null until the AI tier / smart events land) — empty class = none.
    QString detClass;           // person|vehicle|face|…
    double detConf = -1.0;      // 0..1, -1 = none
    QVariantList detBbox;       // [x,y,w,h] normalized 0..1, or empty
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
