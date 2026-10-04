#include "LabsVerify.h"

#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QTimer>

LabsVerify::LabsVerify(QObject *parent) : QObject(parent) {}

LabsVerify::~LabsVerify()
{
    if (m_proc) {
        m_proc->kill();
        m_proc->waitForFinished(2000);
    }
}

void LabsVerify::enqueue(const QString &checkId, const QString &title,
                         const QVariantList &argv, double timeoutS)
{
    enqueueEnv(checkId, title, argv, timeoutS, QVariantMap());
}

void LabsVerify::enqueueEnv(const QString &checkId, const QString &title,
                            const QVariantList &argv, double timeoutS,
                            const QVariantMap &env)
{
    Item it;
    it.id = checkId;
    it.title = title;
    for (const QVariant &v : argv)
        it.argv << v.toString();
    it.timeoutS = timeoutS;
    for (auto e = env.constBegin(); e != env.constEnd(); ++e)
        it.env.insert(e.key(), e.value().toString());
    m_queue.append(it);
}

void LabsVerify::clearQueue()
{
    m_queue.clear();
}

void LabsVerify::startQueue()
{
    if (m_proc)
        return;
    m_cancelled = false;
    emit busyChanged();
    next();
}

void LabsVerify::cancel()
{
    m_cancelled = true;
    m_queue.clear();
    emit busyChanged();
    if (m_proc) {
        m_proc->terminate();
        QTimer::singleShot(3000, this, [this]() {
            if (m_proc && m_proc->state() != QProcess::NotRunning)
                m_proc->kill();
        });
    }
}

void LabsVerify::next()
{
    if (m_queue.isEmpty()) {
        m_current.clear();
        emit currentChanged();
        emit busyChanged();
        emit queueFinished();
        return;
    }
    emit busyChanged();
    const Item it = m_queue.takeFirst();
    m_current = it.title;
    m_currentId = it.id;
    m_pass = m_fail = 0;
    m_timedOut = false;
    emit currentChanged();
    emit busyChanged();
    emit lineReceived(it.id, QStringLiteral("section"), it.title);

    m_proc = new QProcess(this);
    m_proc->setProcessChannelMode(QProcess::MergedChannels);
    connect(m_proc, &QProcess::readyReadStandardOutput, this, [this]() { onStdout(); });
    connect(m_proc, &QProcess::finished, this, [this, it](int code, QProcess::ExitStatus st) {
        onStdout();
        if (m_proc) {
            m_proc->deleteLater();
            m_proc = nullptr;
        }
        const bool ok = !m_cancelled && !m_timedOut && st == QProcess::NormalExit && code == 0;
        QString summary;
        if (m_cancelled)
            summary = tr("cancelled");
        else if (m_timedOut)
            summary = tr("timed out");
        else
            summary = tr("%1 passed, %2 failed, exit %3").arg(m_pass).arg(m_fail).arg(code);
        emit checkFinished(it.id, ok, code, summary);
        if (!m_cancelled)
            next();
        else {
            m_current.clear();
            emit currentChanged();
            emit busyChanged();
            emit queueFinished();
        }
    });
    connect(m_proc, &QProcess::errorOccurred, this, [this, it](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart)
            emit lineReceived(it.id, QStringLiteral("error"),
                              tr("could not start %1").arg(it.argv.value(0)));
    });
    if (it.timeoutS > 0) {
        QTimer::singleShot(int(it.timeoutS * 1000), this, [this, it]() {
            if (m_proc && m_currentId == it.id && m_proc->state() != QProcess::NotRunning) {
                m_timedOut = true;
                emit lineReceived(it.id, QStringLiteral("error"),
                                  tr("timed out after %1 s; killing the check").arg(it.timeoutS));
                m_proc->kill();
            }
        });
    }
    if (!it.env.isEmpty()) {
        QProcessEnvironment pe = QProcessEnvironment::systemEnvironment();
        for (auto e = it.env.constBegin(); e != it.env.constEnd(); ++e)
            pe.insert(e.key(), e.value());
        m_proc->setProcessEnvironment(pe);
    }
    m_proc->start(it.argv.value(0), it.argv.mid(1));
}

void LabsVerify::onStdout()
{
    if (!m_proc)
        return;
    m_buf += m_proc->readAll();
    int nl = 0;
    while ((nl = m_buf.indexOf('\n')) >= 0) {
        const QByteArray line = m_buf.left(nl);
        m_buf.remove(0, nl + 1);
        const QString text = QString::fromUtf8(line).trimmed();
        if (!text.isEmpty())
            classify(m_currentId, text);
    }
}

void LabsVerify::classify(const QString &checkId, const QString &line)
{
    if (line.startsWith(QLatin1String("PASS"))) {
        ++m_pass;
        emit lineReceived(checkId, QStringLiteral("pass"), line);
    } else if (line.startsWith(QLatin1String("FAIL"))) {
        ++m_fail;
        emit lineReceived(checkId, QStringLiteral("fail"), line);
    } else if (line.startsWith(QLatin1String("---")) || line.startsWith(QLatin1String("==="))) {
        emit lineReceived(checkId, QStringLiteral("section"), line);
    } else {
        emit lineReceived(checkId, QStringLiteral("out"), line);
    }
}
