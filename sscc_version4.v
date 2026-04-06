`timescale 1ns/1ps

// ============================================================
// VERSION 4 FIXED:
// - reauth_req is a pulse, not a stuck level
// - low_trust uses hysteresis
// - REAUTH has a timeout escape path
// - trust score recovers faster than it decays
// ============================================================

// ------------------------------------------------------------
// 1) PUF Core
// ------------------------------------------------------------
module puf_core (
    input clk,
    input rst,
    input [7:0] challenge,
    input [7:0] temp,
    output reg [7:0] response
);
    parameter [7:0] SECRET_KEY = 8'h5A;

    wire [7:0] temp_effect;
    assign temp_effect = {temp[3:0], temp[7:4]} ^ 8'h3C;

    always @(posedge clk or posedge rst) begin
        if (rst)
            response <= 8'h00;
        else
            response <= challenge ^ SECRET_KEY ^ temp_effect;
    end
endmodule

// ------------------------------------------------------------
// 2) PUF Stabilizer
// ------------------------------------------------------------
module puf_stabilizer (
    input clk,
    input rst,
    input [7:0] raw_resp,
    input [7:0] temp,
    output reg [7:0] stable_resp,
    output reg stable_ok
);
    reg [7:0] prev_stable;
    wire [7:0] temp_effect;
    assign temp_effect = {temp[3:0], temp[7:4]} ^ 8'h3C;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            stable_resp <= 8'h00;
            prev_stable  <= 8'h00;
            stable_ok    <= 1'b0;
        end else begin
            stable_resp <= raw_resp ^ temp_effect;
            stable_ok   <= ((raw_resp ^ temp_effect) == prev_stable);
            prev_stable <= (raw_resp ^ temp_effect);
        end
    end
endmodule

// ------------------------------------------------------------
// 3) Authentication Controller
// ------------------------------------------------------------
module auth_controller (
    input clk,
    input rst,
    input [7:0] challenge,
    input [7:0] stable_resp,
    input stable_ok,
    output reg auth_ok
);
    parameter [7:0] AUTH_KEY = 8'h5A;

    wire [7:0] expected_resp;
    assign expected_resp = challenge ^ AUTH_KEY;

    always @(posedge clk or posedge rst) begin
        if (rst)
            auth_ok <= 1'b0;
        else if (stable_ok && (stable_resp == expected_resp))
            auth_ok <= 1'b1;
        else
            auth_ok <= 1'b0;
    end
endmodule

// ------------------------------------------------------------
// 4) Link Monitor
// ------------------------------------------------------------
module link_monitor (
    input clk,
    input rst,
    input error,
    output reg fault
);
    reg [2:0] error_count;
    parameter [2:0] THRESHOLD = 3'd2;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            error_count <= 3'd0;
            fault <= 1'b0;
        end else begin
            if (error) begin
                if (error_count != 3'd7)
                    error_count <= error_count + 1'b1;
            end else begin
                if (error_count != 3'd0)
                    error_count <= error_count - 1'b1;
            end

            fault <= (error_count >= THRESHOLD);
        end
    end
endmodule

// ------------------------------------------------------------
// 5) Trust Manager
//    - trust_score rises on good behavior
//    - trust_score decays slowly on bad behavior
//    - low_trust uses hysteresis
//    - reauth_req is a one-cycle pulse on severe events
// ------------------------------------------------------------
module trust_manager (
    input clk,
    input rst,
    input stable_ok,
    input auth_ok,
    input fault,
    input [7:0] temp,
    output reg [7:0] trust_score,
    output reg [7:0] temp_drift,
    output reg low_trust,
    output reg reauth_req
);
    reg [7:0] temp_prev;
    reg [7:0] score_next;
    reg [7:0] drift_abs;
    reg severe_now;
    reg severe_prev;

    always @(*) begin
        if (temp >= temp_prev)
            drift_abs = temp - temp_prev;
        else
            drift_abs = temp_prev - temp;
    end

    always @(*) begin
        severe_now = (drift_abs >= 8'd32) || (!auth_ok && !stable_ok) || (fault && (trust_score <= 8'd3));

        score_next = trust_score;

        // Fast recovery when the system is healthy
        if (stable_ok && auth_ok && !fault && (drift_abs <= 8'd8)) begin
            if (score_next < 8'd15)
                score_next = score_next + 8'd2;
        end
        // Mild decay if conditions are not ideal
        else if (drift_abs >= 8'd16 || !auth_ok || fault) begin
            if (score_next > 8'd1)
                score_next = score_next - 8'd1;
            else
                score_next = 8'd0;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            trust_score <= 8'd8;
            temp_prev   <= 8'd0;
            temp_drift  <= 8'd0;
            low_trust   <= 1'b0;
            reauth_req  <= 1'b0;
            severe_prev <= 1'b0;
        end else begin
            temp_prev  <= temp;
            temp_drift <= drift_abs;
            trust_score <= score_next;

            // Hysteresis:
            // assert low_trust when score is low
            // clear it only when score recovers enough
            if (low_trust) begin
                if (score_next >= 8'd6)
                    low_trust <= 1'b0;
            end else begin
                if (score_next <= 8'd3)
                    low_trust <= 1'b1;
            end

            // One-cycle re-auth pulse on the rising edge of a severe event
            reauth_req  <= severe_now & ~severe_prev;
            severe_prev <= severe_now;
        end
    end
endmodule

// ------------------------------------------------------------
// 6) Healing FSM
//    NORMAL -> RETRY -> REROUTE -> REAUTH -> ISOLATE
// ------------------------------------------------------------
module healing_fsm (
    input clk,
    input rst,
    input auth_ok,
    input fault,
    input low_trust,
    input reauth_req,
    input [7:0] trust_score,
    output reg [2:0] heal_state,
    output reg [1:0] path_sel
);
    localparam NORMAL  = 3'd0;
    localparam RETRY   = 3'd1;
    localparam REROUTE = 3'd2;
    localparam REAUTH  = 3'd3;
    localparam ISOLATE = 3'd4;

    reg [1:0] step_count;
    reg [2:0] reauth_timer;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            heal_state   <= NORMAL;
            path_sel     <= 2'd0;
            step_count   <= 2'd0;
            reauth_timer <= 3'd0;
        end else begin
            case (heal_state)
                NORMAL: begin
                    path_sel     <= 2'd0;
                    step_count   <= 2'd0;
                    reauth_timer <= 3'd0;

                    // Only a real severe pulse or lost auth should enter REAUTH
                    // Low trust sends the controller to RETRY, not a REAUTH loop.
                    if (reauth_req || !auth_ok) begin
                        heal_state <= REAUTH;
                        path_sel   <= 2'd2;
                    end else if (fault || low_trust) begin
                        heal_state <= RETRY;
                    end
                end

                RETRY: begin
                    path_sel <= 2'd0;

                    if (!fault && auth_ok && trust_score >= 8'd5) begin
                        heal_state <= NORMAL;
                        step_count <= 2'd0;
                    end else if (step_count == 2'd2) begin
                        heal_state <= REROUTE;
                        step_count <= 2'd0;
                        path_sel   <= 2'd1;
                    end else begin
                        step_count <= step_count + 1'b1;
                    end
                end

                REROUTE: begin
                    path_sel <= 2'd1;

                    if (!fault && auth_ok && trust_score >= 8'd5) begin
                        heal_state <= NORMAL;
                        step_count <= 2'd0;
                        path_sel   <= 2'd0;
                    end else if (step_count == 2'd2) begin
                        heal_state <= REAUTH;
                        step_count <= 2'd0;
                        path_sel   <= 2'd2;
                    end else begin
                        step_count <= step_count + 1'b1;
                    end
                end

                REAUTH: begin
                    path_sel <= 2'd2;

                    // Recover if trust returns and fault clears
                    if (auth_ok && !fault && !low_trust && trust_score >= 8'd5) begin
                        heal_state   <= NORMAL;
                        reauth_timer <= 3'd0;
                        step_count   <= 2'd0;
                        path_sel     <= 2'd0;
                    end else if (reauth_timer == 3'd5) begin
                        // Escape route: do not get stuck in REAUTH
                        if (!fault)
                            heal_state <= RETRY;
                        else
                            heal_state <= ISOLATE;

                        reauth_timer <= 3'd0;
                        step_count   <= 2'd0;
                    end else begin
                        reauth_timer <= reauth_timer + 1'b1;
                    end
                end

                ISOLATE: begin
                    path_sel <= 2'd3;

                    if (auth_ok && !fault && trust_score >= 8'd5) begin
                        heal_state   <= NORMAL;
                        reauth_timer <= 3'd0;
                        step_count   <= 2'd0;
                        path_sel     <= 2'd0;
                    end
                end

                default: begin
                    heal_state   <= NORMAL;
                    path_sel     <= 2'd0;
                    step_count   <= 2'd0;
                    reauth_timer <= 3'd0;
                end
            endcase
        end
    end
endmodule

// ------------------------------------------------------------
// 7) Backup Path Mux
//    00 = primary, 01 = backup, 10 = hold/reauth, 11 = isolate
// ------------------------------------------------------------
module backup_path_mux (
    input [1:0] path_sel,
    input auth_ok,
    input [7:0] primary_data,
    input [7:0] backup_data,
    output reg [7:0] data_out
);
    always @(*) begin
        if (!auth_ok) begin
            data_out = 8'h00;
        end else begin
            case (path_sel)
                2'd0: data_out = primary_data;
                2'd1: data_out = backup_data;
                2'd2: data_out = 8'h00;
                2'd3: data_out = 8'h00;
                default: data_out = 8'h00;
            endcase
        end
    end
endmodule

// ------------------------------------------------------------
// 8) Top Module
// ------------------------------------------------------------
module sscc_top (
    input clk,
    input rst,
    input [7:0] challenge,
    input [7:0] temp,
    input link_error,
    input [7:0] data_in,
    input [7:0] backup_data,
    output [7:0] data_out,
    output fault_flag,
    output auth_ok,
    output stable_ok,
    output reauth_req,
    output low_trust,
    output [7:0] trust_score,
    output [7:0] temp_drift,
    output [2:0] heal_state,
    output [1:0] path_sel,
    output [7:0] puf_raw,
    output [7:0] puf_stable
);
    wire [7:0] stable_resp;
    wire [7:0] trust_score_w;
    wire [7:0] temp_drift_w;
    wire low_trust_w;
    wire reauth_req_w;

    puf_core u1 (
        .clk(clk),
        .rst(rst),
        .challenge(challenge),
        .temp(temp),
        .response(puf_raw)
    );

    puf_stabilizer u2 (
        .clk(clk),
        .rst(rst),
        .raw_resp(puf_raw),
        .temp(temp),
        .stable_resp(stable_resp),
        .stable_ok(stable_ok)
    );

    auth_controller u3 (
        .clk(clk),
        .rst(rst),
        .challenge(challenge),
        .stable_resp(stable_resp),
        .stable_ok(stable_ok),
        .auth_ok(auth_ok)
    );

    link_monitor u4 (
        .clk(clk),
        .rst(rst),
        .error(link_error),
        .fault(fault_flag)
    );

    trust_manager u5 (
        .clk(clk),
        .rst(rst),
        .stable_ok(stable_ok),
        .auth_ok(auth_ok),
        .fault(fault_flag),
        .temp(temp),
        .trust_score(trust_score_w),
        .temp_drift(temp_drift_w),
        .low_trust(low_trust_w),
        .reauth_req(reauth_req_w)
    );

    healing_fsm u6 (
        .clk(clk),
        .rst(rst),
        .auth_ok(auth_ok),
        .fault(fault_flag),
        .low_trust(low_trust_w),
        .reauth_req(reauth_req_w),
        .trust_score(trust_score_w),
        .heal_state(heal_state),
        .path_sel(path_sel)
    );

    backup_path_mux u7 (
        .path_sel(path_sel),
        .auth_ok(auth_ok),
        .primary_data(data_in),
        .backup_data(backup_data),
        .data_out(data_out)
    );

    assign trust_score = trust_score_w;
    assign temp_drift  = temp_drift_w;
    assign reauth_req  = reauth_req_w;
    assign low_trust   = low_trust_w;
    assign puf_stable  = stable_resp;
endmodule

// ------------------------------------------------------------
// 9) Testbench
// ------------------------------------------------------------
module tb_sscc;
    reg clk;
    reg rst;
    reg [7:0] challenge;
    reg [7:0] temp;
    reg link_error;
    reg [7:0] data_in;
    reg [7:0] backup_data;

    wire [7:0] data_out;
    wire fault_flag;
    wire auth_ok;
    wire stable_ok;
    wire reauth_req;
    wire low_trust;
    wire [7:0] trust_score;
    wire [7:0] temp_drift;
    wire [2:0] heal_state;
    wire [1:0] path_sel;
    wire [7:0] puf_raw;
    wire [7:0] puf_stable;

    sscc_top dut (
        .clk(clk),
        .rst(rst),
        .challenge(challenge),
        .temp(temp),
        .link_error(link_error),
        .data_in(data_in),
        .backup_data(backup_data),
        .data_out(data_out),
        .fault_flag(fault_flag),
        .auth_ok(auth_ok),
        .stable_ok(stable_ok),
        .reauth_req(reauth_req),
        .low_trust(low_trust),
        .trust_score(trust_score),
        .temp_drift(temp_drift),
        .heal_state(heal_state),
        .path_sel(path_sel),
        .puf_raw(puf_raw),
        .puf_stable(puf_stable)
    );

    always #5 clk = ~clk;

    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, tb_sscc);

        clk = 1'b0;
        rst = 1'b1;
        challenge = 8'hA5;
        temp = 8'h12;
        link_error = 1'b0;
        data_in = 8'h55;
        backup_data = 8'hAA;

        #20 rst = 1'b0;

        // normal operation
        #40;

        // small temperature change
        temp = 8'h18;
        #40;

        // fault burst 1
        link_error = 1'b1;
        #40;
        link_error = 1'b0;

        // larger temperature change
        temp = 8'h7E;
        #60;

        // fault burst 2
        link_error = 1'b1;
        #40;
        link_error = 1'b0;

        // recovery window
        #100;
        $finish;
    end

    initial begin
        $monitor("%0t clk=%b rst=%b temp=%h ch=%h auth_ok=%b stable_ok=%b fault=%b reauth_req=%b low_trust=%b trust=%h temp_drift=%h heal_state=%b path_sel=%b data_out=%h puf_raw=%h puf_stable=%h",
                 $time, clk, rst, temp, challenge, auth_ok, stable_ok, fault_flag, reauth_req, low_trust, trust_score, temp_drift, heal_state, path_sel, data_out, puf_raw, puf_stable);
    end
endmodule