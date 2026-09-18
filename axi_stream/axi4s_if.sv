//======================================================================
//  axi4s_if.sv
//
//  Parameterized AXI4-Stream interface used by axi4s_vip_pkg.
//  Signal set is deliberately minimal: TDATA / TVALID / TREADY / TLAST.
//
//  Compile this file BEFORE axi4s_vip_pkg.sv (the package declares
//  `virtual axi4s_if #(...)` handles).
//======================================================================
`ifndef AXI4S_IF_SV
`define AXI4S_IF_SV

interface axi4s_if #(
  parameter int DATA_WIDTH = 32
) (
  input logic aclk,
  input logic aresetn
);

  logic [DATA_WIDTH-1:0] tdata;
  logic                  tvalid;
  logic                  tready;
  logic                  tlast;

  //--------------------------------------------------------------------
  // Clocking blocks
  //
  //  output #0  -> drive in the NBA region of the posedge (identical to
  //                `always @(posedge aclk) sig <= v`)
  //  input #1step -> sample in the Preponed region, i.e. the value that a
  //                  flop clocked on this edge would capture.
  //
  //  All VIP driver loops stay aligned to the clocking event, so a value
  //  written at edge N is visible on the wire during [N, N+1) and the
  //  handshake sampled at edge N+1 belongs to that same cycle.
  //--------------------------------------------------------------------
  clocking mst_cb @(posedge aclk);
    default input #1step output #0;
    output tdata, tvalid, tlast;
    input  tready;
  endclocking

  clocking slv_cb @(posedge aclk);
    default input #1step output #0;
    input  tdata, tvalid, tlast;
    output tready;
  endclocking

  clocking mon_cb @(posedge aclk);
    default input #1step;
    input tdata, tvalid, tready, tlast;
  endclocking

  // VIP-facing modports
  modport mst (clocking mst_cb, input aclk, input aresetn);
  modport slv (clocking slv_cb, input aclk, input aresetn);
  modport mon (clocking mon_cb, input aclk, input aresetn);

  // DUT-facing modports (raw signals)
  modport dut_slv (input  aclk, aresetn, tdata, tvalid, tlast,
                   output tready);
  modport dut_mst (input  aclk, aresetn, tready,
                   output tdata, tvalid, tlast);

  //--------------------------------------------------------------------
  // Protocol checks  (define AXI4S_NO_PROTOCOL_CHECKS to remove)
  //--------------------------------------------------------------------
`ifndef AXI4S_NO_PROTOCOL_CHECKS
  // TVALID must not be withdrawn before TREADY
  property p_tvalid_held;
    @(posedge aclk) disable iff (aresetn !== 1'b1)
      (tvalid && !tready) |=> tvalid;
  endproperty

  // Payload must be stable while a beat is stalled
  property p_tdata_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1)
      (tvalid && !tready) |=> $stable(tdata);
  endproperty

  property p_tlast_stable;
    @(posedge aclk) disable iff (aresetn !== 1'b1)
      (tvalid && !tready) |=> $stable(tlast);
  endproperty

  // No X on the payload of a valid beat
  property p_no_x_when_valid;
    @(posedge aclk) disable iff (aresetn !== 1'b1)
      tvalid |-> !$isunknown({tdata, tlast});
  endproperty

  a_tvalid_held      : assert property (p_tvalid_held)
    else $error("AXI4S %m: TVALID deasserted before TREADY");
  a_tdata_stable     : assert property (p_tdata_stable)
    else $error("AXI4S %m: TDATA changed while stalled");
  a_tlast_stable     : assert property (p_tlast_stable)
    else $error("AXI4S %m: TLAST changed while stalled");
  a_no_x_when_valid  : assert property (p_no_x_when_valid)
    else $error("AXI4S %m: X/Z on TDATA/TLAST while TVALID asserted");
`endif

endinterface : axi4s_if

`endif // AXI4S_IF_SV
