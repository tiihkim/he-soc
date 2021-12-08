// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 15/04/2017
// Description: Top level testbench module. Instantiates the top level DUT, configures
//              the virtual interfaces and starts the test passed by +UVM_TEST+
//`define TEST_CLOCK_BYPASS

`timescale 1ps/1ps

import ariane_pkg::*;
import uvm_pkg::*;

`include "uvm_macros.svh"

import "DPI-C" function read_elf(input string filename);
import "DPI-C" function byte get_section(output longint address, output longint len);
import "DPI-C" context function byte read_section(input longint address, inout byte buffer[]);


module ariane_tb;

    static uvm_cmdline_processor uvcl = uvm_cmdline_processor::get_inst();

    localparam int unsigned REFClockPeriod = 67000ps; // jtag clock
    // toggle with RTC period
    `ifndef TEST_CLOCK_BYPASS
      localparam int unsigned RTC_CLOCK_PERIOD = 30.517us;
    `else 
      localparam int unsigned RTC_CLOCK_PERIOD = 10ns;
    `endif
   
    localparam NUM_WORDS = 2**25;
    logic clk_i;
    logic rst_ni;
    logic rtc_i;
    wire  s_rst_ni;
    wire  s_rtc_i;
    wire s_bypass;
    logic rst_DTM;

   
    localparam ENABLE_DM_TESTS = 0;
   
    parameter  USE_HYPER_MODELS     = 1;
    parameter  USE_24FC1025_MODEL   = 1;
    parameter  USE_S25FS256S_MODEL  = 1;
    parameter  USE_UART =1;

    // use camera verification IP
   parameter  USE_SDVT_CPI = 1;

  `ifdef PRELOAD
    parameter  PRELOAD_HYPERRAM    = 1;
    parameter  LOCAL_JTAG          = 1;
    parameter  CHECK_LOCAL_JTAG    = 0; 
  `else 
    parameter PRELOAD_HYPERRAM = 0;
    `ifdef USE_LOCAL_JTAG 
      parameter  LOCAL_JTAG          = 1;
      parameter  CHECK_LOCAL_JTAG    = 0; 
    `else
      parameter  LOCAL_JTAG          = 0;
      parameter  CHECK_LOCAL_JTAG    = 0; 
    `endif
  `endif
   

  `ifdef POSTLAYOUT
    localparam int unsigned JtagSampleDelay = (REFClockPeriod < 10ns) ? 2 : 1;
  `else
    localparam int unsigned JtagSampleDelay = 0;
  `endif    

  `ifdef JTAG_RBB 
    parameter int   jtag_enable = '1 ;
  `else  
    parameter int   jtag_enable = '0 ;
  `endif

    localparam logic [15:0] PartNumber = 1; 
    logic program_loaded = 0;
    logic  eoc;
    logic [31:0]  retval = 32'h0;  // Store return value
    localparam logic [31:0] dm_idcode  = (dm::DbgVersion013 << 28) | (PartNumber << 12) | 32'b1; 
    localparam AxiWideBeWidth    = ariane_axi_soc::DataWidth / 8;
    localparam AxiWideByteOffset = $clog2(AxiWideBeWidth);
    typedef logic [ariane_axi_soc::AddrWidth-1:0] addr_t;
    typedef logic [ariane_axi_soc::DataWidth-1:0] data_t;   
    data_t memory[bit [31:0]];
    int sections [bit [31:0]];
    
    wire                  s_dmi_req_valid;
    wire                  s_dmi_req_ready;
    wire [ 6:0]           s_dmi_req_bits_addr;
    wire [ 1:0]           s_dmi_req_bits_op;
    wire [31:0]           s_dmi_req_bits_data;
    wire                  s_dmi_resp_valid;
    wire                  s_dmi_resp_ready;
    wire [ 1:0]           s_dmi_resp_bits_resp;
    wire [31:0]           s_dmi_resp_bits_data;   
    wire                  s_dmi_exit;
   
    wire                  s_jtag_TCK       ;
    wire                  s_jtag_TMS       ;
    wire                  s_jtag_TDI       ;
    wire                  s_jtag_TRSTn     ;
    wire                  s_jtag_TDO_data  ;
    wire                  s_jtag_TDO_driven;
    wire                  s_jtag_exit      ;
  
    string                stimuli_file      ;
    logic                 s_tck         ;
    logic                 s_tms         ;
    logic                 s_tdi         ;
    logic                 s_trstn       ;
    logic                 s_tdo         ;

    wire                  s_jtag2alsaqr_tck       ;
    wire                  s_jtag2alsaqr_tms       ;
    wire                  s_jtag2alsaqr_tdi       ;
    wire                  s_jtag2alsaqr_trstn     ;
    wire                  s_jtag2alsaqr_tdo       ;
   
    wire [7:0]            w_hyper0_dq;
    wire                  w_hyper0_ck;
    wire                  w_hyper0_ckn;
    wire [1:0]            w_hyper0_csn;
    wire                  w_hyper0_rwds;
    wire                  w_hyper0_reset;
    wire [7:0]            w_hyper1_dq;
    wire                  w_hyper1_ck;
    wire                  w_hyper1_ckn;
    wire [1:0]            w_hyper1_csn;
    wire                  w_hyper1_rwds;
    wire                  w_hyper1_reset;

    wire                  w_i2c_sda      ;
    wire                  w_i2c_scl      ;

    tri                   w_spim_sck     ; 
    tri                   w_spim_csn0    ;
    tri                   w_spim_sdio0   ; 
    wire                  w_spim_sdio1   ;
    tri                   w_spim_sdio2   ; 
    tri                   w_spim_sdio3   ;

    wire                  w_cam_pclk;
    wire [7:0]            w_cam_data;
    wire                  w_cam_hsync;
    wire                  w_cam_vsync;

    //NEW PAD PERIPHERALS SIGNALS
    wire    pad_periphs_pad_gpio_b_00_pad;
    wire    pad_periphs_pad_gpio_b_01_pad;
    wire    pad_periphs_pad_gpio_b_02_pad;
    wire    pad_periphs_pad_gpio_b_03_pad;
    wire    pad_periphs_pad_gpio_b_04_pad;
    wire    pad_periphs_pad_gpio_b_05_pad;
    wire    pad_periphs_pad_gpio_b_06_pad;
    wire    pad_periphs_pad_gpio_b_07_pad;
    wire    pad_periphs_pad_gpio_b_08_pad;
    wire    pad_periphs_pad_gpio_b_09_pad;
    wire    pad_periphs_pad_gpio_b_10_pad;
    wire    pad_periphs_pad_gpio_b_11_pad;
    wire    pad_periphs_pad_gpio_b_12_pad;
    wire    pad_periphs_pad_gpio_b_13_pad;
    wire    pad_periphs_pad_gpio_b_14_pad;
    wire    pad_periphs_pad_gpio_b_15_pad;
    wire    pad_periphs_pad_gpio_b_16_pad;
    wire    pad_periphs_pad_gpio_b_17_pad;
    wire    pad_periphs_pad_gpio_b_18_pad;
    wire    pad_periphs_pad_gpio_b_19_pad;
    wire    pad_periphs_pad_gpio_b_20_pad;
    wire    pad_periphs_pad_gpio_b_21_pad;
    wire    pad_periphs_pad_gpio_b_22_pad;
    wire    pad_periphs_pad_gpio_b_23_pad;
    wire    pad_periphs_pad_gpio_b_24_pad;
    wire    pad_periphs_pad_gpio_b_25_pad;
    wire    pad_periphs_pad_gpio_b_26_pad;
    wire    pad_periphs_pad_gpio_b_27_pad;
    wire    pad_periphs_pad_gpio_b_28_pad;
    wire    pad_periphs_pad_gpio_b_29_pad;
    wire    pad_periphs_pad_gpio_b_30_pad;
    wire    pad_periphs_pad_gpio_b_31_pad;
    wire    pad_periphs_pad_gpio_b_32_pad;
    wire    pad_periphs_pad_gpio_b_33_pad;
    wire    pad_periphs_pad_gpio_b_34_pad;
    wire    pad_periphs_pad_gpio_b_35_pad;
    wire    pad_periphs_pad_gpio_b_36_pad;
    wire    pad_periphs_pad_gpio_b_37_pad;
    wire    pad_periphs_pad_gpio_b_38_pad;
    wire    pad_periphs_pad_gpio_b_39_pad;
    wire    pad_periphs_pad_gpio_b_40_pad;
    wire    pad_periphs_pad_gpio_b_41_pad;
    wire    pad_periphs_pad_gpio_b_42_pad;
    wire    pad_periphs_pad_gpio_b_43_pad;
    wire    pad_periphs_pad_gpio_b_44_pad;
    wire    pad_periphs_pad_gpio_b_45_pad;
    wire    pad_periphs_pad_gpio_b_46_pad;
    wire    pad_periphs_pad_gpio_b_47_pad;
    wire    pad_periphs_pad_gpio_b_48_pad;
    wire    pad_periphs_pad_gpio_b_49_pad;
    wire    pad_periphs_pad_gpio_b_50_pad;
    wire    pad_periphs_pad_gpio_b_51_pad;
    wire    pad_periphs_pad_gpio_b_52_pad;
    wire    pad_periphs_pad_gpio_b_53_pad;
    wire    pad_periphs_pad_gpio_b_54_pad;
    wire    pad_periphs_pad_gpio_b_55_pad;
    wire    pad_periphs_pad_gpio_b_56_pad;
    wire    pad_periphs_pad_gpio_b_57_pad;
    wire    pad_periphs_pad_gpio_b_58_pad;
    wire    pad_periphs_pad_gpio_b_59_pad;
    wire    pad_periphs_pad_gpio_b_60_pad;
    wire    pad_periphs_pad_gpio_b_61_pad;
    wire    pad_periphs_pad_gpio_c_00_pad;
    wire    pad_periphs_pad_gpio_c_01_pad;
    wire    pad_periphs_pad_gpio_c_02_pad;
    wire    pad_periphs_pad_gpio_c_03_pad;
    wire    pad_periphs_pad_gpio_d_00_pad;
    wire    pad_periphs_pad_gpio_d_01_pad;
    wire    pad_periphs_pad_gpio_d_02_pad;
    wire    pad_periphs_pad_gpio_d_03_pad;
    wire    pad_periphs_pad_gpio_d_04_pad;
    wire    pad_periphs_pad_gpio_d_05_pad;
    wire    pad_periphs_pad_gpio_d_06_pad;
    wire    pad_periphs_pad_gpio_d_07_pad;
    wire    pad_periphs_pad_gpio_d_08_pad;
    wire    pad_periphs_pad_gpio_d_09_pad;
    wire    pad_periphs_pad_gpio_d_10_pad;
    wire    pad_periphs_pad_gpio_e_00_pad;
    wire    pad_periphs_pad_gpio_e_01_pad;
    wire    pad_periphs_pad_gpio_e_02_pad;
    wire    pad_periphs_pad_gpio_e_03_pad;
    wire    pad_periphs_pad_gpio_e_04_pad;
    wire    pad_periphs_pad_gpio_e_05_pad;
    wire    pad_periphs_pad_gpio_e_06_pad;
    wire    pad_periphs_pad_gpio_e_07_pad;
    wire    pad_periphs_pad_gpio_e_08_pad;
    wire    pad_periphs_pad_gpio_e_09_pad;
    wire    pad_periphs_pad_gpio_e_10_pad;
    wire    pad_periphs_pad_gpio_e_11_pad;
    wire    pad_periphs_pad_gpio_e_12_pad;
    wire    pad_periphs_pad_gpio_f_00_pad;
    wire    pad_periphs_pad_gpio_f_01_pad;
    wire    pad_periphs_pad_gpio_f_02_pad;
    wire    pad_periphs_pad_gpio_f_03_pad;
    wire    pad_periphs_pad_gpio_f_04_pad;
    wire    pad_periphs_pad_gpio_f_05_pad;
    wire    pad_periphs_pad_gpio_f_06_pad;
    wire    pad_periphs_pad_gpio_f_07_pad;
    wire    pad_periphs_pad_gpio_f_08_pad;
    wire    pad_periphs_pad_gpio_f_09_pad;
    wire    pad_periphs_pad_gpio_f_10_pad;
    wire    pad_periphs_pad_gpio_f_11_pad;
    wire    pad_periphs_pad_gpio_f_12_pad;
    wire    pad_periphs_pad_gpio_f_13_pad;
    wire    pad_periphs_pad_gpio_f_14_pad;
    wire    pad_periphs_pad_gpio_f_15_pad;
    wire    pad_periphs_pad_gpio_f_16_pad;
    wire    pad_periphs_pad_gpio_f_17_pad;
    wire    pad_periphs_pad_gpio_f_18_pad;
    wire    pad_periphs_pad_gpio_f_19_pad;
    wire    pad_periphs_pad_gpio_f_20_pad;
    wire    pad_periphs_pad_gpio_f_21_pad;
    wire    pad_periphs_pad_gpio_f_22_pad;
    wire    pad_periphs_pad_gpio_f_23_pad;
    wire    pad_periphs_pad_gpio_f_24_pad;
    wire    pad_periphs_pad_gpio_f_25_pad;
    wire    pad_periphs_pad_gpio_pwm0_pad;
    wire    pad_periphs_pad_gpio_pwm1_pad;
    wire    pad_periphs_pad_gpio_pwm2_pad;
    wire    pad_periphs_pad_gpio_pwm3_pad;
    wire    pad_periphs_pad_gpio_pwm4_pad;
    wire    pad_periphs_pad_gpio_pwm5_pad;
    wire    pad_periphs_pad_gpio_pwm6_pad;
    wire    pad_periphs_pad_gpio_pwm7_pad;



    wire                  w_cva6_uart_rx ;
    wire                  w_cva6_uart_tx ;
   
  
    longint unsigned cycles;
    longint unsigned max_cycles;

    logic [31:0] exit_o;

    string        binary ;
    string        cluster_binary;

  assign pad_periphs_pad_gpio_b_37_pad = pad_periphs_pad_gpio_b_05_pad;
  assign pad_periphs_pad_gpio_b_38_pad = pad_periphs_pad_gpio_b_06_pad;
  assign pad_periphs_pad_gpio_b_39_pad = pad_periphs_pad_gpio_b_07_pad;
   
  `ifndef TEST_CLOCK_BYPASS
    assign s_bypass=1'b0;
  `else
    assign s_bypass=1'b1;
  `endif
    
  assign s_rst_ni=rst_ni;
  assign s_rtc_i=rtc_i;

  assign exit_o              = (jtag_enable[0]) ? s_jtag_exit          : s_dmi_exit;

  assign s_jtag2alsaqr_tck    = LOCAL_JTAG  ?  s_tck   : s_jtag_TCK   ;
  assign s_jtag2alsaqr_tms    = LOCAL_JTAG  ?  s_tms   : s_jtag_TMS   ;
  assign s_jtag2alsaqr_tdi    = LOCAL_JTAG  ?  s_tdi   : s_jtag_TDI   ;
  assign s_jtag2alsaqr_trstn  = LOCAL_JTAG  ?  s_trstn : s_jtag_TRSTn ;
  assign s_jtag_TDO_data      = s_jtag2alsaqr_tdo       ;
  assign s_tdo                = s_jtag2alsaqr_tdo       ;
  
  if (~jtag_enable[0] & !LOCAL_JTAG) begin
    SimDTM i_SimDTM (
      .clk                  ( clk_i                 ),
      .reset                ( ~rst_DTM              ),
      .debug_req_valid      ( s_dmi_req_valid       ),
      .debug_req_ready      ( s_dmi_req_ready       ),
      .debug_req_bits_addr  ( s_dmi_req_bits_addr   ),
      .debug_req_bits_op    ( s_dmi_req_bits_op     ),
      .debug_req_bits_data  ( s_dmi_req_bits_data   ),
      .debug_resp_valid     ( s_dmi_resp_valid      ),
      .debug_resp_ready     ( s_dmi_resp_ready      ),
      .debug_resp_bits_resp ( s_dmi_resp_bits_resp  ),
      .debug_resp_bits_data ( s_dmi_resp_bits_data  ), 
      .exit                 ( s_dmi_exit            )
    );
  end else begin
    assign dmi_req_valid = '0;
    assign debug_req_bits_op = '0;
    assign dmi_exit = 1'b0;
  end   
   
  // SiFive's SimJTAG Module
  // Converts to DPI calls
  SimJTAG i_SimJTAG (
    .clock                ( clk_i                ),
    .reset                ( ~rst_ni              ),
    .enable               ( jtag_enable[0]       ),
    .init_done            ( rst_ni               ),
    .jtag_TCK             ( s_jtag_TCK           ),
    .jtag_TMS             ( s_jtag_TMS           ),
    .jtag_TDI             ( s_jtag_TDI           ),
    .jtag_TRSTn           ( s_jtag_TRSTn         ),
    .jtag_TDO_data        ( s_jtag_TDO_data      ),
    .jtag_TDO_driven      ( s_jtag_TDO_driven    ),
    .exit                 ( s_jtag_exit          )
  );
   
    al_saqr #(
        .NUM_WORDS         ( NUM_WORDS                   ),
        .InclSimDTM        ( 1'b1                        ),
        .StallRandomOutput ( 1'b1                        ),
        .StallRandomInput  ( 1'b1                        ),
        .JtagEnable        ( jtag_enable[0] | LOCAL_JTAG )
    ) dut (
        .rst_ni               ( s_rst_ni               ),
        .rtc_i                ( s_rtc_i                ),
        .bypass_clk_i         ( s_bypass               ),
        .dmi_req_valid        ( s_dmi_req_valid        ),
        .dmi_req_ready        ( s_dmi_req_ready        ),
        .dmi_req_bits_addr    ( s_dmi_req_bits_addr    ),
        .dmi_req_bits_op      ( s_dmi_req_bits_op      ),
        .dmi_req_bits_data    ( s_dmi_req_bits_data    ),
        .dmi_resp_valid       ( s_dmi_resp_valid       ),
        .dmi_resp_ready       ( s_dmi_resp_ready       ),
        .dmi_resp_bits_resp   ( s_dmi_resp_bits_resp   ),
        .dmi_resp_bits_data   ( s_dmi_resp_bits_data   ),                      
        .jtag_TCK             ( s_jtag2alsaqr_tck      ),
        .jtag_TMS             ( s_jtag2alsaqr_tms      ),
        .jtag_TDI             ( s_jtag2alsaqr_tdi      ),
        .jtag_TRSTn           ( s_jtag2alsaqr_trstn    ),
        .jtag_TDO_data        ( s_jtag2alsaqr_tdo      ),
        .jtag_TDO_driven      ( s_jtag_TDO_driven      ),

        .cva6_uart_rx_i       ( w_cva6_uart_rx         ),
        .cva6_uart_tx_o       ( w_cva6_uart_tx         ),
        
        .pad_hyper0_dq        ( w_hyper0_dq            ),
        .pad_hyper0_ck        ( w_hyper0_ck            ),
        .pad_hyper0_ckn       ( w_hyper0_ckn           ),
        .pad_hyper0_csn       ( w_hyper0_csn           ),
        .pad_hyper0_rwds      ( w_hyper0_rwds          ),
        .pad_hyper0_reset     ( w_hyper0_reset         ),
        .pad_hyper1_dq        ( w_hyper1_dq            ),
        .pad_hyper1_ck        ( w_hyper1_ck            ),
        .pad_hyper1_ckn       ( w_hyper1_ckn           ),
        .pad_hyper1_csn       ( w_hyper1_csn           ),
        .pad_hyper1_rwds      ( w_hyper1_rwds          ),
        .pad_hyper1_reset     ( w_hyper1_reset         ),
        
        .pad_periphs_pad_gpio_b_00_pad(pad_periphs_pad_gpio_b_00_pad),
        .pad_periphs_pad_gpio_b_01_pad(pad_periphs_pad_gpio_b_01_pad),
        .pad_periphs_pad_gpio_b_02_pad(pad_periphs_pad_gpio_b_02_pad),
        .pad_periphs_pad_gpio_b_03_pad(pad_periphs_pad_gpio_b_03_pad),
        .pad_periphs_pad_gpio_b_04_pad(pad_periphs_pad_gpio_b_04_pad),
        .pad_periphs_pad_gpio_b_05_pad(pad_periphs_pad_gpio_b_05_pad),
        .pad_periphs_pad_gpio_b_06_pad(pad_periphs_pad_gpio_b_06_pad),
        .pad_periphs_pad_gpio_b_07_pad(pad_periphs_pad_gpio_b_07_pad),
        .pad_periphs_pad_gpio_b_08_pad(),
        .pad_periphs_pad_gpio_b_09_pad(),
        .pad_periphs_pad_gpio_b_10_pad(),
        .pad_periphs_pad_gpio_b_11_pad(),
        .pad_periphs_pad_gpio_b_12_pad(),
        .pad_periphs_pad_gpio_b_13_pad(),
        .pad_periphs_pad_gpio_b_14_pad(),
        .pad_periphs_pad_gpio_b_15_pad(),
        .pad_periphs_pad_gpio_b_16_pad(),
        .pad_periphs_pad_gpio_b_17_pad(),
        .pad_periphs_pad_gpio_b_18_pad(),
        .pad_periphs_pad_gpio_b_19_pad(),
        .pad_periphs_pad_gpio_b_20_pad(),
        .pad_periphs_pad_gpio_b_21_pad(),
        .pad_periphs_pad_gpio_b_22_pad(),
        .pad_periphs_pad_gpio_b_23_pad(),
        .pad_periphs_pad_gpio_b_24_pad(),
        .pad_periphs_pad_gpio_b_25_pad(),
        .pad_periphs_pad_gpio_b_26_pad(),
        .pad_periphs_pad_gpio_b_27_pad(),
        .pad_periphs_pad_gpio_b_28_pad(),
        .pad_periphs_pad_gpio_b_29_pad(),
        .pad_periphs_pad_gpio_b_30_pad(),
        .pad_periphs_pad_gpio_b_31_pad(),
        .pad_periphs_pad_gpio_b_32_pad(),
        .pad_periphs_pad_gpio_b_33_pad(),
        .pad_periphs_pad_gpio_b_34_pad(),
        .pad_periphs_pad_gpio_b_35_pad(),
        .pad_periphs_pad_gpio_b_36_pad(),
        .pad_periphs_pad_gpio_b_37_pad(pad_periphs_pad_gpio_b_37_pad),
        .pad_periphs_pad_gpio_b_38_pad(pad_periphs_pad_gpio_b_38_pad),
        .pad_periphs_pad_gpio_b_39_pad(pad_periphs_pad_gpio_b_39_pad),
        .pad_periphs_pad_gpio_b_40_pad(pad_periphs_pad_gpio_b_40_pad),
        .pad_periphs_pad_gpio_b_41_pad(pad_periphs_pad_gpio_b_41_pad),
        .pad_periphs_pad_gpio_b_42_pad(),
        .pad_periphs_pad_gpio_b_43_pad(),
        .pad_periphs_pad_gpio_b_44_pad(),
        .pad_periphs_pad_gpio_b_45_pad(),
        .pad_periphs_pad_gpio_b_46_pad(),
        .pad_periphs_pad_gpio_b_47_pad(),
        .pad_periphs_pad_gpio_b_48_pad(),
        .pad_periphs_pad_gpio_b_49_pad(),
        .pad_periphs_pad_gpio_b_50_pad(pad_periphs_pad_gpio_b_50_pad),
        .pad_periphs_pad_gpio_b_51_pad(pad_periphs_pad_gpio_b_51_pad),
        .pad_periphs_pad_gpio_b_52_pad(),
        .pad_periphs_pad_gpio_b_53_pad(),
        .pad_periphs_pad_gpio_b_54_pad(),
        .pad_periphs_pad_gpio_b_55_pad(),
        .pad_periphs_pad_gpio_b_56_pad(pad_periphs_pad_gpio_b_56_pad),
        .pad_periphs_pad_gpio_b_57_pad(pad_periphs_pad_gpio_b_57_pad),
        .pad_periphs_pad_gpio_b_58_pad(),
        .pad_periphs_pad_gpio_b_59_pad(),
        .pad_periphs_pad_gpio_b_60_pad(),
        .pad_periphs_pad_gpio_b_61_pad(),
        .pad_periphs_pad_gpio_c_00_pad(),
        .pad_periphs_pad_gpio_c_01_pad(),
        .pad_periphs_pad_gpio_c_02_pad(),
        .pad_periphs_pad_gpio_c_03_pad(),
        .pad_periphs_pad_gpio_d_00_pad(pad_periphs_pad_gpio_d_00_pad),
        .pad_periphs_pad_gpio_d_01_pad(pad_periphs_pad_gpio_d_01_pad),
        .pad_periphs_pad_gpio_d_02_pad(pad_periphs_pad_gpio_d_02_pad),
        .pad_periphs_pad_gpio_d_03_pad(pad_periphs_pad_gpio_d_03_pad),
        .pad_periphs_pad_gpio_d_04_pad(pad_periphs_pad_gpio_d_04_pad),
        .pad_periphs_pad_gpio_d_05_pad(pad_periphs_pad_gpio_d_05_pad),
        .pad_periphs_pad_gpio_d_06_pad(pad_periphs_pad_gpio_d_06_pad),
        .pad_periphs_pad_gpio_d_07_pad(pad_periphs_pad_gpio_d_07_pad),
        .pad_periphs_pad_gpio_d_08_pad(pad_periphs_pad_gpio_d_08_pad),
        .pad_periphs_pad_gpio_d_09_pad(pad_periphs_pad_gpio_d_09_pad),
        .pad_periphs_pad_gpio_d_10_pad(pad_periphs_pad_gpio_d_10_pad),
        .pad_periphs_pad_gpio_e_00_pad(),
        .pad_periphs_pad_gpio_e_01_pad(),
        .pad_periphs_pad_gpio_e_02_pad(),
        .pad_periphs_pad_gpio_e_03_pad(),
        .pad_periphs_pad_gpio_e_04_pad(),
        .pad_periphs_pad_gpio_e_05_pad(),
        .pad_periphs_pad_gpio_e_06_pad(),
        .pad_periphs_pad_gpio_e_07_pad(),
        .pad_periphs_pad_gpio_e_08_pad(),
        .pad_periphs_pad_gpio_e_09_pad(),
        .pad_periphs_pad_gpio_e_10_pad(),
        .pad_periphs_pad_gpio_e_11_pad(),
        .pad_periphs_pad_gpio_e_12_pad(),
        .pad_periphs_pad_gpio_f_00_pad(),
        .pad_periphs_pad_gpio_f_01_pad(),
        .pad_periphs_pad_gpio_f_02_pad(),
        .pad_periphs_pad_gpio_f_03_pad(),
        .pad_periphs_pad_gpio_f_04_pad(),
        .pad_periphs_pad_gpio_f_05_pad(),
        .pad_periphs_pad_gpio_f_06_pad(),
        .pad_periphs_pad_gpio_f_07_pad(),
        .pad_periphs_pad_gpio_f_08_pad(),
        .pad_periphs_pad_gpio_f_09_pad(),
        .pad_periphs_pad_gpio_f_10_pad(),
        .pad_periphs_pad_gpio_f_11_pad(),
        .pad_periphs_pad_gpio_f_12_pad(),
        .pad_periphs_pad_gpio_f_13_pad(),
        .pad_periphs_pad_gpio_f_14_pad(),
        .pad_periphs_pad_gpio_f_15_pad(),
        .pad_periphs_pad_gpio_f_16_pad(),
        .pad_periphs_pad_gpio_f_17_pad(),
        .pad_periphs_pad_gpio_f_18_pad(),
        .pad_periphs_pad_gpio_f_19_pad(),
        .pad_periphs_pad_gpio_f_20_pad(),
        .pad_periphs_pad_gpio_f_21_pad(),
        .pad_periphs_pad_gpio_f_22_pad(),
        .pad_periphs_pad_gpio_f_23_pad(),
        .pad_periphs_pad_gpio_pwm7_pad(),
        .pad_periphs_pad_gpio_f_24_pad(),
        .pad_periphs_pad_gpio_f_25_pad(),
        .pad_periphs_pad_gpio_pwm0_pad(),
        .pad_periphs_pad_gpio_pwm1_pad(),
        .pad_periphs_pad_gpio_pwm2_pad(),
        .pad_periphs_pad_gpio_pwm3_pad(),
        .pad_periphs_pad_gpio_pwm4_pad(),
        .pad_periphs_pad_gpio_pwm5_pad(),
        .pad_periphs_pad_gpio_pwm6_pad()
   );

   
   if (USE_UART == 1) begin
        assign pad_periphs_pad_gpio_b_41_pad =pad_periphs_pad_gpio_b_40_pad;
   end

   generate
     /* I2C memory models connected on I2C0*/
     if (USE_24FC1025_MODEL == 1) begin
        pullup scl0_pullup_i (pad_periphs_pad_gpio_b_50_pad);
        pullup sda0_pullup_i (pad_periphs_pad_gpio_b_51_pad);

        M24FC1025 i_i2c_mem_0 (
           .A0    ( 1'b0       ),
           .A1    ( 1'b0       ),
           .A2    ( 1'b1       ),
           .WP    ( 1'b0       ),
           .SDA   ( pad_periphs_pad_gpio_b_51_pad ),
           .SCL   ( pad_periphs_pad_gpio_b_50_pad ),
           .RESET ( 1'b0       )
        );
       
        M24FC1025 i_i2c_mem_1 (
           .A0    ( 1'b1       ),
           .A1    ( 1'b0       ),
           .A2    ( 1'b1       ),
           .WP    ( 1'b0       ),
           .SDA   ( pad_periphs_pad_gpio_b_51_pad ),
           .SCL   ( pad_periphs_pad_gpio_b_50_pad ),
           .RESET ( 1'b0       )
        );

   end
   endgenerate

  generate
    /* SPI flash */
      if(USE_S25FS256S_MODEL == 1) begin
         s25fs256s #(
            .TimingModel   ( "S25FS256SAGMFI000_F_30pF" ),
            .mem_file_name ( "./vectors/qspi_stim.slm" ),
            .UserPreload   ( 0 )
         ) i_spi_flash_csn0 (
            .SI       ( pad_periphs_pad_gpio_b_03_pad  ),
            .SO       ( pad_periphs_pad_gpio_b_02_pad  ),
            .SCK      ( pad_periphs_pad_gpio_b_01_pad  ),
            .CSNeg    ( pad_periphs_pad_gpio_b_00_pad  ),
            .WPNeg    (  ),
            .RESETNeg (  )
         );
      end
  endgenerate

  generate
     /* CAM */
      if (USE_SDVT_CPI==1) begin
         cam_vip #(
            .HRES       ( 32 ), //320
            .VRES       ( 32 ) //240
         ) i_cam_vip (
            .en_i        ( pad_periphs_pad_gpio_b_00_pad  ),  //GPIO B 0
            .cam_clk_o   ( pad_periphs_pad_gpio_d_00_pad  ),
            .cam_vsync_o ( pad_periphs_pad_gpio_d_10_pad ),
            .cam_href_o  ( pad_periphs_pad_gpio_d_01_pad ),
            .cam_data_o  ( w_cam_data  )
         );
        
        assign pad_periphs_pad_gpio_d_02_pad = w_cam_data[0];
        assign pad_periphs_pad_gpio_d_03_pad = w_cam_data[1];
        assign pad_periphs_pad_gpio_d_04_pad = w_cam_data[2];
        assign pad_periphs_pad_gpio_d_05_pad = w_cam_data[3];
        assign pad_periphs_pad_gpio_d_06_pad = w_cam_data[4];
        assign pad_periphs_pad_gpio_d_07_pad = w_cam_data[5];
        assign pad_periphs_pad_gpio_d_08_pad = w_cam_data[6];
        assign pad_periphs_pad_gpio_d_09_pad = w_cam_data[7];
      end
  endgenerate


   s27ks0641 #(
         .TimingModel   ( "S27KS0641DPBHI020"    ),
         .UserPreload   ( PRELOAD_HYPERRAM       ),
         .mem_file_name ( "./hyperram0.slm"      )
     ) i_main_hyperram0 (
            .DQ7      ( w_hyper0_dq[7]  ),
            .DQ6      ( w_hyper0_dq[6]  ),
            .DQ5      ( w_hyper0_dq[5]  ),
            .DQ4      ( w_hyper0_dq[4]  ),
            .DQ3      ( w_hyper0_dq[3]  ),
            .DQ2      ( w_hyper0_dq[2]  ),
            .DQ1      ( w_hyper0_dq[1]  ),
            .DQ0      ( w_hyper0_dq[0]  ),
            .RWDS     ( w_hyper0_rwds   ),
            .CSNeg    ( w_hyper0_csn[0] ),
            .CK       ( w_hyper0_ck     ),
            .CKNeg    ( w_hyper0_ckn    ),
            .RESETNeg ( w_hyper0_reset  )
     ); 
   s27ks0641 #(
         .TimingModel   ( "S27KS0641DPBHI020"    ),
         .UserPreload   ( 1'b0                   ),
         .mem_file_name ( "hyper.mem"            )
     ) i_main_hyperram1 (
            .DQ7      ( w_hyper0_dq[7]  ),
            .DQ6      ( w_hyper0_dq[6]  ),
            .DQ5      ( w_hyper0_dq[5]  ),
            .DQ4      ( w_hyper0_dq[4]  ),
            .DQ3      ( w_hyper0_dq[3]  ),
            .DQ2      ( w_hyper0_dq[2]  ),
            .DQ1      ( w_hyper0_dq[1]  ),
            .DQ0      ( w_hyper0_dq[0]  ),
            .RWDS     ( w_hyper0_rwds   ),
            .CSNeg    ( w_hyper0_csn[1] ),
            .CK       ( w_hyper0_ck     ),
            .CKNeg    ( w_hyper0_ckn    ),
            .RESETNeg ( w_hyper0_reset  )
     );
         s27ks0641 #(
            .TimingModel   ( "S27KS0641DPBHI020" ),
            .UserPreload   ( PRELOAD_HYPERRAM    ),
            .mem_file_name ( "./hyperram1.slm"   )
         ) i_main_hyperram2 (
            .DQ7      ( w_hyper1_dq[7]  ),
            .DQ6      ( w_hyper1_dq[6]  ),
            .DQ5      ( w_hyper1_dq[5]  ),
            .DQ4      ( w_hyper1_dq[4]  ),
            .DQ3      ( w_hyper1_dq[3]  ),
            .DQ2      ( w_hyper1_dq[2]  ),
            .DQ1      ( w_hyper1_dq[1]  ),
            .DQ0      ( w_hyper1_dq[0]  ),
            .RWDS     ( w_hyper1_rwds   ),
            .CSNeg    ( w_hyper1_csn[0] ),
            .CK       ( w_hyper1_ck     ),
            .CKNeg    ( w_hyper1_ckn    ),
            .RESETNeg ( w_hyper1_reset  )
         );
         s27ks0641 #(
            .TimingModel   ( "S27KS0641DPBHI020" ),
            .UserPreload   ( 1'b0                ),
            .mem_file_name ( "hyper.mem"         )
         ) i_main_hyperram3 (
            .DQ7      ( w_hyper1_dq[7]  ),
            .DQ6      ( w_hyper1_dq[6]  ),
            .DQ5      ( w_hyper1_dq[5]  ),
            .DQ4      ( w_hyper1_dq[4]  ),
            .DQ3      ( w_hyper1_dq[3]  ),
            .DQ2      ( w_hyper1_dq[2]  ),
            .DQ1      ( w_hyper1_dq[1]  ),
            .DQ0      ( w_hyper1_dq[0]  ),
            .RWDS     ( w_hyper1_rwds   ),
            .CSNeg    ( w_hyper1_csn[1] ),
            .CK       ( w_hyper1_ck     ),
            .CKNeg    ( w_hyper1_ckn    ),
            .RESETNeg ( w_hyper1_reset  )
         );

   uart_bus #(.BAUD_RATE(115200), .PARITY_EN(0)) i_uart_bus (.rx(w_cva6_uart_tx), .tx(w_cva6_uart_rx), .rx_en(1'b1));

    initial begin: reset_jtag
      jtag_mst.tdi = 0;
      jtag_mst.tms = 0;
    end
  
    // JTAG Definition
    typedef jtag_test::riscv_dbg #(
      .IrLength       (5                 ),
      .TA             (REFClockPeriod*0.1),
      .TT             (REFClockPeriod*0.9),
      .JtagSampleDelay(JtagSampleDelay   )
    ) riscv_dbg_t;
  
    // JTAG driver
    JTAG_DV jtag_mst (s_tck);
    riscv_dbg_t::jtag_driver_t jtag_driver = new(jtag_mst);
    riscv_dbg_t riscv_dbg = new(jtag_driver);
  
    assign s_trstn      = jtag_mst.trst_n;
    assign s_tms        = jtag_mst.tms;
    assign s_tdi        = jtag_mst.tdi;
    assign jtag_mst.tdo = s_tdo;

    // Clock process
    initial begin
        rst_ni = 1'b0;
        rst_DTM = 1'b0;
        jtag_mst.trst_n = 1'b0;
       
        repeat(2)
            @(posedge rtc_i);
        rst_ni = 1'b1;
        repeat(20)
            @(posedge rtc_i);
        rst_DTM = 1'b1;
        jtag_mst.trst_n = 1'b1;       
        forever begin
            @(posedge clk_i);
            cycles++;
        end
    end

    initial begin
        forever begin
            rtc_i = 1'b0;
            #(RTC_CLOCK_PERIOD/2) rtc_i = 1'b1;
            #(RTC_CLOCK_PERIOD/2) rtc_i = 1'b0;
        end
    end
   
   assign clk_i = dut.i_host_domain.i_apb_subsystem.i_alsaqr_clk_rst_gen.clk_soc_o;

   initial begin
      s_tck = '0;
      forever
        #(REFClockPeriod/2) s_tck=~s_tck;
   end
      
    initial begin
        forever begin

            wait (exit_o[0]);

            if ((exit_o >> 1)) begin
                `uvm_error( "Core Test",  $sformatf("*** FAILED *** (tohost = %0d)", (exit_o >> 1)))
            end else begin
                `uvm_info( "Core Test",  $sformatf("*** SUCCESS *** (tohost = %0d)", (exit_o >> 1)), UVM_LOW)
            end

            $finish();
        end
    end


   initial  begin: local_jtag_preload

      logic [63:0] rdata;
      logic [32:0] addr;

      automatic dm::sbcs_t sbcs = '{
        sbautoincrement: 1'b1,
        sbreadondata   : 1'b1,
        default        : 1'b0
      };
      
      if(LOCAL_JTAG) begin

         if(!PRELOAD_HYPERRAM) begin
           if ( $value$plusargs ("CVA6_STRING=%s", binary));
             $display("Testing %s", binary);
           if ( $value$plusargs ("CL_STRING=%s", cluster_binary));
            if(cluster_binary!="none") 
              $display("Testing cluster: %s", cluster_binary);
         end 
         
        repeat(50)
            @(posedge rtc_i);
           debug_module_init();
           if(!PRELOAD_HYPERRAM) begin
              // LOAD cluster code
              if(cluster_binary!="none") 
                load_binary(cluster_binary);
              
              load_binary(binary);
              // Call the JTAG preload task
              jtag_data_preload();
           end else begin
              $display("Sanity write/read at 0x1C000000"); // word = 8 bytes here
              addr = 32'h1c000000;
              do riscv_dbg.read_dmi(dm::SBCS, sbcs);
              while (sbcs.sbbusy);
              riscv_dbg.write_dmi(dm::SBCS, sbcs);
              do riscv_dbg.read_dmi(dm::SBCS, sbcs);
              while (sbcs.sbbusy);
              riscv_dbg.write_dmi(dm::SBAddress0, addr);
              do riscv_dbg.read_dmi(dm::SBCS, sbcs);
              while (sbcs.sbbusy);         
              riscv_dbg.write_dmi(dm::SBData1, 32'hdeadcaca);
              do riscv_dbg.read_dmi(dm::SBCS, sbcs);
              while (sbcs.sbbusy);           
              riscv_dbg.write_dmi(dm::SBData0, 32'habbaabba);
              do riscv_dbg.read_dmi(dm::SBCS, sbcs);
              while (sbcs.sbbusy);  
              sbcs.sbreadonaddr = 1;
              riscv_dbg.write_dmi(dm::SBCS, sbcs);
              do riscv_dbg.read_dmi(dm::SBCS, sbcs);
              while (sbcs.sbbusy);  
              riscv_dbg.write_dmi(dm::SBAddress0, addr);
              do riscv_dbg.read_dmi(dm::SBCS, sbcs);
              while (sbcs.sbbusy);
              riscv_dbg.read_dmi(dm::SBData1, rdata[63:32]);
              // Wait until SBA is free to read another 32 bits
              do riscv_dbg.read_dmi(dm::SBCS, sbcs);
              while (sbcs.sbbusy);           
              riscv_dbg.read_dmi(dm::SBData0, rdata[32:0]);
              // Wait until SBA is free to read another 32 bits
              do riscv_dbg.read_dmi(dm::SBCS, sbcs);
              while (sbcs.sbbusy);           
              if(rdata!=64'hdeadcacaabbaabba) begin
                $fatal(1,"rdata at 0x1c000000: %x" , rdata);
              end else begin
                $display("R/W sanity check ok!");
              end
           end 
            
           #(REFClockPeriod);
           jtag_ariane_wakeup();
           jtag_read_eoc();
         end 
   end
   
  task debug_module_init;
    logic [31:0]  idcode;
    automatic dm::sbcs_t sbcs;

`ifdef POSTLAYOUT
    #(0.05 * REFClockPeriod);
`endif

    $info(" JTAG Preloading start time");
    riscv_dbg.wait_idle(300);

`ifdef POSTLAYOUT
    #(0.05 * REFClockPeriod);
`endif

    $info(" Start getting idcode of JTAG");
    riscv_dbg.get_idcode(idcode);

    // Check Idcode
    assert (idcode == dm_idcode)
    else $error(" Wrong IDCode, expected: %h, actual: %h", dm_idcode, idcode);
    $display(" IDCode = %h", idcode);

    $info(" Activating Debug Module");
    // Activate Debug Module
    riscv_dbg.write_dmi(dm::DMControl, 32'h0000_0001);

    $info(" SBA BUSY ");
    // Wait until SBA is free
    do riscv_dbg.read_dmi(dm::SBCS, sbcs);
    while (sbcs.sbbusy);
    $info(" SBA FREE");
  endtask // debug_module_init
   
   task jtag_data_preload;
    logic [63:0] rdata;

    automatic dm::sbcs_t sbcs = '{
      sbautoincrement: 1'b1,
      sbreadondata   : 1'b1,
      default        : 1'b0
    };

    $display("======== Initializing the Debug Module ========");

    debug_module_init();
    riscv_dbg.write_dmi(dm::SBCS, sbcs);
    do riscv_dbg.read_dmi(dm::SBCS, sbcs);
    while (sbcs.sbbusy);

    $display("======== Preload data to SRAM ========");

    // Start writing to SRAM
    foreach (sections[addr]) begin
      $display("Writing %h with %0d words", addr << 3, sections[addr]); // word = 8 bytes here
       riscv_dbg.write_dmi(dm::SBAddress0, (addr << 3));
       do riscv_dbg.read_dmi(dm::SBCS, sbcs);
       while (sbcs.sbbusy);
      for (int i = 0; i < sections[addr]; i++) begin
        // $info(" Loading words to SRAM ");
        $display(" -- Word %0d/%0d", i, sections[addr]);
        riscv_dbg.write_dmi(dm::SBData1, memory[addr + i][63:32]);
        do riscv_dbg.read_dmi(dm::SBCS, sbcs);
        while (sbcs.sbbusy);           
        riscv_dbg.write_dmi(dm::SBData0, memory[addr + i][32:0]);
        // Wait until SBA is free to write next 32 bits
        do riscv_dbg.read_dmi(dm::SBCS, sbcs);
        while (sbcs.sbbusy);
      end
    end

    // Check loaded data
    if (CHECK_LOCAL_JTAG) begin
      $display("======== Checking loaded data ========");
      // Set SBCS register to read data
      sbcs.sbreadonaddr = 1;
      riscv_dbg.write_dmi(dm::SBCS, sbcs);
      foreach (sections[addr]) begin
        $display(" Checking %h", addr << 3);
        riscv_dbg.write_dmi(dm::SBAddress0, (addr << 3));
        for (int i = 0; i < sections[addr]; i++) begin
          riscv_dbg.read_dmi(dm::SBData1, rdata[63:32]);
          // Wait until SBA is free to read another 32 bits
          do riscv_dbg.read_dmi(dm::SBCS, sbcs);
          while (sbcs.sbbusy);           
          riscv_dbg.read_dmi(dm::SBData0, rdata[32:0]);
          // Wait until SBA is free to read another 32 bits
          do riscv_dbg.read_dmi(dm::SBCS, sbcs);
          while (sbcs.sbbusy);
          if (rdata != memory[addr + i])
            $error("Mismatch detected at %h, expected %0d, actual %0d",
              (addr + i) << 3, memory[addr + 1], rdata);
        end
      end
    end

    $display("======== Preloading finished ========");

    // Preloading finished. Can now start executing
    sbcs.sbreadonaddr = 0;
    sbcs.sbreadondata = 0;
    riscv_dbg.write_dmi(dm::SBCS, sbcs);

  endtask // jtag_data_preload


  // Load ELF binary file
  task load_binary;
    input string binary;                   // File name
    addr_t       section_addr, section_len;
    byte         buffer[];
    // Read ELF
    void'(read_elf(binary));
    $display("Reading %s", binary);
    while (get_section(section_addr, section_len)) begin
      // Read Sections
      automatic int num_words = (section_len + AxiWideBeWidth - 1)/AxiWideBeWidth;
      $display("Reading section %x with %0d words", section_addr, num_words);

      sections[section_addr >> AxiWideByteOffset] = num_words;
      buffer                                      = new[num_words * AxiWideBeWidth];
      void'(read_section(section_addr, buffer));
      for (int i = 0; i < num_words; i++) begin
        automatic logic [AxiWideBeWidth-1:0][7:0] word = '0;
        for (int j = 0; j < AxiWideBeWidth; j++) begin
          word[j] = buffer[i * AxiWideBeWidth + j];
        end
        memory[section_addr/AxiWideBeWidth + i] = word;
      end
    end

  endtask // load_binary

  
  task jtag_ariane_wakeup;

    $info("======== Waking up Ariane using JTAG ========");
    // Generate the interrupt
    riscv_dbg.write_dmi(dm::DMControl, 32'h0000_0003);

    # 150ns; 
     
    riscv_dbg.write_dmi(dm::DMControl, 32'h0000_0001);
    // Wait till end of computation
    program_loaded = 1;

    // When task completed reading the return value using JTAG
    // Mainly used for post synthesis part
    $info("======== Wait for Completion ========");

  endtask // execute_application

  task jtag_read_eoc;

    automatic dm::sbcs_t sbcs = '{
      sbautoincrement: 1'b1,
      sbreadondata   : 1'b1,
      default        : 1'b0
    };

    // Initialize the dm module again, otherwise it will not work
    debug_module_init();
    sbcs.sbreadonaddr = 1;
    sbcs.sbautoincrement = 0;
    riscv_dbg.write_dmi(dm::SBCS, sbcs);
    do riscv_dbg.read_dmi(dm::SBCS, sbcs);
    while (sbcs.sbbusy);

    riscv_dbg.write_dmi(dm::SBAddress0, 32'h8000_1000); // tohost address
    riscv_dbg.wait_idle(10);
    do begin 
       riscv_dbg.read_dmi(dm::SBData0, retval);
       # 100ns;
    end while (~retval[0]);
     

    if (retval[31:1]!=0) begin
        `uvm_error( "Core Test",  $sformatf("*** FAILED *** (tohost = %0d)",retval[31:1]))
    end else begin
        `uvm_info( "Core Test",  $sformatf("*** SUCCESS *** (tohost = %0d)", (retval[31:1])), UVM_LOW)
    end

     $finish;
     
  endtask // jtag_read_eoc

endmodule // ariane_tb

