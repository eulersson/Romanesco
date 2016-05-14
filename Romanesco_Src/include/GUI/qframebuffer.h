#ifndef QFRAMEBUFFER_H
#define QFRAMEBUFFER_H


#include <QMainWindow>
#include <QGraphicsScene>
#include <QImage>
#include <QList>

#include "GUI/qtimelineanimated.h"

class QFramebuffer : public QMainWindow
{
    Q_OBJECT
public:
    explicit QFramebuffer(QWidget *parent = 0);

private:
    QAnimatedTimeline* m_timeline;
    QGraphicsScene* m_scene;
    QMenuBar* m_menu;
    QGraphicsView* m_view;

    QList<QImage> m_frames;

signals:

public slots:
};

#endif // QFRAMEBUFFER_H