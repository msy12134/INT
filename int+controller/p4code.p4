/*
对于INT数据包（发包直接指定了srv6的相关内容），直接srv6转发即可
但是对于ipv4普通数据包，先添加ipv6和srv6的相关内容，然后再使用srv6转发，末尾srv6转发确定出口后
直接拿掉ipv6和srv6相关部分即可
*/


#include <core.p4>
#include <v1model.p4>

/*************************************************************************
 ************* C O N S T A N T S    A N D   T Y P E S  *******************
**************************************************************************/
#define MAX_PORTS 255
#define MAX_HOPS  15

const bit<16> TYPE_IPV4 = 0x0800;
const bit<16> TYPE_IPV6 = 0x86dd;

const bit<8>  IP_PROTO_TCP = 8w6;
const bit<8>  IP_PROTO_ICMP = 8w1;
const bit<8>  IP_PROTO_INT = 8w150;

/*************************************************************************
*********************** H E A D E R S  ***********************************
*************************************************************************/

header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16>   ether_type;
}

header probe_header_t {
    bit<8> num_probe_data;    
}
header probe_data_t {
    bit<8>    swid;      
    bit<8>    ingress_port;
    bit<8>    egress_port;
    bit<32>   ingress_byte_cnt;
    bit<32>   egress_byte_cnt;
    bit<48>    ingress_last_time;
    bit<48>    ingress_cur_time;        
    bit<48>    egress_last_time;
    bit<48>    egress_cur_time;
    bit<32>    ingress_packet_count;
    bit<32>    egress_packet_count;
}
header ipv6_h {
    bit<4>   version;
    bit<8>   traffic_class;
    bit<20>  flow_label;
    bit<16>  payload_len;  
    bit<8>   next_hdr;  
    bit<8>   hop_limit;
    bit<128> src_addr;
    bit<128> dst_addr;
} 


header srv6h_t {
    bit<8> next_hdr;
    bit<8> hdr_ext_len;  
    bit<8> routing_type;  
    bit<8> segment_left;  
    bit<8> last_entry;   
    bit<8> flags;   
    bit<16> tag;
}

header srv6_list_t {
    bit<128> segment_id;  
} 

header ipv4_t {
    bit<4>    version;
    bit<4>    ihl;
    bit<8>    diffserv;
    bit<16>   totalLen;
    bit<16>   identification;
    bit<3>    flags;
    bit<13>   fragOffset;
    bit<8>    ttl;
    bit<8>    protocol;
    bit<16>   hdrChecksum;
    bit<32> src_addr;
    bit<32> dst_addr;
}

//--------------------------
//TCP首部
header tcp_h {
    bit<16>  src_port;
    bit<16>  dst_port;
    bit<32>  seq_no;
    bit<32>  ack_no;
    bit<4>   data_offset;
    bit<4>   res;
    bit<8>   flags;
    bit<16>  window;
    bit<16>  checksum;
    bit<16>  urgent_ptr;
}
//--------------------------
header icmp_t {
    bit<8>  type;
    bit<8>  code;
    bit<16>  checksum;
    bit<16>  identifier;
    bit<16>  sequence;
}



/*************************************************************************
 **************  I N G R E S S   P R O C E S S I N G   *******************
 *************************************************************************/

    /***********************  H E A D E R S  ************************/
struct headers {
    ethernet_t               ethernet;
    ipv6_h                   ipv6;
    srv6h_t                  srv6h;
    srv6_list_t[MAX_HOPS]    srv6_list;
    ipv4_t                   ipv4;
    probe_header_t           probe_header;
    probe_data_t[MAX_HOPS]   probe_data;
    tcp_h                    tcp;
    icmp_t                   icmp;
}



    /******  G L O B A L   I N G R E S S   M E T A D A T A  *********/

struct metadata {
    bit<8> num_segments;  //用于后面改变srv6长度
    bit<8> trafficclass;
    bit<8>   remaining1;
    bit<8>   last_entry;
}

    /***********************  P A R S E R  **************************/

parser MyParser(packet_in pkt,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata){
    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        pkt.extract(hdr.ethernet);
        transition select(hdr.ethernet.ether_type) {
            TYPE_IPV4: parse_ipv4;
            TYPE_IPV6: parse_ipv6;
            default: accept;
        }
    }

    state parse_ipv4 {
        pkt.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            IP_PROTO_TCP: parse_tcp;
            IP_PROTO_ICMP: parse_icmp;
            IP_PROTO_INT: parse_probe; 
            default: accept;
        }
    }

    state parse_icmp {
        pkt.extract(hdr.icmp);
        transition accept;
    }

    state parse_probe {
        pkt.extract(hdr.probe_header);
        meta.remaining1=hdr.probe_header.num_probe_data;
        transition select(hdr.probe_header.num_probe_data){
            0:accept;                          
            default:parse_probe_list;
        }
    }
    state parse_probe_list{
        pkt.extract(hdr.probe_data.next);
        meta.remaining1=meta.remaining1-1;
        transition select(meta.remaining1){
            0:accept;
            default: parse_probe_list;
        }
    }

    state parse_tcp {
        pkt.extract(hdr.tcp);
        transition accept;
    }

    state parse_ipv6 {
        pkt.extract(hdr.ipv6);
        transition parse_srv6;   
    }

    //srv6解析
    state parse_srv6 {
        pkt.extract(hdr.srv6h);
        meta.num_segments=hdr.srv6h.last_entry+1;
        transition parse_srv6_list;
    }

    state parse_srv6_list {
        pkt.extract(hdr.srv6_list.next); 
        meta.num_segments=meta.num_segments-1;
		transition select(meta.num_segments){
     		0:parse_ipv4;
			default:parse_srv6_list;
		}  
    }    
}

    
control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {  }
}  
    /***************** M A T C H - A C T I O N  *********************/

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata)
{   register<bit<32>>(MAX_PORTS) byte_cnt_reg;
    register<bit<32>>(MAX_PORTS) packet_cnt_reg;
    register<bit<48>>(MAX_PORTS) last_time_reg;
    action drop() {
        mark_to_drop(standard_metadata);
    }


//---------------------------------------ipv6和srv6插入-----------------------------------------------
    action ipv4_forward(bit<48> dstAddr, bit<9> port){
        standard_metadata.egress_spec = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr; 
    }

    table ipv4_lpm{
        key = {
            hdr.ipv4.dst_addr: exact;
        }
        actions = {
            ipv4_forward;
            drop;
        }
        size = 1024;
        default_action = drop;  
    }

    action ipv6_forward(bit<48> dstAddr, bit<9> port) {
        standard_metadata.egress_spec = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;  
    }
    action srv6_forward() {
       hdr.ipv6.dst_addr = hdr.srv6_list[hdr.srv6h.segment_left].segment_id;
       hdr.srv6h.segment_left = hdr.srv6h.segment_left + 1;
    }
    table ipv6_lpm {
        key = {
            hdr.ipv6.dst_addr: exact;
        }
        actions = {
            ipv6_forward;
            drop;
        }
        size = 1024;
        default_action = drop;  
    }
    action set_swid(bit<8> swid) {
        hdr.probe_data[hdr.probe_header.num_probe_data].swid = swid;
    }
    table swid {
    	key = {
           hdr.ethernet.ether_type: exact;       
        }
        actions = {
            set_swid;
            NoAction;
        }
        default_action = NoAction();
    }
    table srv6_forward_table {
    	key = {
           hdr.ethernet.ether_type: exact;       
        }
        actions = {
            srv6_forward;
            NoAction;
        }
        default_action = NoAction();
    }
    //---------------------------------------srv6路径映射------------------------------------------------------
   
    
    //------------------------------------------------------------------------------------------------------
    //                                            apply
    //--------------------------------------------------------------------------------------------------------
    apply {
        bit<32> packet_cnt;
        bit<32> new_packet_cnt;
        bit<32> byte_cnt;
        bit<32> new_byte_cnt;
        bit<48> last_time;
        bit<48> cur_time = standard_metadata.ingress_global_timestamp;
        byte_cnt_reg.read(byte_cnt, (bit<32>)standard_metadata.ingress_port);
        byte_cnt = byte_cnt + standard_metadata.packet_length;
        new_byte_cnt = (hdr.probe_header.isValid()) ? 0 : byte_cnt;
        byte_cnt_reg.write((bit<32>)standard_metadata.ingress_port, new_byte_cnt);
        packet_cnt_reg.read(packet_cnt, (bit<32>)standard_metadata.ingress_port);
        packet_cnt = packet_cnt + 1;
        new_packet_cnt = (hdr.probe_header.isValid()) ? 0 : packet_cnt;
        packet_cnt_reg.write((bit<32>)standard_metadata.ingress_port, new_packet_cnt);
        if(hdr.ipv4.isValid() && !hdr.probe_header.isValid()){
            ipv4_lpm.apply();   //传递普通数据包
        }
        else if(hdr.ipv6.isValid()){     //控制INT包
            srv6_forward_table.apply();
            ipv6_lpm.apply();
            
            hdr.probe_data[hdr.probe_header.num_probe_data].setValid();
            swid.apply();
            
            hdr.probe_header.num_probe_data=hdr.probe_header.num_probe_data+1;
            hdr.probe_data[hdr.probe_header.num_probe_data-1].ingress_port = (bit<8>)standard_metadata.ingress_port;
            hdr.probe_data[hdr.probe_header.num_probe_data-1].ingress_byte_cnt = byte_cnt-standard_metadata.packet_length;
            last_time_reg.read(last_time, (bit<32>)standard_metadata.ingress_port);
            last_time_reg.write((bit<32>)standard_metadata.ingress_port, cur_time);
            hdr.probe_data[hdr.probe_header.num_probe_data-1].ingress_last_time = last_time;
            hdr.probe_data[hdr.probe_header.num_probe_data-1].ingress_cur_time = cur_time;
            hdr.probe_data[hdr.probe_header.num_probe_data-1].ingress_packet_count = packet_cnt-1;
            
            if(hdr.srv6h.segment_left==hdr.srv6h.last_entry+1){
                hdr.ethernet.ether_type=TYPE_IPV4;
                hdr.ipv6.setInvalid();
                hdr.srv6h.setInvalid();
                hdr.srv6_list[0].setInvalid();
                hdr.srv6_list[1].setInvalid();
                hdr.srv6_list[2].setInvalid();
                hdr.srv6_list[3].setInvalid();
                hdr.srv6_list[4].setInvalid();
                hdr.srv6_list[5].setInvalid();
                hdr.srv6_list[6].setInvalid();
                hdr.srv6_list[7].setInvalid();
                hdr.srv6_list[8].setInvalid();
            }
            
        }
    }
}
    

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata){
    register<bit<32>>(MAX_PORTS) byte_cnt_reg;
    register<bit<32>>(MAX_PORTS) packet_cnt_reg;
    register<bit<48>>(MAX_PORTS) last_time_reg;   
    
    apply{
        bit<32> packet_cnt;
        bit<32> new_packet_cnt;
        bit<32> byte_cnt;
        bit<32> new_byte_cnt;
        bit<48> last_time;
        bit<48> cur_time = standard_metadata.egress_global_timestamp;
        byte_cnt_reg.read(byte_cnt, (bit<32>)standard_metadata.egress_port);
        byte_cnt = byte_cnt + standard_metadata.packet_length;
        new_byte_cnt = (hdr.probe_header.isValid()) ? 0 : byte_cnt;
        byte_cnt_reg.write((bit<32>)standard_metadata.egress_port, new_byte_cnt);
        packet_cnt_reg.read(packet_cnt, (bit<32>)standard_metadata.egress_port);
        packet_cnt = packet_cnt + 1;
        new_packet_cnt = (hdr.probe_header.isValid()) ? 0 : packet_cnt;
        packet_cnt_reg.write((bit<32>)standard_metadata.egress_port, new_packet_cnt);
        if(hdr.probe_header.isValid()){
            hdr.probe_data[hdr.probe_header.num_probe_data-1].egress_port = (bit<8>)standard_metadata.egress_port;
            hdr.probe_data[hdr.probe_header.num_probe_data-1].egress_byte_cnt = byte_cnt-standard_metadata.packet_length;
            last_time_reg.read(last_time, (bit<32>)standard_metadata.egress_port);
            last_time_reg.write((bit<32>)standard_metadata.egress_port, cur_time);
            hdr.probe_data[hdr.probe_header.num_probe_data-1].egress_last_time = last_time;
            hdr.probe_data[hdr.probe_header.num_probe_data-1].egress_cur_time = cur_time;
            hdr.probe_data[hdr.probe_header.num_probe_data-1].egress_packet_count = packet_cnt-1;
        }
    }
}
    /*********************  D E P A R S E R  ************************/

control MyComputeChecksum(inout headers  hdr, inout metadata meta) {
     apply {
        update_checksum(
        hdr.ipv4.isValid(),
            { hdr.ipv4.version,
              hdr.ipv4.ihl,
              hdr.ipv4.diffserv,
              hdr.ipv4.totalLen,
              hdr.ipv4.identification,
              hdr.ipv4.flags,
              hdr.ipv4.fragOffset,
              hdr.ipv4.ttl,
              hdr.ipv4.protocol,
              hdr.ipv4.src_addr,
              hdr.ipv4.dst_addr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
        }
}
control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv6);
        packet.emit(hdr.srv6h);
        packet.emit(hdr.srv6_list);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.probe_header);
        packet.emit(hdr.probe_data);
        packet.emit(hdr.tcp);
        packet.emit(hdr.icmp);
    }
}
/*************************************************************************
***********************  S W I T C H  *******************************
*************************************************************************/

V1Switch(
MyParser(),
MyVerifyChecksum(),
MyIngress(),
MyEgress(),
MyComputeChecksum(),
MyDeparser()
) main;
