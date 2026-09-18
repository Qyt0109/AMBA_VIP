//======================================================================
//  axi4s_vip_pkg.sv
//
//  Lightweight AXI4-Stream Verification IP, API-shaped after the Xilinx
//  axi4stream_vip (agents / driver.send() / ready_gen / set_delay()).
//
//  Contents
//    axi4s_delay_cfg          - pluggable TVALID delay generator
//    axi4s_transaction #(W)   - one beat (data/last/delay)
//    axi4s_packet #(W)        - a TLAST-delimited group of beats
//    axi4s_ready_gen          - TREADY backpressure shaping
//    axi4s_master_driver #(W) - drives TDATA/TVALID/TLAST
//    axi4s_slave_driver  #(W) - drives TREADY, collects beats
//    axi4s_monitor #(W)       - passive beat/packet collector
//    axi4s_master_agent #(W)  - driver + monitor, start_master()
//    axi4s_slave_agent  #(W)  - driver + monitor, start_slave()
//
//  Compile order: axi4s_if.sv  ->  axi4s_vip_pkg.sv  ->  testbench
//======================================================================
`ifndef AXI4S_VIP_PKG_SV
`define AXI4S_VIP_PKG_SV

package axi4s_vip_pkg;

  //====================================================================
  // Enumerations
  //====================================================================

  // TREADY generation policies (mirrors XIL_AXI4STREAM_READY_GEN_*)
  typedef enum int {
    AXI4S_READY_GEN_NO_BACKPRESSURE    = 0, // TREADY tied high
    AXI4S_READY_GEN_SINGLE             = 1, // 1 high, low_time low, repeat
    AXI4S_READY_GEN_OSC                = 2, // high_time high, low_time low
    AXI4S_READY_GEN_RANDOM             = 3, // random 1..high_time / 0..low_time
    AXI4S_READY_GEN_AFTER_VALID_SINGLE = 4, // as SINGLE, starts on first TVALID
    AXI4S_READY_GEN_AFTER_VALID_OSC    = 5, // as OSC,    starts on first TVALID
    AXI4S_READY_GEN_AFTER_VALID_RANDOM = 6, // as RANDOM, starts on first TVALID
    AXI4S_READY_GEN_EVENTS             = 7, // accept event_count beats, then
                                            // deassert for low_time
    AXI4S_READY_GEN_LOW_TIME           = 8  // low for low_time, then high
  } axi4s_ready_policy_e;

  // How the driver picks the pre-TVALID gap for each beat
  typedef enum int {
    AXI4S_DELAY_FIXED    = 0, // always fixed_delay
    AXI4S_DELAY_UNIFORM  = 1, // $urandom_range(max_delay, min_delay)
    AXI4S_DELAY_WEIGHTED = 2, // zero_weight : nz_weight split
    AXI4S_DELAY_SEQUENCE = 3, // walk seq_delays[$]
    AXI4S_DELAY_CUSTOM   = 4  // call user_delay() - extend the class
  } axi4s_delay_mode_e;

  typedef enum int {
    AXI4S_NONE   = 0,
    AXI4S_LOW    = 100,
    AXI4S_MEDIUM = 200,
    AXI4S_HIGH   = 300,
    AXI4S_DEBUG  = 400
  } axi4s_verbosity_e;

  // Print helper: a message tagged `lvl` is shown when lvl <= cur
  function automatic void axi4s_msg(input axi4s_verbosity_e cur,
                                    input axi4s_verbosity_e lvl,
                                    input string            id,
                                    input string            msg);
    if (cur != AXI4S_NONE && int'(lvl) <= int'(cur))
      $display("[%0t] %s: %s", $time, id, msg);
  endfunction

  //====================================================================
  // axi4s_delay_cfg
  //
  //  Produces the number of ACLK cycles TVALID is held low before the
  //  next beat is presented. One object can be shared by a driver as its
  //  default policy, or attached to a single transaction for a one-shot
  //  override. Extend it and override user_delay() for anything exotic.
  //====================================================================
  class axi4s_delay_cfg;

    axi4s_delay_mode_e mode        = AXI4S_DELAY_FIXED;
    int unsigned       fixed_delay = 0;
    int unsigned       min_delay   = 0;
    int unsigned       max_delay   = 0;
    int unsigned       zero_weight = 8;   // AXI4S_DELAY_WEIGHTED
    int unsigned       nz_weight   = 2;   // AXI4S_DELAY_WEIGHTED
    int unsigned       seq_delays[$];     // AXI4S_DELAY_SEQUENCE
    bit                seq_repeat  = 1'b1;

    protected int unsigned m_idx  = 0;    // sequence cursor
    protected int unsigned m_call = 0;    // beats served so far

    function new(axi4s_delay_mode_e mode = AXI4S_DELAY_FIXED);
      this.mode = mode;
    endfunction

    //---- factory helpers ---------------------------------------------
    static function axi4s_delay_cfg make_fixed(int unsigned d);
      axi4s_delay_cfg c;
      c = new(AXI4S_DELAY_FIXED);
      c.fixed_delay = d;
      return c;
    endfunction

    static function axi4s_delay_cfg make_uniform(int unsigned lo,
                                                 int unsigned hi);
      axi4s_delay_cfg c;
      c = new(AXI4S_DELAY_UNIFORM);
      c.min_delay = lo;
      c.max_delay = hi;
      return c;
    endfunction

    // `pct_idle` percent of beats get a gap in [lo:hi], the rest are
    // back-to-back.
    static function axi4s_delay_cfg make_weighted(int unsigned pct_idle,
                                                  int unsigned lo,
                                                  int unsigned hi);
      axi4s_delay_cfg c;
      c = new(AXI4S_DELAY_WEIGHTED);
      c.nz_weight   = (pct_idle > 100) ? 100 : pct_idle;
      c.zero_weight = 100 - c.nz_weight;
      c.min_delay   = lo;
      c.max_delay   = hi;
      return c;
    endfunction

    static function axi4s_delay_cfg make_sequence(int unsigned list[$],
                                                  bit          repeat_list = 1'b1);
      axi4s_delay_cfg c;
      c = new(AXI4S_DELAY_SEQUENCE);
      c.seq_delays = list;
      c.seq_repeat = repeat_list;
      return c;
    endfunction

    //---- runtime ------------------------------------------------------
    virtual function void reset();
      m_idx  = 0;
      m_call = 0;
    endfunction

    protected function int unsigned rand_range(int unsigned lo,
                                               int unsigned hi);
      if (hi <= lo) return lo;
      return $urandom_range(hi, lo);
    endfunction

    // Called once per beat by the master driver.
    virtual function int unsigned next_delay();
      int unsigned d;
      int unsigned total;
      d     = 0;
      total = zero_weight + nz_weight;
      case (mode)
        AXI4S_DELAY_FIXED:
          d = fixed_delay;

        AXI4S_DELAY_UNIFORM:
          d = rand_range(min_delay, max_delay);

        AXI4S_DELAY_WEIGHTED: begin
          if (total == 0)
            d = 0;
          else if ($urandom_range(total-1, 0) < zero_weight)
            d = 0;
          else
            d = rand_range((min_delay == 0) ? 1 : min_delay,
                           (max_delay == 0) ? 1 : max_delay);
        end

        AXI4S_DELAY_SEQUENCE: begin
          if (seq_delays.size() == 0) begin
            d = 0;
          end
          else begin
            if (m_idx >= seq_delays.size())
              m_idx = seq_repeat ? 0 : (seq_delays.size() - 1);
            d = seq_delays[m_idx];
            m_idx++;
          end
        end

        AXI4S_DELAY_CUSTOM:
          d = user_delay(m_call);

        default:
          d = 0;
      endcase
      m_call++;
      return d;
    endfunction

    // Override this (and use AXI4S_DELAY_CUSTOM) for arbitrary shaping:
    // burst gaps, credit models, delays derived from the beat index, ...
    virtual function int unsigned user_delay(int unsigned beat_index);
      return fixed_delay;
    endfunction

  endclass : axi4s_delay_cfg

  //====================================================================
  // axi4s_transaction - one AXI4-Stream beat
  //====================================================================
  class axi4s_transaction #(int DATA_WIDTH = 32);

    typedef axi4s_transaction #(DATA_WIDTH) this_type;

    rand bit [DATA_WIDTH-1:0] data;
    rand bit                  last;
    rand int unsigned         delay;   // ACLK cycles of TVALID-low before beat

    // Randomization knobs (non-rand)
    int unsigned delay_min = 0;
    int unsigned delay_max = 0;

    // Per-transaction delay override (highest precedence in the driver)
    bit             delay_set = 1'b0;
    axi4s_delay_cfg delay_cfg = null;  // per-transaction policy (2nd prio)

    // Bookkeeping, filled in by driver / monitor
    int unsigned beat_id = 0;
    time         stamp   = 0;

    constraint c_delay {
      delay >= delay_min;
      delay <= delay_max;
    }

    function new(bit [DATA_WIDTH-1:0] data = '0, bit last = 1'b0);
      this.data  = data;
      this.last  = last;
      this.delay = 0;
    endfunction

    // A randomized delay counts as an explicit one
    function void post_randomize();
      delay_set = 1'b1;
    endfunction

    //---- payload ------------------------------------------------------
    function void set_data(bit [DATA_WIDTH-1:0] d);  data = d;      endfunction
    function bit [DATA_WIDTH-1:0] get_data();        return data;   endfunction
    function void set_last(bit l);                   last = l;      endfunction
    function bit  get_last();                        return last;   endfunction

    //---- delay --------------------------------------------------------
    function void set_delay(int unsigned d);
      delay     = d;
      delay_set = 1'b1;
    endfunction
    function int unsigned get_delay();  return delay;      endfunction
    function bit          has_delay();  return delay_set;  endfunction
    function void         clear_delay();
      delay     = 0;
      delay_set = 1'b0;
    endfunction

    function void set_delay_range(int unsigned lo, int unsigned hi);
      delay_min = lo;
      delay_max = hi;
    endfunction

    function void set_delay_cfg(axi4s_delay_cfg cfg);
      delay_cfg = cfg;
    endfunction

    //---- object services ----------------------------------------------
    function void copy(this_type rhs);
      if (rhs == null) return;
      data      = rhs.data;
      last      = rhs.last;
      delay     = rhs.delay;
      delay_set = rhs.delay_set;
      delay_cfg = rhs.delay_cfg;
      delay_min = rhs.delay_min;
      delay_max = rhs.delay_max;
      beat_id   = rhs.beat_id;
      stamp     = rhs.stamp;
    endfunction

    function this_type clone();
      this_type t;
      t = new();
      t.copy(this);
      return t;
    endfunction

    function bit compare(this_type rhs);
      if (rhs == null) return 1'b0;
      return (data === rhs.data) && (last === rhs.last);
    endfunction

    function string convert2string();
      return $sformatf("beat=%0d data=0x%0h last=%0b delay=%0d%s",
                       beat_id, data, last, delay,
                       delay_set ? " (explicit)" : "");
    endfunction

  endclass : axi4s_transaction

  //====================================================================
  // axi4s_packet - beats between TLAST boundaries
  //====================================================================
  class axi4s_packet #(int DATA_WIDTH = 32);

    typedef axi4s_packet #(DATA_WIDTH) this_type;

    bit [DATA_WIDTH-1:0] data[$];
    time                 start_time = 0;
    time                 end_time   = 0;

    function int unsigned size();                   return data.size();   endfunction
    function void push(bit [DATA_WIDTH-1:0] d);     data.push_back(d);    endfunction

    function bit compare(this_type rhs);
      if (rhs == null)                    return 1'b0;
      if (rhs.data.size() != data.size()) return 1'b0;
      foreach (data[i])
        if (data[i] !== rhs.data[i])      return 1'b0;
      return 1'b1;
    endfunction

    function string convert2string();
      string s;
      s = $sformatf("packet beats=%0d :", data.size());
      foreach (data[i]) s = {s, $sformatf(" %0h", data[i])};
      return s;
    endfunction

  endclass : axi4s_packet

  //====================================================================
  // axi4s_ready_gen - TREADY waveform shaping
  //
  //  next_ready() is evaluated once per ACLK by the slave driver and
  //  returns the TREADY level for the upcoming cycle.
  //====================================================================
  class axi4s_ready_gen;

    protected string               m_name;
    protected axi4s_ready_policy_e m_policy      = AXI4S_READY_GEN_NO_BACKPRESSURE;
    protected int unsigned         m_low_time    = 1;
    protected int unsigned         m_high_time   = 1;
    protected int unsigned         m_event_count = 1;

    protected bit          m_cur     = 1'b0;
    protected int unsigned m_cnt     = 0;
    protected int unsigned m_events  = 0;
    protected bit          m_started = 1'b0;

    function new(string name = "axi4s_ready_gen");
      m_name = name;
      reset();
    endfunction

    function void set_ready_policy(axi4s_ready_policy_e p);
      m_policy = p;
      reset();
    endfunction
    function axi4s_ready_policy_e get_ready_policy(); return m_policy; endfunction

    function void set_low_time   (int unsigned t); m_low_time    = t;  endfunction
    function void set_high_time  (int unsigned t); m_high_time   = t;  endfunction
    function void set_event_count(int unsigned c); m_event_count = (c == 0) ? 1 : c; endfunction

    function int unsigned get_low_time   (); return m_low_time;    endfunction
    function int unsigned get_high_time  (); return m_high_time;   endfunction
    function int unsigned get_event_count(); return m_event_count; endfunction

    virtual function void reset();
      m_cur     = (m_policy == AXI4S_READY_GEN_NO_BACKPRESSURE);
      m_cnt     = (m_policy == AXI4S_READY_GEN_LOW_TIME) ? m_low_time : 0;
      m_events  = 0;
      m_started = 1'b0;
    endfunction

    protected function bit needs_valid();
      return (m_policy inside {AXI4S_READY_GEN_AFTER_VALID_SINGLE,
                               AXI4S_READY_GEN_AFTER_VALID_OSC,
                               AXI4S_READY_GEN_AFTER_VALID_RANDOM});
    endfunction

    protected function int unsigned phase_len(bit level);
      case (m_policy)
        AXI4S_READY_GEN_SINGLE,
        AXI4S_READY_GEN_AFTER_VALID_SINGLE:
          return level ? 1 : m_low_time;

        AXI4S_READY_GEN_OSC,
        AXI4S_READY_GEN_AFTER_VALID_OSC:
          return level ? m_high_time : m_low_time;

        AXI4S_READY_GEN_RANDOM,
        AXI4S_READY_GEN_AFTER_VALID_RANDOM:
          return level ? ((m_high_time == 0) ? 0 : $urandom_range(m_high_time, 1))
                       : $urandom_range(m_low_time, 0);

        default:
          return level ? 1 : 0;
      endcase
    endfunction

    // tvalid / beat_accepted describe the cycle that just completed.
    virtual function bit next_ready(bit tvalid, bit beat_accepted);
      int guard;
      case (m_policy)

        AXI4S_READY_GEN_NO_BACKPRESSURE: begin
          m_cur = 1'b1;
        end

        AXI4S_READY_GEN_LOW_TIME: begin
          if (m_cnt > 0) begin
            m_cnt--;
            m_cur = 1'b0;
          end
          else m_cur = 1'b1;
        end

        AXI4S_READY_GEN_EVENTS: begin
          if (m_cur) begin
            if (beat_accepted) m_events++;
            if (m_events >= m_event_count) begin
              m_events = 0;
              m_cur    = 1'b0;
              m_cnt    = m_low_time;
            end
          end
          else begin
            if (m_cnt > 0) m_cnt--;
            if (m_cnt == 0) m_cur = 1'b1;
          end
        end

        default: begin // SINGLE / OSC / RANDOM (+ AFTER_VALID_* variants)
          if (needs_valid() && !m_started) begin
            if (!tvalid) begin
              m_cur = 1'b0;
              return m_cur;
            end
            m_started = 1'b1;
            m_cnt     = 0;
          end
          if (m_cnt == 0) begin
            guard = 0;
            do begin
              m_cur = ~m_cur;
              m_cnt = phase_len(m_cur);
              guard++;
            end while ((m_cnt == 0) && (guard < 4));
            if (m_cnt == 0) m_cur = 1'b1;  // degenerate config: stay ready
            else            m_cnt--;
          end
          else m_cnt--;
        end

      endcase
      return m_cur;
    endfunction

  endclass : axi4s_ready_gen

  //====================================================================
  // axi4s_master_driver
  //====================================================================
  class axi4s_master_driver #(int DATA_WIDTH = 32);

    typedef axi4s_transaction #(DATA_WIDTH) txn_t;

    virtual axi4s_if #(DATA_WIDTH) vif;
    string                         name;
    axi4s_verbosity_e              verbosity     = AXI4S_NONE;
    axi4s_delay_cfg                delay_cfg;              // default policy
    bit                            drop_on_reset = 1'b1;

    int unsigned num_beats = 0;

    protected mailbox #(txn_t) m_q;
    protected int unsigned     m_pending = 0;   // queued + in flight
    protected bit              m_busy    = 1'b0;

    function new(virtual axi4s_if #(DATA_WIDTH) vif,
                 string                         name = "axi4s_master_driver");
      this.vif  = vif;
      this.name = name;
      m_q       = new();                       // unbounded
      delay_cfg = axi4s_delay_cfg::make_fixed(0);
    endfunction

    //---- transaction factory ------------------------------------------
    function txn_t create_transaction(string name = "txn");
      txn_t t;
      t = new();
      return t;
    endfunction

    //---- delay configuration ------------------------------------------
    function void set_delay_cfg(axi4s_delay_cfg cfg);
      if (cfg != null) begin
        delay_cfg = cfg;
        delay_cfg.reset();
      end
    endfunction
    function void set_delay_fixed (int unsigned d);
      set_delay_cfg(axi4s_delay_cfg::make_fixed(d));
    endfunction
    function void set_delay_random(int unsigned lo, int unsigned hi);
      set_delay_cfg(axi4s_delay_cfg::make_uniform(lo, hi));
    endfunction

    //---- stimulus ------------------------------------------------------
    // Non-blocking. `delay` >= 0 overrides the gap for THIS call only;
    // `cfg` != null attaches a one-shot delay policy to this beat.
    // Precedence: delay arg / t.set_delay()  >  t.delay_cfg  >  driver cfg
    function void send(txn_t t, int delay = -1, axi4s_delay_cfg cfg = null);
      if (t == null) return;
      if (cfg   != null) t.set_delay_cfg(cfg);
      if (delay >= 0)    t.set_delay(delay);
      m_pending++;
      void'(m_q.try_put(t));
    endfunction

    function void send_data(bit [DATA_WIDTH-1:0] d,
                            bit                  last  = 1'b0,
                            int                  delay = -1);
      txn_t t;
      t = create_transaction();
      t.set_data(d);
      t.set_last(last);
      send(t, delay);
    endfunction

    // Queue a whole TLAST-terminated packet.
    function void send_packet(bit [DATA_WIDTH-1:0] payload[$],
                              int                  delay     = -1,
                              bit                  gen_tlast = 1'b1,
                              axi4s_delay_cfg      cfg       = null);
      txn_t t;
      foreach (payload[i]) begin
        t = create_transaction();
        t.set_data(payload[i]);
        t.set_last(gen_tlast && (i == payload.size()-1));
        send(t, delay, cfg);
      end
    endfunction

    task send_blocking(txn_t t, int delay = -1, axi4s_delay_cfg cfg = null);
      send(t, delay, cfg);
      wait_driver_idle();
    endtask

    //---- status ---------------------------------------------------------
    function bit is_idle();            return (m_pending == 0); endfunction
    function int unsigned num_pending();return m_pending;       endfunction

    task wait_driver_idle();
      while (m_pending != 0) @(vif.mst_cb);
    endtask

    function void flush();
      txn_t t;
      while (m_q.try_get(t) != 0) ;
      m_pending = 0;
    endfunction

    //---- driving --------------------------------------------------------
    protected task drive_idle();
      vif.mst_cb.tvalid <= 1'b0;
      vif.mst_cb.tlast  <= 1'b0;
      vif.mst_cb.tdata  <= '0;
    endtask

    task automatic run();
      if (vif == null)
        $fatal(1, "%s: virtual interface is null", name);
      forever begin
        drive_idle();
        wait (vif.aresetn === 1'b1);
        fork
          drive_loop();
          @(negedge vif.aresetn);
        join_any
        disable fork;
        if (vif.aresetn !== 1'b1) begin
          m_busy = 1'b0;
          if (drop_on_reset) flush();
          axi4s_msg(verbosity, AXI4S_LOW, name, "reset asserted - driver idled");
        end
      end
    endtask

    protected task drive_loop();
      txn_t t;
      @(vif.mst_cb);                       // align to the clocking event
      forever begin
        if (m_q.try_get(t) != 0) begin
          m_busy = 1'b1;
          drive_beat(t);
          m_busy = 1'b0;
          if (m_pending > 0) m_pending--;
        end
        else begin
          vif.mst_cb.tvalid <= 1'b0;
          @(vif.mst_cb);
        end
      end
    endtask

    // Entered and left exactly on a clocking event.
    protected task drive_beat(txn_t t);
      int unsigned d;

      if (t.has_delay())            d = t.get_delay();
      else if (t.delay_cfg != null) d = t.delay_cfg.next_delay();
      else                          d = delay_cfg.next_delay();

      repeat (d) begin
        vif.mst_cb.tvalid <= 1'b0;
        vif.mst_cb.tlast  <= 1'b0;
        @(vif.mst_cb);
      end

      vif.mst_cb.tdata  <= t.data;
      vif.mst_cb.tlast  <= t.last;
      vif.mst_cb.tvalid <= 1'b1;

      forever begin
        @(vif.mst_cb);
        if (vif.mst_cb.tready === 1'b1) break;
      end

      vif.mst_cb.tvalid <= 1'b0;           // overridden if the next beat has d==0
      vif.mst_cb.tlast  <= 1'b0;

      t.delay   = d;
      t.beat_id = num_beats;
      t.stamp   = $time;
      num_beats++;
      axi4s_msg(verbosity, AXI4S_HIGH, name,
                $sformatf("sent %s", t.convert2string()));
    endtask

  endclass : axi4s_master_driver

  //====================================================================
  // axi4s_slave_driver
  //====================================================================
  class axi4s_slave_driver #(int DATA_WIDTH = 32);

    typedef axi4s_transaction #(DATA_WIDTH) txn_t;

    virtual axi4s_if #(DATA_WIDTH) vif;
    string                         name;
    axi4s_verbosity_e              verbosity = AXI4S_NONE;
    axi4s_ready_gen                ready_gen;
    mailbox #(txn_t)               rx;          // beats accepted here

    int unsigned num_beats = 0;

    protected bit m_cur_ready = 1'b0;

    function new(virtual axi4s_if #(DATA_WIDTH) vif,
                 string                         name = "axi4s_slave_driver");
      this.vif  = vif;
      this.name = name;
      ready_gen = new({name, ".ready_gen"});
      rx        = new();
    endfunction

    function axi4s_ready_gen create_ready(string name = "ready");
      axi4s_ready_gen rg;
      rg = new(name);
      return rg;
    endfunction

    // Install a ready generator (equivalent of driver.send_tready()).
    function void send_tready(axi4s_ready_gen rg);
      if (rg != null) begin
        ready_gen = rg;
        ready_gen.reset();
      end
    endfunction

    // Shorthand for the common cases
    function void set_no_backpressure();
      ready_gen.set_ready_policy(AXI4S_READY_GEN_NO_BACKPRESSURE);
    endfunction
    function void set_osc_backpressure(int unsigned high, int unsigned low);
      ready_gen.set_high_time(high);
      ready_gen.set_low_time(low);
      ready_gen.set_ready_policy(AXI4S_READY_GEN_OSC);
    endfunction

    task automatic run();
      if (vif == null)
        $fatal(1, "%s: virtual interface is null", name);
      forever begin
        vif.slv_cb.tready <= 1'b0;
        m_cur_ready = 1'b0;
        ready_gen.reset();
        wait (vif.aresetn === 1'b1);
        fork
          ready_loop();
          @(negedge vif.aresetn);
        join_any
        disable fork;
      end
    endtask

    protected task ready_loop();
      bit   accepted;
      txn_t t;
      @(vif.slv_cb);                        // align
      forever begin
        accepted = (vif.slv_cb.tvalid === 1'b1) && (m_cur_ready === 1'b1);
        if (accepted) begin
          t = new();
          t.set_data(vif.slv_cb.tdata);
          t.set_last(vif.slv_cb.tlast);
          t.beat_id = num_beats;
          t.stamp   = $time;
          num_beats++;
          void'(rx.try_put(t));
          axi4s_msg(verbosity, AXI4S_HIGH, name,
                    $sformatf("recv %s", t.convert2string()));
        end
        m_cur_ready       = ready_gen.next_ready(vif.slv_cb.tvalid, accepted);
        vif.slv_cb.tready <= m_cur_ready;
        @(vif.slv_cb);
      end
    endtask

  endclass : axi4s_slave_driver

  //====================================================================
  // axi4s_monitor - passive, works on either side of the link
  //====================================================================
  class axi4s_monitor #(int DATA_WIDTH = 32);

    typedef axi4s_transaction #(DATA_WIDTH) txn_t;
    typedef axi4s_packet      #(DATA_WIDTH) pkt_t;

    virtual axi4s_if #(DATA_WIDTH) vif;
    string                         name;
    axi4s_verbosity_e              verbosity = AXI4S_NONE;

    mailbox #(txn_t) beat_mb;
    mailbox #(pkt_t) pkt_mb;

    int unsigned num_beats   = 0;
    int unsigned num_packets = 0;

    protected pkt_t m_pkt;

    function new(virtual axi4s_if #(DATA_WIDTH) vif,
                 string                         name = "axi4s_monitor");
      this.vif  = vif;
      this.name = name;
      beat_mb   = new();
      pkt_mb    = new();
      m_pkt     = null;
    endfunction

    // Analysis hooks - override in a subclass to plug in a scoreboard
    virtual function void write_beat  (txn_t t); endfunction
    virtual function void write_packet(pkt_t p); endfunction

    task wait_beats(int unsigned n);
      while (num_beats < n) @(vif.mon_cb);
    endtask

    task wait_packets(int unsigned n);
      while (num_packets < n) @(vif.mon_cb);
    endtask

    task automatic run();
      if (vif == null)
        $fatal(1, "%s: virtual interface is null", name);
      forever begin
        m_pkt = null;                       // drop partial packet on reset
        wait (vif.aresetn === 1'b1);
        fork
          sample_loop();
          @(negedge vif.aresetn);
        join_any
        disable fork;
      end
    endtask

    protected task sample_loop();
      txn_t t;
      forever begin
        @(vif.mon_cb);
        if ((vif.mon_cb.tvalid === 1'b1) && (vif.mon_cb.tready === 1'b1)) begin
          t = new();
          t.set_data(vif.mon_cb.tdata);
          t.set_last(vif.mon_cb.tlast);
          t.beat_id = num_beats;
          t.stamp   = $time;
          num_beats++;
          void'(beat_mb.try_put(t));
          write_beat(t);

          if (m_pkt == null) begin
            m_pkt = new();
            m_pkt.start_time = $time;
          end
          m_pkt.push(t.data);

          if (t.last) begin
            m_pkt.end_time = $time;
            void'(pkt_mb.try_put(m_pkt));
            write_packet(m_pkt);
            num_packets++;
            axi4s_msg(verbosity, AXI4S_MEDIUM, name,
                      $sformatf("%s", m_pkt.convert2string()));
            m_pkt = null;
          end
        end
      end
    endtask

  endclass : axi4s_monitor

  //====================================================================
  // axi4s_master_agent
  //====================================================================
  class axi4s_master_agent #(int DATA_WIDTH = 32);

    typedef axi4s_transaction #(DATA_WIDTH) txn_t;

    virtual axi4s_if #(DATA_WIDTH)    vif;
    string                            name;
    axi4s_master_driver #(DATA_WIDTH) driver;
    axi4s_monitor       #(DATA_WIDTH) monitor;

    protected bit m_started = 1'b0;

    function new(virtual axi4s_if #(DATA_WIDTH) vif,
                 string                         name = "axi4s_master_agent");
      this.vif  = vif;
      this.name = name;
      driver    = new(vif, {name, ".driver"});
      monitor   = new(vif, {name, ".monitor"});
    endfunction

    // Returns immediately; driver and monitor run in the background.
    task start_master();
      if (m_started) return;
      m_started = 1'b1;
      fork
        driver.run();
        monitor.run();
      join_none
    endtask

    task wait_driver_idle();
      driver.wait_driver_idle();
    endtask

    function void set_verbosity(axi4s_verbosity_e v);
      driver.verbosity  = v;
      monitor.verbosity = v;
    endfunction

    function void set_delay_cfg(axi4s_delay_cfg cfg); driver.set_delay_cfg(cfg);   endfunction
    function void set_delay_fixed(int unsigned d);    driver.set_delay_fixed(d);   endfunction
    function void set_delay_random(int unsigned lo, int unsigned hi);
      driver.set_delay_random(lo, hi);
    endfunction

  endclass : axi4s_master_agent

  //====================================================================
  // axi4s_slave_agent
  //====================================================================
  class axi4s_slave_agent #(int DATA_WIDTH = 32);

    typedef axi4s_transaction #(DATA_WIDTH) txn_t;

    virtual axi4s_if #(DATA_WIDTH)   vif;
    string                           name;
    axi4s_slave_driver #(DATA_WIDTH) driver;
    axi4s_monitor      #(DATA_WIDTH) monitor;

    protected bit m_started = 1'b0;

    function new(virtual axi4s_if #(DATA_WIDTH) vif,
                 string                         name = "axi4s_slave_agent");
      this.vif  = vif;
      this.name = name;
      driver    = new(vif, {name, ".driver"});
      monitor   = new(vif, {name, ".monitor"});
    endfunction

    task start_slave();
      if (m_started) return;
      m_started = 1'b1;
      fork
        driver.run();
        monitor.run();
      join_none
    endtask

    function axi4s_ready_gen create_ready(string name = "ready");
      return driver.create_ready(name);
    endfunction

    function void send_tready(axi4s_ready_gen rg);
      driver.send_tready(rg);
    endfunction

    function void set_verbosity(axi4s_verbosity_e v);
      driver.verbosity  = v;
      monitor.verbosity = v;
    endfunction

  endclass : axi4s_slave_agent

endpackage : axi4s_vip_pkg

`endif // AXI4S_VIP_PKG_SV
