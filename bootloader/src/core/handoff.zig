const protocol = @import("boot_protocol");

pub fn prepareHeader(architecture: protocol.Architecture) protocol.Header {
    return protocol.Header.init(architecture);
}
