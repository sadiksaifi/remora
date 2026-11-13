# LAN responsiveness measurements

Six alternating Apple-mode and Screen Sharing pairs ran on 2026-11-13 against the same M3 Pro Mac over Ethernet. The tested application code is `a9a3584`; `e3d5460` adds documentation only. No external native-test process event appeared in any paired round, and no pair was replaced.

The [results and limits](../../../../Vendor/apple-mvs/README.md#responsiveness-on-lan) explain the captured-response metric. [METHOD.md](METHOD.md) preserves the prospective rules with private endpoints and paths removed. `trials.csv` contains all 576 planned and performed observations; `summary.json` records their analysis and source hashes. `environment-validity.csv` records the six independent process-log classifications.

Run `python3 reproduce.py --check` here to recompute every analysis field from the numeric CSV. The inference functions are extracted unchanged from the analysis used for this series. Its command-line filename-prefix guard was adapted from `J` to `Jm` before analysis; no statistical function changed.

Earlier G completed on another LAN interface. H stopped at a Screen Sharing menu that closed before Escape, with no matching external test launch. J stopped on a Remora key that produced no glyph. K stopped on a Remora menu-opening timeout. The latter two incidents and K's earlier menu closures coincided with unrelated native AppKit tests that created key panels on the served Mac. Their raw data are retained privately and are not pooled here. They do not support a general input-reliability claim.

`completion-control.csv` and `completion-summary.json` record the separate one-round-per-client control. [COMPLETION-METHOD.txt](COMPLETION-METHOD.txt) defines its longer settling rule and first-matching-frame metric. Apple mode and Screen Sharing each completed 48 inputs. Standard recorded 47 performed inputs with 46 responses, stopped on a menu-opening timeout, and left one planned reverse unattempted. Its observed menu medians condition on responses. Six image-bearing typing checks are excluded from control timing. This control is not pooled with the paired series.
