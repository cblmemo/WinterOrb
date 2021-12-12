`include "header.v"

/*
 * module ReorderBuffer
 * --------------------------------------------------
 * This module inplements ReorderBuffer in tomasulo's
 * algorithm. By maintaining a circular queue, this
 * module commit all instruction in order to avoid
 * data hazard.
 */

module ReorderBuffer (
    input  wire                    clk,
    input  wire                    rst,

    output wire                    full_out,
    output reg                     rollback_out,

    // Fetcher
    output reg  [`WORD_RANGE]      fet_rollback_pc_out,

    // Decoder
    input  wire                    dec_issue_in,
    input  wire [`WORD_RANGE]      dec_predict_pc_in,
    input  wire [`WORD_RANGE]      dec_inst_in,
    input  wire [`REG_INDEX_RANGE] dec_rd_in,
    input  wire [`ROB_TAG_RANGE]   dec_Qj_in,
    input  wire [`ROB_TAG_RANGE]   dec_Qk_in,
    output wire [`ROB_TAG_RANGE]   dec_next_tag_out,
    output wire                    dec_Vj_ready_out,
    output wire                    dec_Vk_ready_out,
    output wire [`WORD_RANGE]      dec_Vj_out,
    output wire [`WORD_RANGE]      dec_Vk_out,

    // ArithmeticLogicUnit
    input  wire [`WORD_RANGE]      alu_new_pc_in,

    // BroadCast (ArithmeticLogicUnit && LoadStoreBuffer)
    input  wire                    alu_broadcast_signal_in,
    input  wire [`WORD_RANGE]      alu_result_in,
    input  wire [`ROB_TAG_RANGE]   alu_dest_tag_in,
    input  wire                    lsb_broadcast_signal_in,
    input  wire [`WORD_RANGE]      lsb_result_in,
    input  wire [`ROB_TAG_RANGE]   lsb_dest_tag_in,

    // RegisterFile && LoadStoreBuffer
    output reg                     commit_signal_out,
    output reg                     commit_lsb_signal_out,
    output reg  [`ROB_TAG_RANGE]   commit_tag_out,
    output reg  [`WORD_RANGE]      commit_data_out,
    output reg  [`REG_INDEX_RANGE] commit_target_out
);

    integer i;

    // index of head doesn't store any data, index of tail store data
    // head == tail -> empty
    // head == tail.next -> full
    reg [`ROB_TAG_RANGE] head, tail;
    wire [`ROB_TAG_RANGE] head_next, tail_next;
    reg ready [`ROB_RANGE];
    reg [`WORD_RANGE] inst [`ROB_RANGE];
    reg [`WORD_RANGE] data [`ROB_RANGE];
    reg [`REG_INDEX_RANGE] dest [`ROB_RANGE];
    reg [`WORD_RANGE] predict_pc [`ROB_RANGE];
    reg [`WORD_RANGE] new_pc [`ROB_RANGE];

    assign dec_Vj_ready_out = ready[dec_Qj_in];
    assign dec_Vk_ready_out = ready[dec_Qk_in];
    assign dec_Vj_out       = data[dec_Qj_in];
    assign dec_Vk_out       = data[dec_Qk_in];

    assign head_next = head == `ROB_CAPACITY - 1 ? 1 : head + 1;
    assign tail_next = tail == `ROB_CAPACITY - 1 ? 1 : tail + 1;
    assign full_out  = head == tail_next;
    assign dec_next_tag_out = (head != tail_next) ? tail_next : `NULL_TAG;

    always @(posedge clk) begin
        rollback_out <= `FALSE;
        commit_signal_out <= `FALSE;
        commit_lsb_signal_out <= `FALSE;
        if (rst) begin
            tail <= 1;
            head <= 1;
            for (i = 0; i < `ROB_CAPACITY; i = i + 1) begin
                ready[i] <= `FALSE;
                inst[i] <= `ZERO_WORD;
                data[i] <= `ZERO_WORD;
                dest[i] <= `ZERO_REG_INDEX;
                predict_pc[i] <= `ZERO_WORD;
            end
        end else begin
            if (dec_issue_in) begin
                // add new entry
                ready[tail_next] <= `FALSE;
                inst[tail_next] <= dec_inst_in;
                data[tail_next] <= `ZERO_WORD;
                dest[tail_next] <= dec_rd_in;
                predict_pc[tail_next] <= dec_predict_pc_in;
                tail <= tail_next;
            end
            // update data by snoopy on cdb (i.e., alu && lsb)
            if (alu_broadcast_signal_in) begin
                data[alu_dest_tag_in] <= alu_result_in;
                ready[alu_dest_tag_in] <= `TRUE;
                new_pc[alu_dest_tag_in] <= alu_new_pc_in;
            end
            if (lsb_broadcast_signal_in) begin
                data[lsb_dest_tag_in] <= lsb_result_in;
                ready[lsb_dest_tag_in] <= `TRUE;
            end
            // commit when not empty
            // store will automatically committed when it reach rob head
            if (head != tail && (ready[head_next] || inst[head_next][6:0] == `STORE_OPCODE)) begin
                ready[head_next] <= `FALSE;
                commit_signal_out <= `TRUE;
                commit_lsb_signal_out <= inst[head_next][6:0] == `STORE_OPCODE || inst[head_next][6:0] == `LOAD_OPCODE;
                commit_tag_out <= head_next;
                // TODO broadcast rob as well
                commit_data_out <= data[head_next];
                commit_target_out <= dest[head_next];
                head <= head_next;
                if (inst[head_next][6:0] == `JALR_OPCODE  || 
                    inst[head_next][6:0] == `AUIPC_OPCODE ||
                    inst[head_next][6:0] == `BRANCH_OPCODE) begin
                    if (new_pc[head_next] != predict_pc[head_next]) begin
                        // rollback:
                        // (1) reset pc
                        // (2) execute all committed instruction in lsb
                        // (3) keep register value in RegisterFile
                        // (4) rst all other modules
                        rollback_out <= `TRUE;
                        fet_rollback_pc_out <= new_pc[head_next];
                        tail <= 1;
                        head <= 1;
                        for (i = 0; i < `ROB_CAPACITY; i = i + 1) begin
                            ready[i] <= `FALSE;
                            inst[i] <= `ZERO_WORD;
                            data[i] <= `ZERO_WORD;
                            dest[i] <= `ZERO_REG_INDEX;
                            predict_pc[i] <= `ZERO_WORD;
                        end
                    end
                end
            end
        end
    end

endmodule