# Client-aware, band-aware coverage planning (design, for the owner's review)

Status: **proposed, 2026-11-11. Build nothing from this until the owner approves it.** Written on the owner's request of 2026-11-11, after
the review in `docs/research/REVIEW-AND-ENRICHMENT-2026-11.md` (PR #100, ideas B1, B5, B7 and Q5). It extends `docs/design.md` (sections 3
and 4: the engine) and `docs/design-standalone-app.md` (where the engine runs). Where this document says "today" it describes the engine
at `main` after #99 and the Q1 to Q3 fixes of the review (#101 to #103). Every example is synthetic; no house data is used.

Numbers in this document are of three kinds, and the tables say which: **sourced** (a spec sheet or a regulation, with its URL),
**assumed** (a starting value I chose, to be replaced by a sourced or measured one), and **owner** (only the owner can say).
Nothing here is a measurement.

## 1. The question the owner wants answered

The owner has bought: an ASUS ROG Wi-Fi 7 router (exact model unknown to me) with an **Ethernet backbone to three ASUS ZenWiFi ET9
nodes** (Wi-Fi 6E tri-band). They may buy more ET9s and want to see **what each extra one buys**, for the devices they actually use, in the
places those devices actually are, on the bands those devices actually need.

That asks the engine for six things it does not do today:

1. Treat a client as a **class with both link directions**: a link works only as far as the weaker of downlink and uplink.
2. Score **each band** (2.4, 5, 6 GHz) against what a device needs, not only "the best band".
3. Put nodes on **specific Ethernet jacks**, with wired backhaul, and keep the existing nodes where they are.
4. Score **pinned devices and must-cover spots** pass or fail, plus a background whole-house score for a generic phone.
5. Show results **per node count** (existing nodes + 0, 1, 2, ... added) side by side, which shows diminishing returns only if more nodes
   is **not free**: it needs a self-interference and channel model.
6. Plan with **the owner's real gear**, from a catalogue with sourced values and "assumed" flags, including 6 GHz and Wi-Fi 7.

## 2. What the engine does today (facts, with where to look)

| Area | Today | Where |
|---|---|---|
| Client | A client has `chains`, `max_width`, `standard`, `ant_gain_dbi` per band and one `noise_figure_db`. **No transmit power.** | `homemesh/equipment.py` (`Client`, `ClientRadio`), `core/Sources/HomemeshCore/Equipment.swift` |
| Access link | Computed **downlink only**: node `tx_dbm + ant_gain` plus the client's gain, minus path loss and the shadowing margin, over the client's noise floor, then through the MCS table. | `homemesh/network.py` `access_rate` (lines 192-205) |
| Band choice | Per cell, the **best rate over all nodes and radios** ("a client uses the band with the best throughput"). The model keeps no per-band answer. | `homemesh/network.py` `evaluate`; `docs/design.md` 3.5 item 4 |
| Backhaul link | Already uses the **weaker direction** (`min(r_down, r_up)`) for node-to-node wireless links. Clients do not. | `network.py` `link_rate` (lines 208-226) |
| Widths | Capped at 20 / 80 / 80 MHz for 2.4 / 5 / 6 GHz regardless of what the radios and the client support. Standards stop at `ax`; MCS at 11. | `network.py` `BAND_WIDTH_CAP`, `rates.py` |
| Zone need | `Need` has `min_rssi`, `min_throughput`, `max_latency`, `band_pref`, `must`, `rx_height`. **`band_pref` and `max_latency` are stored and used by nothing.** A zone is an area, scored as a mean utility, and a `must` zone is met when 90 % of its cells reach the target at the margin. | `homemesh/model.py:211`; `network.py` `zone_scores` |
| One client | A plan uses **one** client profile for the whole house (`phone-2x2-ax` or a generic 1x1 laptop). | `LocalAPIPlans.swift` `makeContext` |
| Spots | Candidates are a grid inside allow zones, plus any jack inside an allow zone ("it may be a wired spot"). A node within 0.6 m of a live jack gets a **wired** uplink at the jack's rate through the switch chain. | `planner.py` `candidates`; `network.py` `wired_at` |
| Wired parity | The golden vectors contain **no wired backhaul** (`jacks_used` is always empty; "unknown jack trusted" equals "untrusted"). The wired chain, the brief's "wired where a jack allows", has **no cross-engine test**. | review 2.2 item 2 |
| Existing nodes | A plan has one gateway (at the internet entry) and `k` added nodes. There is **no way to say "these three nodes already exist, here"**. An `access_point` list exists for calibration but is not part of an arrangement. | `Placement`, `planner.search` |
| Interference | None. `docs/design.md` 3.5 specifies self-interference and a channel plan; neither was built. A node added anywhere can only raise a cell's best rate, so **more nodes is never worse** and the cost term alone stops the search. | `network.py` `evaluate` |
| Catalogue | Three generic devices with invented numbers. The Swift side has no loader; plans always use `Catalogue.generic()`. | `equipment.py`, `LocalAPIPlans.swift:35` |
| Scores | A zone score is a mean **utility** (a number between 0 and 1); `must` is the only pass/fail and it is per zone, not per device. | `zone_scores` |

The rest of the engine (multi-wall propagation, calibration, the planner's exhaustive / greedy / swap search, explanations) stays; this
design changes how a client, a band, a spot and a node count are modelled and shown.

## 3. Client classes with both link directions

### 3.1 The rule

A client link carries traffic in two directions that do not have the same budget. Downlink is limited by the node's transmit power and
the client's receiver; uplink by the **client's** (much smaller) transmit power and the node's receiver. For a cell *c*, band *b*, node *n*:

```
rssi_down = node_tx_dbm + node_ant_gain_dbi + client_ant_gain_dbi - (loss + margin)
rssi_up   = client_tx_dbm + client_ant_gain_dbi + node_ant_gain_dbi - (loss + margin)
snr_down  = rssi_down - noise(width, client_noise_figure)
snr_up    = rssi_up   - noise(width, node_noise_figure)
rate_down = throughput(snr_down, standard, width, streams_down)
rate_up   = throughput(snr_up,   standard, width, streams_up)
```

**Range is the weaker of the two.** A cell is *connected* on a band only if both `rate_down` and `rate_up` clear the minimum MCS, and the
link's usable rate for a device is `min(rate_down / need_down, rate_up / need_up)` against what the device asks for in each direction
(section 6). `streams_down` and `streams_up` are each `min(node chains, client chains)`; a 1x1 IoT sensor has one stream either way.
The backhaul rule already works this way (`link_rate`); this brings the access link in line with it.

Rules that carry over unchanged: the shadowing margin applies to both directions; the same propagation model is used for both
(reciprocity); calibration still fits one set of path-loss parameters per band.

### 3.2 Client classes

A **client class** is a catalogue entry (section 8), not a hard-coded list. The classes the owner described, with the values the engine
needs. All numeric starting values are **assumed** (the Client record's `assumed` flag is true) and are placeholders until sourced from a
spec sheet or measured with the owner's own devices; none is a claim about a product.

| Class | Examples | Bands | Chains | Client tx (assumed start) | Antenna gain (assumed) | Notes |
|---|---|---|---|---|---|---|
| `fixed-2x2` | Apple TV, console, desktop | 2.4 / 5 / 6 per device | 2 | high end of its range (plugged in, a bigger antenna) | 0 to 3 dBi | stationary: the margin can be smaller (open question) |
| `laptop-2x2` | laptops | 2.4 / 5 / 6 | 2 | middle | 0 to 2 dBi | |
| `phone-2x2` | phones, tablets | 2.4 / 5 / (6) | 2 | lowest of the three (battery) | about 0 dBi | the generic background client |
| `iot-1x1-24` | sensors, plugs, cameras | **2.4 only** | 1 | low | about 0 dBi | cannot use 5 or 6 GHz at all |

For each radio of a class the entry records: `tx_dbm` (conducted, per the sourced regulation cap or a measured value), `ant_gain_dbi`,
`chains`, `max_width`, `standard` (`n`, `ac`, `ax`, `be`), and `noise_figure_db`. A device may support fewer bands than its class: the
pin (section 6) names the exact band set.

### 3.3 6 GHz

On 6 GHz at low power indoor (LPI), the client is permitted about **6 dB less** than the access point (the owner's figure; the
regulation's exact EIRP and power-spectral-density limits per width are a **sourced** value to be looked up for the owner's region, D13, and
recorded in the catalogue with their URL; I do not state them here). Two modelling consequences:

- A 6 GHz client cap is a **separate, lower** `tx_dbm` in the client's 6 GHz radio, so the model does not need a special case: the uplink
  budget falls out of the numbers in 3.1. The same entry also caps the **node's** EIRP by channel width (a wider channel spreads the same
  limit over more bandwidth), which is why `BAND_WIDTH_CAP` stops being a constant and becomes a function of region and equipment.
- 6 GHz also has the highest path loss and the least penetration, so it is the band where the uplink limit shows first. The design
  intends the planner to say so: "this spot is downlink-fine and uplink-limited on 6 GHz".

### 3.4 Wi-Fi generation

The owner's router is Wi-Fi 7 and the ET9 is Wi-Fi 6E. The engine's standards stop at `ax`. To plan honestly for the router's own
radios, the rate model gains `be` (320 MHz on 6 GHz, 4096-QAM / MCS 12 and 13) and a **first-order** multi-link rule (section 8.3). A
client can only use what it supports; the ET9 nodes are the limit on every ET9-served cell, and the router's Wi-Fi 7 features matter only
for cells the router itself serves. The design says this in the results so the owner does not credit the ET9 nodes with Wi-Fi 7 speeds.

## 4. Per-band requirements

Today a requirement is "this zone wants 400 Mbit/s" and the best band wins. The owner's devices have band needs: a console on Ethernet-like
5 or 6 GHz, a sensor on 2.4 GHz only, a laptop that should be on 6 GHz for the speed. So the evaluation keeps **a result per band**:

```
for each cell and band b in {2.4, 5, 6}:
    serving node, rssi_down, rssi_up, snr_down, snr_up, rate_down, rate_up, usable (both directions connected)
```

A requirement (section 6) names the **bands the device may use** (a set) and asks for the best of those:
`required rate = max over allowed bands of min(rate_down, rate_up scaled)`. "Any band" is the set {2.4, 5, 6} limited by the class's
support, which reproduces today's behaviour for the background phone score. The results for a pinned device show the **band matrix**
(section 6.4), so the owner sees "2.4: fine, 5: fine, 6: not reached".

Not modelled, stated so the owner is not misled: how a router *decides* which band a client joins (band steering, roaming thresholds,
"smart connect"). The model says what each band could deliver; the assumption that a client sits on a band that works is a stated
simplification. A pin that must be on 6 GHz is checked on 6 GHz whether or not the router would steer it there.

## 5. Candidate spots as Ethernet jacks, with wired backhaul

### 5.1 Spots

The owner's nodes are wired, so a node can sit **only where there is a jack** (or a place the owner is prepared to run a cable to; section
13). `Zone.requires` already exists (`outlet`, `poe`, `none`); this design adds a plan-level **spot policy**:

| Policy | Candidates | Use |
|---|---|---|
| `jacks` | the live and the "unknown, if it works" jacks only | the owner's case: the wiring is fixed |
| `zones` | the grid in the allow zones, as today | "where would a node ideally go" |
| `both` | jacks first, grid spots marked "needs a cable here" | to show what a new run would be worth |

A jack candidate carries its jack id, its rate (`measured_rate`, else the cable type's conservative rate) and the switch chain that
reaches the entry. The result lists "node 2 on jack J7 (verified)" and keeps the existing "which unverified jacks the plan depends on".

### 5.2 Wired backhaul is a prerequisite (Q5)

The wired path (`wired_at` / `Backhaul.wiredAt`, the switch chain, `trust_unknown_jacks`) is the heart of this plan and **has no
cross-engine test today**. Before any of the new model is built, the vectors gain the cases the review named (idea Q5):

- a node on a jack whose switch chain reaches the entry (rate = the minimum along the chain), a chain through two switches, a dead
  uplink, an unknown jack trusted and untrusted (the two runs must **differ**), a jack in a forbidden zone;
- the greedy search (a case large enough to pass `exhaustive_limit`), two floors, an invalid arrangement (system limits), a price
  ceiling, a 6 GHz radio.

This may reveal real differences between Python and Swift; that is the point, and each is fixed in whichever engine is wrong. Only then
does the new model start, so that its vectors rest on a checked wired path.

### 5.3 Existing nodes are fixed

An arrangement gains a list of **installed nodes**: equipment, position or jack, level, height, and `fixed: true`. The planner never
moves or removes them; it only adds. The router is the gateway at the internet entry (already so). The three ET9s are installed nodes on
their jacks. A plan is then "installed + `a` added", with `a` = 0, 1, 2, ...; `a = 0` is the **baseline** (section 9).

## 6. Pinned devices and must-cover spots

### 6.1 The pin

A **pin** is a fixed device or a spot that must work:

```
pin: id, name, level, position, rx_height,
     class            (a client class: fixed-2x2, laptop-2x2, phone-2x2, iot-1x1-24, or a custom entry),
     bands            (the set it may use: e.g. {5, 6}, or {2.4} for an IoT sensor),
     min_down, min_up (Mbit/s; min_up defaults to a small value, and a streaming box needs almost none),
     must             (true: the plan fails if this pin fails; false: scored, not required)
```

Pins are stored in the house document (the owner's D6 list: "the TV in the living room needs 100 Mbit/s on 5 or 6 GHz"). A pin on a
spot where nothing is installed yet (a future desk) is the same record. Zones keep working as before for areas; a pin is for a place a
device actually sits.

### 6.2 Scoring a pin: pass or fail

For a pin, at its position and `rx_height`, using the **margin** (the robust run), for each allowed band:
`pass` if the link is connected in both directions and `rate_down >= min_down` and `rate_up >= min_up`. The pin passes if **any allowed
band** passes; the result records which band, which node serves it, and the headroom (rate over need). A point is sensitive to one cell's
noise, so the check takes the **worst of the receive cell and its neighbours within 0.5 m** (a stated, tunable choice, the same idea as
the 90 % rule for zones).

### 6.3 The whole-house background score

The existing whole-house utility, for the generic `phone-2x2` client and "any band", is kept as the **background** score. It answers
"is the rest of the house fine", and breaks ties between arrangements that pass the same pins.

### 6.4 The order that ranks arrangements

1. every `must` pin passes (an arrangement that fails one is ranked below any that passes all, as `must_ok` works today);
2. the number of non-`must` pins that pass;
3. the background score;
4. cost.

(Today's order is valid, must, score, margin score, cost; this inserts pin counts before the background score.) The result view for a
plan shows a **pin x band matrix** (rows: pins, columns: 2.4 / 5 / 6, each cell "ok 640" / "uplink-limited 18 < 25" / "no signal"), then
the background map. The explanation module gains the new limiter names: `uplink`, `downlink`, `band not offered`, `backhaul`.

## 7. Results per node count, and the interference model that makes them honest

### 7.1 The comparison

For the installed nodes plus `a` = 0, 1, ..., `a_max` added ET9s, the planner returns the **best arrangement for each `a`**, side by side:

| Added | Must pins pass | Pins pass | Background | Worst pin headroom | Cost | Gain over the previous row |
|---|---|---|---|---|---|---|
| 0 (what you have) | 4 of 6 | 7 of 10 | 0.62 | -32 Mbit/s | 0 | n/a |
| 1 | ... | ... | ... | ... | one ET9 | ... |

(Illustrative layout; no real numbers.) The "gain" column and a one-line verdict ("the third added node improves the background score by
0.01 and no pin") state diminishing returns in words. The search already iterates node counts (`k` from 1 to `k_max`); what changes is
that **the best for each count is kept and shown**, `a = 0` is always included, and the equipment for added nodes is the owner's chosen
model (the ET9) rather than every catalogue entry.

### 7.2 Why that needs the interference model (B7)

With the engine as it is, a cell's rate is the best over nodes, so an added node **cannot lower** any cell; the table would say "more is
always better" and cost would be the only brake. In a real house, nodes on the same channel hear each other, reduce each other's
signal-to-interference, and share airtime. The design therefore builds, **in Python first (the oracle), then Swift**:

- **Channel plan per band.** 2.4 GHz: channels 1 / 6 / 11. 5 GHz: the non-overlapping channels the region and width allow. 6 GHz: the
  region's channels at 20 to 160 MHz (and 320 MHz for Wi-Fi 7). The planner assigns channels by a simple reuse rule (a greedy colouring
  that puts the nodes that hear each other most on different channels), because the ET9s choose their channels automatically; the model
  assumes a **good** plan, and a switch lets the owner see a worse one.
- **Co-channel interference.** For a cell served by node *n* on channel *k*, the noise floor rises by the power received from every
  other node on channel *k* times an **activity factor** (assumed 0.2, a calibration parameter). SNR becomes SINR. This is what
  `docs/design.md` 3.5 already specified.
- **Airtime sharing.** Nodes within carrier-sense range on one channel share airtime for access traffic as the code already does for a
  shared backhaul radio. Ethernet-backhauled nodes use no airtime for backhaul, which is exactly why the wired design matters.
- **Out of scope for the first version, stated:** neighbours' networks (a background noise-floor offset per band remains the only
  handle), client counts per node, roaming costs, DFS channel loss.

The consequence the owner should see: past some count, a node on a free channel still helps a distant pin, but a node placed among
others on the same channel can lower the background score, and the table says so. That is also the main sanity check on the model
(section 10).

### 7.3 Compute cost

Pins are points, so their per-arrangement cost is small next to the grid; the grid (background) is the expensive part and the existing
caches stay. With 3 installed nodes, a few jack candidates, and `a_max` of 3 or 4, exhaustive search is tiny (combinations of a handful
of jacks). The channel plan adds a small inner loop per arrangement. The review's runtime concern (B8) is not a blocker for this case,
and the design does not depend on it.

## 8. A catalogue seeded with the owner's gear (B1)

### 8.1 Where it lives

`catalogue/*.json` is bundled with the app as a resource and loaded by a Swift loader (the Swift side has none today); the owner's own
entries and measured figures are added in the app, stored with the house or the app data (never in git), exported with the house, and
**win over the public entries on an id clash**, as `catalogue/README.md` already says. Every public entry names its `sources`; every
number not taken from a source carries `assumed: true` and the app shows the flag.

### 8.2 The schema additions

Equipment: `wifi` generation per radio (`ax`, `be`), 6 GHz radios, per-width EIRP caps by region, `ports` with real rates, `noise_figure_db`
(for the uplink budget), `backhaul` options (wired, wireless on which radio), `mlo` capability. Client classes move from the two
generic entries to catalogue records with per-radio `tx_dbm` and `assumed`. A custom device entry is the owner's way to say "my laptop
is 2x2 and supports 6 GHz".

### 8.3 Wi-Fi 7 and multi-link, first order

Add MCS 12 and 13 and 320 MHz for `be`. Multi-link operation (a client using two bands at once) is **not** modelled as a rate sum
without a source; the first version takes the better single link and reports "multi-link could add up to the second band's rate", marked
assumed, because real gain depends on the client and the AP and few clients support it. A decision for the owner (section 13).

### 8.4 The owner's equipment, as I can state it

| Item | Known | Source | Unknown, to be confirmed by the owner |
|---|---|---|---|
| ASUS ROG Wi-Fi 7 router | the owner says it is Wi-Fi 7 | owner | **the exact model** (it sets bands, 6 GHz and 320 MHz support, chains, power, ports); until then the entry is `owner-rog-router`, every radio `assumed` |
| ASUS ZenWiFi ET9 | tri-band Wi-Fi 6E; 160 MHz on 5 and 6 GHz; selectable wired or wireless backhaul; a 2.5 Gbit/s WAN port; the 3-pack lists three 1 Gbit/s LAN ports | ASUS product page: `https://www.asus.com/networking-iot-servers/whole-home-mesh-systems/asus-zenwifi/asus-zenwifi-et9/` and a retailer listing (Newegg 3-pack, `N82E16833320602`); the ASUS techspec page snippet was incomplete when I looked and must be read in full | chains per band, antenna gain, conducted power per band, whether 2.5 G is available on a LAN port for backhaul (retailer says 3 x 1 G LAN, which would cap the wired backhaul at 1 Gbit/s), which radio carries wireless backhaul |

I did not find antenna counts, per-band transmit power or antenna gain in the sources I could open. The first catalogue PR therefore
marks every ET9 radio figure `assumed` and carries a visible table of the values it assumed (copied from the generic tri-band entry, not
from ASUS), each with the line to replace once the owner reads the spec sheet or measures. The entry says "assumed" loudly rather than
carrying a quiet guess.

## 9. The baseline and a plan to act on (B5)

- **Baseline.** The installed setup (router + 3 ET9 on their jacks, with whatever channels) is evaluated as the row `a = 0` of every
  result, so every number is relative to what the owner has: "today the study desk fails by 31 Mbit/s; with one more ET9 on jack J7 it
  passes". If the owner's calibration readings exist, the baseline is the check that the model agrees with the house (it should
  reproduce the readings; that is the calibration's job, and a baseline that disagrees tells the owner not to trust the rest yet).
- **The plan to act on.** A one-page summary of the chosen row: where each added node goes (a plan picture with the jack named), what to
  plug into which jack, which unverified jacks to test first, which pins pass and fail and by how much, what was assumed (every
  assumed catalogue value that the result depends on, listed). The summary contains the house layout, so it is produced and shared
  only by the owner's own action.

## 10. Rule-of-thumb ranges: sanity checks, never the model

The planner computes everything from the link budgets of section 3 and the house's walls. Common ranges ("2.4 GHz reaches farther
than 5, which reaches farther than 6", "each interior wall costs a few dB", free-space loss at 1 m is about 40 dB at 2.4 GHz and about
47 to 48 dB at 5 to 6 GHz) are used **only as tests of the output**:

- Under identical walls, the coverage radius at a given rate is ordered 2.4 > 5 > 6.
- An uplink-limited cell exists on 6 GHz for a phone class before a downlink-limited one does.
- Adding a node on a channel unused nearby never lowers any cell it does not serve; adding one on a shared channel may.
- A zero-wall open room's rate falls monotonically with distance.

If a sanity check fails, the model is wrong (or the check is); a range is never substituted for a computed value.

## 11. Plan, in order, with what each step checks

All steps follow the project's rules: one PR per piece, `./scripts/verify` and `dev check .`, CI before merging. **Python first, then
Swift, with golden vectors** (open question 13.9: whether Python stays the oracle for these).

| Step | Change | Check |
|---|---|---|
| 1 | Q5: the vector gaps listed in 5.2 (wired chains, greedy, two floors, invalid, 6 GHz) | vectors regenerate; Swift agrees or one engine is fixed |
| 2 | Installed (fixed) nodes in an arrangement; `a` = 0 baseline; jack spot policy | golden cases; baseline equals today's evaluation with the same nodes |
| 3 | Client classes with `tx_dbm`; both directions; per-band results kept; the 6 GHz client cap; `be` rates | per-direction golden cases; sanity checks of section 10 |
| 4 | Pins: pass / fail, band matrix, new ranking order, new limiter names | golden cases for each pass and fail reason |
| 5 | Interference: channel plan, SINR, airtime | golden cases; "more nodes is not free" test |
| 6 | Catalogue: Swift loader, owner's entries, seeded ROG and ET9 with sources and `assumed` | decode tests; the assumed-value list is shown |
| 7 | App: pins UI (per room), the per-node-count comparison view, the baseline row and the plan summary | **device and screenshot checks only the owner or CI can give** |
| 8 | (Optional) calibration route (B2) to test the model against the owner's real readings | the baseline reproduces the readings |

Steps 1 to 5 are engine work I can verify on Linux; steps 6 and 7 need the macOS CI build and the owner's phone.

## 12. Risks

- **The model gets more parameters than anyone has measured** (client tx power, activity factor, noise figures). Mitigation: every one
  is a named, flagged parameter; calibration (B2) is the way to test them; results list the assumed values they depend on.
- **A wrong spec misleads more than a generic one.** The ROG model is unknown and the ET9 chains and powers are not in the sources I
  opened. The seeded entries say "assumed" until confirmed.
- **Uplink is dominated by a number I do not have** (the client's transmit power). The class defaults are a starting point; the owner's
  own devices could be measured with a hand-held Wi-Fi tool, or left as stated.
- **Band steering is not modelled** (section 4); a device might not join the band the model says works.
- **Channel auto-selection** by the ET9s is assumed good; a bad real-world plan will do worse than the model says.
- **Oracle drift**: the pins, the channel plan and the catalogue loader are new code on both sides.

## 13. Decisions the owner must make

1. **The exact ROG router model** (the name on the box or in the router's admin page). It decides the router's bands, 6 GHz and 320 MHz
   support, chains, ports and power. Until then it is `assumed`.
2. **The list of fixed devices by room (D6 in the original design):** for each, a class (fixed 2x2, laptop, phone / tablet, IoT 1x1), the
   room and spot, and whether it must work (`must`).
3. **Which bands each pin needs:** the allowed set per device (for example "5 or 6", "6 only", "2.4 only"), and the minimum down and up
   speeds (Mbit/s) the owner calls good enough. A starting suggestion from the owner's own rules beats my defaults.
4. **Region (D13).** It sets the 6 GHz rules and the power caps. The engine's default is "US", which is a placeholder until the owner
   confirms.
5. **How many ET9s the owner would buy at most** (`a_max`), and **the price per ET9** (for the cost column and a budget ceiling).
6. **Spot policy:** only the existing jacks, or also places the owner would run a new cable to ("both" in 5.1).
7. **Wi-Fi 7 multi-link:** whether the first version may report it as an unquantified note (8.3), or the owner wants a rate for it, with a
   named client and a source.
8. **The WAN rate (D12)**, since the router's WAN rate caps what any node can deliver.
9. **Whether Python stays the oracle for this work** (review idea B12): the design assumes yes (Python first, then Swift, vectors), as for
   all engine work so far.
10. **The ET9 channel assumption:** plan as if the nodes choose a good channel plan (my default), or show a worst case alongside.
11. **Priority:** whether this comes before the LiDAR screen, the scan-safety work (Q4) and the catalogue in app form (B1) on its own.

Nothing here is built. When the owner has answered 1 to 5 (the rest have defaults), I would start with step 1 of section 11.
