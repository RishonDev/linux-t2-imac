# iMac20 5K Dual-SST / APPAE32 Investigation Findings

Date: 2026-05-07

## Goal

Enable the iMac20 5K internal panel at full 5120x2880 by waking the second SST tile.

The working theory is that the panel is internally dual-SST:

- The left/main tile appears as APPAE31 and is currently driven through `eDP-1`.
- The right/second tile is expected to be APPAE32.
- Firmware exposes a `DP-1` connector that may correspond to the second tile, but Linux reports it disconnected.
- Windows appears to mitigate this at the kernel/driver level rather than relying on firmware.
- OCLP/macOS can wake both physical panel halves, but without dual-SST support in the tested path it remains limited to 2560x2160.

This work is explicitly experimental.

## Hardware And Runtime Context

Target system:

- Apple iMac20 family, expected DMI product `iMac20,1` or `iMac20,2`.
- AMD GPU at PCI address `0000:03:00.0`.
- Kernel version under test: `7.0.0-T2-1-t2`.
- Boot parameter used for experimental path:

```text
amdgpu.imac20_5k_experimental_dp1=1
```

The module parameter was confirmed active on target:

```text
/sys/module/amdgpu/parameters/imac20_5k_experimental_dp1 = Y
```

The target uses a service that rebinds `amdgpu` to force/retry initialization. This affects timing and can change DRM card numbering.

Observed card numbering:

- One boot exposed the display under `card1`.
- A later boot exposed it under `card0`.
- The underlying PCI device remained `0000:03:00.0`, so card number changes are considered probe-order/rebind artifacts rather than meaningful hardware changes.

## Build And Deployment Context

Build server:

```text
arch@18.212.55.14
```

SSH key:

```text
~/Downloads/ArchLinuxSSH.pem
```

Remote build tree:

```text
~/linux-t2-imac
```

The kernel packages are built on the remote server with:

```sh
MAKEFLAGS="-j64" makepkg -ef --noconfirm
```

The server reports 64 CPUs and the build was confirmed to use many cores, with sampled `cc1`/`make` CPU use around 7000% during the main compile phase.

Important package artifacts produced during this investigation:

```text
~/linux-t2-imac/linux-t2-7.0-1-x86_64.pkg.tar.zst
~/linux-t2-imac/linux-t2-headers-7.0-1-x86_64.pkg.tar.zst
```

The latest DP-1 post-detect diagnostic package was built at:

```text
linux-t2-7.0-1-x86_64.pkg.tar.zst          2026-05-07 01:28
linux-t2-headers-7.0-1-x86_64.pkg.tar.zst  2026-05-07 01:29
```

## Patch Set Under Test

The local/remote patch set contains these relevant patches:

```text
6001-amdgpu-imac20-panel-mode-quirk.patch
6002-amdgpu-imac20-disable-navi-smu-low-power-features.patch
6003-amdgpu-imac20-retry-smu-enable.patch
6004-amdgpu-imac20-external-no-edid-common-modes.patch
6005-amdgpu-imac20-5k-tiled-display.patch
6006-amdgpu-imac20-force-edp-panel-mode.patch
6007-amdgpu-imac20-efi-panel-handoff.patch
6008-amdgpu-imac20-cap-8bpc.patch
```

### 6001: Internal Panel Classification

Purpose:

- Force AMD DC to classify the iMac20 internal panel link as internal.

Observed log:

```text
link=0 iMac20 5K quirk: forcing internal panel classification for link_id=20
```

Interpretation:

- The DMI check works.
- Link 0 / object id 20 is consistently the internal eDP/APPAE31 path.

### 6005: 5K Dual-SST / APPAE32 Probe

Purpose:

- Add deferred probing for the suspected second tile path.
- Write eDP panel mode to the working eDP path.
- Attempt to wake/probe `DP-1` as APPAE32.
- Add diagnostic logging for connector/link identity.

Important log strings:

```text
iMac20 5K: connector scan attempt=...
iMac20 5K: panel_mode=EDP, DPCD 0x10A write: ret=...
DP-1: iMac20 5K: DP-1 APPAE32 wake attempt=...
DP-1: iMac20 5K: DP-1 re-detect after APPAE32 wake ret=...
```

### 6006: Force eDP Panel Mode / Experimental Parameter

Purpose:

- Add `amdgpu.imac20_5k_experimental_dp1`.
- Prevent some panel-mode state from being overwritten back to default for the experimental path.

Confirmed:

- The parameter exists in the built module.
- The parameter reads `Y` on the target when set on the kernel command line.

### 6007: EFI Handoff And Initial Work Scheduling

Purpose:

- EFI handoff cleanup on reboot.
- Schedule the APPAE32 delayed work from `amdgpu_dm_init()`.

Important patch interaction found:

- Initially, `6005` probe functions were present in source but were optimized out of `amdgpu.ko`.
- The package contained `imac20_5k_experimental_dp1` strings from `6006`, but did not contain `DP-1 APPAE32` strings from `6005`.
- The prepared source had `6005` functions but did not have the initial `schedule_delayed_work(&imac20_5k_work, ...)` reference in the final `amdgpu_dm_init()` block.
- Because the static delayed work was never referenced from live code, the compiler/linker removed the probe path.

Fix:

- Move/merge the scheduling into the final iMac20 init block owned by `6007`.
- After this fix, `amdgpu.ko` contained the expected strings:

```text
iMac20 5K: DP-1/APPAE32 wake probe disabled...
iMac20 5K: panel_mode=EDP, DPCD 0x10A write...
DP-1 APPAE32 wake attempt...
```

## Important Build/Install Failure Found

At one point, the target booted a module that only contained the `6006` parameter string and not the `6005` APPAE32 probe strings.

Evidence from target:

```text
dmesg | grep -i 'DP-1 APPAE32'
```

returned no output.

Evidence from module strings:

```text
strings amdgpu.ko | grep -Ei 'DP-1 APPAE32|panel_mode=EDP'
```

returned no APPAE32 strings.

Root cause:

- The patch stack had applied incompletely from the perspective of final reachable code.
- The delayed work was not referenced.
- The APPAE32 probe functions were optimized out.

Resolution:

- The init block was corrected.
- Packages were rebuilt.
- Package string verification confirmed the expected strings were present before further testing.

## Safety Notes On Repeated DPCD 0x10A Writes

The experiment repeatedly writes:

```text
DP_EDP_CONFIGURATION_SET / DPCD 0x10A = DP_PANEL_MODE_EDP
```

Observed behavior:

- On `eDP-1`, repeated writes return success:

```text
iMac20 5K: panel_mode=EDP, DPCD 0x10A write: ret=1
```

- On `DP-1`, all attempted DPCD reads/writes fail with `-5`.

Interpretation:

- Repeated writes to working `eDP-1` appear to be accepted by the sink.
- Repeated writes to `DP-1` are not actually reaching a live AUX target.
- Continuing to hammer 0x10A on DP-1 does not look useful because the failure is below the panel-mode state: AUX itself is inaccessible.

Practical conclusion:

- Repeated `0x10A` writes to eDP are probably not the main risk here, but they also are not solving DP-1.
- Further experiments should reduce repeated writes and focus on why DP-1 AUX/HPD is dead.

## Connector Inventory Findings

The most important diagnostic output came from connector inventory logs.

At first scan:

```text
eDP-1:
  connector_type=14
  status=3
  link_index=0
  link_id=20
  enum=1
  obj_type=3
  dc_type=1
  signal=128
  local_sink=1
  sink_count=0
  internal=1
  hpd=0
  hpd_pending=0
  aux_disabled=0
  edp_sink=1
  ddc=1
  hpd_src=1

DP-1:
  connector_type=10
  status=3
  link_index=1
  link_id=19
  enum=1
  obj_type=3
  dc_type=0
  signal=32
  local_sink=0
  sink_count=0
  internal=0
  hpd=0
  hpd_pending=0
  aux_disabled=0
  edp_sink=0
  ddc=2
  hpd_src=0

DP-2:
  connector_type=10
  status=3
  link_index=2
  link_id=19
  enum=2
  obj_type=3
  dc_type=3
  signal=32
  local_sink=1
  sink_count=0
  internal=0
  hpd=0
  hpd_pending=0
  aux_disabled=0
  edp_sink=0
  ddc=4
  hpd_src=2
```

Later scan:

```text
eDP-1 status=1 dc_type=1 local_sink=1
DP-1 status=2 dc_type=0 local_sink=0
DP-2 status=1 dc_type=3 local_sink=1
DP-3 status=2 dc_type=0 local_sink=0
```

Meaning of status values in context:

- `status=3`: initially unknown during early probing.
- `status=1`: connected.
- `status=2`: disconnected.

Meaning of DC connection type:

```c
enum dc_connection_type {
    dc_connection_none,       // 0
    dc_connection_single,     // 1
    dc_connection_mst_branch, // 2
    dc_connection_sst_branch, // 3
    dc_connection_analog_load // 4
};
```

Interpretation:

- `eDP-1` is the active internal APPAE31 path.
- `DP-1` is firmware-exposed but dead from AMD DC's perspective.
- `DP-2` is a live external display, not the internal APPAE32 tile.
- `DP-3` appears as another disconnected DP object.

Critical correction:

- A temporary idea to retarget the APPAE32 experiment to `DP-2` was rejected.
- `DP-2` is the user's external display and must not be touched for internal panel wake experiments.
- The local patch was restored to target `DP-1/link_index=1` only.

## DP-1 / APPAE32 Probe Results

The DP-1 probe repeatedly produced:

```text
DP-1: iMac20 5K: DP-1 APPAE32 wake attempt=N
status=...
type=0
write_0x10a=-5
dpcd_read=-5
caps=00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Additional DPCD reads:

```text
DP-1: link=1 DPCD sink-oui 0x00400 ret=-5
DP-1: link=1 DPCD edp-caps 0x00700 ret=-5
```

Interpretation:

- `-5` is `-EIO`.
- DP-1 AUX transactions fail consistently.
- DP-1 has no local sink.
- DP-1 remains `dc_connection_none`.
- The issue is not only that the connector is marked disconnected; the AUX path itself does not work from this Linux path.

## Forced Detect Experiment

A later patch changed the probe so that failed initial DP-1 AUX no longer returned early.

New behavior:

- Try DP-1 0x10A write.
- Try DP-1 DPCD read.
- Run:

```c
dc_link_detect(aconn->dc_link, DETECT_REASON_HPD)
```

- Then perform a post-detect DPCD read.

Result:

```text
DP-1 re-detect after APPAE32 wake ret=1 type=0 local_sink=0 post_dpcd_read=-5
```

This repeated across all attempts.

Interpretation:

- `dc_link_detect()` returns true as a function call.
- It does not create a DP-1 sink.
- It does not change DP-1 `type`.
- It does not make DP-1 AUX readable.
- `post_dpcd_read=-5` proves normal AMD DC detection does not wake/enable DP-1 AUX in this state.

## HPD Findings

DP-1 inventory:

```text
hpd=0
hpd_pending=0
hpd_src=0
```

The AMD DC code path shows physical endpoint detection uses `link_get_hpd_state(link)`, which calls the link encoder's hardware HPD function:

```c
bool link_get_hpd_state(struct dc_link *link)
{
    if (link->link_enc)
        return link->link_enc->funcs->get_hpd_state(link->link_enc);
    else
        return false;
}
```

Interpretation:

- Simply setting `link->hpd_status` would not be enough for a physical DP endpoint.
- DP-1 appears to have no HPD source (`hpd_src=0`) and no hardware HPD asserted.
- AMD DC detection sees no connection and keeps `dc_connection_none`.

## Why DP-2 Must Not Be Used For APPAE32

DP-2 looked tempting because:

```text
DP-2 dc_type=3 local_sink=1
```

But user clarified:

- DP-2 is the external display.

Therefore:

- DP-2 must be excluded from APPAE32/internal-panel experiments.
- Any internal APPAE32 wake logic must not disturb DP-2.
- The internal candidate remains DP-1 because it is the firmware-exposed dead object with `link_index=1`, `link_id=19`, `enum=1`.

## Comparison With Earlier Boot Logs

Earlier logs before the final diagnostics showed:

- `eDP-1` connected and receiving preferred mode.
- `DP-1` added to sysfs but reported disconnected.
- AUX reads on bus 2 could succeed for some external/live DP path.
- DP-1 status remained disconnected.

After connector inventory, the reason became clearer:

- The live DP path in the log corresponds to DP-2/external, not the internal second tile.
- DP-1 remains an AMD DC object, but it has no live sink and its AUX transactions fail.

## Current Working Conclusions

1. The experimental module is loading and running.

Evidence:

```text
iMac20 5K: scheduled APPAE32 delayed probe
connector scan attempt=...
DP-1 APPAE32 wake attempt=...
```

2. The iMac20 DMI check is working.

Evidence:

```text
dm init dmi=1 experimental_dp1=1
```

3. The working internal tile is `eDP-1`.

Evidence:

```text
eDP-1 link_index=0 link_id=20 dc_type=1 local_sink=1 internal=1 edp_sink=1
```

4. Writing eDP panel mode to `eDP-1` succeeds.

Evidence:

```text
panel_mode=EDP, DPCD 0x10A write: ret=1
```

5. `DP-1` is the dead APPAE32 candidate, but Linux cannot currently access AUX on it.

Evidence:

```text
DP-1 link_index=1 link_id=19 enum=1 dc_type=0 local_sink=0 hpd_src=0 ddc=2
write_0x10a=-5
dpcd_read=-5
post_dpcd_read=-5
```

6. `dc_link_detect()` does not wake DP-1.

Evidence:

```text
re-detect ret=1 type=0 local_sink=0 post_dpcd_read=-5
```

7. `DP-2` is not APPAE32.

Evidence:

```text
DP-2 link_index=2 link_id=19 enum=2 dc_type=3 local_sink=1
```

User clarified:

```text
DP-2 is my external display
```

8. Further work should move below the DM connector layer.

Reason:

- DM-level attempts can call detect and write DPCD, but DP-1 AUX remains EIO.
- The failure appears to be in link creation, HPD/AUX routing, firmware routing, or a lower-level AMD DC/BIOS object mapping.

## Recommended Next Experiments

### 1. Instrument Link Creation For All DP Objects

Add logs during link creation / PHY construction, especially around:

```text
drivers/gpu/drm/amd/display/dc/link/link_factory.c
```

Capture for each link:

- `link_index`
- `link_id.id`
- `link_id.enum_id`
- `connector_signal`
- `is_internal_display`
- `ddc_hw_inst`
- `hpd_src`
- `link_enc_hw_inst`
- `eng_id`
- whether `link_enc` exists
- any BIOS object table decisions

Goal:

- Understand why DP-1 gets `hpd_src=0` and no live AUX.
- Compare DP-1 against eDP-1 and DP-2.

### 2. Instrument AUX Channel Mapping

Find and log how AMD maps:

- connector object
- DDC line
- AUX engine
- HPD source

For DP-1:

```text
ddc=2
hpd_src=0
```

For DP-2/external:

```text
ddc=4
hpd_src=2
```

Goal:

- Determine whether DP-1 AUX engine is missing, disabled, misrouted, or firmware-gated.

### 3. Avoid Further DP-2 Experiments

DP-2 is external and live.

Rule:

- Do not retarget APPAE32 wake attempts to DP-2.
- Do not modify DP-2 panel mode or training behavior for internal panel experiments.

### 4. Reduce Repeated DP-1 Hammering

Since DP-1 consistently returns `-EIO`, repeated attempts do not add much after diagnostics.

Recommended:

- Keep connector inventory logs.
- Probe DP-1 fewer times.
- Focus on lower-level link/AUX routing.

### 5. Compare Against macOS/OCLP Behavior If Logs Are Available

Useful evidence would include:

- Which connector/object gets the second internal tile.
- Whether the second tile appears through the equivalent of link id 19 enum 1.
- Whether firmware/macOS toggles HPD/AUX routing before Linux would normally detect.

## Useful Commands

Check active kernel command line:

```sh
cat /proc/cmdline
```

Check experimental parameter:

```sh
cat /sys/module/amdgpu/parameters/imac20_5k_experimental_dp1
```

Filter relevant logs:

```sh
sudo dmesg | grep -Ei 'connector scan|APPAE32|re-detect|post_dpcd|0x10A|panel_mode|dm init'
```

Verify built module strings inside package:

```sh
bsdtar -xOf linux-t2-7.0-1-x86_64.pkg.tar.zst \
  usr/lib/modules/7.0.0-T2-1-t2/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko.zst |
  zstdcat |
  strings |
  grep -Ei 'connector scan|APPAE32|post_dpcd|panel_mode=EDP'
```

## Current State To Continue From

The latest known-good server baseline:

- Targets DP-1 only for APPAE32 experiments.
- Keeps connector inventory diagnostics.
- Forces `dc_link_detect()` even if initial DP-1 AUX fails.
- Logs post-detect DPCD result.

Observed result:

```text
post_dpcd_read=-5
type=0
local_sink=0
```

Next recommended coding direction:

- Instrument `link_factory.c` and related AUX/HPD mapping paths.
- Do not touch DP-2.
- Determine why DP-1 is created with no useful HPD/AUX path.

## Experiment 2026-05-07-A: Link Factory / BIOS Object Instrumentation

Purpose:

- Move below the DM connector layer and log how AMD DC creates each physical link.
- Confirm whether DP-1 is born with broken/missing HPD/AUX routing before DM ever probes it.
- Compare the low-level BIOS/DDC/HPD/encoder assignment for:
  - eDP-1 / link 0 / link_id 20
  - DP-1 / link 1 / link_id 19 enum 1
  - DP-2 / link 2 / link_id 19 enum 2, known external display
  - DP-3 / link 3 / link_id 19 enum 3, disconnected

Rules:

- This experiment is logging-only.
- Do not retarget APPAE32 probing to DP-2.
- Do not change DP-2 behavior.
- Do not change training, HPD, AUX, DDC, or connector routing yet.

Patch target:

```text
6001-amdgpu-imac20-panel-mode-quirk.patch
drivers/gpu/drm/amd/display/dc/link/link_factory.c
construct_phy()
```

Fields to log:

- connector index from BIOS table
- `link_index`
- `link_id.id`
- `link_id.enum_id`
- `link_id.type`
- `is_internal_display`
- transmitter selected from BIOS source object
- analog engine
- DDC line / `ddc_hw_inst`
- HPD source / `hpd_src`
- HPD IRQ source
- HPD RX IRQ source
- read-request IRQ source
- connector signal
- encoder engine id
- link encoder hardware instance / transmitter
- whether `link_enc` exists

Implementation notes:

- Add logs only in `construct_phy()`.
- Keep the existing APPAE31/eDP-1 internal-classification quirk unchanged.
- Print one `pre-ddc` line after BIOS connector capabilities and before connector validation.
- Print one `ddc` line after `ddc_hw_inst` is derived.
- Print one `hpd` line after HPD source selection and before link encoder creation.
- Print one `final` line after connector signal, engine id, and link encoder hardware instance are known.
- These logs are expected to include DP-2 for comparison only; DP-2 is the external display and is not an APPAE32 target.

Expected value of this experiment:

- If DP-1 has invalid or suspicious HPD/DDC/encoder assignment at creation, the next patch should focus on link construction or BIOS object interpretation.
- If DP-1 creation looks normal but AUX still fails later, the next patch should instrument AUX transaction setup/path selection.
- If DP-1 and DP-3 are both dead in similar ways, compare both against DP-2 external and eDP-1 internal.

## Experiment 2026-05-07-A Result

Input log:

```text
~/mesg.txt
```

Result summary:

- The link factory instrumentation worked.
- All four BIOS connector entries are constructed.
- DP-1 is not missing a link encoder.
- DP-1 is not missing DDC assignment.
- DP-1 is not missing HPD assignment.
- DP-1 still cannot complete AUX/DPCD transactions.
- Repeated `dc_link_detect()` calls do not create a sink on DP-1.
- DP-2 remains the external display and should not be used as the APPAE32 target.

Constructed links:

```text
eDP-1 / link 0 / connector_index 0 / link_id 20 enum 1
  internal=1
  transmitter=1
  ddc_hw_inst=1
  ddc_channel=2
  hpd_src=1
  irq_hpd=0 final
  irq_hpd_rx=8 final
  signal=128
  eng_id=1
  link_enc_hw_inst=1

DP-1 / link 1 / connector_index 1 / link_id 19 enum 1
  internal=0
  transmitter=0
  ddc_hw_inst=2
  ddc_channel=3
  hpd_src=0
  irq_hpd=1 final
  irq_hpd_rx=7 final
  signal=32
  eng_id=0
  link_enc_hw_inst=0

DP-2 / link 2 / connector_index 2 / link_id 19 enum 2
  internal=0
  transmitter=4
  ddc_hw_inst=4
  ddc_channel=5
  hpd_src=2
  irq_hpd=3 final
  irq_hpd_rx=9 final
  signal=32
  eng_id=4
  link_enc_hw_inst=4
  known external display

DP-3 / link 3 / connector_index 3 / link_id 19 enum 3
  internal=0
  transmitter=2
  ddc_hw_inst=0
  ddc_channel=1
  hpd_src=3
  irq_hpd=4 final
  irq_hpd_rx=10 final
  signal=32
  eng_id=2
  link_enc_hw_inst=2
```

Connector scan state:

```text
eDP-1: status=connected, local_sink=1, dc_type=1, internal=1
DP-1: status=disconnected, local_sink=0, dc_type=0, internal=0
DP-2: status=connected, local_sink=1, dc_type=3, internal=0
DP-3: status=disconnected, local_sink=0, dc_type=0, internal=0
```

DP-1 AUX result:

```text
write_0x10a=-5
dpcd_read=-5
post_dpcd_read=-5
dc_link_detect() ret=1
type=0
local_sink=0
```

Interpretation:

- The failure is now below the link-factory object mapping layer.
- DP-1 has a plausible BIOS object, HPD source, DDC line, link encoder, signal type, and engine assignment.
- The firmware-exposed DP-1 path is still not AUX-accessible when Linux probes it.
- Since DP-2 is valid external output and DP-1 is the dead APPAE32 candidate, copying DP-2 behavior directly is not appropriate.
- The next experiment should instrument or alter AUX path selection/gating for link 1, not connector enumeration.

Next recommended experiment:

- Add logging in the AMD DC AUX transaction path for iMac20 only.
- Log which AUX engine/DDC/AUX channel is selected for link 0, link 1, link 2, and link 3.
- Compare successful eDP-1 and DP-2 AUX transactions against failing DP-1 transactions.
- Keep DP-2 untouched except for passive logging.

## Handover To Claude / Next Agent

Status at handoff:

- Current date: 2026-05-07.
- Working tree: `/home/rishon/linux-t2-imac`.
- Target hardware: iMac20 5K with AMDGPU, not always physically available from the build machine.
- Remote build server: `arch@18.212.55.14`.
- SSH key: `~/Downloads/ArchLinuxSSH.pem`.
- Package repo on remote: `~/linux-t2-imac`.

Important user constraint:

- Do not treat DP-2 as the APPAE32/internal-right-panel target.
- DP-2 is the user's external display.
- DP-2 may be logged for comparison only.
- Do not route, force, wake, train, or otherwise experiment on DP-2.

Current patch state:

- `6001-amdgpu-imac20-panel-mode-quirk.patch`
  - Keeps the APPAE31/eDP-1 internal classification quirk.
  - Adds logging-only `link_factory.c` instrumentation in `construct_phy()`.
  - Logs `pre-ddc`, `ddc`, `hpd`, and `final` link construction fields.

- `6005-amdgpu-imac20-5k-tiled-display.patch`
  - Contains the experimental DP-1/APPAE32 delayed probe path.
  - Targets DP-1 only.
  - Repeatedly attempts APPAE32 wake/detect on DP-1.
  - Logs connector inventory and post-detect DPCD result.

Latest built remote packages:

```text
~/linux-t2-imac/linux-t2-7.0-1-x86_64.pkg.tar.zst
~/linux-t2-imac/linux-t2-headers-7.0-1-x86_64.pkg.tar.zst
```

Build verification already done:

```text
makepkg -Cfo passed
MAKEFLAGS="-j64" makepkg -ef --noconfirm passed
amdgpu.ko contains the link factory diagnostic strings
```

Latest user log:

```text
~/mesg.txt
```

Main conclusion from latest log:

- DP-1 is constructed normally enough at AMD DC link-factory level.
- DP-1 has a BIOS connector object, DDC assignment, HPD assignment, link encoder, signal type, engine id, and link encoder hardware instance.
- DP-1 still fails all AUX/DPCD transactions with `-5`.
- `dc_link_detect()` returns success as a function call but leaves DP-1 with `type=0`, `local_sink=0`, and `post_dpcd_read=-5`.
- Therefore the failure is below connector enumeration and below basic link construction.

Critical latest DP-1 values:

```text
DP-1 / link 1 / connector_index 1 / link_id 19 enum 1
internal=0
transmitter=0
ddc_hw_inst=2
ddc_channel=3
hpd_src=0
irq_hpd=1 final
irq_hpd_rx=7 final
signal=32
eng_id=0
link_enc_hw_inst=0

write_0x10a=-5
dpcd_read=-5
post_dpcd_read=-5
type=0
local_sink=0
```

Comparison anchors:

```text
eDP-1 / link 0 / link_id 20 enum 1
  connected internal APPAE31
  transmitter=1 ddc_hw_inst=1 ddc_channel=2 hpd_src=1 eng_id=1 link_enc_hw_inst=1

DP-2 / link 2 / link_id 19 enum 2
  connected external display
  transmitter=4 ddc_hw_inst=4 ddc_channel=5 hpd_src=2 eng_id=4 link_enc_hw_inst=4

DP-3 / link 3 / link_id 19 enum 3
  disconnected
  transmitter=2 ddc_hw_inst=0 ddc_channel=1 hpd_src=3 eng_id=2 link_enc_hw_inst=2
```

Recommended next experiment:

- Instrument the AMD DC AUX transaction path for iMac20 only.
- Keep it logging-only first.
- Log the AUX/DDC path selected for every DPCD read/write on links 0, 1, 2, and 3.
- Compare successful eDP-1 and DP-2 AUX transactions against failing DP-1 transactions.
- The likely next useful question is whether DP-1's AUX engine/channel is wrong, disabled, firmware-gated, or timing-sensitive after firmware rewrites.

Suggested grep after next boot:

```sh
sudo dmesg | grep -Ei 'aux|dpcd|link factory|connector scan|APPAE32|post_dpcd|0x10A|panel_mode'
```

Known non-solution:

- Repeatedly writing DPCD `0x10a` on DP-1 does not wake APPAE32 because DP-1 AUX itself returns `-5`.
- Forcing `dc_link_detect()` after the failed wake does not create a DP-1 sink.
- Changing GRUB OS personality to Darwin did not resolve the firmware path.

## Experiment 2026-05-07-B: AUX Path Instrumentation

Purpose:

- Move below link construction into the actual DRM/AMDGPU AUX transfer path.
- Confirm which DDC/AUX path each link uses when native AUX/DPCD transactions occur.
- Compare successful eDP-1 and DP-2 transactions against failing DP-1 transactions.
- Keep DP-2 passive: log it only because it is the user's external display.

Patch:

```text
6009-amdgpu-imac20-aux-path-instrumentation.patch
drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm_mst_types.c
dm_dp_aux_transfer()
```

Why this location:

- `dm_dp_aux_transfer()` is the DRM AUX callback for AMDGPU DM connectors.
- It handles native AUX/DPCD requests and I2C-over-AUX requests.
- It has access to `TO_DM_AUX(aux)->ddc_service`.
- `ddc_service` has `ddc_service->link`, which identifies the AMD DC link.
- `ddc_service->ddc_pin` exposes the DDC channel and AUX engine index used by the lower DC path.

Fields now logged:

- AUX device name
- `link_index`
- `link_id.id`
- `link_id.enum_id`
- connector signal
- internal-display flag
- `ddc_hw_inst`
- DDC channel from `ddc_pin->hw_info.ddc_channel`
- DDC pin engine index from `ddc_pin->pin_data->en`
- `hpd_src`
- `link_enc_hw_inst`
- whether the DMUB AUX path is selected
- raw AUX request byte
- native AUX vs I2C-over-AUX
- write vs read
- MOT flag
- AUX/DPCD address
- transfer size
- raw transfer result before DRM helper error translation
- AMD DC AUX operation result
- reply byte
- payload data

Expected next boot grep:

```sh
sudo dmesg | grep -Ei 'iMac20 5K AUX xfer|link factory|connector scan|APPAE32|post_dpcd|0x10A|panel_mode'
```

What to look for:

- Whether DP-1 uses a unique or suspicious `ddc_channel` / `ddc_pin_en` compared with eDP-1 and DP-2.
- Whether DP-1 fails before reply data exists.
- Whether DP-1 returns a consistent AMD DC AUX operation result, such as engine acquire, HPD disconnect, timeout, protocol error, or unknown error.
- Whether the DMUB path is being used unexpectedly.
- Whether failed DP-1 transactions happen only after the eDP-1 `0x10A` write or are already failing earlier.

Build result:

```text
makepkg -Cfo passed
MAKEFLAGS="-j64" makepkg -ef --noconfirm passed
amdgpu.ko contains "iMac20 5K AUX xfer"
```

Built packages on remote:

```text
~/linux-t2-imac/linux-t2-7.0-1-x86_64.pkg.tar.zst         May  7 10:08, 174M
~/linux-t2-imac/linux-t2-headers-7.0-1-x86_64.pkg.tar.zst May  7 10:09, 41M
```

## Experiment 2026-05-07-B Result

Input log:

```text
~/dmesg.txt
```

Result summary:

- The AUX instrumentation worked.
- The captured log contains 5,006 lines.
- 4,877 AUX transaction logs are for DP-1 / link 1.
- 30 AUX transaction logs are for eDP-1 / link 0.
- No DP-2 AUX transactions are present in the captured filtered log, so DP-2 remains only a connector-scan comparison point for this boot.
- eDP-1 `0x10a` writes succeed.
- Every DP-1 AUX transaction fails before any reply payload is received.
- DP-1 consistently returns AMD DC AUX operation result `op=4`.

Important enum mapping:

```text
AUX_RET_SUCCESS = 0
AUX_RET_ERROR_UNKNOWN = 1
AUX_RET_ERROR_INVALID_REPLY = 2
AUX_RET_ERROR_TIMEOUT = 3
AUX_RET_ERROR_HPD_DISCON = 4
AUX_RET_ERROR_ENGINE_ACQUIRE = 5
AUX_RET_ERROR_INVALID_OPERATION = 6
AUX_RET_ERROR_PROTOCOL_ERROR = 7
```

Therefore:

```text
op=4 == AUX_RET_ERROR_HPD_DISCON
```

This comes from `dce_aux.c:get_channel_status()` when the hardware status register has `AUX_SW_HPD_DISCON` set.

DP-1 failing path:

```text
link=1
link_id=19 enum=1
signal=32
internal=0
ddc_hw_inst=2
ddc_channel=2
ddc_pin_en=2
hpd_src=0
link_enc_hw_inst=0
dmub=0
result=-1
op=4
reply=0x00
```

DP-1 failed transaction counts:

```text
1952 reads  addr=0x00000 req=0x9 result=-1 op=4
 992 reads  addr=0x00700 req=0x9 result=-1 op=4
 973 reads  addr=0x00400 req=0x9 result=-1 op=4
 960 writes addr=0x0010a req=0x8 result=-1 op=4 data=01
```

eDP-1 successful path:

```text
link=0
link_id=20 enum=1
signal=128
internal=1
ddc_hw_inst=1
ddc_channel=1
ddc_pin_en=1
hpd_src=1
link_enc_hw_inst=1
dmub=0
req=0x8
addr=0x0010a
size=1
result=0
op=0
data=01
```

eDP-1 successful transaction count:

```text
30 writes addr=0x0010a req=0x8 result=0 op=0 data=01
```

Connector scan state remains unchanged:

```text
eDP-1: connected, local_sink=1, ddc=1, hpd_src=1
DP-1: disconnected, local_sink=0, ddc=2, hpd_src=0
DP-2: connected external display, local_sink=1, ddc=4, hpd_src=2
DP-3: disconnected, local_sink=0, ddc=0, hpd_src=3
```

Interpretation:

- DP-1 is not failing because the AUX engine cannot be acquired.
- DP-1 is not failing because of an AUX timeout.
- DP-1 is not failing because of an invalid AUX reply.
- DP-1 is failing because the AUX engine reports HPD disconnect for the DP-1 AUX path.
- This is consistent with firmware exposing the DP-1 connector object while leaving its HPD/AUX path gated or electrically disconnected from Linux's current state.
- Repeated `0x10a` writes cannot work on DP-1 while `AUX_SW_HPD_DISCON` is asserted for that path.

Recommended next experiment:

- Stop the high-volume repeated DP-1 DPCD logging; it now proves the same HPD-disconnect state thousands of times.
- Add a narrow HPD/AUX status experiment instead:
  - log raw HPD sense / HPD source state for link 1 before each DP-1 AUX attempt,
  - optionally try a single controlled forced-HPD path for link 1 before one AUX read,
  - compare whether the hardware AUX status changes from `AUX_RET_ERROR_HPD_DISCON` to a different failure class.
- Keep DP-2 passive and untouched.

## Experiment 2026-05-07-C: Targeted HPD/AUX Status

Purpose:

- Replace the high-volume DP-1 DPCD retry spam with a smaller HPD-focused probe.
- Confirm whether DP-1's cached HPD state and encoder-sensed HPD state agree with the AUX hardware's `AUX_RET_ERROR_HPD_DISCON`.
- Keep DP-2 passive and untouched.

Patch changes:

- `6005-amdgpu-imac20-5k-tiled-display.patch`
  - removes extra DP-1 DPCD reads for `0x400` and `0x700`;
  - logs DP-1 `cached_hpd`, `sensed_hpd`, `hpd_pending`, `aux_disabled`, `hpd_src`, and `ddc` before each attempt;
  - logs the same HPD state after `dc_link_detect()`;
  - limits APPAE32/DP-1 probing to 5 attempts;
  - logs connector inventory only on attempts 1, 3, and 5.

- `6009-amdgpu-imac20-aux-path-instrumentation.patch`
  - adds `cached_hpd`, `sensed_hpd`, `hpd_pending`, and `aux_disabled` to each AUX transfer log.

Expected next boot grep:

```sh
sudo dmesg | grep -Ei 'DP-1 HPD/AUX|iMac20 5K AUX xfer|connector scan|APPAE32|post_dpcd|0x10A|panel_mode'
```

What to look for:

- If `sensed_hpd=0`, then DP-1's encoder HPD sense agrees with the AUX hardware's HPD-disconnect failure.
- If `cached_hpd=0` but `sensed_hpd=1`, then AMD DC's cached HPD state may be stale or not updated for this firmware-exposed connector.
- If both HPD states are `1` but AUX still returns `op=4`, then the AUX engine's HPD-disconnect status is coming from a lower hardware gate than normal HPD sense.

Build result:

- `makepkg -Cfo` prepare validation passed after fixing the `6005` hunk header.
- `build-ramdisk.sh` completed successfully on the remote builder using `/dev/shm`.
- The script copied only the built package artifacts back to `~/linux-t2-imac`:
  - `linux-t2-7.0-1-x86_64.pkg.tar.zst`
  - `linux-t2-headers-7.0-1-x86_64.pkg.tar.zst`
- Package string verification confirmed that `amdgpu.ko` contains:
  - `DP-1 HPD/AUX pre`
  - `cached_hpd`
  - `sensed_hpd`
  - `post_dpcd_read`
  - expanded `iMac20 5K AUX xfer` logging
