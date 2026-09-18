//======================================================================
//  tb_axi4s_vip.sv
//
//  Self-checking example for axi4s_vip_pkg:
//    - an AXI4-Stream master agent drives a skid buffer
//    - an AXI4-Stream slave agent applies backpressure on the far side
//    - both monitors feed a packet-level scoreboard
//
//  Compile order: axi4s_if.sv  ->  axi4s_vip_pkg.sv  ->  this file
//======================================================================
`timescale 1ns/1ps

//----------------------------------------------------------------------
// DUT: single-beat AXI4-Stream skid buffer (registered outputs)
//----------------------------------------------------------------------
module axi4s_skid_buffer #(
  parameter int DATA_WIDTH = 32
) (
  input  logic                  aclk,
  input  logic                  aresetn,
  input  logic [DATA_WIDTH-1:0] s_tdata,
  input  logic                  s_tvalid,
  input  logic                  s_tlast,
  output logic                  s_tready,
  output logic [DATA_WIDTH-1:0] m_tdata,
  output logic                  m_tvalid,
  output logic                  m_tlast,
  input  logic                  m_tready
);

  logic [DATA_WIDTH-1:0] skid_data;
  logic                  skid_last;
  logic                  skid_valid;

  assign s_tready = !skid_valid;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      m_tdata    <= '0;
      m_tlast    <= 1'b0;
      m_tvalid   <= 1'b0;
      skid_data  <= '0;
      skid_last  <= 1'b0;
      skid_valid <= 1'b0;
    end
    else begin
      if (!m_tvalid || m_tready) begin
        if (skid_valid) begin
          m_tdata    <= skid_data;
          m_tlast    <= skid_last;
          m_tvalid   <= 1'b1;
          skid_valid <= 1'b0;
        end
        else begin
          m_tdata  <= s_tdata;
          m_tlast  <= s_tlast;
          m_tvalid <= s_tvalid;
        end
      end
      else if (s_tvalid && s_tready) begin
        skid_data  <= s_tdata;
        skid_last  <= s_tlast;
        skid_valid <= 1'b1;
      end
    end
  end

endmodule : axi4s_skid_buffer

//----------------------------------------------------------------------
// A user-defined delay policy: N back-to-back beats, then a fixed gap.
//----------------------------------------------------------------------
class burst_gap_delay extends axi4s_vip_pkg::axi4s_delay_cfg;
  int unsigned beats_per_burst = 8;
  int unsigned gap             = 12;

  function new(int unsigned beats_per_burst = 8, int unsigned gap = 12);
    super.new(axi4s_vip_pkg::AXI4S_DELAY_CUSTOM);
    this.beats_per_burst = beats_per_burst;
    this.gap             = gap;
  endfunction

  function int unsigned user_delay(int unsigned beat_index);
    if ((beat_index != 0) && ((beat_index % beats_per_burst) == 0))
      return gap;
    return 0;
  endfunction
endclass

//----------------------------------------------------------------------
// Testbench
//----------------------------------------------------------------------
module tb_axi4s_vip;

  import axi4s_vip_pkg::*;

  localparam int DW = 32;

  logic aclk    = 1'b0;
  logic aresetn = 1'b0;

  always #5 aclk = ~aclk;                     // 100 MHz

  axi4s_if #(DW) src (.aclk(aclk), .aresetn(aresetn));
  axi4s_if #(DW) dst (.aclk(aclk), .aresetn(aresetn));

  axi4s_skid_buffer #(DW) dut (
    .aclk     (aclk),
    .aresetn  (aresetn),
    .s_tdata  (src.tdata),
    .s_tvalid (src.tvalid),
    .s_tlast  (src.tlast),
    .s_tready (src.tready),
    .m_tdata  (dst.tdata),
    .m_tvalid (dst.tvalid),
    .m_tlast  (dst.tlast),
    .m_tready (dst.tready)
  );

  typedef axi4s_transaction #(DW) txn_t;
  typedef axi4s_packet      #(DW) pkt_t;

  axi4s_master_agent #(DW) mst;
  axi4s_slave_agent  #(DW) slv;

  int unsigned pkt_checked = 0;
  int unsigned errors      = 0;

  //--------------------------------------------------------------------
  // Packet scoreboard: source monitor vs destination monitor
  //--------------------------------------------------------------------
  task automatic scoreboard();
    pkt_t exp, got;
    forever begin
      mst.monitor.pkt_mb.get(exp);
      slv.monitor.pkt_mb.get(got);
      if (!exp.compare(got)) begin
        errors++;
        $error("SCOREBOARD mismatch\n  exp: %s\n  got: %s",
               exp.convert2string(), got.convert2string());
      end
      else begin
        pkt_checked++;
        $display("[%0t] SCOREBOARD: packet %0d OK (%0d beats, %0t -> %0t)",
                 $time, pkt_checked, got.size(), got.start_time, got.end_time);
      end
    end
  endtask

  //--------------------------------------------------------------------
  // Helpers
  //--------------------------------------------------------------------
  function automatic void gen_payload(ref bit [DW-1:0] q[$], input int n);
    q.delete();
    for (int i = 0; i < n; i++) q.push_back($urandom());
  endfunction

  task automatic drain(int n = 30);
    repeat (n) @(posedge aclk);
  endtask

  //--------------------------------------------------------------------
  // Main
  //--------------------------------------------------------------------
  initial begin
    bit [DW-1:0]    payload[$];
    txn_t           t;
    axi4s_ready_gen rg;
    axi4s_delay_cfg dcfg;
    burst_gap_delay bcfg;

    mst = new(src, "mst");
    slv = new(dst, "slv");
    mst.set_verbosity(AXI4S_MEDIUM);
    slv.set_verbosity(AXI4S_MEDIUM);

    mst.start_master();
    slv.start_slave();
    fork
      scoreboard();
    join_none

    // reset
    aresetn = 1'b0;
    repeat (8) @(posedge aclk);
    aresetn <= 1'b1;
    repeat (4) @(posedge aclk);

    //------------------------------------------------------------------
    $display("\n=== TEST 1: back-to-back, no backpressure ===");
    rg = slv.create_ready("no_bp");
    rg.set_ready_policy(AXI4S_READY_GEN_NO_BACKPRESSURE);
    slv.send_tready(rg);

    gen_payload(payload, 16);
    mst.driver.send_packet(payload);          // delay defaults to 0
    mst.wait_driver_idle();
    drain();

    //------------------------------------------------------------------
    $display("\n=== TEST 2: fixed 3-cycle gap per beat (set_delay) ===");
    gen_payload(payload, 8);
    foreach (payload[i]) begin
      t = mst.driver.create_transaction();
      t.set_data(payload[i]);
      t.set_last(i == payload.size()-1);
      t.set_delay(3);                         // Xilinx-style per-beat delay
      mst.driver.send(t);
    end
    mst.wait_driver_idle();
    drain();

    //------------------------------------------------------------------
    $display("\n=== TEST 3: per-call delay override on send() ===");
    gen_payload(payload, 6);
    foreach (payload[i]) begin
      t = mst.driver.create_transaction();
      t.set_data(payload[i]);
      t.set_last(i == payload.size()-1);
      mst.driver.send(t, .delay(i));          // 0,1,2,3,4,5 cycle gaps
    end
    mst.wait_driver_idle();
    drain();

    //------------------------------------------------------------------
    $display("\n=== TEST 4: random master gaps + oscillating TREADY ===");
    mst.set_delay_random(0, 4);               // driver-level default policy
    rg = slv.create_ready("osc");
    rg.set_ready_policy(AXI4S_READY_GEN_OSC);
    rg.set_high_time(2);
    rg.set_low_time(3);
    slv.send_tready(rg);

    gen_payload(payload, 20);
    mst.driver.send_packet(payload);
    mst.wait_driver_idle();
    drain(60);

    //------------------------------------------------------------------
    $display("\n=== TEST 5: weighted gaps + random TREADY ===");
    dcfg = axi4s_delay_cfg::make_weighted(.pct_idle(30), .lo(1), .hi(6));
    mst.set_delay_cfg(dcfg);
    rg = slv.create_ready("rnd");
    rg.set_ready_policy(AXI4S_READY_GEN_RANDOM);
    rg.set_high_time(4);
    rg.set_low_time(4);
    slv.send_tready(rg);

    gen_payload(payload, 24);
    mst.driver.send_packet(payload);
    mst.wait_driver_idle();
    drain(80);

    //------------------------------------------------------------------
    $display("\n=== TEST 6: custom delay class (burst gaps) + EVENTS TREADY ===");
    bcfg = new(.beats_per_burst(4), .gap(10));
    rg   = slv.create_ready("events");
    rg.set_ready_policy(AXI4S_READY_GEN_EVENTS);
    rg.set_event_count(3);                    // accept 3 beats ...
    rg.set_low_time(5);                       // ... then stall 5 cycles
    slv.send_tready(rg);

    gen_payload(payload, 16);
    mst.driver.send_packet(payload, .delay(-1), .gen_tlast(1'b1), .cfg(bcfg));
    mst.wait_driver_idle();
    drain(100);

    //------------------------------------------------------------------
    $display("\n=== TEST 7: constrained-random beats (delay range) ===");
    mst.set_delay_fixed(0);
    rg = slv.create_ready("sgl");
    rg.set_ready_policy(AXI4S_READY_GEN_SINGLE);
    rg.set_low_time(2);
    slv.send_tready(rg);

    for (int i = 0; i < 12; i++) begin
      t = mst.driver.create_transaction();
      t.set_delay_range(0, 5);
      if (!t.randomize() with { last == (i == 11); })
        $fatal(1, "randomize failed");
      mst.driver.send(t);
    end
    mst.wait_driver_idle();
    drain(120);

    //------------------------------------------------------------------
    if (pkt_checked != 7) begin
      errors++;
      $error("expected 7 checked packets, got %0d", pkt_checked);
    end

    $display("\n======================================================");
    $display(" packets checked : %0d", pkt_checked);
    $display(" master beats    : %0d", mst.monitor.num_beats);
    $display(" slave  beats    : %0d", slv.monitor.num_beats);
    $display(" errors          : %0d", errors);
    $display(" %s", (errors == 0) ? "*** TEST PASSED ***" : "*** TEST FAILED ***");
    $display("======================================================\n");
    $finish;
  end

  // watchdog
  initial begin
    #500us;
    $error("TIMEOUT");
    $finish;
  end

  initial begin
    $dumpfile("tb_axi4s_vip.vcd");
    $dumpvars(0, tb_axi4s_vip);
  end

endmodule : tb_axi4s_vip
