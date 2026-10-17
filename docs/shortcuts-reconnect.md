# Shortcuts and reconnect

Remora captures keyboard input while a connected session window is key, the app is active, and its desktop is first responder. Command maps to Windows/Super, Control to Control, and Option to Alt. Cmd-Q and Ctrl-Cmd-F stay local. Ctrl-Option-Cmd-Escape releases capture; click the desktop to capture again. Focus loss, a sheet, disconnect, reconnect, and window close remove the tap and release pressed input.

The active head-insert session event tap handles key-down, key-up, and modifier changes through the desktop's existing KeyboardState and sendKey path. AppKit keyboard delivery is skipped while the tap is enabled. Timeout and user-input disable notifications re-enable the tap if the desktop still has focus. Secure Event Input can prevent capture; tap creation failure leaves ordinary AppKit input available.

## Permission

AXIsProcessTrusted checks Accessibility access. The installed SDK's CGEvent.h documents assistive-device access for an active keyboard filter; listen-event preflight checks passive listening access instead. The session banner opens Privacy & Security > Accessibility. "Not Now" persists in UserDefaults as ShortcutCapturePermissionDismissed.

The app checks again on activation and retries creating the tap. The implementation does not require a relaunch when the trust check and tap creation succeed. Granting permission during a running process remains a live verification item; the development app was already trusted. If macOS keeps the old trust result or rejects tap creation after granting, relaunch Remora.

## Reconnect mechanism

AutoReconnectionEnabled is enabled, with a 20-attempt limit. The session thread calls FreeRDP 3.32.2's freerdp_reconnect, preserving the server's auto-reconnect cookie and using FreeRDP's channel disconnect/rebind handling. A small app policy loop delays before attempts by 1, 2, 4, 8, then 10 seconds, capped at 20 attempts per drop. Connection time is additional to those delays. Backoff checks cancellation every 50 ms; in-progress connections use the existing abort path.

client_auto_reconnect_ex was not used because its first attempt is immediate, its delay happens after failure, its sleep does not observe cancellation, and it permits a graphics-subsystem server error. Remora starts recovery only for a transport failure/reset or activation timeout with no server error-info PDU. During recovery, connection refusal and DNS failure can also retry. Authentication, certificate, protocol, intentional server-end, and user-cancel failures stop recovery. An initial connection failure does not start automatic recovery.

SessionState adds reconnecting(attempt: Int), numbered 1 through 20. The C callback struct adds reconnecting(user, attempt). Each successful recovery re-emits connected. Input is gated during recovery, pending input is discarded, and previously sent keys/buttons are released after reconnect before new input. Existing clipboard channel hooks attach to the new channel; lock state and local clipboard text are re-published on connected. The desktop stays mounted under the dimmed reconnect overlay.

GNOME Remote Login 48.1 sends LB_LOAD_BALANCE_INFO without a replacement host. FreeRDP retains the original host and routing token/RDSTLS redirection settings, and freerdp_reconnect reuses them. Remora does not substitute a redirected address or recreate the context. This follows source inspection, not a live interoperability result. Qualify the installed GNOME version with the checklist below.

Source references:

- FreeRDP 3.32.2: client/common/client.c, client_auto_reconnect_do and client_auto_reconnect_ex; libfreerdp/core/connection.c, rdp_client_reconnect and rdp_client_redirect; libfreerdp/core/info.c, auto-reconnect cookie handling.
- [Apple event tap API](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)).
- [GNOME 48.1 server redirection](https://github.com/GNOME/gnome-remote-desktop/blob/48.1/src/grd-session-rdp.c#L299).

## Local shortcut check

The Debug app accepts --shortcut-capture-demo and opens a desktop with a logging session, without connecting to a server. It always removes capture and exits after three seconds. Adding --verify-shortcut-capture posts a Cmd-Tab chord after one second and then removes capture and exits after another half-second. Run it only while nobody else is testing input on this Mac. The verification log must contain one Tab-down and Tab-up pair, Command-down and Command-up, keyWindow=true, active=true, and "capture removed; exiting". If trust or focus is missing, the check reports that it skipped capture and exits.

## Live reconnect checklist

Run this later, after other agents have stopped using the host. No live server connection or firewall change was made for this implementation.

1. Build and open the app. Connect to Windows, open an unsaved document, and record the remote session ID with `query session`. Start continuous visible remote activity so the transport notices a blocked connection. Check typing, pointer buttons, wheel, Caps Lock, and clipboard in both directions.
2. Use a separate local Terminal window. Set HOST to the server's numeric address and CLIENT to this Mac's source address for that route. Confirm `sudo pfctl -sr` contains `anchor "com.apple/*"` before using this anchor. Enable a temporary PF reference with `sudo pfctl -E` and record its Token. Do not reload or flush the main ruleset.
3. Load only the temporary anchor, then kill this host's existing states so established TCP traffic cannot bypass the drop rule:

   ```sh
   printf 'block drop quick from any to %s\nblock drop quick from %s to any\n' "$HOST" "$HOST" | sudo pfctl -a com.apple/remora-reconnect-test -f -
   sudo pfctl -k "$CLIENT" -k "$HOST"
   sudo pfctl -k "$HOST" -k "$CLIENT"
   ```

4. Bring Remora forward. After transport failure is detected, verify that the last frame remains visible and dimmed, the overlay says "Reconnecting...", and Cancel is available. Observe attempts in the SessionWindow log. Attempt 1 waits one second before connecting; later delays are 2, 4, 8, then 10 seconds, plus each connection's duration. Keys and clicks during recovery must not replay later. System shortcuts must act locally during recovery.
5. Before attempt 20, restore connectivity with `sudo pfctl -a com.apple/remora-reconnect-test -F rules`. Release only this test's PF enable reference with `sudo pfctl -X TOKEN`. Verify the overlay disappears, the same unsaved document and Windows session ID remain, frames resume, and typing, modifier releases, pointer buttons, wheel, Caps Lock, clipboard both ways, and system shortcut capture work. Copy fresh local text while disconnected and verify it is offered after recovery.
6. Repeat the drop and leave it blocked through attempt 20. Verify there is no attempt 21 and the existing disconnected view offers Reconnect and Close. Restore the anchor and release the PF token even if a check fails. Verify manual Reconnect works.
7. Repeat once with Cancel during backoff and once with Cancel during a connection attempt. Verify no more attempts follow and the disconnected view appears. Repeat by closing the window during recovery; verify it stays closed and the session thread exits. Other Remora windows must remain usable.
8. Verify deliberate remote logoff, a server-admin disconnect, rejected credentials, and a certificate rejection end the session without automatic retry. Verify an initially unreachable host also uses the existing disconnected view without retrying.
9. Connect through GNOME Remote Login using the original saved host. Complete GDM login and its redirections. Record the remote session identity and open an unsaved document. Repeat steps 2 through 5, then a second drop after recovery. Verify the original host/routing-token path resumes that desktop, avoids repeated credential prompts, and restores frames, input, clipboard, and any Display Control channel. Record the installed GNOME version and any server-side routing-token rejection.
10. With the server connected, verify Cmd-Tab, Cmd-Shift-Tab, Cmd-Space, Cmd-backtick, Ctrl-arrows/Mission Control, Cmd-Shift-3/4/5, Cmd-H/M/W, and ordinary modifier combinations arrive once remotely. Verify Cmd-Q and Ctrl-Cmd-F stay local. Verify Ctrl-Option-Cmd-Escape releases capture until clicking the desktop again. Check focus changes between two session windows and a credential sheet. With Accessibility unavailable, verify normal input still works, system shortcuts stay local, Not Now persists, and granting permission followed by app activation starts capture without relaunch when macOS permits it.
