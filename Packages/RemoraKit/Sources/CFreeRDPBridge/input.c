#include "input.h"
#include <freerdp/gdi/gdi.h>
#include <freerdp/graphics.h>
#include <freerdp/input.h>
#include <freerdp/locale/keyboard.h>
#include <freerdp/scancode.h>
#include <winpr/input.h>
#include <pthread.h>
#include <stdlib.h>

/* All FreeRDP input calls and pressed state belong to the session thread.
 * The mutex covers queue links, request cancellation/receipts and capabilities. */
typedef enum { COMMAND_KEY, COMMAND_POINTER, COMMAND_WHEEL, COMMAND_SYNCHRONIZE, COMMAND_RELEASE, COMMAND_AGENT } CommandType;
typedef struct Command {
    CommandType type;
    uint64_t request, sequence;
    RMRDPAgentEvent agent;
    uint16_t key, x, y;
    uint8_t buttons, locks;
    bool down, movement;
    int32_t vertical, horizontal;
    struct Command *next;
} Command;

struct RMInput {
    rdpContext *context;
    RMRDPCallbacks callbacks;
    void *user;
    pthread_mutex_t lock;
    HANDLE wake;
    Command *head, *tail;
    bool keys[2][512];
    uint8_t source_buttons[2], capabilities;
    uint64_t request, queued, submitted;
    bool cancelled, failed;
    bool iso_keyboard;
    uint8_t buttons, queued_buttons;
    uint16_t x, y;
};

uint32_t rm_rdp_keyboard_layout(const char *name) {
    const DWORD layout = freerdp_keyboard_get_layout_id_from_name(name);
    return layout ? layout : 0x0409;
}

uint32_t rm_rdp_scancode(uint16_t key, bool iso_keyboard) {
    /* Match FreeRDP's Mac client: Apple exchanges the two ISO physical positions. */
    if (iso_keyboard) {
        if (key == 0x0A) key = 0x32;
        else if (key == 0x32) key = 0x0A;
    }
    if (key > 127)
        return 0;
    const DWORD vk = GetVirtualKeyCodeFromKeycode(key, WINPR_KEYCODE_TYPE_APPLE);
    const DWORD scan = GetVirtualScanCodeFromVirtualKeyCode(vk, 4);
    /* FreeRDP 3.32.2 Apple table gaps. Preserve physical keys, including F13/F15
     * rather than its legacy PrintScreen/Pause aliases. Fn has no PC equivalent. */
    switch (key) {
        case 0x3E: return RDP_SCANCODE_RCONTROL;
        case 0x3F: return 0;
        case 0x48: return RDP_SCANCODE_VOLUME_UP;
        case 0x49: return RDP_SCANCODE_VOLUME_DOWN;
        case 0x4A: return RDP_SCANCODE_VOLUME_MUTE;
        case 0x51: return MAKE_RDP_SCANCODE(0x59, FALSE); /* Keypad equals */
        case 0x5D: return RDP_SCANCODE_BACKSLASH_JP;     /* JIS Yen */
        case 0x5E: return RDP_SCANCODE_ABNT_C1;          /* JIS Ro/underscore */
        case 0x5F: return RDP_SCANCODE_ABNT_C2;          /* JIS keypad comma */
        case 0x66: return RDP_SCANCODE_NONCONVERT_JP;    /* Eisu */
        case 0x68: return RDP_SCANCODE_HIRAGANA;         /* Kana */
        case 0x69: return RDP_SCANCODE_F13;
        case 0x6E: return RDP_SCANCODE_APPS;
        case 0x71: return RDP_SCANCODE_F15;
        default: return scan;
    }
}

RMInput *rm_input_new(rdpContext *context, const RMRDPCallbacks *callbacks, void *user, bool iso_keyboard) {
    RMInput *q = calloc(1, sizeof(*q));
    if (!q)
        return NULL;
    q->context = context;
    q->iso_keyboard = iso_keyboard;
    q->callbacks = *callbacks;
    q->user = user;
    if (pthread_mutex_init(&q->lock, NULL) != 0) {
        free(q);
        return NULL;
    }
    q->wake = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!q->wake) {
        pthread_mutex_destroy(&q->lock);
        free(q);
        return NULL;
    }
    return q;
}

void rm_input_free(RMInput *q) {
    if (!q)
        return;
    Command *command = q->head;
    while (command) {
        Command *next = command->next;
        free(command);
        command = next;
    }
    CloseHandle(q->wake);
    pthread_mutex_destroy(&q->lock);
    free(q);
}

HANDLE rm_input_event(RMInput *q) { return q->wake; }

/* Returns the agent sequence, or 0 when an agent command is refused or unallocated. */
static uint64_t enqueue(RMRDPSession *session, Command command) {
    RMInput *q = rm_rdp_input(session);
    pthread_mutex_lock(&q->lock);
    if (command.type == COMMAND_AGENT) {
        if (command.request != q->request || (q->cancelled && command.agent.kind != RMRDP_AGENT_RELEASE)) {
            pthread_mutex_unlock(&q->lock);
            return 0;
        }
        command.sequence = ++q->queued;
    }
    uint64_t result = command.sequence;
    if (command.type == COMMAND_POINTER) {
        command.movement = command.buttons == q->queued_buttons;
        q->queued_buttons = command.buttons;
    } else if (command.type == COMMAND_RELEASE) {
        q->queued_buttons = 0;
    }
    /* Only replace movement with the same button state. Never erase a click,
     * key, wheel, synchronization or release boundary. */
    if (command.type == COMMAND_POINTER && command.movement && q->tail &&
        q->tail->type == COMMAND_POINTER && q->tail->movement) {
        q->tail->x = command.x;
        q->tail->y = command.y;
    } else {
        Command *copy = malloc(sizeof(*copy));
        if (copy) {
            *copy = command;
            if (q->tail) q->tail->next = copy;
            else q->head = copy;
            q->tail = copy;
        } else {
            result = 0;
            if (command.request) q->failed = true;
        }
    }
    SetEvent(q->wake);
    pthread_mutex_unlock(&q->lock);
    return result;
}

void rm_rdp_key(RMRDPSession *s, uint16_t key, bool down) {
    enqueue(s, (Command){ .type = COMMAND_KEY, .key = key, .down = down });
}
void rm_rdp_pointer(RMRDPSession *s, uint16_t x, uint16_t y, uint8_t buttons) {
    enqueue(s, (Command){ .type = COMMAND_POINTER, .x = x, .y = y, .buttons = buttons & 31 });
}
void rm_rdp_wheel(RMRDPSession *s, int32_t vertical, int32_t horizontal) {
    enqueue(s, (Command){ .type = COMMAND_WHEEL, .vertical = vertical, .horizontal = horizontal });
}
void rm_rdp_synchronize(RMRDPSession *s, uint8_t locks) {
    enqueue(s, (Command){ .type = COMMAND_SYNCHRONIZE, .locks = locks });
}
void rm_rdp_release_all(RMRDPSession *s) { enqueue(s, (Command){ .type = COMMAND_RELEASE, .down = true }); }
void rm_rdp_release_human(RMRDPSession *s) { enqueue(s, (Command){ .type = COMMAND_RELEASE }); }

static BOOL send_scan(RMInput *q, unsigned source, UINT32 scan, bool down) {
    if (!scan || scan >= 512) return TRUE;
    const bool previous = q->keys[0][scan] || q->keys[1][scan];
    const bool repeat = down && q->keys[source][scan];
    q->keys[source][scan] = down;
    const bool current = q->keys[0][scan] || q->keys[1][scan];
    if (previous == current && !repeat) return TRUE;
    return freerdp_input_send_keyboard_event_ex(q->context->input, current, repeat, scan);
}

static BOOL send_key(RMInput *q, uint16_t key, bool down) {
    return send_scan(q, 0, rm_rdp_scancode(key, q->iso_keyboard), down);
}

static BOOL send_pointer(RMInput *q, uint16_t x, uint16_t y, uint8_t buttons) {
    static const UINT16 flags[] = { PTR_FLAGS_BUTTON1, PTR_FLAGS_BUTTON2, PTR_FLAGS_BUTTON3,
                                    PTR_XFLAGS_BUTTON1, PTR_XFLAGS_BUTTON2 };
    const uint8_t changed = q->buttons ^ buttons;
    q->x = x;
    q->y = y;
    for (unsigned i = 0; i < 5; i++) {
        const unsigned mask = 1u << i;
        if (!(changed & mask))
            continue;
        const UINT16 down = (buttons & mask) ? (i < 3 ? PTR_FLAGS_DOWN : PTR_XFLAGS_DOWN) : 0;
        const BOOL ok = i < 3
            ? freerdp_input_send_mouse_event(q->context->input, flags[i] | down, x, y)
            : freerdp_input_send_extended_mouse_event(q->context->input, flags[i] | down, x, y);
        if (!ok)
            return FALSE;
    }
    q->buttons = buttons;
    return freerdp_input_send_mouse_event(q->context->input, PTR_FLAGS_MOVE, x, y);
}

static BOOL send_wheel(RMInput *q, UINT16 flags, int64_t value, uint64_t request) {
    /* SDL3 convention: positive vertical is up, positive horizontal is right.
     * Each negative chunk is encoded as a signed nine-bit two's complement. */
    while (value != 0) {
        if (request) {
            pthread_mutex_lock(&q->lock);
            const bool cancelled = q->request != request || q->cancelled;
            pthread_mutex_unlock(&q->lock);
            if (cancelled) return TRUE;
        }
        const int32_t chunk = value > 255 ? 255 : value < -255 ? -255 : (int32_t)value;
        if (!freerdp_input_send_mouse_event(q->context->input, flags | (chunk & 0x1FF), 0, 0))
            return FALSE;
        value -= chunk;
    }
    return TRUE;
}

static BOOL source_pointer(RMInput *q, unsigned source, uint16_t x, uint16_t y, uint8_t buttons) {
    q->source_buttons[source] = buttons;
    return send_pointer(q, x, y, q->source_buttons[0] | q->source_buttons[1]);
}

static BOOL release_source(RMInput *q, unsigned source) {
    BOOL ok = TRUE;
    for (unsigned scan = 1; scan < 512; scan++)
        if (q->keys[source][scan]) ok = send_scan(q, source, scan, false) && ok;
    return source_pointer(q, source, q->x, q->y, 0) && ok;
}

BOOL rm_input_release_all(RMInput *q) {
    const BOOL ok = release_source(q, 0);
    return release_source(q, 1) && ok;
}

uint8_t rm_rdp_input_capabilities(RMRDPSession *s) {
    RMInput *q = rm_rdp_input(s);
    pthread_mutex_lock(&q->lock);
    const uint8_t result = q->capabilities;
    pthread_mutex_unlock(&q->lock);
    return result;
}

uint64_t rm_rdp_agent_begin(RMRDPSession *s) {
    RMInput *q = rm_rdp_input(s);
    pthread_mutex_lock(&q->lock);
    const uint64_t request = ++q->request;
    q->queued = q->submitted = 0;
    q->cancelled = q->failed = false;
    pthread_mutex_unlock(&q->lock);
    return request;
}

uint64_t rm_rdp_agent_send(RMRDPSession *s, uint64_t request, RMRDPAgentEvent event) {
    return enqueue(s, (Command){ .type = COMMAND_AGENT, .request = request, .agent = event });
}

void rm_rdp_agent_cancel(RMRDPSession *s, uint64_t request) {
    RMInput *q = rm_rdp_input(s);
    pthread_mutex_lock(&q->lock);
    if (request == q->request) q->cancelled = true;
    pthread_mutex_unlock(&q->lock);
    (void)rm_rdp_agent_send(s, request, (RMRDPAgentEvent){ .kind = RMRDP_AGENT_RELEASE });
}

int rm_rdp_agent_status(RMRDPSession *s, uint64_t request, uint64_t sequence, bool cleanup) {
    RMInput *q = rm_rdp_input(s);
    pthread_mutex_lock(&q->lock);
    const int result = request != q->request ? -1 : q->failed ? -2 :
                       (!cleanup && q->cancelled) ? -1 : q->submitted >= sequence ? 1 : 0;
    pthread_mutex_unlock(&q->lock);
    return result;
}

static BOOL send_agent(RMInput *q, RMRDPAgentEvent event, uint64_t request) {
    switch (event.kind) {
        case RMRDP_AGENT_SCAN: return send_scan(q, 1, event.scancode, event.down);
        case RMRDP_AGENT_POINTER: return source_pointer(q, 1, event.x, event.y, event.buttons);
        case RMRDP_AGENT_WHEEL:
            return send_wheel(q, PTR_FLAGS_WHEEL, event.vertical, request) && send_wheel(q, PTR_FLAGS_HWHEEL, event.horizontal, request);
        case RMRDP_AGENT_UNICODE:
            /* One scalar is indivisible for cancellation, including both surrogate units. */
            for (unsigned i = 0; i < event.units && i < 2; i++) {
                if (!freerdp_input_send_unicode_keyboard_event(q->context->input, 0, event.utf16[i]) ||
                    !freerdp_input_send_unicode_keyboard_event(q->context->input, KBD_FLAGS_RELEASE, event.utf16[i])) return FALSE;
            }
            return TRUE;
        case RMRDP_AGENT_PAUSE: return freerdp_input_send_keyboard_pause_event(q->context->input);
        case RMRDP_AGENT_RELEASE: return release_source(q, 1);
    }
    return FALSE;
}

void rm_input_discard_pending(RMInput *q) {
    pthread_mutex_lock(&q->lock);
    Command *command = q->head;
    q->head = q->tail = NULL;
    q->queued_buttons = 0;
    q->cancelled = true;
    ResetEvent(q->wake);
    pthread_mutex_unlock(&q->lock);
    while (command) {
        Command *next = command->next;
        free(command);
        command = next;
    }
    // Retain sent keys/buttons so COMMAND_RELEASE can release them after recovery.
}

BOOL rm_input_drain(RMInput *q) {
    pthread_mutex_lock(&q->lock);
    Command *command = q->head;
    q->head = q->tail = NULL;
    ResetEvent(q->wake); /* Enqueuers cannot race the reset. */
    pthread_mutex_unlock(&q->lock);
    BOOL ok = TRUE;
    while (command) {
        Command *next = command->next;
        pthread_mutex_lock(&q->lock);
        const bool skip = command->request && (command->request != q->request ||
            (q->cancelled && command->agent.kind != RMRDP_AGENT_RELEASE));
        pthread_mutex_unlock(&q->lock);
        if (ok && !skip) {
            switch (command->type) {
                case COMMAND_KEY: ok = send_key(q, command->key, command->down); break;
                case COMMAND_POINTER: ok = source_pointer(q, 0, command->x, command->y, command->buttons); break;
                case COMMAND_WHEEL:
                    ok = send_wheel(q, PTR_FLAGS_WHEEL, command->vertical, 0) &&
                         send_wheel(q, PTR_FLAGS_HWHEEL, command->horizontal, 0);
                    break;
                case COMMAND_SYNCHRONIZE: {
                    const UINT32 locks = ((command->locks & 1) ? KBD_SYNC_CAPS_LOCK : 0) |
                                         ((command->locks & 2) ? KBD_SYNC_NUM_LOCK : 0) |
                                         ((command->locks & 4) ? KBD_SYNC_SCROLL_LOCK : 0);
                    ok = freerdp_input_send_synchronize_event(q->context->input, locks);
                    break;
                }
                case COMMAND_RELEASE:
                    ok = command->down ? rm_input_release_all(q) : release_source(q, 0);
                    break;
                case COMMAND_AGENT: ok = send_agent(q, command->agent, command->request); break;
            }
        }
        if (command->request) {
            pthread_mutex_lock(&q->lock);
            if (command->request == q->request) {
                if (!ok) q->failed = true;
                if (!skip && ok) q->submitted = command->sequence;
            }
            pthread_mutex_unlock(&q->lock);
        }
        free(command);
        command = next;
    }
    return ok;
}

typedef struct {
    rdpPointer pointer;
    BYTE *pixels;
} RemotePointer;

static BOOL pointer_new(rdpContext *context, rdpPointer *pointer) {
    RemotePointer *p = (RemotePointer *)pointer;
    if (!pointer->width || !pointer->height || pointer->width > 384 || pointer->height > 384)
        return FALSE;
    p->pixels = calloc((size_t)pointer->width * pointer->height, 4);
    return p->pixels && freerdp_image_copy_from_pointer_data(
        p->pixels, PIXEL_FORMAT_BGRA32, 0, 0, 0, pointer->width, pointer->height,
        pointer->xorMaskData, pointer->lengthXorMask, pointer->andMaskData,
        pointer->lengthAndMask, pointer->xorBpp, &context->gdi->palette);
}

static void pointer_free(rdpContext *context, rdpPointer *pointer) {
    (void)context;
    free(((RemotePointer *)pointer)->pixels);
}

static BOOL emit_cursor(rdpContext *context, RMRDPCursorKind kind, rdpPointer *pointer) {
    RMInput *q = rm_rdp_input((RMRDPSession *)context);
    if (q->callbacks.cursor) {
        q->callbacks.cursor(q->user, kind, pointer ? ((RemotePointer *)pointer)->pixels : NULL,
                            pointer ? pointer->width : 0, pointer ? pointer->height : 0,
                            pointer ? pointer->xPos : 0, pointer ? pointer->yPos : 0);
    }
    return TRUE;
}
static BOOL pointer_set(rdpContext *c, rdpPointer *p) { return emit_cursor(c, RMRDP_CURSOR_IMAGE, p); }
static BOOL pointer_null(rdpContext *c) { return emit_cursor(c, RMRDP_CURSOR_HIDDEN, NULL); }
static BOOL pointer_default(rdpContext *c) { return emit_cursor(c, RMRDP_CURSOR_DEFAULT, NULL); }
static BOOL pointer_position(rdpContext *c, UINT32 x, UINT32 y) { (void)c; (void)x; (void)y; return TRUE; }

void rm_input_register_pointer(RMInput *q) {
    pthread_mutex_lock(&q->lock);
    q->capabilities = (freerdp_settings_get_bool(q->context->settings, FreeRDP_UnicodeInput) ? 1 : 0) |
        (freerdp_settings_get_bool(q->context->settings, FreeRDP_HasExtendedMouseEvent) ? 2 : 0) |
        (freerdp_settings_get_bool(q->context->settings, FreeRDP_HasHorizontalWheel) ? 4 : 0);
    pthread_mutex_unlock(&q->lock);
    rdpPointer prototype = { 0 };
    prototype.size = sizeof(RemotePointer);
    prototype.New = pointer_new;
    prototype.Free = pointer_free;
    prototype.Set = pointer_set;
    prototype.SetNull = pointer_null;
    prototype.SetDefault = pointer_default;
    prototype.SetPosition = pointer_position;
    graphics_register_pointer(q->context->graphics, &prototype);
}
