// Offline protocol checks. QCoreApplication only; no GUI, clipboard, sockets, or desktop session.
#include "Clipboard.h"
#include "PeerContext_p.h"
#include "RdpConnection.h"
#include <QCoreApplication>
#include <QEvent>
#include <QStringConverter>
#include <freerdp/peer.h>
#include <cassert>
#include <iostream>
#include <thread>

using namespace Qt::StringLiterals;
static KRdp::PeerContext peerContext{};
static freerdp_peer peer{};
static CliprdrServerContext *channel;
static unsigned lists, requests, acks, changes;
static unsigned advertised, responseFlags;
static QByteArray responseBytes;
static std::unique_ptr<QMimeData> received;
static bool stopped;

// Replace only the FreeRDP boundary and peer lookup; execute the built Clipboard implementation.
freerdp_peer *KRdp::RdpConnection::rdpPeer() const { return &peer; }
extern "C" CliprdrServerContext *cliprdr_server_context_new(HANDLE)
{
    auto c = new CliprdrServerContext{};
    channel = c;
    c->Start = [](CliprdrServerContext *) -> UINT { return CHANNEL_RC_OK; };
    c->Stop = [](CliprdrServerContext *c) -> UINT {
        // Reproduce teardown while main-thread event processing is stopped.
        std::thread worker([c] { c->ClientCapabilities(c, nullptr); });
        worker.join();
        stopped = true;
        return CHANNEL_RC_OK;
    };
    c->ServerFormatList = [](CliprdrServerContext *, const CLIPRDR_FORMAT_LIST *p) -> UINT {
        ++lists;
        advertised = p->numFormats;
        if (advertised) assert(p->formats[0].formatId == CF_UNICODETEXT);
        return CHANNEL_RC_OK;
    };
    c->ServerFormatListResponse = [](CliprdrServerContext *, const CLIPRDR_FORMAT_LIST_RESPONSE *p) -> UINT {
        assert(p->common.msgFlags == CB_RESPONSE_OK);
        ++acks;
        return CHANNEL_RC_OK;
    };
    c->ServerFormatDataRequest = [](CliprdrServerContext *, const CLIPRDR_FORMAT_DATA_REQUEST *p) -> UINT {
        assert(p->requestedFormatId == CF_UNICODETEXT);
        ++requests;
        return CHANNEL_RC_OK;
    };
    c->ServerFormatDataResponse = [](CliprdrServerContext *, const CLIPRDR_FORMAT_DATA_RESPONSE *p) -> UINT {
        responseFlags = p->common.msgFlags;
        responseBytes = QByteArray(reinterpret_cast<const char *>(p->requestedFormatData), p->common.dataLen);
        return CHANNEL_RC_OK;
    };
    return c;
}
extern "C" void cliprdr_server_context_free(CliprdrServerContext *c) { delete c; }
static void pump() { for (int i = 0; i < 4; ++i) QCoreApplication::sendPostedEvents(nullptr, QEvent::MetaCall); }
static void offer(std::initializer_list<UINT32> ids)
{
    std::vector<CLIPRDR_FORMAT> formats;
    for (auto id : ids) { CLIPRDR_FORMAT f{}; f.formatId = id; formats.push_back(f); }
    CLIPRDR_FORMAT_LIST p{};
    p.numFormats = formats.size();
    p.formats = formats.data();
    std::thread worker([&] { assert(channel->ClientFormatList(channel, &p) == CHANNEL_RC_OK); });
    worker.join(); // callback must return without pumping the main thread
    for (auto &f : formats) f.formatId = 0; // queued handler must own everything it needs
    pump();
}
static void answer(QByteArray bytes, UINT flags = CB_RESPONSE_OK)
{
    CLIPRDR_FORMAT_DATA_RESPONSE p{};
    p.common.msgFlags = flags;
    p.common.dataLen = bytes.size();
    p.requestedFormatData = reinterpret_cast<const BYTE *>(bytes.constData());
    std::thread worker([&] { channel->ClientFormatDataResponse(channel, &p); });
    worker.join();
    bytes.fill('x'); // verify payload was deep-copied
    pump();
}
static void request(UINT format)
{
    CLIPRDR_FORMAT_DATA_REQUEST p{};
    p.requestedFormatId = format;
    channel->ClientFormatDataRequest(channel, &p);
    pump();
}
int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    peer.context = &peerContext._p;
    KRdp::RdpConnection connection(nullptr, -1);
    QCoreApplication::removePostedEvents(&connection); // suppress network initialization
    {
        KRdp::Clipboard clipboard(&connection);
        QObject::connect(&clipboard, &KRdp::Clipboard::clientDataChanged, &app, [&] {
            ++changes;
            received = clipboard.getClipboard();
        });
        auto server = new QMimeData;
        server->setText(u"Hello नमस्ते 😀\nline"_s);
        clipboard.setServerData(server);
        assert(clipboard.initialize());
        pump();
        assert(lists == 0); // wait for client readiness
        channel->ClientCapabilities(channel, nullptr);
        pump();
        assert(lists == 1 && advertised == 1);
        request(CF_UNICODETEXT);
        assert(responseFlags == CB_RESPONSE_OK);
        assert(responseBytes == QByteArray::fromHex("480065006c006c006f00200028092e0938094d092409470920003dd800de0d000a006c0069006e0065000000"));
        request(CF_DIB);
        assert(responseFlags == CB_RESPONSE_FAIL && responseBytes.isEmpty());
        offer({CF_TEXT, CF_UNICODETEXT, CF_OEMTEXT});
        assert(acks == 1 && requests == 1); // one request, always for an advertised format
        answer(QByteArray::fromHex("41003dd800de0d000a0042000000"));
        assert(received && received->text() == u"A😀\nB"_s);
        offer({CF_UNICODETEXT});
        answer(QByteArray::fromHex("4100000042000000"));
        assert(received && received->text() == u"A"_s); // ignore allocation padding after the first UTF-16 terminator
        offer({CF_UNICODETEXT});
        answer(QByteArray::fromHex("0000"));
        assert(received && received->hasText() && received->text().isEmpty());
        offer({CF_UNICODETEXT});
        answer({});
        assert(received && received->text().isEmpty());
        offer({CF_UNICODETEXT});
        const auto beforeMalformed = changes;
        answer(QByteArray::fromHex("41"));
        assert(changes == beforeMalformed);
        offer({CF_DIB});
        assert(!received && requests == 5); // non-text never requests Unicode
        offer({});
        assert(!received);
        clipboard.setServerData(new QMimeData);
        pump();
        assert(advertised == 0);
        auto empty = new QMimeData;
        empty->setText(QString());
        clipboard.setServerData(empty);
        pump();
        request(CF_UNICODETEXT);
        assert(advertised == 1 && responseFlags == CB_RESPONSE_OK && responseBytes == QByteArray(2, '\0'));
        offer({CF_UNICODETEXT});
        offer({CF_DIB});
        auto beforeStale = changes;
        answer(QByteArray::fromHex("58000000"));
        assert(changes == beforeStale && !received); // ignore response to an older selection
        offer({CF_UNICODETEXT});
        auto newerServer = new QMimeData;
        newerServer->setText(u"newer KDE copy"_s);
        clipboard.setServerData(newerServer);
        pump();
        auto beforeLocalReplacement = changes;
        auto requestsBeforeLocalReplacement = requests;
        answer(QByteArray::fromHex("58000000"));
        assert(changes == beforeLocalReplacement);
        assert(requests == requestsBeforeLocalReplacement); // do not re-request the superseded client selection
        request(CF_UNICODETEXT);
        assert(responseBytes == QByteArray::fromHex("6e00650077006500720020004b0044004500200063006f00700079000000"));
        offer({CF_UNICODETEXT});
        channel->ClientCapabilities(channel, nullptr);
        const auto beforeClose = changes;
        clipboard.close();
        assert(stopped && !clipboard.enabled());
        pump();
        assert(changes == beforeClose);
    }
    // A new connection owns fresh readiness/data state.
    lists = 0;
    {
        KRdp::Clipboard clipboard(&connection);
        assert(clipboard.initialize());
        auto text = new QMimeData;
        text->setText(u"reconnect"_s);
        clipboard.setServerData(text);
        pump();
        assert(lists == 0);
        channel->ClientCapabilities(channel, nullptr);
        pump();
        assert(lists == 1);
        clipboard.close();
    }
    std::cout << "PASS: Unicode both directions, UTF-16LE/CRLF, readiness, empty, non-text, packet lifetime, stale responses, teardown, reconnect state\n";
}
