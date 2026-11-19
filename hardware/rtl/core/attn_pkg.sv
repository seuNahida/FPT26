`timescale 1ns/1ps
// v4 attention core: geometry and number formats. The numerical behaviour is
// specified bit for bit by attn/model/golden_fixed.py; widths here follow it.
package attn_pkg;
    localparam int D = 128;              // head dimension
    localparam int G = 4;                // query heads per KV head
    localparam int W = 8;                // dimensions per cycle in the QK / PV arrays
    localparam int CH = D / W;           // chunks per row
    localparam int R = 16;               // rows (lanes) processed together
    localparam int T = R / G;            // query positions per tile
    localparam int BC = 32;              // KV tokens per block
    localparam int SMAX = 4;             // Q tiles that share each K / V block read (a super-tile)
    localparam int QSLOTS = 2 * SMAX;    // Q slots: two super-tiles of SMAX tiles
    localparam int KB = 4;               // K block slots
    localparam int LINE = 32;            // BF16 elements per buffer line (512 bits)
    localparam int ROW_LINES = D / LINE; // buffer lines per row
    localparam int POS_W = 16;           // positions / lengths

    localparam int FP = 20;              // fraction bits of p, alpha, l
    localparam int FRAC_T = 16;          // fraction bits of the log2-domain score
    localparam int C_SCORE = 16714;      // round(log2(e) / sqrt(128) * 2^17)
    localparam int ZERO_EXP = -134;      // exponent of an all-zero row / block

    // widths
    localparam int EW = 10;              // signed exponents
    localparam int MW = 16;              // signed mantissas
    localparam int DOT_W = 40;           // QK dot (|dot| < 2^38)
    localparam int TW = 32;              // score t
    localparam int PW = FP + 1;          // p and alpha, UQ1.FP
    localparam int LW = 40;              // l, UQ19.FP (up to 64K keys)
    localparam int OBW = 44;             // one block's O contribution (BC * 2^FP * 2^15)
    localparam int OW = 52;              // accumulated O: |O| <= keys * 2^FP * 32640 < 2^51 for 64K keys
    localparam int RECIP_W = 32;         // floor(2^62 / lm), lm in [2^31, 2^32)

    // pipeline latencies of the arithmetic units (v4_math.sv); the core aligns
    // its tag pipelines to these, so a unit can be deepened in one place
    localparam int LAT_MAX = 6;          // v4_max_exp32
    localparam int LAT_BFP = 4;          // v4_bfp8
    localparam int LAT_EXP = 8;          // v4_exp2
    localparam int LAT_SCORE = 11;       // v4_score
    localparam int LAT_MRS = 9;          // v4_mul_round_shift (O and l operands: 3 DSP slices)
    localparam int LAT_RS = 3;           // v4_round_shift
    localparam int LAT_TOBF = 13;        // v4_to_bf16
    localparam int NCV = 4;              // to_bf16 units: final emits a chunk of W values in W / NCV cycles
    // memory read latencies: the Q/K/V ports (address register, BRAM, output
    // register in the test shell) and the core's own block RAMs (output register)
    localparam int MEM_LAT = 3;
    localparam int RAM_LAT = 2;

    // cascade multiplier: 17-bit slices of x, one DSP each (v4_mul_cascade)
    function automatic int mul_slices(input int xw);
        return xw <= 18 ? 1 : (xw - 18 + 16) / 17 + 1;
    endfunction
    function automatic int mul_lat(input int xw);   // input register, M, one P per slice
        return mul_slices(xw) + 2;
    endfunction

    typedef logic signed [MW-1:0] mant_t;
    typedef logic signed [EW-1:0] exp_t;

    localparam int ADDR_W = POS_W + 3;   // rows / tokens of up to 8 groups

    // A job: query rows r = 0..q_len-1 at absolute positions q_pos + r attend
    // to keys 0..q_pos + r. Requires q_pos + q_len <= kv_len. A job covers
    // `groups` KV groups (1..8; 0 counts as 1) with the same lengths, packed
    // one after the other: Q / O row g * q_len * 4 + r * 4 + head, K / V token
    // g * kv_len + j. `sub` (1..SMAX; 0 counts as SMAX) tiles form a
    // super-tile: each K / V block is read once and used by all its tiles.
    typedef struct packed {
        logic [2:0] sub;
        logic [3:0] groups;
        logic [POS_W-1:0] q_len;
        logic [POS_W-1:0] q_pos;
        logic [POS_W-1:0] kv_len;
        logic [POS_W-1:0] kv_stride; // 0 = kv_len, otherwise tokens between groups
    } job_t;

    // One KV block of one tile. A tile holds T query positions x G heads;
    // lane = (position - tile start) * G + head. The tiles of a super-tile
    // take each block in turn: for block b, for tile s = 0.. of the
    // super-tile. A block is read for the first tile that sees it (kvfirst,
    // nkf keys: as many as the super-tile's last tile needs) and released
    // after the last tile (slast).
    typedef struct packed {
        logic [ADDR_W-1:0] qrow0;       // Q / O row of the group's first query
        logic [ADDR_W-1:0] kabs0;       // K / V token of the block's first key (group base + k0)
        logic [POS_W-1:0] tile;
        logic [POS_W-1:0] pos_base;     // absolute position of the tile's first query
        logic [2:0] npos;               // query positions present in the tile (1..T)
        logic [POS_W-1:0] k0;           // first key of the block
        logic [5:0] nk;                 // keys computed (1..BC): up to the tile's last position
        logic [5:0] nkf;                // keys read for the block (nk of the super-tile's last tile)
        logic [5:0] nv;                 // V tokens read for the block exponent (nkf..BC)
        logic first;                    // first / last block of the tile
        logic last;
        logic last_tile;                // the job's last tile (last group)
        logic [1:0] sub;                // tile within the super-tile
        logic slast;                    // the super-tile's last tile: the block's last use
        logic kvfirst;                  // the block's first use: K and V are read
        logic spar;                     // super-tile parity over the job (Q and O slots)
    } blk_t;

    // Q slot of a tile: {super-tile parity, tile within the super-tile}
    function automatic logic [2:0] qslot(input blk_t b);
        return {b.spar, b.sub};
    endfunction

    function automatic logic lane_valid(input blk_t b, input int lane);
        return 3'(lane / G) < b.npos;
    endfunction
    function automatic logic [POS_W-1:0] lane_pos(input blk_t b, input int lane);
        return b.pos_base + POS_W'(lane / G);
    endfunction
    function automatic logic lane_active(input blk_t b, input int lane);
        return lane_valid(b, lane) && lane_pos(b, lane) >= b.k0;
    endfunction
    function automatic logic [R-1:0] act_mask(input blk_t b);
        logic [R-1:0] m;
        for (int l = 0; l < R; l++) m[l] = lane_active(b, l);
        return m;
    endfunction

    // Unbiased group exponent from the biased maximum (ZERO_EXP when all zero).
    function automatic exp_t unbias(input logic [7:0] max_e);
        return max_e == 0 ? exp_t'(ZERO_EXP) : exp_t'($signed({2'b0, max_e}) - 10'sd127);
    endfunction
endpackage
