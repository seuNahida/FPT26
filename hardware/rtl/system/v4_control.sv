`timescale 1ns/1ps
// ATN1 framing, new explicitly-discovered v4 commands. Control CDC uses FIFOs.
// 05 CAPS -> 'AT45'; 06 BASE(index,address); 07 JOB(qlen|qpos<<16,
// kvlen|groups<<16|sub<<24); 10 START. Old CONFIG(03) is deliberately rejected.
module v4_control (
    input logic clk, rst_n, host_clk, host_rst_n, ready,
    input fpt_pkg::command_t command,
    output logic command_ready,
    output fpt_pkg::response_t response,
    output fpt_pkg::status_t host_status,
    output logic start,
    output attn_pkg::job_t job,
    output logic [31:0] bases [4],
    input logic busy, done, fault,
    input logic [255:0] perf,
    input logic [127:0] memory_perf,
    output logic diagnostic_request,
    output logic [4:0] diagnostic_id,
    input logic diagnostic_ready, diagnostic_valid,
    input logic [31:0] diagnostic_data,
    output logic diagnostic_pop,
    input logic [31:0] core_diagnostic [6],
    output logic [9:0] tuning,
    input logic [31:0] outputs
);
    import fpt_pkg::*;
    command_t cmd;
    response_t rsp;
    status_t status;
    logic valid, pop, rsp_ready, rsp_valid, done_sticky, last_start_valid;
    logic [15:0] last_start_txn;
    logic [63:0] cycles;
    logic [31:0] memory_base[4], memory_final[4], memory_delta[4];
    localparam int RW=$bits(response_t)+$bits(status_t);
    logic [RW-1:0] returned;
    logic returned_valid;
    v4_cdc_fifo #(.WIDTH($bits(command_t)),.DEPTH(16)) commands(
        .s_clk(host_clk),.s_rst_n(host_rst_n),.m_clk(clk),.m_rst_n(rst_n),
        .s_data(command),.s_valid(command.valid),.s_ready(command_ready),.s_depth(),
        .m_data(cmd),.m_valid(valid),.m_ready(pop));
    v4_cdc_fifo #(.WIDTH(RW),.DEPTH(16)) replies(
        .s_clk(clk),.s_rst_n(rst_n),.m_clk(host_clk),.m_rst_n(host_rst_n),
        .s_data({rsp,status}),.s_valid(rsp_valid),.s_ready(rsp_ready),.s_depth(),
        .m_data(returned),.m_valid(returned_valid),.m_ready(1'b1));
    always_ff @(posedge host_clk) begin
        if (!host_rst_n) begin response<='0; host_status<='0; end
        else begin
            response.valid<=0;
            if (returned_valid) begin {response,host_status}<=returned; response.valid<=1; end
        end
    end
    assign status = '{ready:ready && !busy && !start, busy:busy || start, done:done_sticky,
        error:fault, core_error:fault, pods:4'hf, cycles:cycles, outputs:64'(outputs)};
    logic [3:0] config_settle;
    logic diagnostic_wait;
    logic decoded,diagnostic_command,start_command;
    logic job_arguments_ok,base_arguments_ok,tuning_arguments_ok;
    logic [63:0] value_q;
    // BRAM command data -> validation -> commit are separate timing stages.
    always_ff @(posedge clk)begin
        if(!rst_n)begin decoded<=0;diagnostic_command<=0;start_command<=0;end
        else begin
            if(pop)decoded<=0;
            else if(valid && !decoded)begin
                decoded<=1;
                diagnostic_command<=cmd.opcode==8'h21 && cmd.arg0>=14 && cmd.arg0<=30 && !cmd.arg1[0];
                start_command<=cmd.opcode==8'h10;
                job_arguments_ok<=cmd.arg0[15:0]!=0 && cmd.arg1[15:0]!=0 && cmd.arg1[15:0]<=8192 &&
                    17'(cmd.arg0[15:0])+17'(cmd.arg0[31:16])<=17'(cmd.arg1[15:0]) &&
                    cmd.arg1[23:16]>=1 && cmd.arg1[23:16]<=8 && cmd.arg1[31:24]<=4 && cmd.arg2[31:16]==0 &&
                    (cmd.arg2==0 || (cmd.arg2>=cmd.arg1[15:0] && cmd.arg2<=8192));
                base_arguments_ok<=cmd.arg0<=3 && cmd.arg1[5:0]==0 && cmd.arg1<32'h20000000;
                tuning_arguments_ok<=cmd.arg0<=1023 && cmd.arg0[2:0]<=4 && cmd.arg0[8:3]<=32;
                value_q<=value;
            end
        end
    end
    assign pop = valid && decoded && rsp_ready && !rsp_valid && !start && !diagnostic_wait &&
                 (!diagnostic_command || diagnostic_ready) && (!start_command || config_settle==0);
    assign diagnostic_request = pop && diagnostic_command;
    assign diagnostic_id = 5'(cmd.arg0-14);
    assign diagnostic_pop = diagnostic_wait && diagnostic_valid && rsp_ready && !rsp_valid;
    logic [63:0] value;
    logic [19:0] qrows,kvrows;
    logic [31:0] qbytes,kvbytes;
    logic [32:0] ends[4];
    logic [3:0] bad_bounds;
    logic [5:0] bad_overlap;
    assign qbytes={2'd0,qrows,10'd0};
    assign kvbytes={4'd0,kvrows,8'd0};
    always_ff @(posedge clk) begin
        qrows<=20'(job.q_len)*20'(job.groups);
        kvrows<=20'(job.kv_stride==0 ? job.kv_len:job.kv_stride)*20'(job.groups);
        for(int i=0;i<4;i++)begin
            ends[i]<={1'b0,bases[i]}+(i==0 || i==3 ? {1'b0,qbytes}:{1'b0,kvbytes});
            bad_bounds[i]<=ends[i]>33'h020000000;
        end
        bad_overlap[0]<= {1'b0,bases[0]}<ends[1] && {1'b0,bases[1]}<ends[0];
        bad_overlap[1]<= {1'b0,bases[0]}<ends[2] && {1'b0,bases[2]}<ends[0];
        bad_overlap[2]<= {1'b0,bases[0]}<ends[3] && {1'b0,bases[3]}<ends[0];
        bad_overlap[3]<= {1'b0,bases[1]}<ends[2] && {1'b0,bases[2]}<ends[1];
        bad_overlap[4]<= {1'b0,bases[1]}<ends[3] && {1'b0,bases[3]}<ends[1];
        bad_overlap[5]<= {1'b0,bases[2]}<ends[3] && {1'b0,bases[3]}<ends[2];
        ranges_ok<=!(|bad_bounds || |bad_overlap);
    end
    logic ranges_ok;
    always_comb begin
        value=0;
        if(cmd.arg0 < 8) value=64'(perf[cmd.arg0*32+:32]);
        else if(cmd.arg0 == 8) value=cycles;
        else if(cmd.arg0 == 9) value=64'(outputs);
        else if(cmd.arg0<14) value=64'(busy ? memory_delta[cmd.arg0-10] : memory_final[cmd.arg0-10]);
        else if(cmd.arg0>=31 && cmd.arg0<37) value=64'(core_diagnostic[cmd.arg0-31]);
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            diagnostic_wait<=0; tuning<=0; config_settle<=6; start<=0; rsp_valid<=0; rsp<='0; done_sticky<=0; cycles<=0; last_start_valid<=0; last_start_txn<=0;
            for(int i=0;i<4;i++)begin memory_base[i]<=0;memory_final[i]<=0;memory_delta[i]<=0;end
            job<='{sub:3'd4,groups:4'd1,q_len:16'd1,q_pos:16'd0,kv_len:16'd1,kv_stride:16'd0};
            bases[0]<=0; bases[1]<=32'h02000000; bases[2]<=32'h04000000; bases[3]<=32'h06000000;
        end else begin
            start<=0;
            if(config_settle!=0) config_settle<=config_settle-1'b1;
            if(rsp_ready) rsp_valid<=0;
            if(diagnostic_pop) begin
                rsp_valid<=1; rsp.valid<=1; rsp.data<=diagnostic_data;
                diagnostic_wait<=0;
            end
            if(busy) cycles<=cycles+1'b1;
            for(int i=0;i<4;i++)memory_delta[i]<=memory_perf[i*32+:32]-memory_base[i];
            if(start) for(int i=0;i<4;i++)memory_base[i]<=memory_perf[i*32+:32];
            if(done) begin
                done_sticky<=1;
                for(int i=0;i<4;i++)memory_final[i]<=memory_delta[i];
            end
            if(pop) begin
                rsp_valid<=!diagnostic_command;
                if(diagnostic_command)diagnostic_wait<=1;
                rsp.valid<=1; rsp.opcode<=cmd.opcode; rsp.txn<=cmd.txn; rsp.status<=0;
                rsp.data<={27'd0,fault,done_sticky,busy,ready,1'b1};
                case(cmd.opcode)
                    8'h00:rsp.data<=32'h504f4e47;
                    8'h01:begin end
                    8'h05:rsp.data<=32'h41543435;
                    // Compatible extension: revision/features and idle-only tuning.
                    // burst_log2[2:0], credit[8:3] (0=32), split_disable[9].
                    8'h09:rsp.data<=32'h41353631; // A561
                    8'h08:if(busy) rsp.status<=1;
                        else if(!tuning_arguments_ok) rsp.status<=2;
                        else begin tuning<=cmd.arg0[9:0];config_settle<=15;end
                    8'h02:if(busy) rsp.status<=1; else done_sticky<=0;
                    8'h06:if(busy) rsp.status<=1;
                        else if(!base_arguments_ok) rsp.status<=2;
                        else begin bases[cmd.arg0[1:0]]<=cmd.arg1;config_settle<=6;end
                    8'h07:if(busy) rsp.status<=1;
                        else if(!job_arguments_ok) rsp.status<=2;
                        else begin config_settle<=6;job<='{sub:cmd.arg1[26:24],groups:cmd.arg1[19:16],q_len:cmd.arg0[15:0],
                            q_pos:cmd.arg0[31:16],kv_len:cmd.arg1[15:0],kv_stride:cmd.arg2[15:0]};end
                    8'h10:if(last_start_valid && cmd.txn==last_start_txn) begin end // replay ACK, never restart
                        else if(busy || !ready || fault) rsp.status<=1;
                        else if(!ranges_ok) rsp.status<=2;
                        else begin start<=1; done_sticky<=0; cycles<=0; last_start_valid<=1; last_start_txn<=cmd.txn; end
                    8'h21:if(cmd.arg0>36) rsp.status<=2; else rsp.data<=cmd.arg1[0]?value_q[63:32]:value_q[31:0];
                    default:rsp.status<=3;
                endcase
            end
        end
    end
endmodule
