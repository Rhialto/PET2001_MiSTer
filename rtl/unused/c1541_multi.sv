//-------------------------------------------------------------------------------
//
// C1541 multi-drive implementation with shared ROM
// (C) 2021 Alexey Melnikov
//
// Input clock/ce 16MHz
//
// MEGA65 port by sy2002 in 2022 and 2023:
//
// Real support, incl. CDC for two different clocks: "clk" (aka "main") is the
// core and "clk_sys" is used to write to the RAMs/ROMs and for the SD card
// handling. Changed to registering the clk_sys at the negative clock edge 
// as QNICE works like this.
//
// Adjusted for 2031 (IEEE-488) option by Olaf 'Rhialto' Seibert, 2024.
//-------------------------------------------------------------------------------


module c1541_multi #(parameter IEEE=1,PARPORT=0,DUALROM=0,DRIVES=2)
(
    //clk ports
    input         clk,
    input   [N:0] reset,
    input         ce,

    input         pause,
    input   [N:0] gcr_mode,

    input   [N:0] img_mounted,
    input         img_readonly,
    input  [31:0] img_size,

    output  [N:0] led,

    input         iec_atn_i,
    input         iec_data_i,
    input         iec_clk_i,
    output        iec_data_o,
    output        iec_clk_o,

    // parallel bus
    input   [7:0] par_data_i,
    input         par_stb_i,
    output reg [7:0] par_data_o,
    output        par_stb_o,

    // IEEE-488 port
    input   [7:0] ieee_data_i,      // could re-use the above par port?
    output  reg [7:0] ieee_data_o,
    input         ieee_atn_i,
    output        ieee_atn_o,
    input         ieee_ifc_i,
    output        ieee_srq_o,
    input         ieee_dav_i,
    output        ieee_dav_o,
    input         ieee_eoi_i,
    output        ieee_eoi_o,
    input         ieee_nrfd_i,
    output        ieee_nrfd_o,
    input         ieee_ndac_i,
    output        ieee_ndac_o,

    //clk_sys ports
    input         clk_sys,

    output [31:0] sd_lba[NDR],
    output  [5:0] sd_blk_cnt[NDR],
    output  [N:0] sd_rd,
    output  [N:0] sd_wr,
    input   [N:0] sd_ack,
    input  [13:0] sd_buff_addr,
    input   [7:0] sd_buff_dout,
    output  [7:0] sd_buff_din[NDR],
    input         sd_buff_wr,

   // clk_sys clock domain
    input  [14:0] rom_addr_i,
    input   [7:0] rom_data_i,
    output  [7:0] rom_data_o,
    input         rom_wr_i,

    // clk clock domain
    input         rom_std_i
);

initial begin
    if (IEEE && PARPORT) begin
        $error("Impossible parameter combination. IEEE and PARPORT can not both be true.");
    end;
end;

localparam NDR = (DRIVES < 1) ? 1 : (DRIVES > 4) ? 4 : DRIVES;
localparam N   = NDR - 1;

wire iec_atn, iec_data, iec_clk;
iecdrv_sync atn_sync(clk, iec_atn_i,  iec_atn);
iecdrv_sync dat_sync(clk, iec_data_i, iec_data);
iecdrv_sync clk_sync(clk, iec_clk_i,  iec_clk);

wire [N:0] reset_drv;
iecdrv_sync #(NDR) rst_sync(clk, reset, reset_drv);

// IEEE-488 bus
wire   [7:0] ieee_data;
wire         ieee_atn, ieee_ifc, ieee_srq, ieee_dav, ieee_eoi, ieee_nrfd, ieee_ndac;
iecdrv_sync #(8) data_sync(clk, ieee_data_i, ieee_data);
iecdrv_sync atn488_sync(clk, ieee_atn_i, ieee_atn);
iecdrv_sync  ifc_sync(clk, ieee_ifc_i, ieee_ifc);
iecdrv_sync  dav_sync(clk, ieee_dav_i, ieee_dav);
iecdrv_sync  eoi_sync(clk, ieee_eoi_i, ieee_eoi);
iecdrv_sync nrfd_sync(clk, ieee_nrfd_i, ieee_nrfd);
iecdrv_sync ndac_sync(clk, ieee_ndac_i, ieee_ndac);

// These collect the outputs from the NDR drives and AND them.
wire   [7:0] ieee_data_d[NDR];
wire   [N:0] ieee_atn_d, ieee_srq_d, ieee_dav_d, ieee_eoi_d, ieee_nrfd_d, ieee_ndac_d;

always_comb begin
    ieee_data_o = 8'hFF;
    for(int i=0; i<NDR; i=i+1) ieee_data_o = ieee_data_o & ieee_data_d[i];
end
assign     ieee_atn_o  = &{ieee_atn_d | reset_drv};	// is this correct?
assign     ieee_srq_o  = &{ieee_srq_d | reset_drv};	// is this correct?
assign     ieee_dav_o  = &{ieee_dav_d | reset_drv};
assign     ieee_eoi_o  = &{ieee_eoi_d | reset_drv};
assign     ieee_nrfd_o = &{ieee_nrfd_d | reset_drv};
assign     ieee_ndac_o = &{ieee_ndac_d | reset_drv};

wire stdrom = (DUALROM || PARPORT) ? rom_std_i : 1'b1;

assign rom_data_o = (DUALROM || PARPORT) ? qnice_rom2_do : qnice_rom1_do;

reg ph2_r;
reg ph2_f;
always @(posedge clk) begin
    reg [3:0] div;
    reg       ena, ena1;

    ena1 <= ~pause;
    if(div[2:0]) ena <= ena1;

    ph2_r <= 0;
    ph2_f <= 0;
    if(ce) begin
        div <= div + 1'd1;
        ph2_r <= ena && !div[3] && !div[2:0];
        ph2_f <= ena &&  div[3] && !div[2:0];
    end
end

reg rom_32k_i;
reg rom_16k_i;
reg empty8k;

initial begin
    rom_32k_i = 1'b1;
    rom_16k_i = 1'b1;
    empty8k   = 1'b1;
end

//negedge because of QNICE
always @(negedge clk_sys) begin
    if (rom_wr_i & !rom_addr_i) empty8k = 1;
    if (rom_wr_i & |rom_data_i & ~&rom_data_i) begin
        {rom_32k_i,rom_16k_i} <= rom_addr_i[14:13];
        if(rom_addr_i[14:8] && !rom_addr_i[14:13]) empty8k = 0;
    end
end

reg [1:0] rom_sz;
always @(negedge clk_sys) rom_sz <= {rom_32k_i,rom_32k_i|rom_16k_i}; // support for 8K/16K/32K ROM, negedge because of QNICE

//rom_32k_i, rom16k_i, empty8k amd rom_sz are in the QNICE clock domain ("clk_sys"); we need to convert them into the main (core clk aka "clk") domain
wire rom32k_main, rom16k_main, empty8k_main;
wire [1:0] rom_sz_main;
xpm_cdc_array_single #(
   .WIDTH(5)
) cdc_qnice2main (
   .src_clk(clk_sys),
   .src_in({empty8k, rom_16k_i, rom_32k_i, rom_sz}),
   .dest_clk(clk),
   .dest_out({empty8k_main, rom16k_main, rom32k_main, rom_sz_main})
);

wire [7:0] rom_do;
wire [7:0] qnice_rom2_do;
generate
    if(PARPORT && ! IEEE) begin
        iecdrv_mem_rom #(
           .DATAWIDTH(8),
           .ADDRWIDTH(15),
           .INITFILE("../../PET2001_MiSTer/rtl/ieee488_drive/c1541_dolphin.mif.hex"),
           .FALLING_A(1'b1)
        ) rom (
            .clock_a(clk_sys),
            .address_a(rom_addr_i),
            .data_a(rom_data_i),
            .wren_a(rom_wr_i),
            .q_a(qnice_rom2_do),

            .clock_b(clk),
            .address_b(mem_a),
            .q_b(rom_do)
        );
    end
    else if(DUALROM) begin
      iecdrv_mem_rom #(
         .DATAWIDTH(8),
         .ADDRWIDTH(14),
         .FALLING_A(1'b1)
      ) rom (
         .clock_a(clk_sys),
         .address_a(rom_addr_i[13:0]),
         .data_a(rom_data_i),
         .wren_a(rom_wr_i),
         .q_a(qnice_rom2_do),

         .clock_b(clk),
         .address_b(mem_a[13:0]),
         .q_b(rom_do)
      );
    end
    else begin
        assign rom_do = romstd_do;
    end
endgenerate

wire [7:0] romstd_do;
wire [7:0] qnice_rom1_do;
iecdrv_mem_rom #(
   .DATAWIDTH(8),
   .ADDRWIDTH(14),
   // Relative to PET_MEGA65/CORE/CORE-R6.runs/synth_1 (or sth.)
   .INITFILE(IEEE ? "../../PET2001_MiSTer/rtl/ieee488_drive/c2031.hex"
                  : "../../C64_MiSTerMEGA65/rtl/iec_drive/c1541_rom.mif.hex"),
   .FALLING_A(1'b1)
) romstd (
    .clock_a(clk_sys),
    .address_a(rom_addr_i[13:0]),
    .data_a(rom_data_i),
    .wren_a((DUALROM || PARPORT) ? 1'b0 : rom_wr_i),
    .q_a(qnice_rom1_do),

    .clock_b(clk),
    .address_b(mem_a[13:0]),
    .q_b(romstd_do)
);

reg  [14:0] mem_a;
wire [14:0] drv_addr[NDR];
reg   [7:0] drv_data[4];
always @(posedge clk) begin
    reg [2:0] state;
    reg [14:0] mem_d;

    if(~&state) state <= state + 1'd1;
    if(ph2_f)   state <= 0;

    case(state)
        0,1,2,3: mem_a <= {drv_addr[state[1:0]][14] & rom_sz_main[1], drv_addr[state[1:0]][13] & (rom_sz_main[0] | stdrom), drv_addr[state[1:0]][12:0]};
    endcase

    case(state)
        3,4,5,6: drv_data[state[1:0] - 2'd3] <= stdrom ? romstd_do : rom_do;
    endcase
end

wire [N:0] iec_data_d, iec_clk_d;
assign     iec_clk_o  = &{iec_clk_d  | reset_drv};
assign     iec_data_o = &{iec_data_d | reset_drv};

wire [N:0] ext_en = {NDR{rom_sz_main[1] & empty8k_main & ~stdrom & |PARPORT}} & ~reset_drv;
wire [7:0] par_data_d[NDR];
wire [N:0] par_stb_d;
assign     par_stb_o = &{par_stb_d | ~ext_en};
always_comb begin
    par_data_o = 8'hFF;
    for(int i=0; i<NDR; i=i+1) if(ext_en[i]) par_data_o = par_data_o & par_data_d[i];
end

wire [N:0] led_drv;
assign     led = led_drv & ~reset_drv;

generate
    genvar i;
    for(i=0; i<NDR; i=i+1) begin :drives
        c1541_drv c1541_drv
        (
            .clk(clk),
            .reset(reset_drv[i]),

            .gcr_mode(gcr_mode[i]),

            .ce(ce),
            .ph2_r(ph2_r),
            .ph2_f(ph2_f),

            .img_mounted(img_mounted[i]),
            .img_readonly(img_readonly),
            .img_size(img_size),

            .drive_num(i),
            .led(led_drv[i]),

            .iec_atn_i(iec_atn),
            .iec_data_i(iec_data & iec_data_o),
            .iec_clk_i(iec_clk & iec_clk_o),
            .iec_data_o(iec_data_d[i]),
            .iec_clk_o(iec_clk_d[i]),

            .par_data_i(par_data_i),
            .par_stb_i(par_stb_i),
            .par_data_o(par_data_d[i]),
            .par_stb_o(par_stb_d[i]),

            // IEEE-488 port
            .ieee_data_i(ieee_data /*& ieee_data_o*/),
            .ieee_data_o(ieee_data_d[i]),
            .ieee_atn_i (ieee_atn & ieee_atn_o),
            .ieee_atn_o (ieee_atn_d[i]),
            .ieee_ifc_i (ieee_ifc),
            .ieee_srq_o (ieee_srq_d[i]),
            .ieee_dav_i (ieee_dav & ieee_dav_o),
            .ieee_dav_o (ieee_dav_d[i]),
            .ieee_eoi_i (ieee_eoi & ieee_eoi_o),
            .ieee_eoi_o (ieee_eoi_d[i]),
            .ieee_nrfd_i(ieee_nrfd & ieee_nrfd_o),
            .ieee_nrfd_o(ieee_nrfd_d[i]),
            .ieee_ndac_i(ieee_ndac & ieee_ndac_o),
            .ieee_ndac_o(ieee_ndac_d[i]),

            .ext_en(IEEE ? 1'b0 : ext_en[i]),
            .rom_addr(drv_addr[i]),
            .rom_data(drv_data[i]),

            .clk_sys(clk_sys),

            .sd_lba(sd_lba[i]),
            .sd_blk_cnt(sd_blk_cnt[i]),
            .sd_rd(sd_rd[i]),
            .sd_wr(sd_wr[i]),
            .sd_ack(sd_ack[i]),
            .sd_buff_addr(sd_buff_addr),
            .sd_buff_dout(sd_buff_dout),
            .sd_buff_din(sd_buff_din[i]),
            .sd_buff_wr(sd_buff_wr)
        );
    end
endgenerate

endmodule
