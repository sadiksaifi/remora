// Runs the real producer, filter graph, H.264 encoder and decoder without a desktop.
// The runner removes only PipeWire connection setup from a disposable producer copy.
#include "pipewireproduce_p.h"
#include "libx264encoder_p.h"
#include "pwhelpers.h"
#include <algorithm>
#include <cstring>
#include <QCoreApplication>
#include <QEventLoop>
#include <iostream>
#include <vector>
extern "C" {
#include <libavfilter/buffersrc.h>
}

static void waitMs(int ms)
{
    QEventLoop loop;
    QTimer::singleShot(ms, &loop, &QEventLoop::quit);
    loop.exec();
}

class FrameEncoder : public LibX264Encoder
{
public:
    explicit FrameEncoder(PipeWireProduce *p) : LibX264Encoder(H264Profile::Baseline, p) {}
    int submissions = 0;
    int maxPending = 0;
    bool filterFrame(const PipeWireFrame &frame) override
    {
        // SoftwareEncoder rejects cursor-only packets without image data.
        if (!frame.dataFrame) return false;
        maxPending = std::max(maxPending, int(m_produce->m_pendingFilterFrames + m_produce->m_pendingEncodeFrames + 1));
        // Replace only the PipeWire image download. Filtering and encoding are real.
        auto image = frame.dataFrame->toImage();
        AVFrame *f = av_frame_alloc();
        f->format = AV_PIX_FMT_RGBA;
        f->width = image.width();
        f->height = image.height();
        f->pts = m_produce->framePts(frame.presentationTimestamp);
        av_frame_get_buffer(f, 32);
        for (int y = 0; y < f->height; ++y) {
            memcpy(f->data[0] + y * f->linesize[0], image.constScanLine(y), f->width * 4);
        }
        const int result = av_buffersrc_add_frame(m_inputFilter, f);
        av_frame_free(&f);
        if (result >= 0) ++submissions;
        return result >= 0;
    }
};

class Produce : public PipeWireProduce
{
public:
    Produce() : PipeWireProduce(PipeWireBaseEncodedStream::H264Baseline, 0, 0, {60, 1})
    {
        initialize();
        setMaxPendingFrames(3);
        auto encoder = std::make_unique<FrameEncoder>(this);
        encoder->setEncodingPreference(PipeWireBaseEncodedStream::Speed);
        if (!encoder->initialize({32, 32})) qFatal("encoder setup failed");
        m_encoder = std::move(encoder);
        decoder = avcodec_alloc_context3(avcodec_find_decoder(AV_CODEC_ID_H264));
        if (avcodec_open2(decoder, decoder->codec, nullptr) < 0) qFatal("decoder setup failed");
    }
    ~Produce() override { avcodec_free_context(&decoder); }
    AVCodecContext *decoder;
    std::vector<int64_t> decoded;
    bool pixelsMatch = true;
    void processPacket(AVPacket *packet) override
    {
        if (avcodec_send_packet(decoder, packet) < 0) qFatal("decode send failed");
        AVFrame *frame = av_frame_alloc();
        while (avcodec_receive_frame(decoder, frame) == 0) {
            decoded.push_back(frame->pts);
            const int expectedY = 16 + (frame->pts * 219 + 127) / 255;
            pixelsMatch &= std::abs(int(frame->data[0][0]) - expectedY) <= 3;
            av_frame_unref(frame);
        }
        av_frame_free(&frame);
    }
    void source(int pts)
    {
        // Keep pixel storage alive until all cached frames have been released.
        images.emplace_back(32, 32, QImage::Format_RGBA8888_Premultiplied);
        images.back().fill(QColor(pts, pts, pts));
        PipeWireFrame f{};
        f.presentationTimestamp = std::chrono::milliseconds(pts);
        f.dataFrame = std::make_shared<PipeWireFrameData>(SPA_VIDEO_FORMAT_RGBA,
            images.back().bits(), images.back().size(), images.back().bytesPerLine(), new PipeWireFrameCleanupFunction([] {}));
        processFrame(f);
    }
    void cursorOnly(int pts)
    {
        PipeWireFrame f{};
        f.presentationTimestamp = std::chrono::milliseconds(pts);
        f.cursor = PipeWireCursor{QPoint(7, 9), QPoint(1, 2), {}};
        processFrame(f);
        if (m_cursor.position != QPoint(7, 9) || m_cursor.hotspot != QPoint(1, 2)) qFatal("cursor metadata lost");
    }
    void release()
    {
        // Drive the exact worker operations synchronously: time/worker scheduling
        // is the controlled boundary, not a fake pending counter or fake encoder.
        const auto [filtered, queued] = m_encoder->encodeFrame(m_maxPendingFrames - m_pendingEncodeFrames);
        m_pendingFilterFrames -= filtered;
        m_pendingEncodeFrames += queued;
        m_pendingEncodeFrames -= m_encoder->receivePacket();
        handleEncodedFramesChanged();
    }
    int submissions() const { return static_cast<FrameEncoder *>(m_encoder.get())->submissions; }
    std::vector<QImage> images;
};

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    av_log_set_level(AV_LOG_ERROR);
    bool all = true;
    for (const auto scenario : {"source", "resume-full", "repeat", "stay-paused", "repeat-paused", "source-cursor", "repeat-cursor"}) {
        Produce p;
        p.source(100); p.source(120); p.source(140);
        const bool repeat = std::string(scenario) == "repeat" || std::string(scenario) == "repeat-paused" || std::string(scenario) == "repeat-cursor";
        const bool pause = std::string(scenario) == "resume-full" || std::string(scenario) == "stay-paused" || std::string(scenario) == "repeat-paused";
        const bool stayPaused = std::string(scenario) == "stay-paused" || std::string(scenario) == "repeat-paused";
        if (pause) p.setEncoderPaused(true);
        if (!repeat) p.source(160);
        if (pause && !stayPaused) p.setEncoderPaused(false);
        if (std::string(scenario) == "source-cursor" || std::string(scenario) == "repeat-cursor") p.cursorOnly(180);
        waitMs(250); // The real single-shot repeat interval is 100 ms.
        const bool held = p.m_pendingFilterFrames + p.m_pendingEncodeFrames == 3 && p.submissions() == 3;
        p.release();
        if (stayPaused) {
            waitMs(150);
            if (p.submissions() != 3) qFatal("submitted while paused");
            p.setEncoderPaused(false);
        }
        for (int i = 0; i < 6; ++i) { waitMs(125); p.release(); }
        const int expected = repeat ? 140 : 160;
        const bool delivered = std::find(p.decoded.begin(), p.decoded.end(), expected) != p.decoded.end();
        const int settled = p.submissions();
        for (int i = 0; i < 4; ++i) { p.handleEncodedFramesChanged(); waitMs(125); p.release(); }
        const bool bounded = static_cast<FrameEncoder *>(p.m_encoder.get())->maxPending <= 3
            && p.m_pendingFilterFrames + p.m_pendingEncodeFrames <= 3;
        const bool quiet = settled == p.submissions();
        const bool pass = held && delivered && p.pixelsMatch && bounded && quiet;
        std::cout << scenario << " " << (pass ? "PASS" : "FAIL") << " held=" << held
                  << " final=" << delivered << " pixels=" << p.pixelsMatch << " bounded=" << bounded << " quiet=" << quiet
                  << " submissions=" << p.submissions() << " decoded=";
        for (auto pts : p.decoded) std::cout << pts << ",";
        std::cout << std::endl;
        all &= pass;
    }
    return all ? 0 : 1;
}
