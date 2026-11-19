`timescale 1ns/1ps
// Packet DMA: pipeline every 256-bit beat through CDC, acknowledge writes only
// after their final command/data handshake. Reads may have many beats in flight.
// The outer dispatcher retains the packet slot until the reply is transmitted.
module v4_host_dma (
    input logic clk,rst_n,ddr_clk,ddr_rst_n,
    input fpt_pkg::command_t command,
    output logic command_ready,
    output fpt_pkg::response_t response,
    input fpt_pkg::bulk_write_t bulk_write,
    input fpt_pkg::bulk_read_t bulk_read,
    output logic [31:0] bulk_read_data,
    output logic [28:0] app_addr,
    output logic [2:0] app_cmd,
    output logic app_en,
    input logic app_rdy,
    output logic [255:0] app_wdf_data,
    output logic [31:0] app_wdf_mask,
    output logic app_wdf_wren,app_wdf_end,
    input logic app_wdf_rdy,
    input logic [255:0] app_rd_data,
    input logic app_rd_data_valid
);
    import fpt_pkg::*;
    typedef struct packed {
        logic wr,last;
        logic [28:0] addr;
        logic [31:0] mask;
        logic [255:0] data;
    } beat_t;
    beat_t beat,ddr_beat;
    logic send,send_ready,ddr_valid,ddr_pop;
    logic rsp_valid,rsp_ready,got_valid,got_ready;
    logic [256:0] rsp_data,got_data;
    v4_cdc_fifo #(.WIDTH($bits(beat_t)),.DEPTH(64)) requests(
        .s_clk(clk),.s_rst_n(rst_n),.m_clk(ddr_clk),.m_rst_n(ddr_rst_n),
        .s_data(beat),.s_valid(send),.s_ready(send_ready),.s_depth(),
        .m_data(ddr_beat),.m_valid(ddr_valid),.m_ready(ddr_pop));
    v4_cdc_fifo #(.WIDTH(257),.DEPTH(64)) responses(
        .s_clk(ddr_clk),.s_rst_n(ddr_rst_n),.m_clk(clk),.m_rst_n(rst_n),
        .s_data(rsp_data),.s_valid(rsp_valid),.s_ready(rsp_ready),.s_depth(),
        .m_data(got_data),.m_valid(got_valid),.m_ready(got_ready));
    // Maximum packet: 46 beats including an unaligned head/tail, less than
    // response FIFO depth. Packet commands are serialized by v4_system.
    logic cmd_sent,data_sent,tag_full,tag_empty,tag_last;
    wire cfire=app_en && app_rdy;
    wire wfire=app_wdf_wren && app_wdf_rdy;
    assign app_addr=ddr_beat.addr;
    assign app_cmd=ddr_beat.wr ? 3'd0:3'd1;
    assign app_en=ddr_valid && !cmd_sent && !tag_full;
    assign app_wdf_wren=ddr_valid && ddr_beat.wr && !data_sent;
    assign app_wdf_end=app_wdf_wren;
    assign app_wdf_data=ddr_beat.data;
    assign app_wdf_mask=ddr_beat.mask;
    assign ddr_pop=ddr_valid && (cmd_sent || cfire) && (!ddr_beat.wr || data_sent || wfire);
    v4_fifo #(.WIDTH(1),.DEPTH(64)) read_tags(.clk(ddr_clk),.rst_n(ddr_rst_n),
        .push(cfire && !ddr_beat.wr),.din(ddr_beat.last),.full(tag_full),
        .pop(app_rd_data_valid),.dout(tag_last),.empty(tag_empty));
    assign rsp_valid=app_rd_data_valid || (ddr_pop && ddr_beat.wr && ddr_beat.last);
    assign rsp_data={app_rd_data_valid ? tag_last:1'b1,app_rd_data};
    always_ff @(posedge ddr_clk) begin
        if(!ddr_rst_n)begin cmd_sent<=0;data_sent<=0;end
        else if(ddr_pop)begin cmd_sent<=0;data_sent<=0;end
        else begin cmd_sent<=cmd_sent || cfire;data_sent<=data_sent || wfire;end
    end
    // Flat, registered packet RAMs; original endian-neutral 32-bit wire words.
    (* ram_style="block" *) logic [31:0] payload[4096],reply_mem[4096];
    logic [11:0] payload_addr;
    logic [31:0] payload_data;
    always_ff @(posedge clk) begin
        if(bulk_write.valid)payload[{bulk_write.slot,bulk_write.index}]<=bulk_write.data;
        payload_data<=payload[payload_addr];
        bulk_read_data<=reply_mem[{bulk_read.slot,bulk_read.index}];
    end
    typedef enum logic [2:0] {IDLE,PREP,PACK,SEND,WAIT_READ,UNPACK,WAIT_WRITE} state_t;
    state_t state;
    command_t saved;
    logic write_job,bulk;
    logic [9:0] count,index,read_index;
    logic [2:0] lane,read_lane;
    logic [3:0] take,pack_i,unpack_i,read_take;
    logic [31:0] address,read_address;
    logic [255:0] read_hold;
    logic [31:0] word_result;
    (* ASYNC_REG="TRUE" *) logic [1:0] calibrated;
    logic [31:0] timeout_count;
    logic poisoned;
    function automatic logic [3:0] nwords(input logic [2:0] l,input logic [9:0] left);
        return left < 10'(8-int'(l)) ? 4'(left):4'(8-int'(l));
    endfunction
    assign command_ready=state==IDLE;
    assign send=state==SEND;
    assign got_ready=(state==WAIT_READ) || (state==WAIT_WRITE);
    always_comb begin
        // One-cycle BRAM read: PREP selects word 0, PACK prefetches word i+1.
        payload_addr={saved.bulk_slot,9'(index+10'(pack_i)+(state==PACK ? 1:0))};
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;response<='0;saved<='0;index<=0;read_index<=0;count<=0;pack_i<=0;unpack_i<=0;
            calibrated<=0;poisoned<=0;timeout_count<=0;word_result<=0;
        end else begin
            calibrated<={calibrated[0],ddr_rst_n};
            response.valid<=0;
            if(state==IDLE)timeout_count<=0;else timeout_count<=timeout_count+1'b1;
            // A failed MIG cannot safely recycle packet/FIFO state. Poison the
            // DMA until reset, return an error rather than reusing stale data.
            if(state!=IDLE && timeout_count==32'd100000000) begin
                state<=IDLE;poisoned<=1;response<= '{valid:1'b1,status:8'd4,opcode:saved.opcode,txn:saved.txn,data:32'h54494d45};
            end else case(state)
                IDLE:if(command.valid) begin
                    saved<=command;
                    response<='{valid:1'b1,status:8'd0,opcode:command.opcode,txn:command.txn,data:32'd0};
                    if(command.opcode==8'h40)response.data<={calibrated[1],1'b0,poisoned,29'd0};
                    else if(poisoned)response.status<=4;
                    else if(!calibrated[1])response.status<=1;
                    else if(command.opcode<8'h41 || command.opcode>8'h44 || command.arg0[1:0]!=0 ||
                        command.arg0>=32'h20000000 ||
                        (command.opcode>=8'h43 && (command.arg1==0 || command.arg1>BULK_WORDS ||
                        {1'b0,command.arg0}+({1'b0,command.arg1}<<2)>33'h020000000)) ||
                        (command.opcode==8'h43 && command.bulk_count<command.arg1))response.status<=2;
                    else begin
                        response.valid<=0;state<=PREP;
                        bulk<=command.opcode>=8'h43;
                        write_job<=command.opcode==8'h41 || command.opcode==8'h43;
                        count<=command.opcode>=8'h43 ? 10'(command.arg1):10'd1;
                        index<=0;read_index<=0;pack_i<=0;unpack_i<=0;
                        address<=command.arg0;read_address<=command.arg0;
                        lane<=command.arg0[4:2];read_lane<=command.arg0[4:2];
                        take<=nwords(command.arg0[4:2],command.opcode>=8'h43 ? 10'(command.arg1):10'd1);
                        read_take<=nwords(command.arg0[4:2],command.opcode>=8'h43 ? 10'(command.arg1):10'd1);
                    end
                end
                PREP:begin
                    beat.wr<=write_job;beat.last<=index+10'(take)==count;
                    beat.addr<={address[28:5],5'd0};beat.mask<='1;beat.data<=0;pack_i<=0;
                    if(!write_job)state<=SEND;
                    else if(!bulk) begin
                        beat.data[32*int'(lane)+:32]<=saved.arg2;
                        beat.mask[4*int'(lane)+:4]<=~(saved.arg1[3:0]==0 ? 4'hf:saved.arg1[3:0]);state<=SEND;
                    end else state<=PACK;
                end
                PACK:begin
                    beat.data[32*(int'(lane)+int'(pack_i))+:32]<=payload_data;
                    beat.mask[4*(int'(lane)+int'(pack_i))+:4]<=0;
                    if(pack_i+1==take)state<=SEND;else pack_i<=pack_i+1'b1;
                end
                SEND:if(send_ready) begin
                    if(beat.last)state<=write_job ? WAIT_WRITE:WAIT_READ;
                    else begin
                        index<=index+10'(take);address<=address+32'(take)*4;lane<=0;pack_i<=0;
                        take<=nwords(0,count-index-10'(take));state<=PREP;
                    end
                end
                WAIT_WRITE:if(got_valid)begin
                    response<='{valid:1'b1,status:8'd0,opcode:saved.opcode,txn:saved.txn,data:bulk?32'(count):saved.arg2};state<=IDLE;
                end
                WAIT_READ:if(got_valid)begin read_hold<=got_data[255:0];unpack_i<=0;state<=UNPACK;end
                UNPACK:begin
                    if(bulk)reply_mem[{saved.bulk_slot,9'(read_index+10'(unpack_i))}]<=read_hold[32*(int'(read_lane)+int'(unpack_i))+:32];
                    else word_result<=read_hold[32*int'(read_lane)+:32];
                    if(unpack_i+1==read_take) begin
                        if(read_index+10'(read_take)==count)begin
                            response<='{valid:1'b1,status:8'd0,opcode:saved.opcode,txn:saved.txn,
                                data:bulk?32'(count):read_hold[32*int'(read_lane)+:32]};state<=IDLE;
                        end else begin
                            read_index<=read_index+10'(read_take);read_lane<=0;
                            read_take<=nwords(0,count-read_index-10'(read_take));state<=WAIT_READ;
                        end
                    end else unpack_i<=unpack_i+1'b1;
                end
                default:state<=IDLE;
            endcase
        end
    end
`ifndef SYNTHESIS
    always @(posedge ddr_clk) if(ddr_rst_n)begin
        assert(!(rsp_valid && !rsp_ready)) else $fatal(1,"host response capacity");
        assert(!(app_rd_data_valid && tag_empty)) else $fatal(1,"unexpected host response");
    end
`endif
endmodule
