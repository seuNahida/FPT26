`timescale 1ns/1ps
// v4 attention core: tiled, block-online softmax for one GQA group
// (4 query heads, 1 KV head, d = 128). Bit-exact to attn/model/golden_fixed.py.
//
// Memory ports (lines of 32 BF16 = 512 bits, read latency MEM_LAT, always ready):
//   Q, O : query row n = g * q_len * 4 + r * 4 + head (group g, row r), line n * 4 + d / 32
//   K, V : token g * kv_len + j, line (token) * 4 + d / 32
//
// Stages, decoupled by buffer slots and descriptor FIFOs:
//   qload : Q tile (16 rows) -> row exponent + int16 mantissas (QSLOTS slots:
//           the tiles of two super-tiles)
//   kfetch: K blocks (KB block slots); a block is read once per super-tile
//   qk    : 16 lanes x 8 MACs; one key per 16 cycles (4 in a split tile) ->
//           score t (log2 domain), block row maximum (2 score slots)
//   smax  : alpha and p = exp2(t - m) with two exp units, running l per tile
//           of the super-tile (2 p slots)
//   vload : V block (raw BF16) and its exponent (3 slots), read once per super-tile
//   pv    : 16 lanes x 8 MACs; O_blk per 8-dimension chunk (2 hold slots)
//   merge : O = alpha * O + O_blk with exponent alignment (2 O slots of one
//           super-tile each)
//   final : 1 / l, O / l -> BF16, written to the O port
//
// Super-tiles (attn_pkg::blk_t, v4_sched): the tiles of a super-tile take
// each K / V block in turn, so the block is read from memory once. Every
// (tile, block) is processed exactly as with one tile per super-tile; only
// per-tile state (Q slot, m, l, O rows) is kept for all tiles of the super-tile.
// `rd_ok` paces the Q / K / V reads (a bandwidth limit in front of the core):
// a reader issues a line only in cycles where it is high.
//
// Coding rules: control registers sit in blocks reset by `srst`; datapath
// registers live in blocks without reset, so `start` does not fan out to them.
// Pipeline tags are aligned to the latencies LAT_*, MEM_LAT and RAM_LAT in
// attn_pkg. For 200 MHz every stage holds at most one carry chain or a few LUT
// levels, wide selects come from registers, and per-lane state that a stage
// would index by a counter is either precomputed or carried along with the data.
module v4_core #(parameter bit STREAM_PORTS = 0) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic split_disable,
    input  attn_pkg::job_t job,
    input  logic rd_ok,                        // a Q / K / V line read may be issued this cycle
    // STREAM_PORTS: each read fires only when its prefetched line is available.
    // o_credit may deassert mid-line; downstream reserves 8 lines for in-flight output.
    input logic [2:0] mem_ready,
    input logic o_credit,
    output logic busy,
    output logic done,
    output logic q_rd_en,
    output logic [19:0] q_raddr,
    input  logic [511:0] q_rdata,
    output logic k_rd_en,
    output logic [19:0] k_raddr,
    input  logic [511:0] k_rdata,
    output logic v_rd_en,
    output logic [19:0] v_raddr,
    input  logic [511:0] v_rdata,
    output logic o_we,
    output logic [19:0] o_waddr,
    output logic [511:0] o_wdata,
    output logic [1:0] final_activity, // {converter issue, output-credit wait}
    output logic [8*32-1:0] perf
);
    import attn_pkg::*;
    // `start` is registered once; srst covers the same cycle, so every job
    // starts from a clean control state
    logic start_q;
    job_t job_q;
    (* max_fanout = 64 *) logic srst;
    always_ff @(posedge clk) begin
        start_q <= rst_n && start;
        job_q <= job;
        srst <= !rst_n || start;
    end

    function automatic logic last_key(input blk_t b, input logic [4:0] jl);
        return 6'(jl) + 1'b1 == 6'(b.nk);
    endfunction
    function automatic logic [7:0] max8(input logic [7:0] a, input logic [7:0] b);
        return a > b ? a : b;
    endfunction
    // A tile with one query position ("split" tile, e.g. decode) fills the 16
    // lanes by splitting the head dimension: lane (g, h) = 4g + h works on line
    // g (dimensions 32g..32g+31) of head h. At step c (0..3) it takes the
    // quarter line (c + g) % 4, so the four groups read four different banks.
    // QK then needs 4 cycles per key (the 4 partial dots are summed) and PV
    // 4 steps per block instead of 16 chunks; all sums stay exact integers.
    function automatic logic split(input blk_t b);
        return !split_disable && b.npos == 1;
    endfunction
    function automatic logic [3:0] last_step(input blk_t b);
        return split(b) ? 4'd3 : 4'd15;
    endfunction
    localparam int CD = STREAM_PORTS ? 1 : MEM_LAT;               // memory data arrives CD cycles after the read
    localparam int CM = CD + LAT_MAX;     // its line maximum CM cycles after the read

    // ==================================================================
    // qload: a reader streams the tile's rows (4 lines each) into a raw line
    // RAM and finds each row's maximum exponent; a converter turns each
    // finished row into mantissas, one line per cycle.
    // ==================================================================
    blk_t ql_blk;
    logic ql_valid, ql_next;
    v4_sched ql_sched (.clk, .rst_n, .start(start_q), .job(job_q), .next(ql_next), .valid(ql_valid), .blk(ql_blk));
    // Q slots {super-tile parity, tile}: filled by qload, freed by qk after
    // the tile's last key
    logic q_produce, q_consume;
    logic [2:0] q_wslot, q_cslot;              // slot being loaded; slot qk frees
    logic [QSLOTS-1:0] qfull;
    exp_t eq [QSLOTS][R];
    always_ff @(posedge clk) begin
        if (srst) qfull <= 0;
        else for (int i = 0; i < QSLOTS; i++)
            if (q_produce && q_wslot == 3'(i)) qfull[i] <= 1;
            else if (q_consume && q_cslot == 3'(i)) qfull[i] <= 0;
    end

    typedef enum logic [1:0] {QR_IDLE, QR_READ, QR_WAIT} qr_state_t;
    qr_state_t qr_state;
    logic [3:0] qr_lane;
    logic [1:0] qr_c;
    logic qc_tile_done;                        // the tile's last line is in qmem
    wire qr_more = qr_lane != R - 1 && lane_valid(ql_blk, int'(qr_lane) + 1);
    assign q_rd_en = qr_state == QR_READ && rd_ok && (!STREAM_PORTS || mem_ready[0]);
    assign q_raddr = 20'({ADDR_W'(ql_blk.qrow0 + ADDR_W'({ql_blk.tile, qr_lane})), qr_c});
    assign q_produce = qr_state == QR_WAIT && qc_tile_done;
    assign ql_next = (qr_state == QR_IDLE && ql_valid && !ql_blk.first) || q_produce;

    always_ff @(posedge clk) begin
        if (srst) begin
            qr_state <= QR_IDLE; qr_lane <= 0; qr_c <= 0;
        end else
            case (qr_state)
                QR_IDLE:
                    if (ql_valid && ql_blk.first && !qfull[qslot(ql_blk)]) begin
                        qr_lane <= 0; qr_c <= 0; qr_state <= QR_READ; q_wslot <= qslot(ql_blk);
                    end
                QR_READ:
                    if (q_rd_en) begin
                        qr_c <= qr_c + 1'b1;
                        if (qr_c == 3) begin
                            if (qr_more) qr_lane <= qr_lane + 1'b1;
                            else qr_state <= QR_WAIT;
                        end
                    end
                QR_WAIT: if (qc_tile_done) qr_state <= QR_IDLE;
                default: qr_state <= QR_IDLE;
            endcase
    end

    // read tags: [s] belongs to the read issued s cycles ago
    logic [CM:1] qt_v;
    logic [3:0] qt_lane [CM:1];
    logic [1:0] qt_c [CM:1];
    logic [CM:1] qt_last;                      // last line of the tile's last row
    logic [7:0] ql_line_max, ql_row_max;
    v4_max_exp32 ql_mx (.clk, .bf16(q_rdata), .max_e(ql_line_max));
    always_ff @(posedge clk) begin
        if (srst) qt_v <= 0;
        else qt_v <= {qt_v[CM-1:1], q_rd_en};
    end
    always_ff @(posedge clk) begin
        qt_lane[1] <= qr_lane; qt_c[1] <= qr_c; qt_last[1] <= qr_c == 3 && !qr_more;
        for (int s = 2; s <= CM; s++) begin qt_lane[s] <= qt_lane[s-1]; qt_c[s] <= qt_c[s-1]; qt_last[s] <= qt_last[s-1]; end
        if (qt_v[CM]) ql_row_max <= qt_c[CM] == 0 ? ql_line_max : max8(ql_row_max, ql_line_max);
    end
    logic [511:0] qraw_rdata;
    logic [5:0] qraw_raddr;
    v4_lutram #(.WIDTH(512), .DEPTH(64)) qraw (.clk, .we(qt_v[CD]), .waddr({qt_lane[CD], qt_c[CD]}),
        .wdata(q_rdata), .raddr(qraw_raddr), .rdata(qraw_rdata));

    // finished rows: {lane, maximum, last}
    typedef struct packed {
        logic [3:0] lane;
        logic [7:0] max_e;
        logic last;
    } qrow_t;
    qrow_t qf_in, qf_out;
    logic qf_empty, qf_full, qf_pop;
    assign qf_in = '{lane: qt_lane[CM], max_e: qt_c[CM] == 0 ? ql_line_max : max8(ql_row_max, ql_line_max),
                     last: qt_last[CM]};
    v4_fifo #(.WIDTH($bits(qrow_t)), .DEPTH(4)) qrow_fifo (.clk, .rst_n(!srst),
        .push(qt_v[CM] && qt_c[CM] == 3), .din(qf_in), .full(qf_full), .pop(qf_pop), .dout(qf_out), .empty(qf_empty));

    // converter: C0 raw read, C1 line, C(1 + LAT_BFP) mantissas, write at QW
    localparam int QW = LAT_BFP + 2;
    logic qc_busy;
    logic [1:0] qc_c;
    qrow_t qc;
    assign qf_pop = !qf_empty && (!qc_busy || qc_c == 3);
    assign qraw_raddr = {qc.lane, qc_c};
    logic [QW:1] qw_v, qw_last;
    logic [3:0] qw_lane [QW:1];
    logic [1:0] qw_line [QW:1];
    logic [511:0] qc_line;
    logic [7:0] qc_max;
    logic [511:0] qc_mant;
    (* max_fanout = 64 *) logic [511:0] qw_mant;
    logic [R-1:0] qw_en;
    logic ql_split;                            // the tile being loaded is a split tile
    logic [4:0] qw_addr;
    for (genvar i = 0; i < 4; i++) begin : g_ql_conv
        v4_bfp8 conv (.clk, .bf16(qc_line[128*i +: 128]), .max_e(qc_max), .mant(qc_mant[128*i +: 128]));
    end
    assign qc_tile_done = qw_v[QW] && qw_last[QW];
    always_ff @(posedge clk) begin
        if (srst) begin
            qc_busy <= 0; qc_c <= 0; qw_v <= 0;
        end else begin
            if (qf_pop) begin qc_busy <= 1; qc_c <= 0; end
            else if (qc_busy) begin
                qc_c <= qc_c + 1'b1;
                if (qc_c == 3) qc_busy <= 0;
            end
            qw_v <= {qw_v[QW-1:1], qc_busy};
        end
    end
    always_ff @(posedge clk) begin
        if (qf_pop) qc <= qf_out;
        if (qc_busy && qc_c == 0) eq[q_wslot][qc.lane] <= unbias(qc.max_e);
        qw_lane[1] <= qc.lane; qw_line[1] <= qc_c; qw_last[1] <= qc.last && qc_c == 3;
        for (int s = 2; s <= QW; s++) begin qw_lane[s] <= qw_lane[s-1]; qw_line[s] <= qw_line[s-1]; qw_last[s] <= qw_last[s-1]; end
        qc_line <= qraw_rdata;
        qc_max <= qc.max_e;
        // one register before the 16 lane memories, with the lane decode
        qw_mant <= qc_mant;
        for (int l = 0; l < R; l++)
            qw_en[l] <= qw_v[QW-1] && (ql_split ? qw_lane[QW-1][1:0] == 2'(l) : qw_lane[QW-1] == 4'(l));
        ql_split <= split(ql_blk);
        qw_addr <= {q_wslot, qw_line[QW-1]};
    end

    // Q mantissas: per lane 4 banks (128-bit quarter lines) x {slot, line}
    (* max_fanout = 64 *) logic [4:0] f1_qaddr [4];  // per lane group
    logic [511:0] qrd [R];
    for (genvar l = 0; l < R; l++) begin : g_qmem
        for (genvar b = 0; b < 4; b++) begin : g_bank
            v4_lutram #(.WIDTH(128), .DEPTH(4 * QSLOTS)) qmem (.clk, .we(qw_en[l]), .waddr(qw_addr),
                .wdata(qw_mant[128*b +: 128]), .raddr(f1_qaddr[l / G]), .rdata(qrd[l][128*b +: 128]));
        end
    end

    // ==================================================================
    // kfetch: K blocks into KB block slots, one line per issued read. A block
    // is read for its first tile (kvfirst: nkf keys) and stays until qk has
    // run its last tile (slast). Every blk goes to qk through a descriptor
    // FIFO with the slot that holds its keys; a key is ready when its row
    // exponent is known (CM cycles after its last line is read). The
    // scheduler moves on as soon as a block's read starts, so blocks are
    // read back to back.
    // ==================================================================
    typedef struct packed {
        blk_t blk;
        logic [4:0] jl;                        // key index within the block
        logic [7:0] max_e;                     // biased row exponent of K
    } key_t;
    typedef struct packed {
        blk_t blk;
        logic [1:0] kslot;
    } kd_t;
    blk_t kf_blk;
    logic kf_valid, kf_next;
    v4_sched kf_sched (.clk, .rst_n, .start(start_q), .job(job_q), .next(kf_next), .valid(kf_valid), .blk(kf_blk));
    logic [1:0] kf_wslot;                      // next slot to allocate
    logic [1:0] kf_slot;                       // slot being read into (the last allocated)
    logic [2:0] k_used;                        // allocated slots not yet released by qk
    logic k_release;                           // qk finished a block's last tile
    logic [5:0] kcount [KB];                   // keys of the slot whose exponent is known
    logic kf_busy;
    logic [4:0] kf_j, kf_jlast;
    logic [1:0] kf_c;
    logic [ADDR_W-1:0] kf_kabs;
    logic kd_push, kd_full, kd_empty, kd_pop;
    kd_t kd_in, kd_out;
    v4_fifo_head #(.WIDTH($bits(kd_t)), .DEPTH(16)) kd_fifo (.clk, .rst_n(!srst), .push(kd_push), .din(kd_in),
        .full(kd_full), .pop(kd_pop), .dout(kd_out), .empty(kd_empty));
    assign k_rd_en = kf_busy && rd_ok && (!STREAM_PORTS || mem_ready[1]);
    assign k_raddr = 20'({ADDR_W'(kf_kabs + ADDR_W'(kf_j)), kf_c});
    wire kf_last_rd = k_rd_en && kf_c == 3 && kf_j == kf_jlast;
    // a block read starts when idle or straight after the last line of the previous one
    wire kf_start = kf_valid && kf_blk.kvfirst && !kd_full && k_used < KB && (!kf_busy || kf_last_rd);
    wire kf_pass = kf_valid && !kf_blk.kvfirst && !kd_full;   // a later tile of the block: no read
    assign kf_next = kf_start || kf_pass;
    assign kd_push = kf_next;
    assign kd_in = '{blk: kf_blk, kslot: kf_start ? kf_wslot : kf_slot};

    logic [CM:1] kt_v;
    logic [1:0] kt_slot [CM:1];
    logic [4:0] kt_j [CM:1];
    logic [1:0] kt_line [CM:1];
    logic [7:0] kf_rmax, kf_line_max;
    v4_max_exp32 kf_mx (.clk, .bf16(k_rdata), .max_e(kf_line_max));
    wire [7:0] kf_row_max = kt_line[CM] == 0 ? kf_line_max : max8(kf_rmax, kf_line_max);
    wire kt_key_done = kt_v[CM] && kt_line[CM] == 3;
    always_ff @(posedge clk) begin
        if (srst) begin
            kf_busy <= 0; kf_wslot <= 0; kf_slot <= 0; k_used <= 0; kt_v <= 0;
            for (int i = 0; i < KB; i++) kcount[i] <= 0;
        end else begin
            kt_v <= {kt_v[CM-1:1], k_rd_en};
            k_used <= k_used + kf_start - k_release;
            if (kf_start) begin
                kf_busy <= 1; kf_slot <= kf_wslot; kf_wslot <= kf_wslot + 1'b1;
            end else if (kf_last_rd) kf_busy <= 0;
            for (int i = 0; i < KB; i++)
                if (kf_start && kf_wslot == 2'(i)) kcount[i] <= 0;
                else if (kt_key_done && kt_slot[CM] == 2'(i)) kcount[i] <= kcount[i] + 1'b1;
        end
    end
    always_ff @(posedge clk) begin
        if (kf_start) begin
            kf_j <= 0; kf_c <= 0; kf_kabs <= kf_blk.kabs0; kf_jlast <= 5'(kf_blk.nkf - 1'b1);
        end else if (k_rd_en) begin
            kf_c <= kf_c + 1'b1;
            if (kf_c == 3) kf_j <= kf_j + 1'b1;
        end
        kt_slot[1] <= kf_slot; kt_j[1] <= kf_j; kt_line[1] <= kf_c;
        for (int s = 2; s <= CM; s++) begin kt_slot[s] <= kt_slot[s-1]; kt_j[s] <= kt_j[s-1]; kt_line[s] <= kt_line[s-1]; end
        if (kt_v[CM]) kf_rmax <= kf_row_max;
    end
    // K blocks: 4 banks (quarter lines) x {slot, key, line}; each bank has its own read address
    (* max_fanout = 64 *) logic [8:0] f1_kaddr [4];
    logic [511:0] krd;
    for (genvar b = 0; b < 4; b++) begin : g_kmem
        v4_sdp_ram #(.WIDTH(128), .DEPTH(4 * KB * BC), .STYLE("block"), .LAT(RAM_LAT)) kmem (.clk,
            .we(kt_v[CD]), .waddr({kt_slot[CD], kt_j[CD], kt_line[CD]}), .wdata(k_rdata[128*b +: 128]),
            .raddr(f1_kaddr[b]), .rdata(krd[128*b +: 128]));
    end
    // K row exponents: {slot, key}
    logic [6:0] f1_kxaddr;
    logic [7:0] kx_rdata;
    v4_lutram #(.WIDTH(8), .DEPTH(KB * BC)) kexp (.clk, .we(kt_key_done), .waddr({kt_slot[CM], kt_j[CM]}),
        .wdata(kf_row_max), .raddr(f1_kxaddr), .rdata(kx_rdata));

    // ==================================================================
    // qk: F0 issue, F1 RAM addresses and quarter selects, F2 Q slices
    //     (selected straight from the LUTRAM outputs) and the K exponent,
    //     F(1 + RAM_LAT) K lines, FS K slices, FK converted K, then multiplier
    //     inputs, products, three adder levels and the accumulator (FD); a
    //     split tile then adds the 4 partial dots (FE). One key takes 16
    //     cycles (4 in a split tile); keys run back to back; when the next key
    //     belongs to another Q slot, qk waits a cycle so the Q exponents follow.
    // ==================================================================
    localparam int FQ = 2;                     // Q slices
    localparam int FS = 2 + RAM_LAT;           // K slices
    localparam int FK = FS + LAT_BFP;          // converted K
    localparam int FM = FK + 2;                // multiplier inputs (after a fabric register at FK + 1)
    localparam int FD = FM + 5;                // products, 3 adder levels, accumulator
    localparam int FE = FD + 2;                // partial dots of a split tile summed
    localparam int DQ = 8;                     // dot FIFO depth: covers take -> pop at 4 cycles per key
    logic qk_run, qk_split;
    logic [3:0] qk_c, qk_last_c;
    blk_t qk_blk;                              // blk of the key being issued
    logic [1:0] qk_kslot;
    logic [4:0] qk_jl;
    logic qd_more;                             // qk_blk has keys after qk_jl
    logic [2:0] qk_qslot;                      // Q slot that qk_eqs follows
    logic [R*EW-1:0] qk_eqs;
    logic [1:0] s_reserved;                    // score slots held by blocks QK has started
    logic s_release;                           // smax finished reading a score slot
    logic [3:0] dq_reserved;
    logic dq_pop;
    wire qk_end_key = qk_run && qk_c == qk_last_c;
    wire qk_free = !qk_run || qk_end_key;      // a key may be taken this cycle
    // the next key: the current blk's next one, or key 0 of the FIFO head
    wire nx_new = !qd_more;
    blk_t nx_blk;
    assign nx_blk = nx_new ? kd_out.blk : qk_blk;
    wire [1:0] nx_kslot = nx_new ? kd_out.kslot : qk_kslot;
    wire [4:0] nx_jl = nx_new ? 5'd0 : qk_jl + 1'b1;
    wire nx_avail = !nx_new || !kd_empty;
    wire nx_qok = qslot(nx_blk) == qk_qslot && qfull[qk_qslot];
    wire qk_take = qk_free && nx_avail && nx_qok && 6'(nx_jl) < kcount[nx_kslot] &&
                   dq_reserved < DQ && (nx_jl != 0 || s_reserved < 2);
    // the Q exponents switch to the next blk's slot once no key reads them at F0
    wire qk_qswitch = qk_free && nx_avail && qslot(nx_blk) != qk_qslot;
    assign kd_pop = qk_take && nx_new;
    wire qk_last_key = last_key(qk_blk, qk_jl);
    assign k_release = qk_end_key && qk_last_key && qk_blk.slast;
    assign q_consume = qk_end_key && qk_last_key && qk_blk.last;
    assign q_cslot = qslot(qk_blk);

    logic [FE:1] f_v, f_split;
    logic [3:0] f_c [FE:1];
    key_t f_key [FE:1];
    logic [7:0] f_kmx [FE:2];                  // K row exponent from F2
    logic [R*EW-1:0] f_eqs [FE:1];
    (* max_fanout = 128 *) logic [1:0] f1_sel [4];
    logic [1:0] fk_sel [FS-1:2][4];            // quarter selects aligned with the K lines
    logic signed [MW-1:0] fq [FQ:FM][R][W];   // Q slice from FQ, aligned with the converted K at FK
    logic [127:0] fs_k [4], fk_mk [4], fm_mk [4];
    (* dont_touch = "true" *) logic [127:0] fr_mk [4];  // stays in fabric: the DSP absorbs only fm_mk
    logic [7:0] fs_max;
    logic signed [31:0] fp_prod [R][W];
    logic signed [32:0] fa1 [R][4];
    // first level: the DSP post-adder (PCIN) of the second product; the rest in
    // fabric, otherwise synthesis spends a DSP per add
    (* use_dsp = "no" *) logic signed [33:0] fa2 [R][2];
    (* use_dsp = "no" *) logic signed [34:0] fa3 [R];
    logic signed [DOT_W-1:0] f_acc [R], fe1 [R], fe2 [R], fe1b [G];
    for (genvar g = 0; g < 4; g++) begin : g_kconv
        v4_bfp8 kconv (.clk, .bf16(fs_k[g]), .max_e(fs_max), .mant(fk_mk[g]));
    end

    always_ff @(posedge clk) begin
        if (srst) begin
            qk_run <= 0; qk_c <= 0; qd_more <= 0; qk_qslot <= 0; f_v <= 0; s_reserved <= 0; dq_reserved <= 0;
        end else begin
            if (qk_take) begin
                qk_run <= 1; qk_c <= 0; qd_more <= 6'(nx_jl) + 1'b1 < nx_blk.nk;
            end else if (qk_run) begin
                if (qk_end_key) qk_run <= 0;
                qk_c <= qk_c + 1'b1;
            end
            if (qk_qswitch) qk_qslot <= qslot(nx_blk);
            s_reserved <= s_reserved + (qk_take && nx_jl == 0) - s_release;
            dq_reserved <= dq_reserved + qk_take - dq_pop;
            f_v <= {f_v[FE-1:1], qk_run};
        end
    end
    always_ff @(posedge clk) begin
        // Block metadata changes only when taking a new FIFO head, not on
        // every key of that block. Keep the key-index update independent.
        if (kd_pop) begin
            qk_blk <= kd_out.blk; qk_kslot <= kd_out.kslot;
            qk_split <= split(kd_out.blk);
            qk_last_c <= last_step(kd_out.blk);
        end
        if (qk_take) qk_jl <= nx_jl;
        // the Q slot being read holds still while its keys run, and qk_qslot
        // moves a cycle before a key of another slot is taken
        for (int l = 0; l < R; l++) qk_eqs[EW*l +: EW] <= eq[qk_qslot][l];
        f_c[1] <= qk_c; f_key[1] <= '{blk: qk_blk, jl: qk_jl, max_e: 8'd0}; f_eqs[1] <= qk_eqs; f_split[1] <= qk_split;
        for (int s = 2; s <= FE; s++) begin
            f_c[s] <= f_c[s-1]; f_key[s] <= f_key[s-1]; f_eqs[s] <= f_eqs[s-1]; f_split[s] <= f_split[s-1];
        end
        // F1: RAM addresses and quarter-line selects (line g, quarter (c + g) % 4 in a split tile)
        for (int g = 0; g < 4; g++) begin
            f1_qaddr[g] <= {qk_qslot, qk_split ? 2'(g) : qk_c[3:2]};
            f1_kaddr[g] <= {qk_kslot, qk_jl, qk_split ? 2'(g) - qk_c[1:0] : qk_c[3:2]};   // bank g serves group g - c
            f1_sel[g] <= qk_split ? qk_c[1:0] + 2'(g) : qk_c[1:0];
        end
        f1_kxaddr <= {qk_kslot, qk_jl};
        // F2: Q slices per lane, taken from the LUTRAM read data; the K exponent
        for (int l = 0; l < R; l++)
            for (int w = 0; w < W; w++) fq[FQ][l][w] <= $signed(qrd[l][128*f1_sel[l/G] + 16*w +: 16]);
        for (int s = FQ + 1; s <= FM; s++) fq[s] <= fq[s-1];
        f_kmx[2] <= kx_rdata;
        for (int s = 3; s <= FE; s++) f_kmx[s] <= f_kmx[s-1];
        fk_sel[2] <= f1_sel;
        for (int s = 3; s <= FS - 1; s++) fk_sel[s] <= fk_sel[s-1];
        // FS: K quarter lines per lane group, from the block RAM read data
        for (int g = 0; g < 4; g++) fs_k[g] <= krd[128*fk_sel[FS-1][g] +: 128];
        fs_max <= f_kmx[FS-1];
        // FK + 1 fabric register, FM multiplier inputs: keeps the conversion out of the DSP input path
        fr_mk <= fk_mk;
        fm_mk <= fr_mk;
        // products, adder tree, accumulation over the chunks of a key
        for (int l = 0; l < R; l++)
            for (int w = 0; w < W; w++) fp_prod[l][w] <= fq[FM][l][w] * $signed(fm_mk[l/G][16*w +: 16]);
        for (int l = 0; l < R; l++) begin
            for (int i = 0; i < 4; i++) fa1[l][i] <= 33'(fp_prod[l][2*i]) + 33'(fp_prod[l][2*i+1]);
            for (int i = 0; i < 2; i++) fa2[l][i] <= 34'(fa1[l][2*i]) + 34'(fa1[l][2*i+1]);
            fa3[l] <= 35'(fa2[l][0]) + 35'(fa2[l][1]);
        end
        if (f_v[FD-1])
            for (int l = 0; l < R; l++)
                f_acc[l] <= f_c[FD-1] == 0 ? DOT_W'(fa3[l]) : f_acc[l] + DOT_W'(fa3[l]);
        // FD + 1, FE: a split tile sums the partial dots of the 4 groups into lanes 0..3
        for (int l = 0; l < R; l++) fe1[l] <= f_split[FD] && l < G ? f_acc[l] + f_acc[l+G] : f_acc[l];
        for (int h = 0; h < G; h++) fe1b[h] <= f_acc[h+2*G] + f_acc[h+3*G];
        for (int l = 0; l < R; l++) fe2[l] <= f_split[FD+1] && l < G ? fe1[l] + fe1b[l] : fe1[l];
    end

    // dot FIFO -> serializer (shift register) -> score unit -> score RAM + block maximum
    typedef struct packed {
        logic [R*DOT_W-1:0] dots;
        logic [R*EW-1:0] eqs;
        key_t key;
        logic signed [POS_W+1:0] diff;         // key position - tile position base
    } dot_t;
    dot_t dq_in, dq_out, sr;
    logic dq_empty, dq_full;
    always_comb begin
        for (int l = 0; l < R; l++) dq_in.dots[DOT_W*l +: DOT_W] = fe2[l];
        dq_in.eqs = f_eqs[FE];
        dq_in.key = '{blk: f_key[FE].blk, jl: f_key[FE].jl, max_e: f_kmx[FE]};
        dq_in.diff = (POS_W+2)'(f_key[FE].blk.k0) + (POS_W+2)'(f_key[FE].jl) - (POS_W+2)'(f_key[FE].blk.pos_base);
    end
    v4_fifo #(.WIDTH($bits(dot_t)), .DEPTH(DQ)) dot_fifo (.clk, .rst_n(!srst),
        .push(f_v[FE] && f_c[FE] == (f_split[FE] ? 4'd3 : 4'd15)),
        .din(dq_in), .full(dq_full), .pop(dq_pop), .dout(dq_out), .empty(dq_empty));

    logic sr_run, sr_split;
    logic [3:0] sr_lane, sr_last;
    logic [LAT_SCORE:1] sv_v, sv_kv, sv_split;
    logic [3:0] sv_lane [LAT_SCORE:1];
    key_t sv_key [LAT_SCORE:1];
    logic signed [TW-1:0] sc_t;
    logic sw_slot;                             // score slot being written (block parity)
    logic signed [TW-1:0] mrot [R];            // block maximum, rotating: mrot[0] is the lane being scored
    logic smd_push;
    blk_t smd_blk;
    logic smd_slot;
    assign dq_pop = (!sr_run || sr_lane == sr_last) && !dq_empty;   // next key on the last lane
    v4_score score (.clk, .dot($signed(sr.dots[DOT_W-1:0])), .eq(sr.eqs[EW-1:0]),
        .ek(unbias(sr.key.max_e)), .t(sc_t));
    wire sv_hit = sv_v[LAT_SCORE];
    wire [3:0] sv_l = sv_lane[LAT_SCORE];
    key_t sv_k;
    assign sv_k = sv_key[LAT_SCORE];
    wire sv_block_end = sv_hit && sv_l == (sv_split[LAT_SCORE] ? 4'(G - 1) : 4'(R - 1)) && last_key(sv_k.blk, sv_k.jl);
    // key jl is visible to lane l when the lane holds a query and k0 + jl <= its position
    wire sr_kv = 3'(sr_lane / G) < sr.key.blk.npos && sr.diff <= $signed((POS_W+2)'(sr_lane / G));

    always_ff @(posedge clk) begin
        if (srst) begin
            sr_run <= 0; sr_lane <= 0; sv_v <= 0; sw_slot <= 0; smd_push <= 0;
        end else begin
            if (dq_pop) begin sr_run <= 1; sr_lane <= 0; end
            else if (sr_run) begin
                if (sr_lane == sr_last) sr_run <= 0;
                sr_lane <= sr_lane + 1'b1;
            end
            sv_v <= {sv_v[LAT_SCORE-1:1], sr_run};
            smd_push <= sv_block_end;           // next cycle: the maxima are complete and aligned
            if (sv_block_end) sw_slot <= !sw_slot;
        end
    end
    always_ff @(posedge clk) begin
        if (dq_pop) begin
            sr <= dq_out;
            sr_split <= split(dq_out.key.blk);
            sr_last <= split(dq_out.key.blk) ? 4'(G - 1) : 4'(R - 1);   // a split tile scores lanes 0..3
        end else if (sr_run) begin
            sr.dots <= sr.dots >> DOT_W;
            sr.eqs <= sr.eqs >> EW;
        end
        sv_lane[1] <= sr_lane; sv_key[1] <= sr.key; sv_kv[1] <= sr_kv; sv_split[1] <= sr_split;
        for (int s = 2; s <= LAT_SCORE; s++) begin
            sv_lane[s] <= sv_lane[s-1]; sv_key[s] <= sv_key[s-1]; sv_kv[s] <= sv_kv[s-1]; sv_split[s] <= sv_split[s-1];
        end
        // lanes arrive in order for every key (0..15, or 0..3 in a split tile),
        // so the maxima rotate by one per score over 16 (or 4) entries
        if (sv_hit) begin
            logic signed [TW-1:0] nm;
            nm = sv_kv[LAT_SCORE] && (sv_k.jl == 0 || sc_t > mrot[0]) ? sc_t : mrot[0];
            for (int l = 0; l < R - 1; l++) mrot[l] <= sv_split[LAT_SCORE] && l == G - 1 ? nm : mrot[l+1];
            mrot[R-1] <= nm;
        end
        if (sv_block_end) begin smd_blk <= sv_k.blk; smd_slot <= sw_slot; end
    end
    // score RAMs for even / odd lanes: address {slot, lane / 2, jl}
    logic [8:0] sm_raddr;
    logic signed [TW-1:0] sm_t [2];
    v4_sdp_ram #(.WIDTH(TW), .DEPTH(512), .STYLE("block"), .LAT(RAM_LAT)) score_even (.clk,
        .we(sv_hit && !sv_l[0]), .waddr({sw_slot, sv_l[3:1], sv_k.jl}), .wdata(sc_t), .raddr(sm_raddr), .rdata(sm_t[0]));
    v4_sdp_ram #(.WIDTH(TW), .DEPTH(512), .STYLE("block"), .LAT(RAM_LAT)) score_odd (.clk,
        .we(sv_hit && sv_l[0]), .waddr({sw_slot, sv_l[3:1], sv_k.jl}), .wdata(sc_t), .raddr(sm_raddr), .rdata(sm_t[1]));

    typedef struct packed {
        blk_t blk;
        logic [R*TW-1:0] mblk;
        logic slot;
    } smd_t;
    smd_t smd_in, smd_out, smd;
    logic smd_pop, smd_empty, smd_full;
    always_comb begin
        smd_in.blk = smd_blk;
        smd_in.slot = smd_slot;
        for (int l = 0; l < R; l++) smd_in.mblk[TW*l +: TW] = mrot[l];
    end
    v4_fifo #(.WIDTH($bits(smd_t)), .DEPTH(2)) smd_fifo (.clk, .rst_n(!srst), .push(smd_push), .din(smd_in),
        .full(smd_full), .pop(smd_pop), .dout(smd_out), .empty(smd_empty));

    // ==================================================================
    // smax: per lane pair (only pairs that hold queries: 2 in a split tile).
    // SEL picks the pair's state, MNEW forms the new
    // maximum and reads score 0, KEYS sends alpha's argument and then one
    // score per cycle to the exp units; l * alpha runs while the keys drain;
    // LWRITE stores l, m. The score RAM latency (2) keeps the alpha argument
    // and the first key's argument in different cycles.
    // ==================================================================
    logic p_produce, p_consume, p_can_produce, p_can_consume;
    logic [0:0] p_wslot, p_rslot;
    v4_slots #(.N(2)) p_ring (.clk, .rst_n(!srst), .produce(p_produce), .consume(p_consume),
        .wr(p_wslot), .rd(p_rslot), .can_produce(p_can_produce), .can_consume(p_can_consume));

    typedef enum logic [3:0] {SM_IDLE, SM_PREP, SM_LIM, SM_SEL, SM_MNEW, SM_KEYS, SM_DRAIN, SM_LWRITE, SM_DONE} sm_state_t;
    sm_state_t sm_state;
    logic [2:0] sm_pair, sm_last_pair;         // pairs 0 .. 2 * npos - 1 hold queries
    logic [5:0] sm_j;                          // next score to read
    // running state of every tile of the super-tile; a blk works on tile smd.blk.sub
    logic signed [TW-1:0] m_run [SMAX][R];
    logic [LW-1:0] l_run [SMAX][R];
    logic [R-1:0] started [SMAX];
    logic [1:0] sm_sub;
    logic [PW-1:0] alpha [R];
    logic [R-1:0] sm_act;                      // lanes that see the block
    logic [5:0] sm_lim [T];                    // last visible key per query position (saturated)
    logic signed [POS_W+1:0] sm_d0;            // pos_base - k0
    // the pair's state
    logic signed [TW-1:0] pm_mb [2], pm_mr [2], sm_mnew [2];
    logic [LW-1:0] pm_l [2];
    logic pm_st [2], pm_act [2];
    logic [5:0] pm_lim [2];                    // last visible key (saturated)
    // score reads, exp arguments, exp results
    logic [RAM_LAT:1] rd_v;
    logic [4:0] rd_j [RAM_LAT:1];
    logic [32:0] ex [2];
    logic ex_v, ex_alpha;
    logic [4:0] ex_j;
    logic [PW-1:0] ep [2];
    logic [LAT_EXP:1] et_v, et_alpha;
    logic [4:0] et_j [LAT_EXP:1];
    logic [LW-1:0] psum [2];
    logic sm_pdone, sm_ldone;
    logic [LAT_MRS:1] lm_v;
    logic signed [LW:0] lmul_y [2];
    logic [LW-1:0] lm_y [2];
    v4_exp2 exp_a (.clk, .x(ex[0]), .p(ep[0]));
    v4_exp2 exp_b (.clk, .x(ex[1]), .p(ep[1]));
    wire et_hit = et_v[LAT_EXP];
    wire [4:0] et_jl = et_j[LAT_EXP];
    for (genvar i = 0; i < 2; i++) begin : g_lmul
        v4_mul_round_shift #(.OW(LW + 1)) lmul (.clk, .o((LW+1)'(pm_l[i])), .a(ep[i]), .s(8'(FP)),
            .y(lmul_y[i]));
    end

    // PV descriptor and the finished l of each tile
    typedef struct packed {
        blk_t blk;
        logic [R-1:0] act;
        logic [R*PW-1:0] alpha;
        logic pslot;
    } pvd_t;
    pvd_t pvd_in, pvd_out;
    logic pvd_push, pvd_pop, pvd_empty, pvd_full;
    v4_fifo #(.WIDTH($bits(pvd_t)), .DEPTH(2)) pvd_fifo (.clk, .rst_n(!srst), .push(pvd_push), .din(pvd_in),
        .full(pvd_full), .pop(pvd_pop), .dout(pvd_out), .empty(pvd_empty));
    typedef struct packed {
        blk_t blk;
        logic [R*LW-1:0] l;
    } tld_t;
    tld_t tl_in, tl_out;
    logic tl_push, tl_pop, tl_empty, tl_full;
    v4_fifo #(.WIDTH($bits(tld_t)), .DEPTH(QSLOTS)) tl_fifo (.clk, .rst_n(!srst), .push(tl_push), .din(tl_in),
        .full(tl_full), .pop(tl_pop), .dout(tl_out), .empty(tl_empty));
    always_comb begin
        pvd_in.blk = smd.blk;
        pvd_in.act = sm_act;
        pvd_in.pslot = p_wslot;
        for (int l = 0; l < R; l++) pvd_in.alpha[PW*l +: PW] = alpha[l];
        tl_in.blk = smd.blk;
        for (int l = 0; l < R; l++) tl_in.l[LW*l +: LW] = l_run[sm_sub][l];
    end
    assign smd_pop = sm_state == SM_IDLE && !smd_empty && p_can_produce && !pvd_full && !tl_full;
    wire sm_rd = sm_state == SM_MNEW || (sm_state == SM_KEYS && sm_j != 6'(smd.blk.nk));
    assign sm_raddr = {smd.slot, sm_pair, sm_state == SM_MNEW ? 5'd0 : 5'(sm_j)};
    assign pvd_push = sm_state == SM_DONE;
    assign tl_push = sm_state == SM_DONE && smd.blk.last;
    assign p_produce = sm_state == SM_DONE;
    assign s_release = sm_state == SM_DONE;

    // p RAM: one per lane pair, address {slot, j}, data {p_odd, p_even}
    logic [5:0] pv_praddr;
    logic [2*PW-1:0] pv_pword [8];
    logic [1:0] ep_mask;
    always_comb
        for (int i = 0; i < 2; i++) ep_mask[i] = pm_act[i] && 6'(et_jl) <= pm_lim[i];
    // writes are registered once (PV reads a p slot only after p_produce)
    logic [7:0] pw_en;
    logic [5:0] pw_addr;
    logic [2*PW-1:0] pw_data;
    always_ff @(posedge clk) begin
        for (int k = 0; k < 8; k++) pw_en[k] <= !srst && et_hit && !et_alpha[LAT_EXP] && sm_pair == 3'(k);
        pw_addr <= {p_wslot, et_jl};
        pw_data <= {ep_mask[1] ? ep[1] : PW'(0), ep_mask[0] ? ep[0] : PW'(0)};
    end
    for (genvar k = 0; k < 8; k++) begin : g_pram
        v4_sdp_ram #(.WIDTH(2*PW), .DEPTH(64), .STYLE("distributed")) pram (.clk,
            .we(pw_en[k]), .waddr(pw_addr), .wdata(pw_data), .raddr(pv_praddr), .rdata(pv_pword[k]));
    end

    always_ff @(posedge clk) begin
        if (srst) begin
            sm_state <= SM_IDLE; rd_v <= 0; ex_v <= 0; et_v <= 0; lm_v <= 0;
            for (int t = 0; t < SMAX; t++) started[t] <= 0;
            sm_pdone <= 0; sm_ldone <= 0;
        end else begin
            rd_v <= {rd_v[RAM_LAT-1:1], sm_rd};
            ex_v <= (sm_state == SM_KEYS && sm_j == 1) || rd_v[RAM_LAT];
            et_v <= {et_v[LAT_EXP-1:1], ex_v};
            lm_v <= {lm_v[LAT_MRS-1:1], et_hit && et_alpha[LAT_EXP]};
            if (et_hit && !et_alpha[LAT_EXP] && last_key(smd.blk, et_jl)) sm_pdone <= 1;
            if (lm_v[LAT_MRS]) sm_ldone <= 1;
            case (sm_state)
                SM_IDLE:
                    if (smd_pop) begin
                        sm_pair <= 0; sm_state <= SM_PREP;
                        if (smd_out.blk.first) started[smd_out.blk.sub] <= 0;
                    end
                SM_PREP: sm_state <= SM_LIM;                    // lane masks, pos_base - k0
                SM_LIM: sm_state <= SM_SEL;                     // key limit per query position
                SM_SEL: begin sm_pdone <= 0; sm_ldone <= 0; sm_state <= SM_MNEW; end
                SM_MNEW: begin sm_j <= 1; sm_state <= SM_KEYS; end
                SM_KEYS:
                    if (sm_j == 6'(smd.blk.nk)) sm_state <= SM_DRAIN;
                    else sm_j <= sm_j + 1'b1;
                SM_DRAIN: if (sm_pdone && sm_ldone) sm_state <= SM_LWRITE;
                SM_LWRITE: begin
                    for (int i = 0; i < 2; i++) if (pm_act[i]) started[sm_sub][2 * int'(sm_pair) + i] <= 1;
                    if (sm_pair == sm_last_pair) sm_state <= SM_DONE;
                    else begin sm_pair <= sm_pair + 1'b1; sm_state <= SM_SEL; end
                end
                SM_DONE: sm_state <= SM_IDLE;
                default: sm_state <= SM_IDLE;
            endcase
        end
    end
    always_ff @(posedge clk) begin
        if (smd_pop) begin smd <= smd_out; sm_sub <= smd_out.blk.sub; end
        if (sm_state == SM_PREP) begin
            sm_act <= act_mask(smd.blk);
            sm_last_pair <= 3'(2 * smd.blk.npos - 1);
            sm_d0 <= (POS_W+2)'(smd.blk.pos_base) - (POS_W+2)'(smd.blk.k0);
        end
        if (sm_state == SM_LIM)
            for (int t = 0; t < T; t++) begin
                logic signed [POS_W+1:0] lim;
                lim = sm_d0 + (POS_W+2)'(t);
                sm_lim[t] <= lim > 63 ? 6'd63 : 6'(lim);
            end
        if (sm_state == SM_SEL)
            for (int i = 0; i < 2; i++) begin
                int l;
                l = 2 * int'(sm_pair) + i;
                pm_mb[i] <= smd.mblk[TW*l +: TW];
                pm_mr[i] <= m_run[sm_sub][l];
                pm_l[i] <= l_run[sm_sub][l];
                pm_st[i] <= started[sm_sub][l];
                pm_act[i] <= sm_act[l];
                pm_lim[i] <= sm_lim[l / G];
                psum[i] <= 0;
            end
        if (sm_state == SM_MNEW)
            for (int i = 0; i < 2; i++) sm_mnew[i] <= !pm_st[i] || pm_mb[i] > pm_mr[i] ? pm_mb[i] : pm_mr[i];
        // exp arguments: alpha in the first KEYS cycle, then m_new - t for each score read
        rd_j[1] <= sm_state == SM_MNEW ? 5'd0 : 5'(sm_j);
        for (int s = 2; s <= RAM_LAT; s++) rd_j[s] <= rd_j[s-1];
        if (sm_state == SM_KEYS && sm_j == 1) begin
            for (int i = 0; i < 2; i++) ex[i] <= pm_st[i] ? 33'(34'(sm_mnew[i]) - 34'(pm_mr[i])) : 33'd0;
            ex_alpha <= 1; ex_j <= 0;
        end else begin
            for (int i = 0; i < 2; i++) ex[i] <= 33'(34'(sm_mnew[i]) - 34'(sm_t[i]));
            ex_alpha <= 0; ex_j <= rd_j[RAM_LAT];
        end
        et_alpha <= {et_alpha[LAT_EXP-1:1], ex_alpha};
        et_j[1] <= ex_j;
        for (int s = 2; s <= LAT_EXP; s++) et_j[s] <= et_j[s-1];
        // exp results
        if (et_hit) begin
            if (et_alpha[LAT_EXP])                  // rows that start in this block take alpha = 0
                for (int i = 0; i < 2; i++) alpha[2 * int'(sm_pair) + i] <= pm_st[i] ? ep[i] : PW'(0);
            else
                for (int i = 0; i < 2; i++) if (ep_mask[i]) psum[i] <= psum[i] + LW'(ep[i]);
        end
        if (lm_v[LAT_MRS]) for (int i = 0; i < 2; i++) lm_y[i] <= LW'(lmul_y[i]);
        if (sm_state == SM_LWRITE)
            for (int i = 0; i < 2; i++) begin
                int l;
                l = 2 * int'(sm_pair) + i;
                if (pm_act[i]) begin
                    l_run[sm_sub][l] <= (pm_st[i] ? lm_y[i] : LW'(0)) + psum[i];
                    m_run[sm_sub][l] <= sm_mnew[i];
                end
            end
    end

    // ==================================================================
    // vload: V block (raw BF16) into 4 banks of 128 bits, block exponent.
    // A block is read for its first tile (kvfirst) and kept until pv has run
    // its last tile. Blocks follow each other without a gap: the scheduler
    // moves on when a read starts, and the exponent of one block is still
    // being found while the next block is read.
    // ==================================================================
    blk_t vl_blk;
    logic vl_valid, vl_next;
    v4_sched vl_sched (.clk, .rst_n, .start(start_q), .job(job_q), .next(vl_next), .valid(vl_valid), .blk(vl_blk));
    logic v_produce, v_consume, v_can_produce, v_can_consume;
    logic [1:0] v_wslot, v_rslot;
    v4_slots #(.N(3)) v_ring (.clk, .rst_n(!srst), .produce(v_produce), .consume(v_consume),
        .wr(v_wslot), .rd(v_rslot), .can_produce(v_can_produce), .can_consume(v_can_consume));
    logic [7:0] vmax [3];
    logic vl_run;
    logic [1:0] vl_slot;                       // slot being read into
    logic [1:0] v_alloc;                       // slots being read or holding a block
    logic [4:0] vl_t, vl_tlast;
    logic [1:0] vl_c;
    logic [ADDR_W-1:0] vl_kabs;
    logic [CM:1] vt_v, vt_first, vt_last;
    logic [1:0] vt_slot [CM:1];
    logic [8:0] vt_waddr [CD:1];
    logic [7:0] vl_rmax, vl_line_max;
    v4_max_exp32 vl_mx (.clk, .bf16(v_rdata), .max_e(vl_line_max));
    assign v_rd_en = vl_run && rd_ok && (!STREAM_PORTS || mem_ready[2]);
    assign v_raddr = 20'({ADDR_W'(vl_kabs + ADDR_W'(vl_t)), vl_c});
    wire vl_end = v_rd_en && vl_c == 3 && vl_t == vl_tlast;
    wire vl_start = vl_valid && vl_blk.kvfirst && v_alloc < 3 && (!vl_run || vl_end);
    wire vl_pass = vl_valid && !vl_blk.kvfirst;                 // a later tile of the block
    wire [7:0] vl_blk_max = vt_first[CM] ? vl_line_max : max8(vl_rmax, vl_line_max);
    assign vl_next = vl_start || vl_pass;
    assign v_produce = vt_v[CM] && vt_last[CM];
    logic [8:0] pv_vraddr [4];
    logic [127:0] pv_vbank [4];
    for (genvar b = 0; b < 4; b++) begin : g_vbank
        v4_sdp_ram #(.WIDTH(128), .DEPTH(512), .STYLE("block"), .LAT(RAM_LAT)) vbank (.clk, .we(vt_v[CD]),
            .waddr(vt_waddr[CD]), .wdata(v_rdata[128*b +: 128]), .raddr(pv_vraddr[b]), .rdata(pv_vbank[b]));
    end

    always_ff @(posedge clk) begin
        if (srst) begin
            vl_run <= 0; vt_v <= 0; vl_t <= 0; vl_c <= 0; vl_slot <= 0; v_alloc <= 0;
        end else begin
            vt_v <= {vt_v[CM-1:1], v_rd_en};
            v_alloc <= v_alloc + vl_start - v_consume;
            if (vl_end) vl_slot <= vl_slot == 2 ? 2'd0 : vl_slot + 1'b1;
            if (vl_start) begin
                vl_run <= 1; vl_t <= 0; vl_c <= 0; vl_kabs <= vl_blk.kabs0; vl_tlast <= 5'(vl_blk.nv - 1'b1);
            end else if (v_rd_en) begin
                vl_c <= vl_c + 1'b1;
                if (vl_c == 3) vl_t <= vl_t + 1'b1;
                if (vl_end) vl_run <= 0;
            end
        end
    end
    always_ff @(posedge clk) begin
        vt_first[1] <= vl_t == 0 && vl_c == 0; vt_last[1] <= vl_end; vt_slot[1] <= vl_slot;
        vt_waddr[1] <= {vl_slot, vl_t, vl_c};
        for (int s = 2; s <= CM; s++) begin vt_first[s] <= vt_first[s-1]; vt_last[s] <= vt_last[s-1]; vt_slot[s] <= vt_slot[s-1]; end
        for (int s = 2; s <= CD; s++) vt_waddr[s] <= vt_waddr[s-1];
        if (vt_v[CM]) vl_rmax <= vl_blk_max;
        if (v_produce) vmax[vt_slot[CM]] <= vl_blk_max;
    end

    // ==================================================================
    // pv: for each chunk c, for each key j: acc[lane][w] += p[lane][j] * mv[j][8c + w]
    // (a split tile runs 4 steps; lane (g, h) takes quarter (c + g) % 4 of line g).
    // P0 read, P(RAM_LAT) V lines, PVR V quarter per group, PVK converted V,
    // PVM multiplier inputs, PVP products, PD accumulator holds the chunk
    // ==================================================================
    localparam int PVR = RAM_LAT + 1;
    localparam int PVK = PVR + LAT_BFP;
    localparam int PVM = PVK + 2;              // after a fabric register at PVK + 1
    localparam int PVP = PVM + 1;
    localparam int PD = PVP + 1;
    typedef struct packed {
        blk_t blk;
        logic split;
        logic [R-1:0] act;
        logic [R*PW-1:0] alpha;
        logic [7:0] vmax;
        logic [3:0] c;
    } hold_meta_t;
    logic pv_run, pv_split;
    pvd_t pvd;
    pvd_t pvdh [2];                            // descriptors of the blocks in the pipeline
    logic pv_par;
    logic [3:0] pv_c, pv_last_c;
    logic [4:0] pv_j;
    logic [1:0] pv_credit;
    logic h_release;                           // merge finished a hold slot
    logic [PD:1] pq_v, pq_last, pq_par, pq_split;
    (* max_fanout = 64 *) logic [PD:1] pq_first;
    logic [3:0] pq_c [PD:1];
    logic [7:0] vmax_p [PD:1];
    logic [127:0] pv_vraw [4], pv_mv [4], pm_mv [4];
    (* dont_touch = "true" *) logic [127:0] pr_mv [4];
    logic [PW-1:0] pp [2:PVM][R];              // p of every lane, aligned with the converted V
    logic signed [PW+MW:0] pv_prod [R][W];
    logic signed [OBW-1:0] acc [R][W];
    logic signed [OBW-1:0] hold [2][R][W];     // shifts out one lane per merge cycle
    hold_meta_t hmeta [2];
    logic [1:0] hvalid;
    logic h_wslot, h_rslot;
    logic mg_run, mg_hslot;
    wire pv_chunk_start = pv_j == 0;
    wire pv_can_issue = pv_run && (!pv_chunk_start || pv_credit != 0);
    assign pvd_pop = !pv_run && !pvd_empty && v_can_consume;
    assign pv_praddr = {pvd.pslot, pv_j};
    for (genvar b = 0; b < 4; b++) begin : g_vaddr      // bank b serves group b - c in a split tile
        assign pv_vraddr[b] = {v_rslot, pv_j, pv_split ? 2'(b) - pv_c[1:0] : pv_c[3:2]};
    end
    assign p_consume = pv_can_issue && pv_c == pv_last_c && last_key(pvd.blk, pv_j);
    assign v_consume = p_consume && pvd.blk.slast;      // the block's last tile
    for (genvar g = 0; g < 4; g++) begin : g_vconv
        v4_bfp8 vconv (.clk, .bf16(pv_vraw[g]), .max_e(vmax_p[PVR]), .mant(pv_mv[g]));
    end
    wire h_wr = pq_v[PD] && pq_last[PD];       // the accumulator holds a finished chunk

    always_ff @(posedge clk) begin
        if (srst) begin
            pv_run <= 0; pv_c <= 0; pv_j <= 0; pv_credit <= 2; pq_v <= 0; hvalid <= 0; h_wslot <= 0; pv_par <= 0;
        end else begin
            if (pvd_pop) begin pv_run <= 1; pv_c <= 0; pv_j <= 0; pv_par <= !pv_par; end
            else if (pv_can_issue) begin
                if (last_key(pvd.blk, pv_j)) begin
                    pv_j <= 0;
                    if (pv_c == pv_last_c) pv_run <= 0;
                    pv_c <= pv_c + 1'b1;
                end else pv_j <= pv_j + 1'b1;
            end
            pv_credit <= pv_credit - (pv_can_issue && pv_chunk_start) + h_release;
            pq_v <= {pq_v[PD-1:1], pv_can_issue};
            if (h_wr) begin hvalid[h_wslot] <= 1; h_wslot <= !h_wslot; end
            if (h_release) hvalid[h_rslot] <= 0;
        end
    end
    always_ff @(posedge clk) begin
        if (pvd_pop) begin
            pvd <= pvd_out; pvdh[!pv_par] <= pvd_out;
            pv_split <= split(pvd_out.blk); pv_last_c <= last_step(pvd_out.blk);
        end
        pq_first <= {pq_first[PD-1:1], pv_chunk_start};
        pq_last <= {pq_last[PD-1:1], last_key(pvd.blk, pv_j)};
        pq_par <= {pq_par[PD-1:1], pv_par};
        pq_split <= {pq_split[PD-1:1], pv_split};
        pq_c[1] <= pv_c; vmax_p[1] <= vmax[v_rslot];
        for (int s = 2; s <= PD; s++) begin pq_c[s] <= pq_c[s-1]; vmax_p[s] <= vmax_p[s-1]; end
        // PVR: each group's quarter line; p of all lanes from P2 on (a split
        // tile gives lane (g, h) the p of head h)
        for (int g = 0; g < 4; g++)
            pv_vraw[g] <= pv_vbank[pq_split[RAM_LAT] ? pq_c[RAM_LAT][1:0] + 2'(g) : pq_c[RAM_LAT][1:0]];
        for (int l = 0; l < R; l++) begin
            int src;
            src = pq_split[1] ? l % G : l;
            pp[2][l] <= pv_pword[src / 2][PW * (src % 2) +: PW];
        end
        for (int s = 3; s <= PVM; s++) pp[s] <= pp[s-1];
        // PVM: multiplier inputs; PVP: products; PD: accumulator
        pr_mv <= pv_mv;
        pm_mv <= pr_mv;
        for (int l = 0; l < R; l++)
            for (int w = 0; w < W; w++) pv_prod[l][w] <= $signed({1'b0, pp[PVM][l]}) * $signed(pm_mv[l/G][16*w +: 16]);
        if (pq_v[PVP])
            for (int l = 0; l < R; l++)
                for (int w = 0; w < W; w++)
                    acc[l][w] <= (pq_first[PVP] ? OBW'(0) : acc[l][w]) + OBW'(pv_prod[l][w]);
        if (h_wr) h_tile_start[h_wslot] <= pvdh[pq_par[PD]].blk.first && pvdh[pq_par[PD]].blk.sub == 0 && pq_c[PD] == 0;
        if (h_wr)
            hmeta[h_wslot] <= '{blk: pvdh[pq_par[PD]].blk, split: pq_split[PD], act: pvdh[pq_par[PD]].act,
                                alpha: pvdh[pq_par[PD]].alpha, vmax: vmax_p[PD], c: pq_c[PD]};
    end

    // ==================================================================
    // merge: lane by lane, 8 values per cycle. M0 reads the lane's state and
    // its O (RAM_LAT); M1 new exponent; M2 exponent differences; M3 clipped
    // shift; M4 O_old * alpha (mul_round_shift); O_blk's round_shift ends
    // with it at MA; write at MS. An O slot holds a whole super-tile (row
    // {tile, lane}); it is handed to final when the super-tile's last block
    // of its last tile is merged.
    // ==================================================================
    localparam int MA = 4 + LAT_MRS;            // both terms ready
    localparam int MS = MA + 1;                 // write
    logic o_produce, o_consume, o_can_produce, o_can_consume;
    logic [0:0] o_wslot, o_rslot;
    v4_slots #(.N(2)) o_ring (.clk, .rst_n(!srst), .produce(o_produce), .consume(o_consume),
        .wr(o_wslot), .rd(o_rslot), .can_produce(o_can_produce), .can_consume(o_can_consume));
    exp_t eo [2][SMAX*R];
    exp_t enew [R];
    logic [SMAX*R-1:0] ostarted [2];
    logic [3:0] mg_lane;
    hold_meta_t mg;
    logic [MS:1] mt_v, mt_act;
    logic [5:0] mt_l [MS:1];                   // {tile, row}
    logic [3:0] mt_cc [MS:1];
    logic m1_st, m1_c0, m1_c15, m2_st, m3_st, m4_st;
    exp_t m1_eo, m1_enew, m1_ev, m2_en, m2_eo, m2_ev;
    logic [PW-1:0] m1_alpha, m2_alpha, m3_alpha, m4_alpha;
    logic signed [10:0] m3_dold;                // FP + e_new - e_old
    logic [7:0] m4_sold;                        // shift for the old O (>= FP)
    logic [8:0] msb [MA-LAT_RS:3];              // shift for O_blk
    logic signed [OBW-1:0] mob [MA-LAT_RS:1][W];
    logic signed [OW-1:0] m3_o [W], m4_o [W];
    logic signed [OW-1:0] o_scaled [W];
    logic signed [OBW-1:0] ob_sh [W];
    logic [W*OW-1:0] oram_rdata [2];
    logic [9:0] mg_raddr;
    logic [W*OW-1:0] mg_wdata;
    logic [7:0] mg_tail;
    logic mg_tile_done;
    logic mg_owns;                             // a tile is being merged into slot o_wslot
    logic [1:0] h_tile_start;                  // hold slot s opens a super-tile (first block of tile 0, chunk 0)
    logic mg_tail_idle;
    wire mg_tile_start = hvalid[h_rslot] && h_tile_start[h_rslot];
    wire mg_can_start = !mg_run && hvalid[h_rslot] && (!mg_tile_start || o_can_produce) && mg_tail_idle;
    // Predict the next cycle's hold operation at the existing control boundary.
    // A simultaneous current write advances the alternating slot, including
    // back-to-back single-key chunks. Local registers distribute each enable
    // to one OBW-bit word instead of a single LUT driving thousands of FF CEs.
    wire hold_load_next = pq_v[PD-1] && pq_last[PD-1];
    wire hold_slot_next = h_wslot ^ h_wr;
    for (genvar hs = 0; hs < 2; hs++) begin : g_hold_slot
        wire load_next = hold_load_next && hold_slot_next == 1'(hs);
        wire shift_next = (mg_can_start && h_rslot == 1'(hs)) ||
                          (mg_run && mg_lane != R-1 && mg_hslot == 1'(hs));
        for (genvar hl = 0; hl < R; hl++) begin : g_lane
            for (genvar hw = 0; hw < W; hw++) begin : g_word
                (* dont_touch = "true" *) logic load_acc, write_enable;
                always_ff @(posedge clk) begin
                    if (srst) begin load_acc <= 0; write_enable <= 0; end
                    else begin
                        load_acc <= load_next;
                        write_enable <= load_next || (hl < R-1 && shift_next);
                    end
                end
                if (hl < R-1) begin : g_shift
                    always_ff @(posedge clk)
                        if (write_enable)
                            hold[hs][hl][hw] <= load_acc ? acc[hl][hw] : hold[hs][hl+1][hw];
                end else begin : g_last
                    always_ff @(posedge clk)
                        if (write_enable) hold[hs][hl][hw] <= acc[hl][hw];
                end
`ifndef SYNTHESIS
                // This is a control-distribution change, with no extra data
                // latency. Check equivalence to the original enables per cycle.
                always_ff @(posedge clk) if (!srst) begin
                    assert (load_acc == (h_wr && h_wslot == 1'(hs)));
                    assert (write_enable == ((h_wr && h_wslot == 1'(hs)) ||
                            (hl < R-1 && mg_run && mg_hslot == 1'(hs))));
                end
`endif
            end
        end
    end
    for (genvar w = 0; w < W; w++) begin : g_merge
        v4_mul_round_shift mrs (.clk, .o(m4_st ? m4_o[w] : OW'(0)), .a(m4_alpha), .s(m4_sold), .y(o_scaled[w]));
        v4_round_shift #(.XW(OBW)) rs (.clk, .x(mob[MA-LAT_RS][w]), .s(msb[MA-LAT_RS]), .y(ob_sh[w]));
    end
    // lane -> O row and chunk: lane (g, h) of a split tile at step c holds
    // head h, chunk 4g + (c + g) % 4; a row's first merge in the block sets
    // its new exponent, its last one stores it
    wire [1:0] mg_g = mg_lane[3:2];
    wire [3:0] mg_row = mg.split ? {2'b0, mg_lane[1:0]} : mg_lane;
    wire [3:0] mg_chunk = mg.split ? {mg_g, mg.c[1:0] + mg_g} : mg.c;
    wire mg_first = mg.c == 0 && (!mg.split || mg_g == 0);
    wire mg_last = mg.split ? mg.c == 3 && mg_g == 3 : mg.c == 15;
    wire mg_last_step = mg.c == (mg.split ? 4'd3 : 4'd15);
    wire [5:0] mg_srow = {mg.blk.sub, mg_row};
    wire mg_sup_end = mg_last_step && mg.blk.last && mg.blk.slast;   // the super-tile's last merge
    assign h_release = mg_run && mg_lane == R - 1;
    assign mg_raddr = {mg_srow, mg_chunk};
    assign o_produce = mg_tile_done;

    always_ff @(posedge clk) begin
        if (srst) begin
            mg_run <= 0; mg_lane <= 0; mt_v <= 0; h_rslot <= 0; mg_tail <= 0; mg_tile_done <= 0; mg_owns <= 0;
            mg_tail_idle <= 1;
            ostarted[0] <= 0; ostarted[1] <= 0;
        end else begin
            mg_tile_done <= 0;
            if (mg_can_start) begin
                mg_run <= 1; mg_lane <= 0; mg_hslot <= h_rslot;
                if (mg_tile_start) begin ostarted[o_wslot] <= 0; mg_owns <= 1; end
            end else if (mg_run) begin
                mg_lane <= mg_lane + 1'b1;
                if (mg_lane == R - 1) begin
                    mg_run <= 0; h_rslot <= !h_rslot;
                    if (mg_sup_end) mg_tail <= 8'(MS + 5);   // drain, then hand over
                end
            end
            if (mg_tail != 0) begin
                mg_tail <= mg_tail - 1'b1;
                if (mg_tail == 1) begin mg_tile_done <= 1; mg_owns <= 0; end
            end
            mt_v <= {mt_v[MS-1:1], mg_run};
            mg_tail_idle <= mg_tail == 0 && !(mg_run && mg_lane == R - 1 && mg_sup_end);
            if (mg_run && mg_last && mg.act[mg_row]) ostarted[o_wslot][mg_srow] <= 1;
        end
    end
    always_ff @(posedge clk) begin
        if (mg_can_start) mg <= hmeta[h_rslot];
        mt_l[1] <= mg_srow; mt_cc[1] <= mg_chunk; mt_act[1] <= mg.act[mg_row];
        for (int s = 2; s <= MS; s++) begin mt_l[s] <= mt_l[s-1]; mt_cc[s] <= mt_cc[s-1]; mt_act[s] <= mt_act[s-1]; end
        // M0 -> M1: the lane's state, alpha and O_blk
        m1_st <= ostarted[o_wslot][mg_srow];
        m1_eo <= eo[o_wslot][mg_srow];
        m1_enew <= enew[mg_row];
        m1_ev <= unbias(mg.vmax);
        m1_c0 <= mg_first;
        m1_c15 <= mg_last;
        m1_alpha <= mg.alpha[PW*mg_row +: PW];
        for (int w = 0; w < W; w++) mob[1][w] <= hold[mg_hslot][0][w];
        for (int s = 2; s <= MA - LAT_RS; s++) mob[s] <= mob[s-1];
        // M1: new exponent of the row (taken at its first merge of the block, stored at its last)
        begin
            exp_t en;
            en = m1_c0 ? (m1_st && m1_eo > m1_ev ? m1_eo : m1_ev) : m1_enew;
            if (mt_v[1] && m1_c0) enew[mt_l[1][3:0]] <= en;
            if (mt_v[1] && m1_c15 && mt_act[1]) eo[o_wslot][mt_l[1]] <= en;
            m2_en <= en;
        end
        m2_st <= m1_st; m2_eo <= m1_eo; m2_ev <= m1_ev; m2_alpha <= m1_alpha;
        // M2: shift amounts; O_old arrives from the RAM
        m3_dold <= 11'(FP) + 11'(m2_en) - 11'(m2_eo);
        msb[3] <= 9'(11'(m2_en) - 11'(m2_ev));
        for (int s = 4; s <= MA - LAT_RS; s++) msb[s] <= msb[s-1];
        m3_st <= m2_st; m3_alpha <= m2_alpha;
        for (int w = 0; w < W; w++) m3_o[w] <= $signed(oram_rdata[o_wslot][OW*w +: OW]);
        // M3: clip the shift
        m4_sold <= m3_st ? (m3_dold > 255 ? 8'd255 : 8'(m3_dold)) : 8'd255;
        m4_st <= m3_st; m4_alpha <= m3_alpha; m4_o <= m3_o;
        // MA: O = O_old * alpha + O_blk
        for (int w = 0; w < W; w++) mg_wdata[OW*w +: OW] <= o_scaled[w] + OW'(ob_sh[w]);
    end

    // O state: one RAM per O slot (a super-tile, address {tile, row, chunk}).
    // While merge builds a super-tile in o_wslot it owns that RAM's read port;
    // final reads the slot it is emitting (o_rslot), which is never the one
    // being merged.
    logic [9:0] fn_raddr;
    for (genvar s = 0; s < 2; s++) begin : g_oram
        v4_sdp_ram #(.WIDTH(W*OW), .DEPTH(SMAX * 256), .STYLE("block"), .LAT(RAM_LAT)) oram (.clk,
            .we(mt_v[MS] && mt_act[MS] && o_wslot == s), .waddr({mt_l[MS], mt_cc[MS]}), .wdata(mg_wdata),
            .raddr(mg_owns && o_wslot == s ? mg_raddr : fn_raddr), .rdata(oram_rdata[s]));
    end


    // ==================================================================
    // final: per tile, per group of 4 lanes (one query position, 4 heads).
    //   Tiles come in order from tl_fifo (l and the tile's last blk); a tile
    //   is emitted once its super-tile is merged (o_can_consume), and the O
    //   slot is released after the super-tile's last tile.
    //   divider side: l of the group -> leading one, shift -> 4 dividers -> one
    //     of 2 reciprocal slots, so the next group divides while this one is emitted.
    //     It starts as soon as softmax has the tile's l (before merge is done);
    //     only the output exponent, from the merged row exponent, waits for merge;
    //   output side: 16 chunks per lane, each in NPH = W / NCV cycles through
    //     the NCV to_bf16 units; a slot is released when its last chunk has
    //     taken its reciprocal.
    // F0 read, F(RAM_LAT) O data, FO registered O into to_bf16, BF16 at FT.
    // ==================================================================
    typedef enum logic [2:0] {FD_IDLE, FD_SEL, FD_LZ, FD_SH, FD_DIV, FD_WAIT, FD_PUT, FD_END} fd_state_t;
    typedef enum logic [2:0] {FN_IDLE, FN_WAIT, FN_OUT, FN_DRAIN, FN_DONE} fn_state_t;
    localparam int FO = RAM_LAT + 1;
    localparam int FT = FO + LAT_TOBF;
    localparam int NPH = W / NCV;
    fd_state_t fd_state;
    fn_state_t fn_state;
    tld_t fnl;
    logic [1:0] fd_group, fn_group, fn_last_group;
    logic [1:0] fn_li;                         // lane within the group
    logic [3:0] fn_c;
    logic [$clog2(NPH > 1 ? NPH : 2)-1:0] fn_h;                 // phase within the chunk
    logic [3:0] fn_div_start;
    logic [3:0] fn_div_busy, fn_div_done;
    logic [LW-1:0] fn_lv [4];
    logic [5:0] fn_lz [4];
    logic [5:0] fn_sh [4];
    logic fn_left [4];
    logic [31:0] fn_lm [4];
    logic [31:0] fn_recip [4];
    logic [31:0] rs_recip [2][4];              // reciprocal slots
    logic signed [11:0] rs_e [2][4];
    logic [1:0] rs_valid;
    logic rs_w, rs_r;
    logic [FT:1] fv, fend;
    logic fs [FT:1];
    logic [3:0] fl [FT:1];
    logic [3:0] fc [FT:1];
    logic [$bits(fn_h)-1:0] fh [FT:1];
    logic signed [OW-1:0] fn_o [NCV];
    logic [16*NCV-1:0] fn_bf;
    logic [511:0] fn_line;
    logic [R-1:0] fn_valid_lanes;
    for (genvar i = 0; i < 4; i++) begin : g_recip
        v4_recip recip (.clk, .rst_n(!srst), .start(fn_div_start[i]), .lm(fn_lm[i]), .busy(fn_div_busy[i]),
            .done(fn_div_done[i]), .q(fn_recip[i]));
    end
    for (genvar i = 0; i < NCV; i++) begin : g_tobf
        v4_to_bf16 cv (.clk, .o(fn_o[i]), .recip(rs_recip[fs[FO]][fl[FO][1:0]]), .e(rs_e[fs[FO]][fl[FO][1:0]]),
            .bf16(fn_bf[16*i +: 16]));
    end
    wire [3:0] fn_lane_now = {fn_group, fn_li};
    wire fd_tile_start = fd_state == FD_IDLE && !tl_empty;
    wire fn_tile_start = fn_state == FN_IDLE && fd_state != FD_IDLE && o_can_consume;
    wire fd_put = fd_state == FD_PUT && !rs_valid[rs_w] && o_can_consume;
    wire fn_issue = fn_state == FN_OUT && (!STREAM_PORTS || o_credit);
    wire fn_group_end = fn_issue && fn_li == 3 && fn_c == 15 && fn_h == NPH - 1;
    assign final_activity = {fn_issue, fn_state == FN_OUT && !o_credit};
    assign fn_raddr = {fnl.blk.sub, fn_lane_now, fn_c};
    assign tl_pop = fn_state == FN_DONE;
    assign o_consume = fn_state == FN_DONE && fnl.blk.slast;

    always_ff @(posedge clk) begin
        if (srst) begin
            fd_state <= FD_IDLE; fn_state <= FN_IDLE; fv <= 0; fn_div_start <= 0; o_we <= 0; done <= 0;
            rs_valid <= 0; rs_w <= 0; rs_r <= 0;
        end else begin
            fn_div_start <= 0;
            done <= 0;
            // divider side
            case (fd_state)
                FD_IDLE: if (fd_tile_start) begin fd_group <= 0; fd_state <= FD_SEL; end
                FD_SEL: fd_state <= FD_LZ;                             // the group's l and exponents
                FD_LZ: fd_state <= FD_SH;                              // leading ones of l
                FD_SH: fd_state <= FD_DIV;                             // shift amounts
                FD_DIV: begin fn_div_start <= 4'hF; fd_state <= FD_WAIT; end
                FD_WAIT: if (fn_div_done[0]) fd_state <= FD_PUT;
                FD_PUT:                                                // needs the merged tile (eo)
                    if (fd_put) begin
                        rs_w <= !rs_w;
                        if (fd_group == fn_last_group) fd_state <= FD_END;
                        else begin fd_group <= fd_group + 1'b1; fd_state <= FD_SEL; end
                    end
                FD_END: if (fn_state == FN_DONE) fd_state <= FD_IDLE;
                default: fd_state <= FD_IDLE;
            endcase
            // output side
            case (fn_state)
                FN_IDLE: if (fn_tile_start) begin fn_group <= 0; fn_state <= FN_WAIT; end
                FN_WAIT: if (rs_valid[rs_r]) begin fn_li <= 0; fn_c <= 0; fn_h <= 0; fn_state <= FN_OUT; end
                FN_OUT: if (fn_issue) begin                            // one chunk of one lane per NPH cycles
                    fn_h <= fn_h == NPH - 1 ? '0 : fn_h + 1'b1;
                    if (fn_h == NPH - 1) begin
                        if (fn_c == 15) begin
                            fn_c <= 0;
                            fn_li <= fn_li + 1'b1;
                        end else fn_c <= fn_c + 1'b1;
                    end
                    if (fn_group_end) begin
                        rs_r <= !rs_r;
                        if (fn_group == fn_last_group) fn_state <= FN_DRAIN;
                        else begin fn_group <= fn_group + 1'b1; fn_state <= FN_WAIT; end
                    end
                end
                FN_DRAIN: if (fv == 0 && !o_we) fn_state <= FN_DONE;  // the tile's lines are written
                FN_DONE: begin
                    fn_state <= FN_IDLE;
                    if (fnl.blk.last_tile) done <= 1;
                end
                default: fn_state <= FN_IDLE;
            endcase
            // reciprocal slots: filled by the divider side, released when the
            // group's last chunk has taken its reciprocal (stage FO)
            if (fd_put) rs_valid[rs_w] <= 1;
            if (fv[FO] && fend[FO]) rs_valid[fs[FO]] <= 0;
            fv <= {fv[FT-1:1], fn_issue && fn_valid_lanes[fn_lane_now]};
            o_we <= fv[FT] && fc[FT][1:0] == 3 && fh[FT] == NPH - 1;
        end
    end
    always_ff @(posedge clk) begin
        if (fd_tile_start) begin
            fnl <= tl_out;
            fn_last_group <= 2'(tl_out.blk.npos - 1'b1);           // group g = query position g
        end
        if (fn_tile_start)
            for (int l = 0; l < R; l++) fn_valid_lanes[l] <= lane_valid(fnl.blk, l);
        if (fd_state == FD_SEL)
            for (int i = 0; i < 4; i++) fn_lv[i] <= fnl.l[LW*(4*int'(fd_group) + i) +: LW];
        if (fd_state == FD_LZ)
            for (int i = 0; i < 4; i++) begin
                fn_lz[i] <= 0;
                for (int b = 0; b < LW; b++) if (fn_lv[i][b]) fn_lz[i] <= 6'(b);
            end
        if (fd_state == FD_SH)
            for (int i = 0; i < 4; i++) begin
                fn_left[i] <= fn_lz[i] <= 31;
                fn_sh[i] <= fn_lz[i] <= 31 ? 6'd31 - fn_lz[i] : fn_lz[i] - 6'd31;
            end
        if (fd_state == FD_DIV)
            for (int i = 0; i < 4; i++)
                fn_lm[i] <= fn_left[i] ? 32'(fn_lv[i] << fn_sh[i]) : 32'(fn_lv[i] >> fn_sh[i]);
        if (fd_put)
            for (int i = 0; i < 4; i++) begin
                rs_recip[rs_w][i] <= fn_recip[i];
                rs_e[rs_w][i] <= 12'(eo[o_rslot][R*int'(fnl.blk.sub) + 4*int'(fd_group) + i]) - 12'sd45 - 12'(fn_lz[i]);
            end
        fl[1] <= fn_lane_now;
        fc[1] <= fn_c;
        fh[1] <= fn_h;
        fs[1] <= rs_r;
        fend[1] <= fn_group_end;
        for (int s = 2; s <= FT; s++) begin
            fl[s] <= fl[s-1]; fc[s] <= fc[s-1]; fh[s] <= fh[s-1]; fs[s] <= fs[s-1]; fend[s] <= fend[s-1];
        end
        for (int i = 0; i < NCV; i++)
            fn_o[i] <= $signed(oram_rdata[o_rslot][OW*(NCV*int'(fh[RAM_LAT]) + i) +: OW]);
        if (fv[FT]) begin
            fn_line[128*fc[FT][1:0] + 16*NCV*int'(fh[FT]) +: 16*NCV] <= fn_bf;
            if (fc[FT][1:0] == 3 && fh[FT] == NPH - 1)
                o_waddr <= 20'({ADDR_W'(fnl.blk.qrow0 + ADDR_W'({fnl.blk.tile, fl[FT]})), fc[FT][3:2]});
        end
    end
    assign o_wdata = fn_line;

    // ==================================================================
    // status and counters
    // ==================================================================
    logic [31:0] cnt [8];
    logic [7:0] ev;                            // events of the previous cycle
    always_ff @(posedge clk)
        ev <= {pv_run && !pv_can_issue, !qk_run && kf_valid, fn_state != FN_IDLE, mg_run,
               sm_state != SM_IDLE, pv_can_issue, qk_run, 1'b1};
    always_ff @(posedge clk) begin
        if (!rst_n) busy <= 0;
        else if (start_q) busy <= 1;
        else if (done) busy <= 0;
        if (srst) for (int i = 0; i < 8; i++) cnt[i] <= 0;
        else if (busy)
            // cycles; QK busy; PV busy; softmax busy; merge busy; final busy;
            // QK idle while keys remain; PV waiting for merge
            for (int i = 0; i < 8; i++) cnt[i] <= cnt[i] + ev[i];
    end
    for (genvar i = 0; i < 8; i++) begin : g_perf
        assign perf[32*i +: 32] = cnt[i];
    end
endmodule
