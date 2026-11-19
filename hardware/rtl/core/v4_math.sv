`timescale 1ns/1ps
// Arithmetic units of the v4 core. Each mirrors one function of
// attn/model/golden_fixed.py exactly (rounding, saturation, edge cases).
// All units are fully pipelined: one operation per cycle, fixed latency
// (LAT_* in attn_pkg). Stages are cut for 200 MHz on Artix-7 -2: at most one
// carry chain or about three LUT levels per stage, and every DSP has its
// product (M) and sum (P) registers.

// x * y for a signed x of any width and a signed y of at most 25 bits (the DSP
// A port). x is cut into 17-bit slices, lowest first; slice k enters k cycles
// late, multiplies in its own DSP (M register) and adds the previous DSP's sum
// shifted down by 17 (P register, PCIN cascade). x and y are registered on
// entry in fabric (dont_touch), so no logic in front of the unit can be pulled
// into the DSP input registers. Latency mul_slices(XW) + 2.
(* use_dsp = "yes" *)
module v4_mul_cascade #(parameter int XW = 57, parameter int YW = 22) (
    input  logic clk,
    input  logic signed [XW-1:0] x,
    input  logic signed [YW-1:0] y,
    output logic signed [XW+YW-1:0] p
);
    localparam int NC = attn_pkg::mul_slices(XW);
    localparam int TOPW = XW + YW - 17 * (NC - 1);   // result bits above the low slices
    (* dont_touch = "true" *) logic signed [XW-1:0] xr;
    (* dont_touch = "true" *) logic signed [YW-1:0] yr;
    always_ff @(posedge clk) begin xr <= x; yr <= y; end
    logic signed [47:0] s [NC];
    for (genvar k = 0; k < NC; k++) begin : g_slice
        logic signed [17:0] xin, xk;           // slice k now, and k cycles late
        logic signed [YW-1:0] yk;
        logic signed [YW+17:0] m;
        if (k < NC - 1) begin : g_low
            assign xin = {1'b0, xr[17*k +: 17]};
        end else begin : g_top
            assign xin = 18'($signed(xr[XW-1:17*k]));
        end
        if (k == 0) begin : g_now
            assign xk = xin;
            assign yk = yr;
        end else begin : g_late
            logic signed [17:0] xd [k];
            logic signed [YW-1:0] yd [k];
            always_ff @(posedge clk) begin
                xd[0] <= xin;
                yd[0] <= yr;
                for (int d = 1; d < k; d++) begin xd[d] <= xd[d-1]; yd[d] <= yd[d-1]; end
            end
            assign xk = xd[k-1];
            assign yk = yd[k-1];
        end
        always_ff @(posedge clk) m <= yk * xk;
        if (k == 0) begin : g_first
            always_ff @(posedge clk) s[0] <= 48'(m);
        end else begin : g_next
            always_ff @(posedge clk) s[k] <= 48'(m) + (s[k-1] >>> 17);
        end
        // the low 17 bits of s[k] are final; delay them to line up with the top
        if (k < NC - 1) begin : g_lo
            logic [16:0] lo [NC-1-k];
            always_ff @(posedge clk) begin
                lo[0] <= s[k][16:0];
                for (int d = 1; d < NC - 1 - k; d++) lo[d] <= lo[d-1];
            end
            assign p[17*k +: 17] = lo[NC-2-k];
        end
    end
    assign p[XW+YW-1 : 17*(NC-1)] = s[NC-1][TOPW-1:0];
endmodule

// Largest biased exponent among the non-zero elements of 32 BF16 values
// (0 when all are zero or subnormal); the row/block maximum is the max of
// these over its lines. Input register and a 2:1 comparator tree, one level
// per stage: latency LAT_MAX = 6.
module v4_max_exp32 (
    input  logic clk,
    input  logic [32*16-1:0] bf16,
    output logic [7:0] max_e
);
    logic [7:0] lv [6][32];                    // lv[k]: 32 >> k values
    always_ff @(posedge clk) begin
        for (int i = 0; i < 32; i++) lv[0][i] <= bf16[16*i + 7 +: 8];
        for (int k = 1; k < 6; k++)
            for (int i = 0; i < (32 >> k); i++)
                lv[k][i] <= lv[k-1][2*i] > lv[k-1][2*i+1] ? lv[k-1][2*i] : lv[k-1][2*i+1];
    end
    assign max_e = lv[5][0];
endmodule

// golden_fixed.to_bfp for 8 elements given the group's maximum biased
// exponent (0 = all zero). value = m * 2^(E - 14), E = max_e - 127.
// An element at exponent e has significand sig (8 bits) and shift
// s = max_e - e - 7: left by -s when s <= 0, else rounded half up,
// (sig + 2^(s-1)) >> s = ((sig >> (s-1)) + 1) >> 1, and 0 for s >= 9.
// Latency LAT_BFP = 4: exponent difference; shift; rounding; sign.
module v4_bfp8 (
    input  logic clk,
    input  logic [8*16-1:0] bf16,
    input  logic [7:0] max_e,
    output logic [8*16-1:0] mant
);
    logic [7:0] sig1 [8];
    logic [8:0] d1 [8];                        // max_e - e (>= 0 for the group maximum)
    logic neg1 [8], neg2 [8], neg3 [8];
    logic [15:0] v2 [8], mag3 [8];
    logic right2 [8];
    always_ff @(posedge clk)
        for (int i = 0; i < 8; i++) begin
            logic [7:0] e;
            e = bf16[16*i+7 +: 8];
            // 1
            sig1[i] <= e == 0 ? 8'd0 : {1'b1, bf16[16*i +: 7]};
            d1[i] <= {1'b0, max_e} - {1'b0, e};
            neg1[i] <= bf16[16*i+15];
            // 2: s = d - 7; left by 7 - d, or right by s - 1 = d - 8; zero for s >= 9
            neg2[i] <= neg1[i];
            right2[i] <= !d1[i][8] && d1[i] >= 8;
            if (sig1[i] == 0 || (!d1[i][8] && d1[i] >= 16)) v2[i] <= 0;
            else if (!d1[i][8] && d1[i] >= 8) v2[i] <= 16'(sig1[i] >> (d1[i] - 9'd8));
            else v2[i] <= {8'd0, sig1[i]} << (9'd7 - d1[i]);
            // 3: rounding
            neg3[i] <= neg2[i];
            mag3[i] <= right2[i] ? (v2[i] + 1'b1) >> 1 : v2[i];
            // 4: sign
            mant[16*i +: 16] <= neg3[i] ? -mag3[i] : mag3[i];
        end
endmodule

// golden_fixed.exp2_neg: 2^(-x / 2^16) as UQ1.20, x >= 0 (x registered by the
// caller). Latency LAT_EXP = 8: table lookups, product (4), rounding and
// the shift addend, sum, shift.
module v4_exp2 (
    input  logic clk,
    input  logic [32:0] x,
    output logic [attn_pkg::PW-1:0] p
);
    import attn_pkg::*;
    `include "exp2_tables.svh"
    localparam int LM = mul_lat(PW + 1);
    logic [16:0] n [LM+2:1];
    logic [PW-1:0] hi1, lo1;
    logic signed [2*PW+1:0] prod;
    logic [PW-1:0] frac;
    logic [PW:0] v, add;
    logic [4:0] sh, sh0;
    logic zero, zero0;
    v4_mul_cascade #(.XW(PW + 1), .YW(PW + 1)) mul (.clk, .x({1'b0, lo1}), .y({1'b0, hi1}), .p(prod));
    always_ff @(posedge clk) begin
        // 1: table lookups
        n[1] <= x[32:16];
        hi1 <= EXP2_HI[x[15:8]];
        lo1 <= EXP2_LO[x[7:0]];
        for (int s = 2; s <= LM + 2; s++) n[s] <= n[s-1];
        // 1 + LM: 2^-f = round(prod / 2^FP)
        frac <= PW'((prod + (2*PW+2)'(1 << (FP - 1))) >> FP);
        // shift by the integer part n: rounding addend (decoded from n a stage
        // early), sum, shift
        zero0 <= n[LM+1] > FP;
        sh0 <= 5'(n[LM+1]);
        add <= n[LM+1] == 0 || n[LM+1] > FP ? (PW+1)'(0) : (PW+1)'(1) << (n[LM+1] - 1);
        zero <= zero0;
        sh <= sh0;
        v <= {1'b0, frac} + add;
        p <= zero ? PW'(0) : PW'(v >> sh);
    end
endmodule

// golden_fixed.score_log2: t = dot * C shifted by eq + ek - 29, saturating to
// +-(2^31 - 1). Latency LAT_SCORE = 11: operands, product (5), magnitude,
// saturation test / rounding term, coarse shift, fine shift, clip.
module v4_score (
    input  logic clk,
    input  logic signed [attn_pkg::DOT_W-1:0] dot,
    input  attn_pkg::exp_t eq,
    input  attn_pkg::exp_t ek,
    output logic signed [attn_pkg::TW-1:0] t
);
    import attn_pkg::*;
    localparam int PRW = DOT_W + 17;
    localparam int LM = mul_lat(DOT_W);
    localparam logic signed [63:0] T_MAX = 64'sd2147483647;
    logic signed [DOT_W-1:0] dot0;
    logic signed [11:0] sh [LM:0];
    logic signed [PRW-1:0] prod;
    // after the product: 5 magnitude, 6 saturation / rounding, 7 coarse shift, 8 fine shift
    logic left5, neg5, zero5;
    logic [5:0] left_amt5, right_amt5;
    logic [PRW-1:0] mag5;
    logic signed [PRW-1:0] val5;
    logic left6, sat6, neg6, zero6;
    logic [5:0] amt6;
    logic signed [63:0] val6;
    logic left7, sat7, neg7, zero7;
    logic [2:0] amt7;
    logic signed [63:0] val7;
    logic signed [63:0] out8;
    v4_mul_cascade #(.XW(DOT_W), .YW(17)) mul (.clk, .x(dot0), .y(17'(C_SCORE)), .p(prod));
    always_ff @(posedge clk) begin
        dot0 <= dot;
        sh[0] <= 12'(eq) + 12'(ek) - 12'sd29;
        for (int s = 1; s <= LM; s++) sh[s] <= sh[s-1];
        // 5: sign, magnitude, shift amounts
        left5 <= sh[LM] >= 0;
        neg5 <= prod < 0;
        mag5 <= prod < 0 ? PRW'(-prod) : PRW'(prod);
        val5 <= prod;
        left_amt5 <= sh[LM] > 31 ? 6'd31 : 6'(sh[LM]);
        right_amt5 <= -sh[LM] >= 62 ? 6'd62 : 6'(-sh[LM]);
        zero5 <= sh[LM] < 0 && -sh[LM] >= 62;
        // 6: saturation (mag >= 2^(31 - left)) or the rounding term of the right shift
        begin
            logic hit;
            hit = 0;
            for (int i = 0; i < PRW; i++) if (mag5[i] && i + int'(left_amt5) >= 31) hit = 1;
            sat6 <= left5 && hit;
        end
        left6 <= left5; neg6 <= neg5; zero6 <= zero5;
        amt6 <= left5 ? left_amt5 : right_amt5;
        val6 <= left5 ? 64'(val5) : 64'(val5) + (64'sd1 <<< (right_amt5 - 1));
        // 7, 8: shift by 8 * amt[5:3], then by amt[2:0]
        left7 <= left6; sat7 <= sat6; neg7 <= neg6; zero7 <= zero6;
        amt7 <= amt6[2:0];
        val7 <= left6 ? val6 <<< {amt6[5:3], 3'b0} : val6 >>> {amt6[5:3], 3'b0};
        if (sat7) out8 <= neg7 ? -T_MAX : T_MAX;
        else if (zero7) out8 <= 0;
        else if (left7) out8 <= val7 <<< amt7;
        else out8 <= val7 >>> amt7;
        // 9: clip
        t <= out8 > T_MAX ? TW'(T_MAX) : out8 < -T_MAX ? TW'(-T_MAX) : TW'(out8);
    end
endmodule

// golden_fixed.mul_round_shift: floor((o * a + 2^(s-1)) / 2^s) for s >= 1;
// zero when s >= the product width (0 there for every o). Computed as
// (floor(o * a / 2^(s-1)) + 1) >> 1, which is the same integer.
// Latency LAT_MRS = 9 for OW <= 52: operands, product (5), coarse shift, fine shift, round.
module v4_mul_round_shift #(
    parameter int OW = attn_pkg::OW,
    parameter int AW = attn_pkg::PW
) (
    input  logic clk,
    input  logic signed [OW-1:0] o,
    input  logic [AW-1:0] a,
    input  logic [7:0] s,
    output logic signed [OW-1:0] y
);
    localparam int PRW = OW + AW + 1;
    localparam int LM = attn_pkg::mul_lat(OW);
    logic signed [OW-1:0] o0;
    logic signed [AW:0] a0;
    logic [6:0] sh [LM:0];                     // min(s - 1, PRW - 1)
    logic signed [PRW-1:0] prod, q1;
    wire signed [PRW-1:0] fine = q1 >>> sh_lo;
    logic [2:0] sh_lo;
    v4_mul_cascade #(.XW(OW), .YW(AW + 1)) mul (.clk, .x(o0), .y(a0), .p(prod));
    always_ff @(posedge clk) begin
        o0 <= o;
        a0 <= {1'b0, a};
        sh[0] <= s - 8'd1 >= 8'(PRW - 1) ? 7'(PRW - 1) : 7'(s - 8'd1);
        for (int i = 1; i <= LM; i++) sh[i] <= sh[i-1];
        q1 <= prod >>> {sh[LM][6:3], 3'b0};
        sh_lo <= sh[LM][2:0];
    end
    v4_round_from_fine #(.WIDTH(OW+1)) rounding(.clk,.value(fine[OW:0]),.bypass(1'b0),.y);
endmodule

// golden_fixed.round_shift for a signed value: (x + 2^(s-1)) >> s, s >= 0,
// 0 when s >= 62. As above, (floor(x / 2^(s-1)) + 1) >> 1 for s >= 1.
// Latency LAT_RS = 3: coarse shift, fine shift, round.
module v4_round_shift #(parameter int XW = attn_pkg::OBW) (
    input  logic clk,
    input  logic signed [XW-1:0] x,
    input  logic [8:0] s,
    output logic signed [XW-1:0] y
);
    localparam int SW = $clog2(XW + 1);
    logic [SW-1:0] sh;                         // min(s - 1, XW): x >> XW is 0 or -1
    logic signed [XW-1:0] x1;
    wire signed [XW-1:0] fine = x1 >>> sh_lo;
    logic [2:0] sh_lo;
    logic pass1;                               // s == 0
    always_comb sh = s == 0 ? SW'(0) : s - 1'b1 >= 9'(XW) ? SW'(XW) : SW'(s - 1'b1);
    always_ff @(posedge clk) begin
        x1 <= x >>> {sh[SW-1:3], 3'b0};
        sh_lo <= sh[2:0];
        pass1 <= s == 0;
    end
    v4_round_from_fine #(.WIDTH(XW+1)) rounding(
        .clk,.value({fine[XW-1],fine}),.bypass(pass1),.y);
endmodule

// Two stages, replacing the existing fine-register + rounding-register pair.
// Prefix carries are computed beside the fine shift. The final increment uses
// independent <=16-bit chains; modulo-WIDTH addition exactly preserves all
// signed guard bits and the original (value+1)>>1 low-bit result.
module v4_round_from_fine #(parameter int WIDTH=45) (
    input logic clk,
    input logic [WIDTH-1:0] value,
    input logic bypass,
    output logic signed [WIDTH-2:0] y
);
    localparam int BLOCK=16, N=(WIDTH+BLOCK-1)/BLOCK;
    logic [WIDTH-1:0] held,incremented;
    logic [N-1:0] carry;
    logic bypass_q;
    always_ff @(posedge clk)begin held<=value;bypass_q<=bypass;end
    for(genvar g=0;g<N;g++)begin:g_round
        localparam int BITS=(WIDTH-g*BLOCK)<BLOCK ? WIDTH-g*BLOCK:BLOCK;
        if(g==0)assign carry[g]=1'b1;
        else always_ff @(posedge clk)carry[g]<=&value[g*BLOCK-1:0];
        assign incremented[g*BLOCK+:BITS]=held[g*BLOCK+:BITS]+BITS'(carry[g]);
    end
    always_ff @(posedge clk)y<=bypass_q ? held[WIDTH-2:0]:incremented[WIDTH-1:1];
endmodule

// floor(2^62 / lm) for lm in [2^31, 2^32): restoring division, one bit per
// cycle. The remainder stays below lm, so it needs 32 bits.
module v4_recip (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic [31:0] lm,
    output logic busy,
    output logic done,
    output logic [31:0] q
);
    logic [31:0] rem;
    logic [31:0] div;
    logic [5:0] k;
    always_ff @(posedge clk) begin
        done <= 0;
        if (!rst_n) begin
            busy <= 0;
        end else if (start && !busy) begin
            busy <= 1; div <= lm; k <= 6'd62; rem <= 0; q <= 0;
        end else if (busy) begin
            // dividend bit k of 2^62 is 1 only for k = 62
            logic [32:0] r;
            logic [33:0] t;
            r = {rem, k == 62};
            t = {1'b0, r} - {2'b0, div};          // borrow (t[33]) means r < div
            rem <= t[33] ? r[31:0] : t[31:0];
            q <= {q[30:0], !t[33]};
            if (k == 0) begin busy <= 0; done <= 1; end
            else k <= k - 1'b1;
        end
    end
endmodule

// golden_fixed.bf16_from_scaled(o * recip, e): round o * recip * 2^e to BF16
// (nearest even, signed zero on underflow, Inf on overflow). The magnitude
// |o| is multiplied in three 24-bit pieces. Latency LAT_TOBF = 13: magnitude,
// products (4), two partial sums, chunk leading ones, coarse normalise, fine
// normalise, guard/sticky, round, pack.
module v4_to_bf16 (
    input  logic clk,
    input  logic signed [attn_pkg::OW-1:0] o,
    input  logic [attn_pkg::RECIP_W-1:0] recip,
    input  logic signed [11:0] e,
    output logic [15:0] bf16
);
    import attn_pkg::*;
    localparam int YW = OW + RECIP_W;          // magnitude bits of the product
    localparam int NCH = (YW + 15) / 16;       // 16-bit chunks for the leading-one search
    localparam int PADW = 16 * NCH;
    localparam int LM = mul_lat(RECIP_W + 1);
    localparam int D = LM + 8;                 // tags: ed[s] / sd[s] belong to the value in stage s
    logic [OW-1:0] a1;
    logic [RECIP_W-1:0] r1;
    logic signed [11:0] ed [D:1];
    logic sd [D:1];
    logic signed [RECIP_W+25:0] pp [3];
    logic [YW-1:0] u;
    logic [YW-25:0] pp0_hi;
    logic [23:0] lo24;
    logic [YW-1:0] prod;
    logic [NCH-1:0] nz;
    logic [3:0] pos [NCH];
    logic [PADW-1:0] v7, n8, n9;
    logic [3:0] fine8;
    logic signed [12:0] ex8, ex9, exb10;
    logic zero8, zero9, zero10, zero11, up10;
    logic [7:0] mant10, mant11, exf11;
    logic under11, over11;
    for (genvar i = 0; i < 3; i++) begin : g_mul
        v4_mul_cascade #(.XW(RECIP_W + 1), .YW(25)) mul (.clk, .x({1'b0, r1}),
            .y({1'b0, 24'(a1 >> (24 * i))}), .p(pp[i]));
    end
    always_ff @(posedge clk) begin
        // 1: magnitude
        a1 <= o < 0 ? OW'(-o) : OW'(o);
        r1 <= recip;
        ed[1] <= e;
        sd[1] <= o < 0;
        for (int s = 2; s <= D; s++) begin ed[s] <= ed[s-1]; sd[s] <= sd[s-1]; end
        // 1 + LM, 2 + LM: |o| * recip = pp0 + (pp1 + pp2 * 2^24) * 2^24
        u <= YW'(pp[1]) + (YW'(pp[2]) << 24);
        pp0_hi <= (YW-24)'(pp[0] >>> 24);
        lo24 <= pp[0][23:0];
        prod <= {(YW-24)'(u) + pp0_hi, lo24};
        // 3 + LM: per-chunk leading ones
        v7 <= PADW'(prod);
        for (int c = 0; c < NCH; c++) begin
            logic [15:0] ch;
            ch = 16'(PADW'(prod) >> (16 * c));
            nz[c] <= ch != 0;
            pos[c] <= 0;
            for (int i = 0; i < 16; i++) if (ch[i]) pos[c] <= 4'(i);
        end
        // 4 + LM: highest non-zero chunk to the top
        begin
            int top;
            top = 0;
            for (int c = 0; c < NCH; c++) if (nz[c]) top = c;
            n8 <= v7 << (16 * (NCH - 1 - top));
            fine8 <= 4'd15 - pos[top];
            ex8 <= 13'(16 * top) + 13'(pos[top]) + 13'(ed[LM+4]);
            zero8 <= nz == 0;
        end
        // 5 + LM: leading one to bit PADW - 1
        n9 <= n8 << fine8;
        ex9 <= ex8;
        zero9 <= zero8;
        // 6 + LM: 8 significant bits, round-to-nearest-even decision
        mant10 <= n9[PADW-1 -: 8];
        up10 <= n9[PADW-9] && ((|n9[PADW-10:0]) || n9[PADW-8]);
        exb10 <= ex9 + 13'sd127;
        zero10 <= zero9;
        // 7 + LM: round; a carry out of the significand bumps the exponent
        begin
            logic carry;
            logic signed [12:0] exc;
            carry = up10 && mant10 == 8'hFF;
            exc = exb10 + (carry ? 13'sd1 : 13'sd0);
            mant11 <= carry ? 8'h80 : mant10 + 8'(up10);
            exf11 <= exc[7:0];
            under11 <= exc <= 0;
            over11 <= exc >= 255;
            zero11 <= zero10;
        end
        // 8 + LM: pack
        if (zero11) bf16 <= 16'd0;                         // golden: exact zero, no sign
        else if (under11) bf16 <= {sd[LM+8], 15'd0};
        else if (over11) bf16 <= {sd[LM+8], 15'h7F80};
        else bf16 <= {sd[LM+8], exf11, mant11[6:0]};
    end
endmodule
