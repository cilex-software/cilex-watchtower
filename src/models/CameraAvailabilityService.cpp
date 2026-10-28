#include "CameraAvailabilityService.h"
#include "CameraAvailabilityWorker.h"
#include "AvailabilityObservationBus.h"
#include "AuthController.h"
#include <QCoreApplication>

CameraAvailabilityService::CameraAvailabilityService(AuthController *auth, QObject *parent)
    : QObject(parent), m_auth(auth)
{
    auto *bus = AvailabilityObservationBus::instance();
    const QString isolated = qEnvironmentVariable("WT_SETTINGS_DIR");
    CameraAvailabilityWorker::Options options;
    // An isolated UI fixture must never read the guard's station credential or
    // write to the guard's availability database, even on Windows.
    if (!isolated.isEmpty()) options.provisioningFile = isolated + "/availability-station.conf";
    m_worker = new CameraAvailabilityWorker(isolated.isEmpty() ? QString{} : isolated + "/availability.sqlite3", options);
    m_thread = new QThread;
    m_worker->moveToThread(m_thread);
    connect(m_thread, &QThread::started, m_worker, &CameraAvailabilityWorker::initialize);
    connect(this, &CameraAvailabilityService::configureRequested, m_worker, &CameraAvailabilityWorker::configure);
    connect(this, &CameraAvailabilityService::syncRequested, m_worker, &CameraAvailabilityWorker::synchronize);
    connect(this, &CameraAvailabilityService::stopRequested, m_worker, &CameraAvailabilityWorker::stop);
    connect(this, &CameraAvailabilityService::historyRequested, m_worker, &CameraAvailabilityWorker::loadHistory);
    connect(bus, &AvailabilityObservationBus::observationReady, m_worker, &CameraAvailabilityWorker::observe);
    connect(m_worker, &CameraAvailabilityWorker::stateReady, this, [this](const QVariantMap &value) { m_status = value; emit stateChanged(); });
    connect(m_worker, &CameraAvailabilityWorker::historyReady, this, [this](const QVariantList &rows, quint64 generation) {
        if (generation != m_viewGeneration) return;
        // Recheck authorization on receipt; a queued result cannot outlive logout.
        m_history.clear();
        if (m_auth->authenticated() && !m_auth->stationLive()) {
            for (auto value : rows) {
                const auto row = value.toMap(); const auto id = row.value("camera_id").toString();
                if (canViewStationEvents() || (!id.isEmpty() && m_auth->cameraScope().contains(id))) m_history.append(row);
            }
        }
        emit stateChanged();
    });
    connect(m_worker, &CameraAvailabilityWorker::finished, m_thread, &QThread::quit, Qt::DirectConnection);
    connect(m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
    connect(auth, &AuthController::authenticatedChanged, this, &CameraAvailabilityService::updateSession);
    connect(auth, &AuthController::identityChanged, this, &CameraAvailabilityService::updateSession);
    connect(auth, &AuthController::baseUrlChanged, this, &CameraAvailabilityService::updateSession);
    connect(auth, &AuthController::stationLiveChanged, this, &CameraAvailabilityService::updateSession);
    connect(qApp, &QCoreApplication::aboutToQuit, m_worker, &CameraAvailabilityWorker::stop);
    m_thread->start();
    updateSession();
}

CameraAvailabilityService::~CameraAvailabilityService()
{
    if (m_thread->isRunning()) emit stopRequested();
    // Network is aborted by stop; busy SQLite operations have a 250 ms timeout.
    // A stalled disk must not hold the GUI/process exit indefinitely. An unclosed
    // run is durably recognized as an observation gap at the next startup.
    if (m_thread->wait(2000)) delete m_thread;
    else {
        connect(m_thread, &QThread::finished, m_thread, &QObject::deleteLater);
        qWarning("Availability shutdown did not finish within two seconds; remaining evidence stays unconfirmed.");
    }
}

bool CameraAvailabilityService::canViewStationEvents() const
{
    const auto role = m_auth->role().toLower();
    return m_auth->authenticated() && !m_auth->stationLive() && (role == "admin" || role == "owner");
}

bool CameraAvailabilityService::canSync() const
{
    const auto role = m_auth->role().toLower();
    return m_auth->authenticated() && !m_auth->stationLive()
        && (role == "admin" || role == "owner" || role == "engineering");
}

void CameraAvailabilityService::updateSession()
{
    ++m_viewGeneration;
    m_history.clear(); emit stateChanged();
    emit configureRequested(m_auth->baseUrl(), m_auth->authenticated() && !m_auth->stationLive(),
                            m_auth->role(), m_auth->cameraScope(), m_viewGeneration);
}
void CameraAvailabilityService::syncNow()
{
    if (canSync()) emit syncRequested();
}
void CameraAvailabilityService::refreshHistory(const QString &camera, const QString &from, const QString &until)
{
    if (!m_auth->authenticated() || m_auth->stationLive()) { m_history.clear(); emit stateChanged(); return; }
    if (!camera.isEmpty() && !canViewStationEvents() && !m_auth->cameraScope().contains(camera)) {
        m_history.clear(); emit stateChanged(); return;
    }
    emit historyRequested(camera, from, until);
}
