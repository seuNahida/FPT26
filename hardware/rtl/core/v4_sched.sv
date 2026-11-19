`timescale 1ns/1ps
// Walks the (group, super-tile, block, tile) schedule of a job in order.
// Several stages each run their own copy, so they agree on the sequence
// without talking. A group is a run of super-tiles with its own Q / O row
// base and K / V token base (attn_pkg::job_t); the stages see it only through
// those bases.
//   super-tile: positions P0 .. P0 + S*T - 1 (S = job.sub), tiles s = 0..ns-1
//   tile s: positions p = P0 + s*T .. + npos - 1, keys 0 .. kend_s - 1 with
//     kend_s = q_pos + min(P0 + (s+1)*T, q_len)
//   for each block k0 = 0, BC, .. < kend of the last tile:
//     for each tile s that sees the block (k0 < kend_s; these are s_min..ns-1):
//       one blk: keys k0 .. k0+nk-1; V tokens k0 .. k0+nv-1 (nv runs to the
//       end of the block or of the job: the V block exponent of golden_fixed
//       is taken over the whole block, whatever the tiles need)
// With S = 1 this is the plain (tile, block) order. `blk` is computed from the
// position (P0, k0, s) in four registered steps, so `valid` drops for SETTLE
// cycles after `start` and after each `next`.
module v4_sched (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  attn_pkg::job_t job,
    input  logic next,                  // consume the current block
    output logic valid,                 // `blk` is a block still to process
    output attn_pkg::blk_t blk
);
    import attn_pkg::*;
    localparam int SETTLE = 4;
    localparam int PW1 = POS_W + 2;            // signed position differences
    job_t j;
    logic run;
    logic [2:0] settle;
    logic [2:0] sn;                            // tiles per super-tile (1..SMAX)
    logic [POS_W-1:0] p0, k0;
    logic [1:0] s;
    logic spar;
    logic [3:0] grp, grp_last;
    logic [ADDR_W-1:0] qbase, kvbase;          // the group's first Q row and first K / V token
    // derived from the position, valid with `blk`
    logic sblk_last;                           // the block is the super-tile's last
    logic sup_last;                            // the super-tile is the group's last
    logic [1:0] s_next;                        // first tile that sees the next block
    // step a
    logic [POS_W-1:0] a_left, a_bsup, a_k0, a_p0;
    logic [POS_W:0] a_vend, a_k0n;
    logic [4:0] a_soff;
    logic [1:0] a_s;
    logic [ADDR_W-1:0] a_qrow, a_kabs;
    logic a_lastg, a_spar;
    // step b
    logic [2:0] b_ns;
    logic [4:0] b_span, b_soff;
    logic [POS_W-1:0] b_sp, b_base, b_k0, b_p0;
    logic signed [PW1-1:0] b_d0, b_dn, b_dm;
    logic [POS_W:0] b_vend;
    logic [1:0] b_s;
    logic [ADDR_W-1:0] b_qrow, b_kabs;
    logic b_lastg, b_spar, b_lastsup;
    // step c
    logic [2:0] c_npos;
    logic signed [PW1-1:0] c_dlast, c_ds;
    logic [1:0] c_snext, c_smin;
    logic c_slast, c_lastsup, c_lastg, c_spar;
    logic [POS_W-1:0] c_base, c_k0, c_p0;
    logic [POS_W:0] c_vend;
    logic [1:0] c_s;
    logic [ADDR_W-1:0] c_qrow, c_kabs;
    assign valid = run && settle == 0;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            run <= 0; settle <= 0; p0 <= 0; k0 <= 0; s <= 0; spar <= 0; j <= '0; sn <= 1;
            grp <= 0; grp_last <= 0; qbase <= 0; kvbase <= 0;
        end else if (start) begin
            run <= job.q_len != 0; settle <= 3'(SETTLE); p0 <= 0; k0 <= 0; s <= 0; spar <= 0; j <= job;
            sn <= job.sub == 0 || job.sub > 3'(SMAX) ? 3'(SMAX) : job.sub;
            grp <= 0; grp_last <= job.groups > 1 ? job.groups - 1'b1 : 4'd0; qbase <= 0; kvbase <= 0;
        end else if (next && valid) begin
            settle <= 3'(SETTLE);
            if (!blk.slast) s <= s + 1'b1;                       // next tile, same block
            else if (!sblk_last) begin k0 <= k0 + BC; s <= s_next; end
            else begin                                           // super-tile done
                k0 <= 0; s <= 0; spar <= !spar;
                if (!sup_last) p0 <= p0 + POS_W'({sn, 2'b00});
                else if (blk.last_tile) run <= 0;
                else begin                                       // next group
                    p0 <= 0;
                    grp <= grp + 1'b1;
                    qbase <= qbase + ADDR_W'({j.q_len, 2'b00});
                    kvbase <= kvbase + ADDR_W'(j.kv_stride == 0 ? j.kv_len : j.kv_stride);
                end
            end
        end else if (settle != 0) settle <= settle - 1'b1;
    end
    always_ff @(posedge clk) begin
        // a
        a_left <= j.q_len - p0;
        a_bsup <= j.q_pos + p0;
        a_soff <= {1'b0, s, 2'b00};
        a_vend <= (POS_W+1)'(j.kv_len) - k0;
        a_k0 <= k0;
        a_k0n <= (POS_W+1)'(k0) + BC;
        a_p0 <= p0;
        a_s <= s;
        a_qrow <= qbase;
        a_kabs <= kvbase + ADDR_W'(k0);
        a_lastg <= grp == grp_last;
        a_spar <= spar;
        // b
        b_ns <= POS_W'(a_left + 3) >> 2 >= POS_W'(sn) ? sn : 3'((a_left + 3) >> 2);
        b_span <= a_left >= POS_W'({sn, 2'b00}) ? {sn, 2'b00} : 5'(a_left);
        b_lastsup <= a_left <= POS_W'({sn, 2'b00});
        b_sp <= a_left - POS_W'(a_soff);
        b_base <= a_bsup + POS_W'(a_soff);
        b_d0 <= PW1'(a_bsup) - PW1'(a_k0);
        b_dn <= PW1'(a_k0n) - PW1'(a_bsup);
        b_dm <= PW1'(a_k0) - PW1'(a_bsup);
        b_soff <= a_soff; b_vend <= a_vend; b_k0 <= a_k0; b_p0 <= a_p0; b_s <= a_s;
        b_qrow <= a_qrow; b_kabs <= a_kabs; b_lastg <= a_lastg; b_spar <= a_spar;
        // c
        c_npos <= b_sp >= T ? 3'(T) : 3'(b_sp);
        c_dlast <= b_d0 + PW1'(b_span);
        c_ds <= b_d0 + PW1'(b_soff);
        c_snext <= b_dn < 0 ? 2'd0 : b_dn >= PW1'(4 * SMAX) ? 2'(SMAX - 1) : 2'(b_dn >>> 2);
        c_smin <= b_dm < 0 ? 2'd0 : 2'(b_dm >>> 2);
        c_slast <= 3'(b_s) + 1'b1 == b_ns;
        c_lastsup <= b_lastsup;
        c_base <= b_base; c_vend <= b_vend; c_k0 <= b_k0; c_p0 <= b_p0; c_s <= b_s;
        c_qrow <= b_qrow; c_kabs <= b_kabs; c_lastg <= b_lastg; c_spar <= b_spar;
        // blk
        begin
            logic signed [PW1-1:0] kend;           // keys left for the tile, >= 1
            kend = c_ds + PW1'(c_npos);
            blk.tile <= (c_p0 >> 2) + POS_W'(c_s);
            blk.pos_base <= c_base;
            blk.npos <= c_npos;
            blk.k0 <= c_k0;
            blk.nk <= kend >= BC ? 6'(BC) : 6'(kend);
            blk.nkf <= c_dlast >= BC ? 6'(BC) : 6'(c_dlast);
            blk.nv <= c_vend >= BC ? 6'(BC) : 6'(c_vend);
            blk.first <= c_k0 == 0;
            blk.last <= kend <= BC;
            blk.qrow0 <= c_qrow;
            blk.kabs0 <= c_kabs;
            blk.sub <= c_s;
            blk.slast <= c_slast;
            blk.kvfirst <= c_smin == c_s;
            blk.spar <= c_spar;
            blk.last_tile <= c_lastsup && c_lastg && c_slast;
            sblk_last <= c_dlast <= BC;
            sup_last <= c_lastsup;
            s_next <= c_snext;
        end
    end
endmodule
