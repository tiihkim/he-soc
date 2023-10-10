// File auto-generated by Padrick 0.1.0.post0.dev51+g806b078.dirty
module alsaqr_periph_fpga_padframe
  import pkg_alsaqr_periph_fpga_padframe::*;
#(
  parameter int unsigned   AW = 32,
  parameter int unsigned   DW = 32,
  parameter type req_t = logic, // reg_interface request type
  parameter type resp_t = logic, // reg_interface response type
  parameter logic [DW-1:0] DecodeErrRespData = 32'hdeadda7a
)(
  input logic                                clk_i,
  input logic                                rst_ni,
  output port_signals_pad2soc_t              port_signals_pad2soc,
  input port_signals_soc2pad_t               port_signals_soc2pad,
  // Landing Pads
  inout wire logic                           pad_periphs_pad_gpio_b_00_pad,
  inout wire logic                           pad_periphs_pad_gpio_b_01_pad,
  inout wire logic                           pad_periphs_pad_gpio_b_02_pad,
  inout wire logic                           pad_periphs_pad_gpio_b_03_pad,
  inout wire logic                           pad_periphs_pad_gpio_b_04_pad,
  inout wire logic                           pad_periphs_pad_gpio_b_05_pad,
  inout wire logic                           pad_periphs_pad_gpio_b_06_pad,
  inout wire logic                           pad_periphs_pad_gpio_b_07_pad,
  inout wire logic                           pad_periphs_pad_gpio_b_08_pad,
  inout wire logic                           pad_periphs_pad_gpio_b_09_pad,
  inout wire logic                           pad_periphs_pad_gpio_b_10_pad,
  inout wire logic                           pad_periphs_pad_gpio_b_11_pad,
  inout wire logic                           pad_periphs_pad_gpio_b_12_pad,
  inout wire logic                           pad_periphs_pad_gpio_b_13_pad,
  inout wire logic                           pad_periphs_ot_spi_00_pad,
  inout wire logic                           pad_periphs_ot_spi_01_pad,
  inout wire logic                           pad_periphs_ot_spi_02_pad,
  inout wire logic                           pad_periphs_ot_spi_03_pad,
  // Config Interface
  input req_t                                config_req_i,
  output resp_t                              config_rsp_o
  );


  req_t periphs_config_req;
  resp_t periphs_config_resp;
  alsaqr_periph_fpga_padframe_periphs #(
    .req_t(req_t),
    .resp_t(resp_t)
  ) i_periphs (
   .clk_i,
   .rst_ni,
   .port_signals_pad2soc_o(port_signals_pad2soc.periphs),
   .port_signals_soc2pad_i(port_signals_soc2pad.periphs),
   .pad_pad_gpio_b_00_pad(pad_periphs_pad_gpio_b_00_pad),
   .pad_pad_gpio_b_01_pad(pad_periphs_pad_gpio_b_01_pad),
   .pad_pad_gpio_b_02_pad(pad_periphs_pad_gpio_b_02_pad),
   .pad_pad_gpio_b_03_pad(pad_periphs_pad_gpio_b_03_pad),
   .pad_pad_gpio_b_04_pad(pad_periphs_pad_gpio_b_04_pad),
   .pad_pad_gpio_b_05_pad(pad_periphs_pad_gpio_b_05_pad),
   .pad_pad_gpio_b_06_pad(pad_periphs_pad_gpio_b_06_pad),
   .pad_pad_gpio_b_07_pad(pad_periphs_pad_gpio_b_07_pad),
   .pad_pad_gpio_b_08_pad(pad_periphs_pad_gpio_b_08_pad),
   .pad_pad_gpio_b_09_pad(pad_periphs_pad_gpio_b_09_pad),
   .pad_pad_gpio_b_10_pad(pad_periphs_pad_gpio_b_10_pad),
   .pad_pad_gpio_b_11_pad(pad_periphs_pad_gpio_b_11_pad),
   .pad_pad_gpio_b_12_pad(pad_periphs_pad_gpio_b_12_pad),
   .pad_pad_gpio_b_13_pad(pad_periphs_pad_gpio_b_13_pad),
   .pad_ot_spi_00_pad(pad_periphs_ot_spi_00_pad),
   .pad_ot_spi_01_pad(pad_periphs_ot_spi_01_pad),
   .pad_ot_spi_02_pad(pad_periphs_ot_spi_02_pad),
   .pad_ot_spi_03_pad(pad_periphs_ot_spi_03_pad),
   .config_req_i(periphs_config_req),
   .config_rsp_o(periphs_config_resp)
  );


   localparam int unsigned NUM_PAD_DOMAINS = 1;
   localparam int unsigned REG_ADDR_WIDTH = 8;
   typedef struct packed {
      int unsigned idx;
      logic [REG_ADDR_WIDTH-1:0] start_addr;
      logic [REG_ADDR_WIDTH-1:0] end_addr;
   } addr_rule_t;

   localparam addr_rule_t[NUM_PAD_DOMAINS-1:0] ADDR_DEMUX_RULES = '{
     '{ idx: 0, start_addr: 8'd0,  end_addr: 8'd144}
     };
   logic[$clog2(NUM_PAD_DOMAINS+1)-1:0] pad_domain_sel; // +1 since there is an additional error slave
   addr_decode #(
       .NoIndices(NUM_PAD_DOMAINS+1),
       .NoRules(NUM_PAD_DOMAINS),
       .addr_t(logic[REG_ADDR_WIDTH-1:0]),
       .rule_t(addr_rule_t)
     ) i_addr_decode(
       .addr_i(config_req_i.addr[REG_ADDR_WIDTH-1:0]),
       .addr_map_i(ADDR_DEMUX_RULES),
       .dec_valid_o(),
       .dec_error_o(),
       .idx_o(pad_domain_sel),
       .en_default_idx_i(1'b1),
       .default_idx_i(1'd1) // The last entry is the error slave
     );

     req_t error_slave_req;
     resp_t error_slave_rsp;

     // Config Interface demultiplexing
     reg_demux #(
       .NoPorts(NUM_PAD_DOMAINS+1), //+1 for the error slave
       .req_t(req_t),
       .rsp_t(resp_t)
     ) i_config_demuxer (
       .clk_i,
       .rst_ni,
       .in_select_i(pad_domain_sel),
       .in_req_i(config_req_i),
       .in_rsp_o(config_rsp_o),
       .out_req_o({error_slave_req, periphs_config_req}),
       .out_rsp_i({error_slave_rsp, periphs_config_resp})
     );

     assign error_slave_rsp.error = 1'b1;
     assign error_slave_rsp.rdata = DecodeErrRespData;
     assign error_slave_rsp.ready = 1'b1;

endmodule
