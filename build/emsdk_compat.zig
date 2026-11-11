//! Compatibility adapter for the pinned upstream raylib/emsdk build helper.
//!
//! Upstream attaches an `Activate EMSDK` user step to every Emscripten raylib
//! compile. That step runs `emsdk update`, `install` and `activate`, which is
//! incompatible with explicit setup and with offline normal builds. Detach
//! exactly that step here so the incompatibility stays isolated in one place
//! and cannot silently detach some other upstream dependency if the pin
//! changes.

const std = @import("std");

/// The exact user-step name created by the pinned upstream build helper.
pub const activation_step_name = "Activate EMSDK";

pub const DetachError = error{
    /// The pinned upstream graph changed; refusing to keep an installer attached.
    UpstreamActivationStepMissing,
    UpstreamActivationStepDuplicated,
};

/// Remove the upstream installer step from `step`'s direct dependencies.
///
/// Callers add their own pinned, check/provision-aware SDK step afterwards.
/// Missing or duplicate matches are configuration errors: they mean the
/// pinned upstream dependency no longer has the shape this adapter verifies.
pub fn detachActivationStep(step: *std.Build.Step) DetachError!void {
    removeExactlyOneNamed(&step.dependencies, activation_step_name) catch |err| {
        switch (err) {
            error.UpstreamActivationStepMissing => std.log.err(
                "the pinned raylib build no longer attaches the expected '{s}' step; refusing to build because an upstream Emscripten installer could not be detached. Update build/emsdk_compat.zig for the new pinned upstream graph.",
                .{activation_step_name},
            ),
            error.UpstreamActivationStepDuplicated => std.log.err(
                "the pinned raylib build attaches more than one '{s}' step; refusing to build because the upstream Emscripten installer cannot be detached unambiguously. Update build/emsdk_compat.zig for the new pinned upstream graph.",
                .{activation_step_name},
            ),
        }
        return err;
    };
}

fn removeExactlyOneNamed(list: anytype, name: []const u8) DetachError!void {
    var found: usize = 0;
    for (list.items) |item| {
        if (std.mem.eql(u8, item.name, name)) found += 1;
    }
    if (found == 0) return error.UpstreamActivationStepMissing;
    if (found > 1) return error.UpstreamActivationStepDuplicated;

    var index: usize = 0;
    while (index < list.items.len) : (index += 1) {
        if (std.mem.eql(u8, list.items[index].name, name)) {
            _ = list.orderedRemove(index);
            return;
        }
    }
    unreachable;
}

const FakeDependency = struct { name: []const u8 };

fn fakeList(allocator: std.mem.Allocator, names: []const []const u8) !std.ArrayList(FakeDependency) {
    var list: std.ArrayList(FakeDependency) = .empty;
    for (names) |name| try list.append(allocator, .{ .name = name });
    return list;
}

test "detaches exactly the expected activation step and keeps order" {
    var list = try fakeList(std.testing.allocator, &.{ "raylib", activation_step_name, "sysroot" });
    defer list.deinit(std.testing.allocator);

    try removeExactlyOneNamed(&list, activation_step_name);

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("raylib", list.items[0].name);
    try std.testing.expectEqualStrings("sysroot", list.items[1].name);
}

test "a missing activation step is a hard configuration error" {
    var list = try fakeList(std.testing.allocator, &.{"raylib"});
    defer list.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.UpstreamActivationStepMissing,
        removeExactlyOneNamed(&list, activation_step_name),
    );
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
}

test "duplicate activation steps are rejected instead of guessing" {
    var list = try fakeList(std.testing.allocator, &.{ activation_step_name, "raylib", activation_step_name });
    defer list.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.UpstreamActivationStepDuplicated,
        removeExactlyOneNamed(&list, activation_step_name),
    );
    // The error happens before any mutation, so an unexpected upstream graph
    // is never left partially detached.
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
}

test "an unrelated step name is never removed" {
    var list = try fakeList(std.testing.allocator, &.{ "Activate EMSDK-like", "check Emscripten 4.0.19" });
    defer list.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.UpstreamActivationStepMissing,
        removeExactlyOneNamed(&list, activation_step_name),
    );
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
}
