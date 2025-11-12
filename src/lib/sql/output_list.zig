const std = @import("std");

const meta = @import("../meta.zig");

pub fn OutputList(comptime Outputs: []const type) type {
    const outputs_params_types: []const type = comptime outputs_params_types: {
        var types_buf: [Outputs.len]type = undefined;
        for (Outputs, 0..) |Output, index| {
            types_buf[index] = @typeInfo(@TypeOf(Output.params)).@"fn".return_type.?;
        }
        const types = types_buf;
        break :outputs_params_types &types;
    };

    return struct {
        const UnflattenedParams = std.meta.Tuple(outputs_params_types);
        pub const Params = meta.FlattenedTuples(std.meta.Tuple(outputs_params_types));

        outputs: std.meta.Tuple(Outputs),

        pub fn params(self: *const @This()) Params {
            var unflattened_params: UnflattenedParams = undefined;
            inline for (self.outputs, 0..) |output, index| {
                unflattened_params[index] = output.params();
            }
            return meta.flattenTuples(unflattened_params);
        }

        pub fn writeToSql(writer: *std.Io.Writer, next_placeholder: *usize) std.Io.Writer.Error!void {
            var needs_leading_comma = false;
            for (Outputs) |Output| {
                if (needs_leading_comma) {
                    try writer.writeByte(',');
                }
                try Output.writeToSql(writer, next_placeholder);
                needs_leading_comma = true;
            }
        }
    };
}
