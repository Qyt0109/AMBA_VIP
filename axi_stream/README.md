# AXI4-Stream VIP (SystemVerilog)

A compact AXI4-Stream verification IP shaped after the Xilinx `axi4stream_vip`
API: agents you `start_master()` / `start_slave()`, a `driver.send()` you feed
transactions to, a `ready_gen` for backpressure, and `set_delay()` on every beat.

Signal set is the simple one: **TDATA / TVALID / TREADY / TLAST**.

## Files & compile order

```
axi4s_if.sv        # parameterized interface (compile first)
axi4s_vip_pkg.sv   # the VIP package
tb_axi4s_vip.sv    # skid-buffer DUT + self-checking example
```

```bash
# Questa
vlog -sv axi4s_if.sv axi4s_vip_pkg.sv tb_axi4s_vip.sv && vsim -c tb_axi4s_vip -do "run -all; quit"
# VCS
vcs -sverilog -assert svaext axi4s_if.sv axi4s_vip_pkg.sv tb_axi4s_vip.sv && ./simv
# Xcelium
xrun -sv axi4s_if.sv axi4s_vip_pkg.sv tb_axi4s_vip.sv
```

Packages cannot be parameterized in SystemVerilog, so the width lives on the
*classes* (`#(int DATA_WIDTH = 32)`) and on the interface, and each class holds a
`virtual axi4s_if #(DATA_WIDTH)` handle. Instantiate any widths you like in the
same testbench.

## Quick start

```systemverilog
import axi4s_vip_pkg::*;

axi4s_if #(64) src (.aclk(aclk), .aresetn(aresetn));

axi4s_master_agent #(64) mst;
axi4s_slave_agent  #(64) slv;
axi4s_transaction  #(64) t;

initial begin
  mst = new(src, "mst");
  slv = new(dst, "slv");
  mst.start_master();          // returns immediately, forks driver+monitor
  slv.start_slave();

  t = mst.driver.create_transaction();
  t.set_data(64'hdead_beef);
  t.set_last(1'b1);
  t.set_delay(3);              // 3 idle ACLK cycles before TVALID
  mst.driver.send(t);          // non-blocking
  mst.wait_driver_idle();
end
```

## Delay control (three levels of precedence)

`delay` is the number of ACLK cycles TVALID is held low *before* the beat.

| Priority | How | Scope |
|---|---|---|
| 1 | `t.set_delay(n)` or `driver.send(t, .delay(n))` | that beat only |
| 2 | `t.set_delay_cfg(cfg)` or `driver.send(t, .cfg(cfg))` | that beat, from a policy object |
| 3 | `driver.set_delay_cfg(cfg)` / `set_delay_fixed()` / `set_delay_random()` | every beat with no override |

Built-in policies via `axi4s_delay_cfg`:

```systemverilog
axi4s_delay_cfg::make_fixed(4);                          // always 4
axi4s_delay_cfg::make_uniform(0, 7);                     // $urandom_range
axi4s_delay_cfg::make_weighted(.pct_idle(30),.lo(1),.hi(6)); // 30% of beats gapped
axi4s_delay_cfg::make_sequence('{0,0,5,1}, .repeat_list(1)); // walk a pattern
```

Anything else: extend the class, set mode `AXI4S_DELAY_CUSTOM`, override
`user_delay(beat_index)`. `tb_axi4s_vip.sv` shows a `burst_gap_delay` that sends
N beats back-to-back then inserts a fixed gap.

Randomization also works — `set_delay_range(lo,hi)` then `t.randomize()`;
`post_randomize()` marks the delay as explicit so the driver uses it.

## Backpressure control

```systemverilog
axi4s_ready_gen rg = slv.create_ready("bp");
rg.set_ready_policy(AXI4S_READY_GEN_OSC);
rg.set_high_time(2);
rg.set_low_time(3);
slv.send_tready(rg);
```

| Policy | Behaviour |
|---|---|
| `NO_BACKPRESSURE` | TREADY tied high |
| `SINGLE` | 1 cycle high, `low_time` low, repeat |
| `OSC` | `high_time` high, `low_time` low, repeat |
| `RANDOM` | random 1..`high_time` high, 0..`low_time` low |
| `AFTER_VALID_SINGLE/OSC/RANDOM` | same, but the pattern only starts after the first TVALID |
| `EVENTS` | accept `event_count` beats, then stall `low_time` cycles |
| `LOW_TIME` | low for `low_time`, then high forever |

Subclass `axi4s_ready_gen` and override `next_ready(tvalid, beat_accepted)` for a
custom waveform — it is called once per ACLK and returns TREADY for the next cycle.

## Monitors / scoreboarding

Both agents contain a passive `axi4s_monitor` sampling TVALID&&TREADY:

* `monitor.beat_mb` — `mailbox` of `axi4s_transaction`
* `monitor.pkt_mb`  — `mailbox` of `axi4s_packet` (TLAST-delimited, has `compare()`)
* `monitor.write_beat()` / `write_packet()` — virtual hooks to plug a scoreboard into
* `monitor.wait_beats(n)` / `wait_packets(n)`, `num_beats`, `num_packets`

The slave driver additionally puts everything it accepts into `slv.driver.rx`.

## Notes and limitations

* Driver and monitor loops stay aligned to the clocking event, so back-to-back
  beats have zero bubbles and handshake sampling is race-free (`input #1step`,
  `output #0`).
* On `aresetn` assertion the driver aborts the in-flight beat and (by default,
  `drop_on_reset`) discards queued transactions. TVALID deasserts on the first
  clock edge after reset, not combinationally.
* `set_verbosity(AXI4S_HIGH)` prints every beat; `AXI4S_MEDIUM` prints packets;
  `AXI4S_NONE` (default) is silent.
* Protocol assertions live in the interface — compile with `+define+AXI4S_NO_PROTOCOL_CHECKS`
  to drop them.
* To add TKEEP/TSTRB/TID/TDEST/TUSER: add the signals to the interface and its
  clocking blocks, add fields plus `set_*`/`get_*` to `axi4s_transaction`, and
  extend `drive_beat()` / `sample_loop()` — nothing else changes.
