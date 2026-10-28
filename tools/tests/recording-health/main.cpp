#include "RecordingHealth.h"
#include <QCoreApplication>
#include <QTimeZone>
#include <QJsonDocument>
#include <iostream>

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const auto iso = [](qint64 ms) { return QDateTime::fromMSecsSinceEpoch(ms, QTimeZone::UTC).toString(Qt::ISODateWithMs); };
    const auto lane = [&](const QString &capture, const QString &archive, bool expected = true) {
        return QJsonObject {{"expected",expected},{"observed_at",iso(now-1000)},
            {"valid_until",iso(now+60000)},{"capture_state",capture},{"archive_state",archive},
            {"archive_delay_s",300}};
    };
    QJsonObject health {{"version",1},{"observed_at",iso(now-1000)},{"valid_until",iso(now+60000)},
        {"capture_state","progressing"},{"archive_state","current"},{"archive_delay_s",300},
        {"incident_started_at",QJsonValue::Null},
        {"streams",QJsonObject{{"main",lane("progressing","delayed")},{"sub",lane("progressing","current")}}}};
    int checks=0,failures=0;
    const auto check = [&](bool ok, const char *name) { ++checks; if(!ok) ++failures; std::cout<<(ok?"PASS ":"FAIL ")<<name<<"\n"; };
    auto parsed=wt::recordingHealth::normalize(health,now);
    check(parsed["capture_state"]=="progressing","fresh required lanes establish progress");
    check(parsed["archive_state"]=="delayed","delayed main cannot be masked by current sub or aggregate");
    check(parsed["incident_started_at"].isNull(),"no invented historical incident onset");
    auto badDates=health;badDates["incident_started_at"]="2026-10-28T12:00:00";
    badDates["last_available_end"]="not a date";
    auto badDateResult=wt::recordingHealth::normalize(badDates,now);
    check(badDateResult["incident_started_at"].isNull(),"naive incident onset cannot become a local-time assertion");
    check(badDateResult["last_available_end"].isNull(),"malformed catalogue end is not displayed as a timestamp");
    auto understated=health; understated["archive_delay_s"]=1;
    check(wt::recordingHealth::normalize(understated,now)["archive_delay_s"].toDouble()==300,
          "required-lane delay cannot be understated by optimistic aggregate");
    auto stopped=health; stopped["streams"]=QJsonObject{{"main",lane("stopped","current")},{"sub",lane("progressing","current")}};
    check(wt::recordingHealth::normalize(stopped,now)["capture_state"]=="stopped","main capture stop survives healthy sub");
    auto uncertain=health; uncertain["streams"]=QJsonObject{{"main",lane("progressing","current")}};
    check(wt::recordingHealth::normalize(uncertain,now)["capture_state"]=="unknown","missing lane expectation remains unknown");
    auto expired=wt::recordingHealth::normalize(health,now+60001);
    check(expired["capture_state"]=="unknown" && expired["archive_state"]=="unknown","expired telemetry certifies neither capture nor archive");
    check(expired["archive_delay_s"].isNull(),"expired delay is not presented as current measurement");
    auto invalid=health; invalid.remove("valid_until");
    check(wt::recordingHealth::normalize(invalid,now)["capture_state"]=="unknown","deadline mandatory");
    invalid=health;invalid["observed_at"]="2026-10-28T12:00:00";
    check(wt::recordingHealth::normalize(invalid,now)["capture_state"]=="unknown","naive timestamps rejected");
    invalid=health;invalid["observed_at"]=iso(now+31000);
    check(wt::recordingHealth::normalize(invalid,now)["capture_state"]=="unknown","future observation not current");
    invalid=health;invalid["version"]=2;
    check(wt::recordingHealth::normalize(invalid,now)["capture_state"]=="unknown","unknown contract version never green");
    check(wt::recordingHealth::normalize({},now)["capture_state"]=="unknown","old backend supplies no capture proof");
    auto source=lane("progressing","current");source["capture_state"]="new-state";
    check(wt::recordingHealth::lane(source,now)["capture_state"]=="unknown","unknown capture vocabulary rejected");
    source=lane("progressing","current");source["archive_delay_s"]=-1;
    check(wt::recordingHealth::lane(source,now)["archive_delay_s"].isNull(),"negative delay not fabricated");
    source=lane("progressing","current");source["valid_until"]=iso(now-1);
    auto staleMain=health;staleMain["streams"]=QJsonObject{{"main",source},{"sub",lane("progressing","current")}};
    check(wt::recordingHealth::normalize(staleMain,now)["capture_state"]=="unknown","stale main not masked by fresh aggregate");
    std::cout<<checks<<" checks, "<<failures<<" failures\n";
    return failures ? 1 : 0;
}
