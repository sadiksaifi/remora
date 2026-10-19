// SPDX-License-Identifier: MIT
// Build: c++ -fPIC desktop-input.cpp -o desktop-input $(pkg-config --cflags --libs Qt6Widgets)
// Operate through the RDP client. Counters report events received by the application.
#include <QApplication>
#include <QClipboard>
#include <QLabel>
#include <QLineEdit>
#include <QMouseEvent>
#include <QPushButton>
#include <QTextEdit>
#include <QVBoxLayout>
#include <QWheelEvent>

class InputTarget : public QLabel
{
public:
    InputTarget()
        : QLabel("Pointer target: click, double-click, right-click, middle-click, drag")
    {
        setMinimumHeight(100);
        setFrameStyle(QFrame::Box);
        setMouseTracking(true);
        setFocusPolicy(Qt::StrongFocus);
    }

protected:
    void mousePressEvent(QMouseEvent *event) override
    {
        origin = event->position();
        setText(QString("Press: button=%1, count=%2").arg(int(event->button())).arg(++presses));
    }
    void mouseReleaseEvent(QMouseEvent *event) override
    {
        auto distance = event->position() - origin;
        setText(QString("Release: button=%1, presses=%2, drag=%3,%4")
                    .arg(int(event->button())).arg(presses).arg(distance.x()).arg(distance.y()));
    }
    void mouseDoubleClickEvent(QMouseEvent *) override
    {
        setText(QString("Double-click received: %1").arg(++doubleClicks));
    }
    void wheelEvent(QWheelEvent *event) override
    {
        wheel += event->angleDelta();
        setText(QString("Wheel total: x=%1 y=%2; last: x=%3 y=%4")
                    .arg(wheel.x()).arg(wheel.y())
                    .arg(event->angleDelta().x()).arg(event->angleDelta().y()));
        event->accept();
    }

private:
    int presses = 0;
    int doubleClicks = 0;
    QPointF origin;
    QPoint wheel;
};

int main(int argc, char **argv)
{
    QApplication app(argc, argv);
    QWidget window;
    window.setWindowTitle("Remora desktop compatibility check");
    auto layout = new QVBoxLayout(&window);
    layout->addWidget(new QLabel("Keyboard: type, select, delete, undo; Tab between controls."));
    auto text = new QLineEdit;
    text->setPlaceholderText("Keyboard and paste target");
    layout->addWidget(text);
    layout->addWidget(new InputTarget);
    auto copy = new QPushButton("Copy known Unicode text to remote clipboard");
    layout->addWidget(copy);
    QObject::connect(copy, &QPushButton::clicked, [] {
        QApplication::clipboard()->setText(QString::fromUtf8("KDE clipboard: café Ελληνικά 日本語 🙂"));
    });
    auto paste = new QPushButton("Read remote clipboard into text field");
    layout->addWidget(paste);
    QObject::connect(paste, &QPushButton::clicked, [text] {
        text->setText(QApplication::clipboard()->text());
    });
    auto scroll = new QTextEdit;
    scroll->setReadOnly(true);
    scroll->setLineWrapMode(QTextEdit::NoWrap);
    QString lines;
    for (int i = 1; i <= 200; ++i) {
        lines += QString("Line %1: ").arg(i) + QString("horizontal scroll target ").repeated(12) + '\n';
    }
    scroll->setPlainText(lines);
    layout->addWidget(scroll);
    window.resize(1000, 700);
    window.show();
    return app.exec();
}
