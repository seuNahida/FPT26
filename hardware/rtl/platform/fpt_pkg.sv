// Public contracts. All application interfaces use ready/valid in their own clock domain.
`timescale 1ns/1ps
package fpt_pkg;
    localparam int MAX_SEQ = 128;
    localparam int HEAD_DIM = 128;
    localparam int LANES = 8;
    localparam int POS_W = $clog2(MAX_SEQ);
    localparam int DIM_W = $clog2(HEAD_DIM);
    localparam int BULK_WORDS = 360;
    localparam int BULK_W = $clog2(BULK_WORDS);
    localparam logic [31:0] Q_BASE = 32'h00000000;
    localparam logic [31:0] K_BASE = 32'h00100000;
    localparam logic [31:0] V_BASE = 32'h00200000;
    localparam logic [31:0] O_BASE = 32'h00300000;
    localparam int SLOT_SHIFT = 22;

    typedef struct packed {
        logic decode;
        logic [15:0] kv_len, q_len, q_position;
    } attention_task_t;
    typedef struct packed {
        attention_task_t attention;
        logic [6:0] kv_slot;
    } memory_task_t;
    typedef enum logic [1:0] {TENSOR_Q, TENSOR_K, TENSOR_V} tensor_t;
    typedef struct packed {
        tensor_t tensor;
        logic [1:0] head;
        logic [POS_W-1:0] row;
        logic [DIM_W-1:0] dim;
        logic [15:0] bf16;
    } tensor_word_t;
    typedef struct packed {
        logic [1:0] head;
        logic [POS_W-1:0] row;
        logic [DIM_W-1:0] dim;
        logic [15:0] bf16;
    } result_word_t;
    typedef struct packed {
        logic ready, busy, done, error, core_error;
        logic [3:0] pods;
        logic [63:0] cycles, outputs;
    } status_t;
    typedef struct packed {
        logic core_busy;
        logic [11*64-1:0] counters;
        logic [32*64-1:0] pipeline;
    } compute_perf_t;
    typedef struct packed {
        logic ready, load_busy, store_busy, load_done, store_done, error;
        logic [31:0] loaded_words, stored_words;
    } memory_status_t;
    typedef struct packed {
        logic capture, high;
        logic [31:0] index;
        logic [15:0] events;
        logic [32*64-1:0] core;
    } probe_input_t;
    typedef struct packed {
        logic done;
        logic [31:0] generation, data;
    } probe_output_t;

    // ATN1 command framing is confined to ethernet.sv; these are application messages.
    typedef struct packed {
        logic valid;
        logic [7:0] opcode, flags;
        logic [15:0] txn;
        logic [31:0] arg0, arg1, arg2;
        logic [2:0] bulk_slot;
        logic [BULK_W:0] bulk_count;
    } command_t;
    typedef struct packed {
        logic valid;
        logic [7:0] status, opcode;
        logic [15:0] txn;
        logic [31:0] data;
    } response_t;
    // Packet storage has eight slots, retained through transmission of its reply.
    typedef struct packed {
        logic valid;
        logic [2:0] slot;
        logic [BULK_W-1:0] index;
        logic [BULK_W:0] count;
        logic [31:0] data;
    } bulk_write_t;
    typedef struct packed {
        logic [2:0] slot;
        logic [BULK_W-1:0] index;
    } bulk_read_t;
    function automatic logic is_memory_command(input logic [7:0] opcode);
        return opcode >= 8'h40 && opcode <= 8'h44;
    endfunction
endpackage

// Private numeric format, shared by the arithmetic units.
// ---- Private implementation: fpt_math_attention_pkg.sv ----
`timescale 1ns/1ps
package fpt_math_attention_pkg;

    // External Q/K/V are BF16. They are converted to signed Q8.8 at the
    // attention-top write boundary; the internal datapath remains fixed-point.
    localparam int V3_BF16_W      = 16;
    localparam int V3_DATA_W       = 16;
    localparam int V3_DATA_FRAC    = 8;

    // QK dot keeps the full product accumulation, then score scaling drops
    // the 2*DATA_FRAC fractional bits back to SCORE_FRAC.
    localparam int V3_ACC_W        = 48;
    localparam int V3_SCORE_W      = 32;
    localparam int V3_SCORE_FRAC   = 12;
    localparam int V3_SCALE_W      = 18;
    localparam int V3_SCALE_FRAC   = 0;
    localparam logic signed [V3_SCALE_W-1:0] V3_SCORE_SCALE_Q = 18'sd4096;
    localparam int V3_SCORE_SHIFT  = 2 * V3_DATA_FRAC;

    // exp/l/o use the online-softmax fixed-point state format.
    localparam int V3_EXP_W        = 24;
    localparam int V3_EXP_FRAC     = 16;
    localparam int V3_SUM_W        = 32;
    localparam int V3_O_ACC_W      = 48;
    localparam int V3_O_FRAC       = 16;
    // The internal normalized result is Q16.16. The external 32-bit stream
    // carries one BF16 value in bits [15:0], with bits [31:16] cleared.
    localparam int V3_OUT_W        = 32;
    localparam int V3_OUT_FRAC     = 16;

endpackage
