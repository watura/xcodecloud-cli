const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const api_client = @import("api/client.zig");
const types = @import("api/types.zig");
const products_view = @import("views/products.zig");
const workflows_view = @import("views/workflows.zig");
const build_runs_view = @import("views/build_runs.zig");
const build_run_detail_view = @import("views/build_run_detail.zig");
const build_action_artifacts_view = @import("views/build_action_artifacts.zig");
const status_bar = @import("widgets/status_bar.zig");

const Allocator = std.mem.Allocator;
const poll_interval_ms: u32 = 30_000;

pub const Screen = enum {
    products,
    workflows,
    build_runs,
    build_run_detail,
    build_action_artifacts,
    log_viewer,
};

const RowEntry = struct {
    line: []const u8,
    text: vxfw.Text,
};

pub const App = struct {
    allocator: Allocator,
    api: *api_client.Client,

    screen: Screen = .products,
    list_view: vxfw.ListView,
    log_scroll_view: vxfw.ScrollView,

    rows_arena: std.heap.ArenaAllocator,
    row_entries: []RowEntry = &.{},
    title_line: []const u8 = "",
    header_line: []const u8 = "",
    detail_summary: []const u8 = "",

    products: []types.CiProduct = &.{},
    workflows: []types.CiWorkflow = &.{},
    build_runs: []types.CiBuildRun = &.{},
    build_run_detail: ?types.CiBuildRun = null,
    build_actions: []types.CiBuildAction = &.{},
    build_action_artifacts: []types.CiArtifact = &.{},

    selected_product_index: usize = 0,
    selected_workflow_index: usize = 0,
    selected_build_run_index: usize = 0,
    selected_build_action_index: usize = 0,
    selected_artifact_index: usize = 0,

    log_content: ?[]u8 = null,
    log_artifact_name: []const u8 = "",

    status_message: ?[]u8 = null,

    pub fn init(allocator: Allocator, api: *api_client.Client) !App {
        var app = App{
            .allocator = allocator,
            .api = api,
            .screen = .products,
            .list_view = .{
                .children = .{ .builder = .{ .userdata = undefined, .buildFn = App.buildRow } },
                .draw_cursor = false,
                .item_count = 0,
            },
            .log_scroll_view = .{
                .children = .{ .builder = .{ .userdata = undefined, .buildFn = App.buildRow } },
                .draw_cursor = false,
                .item_count = 0,
            },
            .rows_arena = std.heap.ArenaAllocator.init(allocator),
        };

        app.list_view.children = .{ .builder = .{ .userdata = &app, .buildFn = App.buildRow } };
        app.log_scroll_view.children = .{ .builder = .{ .userdata = &app, .buildFn = App.buildRow } };

        if (api.authWarning()) |warning| {
            try app.setStatus(warning);
        } else {
            try app.setStatus("Ready");
        }

        return app;
    }

    pub fn deinit(self: *App) void {
        self.clearProducts();
        self.clearWorkflows();
        self.clearBuildRuns();
        self.clearBuildActions();
        self.clearBuildActionArtifacts();
        self.clearBuildRunDetail();
        self.clearLogContent();

        if (self.status_message) |message| {
            self.allocator.free(message);
            self.status_message = null;
        }

        self.rows_arena.deinit();
    }

    pub fn widget(self: *App) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *App = @ptrCast(@alignCast(ptr));
        self.handleEvent(ctx, event) catch |err| {
            self.setStatusFmt("Error: {s}", .{@errorName(err)}) catch {};
            ctx.consumeAndRedraw();
        };
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *App = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn handleEvent(self: *App, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
        switch (event) {
            .init => {
                try self.reloadCurrentScreen();
                try self.scheduleNextPoll(ctx);
                ctx.consumeAndRedraw();
            },
            .tick => {
                try self.pollScreenAndNotify(ctx);
                try self.scheduleNextPoll(ctx);
            },
            .key_press => |key| try self.handleKeyPress(ctx, key),
            .mouse => |mouse| {
                if (self.screen == .log_viewer) {
                    try self.log_scroll_view.handleEvent(ctx, .{ .mouse = mouse });
                }
            },
            else => {},
        }
    }

    fn scheduleNextPoll(self: *App, ctx: *vxfw.EventContext) !void {
        try ctx.tick(poll_interval_ms, self.widget());
    }

    fn pollScreenAndNotify(self: *App, ctx: *vxfw.EventContext) !void {
        switch (self.screen) {
            .workflows => {
                const changed = self.refreshWorkflowsIfChanged() catch |err| {
                    try self.setStatusFmt("Polling failed: {s}", .{@errorName(err)});
                    ctx.consumeAndRedraw();
                    return;
                };
                if (changed) {
                    try ctx.sendNotification("Xcode Cloud", "Workflows list updated");
                    ctx.consumeAndRedraw();
                }
            },
            .build_runs => {
                const changed = self.refreshBuildRunsIfChanged() catch |err| {
                    try self.setStatusFmt("Polling failed: {s}", .{@errorName(err)});
                    ctx.consumeAndRedraw();
                    return;
                };
                if (changed) {
                    try ctx.sendNotification("Xcode Cloud", "Build runs updated");
                    ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
    }

    fn handleKeyPress(self: *App, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        if (key.matches('c', .{ .ctrl = true })) {
            ctx.quit = true;
            ctx.consumeEvent();
            return;
        }

        if (key.matches('R', .{}) or key.matches('r', .{ .shift = true })) {
            try self.reloadCurrentScreen();
            ctx.consumeAndRedraw();
            return;
        }

        if (key.matches(vaxis.Key.escape, .{})) {
            try self.goBack();
            ctx.consumeAndRedraw();
            return;
        }

        if (key.matches('q', .{})) {
            if (self.screen == .products) {
                ctx.quit = true;
                ctx.consumeEvent();
                return;
            }

            try self.goBack();
            ctx.consumeAndRedraw();
            return;
        }

        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.screen == .log_viewer) {
                ctx.consumeEvent();
                return;
            }
            try self.activateSelection();
            ctx.consumeAndRedraw();
            return;
        }

        if ((key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) and self.screen != .log_viewer) {
            self.list_view.nextItem(ctx);
            return;
        }

        if ((key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) and self.screen != .log_viewer) {
            self.list_view.prevItem(ctx);
            return;
        }

        if (key.matches('r', .{}) and self.screen == .build_runs) {
            try self.triggerBuild();
            ctx.consumeAndRedraw();
            return;
        }

        if (key.matches('d', .{}) and self.screen == .build_action_artifacts) {
            try self.downloadSelectedArtifact();
            ctx.consumeAndRedraw();
            return;
        }

        if (self.screen == .log_viewer) {
            if (key.matches(vaxis.Key.page_down, .{})) {
                const scroll_lines: u8 = 20;
                if (self.log_scroll_view.scroll.linesDown(scroll_lines)) {
                    ctx.consumeAndRedraw();
                } else {
                    ctx.consumeEvent();
                }
                return;
            }
            if (key.matches(vaxis.Key.page_up, .{})) {
                const scroll_lines: u8 = 20;
                if (self.log_scroll_view.scroll.linesUp(scroll_lines)) {
                    ctx.consumeAndRedraw();
                } else {
                    ctx.consumeEvent();
                }
                return;
            }

            try self.log_scroll_view.handleEvent(ctx, .{ .key_press = key });
            return;
        }
    }

    fn draw(self: *App, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const breadcrumb = try self.breadcrumbLine(ctx.arena);
        const info = self.status_message orelse "";
        const auth_warning = self.api.authWarning() orelse "";

        const title_block = if (auth_warning.len > 0)
            try std.fmt.allocPrint(ctx.arena, "{s}\n{s}\n{s}", .{ breadcrumb, auth_warning, info })
        else
            try std.fmt.allocPrint(ctx.arena, "{s}\n{s}", .{ breadcrumb, info });

        const hints = try status_bar.line(
            ctx.arena,
            self.screen != .products,
            self.screen == .build_runs,
            self.screen == .build_action_artifacts,
            self.screen == .log_viewer,
        );

        const title_text: vxfw.Text = .{
            .text = title_block,
            .style = .{ .fg = .{ .index = 6 } },
            .softwrap = false,
            .overflow = .clip,
            .width_basis = .parent,
        };

        const summary_text: vxfw.Text = .{
            .text = self.detail_summary,
            .style = .{ .fg = .{ .index = 8 } },
            .softwrap = false,
            .overflow = .clip,
            .width_basis = .parent,
        };

        const header_text: vxfw.Text = .{
            .text = self.header_line,
            .style = .{ .fg = .{ .index = 4 } },
            .softwrap = false,
            .overflow = .clip,
            .width_basis = .parent,
        };

        const status_text: vxfw.Text = .{
            .text = hints,
            .style = .{ .fg = .{ .index = 3 } },
            .softwrap = false,
            .overflow = .clip,
            .width_basis = .parent,
        };
        const list_widget = if (self.screen == .log_viewer)
            self.log_scroll_view.widget()
        else
            self.list_view.widget();

        const list_box: vxfw.SizedBox = .{
            .child = list_widget,
            .size = .{ .width = 1, .height = 1 },
        };

        const children = try ctx.arena.alloc(vxfw.FlexItem, 5);
        children[0] = .{ .widget = title_text.widget(), .flex = 0 };
        children[1] = .{ .widget = summary_text.widget(), .flex = 0 };
        children[2] = .{ .widget = header_text.widget(), .flex = 0 };
        children[3] = .{ .widget = list_box.widget(), .flex = 1 };
        children[4] = .{ .widget = status_text.widget(), .flex = 0 };

        const column: vxfw.FlexColumn = .{ .children = children };
        return column.draw(ctx);
    }

    fn activateSelection(self: *App) !void {
        switch (self.screen) {
            .products => {
                if (self.products.len == 0) return;
                self.selected_product_index = self.cursorIndex();
                try self.loadWorkflows();
            },
            .workflows => {
                if (self.workflows.len == 0) return;
                self.selected_workflow_index = self.cursorIndex();
                try self.loadBuildRuns();
            },
            .build_runs => {
                if (self.build_runs.len == 0) return;
                self.selected_build_run_index = self.cursorIndex();
                try self.loadBuildRunDetail();
            },
            .build_run_detail => {
                if (self.build_actions.len == 0) return;
                self.selected_build_action_index = self.cursorIndex();
                try self.loadBuildActionArtifacts();
            },
            .build_action_artifacts => {
                try self.openOrViewArtifact();
            },
            .log_viewer => {},
        }
    }

    fn goBack(self: *App) !void {
        switch (self.screen) {
            .products => {},
            .workflows => {
                self.screen = .products;
                try self.rebuildRows(self.selected_product_index);
            },
            .build_runs => {
                self.screen = .workflows;
                try self.rebuildRows(self.selected_workflow_index);
            },
            .build_run_detail => {
                self.screen = .build_runs;
                try self.rebuildRows(self.selected_build_run_index);
            },
            .build_action_artifacts => {
                self.screen = .build_run_detail;
                try self.rebuildRows(self.selected_build_action_index);
            },
            .log_viewer => {
                self.clearLogContent();
                self.screen = .build_action_artifacts;
                try self.rebuildRows(self.selected_artifact_index);
            },
        }
    }

    fn reloadCurrentScreen(self: *App) !void {
        switch (self.screen) {
            .products => try self.loadProducts(),
            .workflows => try self.loadWorkflows(),
            .build_runs => try self.loadBuildRuns(),
            .build_run_detail => try self.loadBuildRunDetail(),
            .build_action_artifacts => try self.loadBuildActionArtifacts(),
            .log_viewer => try self.loadLogContent(),
        }
    }

    fn loadProducts(self: *App) !void {
        self.clearProducts();
        self.products = try self.api.listProducts();
        self.screen = .products;

        if (self.selected_product_index >= self.products.len) {
            self.selected_product_index = 0;
        }

        try self.rebuildRows(self.selected_product_index);
        try self.setStatusFmt("Loaded {d} products", .{self.products.len});
    }

    fn loadWorkflows(self: *App) !void {
        if (self.products.len == 0) {
            try self.setStatus("No products available");
            return;
        }

        self.selected_product_index = @min(self.selected_product_index, self.products.len - 1);
        const product = self.products[self.selected_product_index];

        self.clearWorkflows();
        self.workflows = try self.api.listWorkflows(product.id);
        self.screen = .workflows;

        if (self.selected_workflow_index >= self.workflows.len) {
            self.selected_workflow_index = 0;
        }

        try self.rebuildRows(self.selected_workflow_index);
        try self.setStatusFmt("Loaded {d} workflows for {s}", .{ self.workflows.len, product.name });
    }

    fn refreshWorkflowsIfChanged(self: *App) !bool {
        if (self.products.len == 0) return false;
        self.selected_product_index = @min(self.selected_product_index, self.products.len - 1);
        const product = self.products[self.selected_product_index];

        const latest = try self.api.listWorkflows(product.id);
        errdefer types.freeWorkflows(self.allocator, latest);

        if (workflowsEqual(self.workflows, latest)) {
            types.freeWorkflows(self.allocator, latest);
            return false;
        }

        self.clearWorkflows();
        self.workflows = latest;
        if (self.selected_workflow_index >= self.workflows.len) {
            self.selected_workflow_index = 0;
        }
        try self.rebuildRows(self.selected_workflow_index);
        try self.setStatusFmt("Updated workflows for {s}", .{product.name});
        return true;
    }

    fn loadBuildRuns(self: *App) !void {
        if (self.workflows.len == 0) {
            try self.setStatus("No workflows available");
            return;
        }

        self.selected_workflow_index = @min(self.selected_workflow_index, self.workflows.len - 1);
        const workflow = self.workflows[self.selected_workflow_index];

        self.clearBuildRuns();
        self.build_runs = try self.api.listBuildRuns(workflow.id);
        std.mem.sort(types.CiBuildRun, self.build_runs, {}, lessThanBuildRunNewestFirst);
        self.screen = .build_runs;

        if (self.selected_build_run_index >= self.build_runs.len) {
            self.selected_build_run_index = 0;
        }

        try self.rebuildRows(self.selected_build_run_index);
        try self.setStatusFmt("Loaded {d} build runs for {s}", .{ self.build_runs.len, workflow.name });
    }

    fn refreshBuildRunsIfChanged(self: *App) !bool {
        if (self.workflows.len == 0) return false;
        self.selected_workflow_index = @min(self.selected_workflow_index, self.workflows.len - 1);
        const workflow = self.workflows[self.selected_workflow_index];

        const latest = try self.api.listBuildRuns(workflow.id);
        errdefer types.freeBuildRuns(self.allocator, latest);
        std.mem.sort(types.CiBuildRun, latest, {}, lessThanBuildRunNewestFirst);

        if (buildRunsEqual(self.build_runs, latest)) {
            types.freeBuildRuns(self.allocator, latest);
            return false;
        }

        self.clearBuildRuns();
        self.build_runs = latest;
        if (self.selected_build_run_index >= self.build_runs.len) {
            self.selected_build_run_index = 0;
        }
        try self.rebuildRows(self.selected_build_run_index);
        try self.setStatusFmt("Updated build runs for {s}", .{workflow.name});
        return true;
    }

    fn lessThanBuildRunNewestFirst(_: void, lhs: types.CiBuildRun, rhs: types.CiBuildRun) bool {
        const lhs_created = lhs.created_date;
        const rhs_created = rhs.created_date;
        if (!std.mem.eql(u8, lhs_created, rhs_created)) {
            // ISO8601 strings can be compared lexicographically when format is consistent.
            return std.mem.order(u8, lhs_created, rhs_created) == .gt;
        }

        const lhs_number = std.fmt.parseUnsigned(u64, lhs.number, 10) catch 0;
        const rhs_number = std.fmt.parseUnsigned(u64, rhs.number, 10) catch 0;
        if (lhs_number != rhs_number) {
            return lhs_number > rhs_number;
        }

        return std.mem.order(u8, lhs.id, rhs.id) == .lt;
    }

    fn loadBuildRunDetail(self: *App) !void {
        if (self.build_runs.len == 0) {
            try self.setStatus("No build runs available");
            return;
        }

        self.selected_build_run_index = @min(self.selected_build_run_index, self.build_runs.len - 1);
        const run = self.build_runs[self.selected_build_run_index];

        self.clearBuildRunDetail();
        self.clearBuildActions();
        self.clearBuildActionArtifacts();

        self.build_run_detail = try self.api.getBuildRun(run.id);
        self.build_actions = try self.api.listBuildActions(run.id);
        self.screen = .build_run_detail;

        try self.rebuildRows(0);
        try self.setStatusFmt("Loaded details for build run #{s}", .{run.number});
    }

    fn loadBuildActionArtifacts(self: *App) !void {
        if (self.build_actions.len == 0) {
            try self.setStatus("No build actions available");
            return;
        }

        self.selected_build_action_index = @min(self.selected_build_action_index, self.build_actions.len - 1);
        const action = self.build_actions[self.selected_build_action_index];

        self.clearBuildActionArtifacts();
        self.build_action_artifacts = try self.api.listArtifactsForAction(action.id);
        self.screen = .build_action_artifacts;
        if (self.selected_artifact_index >= self.build_action_artifacts.len) {
            self.selected_artifact_index = 0;
        }

        try self.rebuildRows(self.selected_artifact_index);
        try self.setStatusFmt("Loaded {d} artifacts for action {s}", .{ self.build_action_artifacts.len, action.name });
    }

    fn downloadSelectedArtifact(self: *App) !void {
        if (self.build_action_artifacts.len == 0) {
            try self.setStatus("No artifacts available");
            return;
        }
        self.selected_artifact_index = @min(self.cursorIndex(), self.build_action_artifacts.len - 1);
        const artifact = self.build_action_artifacts[self.selected_artifact_index];
        const saved_path = try self.api.downloadArtifact(artifact);
        defer self.allocator.free(saved_path);
        try self.setStatusFmt("Downloaded: {s}", .{saved_path});
    }

    fn openOrViewArtifact(self: *App) !void {
        if (self.build_action_artifacts.len == 0) {
            try self.setStatus("No artifacts available");
            return;
        }
        self.selected_artifact_index = @min(self.cursorIndex(), self.build_action_artifacts.len - 1);
        const artifact = self.build_action_artifacts[self.selected_artifact_index];
        if (isLogArtifactType(artifact.file_type)) {
            try self.loadLogContentForArtifact(artifact);
            return;
        }

        try self.openArtifactUrl(artifact);
    }

    fn loadLogContentForArtifact(self: *App, artifact: types.CiArtifact) !void {
        self.clearLogContent();
        self.log_content = try self.api.fetchArtifactContent(artifact);
        self.log_artifact_name = try self.allocator.dupe(u8, artifact.file_name);
        self.screen = .log_viewer;
        try self.rebuildRows(0);
        try self.setStatusFmt("Viewing log: {s}", .{artifact.file_name});
    }

    fn loadLogContent(self: *App) !void {
        if (self.build_action_artifacts.len == 0) {
            try self.setStatus("No artifacts available");
            return;
        }
        self.selected_artifact_index = @min(self.selected_artifact_index, self.build_action_artifacts.len - 1);
        const artifact = self.build_action_artifacts[self.selected_artifact_index];
        if (!isLogArtifactType(artifact.file_type)) {
            try self.setStatus("Selected artifact is not a log");
            return;
        }
        try self.loadLogContentForArtifact(artifact);
    }

    fn openArtifactUrl(self: *App, artifact: types.CiArtifact) !void {
        if (std.mem.eql(u8, artifact.download_url, "-")) {
            try self.setStatus("No download URL for selected artifact");
            return;
        }

        const argv = if (@import("builtin").os.tag == .macos)
            [_][]const u8{ "open", artifact.download_url }
        else
            [_][]const u8{ "xdg-open", artifact.download_url };

        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        const term = child.spawnAndWait() catch {
            try self.setStatusFmt("Failed to open URL: {s}", .{artifact.download_url});
            return;
        };
        if (term.Exited != 0) {
            try self.setStatusFmt("Failed to open URL: {s}", .{artifact.download_url});
            return;
        }

        try self.setStatusFmt("Opened URL: {s}", .{artifact.download_url});
    }

    fn triggerBuild(self: *App) !void {
        if (self.screen != .build_runs or self.workflows.len == 0) return;

        self.selected_workflow_index = @min(self.selected_workflow_index, self.workflows.len - 1);
        const workflow = self.workflows[self.selected_workflow_index];

        const created = try self.api.createBuildRun(workflow.id);
        defer types.freeBuildRun(self.allocator, created);

        try self.setStatusFmt("Triggered build run #{s}", .{created.number});
        try self.loadBuildRuns();
    }

    fn rebuildRows(self: *App, cursor: usize) !void {
        self.rows_arena.deinit();
        self.rows_arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena = self.rows_arena.allocator();

        self.title_line = "";
        self.header_line = "";
        self.detail_summary = "";

        switch (self.screen) {
            .products => {
                self.title_line = "Products";
                self.header_line = try products_view.header(arena);
                self.row_entries = try arena.alloc(RowEntry, self.products.len);
                for (self.products, 0..) |item, idx| {
                    const line = try products_view.row(arena, item);
                    self.row_entries[idx] = makeRowEntry(line);
                }
            },
            .workflows => {
                const product_name = if (self.products.len == 0) "-" else self.products[self.selected_product_index].name;
                self.title_line = try std.fmt.allocPrint(arena, "Workflows for {s}", .{product_name});
                self.header_line = try workflows_view.header(arena);
                self.row_entries = try arena.alloc(RowEntry, self.workflows.len);
                for (self.workflows, 0..) |item, idx| {
                    const line = try workflows_view.row(arena, item);
                    self.row_entries[idx] = makeRowEntry(line);
                }
            },
            .build_runs => {
                const workflow_name = if (self.workflows.len == 0) "-" else self.workflows[self.selected_workflow_index].name;
                self.title_line = try std.fmt.allocPrint(arena, "Build Runs for {s}", .{workflow_name});
                self.header_line = try build_runs_view.header(arena);
                self.row_entries = try arena.alloc(RowEntry, self.build_runs.len);
                for (self.build_runs, 0..) |item, idx| {
                    const line = try build_runs_view.row(arena, item);
                    self.row_entries[idx] = makeRowEntry(line);
                }
            },
            .build_run_detail => {
                self.title_line = "Build Run Detail";
                if (self.build_run_detail) |detail| {
                    self.detail_summary = try build_run_detail_view.summaryLine(arena, detail);
                }
                self.header_line = try build_run_detail_view.actionHeader(arena);
                self.row_entries = try arena.alloc(RowEntry, self.build_actions.len);
                for (self.build_actions, 0..) |item, idx| {
                    const line = try build_run_detail_view.actionRow(arena, item);
                    self.row_entries[idx] = makeRowEntry(line);
                }
            },
            .build_action_artifacts => {
                const action_name = if (self.build_actions.len == 0) "-" else self.build_actions[self.selected_build_action_index].name;
                self.title_line = try std.fmt.allocPrint(arena, "Artifacts for {s}", .{action_name});
                self.header_line = try build_action_artifacts_view.artifactHeader(arena);
                self.row_entries = try arena.alloc(RowEntry, self.build_action_artifacts.len);
                for (self.build_action_artifacts, 0..) |item, idx| {
                    const line = try build_action_artifacts_view.artifactRow(arena, item);
                    self.row_entries[idx] = makeRowEntry(line);
                }
            },
            .log_viewer => {
                const artifact_name = if (self.log_artifact_name.len == 0) "-" else self.log_artifact_name;
                self.title_line = try std.fmt.allocPrint(arena, "Log Viewer: {s}", .{artifact_name});
                self.header_line = "";
                self.detail_summary = "";

                if (self.log_content) |content| {
                    if (content.len == 0) {
                        self.row_entries = try arena.alloc(RowEntry, 1);
                        self.row_entries[0] = makeRowEntry("(empty log)");
                    } else {
                        var line_count: usize = 1;
                        for (content) |ch| {
                            if (ch == '\n') line_count += 1;
                        }
                        self.row_entries = try arena.alloc(RowEntry, line_count);

                        var it = std.mem.splitScalar(u8, content, '\n');
                        var idx: usize = 0;
                        while (it.next()) |line| : (idx += 1) {
                            self.row_entries[idx] = makeRowEntry(line);
                        }
                    }
                } else {
                    self.row_entries = try arena.alloc(RowEntry, 1);
                    self.row_entries[0] = makeRowEntry("No log content loaded");
                }
            },
        }

        if (self.screen == .log_viewer) {
            self.resetLogScrollView();
        } else {
            self.resetListView(cursor);
        }
    }

    fn resetListView(self: *App, cursor: usize) void {
        self.list_view = .{
            .children = .{ .builder = .{ .userdata = self, .buildFn = App.buildRow } },
            .draw_cursor = false,
            .item_count = @intCast(self.row_entries.len),
        };

        if (self.row_entries.len == 0) {
            self.list_view.cursor = 0;
            return;
        }

        const clamped = @min(cursor, self.row_entries.len - 1);
        self.list_view.cursor = @intCast(clamped);
    }

    fn resetLogScrollView(self: *App) void {
        self.log_scroll_view = .{
            .children = .{ .builder = .{ .userdata = self, .buildFn = App.buildRow } },
            .draw_cursor = false,
            .item_count = @intCast(self.row_entries.len),
            .scroll = .{},
            .cursor = 0,
        };
    }

    fn breadcrumbLine(self: *App, allocator: Allocator) Allocator.Error![]u8 {
        return switch (self.screen) {
            .products => std.fmt.allocPrint(allocator, "Xcode Cloud > {s}", .{self.titleLine()}),
            .workflows => std.fmt.allocPrint(allocator, "Xcode Cloud > Products > {s}", .{self.titleLine()}),
            .build_runs => std.fmt.allocPrint(allocator, "Xcode Cloud > Products > Workflows > {s}", .{self.titleLine()}),
            .build_run_detail => std.fmt.allocPrint(allocator, "Xcode Cloud > Products > Workflows > Build Runs > Detail", .{}),
            .build_action_artifacts => std.fmt.allocPrint(allocator, "Xcode Cloud > Products > Workflows > Build Runs > Detail > Artifacts", .{}),
            .log_viewer => std.fmt.allocPrint(allocator, "Xcode Cloud > Products > Workflows > Build Runs > Detail > Artifacts > Log Viewer", .{}),
        };
    }

    fn titleLine(self: *const App) []const u8 {
        if (self.title_line.len > 0) return self.title_line;
        return switch (self.screen) {
            .products => "Products",
            .workflows => "Workflows",
            .build_runs => "Build Runs",
            .build_run_detail => "Build Run Detail",
            .build_action_artifacts => "Build Action Artifacts",
            .log_viewer => "Log Viewer",
        };
    }

    fn cursorIndex(self: *const App) usize {
        return @intCast(self.list_view.cursor);
    }

    fn setStatus(self: *App, msg: []const u8) !void {
        if (self.status_message) |old| {
            self.allocator.free(old);
        }
        self.status_message = try self.allocator.dupe(u8, msg);
    }

    fn setStatusFmt(self: *App, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        if (self.status_message) |old| {
            self.allocator.free(old);
        }
        self.status_message = msg;
    }

    fn makeRowEntry(line: []const u8) RowEntry {
        return .{
            .line = line,
            .text = .{
                .text = line,
                .softwrap = false,
                .overflow = .clip,
                .width_basis = .parent,
            },
        };
    }

    fn buildRow(userdata: *const anyopaque, idx: usize, cursor: usize) ?vxfw.Widget {
        const self: *App = @ptrCast(@alignCast(@constCast(userdata)));
        if (idx >= self.row_entries.len) return null;

        const entry = &self.row_entries[idx];
        entry.text.width_basis = if (self.screen == .log_viewer) .longest_line else .parent;
        entry.text.style = if (self.screen != .log_viewer and idx == cursor)
            .{ .reverse = true }
        else
            .{};
        return entry.text.widget();
    }

    fn clearProducts(self: *App) void {
        if (self.products.len > 0) {
            types.freeProducts(self.allocator, self.products);
            self.products = &.{};
        }
    }

    fn clearWorkflows(self: *App) void {
        if (self.workflows.len > 0) {
            types.freeWorkflows(self.allocator, self.workflows);
            self.workflows = &.{};
        }
    }

    fn clearBuildRuns(self: *App) void {
        if (self.build_runs.len > 0) {
            types.freeBuildRuns(self.allocator, self.build_runs);
            self.build_runs = &.{};
        }
    }

    fn clearBuildActions(self: *App) void {
        if (self.build_actions.len > 0) {
            types.freeBuildActions(self.allocator, self.build_actions);
            self.build_actions = &.{};
        }
    }

    fn clearBuildActionArtifacts(self: *App) void {
        if (self.build_action_artifacts.len > 0) {
            types.freeArtifacts(self.allocator, self.build_action_artifacts);
            self.build_action_artifacts = &.{};
        }
    }

    fn clearBuildRunDetail(self: *App) void {
        if (self.build_run_detail) |detail| {
            types.freeBuildRun(self.allocator, detail);
            self.build_run_detail = null;
        }
    }

    fn clearLogContent(self: *App) void {
        if (self.log_content) |content| {
            self.allocator.free(content);
            self.log_content = null;
        }
        if (self.log_artifact_name.len > 0) {
            self.allocator.free(self.log_artifact_name);
            self.log_artifact_name = "";
        }
    }
};

fn workflowsEqual(a: []const types.CiWorkflow, b: []const types.CiWorkflow) bool {
    if (a.len != b.len) return false;
    for (a, b) |lhs, rhs| {
        if (!std.mem.eql(u8, lhs.id, rhs.id)) return false;
        if (!std.mem.eql(u8, lhs.name, rhs.name)) return false;
        if (lhs.is_enabled != rhs.is_enabled) return false;
    }
    return true;
}

fn buildRunsEqual(a: []const types.CiBuildRun, b: []const types.CiBuildRun) bool {
    if (a.len != b.len) return false;
    for (a, b) |lhs, rhs| {
        if (!std.mem.eql(u8, lhs.id, rhs.id)) return false;
        if (!std.mem.eql(u8, lhs.number, rhs.number)) return false;
        if (!std.mem.eql(u8, lhs.source_branch_or_tag, rhs.source_branch_or_tag)) return false;
        if (!std.mem.eql(u8, lhs.status, rhs.status)) return false;
        if (!std.mem.eql(u8, lhs.completion_status, rhs.completion_status)) return false;
        if (!std.mem.eql(u8, lhs.created_date, rhs.created_date)) return false;
        if (!std.mem.eql(u8, lhs.started_date, rhs.started_date)) return false;
        if (!std.mem.eql(u8, lhs.finished_date, rhs.finished_date)) return false;
    }
    return true;
}

fn isLogArtifactType(file_type: []const u8) bool {
    return std.mem.eql(u8, file_type, "LOG") or std.mem.eql(u8, file_type, "LOG_BUNDLE");
}
