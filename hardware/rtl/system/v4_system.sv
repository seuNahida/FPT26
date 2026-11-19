`timescale 1ns/1ps
module v4_system (
    input logic clk, rst_n, host_clk, host_rst_n, ddr_clk, ddr_rst_n,
    input fpt_pkg::command_t command,
    output logic command_ready,
    output fpt_pkg::response_t response,
    input fpt_pkg::bulk_write_t bulk_write,
    input fpt_pkg::bulk_read_t bulk_read,
    output logic [31:0] bulk_read_data,
    output fpt_pkg::status_t host_status,
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
    output logic failed
);
    import fpt_pkg::*;
    logic start, busy, done, engine_fault, bus_fault;
    logic [31:0] bases[4], outputs;
    attn_pkg::job_t job;
    logic [255:0] perf;
    logic [9:0] tuning;
    logic [31:0] core_diagnostic [6];
    logic diagnostic_request,diagnostic_ready,diagnostic_valid,diagnostic_pop;
    logic [4:0] diagnostic_id;
    logic [31:0] diagnostic_data;
    (* ASYNC_REG="TRUE" *) logic [2:0] burst_meta, burst_sync;
    // Tuning changes only while idle and START is delayed 15 core cycles.
    always_ff @(posedge ddr_clk) begin
        if (!ddr_rst_n) begin burst_meta<=0;burst_sync<=0;end
        else begin burst_meta<=tuning[2:0];burst_sync<=burst_meta;end
    end
    command_t ctrl_command, mem_command;
    response_t ctrl_response, mem_response;
    logic ctrl_ready, mem_ready;
    // Serialize application responses: retain each command until its one
    // response has entered the packet stack. UDP payload slots still queue.
    logic pending, memory_cmd, queue_empty, queue_full, issue;
    logic [4:0] queued;
    command_t head;
    // The packet parser registers its request pulse one cycle AFTER observing
    // ready. Keep two spare entries; never discard that already-issued pulse.
    assign command_ready=queued<14;
    v4_fifo #(.WIDTH($bits(command_t)),.DEPTH(16)) ingress(
        .clk(host_clk),.rst_n(host_rst_n),.push(command.valid),.din(command),.full(queue_full),
        .pop(issue),.dout(head),.empty(queue_empty));
    assign memory_cmd=is_memory_command(head.opcode);
    assign issue=!queue_empty && !pending && (memory_cmd ? mem_ready:ctrl_ready);
    always_comb begin
        ctrl_command=head; mem_command=head;
        ctrl_command.valid=issue && !memory_cmd;
        mem_command.valid=issue && memory_cmd;
        response=mem_response.valid ? mem_response:ctrl_response;
    end
    always_ff @(posedge host_clk) begin
        if(!host_rst_n) begin pending<=0;queued<=0;end
        else begin
            queued<=queued+command.valid-issue;
            if(issue) pending<=1;
            if(response.valid) pending<=0;
        end
    end
    (* ASYNC_REG="TRUE" *) logic [1:0] ready_sync, fault_sync;
    always_ff @(posedge clk) begin
        if(!rst_n) begin ready_sync<=0; fault_sync<=0; end
        else begin ready_sync<={ready_sync[0],ddr_rst_n}; fault_sync<={fault_sync[0],bus_fault}; end
    end
    assign failed=engine_fault || fault_sync[1];
    v4_control controller(.clk,.rst_n,.host_clk,.host_rst_n,.ready(ready_sync[1]),
        .command(ctrl_command),.command_ready(ctrl_ready),.response(ctrl_response),.host_status,
        .start,.job,.bases,.busy,.done,.fault(failed),.perf,.memory_perf,.core_diagnostic,.tuning,.outputs,
        .diagnostic_request,.diagnostic_id,.diagnostic_ready,.diagnostic_valid,.diagnostic_data,.diagnostic_pop);
    logic [2:0] req_valid,req_ready,rsp_valid,rsp_ready;
    logic [31:0] req_addr[3];
    logic [511:0] rsp_data[3];
    logic out_valid,out_ready;
    logic [543:0] out_data;
    logic [31:0] written_gray;
    logic [31:0] bus_counters[4];
    logic [31:0] bus_gray[4];
    (* ASYNC_REG="TRUE" *) logic [31:0] bus_meta[4], bus_sync[4];
    logic [127:0] memory_perf;
    logic [31:0] bus_diagnostic [17];
    v4_ddr_diagnostics ddr_observe(.clk,.rst_n,.ddr_clk,.ddr_rst_n,.start,.done,
        .counters(bus_diagnostic),.request(diagnostic_request),.id(diagnostic_id),
        .ready(diagnostic_ready),.valid(diagnostic_valid),.data(diagnostic_data),.pop(diagnostic_pop));
    always_ff @(posedge ddr_clk) begin
        if(!ddr_rst_n) begin bus_counters[3]<=0;for(int i=0;i<4;i++)bus_gray[i]<=0;end
        else begin
            bus_counters[3]<=bus_counters[3]+1'b1;
            for(int i=0;i<4;i++) bus_gray[i]<=(bus_counters[i]>>1)^bus_counters[i];
        end
    end
    for(genvar c=0;c<4;c++) begin:g_bus_counters
        logic [31:0] count;
        always_ff @(posedge clk) begin
            if(!rst_n) begin bus_meta[c]<=0;bus_sync[c]<=0;end
            else begin bus_meta[c]<=bus_gray[c];bus_sync[c]<=bus_meta[c];end
        end
        always_comb begin
            count[31]=bus_sync[c][31];
            for(int b=30;b>=0;b--)count[b]=count[b+1]^bus_sync[c][b];
        end
        always_ff @(posedge clk) memory_perf[32*c+:32]<=count;
    end
    v4_engine engine(.split_disable(tuning[9]),.credit_limit(tuning[8:3]),.diagnostic(core_diagnostic),.clk,.rst_n,.ddr_clk,.ddr_rst_n,.start,.job,.bases,.busy,.done,.fault(engine_fault),.perf,.outputs,
        .req_valid,.req_ready,.req_addr,.rsp_valid,.rsp_ready,.rsp_data,.out_valid,.out_ready,.out_data,.written_gray);
    logic [28:0] host_addr;
    logic [2:0] host_cmd;
    logic host_en,host_rdy,host_wdf_end,host_wdf_wren,host_wdf_rdy,host_rd_data_end,host_rd_data_valid;
    logic [255:0] host_wdf_data,host_rd_data;
    logic [31:0] host_wdf_mask;
    assign host_rd_data_end=host_rd_data_valid;
    v4_mig_bus bus(.burst_log2(burst_sync),.diagnostic(bus_diagnostic),.clk(ddr_clk),.rst_n(ddr_rst_n),.host_addr,.host_cmd,.host_en,.host_wren(host_wdf_wren),
        .host_wdata(host_wdf_data),.host_mask(host_wdf_mask),.host_rdy,.host_wrdy(host_wdf_rdy),
        .host_rdata(host_rd_data),.host_rvalid(host_rd_data_valid),.req_valid,.req_ready,.req_addr,
        .rsp_valid,.rsp_ready,.rsp_data,.out_valid,.out_ready,.out_data,.written_gray,.fault(bus_fault),
        .app_addr,.app_cmd,.app_en,.app_rdy,.app_wdf_data,.app_wdf_mask,.app_wdf_end,.app_wdf_wren,.app_wdf_rdy,
        .app_rd_data,.app_rd_data_valid,.read_beats(bus_counters[0]),.write_beats(bus_counters[1]),.stall_cycles(bus_counters[2]));
    v4_host_dma host_access(.clk(host_clk),.rst_n(host_rst_n),.ddr_clk,.ddr_rst_n,
        .command(mem_command),.command_ready(mem_ready),.response(mem_response),.bulk_write,.bulk_read,.bulk_read_data,
        .app_addr(host_addr),.app_cmd(host_cmd),.app_en(host_en),.app_rdy(host_rdy),
        .app_wdf_data(host_wdf_data),.app_wdf_mask(host_wdf_mask),.app_wdf_wren(host_wdf_wren),
        .app_wdf_end(host_wdf_end),.app_wdf_rdy(host_wdf_rdy),.app_rd_data(host_rd_data),.app_rd_data_valid(host_rd_data_valid));
endmodule

// Event snapshots remain in the DDR domain. Only one requested word crosses
// each way, avoiding a bank of continuously crossing Gray counters and muxes.
module v4_ddr_diagnostics (
    input logic clk,rst_n,ddr_clk,ddr_rst_n,start,done,
    input logic [31:0] counters[17],
    input logic request,
    input logic [4:0] id,
    output logic ready,valid,
    output logic [31:0] data,
    input logic pop
);
    logic start_toggle,done_toggle;
    (* ASYNC_REG="TRUE" *) logic [1:0] start_sync,done_sync;
    logic start_seen,done_seen,running;
    logic [31:0] baseline[17],frozen[17];
    logic id_valid,id_ready,answer_ready;
    logic [4:0] query;
    logic [31:0] answer;
    always_ff @(posedge clk) begin
        if(!rst_n)begin start_toggle<=0;done_toggle<=0;end
        else begin
            if(start)start_toggle<=~start_toggle;
            if(done)done_toggle<=~done_toggle;
        end
    end
    always_ff @(posedge ddr_clk) begin
        if(!ddr_rst_n)begin
            start_sync<=0;done_sync<=0;start_seen<=0;done_seen<=0;running<=0;
            for(int i=0;i<17;i++)begin baseline[i]<=0;frozen[i]<=0;end
        end else begin
            start_sync<={start_sync[0],start_toggle};done_sync<={done_sync[0],done_toggle};
            if(start_sync[1]!=start_seen)begin
                start_seen<=start_sync[1];running<=1;
                for(int i=0;i<17;i++)baseline[i]<=counters[i];
            end
            if(done_sync[1]!=done_seen)begin
                done_seen<=done_sync[1];running<=0;
                for(int i=0;i<17;i++)frozen[i]<=counters[i]-baseline[i];
            end
        end
    end
    v4_cdc_fifo #(.WIDTH(5),.DEPTH(4)) queries(
        .s_clk(clk),.s_rst_n(rst_n),.m_clk(ddr_clk),.m_rst_n(ddr_rst_n),
        .s_data(id),.s_valid(request),.s_ready(ready),.s_depth(),
        .m_data(query),.m_valid(id_valid),.m_ready(id_ready));
    always_comb begin
        answer=0;
        if(query<17)answer=running ? counters[query]-baseline[query]:frozen[query];
    end
    assign id_ready=answer_ready;
    v4_cdc_fifo #(.WIDTH(32),.DEPTH(4)) answers(
        .s_clk(ddr_clk),.s_rst_n(ddr_rst_n),.m_clk(clk),.m_rst_n(rst_n),
        .s_data(answer),.s_valid(id_valid && answer_ready),.s_ready(answer_ready),.s_depth(),
        .m_data(data),.m_valid(valid),.m_ready(pop));
endmodule
