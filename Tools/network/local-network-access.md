# Local network access

Remora cannot repair a macOS network-policy decision. It can report a confirmed
Local Network denial, offer recovery steps, and avoid treating every unreachable
host as a permission denial.

## Investigation of issue 83

On November 13, 2026, macOS 27.0.1 (26A434) rejected Remora's LAN TCP connections
before sending a SYN. The retained kernel log records `reason: NECP`, error 65
(`EHOSTUNREACH`), and `SYN in/out: 0/0`. The permission log also records
`Local network allowed by preference for Remora`. LAN VNC and RDP failed while
the corresponding Tailscale connections worked. Quitting Remora, turning its
Local Network access off and on, and reopening it restored LAN access without a
new prompt.

These observations establish an outbound policy rejection. They do not identify
the policy that rejected the sockets or explain its disagreement with the saved
permission. They do not establish that the app update or duplicate Remora entries
caused the failure. The saved records referenced two older development copies.

The issue records an Apple Development signature at the time of failure. A
read-only check on November 14 found the currently installed app was instead ad
hoc signed, with no team identifier and a designated requirement containing only
its code hash. That later observation does not establish the earlier cause.
Apple-issued signing remains necessary for reliable app identity across builds.
`mise run build` now verifies an Apple-issued signature as well as signature
integrity. Plain `codesign --verify` alone accepts ad hoc signatures.

## Connection behavior

Both protocol engines use BSD sockets. After a timeout or unreachable-host
failure, Remora closes the protocol transport and makes one Network.framework
TCP attempt to the last failed socket's numeric address and port. A hostname's
aggregate path can report satisfied even when its resolved address paths are
denied; the native bridges retain the concrete endpoint to avoid that ambiguity.
If no concrete endpoint was retained, the check uses the configured host. It
sends no protocol data and cancels the
diagnostic connection on completion, cancellation, or its two-second deadline.
Successful sessions, authentication failures, certificate rejections, missing
hosts, and refused connections do not run this check.

`NWPath.UnsatisfiedReason.localNetworkDenied` changes a transport failure to Local
Network Access Denied. VNC also preserves `kDNSServiceErr_PolicyDenied` from
DNS-SD setup, callbacks, and result processing as a confirmed denial during name
resolution. Genuine missing-host errors keep their existing classification. A ready
diagnostic connection does not prove that the
original socket was allowed, and an inconclusive diagnostic leaves the original
failure intact. The diagnostic state and path are logged under the
`NetworkAccess` category with a unique attempt identifier.

The session view offers Open Privacy & Security Settings for a confirmed denial or an
unexplained timeout. The error text also carries the recovery steps to CLI
clients. A timeout explicitly leaves network, VPN, firewall, and remote-computer
failures as possible explanations. Reconnect creates a fresh attempt after the
user changes settings. Remora does not reset system policy, change the user's
permission, use a privileged helper, or bypass Local Network privacy.

## Recovery and distribution checks

Allow Remora in System Settings > Privacy & Security > Local Network. If access
is already enabled but LAN connections fail, quit Remora, turn its access off
and on, then reopen it and reconnect. This recovery worked in the reported case;
it is not a guarantee for every network failure. Check host availability,
routing, VPNs, and firewalls if the failure persists.

Before distributing an app update, verify the exact app being copied:

```sh
codesign --verify --deep --strict -R='anchor apple generic' /path/to/Remora.app
codesign -d -r- /path/to/Remora.app
codesign -dv --verbose=4 /path/to/Remora.app
dwarfdump --uuid /path/to/Remora.app/Contents/MacOS/Remora
```

Compare the signing team and designated requirement with the previous build.
Keep the bundle identifier and signing identity stable. Ensure the main executable
has a unique UUID. Use one installed copy when checking update behavior.

Apple's [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
documents signature-based identity, complications from multiple copies, the lack
of a general permission-query API, and endpoint-specific denial detection with
`NWConnection`. It does not establish the cause of this incident.

## Live verification on November 14

An Apple Development-signed Debug build launched through Launch Services
reproduced the failure with an isolated connection store. The saved LAN VNC
hostname failed with error 65. The diagnostic attempt to the retained numeric
address reported `unsatisfied (Local network prohibited)` and the app and CLI
reported Local Network Access Denied. All three Remora entries in System Settings
were enabled. No permission setting was changed.

Before retaining the numeric address, the hostname-level diagnostic reported a
satisfied aggregate path while Network.framework logged prohibited paths for its
resolved IPv4 and IPv6 addresses. This observation is why the diagnostic uses
the failed socket's concrete endpoint.

The saved Tailscale VNC and RDP connections both reached connected state and
produced screenshots. The RDP screenshot showed the remote Debian login screen.
Windows was unavailable. The original installed app and live connection store
were not changed. Recovery by toggling permission was observed in the original
incident and was not repeated during this verification.

## Verification limits

Automated checks cover conservative classification, cancellation, retaining the
numeric endpoint, and closing the diagnostic socket without sending protocol
data. A child-process DNS-SD fixture verifies that explicit resolver denials reach
the public VNC session event stream while genuine missing-host errors stay intact.
Reproducing the saved
permission/policy disagreement requires macOS state that is not controlled by the
test suite. Do not infer that this check repairs that state or guarantees that a
future app update cannot encounter it.
