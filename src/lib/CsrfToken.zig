const std = @import("std");

const entropy_bytes = 16;
const len = entropy_bytes * 2;

data: ?[len]u8 = null,

fn generateIfNeeded(self: *@This()) void {
    if (self.data != null) return;

    var buf: [entropy_bytes]u8 = undefined;
    std.crypto.random.bytes(&buf);
    var data: [len]u8 = undefined;
    _ = std.fmt.bufPrint(&data, "{x}", .{buf}) catch unreachable;
    self.data = data;
}

pub fn get(self: *@This()) []const u8 {
    self.generateIfNeeded();
    return &self.data.?;
}

pub fn formScoped(self: *@This(), action: []const u8, method: []const u8) FormScoped {
    var pad: [entropy_bytes]u8 = undefined;
    std.crypto.random.bytes(&pad);
    return self.formScopedWithPad(action, method, pad) catch {
        self.data = null;
        self.generateIfNeeded();
        return self.formScopedWithPad(action, method, pad) catch unreachable;
    };
}

fn formScopedWithPad(self: *@This(), action: []const u8, method: []const u8, pad: [entropy_bytes]u8) !FormScoped {
    self.generateIfNeeded();
    var unmasked: [entropy_bytes]u8 = undefined;
    _ = try std.fmt.hexToBytes(&unmasked, &self.data.?);
    var masked: [entropy_bytes]u8 = undefined;
    for (unmasked, pad, 0..) |unmasked_byte, pad_byte, index| {
        masked[index] = unmasked_byte ^ pad_byte;
    }

    var hasher: std.crypto.hash.sha3.Sha3_512 = .init(.{});
    hasher.update(action);
    hasher.update("#");
    hasher.update(method);
    hasher.update("#");
    hasher.update(&masked);

    var digest: [std.crypto.hash.sha3.Sha3_512.digest_length]u8 = undefined;
    hasher.final(&digest);

    var result: FormScopedRaw = undefined;
    @memcpy(result[0..entropy_bytes], &pad);
    @memcpy(result[entropy_bytes..], &digest);

    return std.fmt.bytesToHex(&result, .lower);
}

pub fn isValidFormScoped(self: *@This(), action: []const u8, method: []const u8, form_scoped: []const u8) bool {
    if (form_scoped.len != form_scoped_len) return false;
    var form_scoped_raw: FormScopedRaw = undefined;
    _ = std.fmt.hexToBytes(&form_scoped_raw, form_scoped) catch return false;
    var pad: [entropy_bytes]u8 = undefined;
    @memcpy(&pad, form_scoped_raw[0..entropy_bytes]);
    const expected = self.formScopedWithPad(action, method, pad) catch return false;
    return std.mem.eql(u8, &expected, form_scoped);
}

const form_scoped_raw_len = entropy_bytes + std.crypto.hash.sha3.Sha3_512.digest_length;
const form_scoped_len = form_scoped_raw_len * 2;
const FormScopedRaw = [form_scoped_raw_len]u8;
pub const FormScoped = [form_scoped_len]u8;
