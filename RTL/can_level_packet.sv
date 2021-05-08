`timescale 1ps/1ps

module can_level_packet #(
    parameter logic        TX_RTR         = 1'b0,
    parameter logic [10:0] TX_ID          = 11'h456,
    parameter logic [15:0] default_c_PTS  = 16'd34,
    parameter logic [15:0] default_c_PBS1 = 16'd5,
    parameter logic [15:0] default_c_PBS2 = 16'd10
) (
    input  wire        rstn,  // set to 1 while working
    input  wire        clk,   // system clock
    
    // CAN TX and RX
    input  wire        can_rx,
    output wire        can_tx,
    
    // user tx packet interface
    input  wire        tx_start,
    input  wire [31:0] tx_data,
    output reg         tx_done,
    output reg         tx_acked,
    
    // user rx packet interface
    output reg         rx_valid,
    output reg  [28:0] rx_id,
    output reg         rx_ide,
    output reg         rx_rtr,
    output reg  [ 3:0] rx_len,
    output reg  [63:0] rx_data,
    input  wire        rx_ack
);


function automatic logic [14:0] crc15(input logic [14:0] crc_val, input logic in_bit);
    return {crc_val[13:0], 1'b0} ^ (crc_val[14] ^ in_bit ? 15'h4599 : 15'h0);
endfunction

wire bit_req;
wire bit_rx;
reg  bit_tx;

can_level_bit #(
    .default_c_PTS   ( default_c_PTS    ),
    .default_c_PBS1  ( default_c_PBS1   ),
    .default_c_PBS2  ( default_c_PBS2   )
) can_level_bit_i (
    .rstn            ( rstn             ),
    .clk             ( clk              ),
    .can_rx          ( can_rx           ),
    .can_tx          ( can_tx           ),
    .req             ( bit_req          ),
    .rbit            ( bit_rx           ),
    .tbit            ( bit_tx           )
);


reg [ 7:0] rx_history;
reg [ 3:0] tx_history;
wire       rx_end = rx_history=='1;
wire       rx_err = rx_history[5:0]=='0;
wire       rx_ben = rx_history[4:0]!='0 && rx_history[4:0]!='1;
wire       tx_ben = {tx_history,bit_tx}!='0 && {tx_history,bit_tx}!='1;

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        rx_history <= '0;
        tx_history <= '1;
    end else begin
        if(bit_req) begin
            rx_history <= {rx_history[6:0], bit_rx};
            tx_history <= {tx_history[2:0], bit_tx};
        end
    end



reg        arb;
wire       arb_next = arb && bit_rx==bit_tx;

reg [14:0] rx_crc;
wire[14:0] rx_crc_next = {rx_crc[13:0], 1'b0} ^ (rx_crc[14] ^ bit_rx ? 15'h4599 : 15'h0);

reg [49:0] tx_shift;
reg [14:0] tx_crc;
wire[14:0] tx_crc_next = {tx_crc[13:0], 1'b0} ^ (tx_crc[14] ^ tx_shift[49] ? 15'h4599 : 15'h0);

wire[ 3:0] rx_len_next = {rx_len[2:0], bit_rx};
wire[ 7:0] rx_cnt = rx_len[3] ? 8'd63 : {1'd0, rx_len, 3'd0} - 8'd1;

reg [ 7:0] cnt;
reg [ 3:0] stat;

localparam [3:0] INIT         = 4'd0,
                 IDLE         = 4'd1,
                 TX_ID_MSB    = 4'd2,
                 TRX_ID_BASE  = 4'd3,
                 TX_PAYLOAD   = 4'd4,
                 TX_ACK_DEL   = 4'd5,
                 TX_ACK       = 4'd6,
                 TX_EOF       = 4'd7,
                 RX_IDE_BIT   = 4'd8,
                 RX_ID_EXTEND = 4'd9,
                 RX_RESV1_BIT = 4'd10,
                 RX_CTRL      = 4'd11,
                 RX_DATA      = 4'd12,
                 RX_CRC       = 4'd13,
                 RX_ACK       = 4'd14,
                 RX_EOF       = 4'd15;

reg rx_valid_pre;
reg rx_valid_latch;
reg rx_ack_latch;

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        rx_valid <= 1'b0;
        rx_valid_latch <= 1'b0;
        rx_ack_latch <= 1'b0;
    end else begin
        rx_valid <= rx_valid_pre & (rx_crc==15'd0);
        rx_valid_latch <= rx_valid;
        if(rx_valid_latch)
            rx_ack_latch <= rx_ack;
    end
    

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        {tx_done, tx_acked} <= 1'b0;
        rx_valid_pre <= 1'b0;
        {rx_id,rx_ide,rx_rtr,rx_len,rx_data,rx_crc} <= '0;
        bit_tx <= 1'b1;
        arb <= 1'b0;
        tx_crc <= '0;
        tx_shift <= '1;
        cnt <= 8'd0;
        stat <= INIT;
    end else begin
        {tx_done, tx_acked} <= 1'b0;
        rx_valid_pre <= 1'b0;
        
        if(bit_req) begin
            bit_tx <= 1'b1;
            
            case(stat)
                INIT : begin
                    if(rx_end)
                        stat <= IDLE;
                end
                
                IDLE : begin
                    arb <= 1'b0;
                    {rx_id,rx_ide,rx_rtr,rx_len,rx_data,rx_crc} <= '0;
                    tx_crc <= '0;
                    tx_shift <= {TX_ID, TX_RTR, 1'b0, 1'b0, 4'd4, tx_data};
                    if(bit_rx == 1'b0) begin
                        cnt <= 8'd0;
                        stat <= TRX_ID_BASE;
                    end else if(cnt<8'd20) begin
                        cnt <= cnt + 8'd1;
                    end else if(tx_start) begin
                        bit_tx <= 1'b0;
                        cnt <= 8'd0;
                        stat <= TX_ID_MSB;
                    end
                end
                
                TX_ID_MSB : begin
                    if(bit_rx) begin
                        stat <= TX_EOF;
                    end else begin
                        {bit_tx, tx_shift} <= {tx_shift, 1'b1};
                        tx_crc <= tx_crc_next;
                        arb <= 1'b1;
                        stat <= TRX_ID_BASE;
                    end
                end
                
                TRX_ID_BASE : begin
                    arb <= arb_next;
                    if(arb_next) begin
                        if(tx_ben) begin
                            {bit_tx, tx_shift} <= {tx_shift, 1'b1};
                            tx_crc <= tx_crc_next;
                        end else begin
                            bit_tx <= ~tx_history[0];
                        end
                    end
                    if(rx_end) begin
                        stat <= IDLE;
                    end else if(rx_err) begin
                        stat <= RX_EOF;
                    end else if(rx_ben) begin
                        rx_crc <= rx_crc_next;
                        if(cnt<8'd11) begin
                            rx_id <= {rx_id[27:0], bit_rx};
                            cnt <= cnt + 8'd1;
                        end else begin
                            rx_rtr <= bit_rx;
                            cnt <= 8'd0;
                            stat <= arb_next ? TX_PAYLOAD : RX_IDE_BIT;
                        end
                    end
                end
                
                TX_PAYLOAD : begin
                    if(bit_rx != bit_tx) begin
                        stat <= TX_EOF;
                    end else if(tx_ben) begin
                        {bit_tx, tx_shift} <= {tx_shift, 1'b1};
                        tx_crc <= tx_crc_next;
                        if(cnt==8'd36) tx_shift[49:35] <= tx_crc_next;
                        if(cnt<8'd52) begin
                            cnt <= cnt + 8'd1;
                        end else begin
                            cnt <= 8'd0;
                            stat <= TX_ACK_DEL;
                        end
                    end else begin
                        bit_tx <= ~tx_history[0];
                    end
                end
                
                TX_ACK_DEL : begin
                    stat <= bit_rx ? TX_ACK : TX_EOF;
                end
                
                TX_ACK : begin
                    tx_done <= 1'b1;
                    tx_acked <= ~bit_rx;
                    stat <= TX_EOF;
                end
                
                TX_EOF : begin
                    if(cnt<8'd8) begin
                        cnt <= cnt + 8'd1;
                    end else begin
                        cnt <= 8'd0;
                        stat <= RX_EOF;
                    end
                end
                
                RX_IDE_BIT : begin
                    if(rx_end) begin
                        stat <= IDLE;
                    end else if(rx_err) begin
                        stat <= RX_EOF;
                    end else if(rx_ben) begin
                        rx_crc <= rx_crc_next;
                        rx_ide <= bit_rx;
                        stat <= bit_rx ? RX_ID_EXTEND : RX_CTRL;
                    end
                end
                
                RX_ID_EXTEND : begin
                    if(rx_end) begin
                        stat <= IDLE;
                    end else if(rx_err) begin
                        stat <= RX_EOF;
                    end else if(rx_ben) begin
                        rx_crc <= rx_crc_next;
                        if(cnt<8'd18) begin
                            rx_id <= {rx_id[27:0], bit_rx};
                            cnt <= cnt + 8'd1;
                        end else begin
                            rx_rtr <= bit_rx;
                            cnt <= 8'd0;
                            stat <= RX_RESV1_BIT;
                        end
                    end
                end
                
                RX_RESV1_BIT : begin
                    if(rx_end) begin
                        stat <= IDLE;
                    end else if(rx_err) begin
                        stat <= RX_EOF;
                    end else if(rx_ben) begin
                        rx_crc <= rx_crc_next;
                        stat <= bit_rx ? RX_EOF : RX_CTRL;
                    end
                end
                
                RX_CTRL : begin
                    if(rx_end) begin
                        stat <= IDLE;
                    end else if(rx_err) begin
                        stat <= RX_EOF;
                    end else if(rx_ben) begin
                        rx_crc <= rx_crc_next;
                        rx_len <= rx_len_next;
                        if(cnt<8'd4) begin
                            cnt <= cnt + 8'd1;
                        end else begin
                            cnt <= 8'd0;
                            stat <= (rx_len_next!='0 && rx_rtr==1'b0) ? RX_DATA : RX_CRC;
                        end
                    end
                end
                
                RX_DATA : begin
                    if(rx_end) begin
                        stat <= IDLE;
                    end else if(rx_err) begin
                        stat <= RX_EOF;
                    end else if(rx_ben) begin
                        rx_crc <= rx_crc_next;
                        rx_data <= {rx_data[62:0], bit_rx};
                        if(cnt<rx_cnt) begin
                            cnt <= cnt + 8'd1;
                        end else begin
                            cnt <= 8'd0;
                            stat <= RX_CRC;
                        end
                    end
                end
                
                RX_CRC : begin
                    if(rx_end) begin
                        stat <= IDLE;
                    end else if(rx_err) begin
                        stat <= RX_EOF;
                    end else if(rx_ben) begin
                        rx_crc <= rx_crc_next;
                        if(cnt<8'd14) begin
                            cnt <= cnt + 8'd1;
                        end else begin
                            cnt <= 8'd0;
                            stat <= RX_ACK;
                            rx_valid_pre <= 1'b1;
                        end
                    end
                end
                
                RX_ACK : begin
                    if(rx_end) begin
                        stat <= IDLE;
                    end else if(rx_err) begin
                        stat <= RX_EOF;
                    end else if(rx_ben) begin
                        if(bit_rx && rx_crc==15'd0 && rx_ack_latch) // send ACK=0 bit if DEL=1 and no CRC error and user permission
                            bit_tx <= 1'b0;                         // send ACK
                        stat <= RX_EOF;
                    end
                end
                
                RX_EOF : begin
                    if(rx_end)
                        stat <= IDLE;
                end

            endcase
        end
    end



endmodule
