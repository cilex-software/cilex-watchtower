#pragma once

#include <QObject>
#include <QProcess>
#include <QString>
#include <QMap>
#include <QStringList>
#include <QVariantList>

// Runs the repository's REAL check commands as child processes, one at a time,
// streaming every output line to the Labs Verification view. This is what makes
// the in-app verification honest: the UI does not parse a prewritten report, it
// executes tools/tests/labs-temporal-tracks.py, tools/tests/labs-worker.py, the
// analyser self-tests and the streaming workload exactly as a terminal would,
// and shows the lines and the exit status of THIS run.
//
// One child at a time on purpose: these suites are CPU-heavy and the box may be
// a shared station. A queue also keeps the log ordered and cancellation simple.
// Cancelling kills the current child and drops the rest of the queue -- a
// cancelled verification is reported as cancelled, never as passed.
class LabsVerify : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    Q_PROPERTY(QString currentCheck READ currentCheck NOTIFY currentChanged)
public:
    explicit LabsVerify(QObject *parent = nullptr);
    ~LabsVerify() override;

    bool busy() const { return m_proc != nullptr || !m_queue.isEmpty(); }
    QString currentCheck() const { return m_current; }

    // argv[0] is the program; the rest are arguments. timeoutS <= 0 means no
    // timeout. Nothing runs until startQueue(). `env` adds or overrides child
    // environment variables (the suites read WT_SHORT and friends).
    Q_INVOKABLE void enqueue(const QString &checkId, const QString &title,
                             const QVariantList &argv, double timeoutS);
    Q_INVOKABLE void enqueueEnv(const QString &checkId, const QString &title,
                                const QVariantList &argv, double timeoutS,
                                const QVariantMap &env);
    Q_INVOKABLE void startQueue();
    Q_INVOKABLE void cancel();
    Q_INVOKABLE void clearQueue();

signals:
    // kind: "pass" | "fail" | "section" | "out" | "error"
    void lineReceived(const QString &checkId, const QString &kind, const QString &text);
    void checkFinished(const QString &checkId, bool ok, int exitCode, const QString &summary);
    void queueFinished();
    void busyChanged();
    void currentChanged();

private:
    struct Item {
        QString id;
        QString title;
        QStringList argv;
        QMap<QString, QString> env;
        double timeoutS = 0;
    };
    void next();
    void onStdout();
    void classify(const QString &checkId, const QString &line);

    QList<Item> m_queue;
    QProcess *m_proc = nullptr;
    QByteArray m_buf;
    QString m_current;
    QString m_currentId;
    int m_pass = 0;
    int m_fail = 0;
    bool m_cancelled = false;
    bool m_timedOut = false;
};
