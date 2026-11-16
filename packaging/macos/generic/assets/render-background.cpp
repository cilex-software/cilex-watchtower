// Maintainer tool only: normal installer builds use the committed TIFF.
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QPainter>
#include <QSvgRenderer>
#include <cmath>

int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);
    if (argc != 3) qFatal("Usage: render-background input.svg output-directory");
    const QFileInfo input(QString::fromLocal8Bit(argv[1]));
    const QDir output(QString::fromLocal8Bit(argv[2]));
    QDir::setCurrent(input.absolutePath());
    QSvgRenderer svg(input.absoluteFilePath());
    if (!svg.isValid() || svg.defaultSize() != QSize(760, 480))
        qFatal("Expected a valid 760 x 480 installer SVG");
    for (int scale : {1, 2}) {
        QImage image(svg.defaultSize() * scale, QImage::Format_RGB32);
        image.fill(Qt::white);
        image.setDotsPerMeterX(std::lround(72 * scale / 0.0254));
        image.setDotsPerMeterY(std::lround(72 * scale / 0.0254));
        QPainter painter(&image);
        svg.render(&painter);
        painter.end();
        const auto name = scale == 1 ? "install.png" : "install@2x.png";
        if (!image.save(output.filePath(name))) qFatal("Cannot save background PNG");
    }
}
