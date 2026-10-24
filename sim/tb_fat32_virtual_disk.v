`timescale 1ns/1ps
module tb_fat32_virtual_disk #(parameter PRODUCT_MODE=0);
    reg clk=0,rst=1,sd_ready=0,logical_read=0;
    always #5 clk=~clk;
    reg [31:0] logical_addr=0;
    wire logical_valid,logical_end,ready,fat_mode,mapping_fault;
    wire [7:0] logical_data;
    wire [31:0] virtual_last,physical_addr;
    wire [31:0] list_base,list_bytes,text_base,text_bytes;
    wire physical_read;
    reg physical_valid=0,physical_end=0;
    reg [7:0] physical_data=0;
    reg [7:0] disk [0:8191];
    reg busy=0;
    reg request_seen=0;
    reg [31:0] selected_sector=0;
    reg [8:0] byte_index=0;
    integer i,received;
    integer mapped_sector;
    integer fault_count=0;
    reg [7:0] first,last;

    fat32_virtual_disk #(.FAT32_ONLY(PRODUCT_MODE), .ENABLE_TEXT(!PRODUCT_MODE)) dut (
        .clk(clk),.rst(rst),.sd_ready(sd_ready),
        .logical_read(logical_read),.logical_addr(logical_addr),
        .logical_valid(logical_valid),.logical_data(logical_data),
        .logical_end(logical_end),.ready(ready),.fat_mode(fat_mode),
        .mapping_fault(mapping_fault),
        .virtual_last(virtual_last),.physical_read(physical_read),
        .list_base(list_base),.list_bytes(list_bytes),
        .text_base(text_base),.text_bytes(text_bytes),
        .physical_addr(physical_addr),.physical_valid(physical_valid),
        .physical_data(physical_data),.physical_end(physical_end)
    );

    task put16;
        input integer addr; input [15:0] value;
        begin disk[addr]=value[7:0];disk[addr+1]=value[15:8];end
    endtask
    task put32;
        input integer addr; input [31:0] value;
        begin put16(addr,value[15:0]);put16(addr+2,value[31:16]);end
    endtask
    task entry;
        input integer offset; input [87:0] name;
        input [31:0] cluster,size;
        integer j;
        begin
            for(j=0;j<11;j=j+1)disk[2*512+offset+j]=name[(10-j)*8 +:8];
            disk[2*512+offset+11]=8'h20;
            put16(2*512+offset+20,cluster[31:16]);
            put16(2*512+offset+26,cluster[15:0]);
            put32(2*512+offset+28,size);
        end
    endtask
    task sector;
        input [31:0] addr; input [7:0] first_expected,last_expected;
        begin
            @(negedge clk);logical_addr=addr;logical_read=1;
            received=0;first=0;last=0;
            wait(logical_end);
            @(posedge clk);
            @(negedge clk);logical_read=0;
            if(received!=512 || first!==first_expected || last!==last_expected)
                $fatal(1,"virtual %0d got count=%0d first=%h last=%h expected=%h/%h",
                       addr,received,first,last,first_expected,last_expected);
            repeat(3) @(negedge clk);
        end
    endtask
    always @(negedge clk) begin
        physical_valid = 0;
        physical_end = 0;
        if(!physical_read) request_seen = 0;
        if(rst || !sd_ready) busy = 0;
        else if(!busy && physical_read && !request_seen) begin
            busy = 1;
            request_seen = 1;
            selected_sector = physical_addr;
            byte_index = 0;
        end else if(busy) begin
            physical_valid = 1;
            mapped_sector = selected_sector >= 32'd200000 ?
                            selected_sector - 32'd199999 : selected_sector;
            physical_data = disk[mapped_sector*512+byte_index];
            if(byte_index==511) begin
                physical_end = 1;
                busy = 0;
            end else byte_index = byte_index+1'b1;
        end
    end
    always @(posedge clk) begin
        if(logical_valid) begin
            if(received==0)first=logical_data;
            last=logical_data;
            received=received+1;
        end
        if(mapping_fault) fault_count=fault_count+1;
    end
    initial begin
        for(i=0;i<8192;i=i+1)disk[i]=0;
        disk[0]=8'heb; put16(11,512);disk[13]=1;
        put16(14,1);disk[16]=1;put32(32,16);
        put32(36,1);put32(44,2);
        disk[510]=8'h55;disk[511]=8'haa;
        put32(512+2*4,32'h0fffffff); // Root directory ends.
        put32(512+3*4,5); // BMP 1 is fragmented: cluster 3 then 5.
        put32(512+4*4,32'h0fffffff);
        put32(512+5*4,32'h0fffffff);
        put32(512+6*4,32'h0fffffff);
        put32(512+7*4,8);            // PLAYLIST.TXT 分两簇：7 然后 8。
        put32(512+8*4,32'h0fffffff);
        put32(512+9*4,32'h0fffffff);
        entry(0,"PIC1    BMP",3,1024);
        entry(32,"PIC2    BMP",4,512);
        entry(64,"MUSIC   WAV",6,512);
        entry(96,"PLAYLISTTXT",7,600);
        entry(128,"TEXT    TXT",9,100);
        disk[2*512+160]=0;
        disk[3*512]=8'h42;disk[3*512+511]=8'h31;
        disk[5*512]=8'h43;disk[5*512+511]=8'h35;
        disk[4*512]=8'h44;disk[4*512+511]=8'h34;
        disk[6*512]=8'h52;disk[6*512+511]=8'h36;
        disk[7*512]=8'ha1;disk[7*512+511]=8'ha2;
        disk[8*512]=8'ha3;disk[8*512+511]=8'ha4;
        disk[9*512]=8'hb1;disk[9*512+511]=8'hb2;
        repeat(3) @(negedge clk);rst=0;sd_ready=1;
        wait(ready);#1;
        if(!fat_mode || virtual_last<3)
            $fatal(1,"FAT32 index not activated");
        sector(0,8'h42,8'h31);
        sector(1,8'h43,8'h35);
        sector(2,8'h44,8'h34);
        sector(3,8'h52,8'h36);
        // 配置文件排在三个媒体文件之后，槽位由 virtual 空间决定
        if(list_bytes!=32'd600 || text_bytes!=(PRODUCT_MODE ? 32'd0 : 32'd100))
            $fatal(1,"config sizes wrong: list=%0d text=%0d",list_bytes,text_bytes);
        if(list_base!=32'd4 || (!PRODUCT_MODE && text_base!=32'd6))
            $fatal(1,"config bases wrong: list=%0d text=%0d",list_base,text_base);
        sector(4,8'ha1,8'ha2);
        sector(5,8'ha3,8'ha4);
        if (!PRODUCT_MODE) sector(6,8'hb1,8'hb2);
        sector(1,8'h43,8'h35); // Random access after another file.
        sector(2,8'h44,8'h34); // Evict the first file's cached FAT cluster.
        put32(512+3*4,32'h0fffffff);
        sector(1,8'h00,8'h00);
        if(fault_count!=1)
            $fatal(1,"early FAT end must raise one mapping fault");

        rst=1;sd_ready=0;
        put32(512+3*4,5);
        for(i=7*512-1;i>=0;i=i-1)disk[i+512]=disk[i];
        for(i=0;i<512;i=i+1)disk[i]=0;
        disk[510]=8'h55;disk[511]=8'haa;
        disk[450]=8'h0c;put32(454,32'd200000);
        put32(2*512+2*4,7); // Root starts at cluster 2, continues at cluster 7.
        put32(2*512+7*4,32'h0fffffff);
        for(i=0;i<512;i=i+1)disk[3*512+i]=0;
        for(i=0;i<16;i=i+1)disk[3*512+i*32]="X";
        // The root directory continues in cluster 7.
        for(i=0;i<512;i=i+1)disk[8*512+i]=0;
        disk[8*512+0]="P";disk[8*512+1]="I";disk[8*512+2]="C";
        disk[8*512+3]="1";
        for(i=4;i<8;i=i+1)disk[8*512+i]=" ";
        disk[8*512+8]="B";disk[8*512+9]="M";disk[8*512+10]="P";
        disk[8*512+11]=8'h20;
        put16(8*512+26,3);put32(8*512+28,1024);
        disk[8*512+32]=0;
        repeat(3) @(negedge clk);rst=0;sd_ready=1;
        wait(ready);#1;
        if(!fat_mode)$fatal(1,"MBR FAT32 volume beyond 64MB not detected");
        sector(0,8'h42,8'h31);
        sector(1,8'h43,8'h35);

        rst=1;sd_ready=0;disk[510]=0;
        repeat(3) @(negedge clk);rst=0;sd_ready=1;
        wait(ready);#1;
        if (PRODUCT_MODE) begin
            if (!fat_mode || virtual_last!=0)
                $fatal(1,"single-card build must reject unsupported volumes");
            sector(0,8'h00,8'h00);
            $display("ALL PASSED: single FAT32 card, no TEXT or raw fallback");
        end else begin
            if(fat_mode)$fatal(1,"non-FAT card must use raw sector fallback");
            sector(4,8'h42,8'h31);
            $display("ALL PASSED: fragmented FAT32 files and raw fallback");
        end
        $finish;
    end
    initial begin #20_000_000;$fatal(1,"FAT32 bridge timeout");end
endmodule
