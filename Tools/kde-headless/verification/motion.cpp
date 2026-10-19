#include <QApplication>
#include <QElapsedTimer>
#include <QKeyEvent>
#include <QPainter>
#include <QTimer>
#include <QWidget>
class Motion : public QWidget {
  QElapsedTimer clock;
  bool running = false;
  void paintEvent(QPaintEvent *) override {
    QPainter p(this);
    p.fillRect(rect(), QColor(24, 24, 24));
    const int id = running ? int(clock.nsecsElapsed() / 16666667) : 0;
    for (int x = -80; x < width() + 80; x += 80)
      p.fillRect(QRect(x + (id * 5) % 80, 100, 40, height() - 100),
                 QColor(60, 160, 220));
    for (int bit = 0; bit < 16; ++bit)
      p.fillRect(QRect(20 + bit * 40, 20, 32, 48),
                 (id & (1 << bit)) ? Qt::white : Qt::black);
    p.setPen(Qt::white);
    p.drawText(20, 90,
               QString("Frame %1 | Space restarts 30 second motion; Esc stops")
                   .arg(id));
  }
  void keyPressEvent(QKeyEvent *e) override {
    if (e->key() == Qt::Key_Space) {
      running = true;
      clock.restart();
    }
    if (e->key() == Qt::Key_Escape)
      running = false;
    update();
  }

public:
  Motion() {
    setWindowTitle("RDP motion benchmark");
    resize(960, 540);
    QTimer *t = new QTimer(this);
    t->setTimerType(Qt::PreciseTimer);
    t->setInterval(8);
    connect(t, &QTimer::timeout, this, [this] {
      if (running) {
        if (clock.elapsed() > 30000)
          running = false;
        update();
      }
    });
    t->start();
  }
};
int main(int argc, char **argv) {
  QApplication a(argc, argv);
  Motion m;
  m.show();
  return a.exec();
}
