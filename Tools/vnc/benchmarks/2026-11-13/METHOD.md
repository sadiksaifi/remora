# Published method

Private endpoint names, identifiers and local paths are removed. Statistical definitions and numeric rules are preserved. Reproduction uses the included numeric trials and analysis code.

Prospective M series, prefix Jm, frozen before Jm1 on 2026-11-13.

The user delegated remaining decisions while asleep. This new series follows an
identified external focus contaminant, rather than a change to latency thresholds:
the served Mac's the unrelated application native AppKit test launches coincide with J4's missing
key, Jk3's menu closures and Jk6's missing menu response. No clean precise type/menu
block overlapped those test runs. H2-S's transient menu had no matching launch and
remains a separate unexplained observation. G/H/J/K data are retained, not pooled.
K remains aborted. No Remora source change follows from these incidents.

Independent environment-validity rule, fixed before collecting M data:
- Before each paired round, a read-only process inventory must show no running
  macos_native_main_thread test binary on the served Mac. Send no input while it runs.
- Record the pair's wall-clock bounds. After each pair, before inspecting latency
  results, query the served Mac's persisted runningboardd log for that test name
  over those bounds, padded by one second. Any matching process event voids the
  entire paired attempt, for either client. Preserve all raw outcomes and the log.
- A voided pair may be repeated once under a fresh attempt label, with at most two
  voided attempts in the whole series. Selection depends only on the remote log,
  never on latency values, semantic results or client identity. A performed-input
  failure without a matching external test event ends this series, without retry.
- There are six valid paired rounds, ordered R then S. Exact attempted labels and
  independent classifications are recorded in the manifest. No heavy analysis or
  scene comparisons overlap measured input. All scene checks finish before the
  next measured block starts. Post-block captures and scene checks remain outside
  timing. No trace or trial-image conversion runs during measurement.

Scene checks compare each client with its first setup. Changes are retained and
reviewed, not latency exclusions. Physical inactivity is assumed, not established.
No unrelated application is quit, no test is killed, and no settings are changed.
Current remote T3 inventory reports no active threads. Last native test ended at
23:39:08 on November12, over40minutes before this series. This method does not
establish input reliability or equivalence. The original point-estimate criterion
and the user-approved trial spread/confidence analysis below remain unchanged.

The six-pair order is Jm1-R,Jm1-S,...,Jm6-R,Jm6-S absent voided attempts.

Inherited statistical and semantic rules follow (J is the producer schema name):

Prospective J-series paired-round analysis

This separate J protocol is fixed before J1. Preserve all G and H raw files and
methods. H was aborted at H2-S menu: forward index 6 recorded an actual menu-body
change at 80 ms, but its settled image returned closed. Reverse index 7 found the
menu already closed and sent no Escape. H's strict method stopped there. H is an
aborted measurement series, not calibration. Do not pool H, G, SYNC-ABBA, or other
diagnostic observations into J. The protocol changes prospectively because an
unperformed input has no latency, while the transient opening did have one.

Run after all performance measurements have stopped:
  python3 reproduce.py --check

Design and measurement configuration

The fixed design is six alternating pairs R1,S1,R2,S2,...,R6,S6. R is Remora Apple
mode; S is macOS Screen Sharing. Both use the same M3 Mac over Ethernet at
[private endpoint]. Keep scene, geometry, type/scroll settings and menu-body ROI unchanged
from the H specification. Menu ROI is 130,90,400,480 (x,y,width,height), threshold
125 changed samples, sample step 2; right/bottom are 530/570. It excludes File's
title highlight and the parked pointer. Separate image calibration precedes the
timing series. Trial-image saving stays off during J. Build/network/scene identity
and calibration remain independently documented by the operator.

There are exactly 36 files J{1..6}-{R,S}-{scroll,type,menu}.trials.jsonl. Each has
16 planned rows, indexed 0..15 in order, alternating forward/reverse, eight each.
All 576 planned rows remain in the audit. There are no retries, replacement rows,
optional extra rounds, or post hoc exclusions of slow/partial/transient responses.
Each action/direction/client/round must have at least one performed input; otherwise
conditional inference stops rather than imputing zero or dropping that round.

Producer schema and fatal validation

Every row explicitly records inputSent as a Boolean. Normal performed rows require
inputSent=true, status=observed_change, and a finite nonnegative latencyMS.

The only allowed nonperformed outcome is a menu/reverse row with:
  status="menu_already_closed"
  inputSent=false
  latencyMS/inputTicks/observedTicks null or omitted
  numeric 0 <= reversePreInputDeltaSamples < threshold (threshold remains 125)

The producer observes that closed precondition before posting any Escape, consumes
the planned index, clears its prior forward reference, and proceeds to the next
planned forward row. It sends no input for that row and does not retry it. This is
a workflow outcome, never a latency success, timeout, zero, or censored latency.
Only that semantic NA is permitted. Every other invalid status or malformed row,
missing file/planned trial, index/direction error, or inconsistent NA field is fatal
for all latency inference. Unexpected numbered J-series files are also fatal.

Every actual performed latency is retained, including a forward menu opening whose
settled image is closed. Such an opening must still report at least 125 first-change
body samples and parseable changedBounds entirely in x130..<530,y90..<570. Its
settledChangedSamples <125 outcome is counted separately as forward_settled_closed;
it is not removed from latency metrics. Missing persistence guards are reported.
Type insertion/deletion guards, when present, remain enforced: settled insert
change >= threshold and deletion roundTripResidualSamples < threshold. Performed
menu reverse cannot have a closed precondition. When shared timing fields are
complete for performed inputs, check alternating nonoverlapping block chronology.

Separate workflow reporting

For every client-round, report planned 16 rows, actual inputs performed, valid
latency N, closed-precondition NA count/rate out of eight planned reverse rows,
and transient-open count/rate out of eight forward rows. Also report client totals
over all six rounds and all raw status/guard counts. No missing/NA observation is
imputed. These counts describe workflow reliability separately; the conditional
latency tests below do not establish workflow reliability or equivalence.

Latency estimands and original summaries

All statistics condition on performed inputs. In particular, menu reverse latency
conditions on the menu being open when the reverse precondition was checked. If
that condition differs between clients, report the different denominators and
outcome rates rather than treating the conditional samples as workflow parity.

Primary metrics remain unchanged: scroll pools both performed directions; type
uses forward insertion; menu uses forward opening. Compute each client's median
within each round and then the median of its six round medians. The original
point-estimate criterion remains Remora minus Screen Sharing <=10 ms. Report each
round median, population SD of those six medians, and the historical literal SD
comparison descriptively. It is not an automatic variability gate. Also report
pooled performed-input medians, ranges and confidence intervals. Six separate
action/direction cells retain all their actual performed input latencies.
Quantiles use inclusive/type-7 interpolation at (N-1)*p. IQR is Q75-Q25.

Single global spread test

For each cell, pool the performed latencies from all six rounds per client. Let r
and s be their IQRs. Contrast=2*(r-s)/(r+s), or zero if both are zero. Global T is
max(0, all six contrasts). Larger values favor increased conditional Remora spread.

Enumerate all 2^6=64 paired label assignments. In each round pair keep or swap the
entire client datasets, including performed-input subsets and NA patterns, using
the same swap for all actions/directions. Preserve within-round/cross-cell
dependence and recompute pooled IQRs and global T. The exact one-sided p is the
fraction of all 64 values >= observed (ties included, tolerance 1e-12). Include
the observed assignment; no Monte Carlo +1 correction. Report the one global test
at alpha .05. Per-cell IQR-difference p values are nominal descriptive values only,
not familywise claims. There is no Holm gate or overall variability PASS from
non-rejection. Numerical latency and spread rules are unchanged from the frozen
H statistical plan; only the prospective workflow/NA handling changes.

The permutation calculation assumes joint R/S label exchangeability within each
pair under the null. Preserving dependence does not establish exchangeability.
Fixed order, drift, carryover and client-specific selection by the open precondition
can undermine its interpretation. This is not a causal guarantee or a test justified
solely by equal IQRs. The p-value grid is 1/64 with only six pairs.

Confidence intervals

Use exactly 20,000 paired-cluster bootstrap draws with random.Random seed 6820261112.
Each draw selects six whole round-pair indices with replacement. Keep both clients,
every action/direction, performed-input subset and NA pattern together. No
independent within-round trial resampling. Recompute conditional pooled median/IQR
differences and primary median-of-round-medians/pooled-median differences. Report
pointwise 2.5th/97.5th percentile intervals using inclusive interpolation. Caching
repeated index multisets does not change their sampled multiplicities.

Only six paired clusters are available. Bootstrap coverage may be poor and assumes
representative independent paired rounds. Intervals are pointwise, not simultaneous.
Non-rejection, an interval crossing zero, or similar point estimates do not prove
equivalence, parity, absence of increased spread, or workflow reliability. No new
equivalence margin or automatic passing criterion is invented.

Execution and audit

This script/method is prepared without reading J data or running a large bootstrap
during operator timings. --self-test uses only tiny synthetic examples and three
bootstrap draws. Actual analysis writes JSON/text under [private path] and
records source/method and every raw input hash. H tools/method/data remain unchanged.
