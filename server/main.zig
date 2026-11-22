const std = @import("std");
const transport = @import("transport.zig");
const memory = @import("memory.zig");
const app = @import("app.zig");
const native = @import("native_storage");
const wallet_storage = @import("wallet.zig");
const GameDb = @import("game_db.zig").GameDb;
const Persistence = @import("persistence.zig").Persistence;
const Shutdown = @import("shutdown.zig").Shutdown;
const startup_log = std.log.scoped(.server_startup);

const Options = struct {
    websocket_budget: usize,
    application_budget: usize,

    fn parse(args: []const []const u8) !Options {
        if (args.len > 3) return error.UsageExpectedOptionalWsAppBudgets;
        const websocket_budget = if (args.len >= 2) try std.fmt.parseInt(usize, args[1], 10) else memory.default_ws_budget;
        const application_budget = if (args.len >= 3) try std.fmt.parseInt(usize, args[2], 10) else app.default_budget;
        if (websocket_budget < 4096 or !std.math.isPowerOfTwo(websocket_budget)) return error.InvalidWebsocketBudget;
        return .{
            .websocket_budget = websocket_budget,
            .application_budget = application_budget,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    // Parse and validate configuration before acquiring persistent resources.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try Options.parse(args);
    startup_log.info("configuration parsed: websocket_budget={d}, application_budget={d}", .{
        options.websocket_budget, options.application_budget,
    });

    // Hold the server storage lock until all wallet borrowers are gone.
    const locations = try native.paths.resolveCurrentIdentity(init.gpa, .server);
    defer locations.deinit(init.gpa);
    try native.storage_fs.ensureStandardParents(init.io, locations.standard_parents);
    var lock = try native.instance_lock.acquire(init.io, locations.config_dir);
    defer lock.release(init.io);
    startup_log.info("storage prepared and instance lock acquired", .{});

    try native.wallet.cdk.requireAppMint();
    var wallet = try wallet_storage.open(init.io, init.gpa, locations);
    defer wallet.close() catch {};
    startup_log.info("wallet opened", .{});

    const data_dir = std.fs.path.dirname(locations.wallet_dir) orelse return error.InvalidPath;
    const game_path = try std.fs.path.joinZ(init.gpa, &.{ data_dir, "game.sqlite" });
    defer init.gpa.free(game_path);
    var db = GameDb.open(game_path) catch |err| {
        startup_log.err("cannot open game database at {s}: {s}", .{ game_path, @errorName(err) });
        return err;
    };
    defer db.close();
    startup_log.info("game database opened", .{});

    // Reserve independent WebSocket and application memory regions.
    const websocket_alignment: std.mem.Alignment = .fromByteUnits(options.websocket_budget);
    const websocket_ptr = init.gpa.rawAlloc(options.websocket_budget, websocket_alignment, @returnAddress()) orelse return error.OutOfMemory;
    defer init.gpa.rawFree(websocket_ptr[0..options.websocket_budget], websocket_alignment, @returnAddress());
    var recycler = try memory.Buddy.init(websocket_ptr[0..options.websocket_budget]);
    startup_log.info("WebSocket memory ready", .{});

    const application_buffer = try init.gpa.alignedAlloc(u8, .fromByteUnits(@alignOf(app.Layout)), options.application_budget);
    defer init.gpa.free(application_buffer);
    var application = try app.App.init(init.io, application_buffer);
    application.wallet = &wallet;
    defer application.deinit();
    var persistence = try Persistence.init(init.io, init.gpa, &db, &application.context.state, application.registry);
    defer persistence.deinit(init.gpa);
    application.persistence = &persistence;
    startup_log.info("application ready", .{});

    // Transport initialization reserves slots; listen performs the bind.
    var server = transport.Server.init(init.io, recycler.allocator()) catch |err| {
        if (err == error.OutOfMemory) return error.InsufficientWebsocketBudget;
        return err;
    };
    defer server.deinit();
    startup_log.info("transport ready", .{});

    var shutdown = try Shutdown.install();
    defer shutdown.restore();
    startup_log.info("starting listener", .{});
    const listen_result = listenUntilShutdown(init.io, &server, &application, &shutdown);
    // The listener and all of its connection, tick and saver tasks have joined.
    persistence.flush() catch |err| {
        startup_log.err("final game save failed: {s}", .{@errorName(err)});
        return err;
    };
    try listen_result;
}

fn listenUntilShutdown(io: std.Io, server: *transport.Server, application: *app.App, shutdown: *Shutdown) !void {
    const Result = union(enum) { listener: anyerror!void, signal: std.Io.Cancelable!void };
    var results: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &results);
    defer select.cancelDiscard();
    try select.concurrent(.listener, transport.Server.listen, .{ server, application });
    try select.concurrent(.signal, Shutdown.wait, .{ shutdown, io });
    return switch (try select.await()) {
        .listener => |result| result,
        .signal => |result| result,
    };
}

test "startup options defaults" {
    const options = try Options.parse(&.{"server"});
    try std.testing.expectEqual(memory.default_ws_budget, options.websocket_budget);
    try std.testing.expectEqual(app.default_budget, options.application_budget);
}

test "startup options explicit values and partial defaults" {
    const args = [_][]const u8{ "server", "4096", "131072" };
    for (2..args.len + 1) |count| {
        const options = try Options.parse(args[0..count]);
        try std.testing.expectEqual(@as(usize, 4096), options.websocket_budget);
        try std.testing.expectEqual(if (count >= 3) @as(usize, 131072) else app.default_budget, options.application_budget);
    }
}

test "startup options reject excess arguments and invalid WebSocket budgets" {
    try std.testing.expectError(error.UsageExpectedOptionalWsAppBudgets, Options.parse(&.{ "server", "4096", "1", "extra" }));
    for ([_][]const u8{ "0", "2048", "4097", "6144" }) |budget| {
        try std.testing.expectError(error.InvalidWebsocketBudget, Options.parse(&.{ "server", budget }));
    }
}

test "startup options propagate malformed and overflowing numeric budgets" {
    for (1..3) |index| {
        var args = [_][]const u8{ "server", "4096", "1" };
        args[index] = "not-a-number";
        try std.testing.expectError(error.InvalidCharacter, Options.parse(&args));
        args[index] = "9999999999999999999999999999999999999999";
        try std.testing.expectError(error.Overflow, Options.parse(&args));
    }
}
