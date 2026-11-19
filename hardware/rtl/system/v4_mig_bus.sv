`timescale 1ns/1ps
// Five clients: host, Q, K, V, O. Native reads are tagged in order; at most
// 64 beats are outstanding. 512-bit lines use two BL8 transactions.
// All clients use BYTE addresses. Only this module converts to x32 DRAM words.
module v4_mig_bus (
    input logic clk, rst_n,
    input logic [2:0] burst_log2,
    input logic [28:0] host_addr,
    input logic [2:0] host_cmd,
    input logic host_en, host_wren,
    input logic [255:0] host_wdata,
    input logic [31:0] host_mask,
    output logic host_rdy, host_wrdy,
    output logic [255:0] host_rdata,
    output logic host_rvalid,
    input logic [2:0] req_valid,
    output logic [2:0] req_ready,
    input logic [31:0] req_addr [3],
    output logic [2:0] rsp_valid,
    input logic [2:0] rsp_ready,
    output logic [511:0] rsp_data [3],
    input logic out_valid,
    output logic out_ready,
    input logic [543:0] out_data,
    output logic [31:0] written_gray,
    output logic fault,
    output logic [28:0] app_addr,
    output logic [2:0] app_cmd,
    output logic app_en,
    input logic app_rdy,
    output logic [255:0] app_wdf_data,
    output logic [31:0] app_wdf_mask,
    output logic app_wdf_end, app_wdf_wren,
    input logic app_wdf_rdy,
    input logic [255:0] app_rd_data,
    input logic app_rd_data_valid,
    output logic [31:0] read_beats, write_beats, stall_cycles,
    output logic [31:0] diagnostic [17]
);
    logic locked, half, cmd_sent, data_sent;
    logic [2:0] owner, rr, pick;
    logic found;
    logic [4:0] served;
    logic [6:0] inflight;
    logic previous_valid;
    logic [2:0] previous_owner, previous_bank;
    logic [14:0] previous_row;
    logic [16:0] events;
    logic [4:0] want;
    logic [31:0] byte_addr, written;
    logic tag_full, tag_empty, tag_push;
    logic [2:0] tag_in, tag_out;
    logic [255:0] low [3];
    logic write_op, command_fire, data_fire, finish, beat_done;
    assign want = {out_valid,req_valid,host_en || host_wren};
    always_comb begin
        pick = owner; found = locked;
        // A completed line may retain its owner for a bounded quantum.
        // An empty port yields immediately; host traffic always rotates.
        if (!locked && served != 0 && owner != 0 && want[owner]) found = 1;
        if (!locked && !found) begin
            pick = 0;
            for (int i=0;i<5;i++) begin
                if (!found && want[(int'(rr)+i)%5]) begin
                    pick = 3'((int'(rr)+i)%5); found = 1;
                end
            end
        end
        write_op = pick == 4 || (pick == 0 && host_cmd == 0);
        byte_addr = 0;
        if (pick == 0) byte_addr = {3'd0,host_addr};
        else if (pick == 4) byte_addr = out_data[543:512] + (half ? 32 : 0);
        else byte_addr = req_addr[pick-1] + (half ? 32 : 0);
        app_addr = {1'b0,byte_addr[29:2]};
        app_cmd = write_op ? 3'd0 : 3'd1;
        app_en = found && !cmd_sent && (write_op || !tag_full) && (pick != 0 || host_en);
        app_wdf_wren = found && write_op && !data_sent && (pick != 0 || host_wren);
        app_wdf_end = app_wdf_wren;
        app_wdf_data = pick == 0 ? host_wdata : (half ? out_data[511:256] : out_data[255:0]);
        app_wdf_mask = pick == 0 ? host_mask : 32'd0;
        command_fire = app_en && app_rdy;
        data_fire = app_wdf_wren && app_wdf_rdy;
        beat_done = write_op ? (cmd_sent || command_fire) && (data_sent || data_fire) : command_fire;
        finish = beat_done && (pick == 0 || half);
        host_rdy = found && pick == 0 && !cmd_sent && (write_op || !tag_full) && app_rdy;
        host_wrdy = found && pick == 0 && !data_sent && app_wdf_rdy;
        req_ready = 0;
        if (finish && pick > 0 && pick < 4) req_ready[pick-1] = 1;
        out_ready = finish && pick == 4;
        tag_push = command_fire && !write_op;
        tag_in = {half,2'(pick)};
        rsp_valid = 0;
        for (int i=0;i<3;i++) begin
            rsp_data[i] = {app_rd_data,low[i]};
            rsp_valid[i] = app_rd_data_valid && !tag_empty && tag_out[1:0] == 2'(i+1) && tag_out[2];
        end
        host_rvalid = app_rd_data_valid && !tag_empty && tag_out[1:0] == 0;
        host_rdata = app_rd_data;
    end
    always_comb begin
        events = 0;
        events[0] = app_en && !app_rdy;
        events[1] = app_wdf_wren && !app_wdf_rdy;
        events[2] = found && !write_op && !cmd_sent && tag_full;
        events[5:3] = ~req_valid;
        events[6] = !out_valid;
        events[7] = command_fire && previous_valid && pick != previous_owner;
        events[8] = command_fire && previous_valid && byte_addr[29:27] != previous_bank;
        events[9] = command_fire && previous_valid && byte_addr[29:27] == previous_bank && byte_addr[26:12] != previous_row;
        events[10] = inflight == 0;
        events[11] = inflight > 0 && inflight < 8;
        events[12] = inflight >= 8 && inflight < 16;
        events[13] = inflight >= 16 && inflight < 32;
        events[14] = inflight >= 32 && inflight < 48;
        events[15] = inflight >= 48 && inflight < 64;
        events[16] = inflight == 64;
    end
    v4_fifo #(.WIDTH(3),.DEPTH(64)) tags(.clk,.rst_n,.push(tag_push),.din(tag_in),.full(tag_full),
        .pop(app_rd_data_valid),.dout(tag_out),.empty(tag_empty));
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            locked <= 0; half <= 0; cmd_sent <= 0; data_sent <= 0; owner <= 0; rr <= 0;
            served <= 0; inflight <= 0; previous_valid <= 0;
            previous_owner <= 0; previous_bank <= 0; previous_row <= 0;
            for (int i=0;i<17;i++) diagnostic[i] <= 0;
            written <= 0; written_gray <= 0; fault <= 0; read_beats <= 0; write_beats <= 0; stall_cycles <= 0;
        end else begin
            inflight <= inflight + tag_push - app_rd_data_valid;
            for (int i=0;i<17;i++) if (events[i]) diagnostic[i] <= diagnostic[i]+1'b1;
            if (command_fire) begin
                previous_valid <= 1; previous_owner <= pick;
                previous_bank <= byte_addr[29:27]; previous_row <= byte_addr[26:12];
            end
            if (!locked && served != 0 && !want[owner]) served <= 0;
            if (found) begin
                owner <= pick; locked <= !finish;
                if (finish) begin
                    half <= 0;
                    if (pick != 0 && ((pick == owner ? served : 0)+1'b1) < (5'd1 << burst_log2)) begin
                        served <= (pick == owner ? served : 0)+1'b1;
                    end else begin
                        served <= 0; rr <= pick == 4 ? 3'd0 : pick+1'b1;
                    end
                end
                else if (beat_done) half <= 1;
                if (beat_done) begin cmd_sent <= 0; data_sent <= 0; end
                else begin cmd_sent <= cmd_sent || command_fire; data_sent <= data_sent || data_fire; end
            end
            // Match the registered counter-Gray CDC latency used by snapshots.
            written_gray <= (written>>1)^written;
            if (out_ready) written <= written+1'b1;
            if (tag_push) read_beats <= read_beats+1'b1;
            if (beat_done && write_op) write_beats <= write_beats+1'b1;
            if (found && !beat_done) stall_cycles <= stall_cycles+1'b1;
            if (app_rd_data_valid) begin
                if (tag_empty) fault <= 1;
                else if (tag_out[1:0] != 0 && !tag_out[2]) low[tag_out[1:0]-1] <= app_rd_data;
            end
            if (|(rsp_valid & ~rsp_ready)) fault <= 1; // credit bug: MIG cannot be backpressured
        end
    end
endmodule
