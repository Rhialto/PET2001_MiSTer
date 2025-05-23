/*
 * Commodore 4040/8250 IEEE drive implementation
 *
 * Copyright (C) 2024, Erik Scheffers (https://github.com/eriks5)
 *
 * This file is part of CBM-II_MiSTer.
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by
 * the Free Software Foundation, version 2.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */
 
 module ieee_drive #(
	parameter DRIVES=1,
	parameter SUBDRV=2
)
(
        input       [31:0] CLK,

	input              clk_sys,    // which is CLK Hz
        input              clk_main,   // used for output buffering bus_o_*
	input       [ND:0] reset,

	input              pause,

	//output      [ND:0] led,
	output       [NS:0] led_act[NDR],
	output       [ND:0] led_err,

        /* Vivado seems too stupid to interoperate this with VHDL
        input  st_ieee_bus bus_i,
        output st_ieee_bus bus_o, */
        /* bus_i_* and bus_o_* are in the clk_main clock domain */
        input              bus_i_atn ,
        input              bus_i_eoi ,
        input              bus_i_srq ,
        input              bus_i_ren ,
        input              bus_i_ifc ,
        input              bus_i_dav ,
        input              bus_i_ndac,
        input              bus_i_nrfd,
        input  [7:0]       bus_i_data,

        output             bus_o_atn ,
        output             bus_o_eoi ,
        output             bus_o_srq ,
        output             bus_o_ren ,
        output             bus_o_ifc ,
        output             bus_o_dav ,
        output             bus_o_ndac,
        output             bus_o_nrfd,
        output [7:0]       bus_o_data,


	input       [ND:0] drv_type,                    // clk_main core clock domain

	input       [NB:0] img_mounted,                 // clk_main core clock domain
	input       [31:0] img_size,                    // clk_main core clock domain
	input              img_readonly,                // clk_main core clock domain

	output      [31:0] sd_lba[NBD],
	output       [5:0] sd_blk_cnt[NBD],
	output      [NB:0] sd_rd,
	output      [NB:0] sd_wr,
	input       [NB:0] sd_ack,
	input       [12:0] sd_buff_addr,
	input        [7:0] sd_buff_dout,
	output       [7:0] sd_buff_din[NBD],
	input              sd_buff_wr,

	input              rom_wr,
	input              rom_sel,
	input       [14:0] rom_addr,
	input        [7:0] rom_data
);

localparam NDR = (DRIVES < 1) ? 1 : (DRIVES > 4) ? 4 : DRIVES;  // number of drives
localparam NSD = (SUBDRV < 1) ? 1 : (SUBDRV > 2) ? 2 : SUBDRV;  // number of subunits per drive
localparam NBD = NDR*NSD;                                       // number of block devices

localparam ND  = NDR - 1;
localparam NS  = NSD - 1;
localparam NB  = NBD - 1;

reg ce;
always @(posedge clk_sys) begin
	int sum = 0;

	ce <= 0;
	sum = sum + 16_000_000;
	if(sum >= CLK) begin
		sum = sum - CLK;
		ce <= 1;
	end
end

reg [NB:0] img_loaded_main;
reg [NB:0] img_readonly_l_main;
reg  [1:0] img_type_main[NBD];

reg [NB:0] img_loaded;
reg [NB:0] img_readonly_l;
reg  [1:0] img_type[NBD];

/*
 * I would have preferred to have a single ieeedrv_sync for the whole lot
 * of {img_loaded_main, img_readonly_l_main, img_type_main} but I could not
 * find out how to tell this to Vivado. The obvious thing did not work.
 */
ieeedrv_img_sync #(NBD) img_sync(
    .clk(clk_sys),
    .in1( img_loaded_main), .in2( img_readonly_l_main), .in3( img_type_main),
    .out1(img_loaded     ), .out2(img_readonly_l     ), .out3(img_type     )
);

// Changed from clk_sys to clk_main plus the ieeedrv_img_sync.
always @(posedge clk_main)
	for(int i=0; i<NBD; i=i+1)
		if (img_mounted[i]) begin
			img_loaded_main[i]     <= |img_size;
			// i >> NS only works for NS=0 or NS=1; should be log2(NSD)
			img_type_main[i]       <= {drv_type[i >> NS], img_size[31:8] >= 4166};
			img_readonly_l_main[i] <= img_readonly;
		end

/*
 * img_mounted is also used in several places inside the drive.
 * Since it is a short pulse, let's make sure it is long enough to survive
 * the clock domain crossing.
 */
wire [NB:0] img_mounted_str;    /* stretched signal in clk_main domain */
wire [NB:0] img_mounted_s;      /* synced signal in clk_sys domain */

ieeedrv_stretch #(NBD) img_mounted_stretch(clk_main, img_mounted, img_mounted_str);
ieeedrv_sync #(NBD) img_mounted_sync(clk_sys, img_mounted_str, img_mounted_s);

wire [NB:0] drv_type_s;         /* synced signal in clk_sys domain */
ieeedrv_sync #(NBD) drv_type_sync(clk_sys, drv_type, drv_type_s);

st_ieee_bus drv_bus_i;
st_ieee_bus drv_bus_o[NDR];
st_ieee_bus drv_bus[NDR];

st_ieee_bus bus_i;
assign bus_i.atn  = bus_i_atn ;
assign bus_i.eoi  = bus_i_eoi ;
assign bus_i.srq  = bus_i_srq ;
assign bus_i.ren  = bus_i_ren ;
assign bus_i.ifc  = bus_i_ifc ;
assign bus_i.dav  = bus_i_dav ;
assign bus_i.ndac = bus_i_ndac;
assign bus_i.nrfd = bus_i_nrfd;
assign bus_i.data = bus_i_data;

ieeedrv_bus_sync bus_sync(clk_sys, bus_i, drv_bus_i);

//wire [NS:0] led_act[NDR];
//wire [ND:0] led_err;
//wire        blink_err = err_count[21];
//
//reg [21:0] err_count;
//always @(posedge clk_sys) begin
//	// when led_err is high, blink MiSTer led
//	if (ce) begin
//		if (|led_err)
//			err_count <= err_count + 1'd1;
//		else
//			err_count <= '1;
//	end
//end

st_ieee_bus bus_o;
assign bus_o = drv_bus[NDR-1];

st_ieee_bus main_bus_o;         /* clk_main clock domain */
ieeedrv_bus_sync bus_sync_o(clk_main, bus_o, main_bus_o);

assign bus_o_atn  = main_bus_o.atn ;
assign bus_o_eoi  = main_bus_o.eoi ;
assign bus_o_srq  = main_bus_o.srq ;
assign bus_o_ren  = main_bus_o.ren ;
assign bus_o_ifc  = main_bus_o.ifc ;
assign bus_o_dav  = main_bus_o.dav ;
assign bus_o_ndac = main_bus_o.ndac;
assign bus_o_nrfd = main_bus_o.nrfd;
assign bus_o_data = main_bus_o.data;



// ====================================================================
// Clock
// ====================================================================

reg ph2_r;
reg ph2_f;
always @(posedge clk_sys) begin
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

// ====================================================================
// DOS ROM
// ====================================================================

wire [13:0] dos_addr[NDR];
wire  [7:0] dos_data[NDR], dos4040_data, dos8250_data;

wire  [1:0] dos_select;
wire [13:0] dos_rom_addr;

// ieeedrv_rom #(8,14,16384,"rtl/ieee_drive/roms/c4040_dos.mif") c4040_dos_rom
// Relative to PET_MEGA65/CORE/CORE-R6.runs/synth_1 (or sth.)
ieeedrv_rom #(8,14,16384,"../../PET2001_MiSTer/rtl/ieee_drive/roms/c4040_dos.hex") c4040_dos_rom
(
   .clock_a(clk_sys),
   .address_a(dos_rom_addr),
   .q_a(dos4040_data),

	.clock_b(clk_sys),
	.wren_b(rom_wr && rom_sel && !rom_addr[14]),
	.address_b(rom_addr[13:0]),
	.data_b(rom_data)
);

//ieeedrv_rom #(8,14,16384,"rtl/ieee_drive/roms/c8250_dos.mif") c8250_dos_rom
// Relative to PET_MEGA65/CORE/CORE-R6.runs/synth_1 (or sth.)
ieeedrv_rom #(8,14,16384,"../../PET2001_MiSTer/rtl/ieee_drive/roms/c8250_dos.hex") c8250_dos_rom
(
   .clock_a(clk_sys),
   .address_a(dos_rom_addr),
   .q_a(dos8250_data),

	.clock_b(clk_sys),
	.wren_b(rom_wr && !rom_sel && !rom_addr[14]),
	.address_b(rom_addr[13:0]),
	.data_b(rom_data)
);

ieee_rommux #(NDR,14) dos_rom_mux (
	.clk(clk_sys),
	.ph2(ph2_f),
	.drv_addr(dos_addr),
	.drv_select(dos_select),
	.rom_addr(dos_rom_addr),
	.rom_q(drv_type_s[dos_select] ? dos4040_data : dos8250_data),
	.drv_data(dos_data)
);

reg c4040_dos_16k = 0;
always @(posedge clk_sys) begin
	if (rom_wr && rom_sel && !rom_addr)
		c4040_dos_16k <= 0;

	if (rom_wr && rom_sel && ~|rom_addr[14:12] && |rom_data && ~&rom_data)
		c4040_dos_16k <= 1;
end

// ====================================================================
// Controller ROM
// ====================================================================

wire [10:0] ctl_addr[NDR];
wire  [7:0] ctl_data[NDR], ctl4040_data, ctl8250_data;

wire  [1:0] ctl_select;
wire [10:0] ctl_rom_addr;

//ieeedrv_rom #(8,11,2048,"rtl/ieee_drive/roms/c4040_ctl.mif") c4040_controller_rom
// Relative to PET_MEGA65/CORE/CORE-R6.runs/synth_1 (or sth.)
ieeedrv_rom #(8,11,2048,"../../PET2001_MiSTer/rtl/ieee_drive/roms/c4040_ctl.hex") c4040_controller_rom
(
   .clock_a(clk_sys),
   .address_a(ctl_rom_addr),
   .q_a(ctl4040_data),

	.clock_b(clk_sys),
	.wren_b(rom_wr && rom_sel && rom_addr[14:11] == 'b1000),
	.address_b(rom_addr[10:0]),
	.data_b(rom_data)
);

//ieeedrv_rom #(8,11,2048,"rtl/ieee_drive/roms/c8250_ctl.mif") c8250_controller_rom
// Relative to PET_MEGA65/CORE/CORE-R6.runs/synth_1 (or sth.)
ieeedrv_rom #(8,11,2048,"../../PET2001_MiSTer/rtl/ieee_drive/roms/c8250_ctl.hex") c8250_controller_rom
(
   .clock_a(clk_sys),
   .address_a(ctl_rom_addr),
   .q_a(ctl8250_data),

	.clock_b(clk_sys),
	.wren_b(rom_wr && !rom_sel && rom_addr[14:11] == 'b1000),
	.address_b(rom_addr[10:0]),
	.data_b(rom_data)
);

ieee_rommux #(NDR,11) controller_rom_mux (
	.clk(clk_sys),
	.ph2(ph2_r),
	.drv_addr(ctl_addr),
	.drv_select(ctl_select),
	.rom_addr(ctl_rom_addr),
	.rom_q(drv_type_s[ctl_select] ? ctl4040_data : ctl8250_data),
	.drv_data(ctl_data)
);

generate
	genvar d;
	for (d=0; d<NDR; d=d+1) begin :drive
		assign drv_bus[d] = d==0 ? drv_bus_o[d] : drv_bus_o[d] & drv_bus[d-1];
		//assign led[d] = |led_act[d] | (led_err[d] & blink_err);

		localparam I0 = d*NSD;
		localparam I1 = d*NSD+NS;

		ieeedrv_drv drv
		(
			.CLK(CLK),
			.ce(ce),
			.ph2_f(ph2_f),
			.ph2_r(ph2_r),

			.clk_sys(clk_sys),
			.reset(reset[d] | rom_wr),

			.dev_id(3'(d)),
			.bus_i(drv_bus_i & bus_o),
			.bus_o(drv_bus_o[d]),

			.led_act(led_act[d]),
			.led_err(led_err[d]),

			.drv_type(drv_type_s[d]),
			.dos_16k(c4040_dos_16k | ~drv_type_s[d]),

			.dos_addr(dos_addr[d]),
			.dos_data(dos_data[d]),
			.ctl_addr(ctl_addr[d]),
			.ctl_data(ctl_data[d]),

			.img_mounted(img_mounted_s[I1:I0]),
			.img_loaded(img_loaded[I1:I0]),
			.img_readonly(img_readonly_l[I1:I0]),
			.img_type(img_type[I0:I1]),

			.sd_lba(sd_lba[I0:I1]),
			.sd_blk_cnt(sd_blk_cnt[I0:I1]),
			.sd_rd(sd_rd[I1:I0]),
			.sd_wr(sd_wr[I1:I0]),
			.sd_ack(sd_ack[I1:I0]),
			.sd_buff_addr(sd_buff_addr),
			.sd_buff_dout(sd_buff_dout),
			.sd_buff_din(sd_buff_din[I0:I1]),
			.sd_buff_wr(sd_buff_wr)
		);
	end
endgenerate

endmodule
