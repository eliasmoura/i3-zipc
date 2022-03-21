const std = @import("std");
const json = std.json;
const magic = "i3-ipc";

pub const I3ipc = struct {
    const Self = @This();
    conn: std.net.Stream,
    sock_path: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn init(sock_path: ?[]const u8, allocator: std.mem.Allocator) !I3ipc {
        var path: []const u8 = undefined;
        if (sock_path) |_| {
            path = sock_path.?;
        } else {
            path = std.os.getenv("I3SOCK").?;
        }
        var sock = try std.net.connectUnixSocket(path);
        return I3ipc{ .conn = sock, .sock_path = path, .allocator = allocator };
    }
    pub fn send_msg(self: *Self, msg_type: I3_Cmd, payload: ?[]const u8) !void {
        //NOTE(kotto): std.mem.asBytes seems to be buggy according to ifreund on irc.
        // the code would look like this:
        // ```code zig
        // const std = @import("std");
        //
        // const I3IpcHeader = packed struct { magic: [6]u8 = "i3-ipc".*, len: u32, type: u32 };
        // pub fn main() anyerror!void {
        //     var sock_path = std.os.getenv("I3SOCK").?;
        //     var sock = try std.net.connectUnixSocket(sock_path);
        //     const msg = "workspace 3";
        //     var header = I3IpcHeader{ .len = msg.len, .type = 0 };
        //     _ = try sock.write(std.mem.asBytes(&header));
        //     _ = try sock.write(msg);
        // }
        // ```
        const msg_len = magic.len + @sizeOf(@TypeOf(msg_type)) + 4 + if (payload) |p| p.len else 0;
        // TODO: It might be better to just use a buf in the stack since, most
        // of the time, only the GET_* commands should be used?
        var msg = try self.allocator.alloc(u8, msg_len);
        defer self.allocator.free(msg);
        switch (msg_type) {
            .RUN_COMMAND, .SEND_TICK, .SUBSCRIBE, .SYNC => {
                std.mem.copy(u8, msg, magic);
                // NOTE: i3-ipc uses the host endiannes
                std.debug.assert(payload != null);
                std.mem.writeIntNative(u32, msg[magic.len .. magic.len + 4], @intCast(u32, payload.?.len));
                std.mem.writeIntNative(u32, msg[magic.len + 4 .. magic.len + 8], @enumToInt(msg_type));
                std.mem.copy(u8, msg[magic.len + 8 ..], payload.?);
            },
            .GET_WORKSPACES, .GET_OUTPUTS, .GET_TREE, .GET_MARKS, .GET_BAR_CONFIG, .GET_VERSION, .GET_BINDING_MODES, .GET_CONFIG, .GET_BINDING_STATE => {
                std.mem.copy(u8, msg, magic);
                // NOTE: i3-ipc uses the host endiannes
                std.mem.writeIntNative(u32, msg[magic.len .. magic.len + 4], 0);
                std.mem.writeIntNative(u32, msg[magic.len + 4 .. magic.len + 8], @enumToInt(msg_type));
            },
        }
        _ = try self.conn.write(msg);
    }

    pub fn get_msg(self: *Self) !I3_reply {
        @setEvalBranchQuota(100000);
        // magic len + 4bytes cmd payload len + 4bytes cmd type
        var header: [magic.len + 8]u8 = undefined;
        _ = try self.conn.read(&header);
        // NOTE: if the magic change, than it means breacking changes happened and this lib is not aware of that!
        std.debug.assert(std.mem.eql(u8, magic, header[0..magic.len]));
        const len = std.mem.readIntSliceNative(u32, header[magic.len .. magic.len + 4]);
        const cmd = @intToEnum(I3_reply_type, std.mem.readIntSliceNative(u32, header[magic.len + 4 .. magic.len + 8]));
        const data = try self.allocator.alloc(u8, len);
        defer self.allocator.free(data);
        var payload_read = try self.conn.read(data);
        while (payload_read < data.len) payload_read += try self.conn.read(data[payload_read..]);
        switch (cmd) {
            // NOTE: Using I3_reply.* so that Neovim/ZLS(?) can resolve references/declaration
            I3_reply.I3_cmd => { // COMMAND | Run the payload as an i3 command (like the commands you can bind to keys).
                var stream = json.TokenStream.init(data[0..]);
                return I3_reply{ .I3_cmd = json.parse([]I3_Cmd_reply, &stream, .{ .allocator = self.allocator }) catch |err| {
                    std.log.err("ERROR: {}\n{s}", .{ err, data });
                    return err;
                } };
            },
            I3_reply.I3_get_workspace => { // WORKSPACES    | Get the list of current workspaces.
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_get_workspace = json.parse([]I3_Get_Workspace_reply, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = true,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_subscribe => { // SUBSCRIBE     | Subscribe this IPC connection to the event types specified in the message payload. See [events].
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_subscribe = json.parse(I3_Subscribe_reply, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = true,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_get_output => { // OUTPUTS       | Get the list of current outputs.
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_get_output = json.parse([]I3_Get_Output_reply, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = true
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_get_tree => { // TREE          | Get the i3 layout tree.
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_get_tree = json.parse([]I3_Tree_Node, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = true,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_get_mark => { // MARKS         | Gets the names of all currently set marks.
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_get_mark = json.parse([]I3_Get_Mark_reply, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = true,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_get_bar_config => { // BAR_CONFIG    | Gets the specified bar configuration or the names of all bar configurations if payload is empty.
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_get_bar_config = json.parse([]I3_Get_Bar_config_reply, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = true,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_get_version => { // VERSION       | Gets the i3 version.
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_get_version = json.parse(I3_Get_Version_reply, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = true,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_get_binding_modes => { // BINDING_MODES | Gets the names of all currently configured binding modes.
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_get_binding_modes = json.parse(I3_Get_Binding_modes_reply, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = true,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_get_config => { // CONFIG        | Returns the last loaded i3 config.
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_get_config = json.parse(I3_Get_Config_reply, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = true,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_tick => { // TICK          | Sends a tick event with the specified payload.
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_tick = json.parse(I3_Tick_reply, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = true,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_sync => { // SYNC          | Sends an i3 sync event with the specified random value to the specified window.
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_sync = json.parse(I3_Sync_reply, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = true,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_get_binding_state => { //INDING_STATE | Request the current binding state, i.e. the currently active binding mode name.
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_get_binding_state = json.parse(I3_Get_Binding_state_reply, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = true,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_event_workspace => {
                var stream2 = json.TokenStream.init(data);
                var rj = json.parse(I3_Event_Workspace, &stream2, .{
                    .allocator = self.allocator,
                    //.ignore_unknown_fields = true, //NOTE: It seems like some fields are undecumented?
                }) catch |err| {
                    std.log.err("ERROR: {}\n{s}\n", .{ err, data });
                    return err;
                };
                return I3_reply{ .I3_event_workspace = rj };
            },
            I3_reply.I3_event_mode => {
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_event_mode = json.parse(I3_Event_Mode, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = false,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_event_output => {
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_event_mode = json.parse(I3_Event_Mode, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = false,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_event_window => {
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_event_window = json.parse(I3_Event_Window, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = false,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_event_barconfig_update => {
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_event_window = json.parse(I3_Event_Window, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = false,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_event_binding => {
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_event_mode = json.parse(I3_Event_Mode, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = false,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_event_shutdown => {
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_event_mode = json.parse(I3_Event_Mode, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = false,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
            I3_reply.I3_event_tick => {
                var stream2 = json.TokenStream.init(data[0..]);
                return I3_reply{
                    .I3_event_mode = json.parse(I3_Event_Mode, &stream2, .{
                        .allocator = self.allocator, //.ignore_unknown_fields = false,
                    }) catch |err| {
                        std.log.err("ERROR: {}\n{s}", .{ err, data });
                        return err;
                    },
                };
            },
        }
        return error.invalidMsgType;
    }
};

pub const Error = error{
    invalidMsgType,
};

pub const I3_Cmd = enum(u32) { // i3 ipc uses 4 bytes for the cmd/subscribe events type
    // Type                   | Reply type    | Purpose
    RUN_COMMAND = 0, //       | COMMAND       | Run the payload as an i3 command (like the commands you can bind to keys).
    GET_WORKSPACES = 1, //    | WORKSPACES    | Get the list of current workspaces.
    SUBSCRIBE = 2, //         | SUBSCRIBE     | Subscribe this IPC connection to the event types specified in the message payload. See [events].
    GET_OUTPUTS = 3, //       | OUTPUTS       | Get the list of current outputs.
    GET_TREE = 4, //          | TREE          | Get the i3 layout tree.
    GET_MARKS = 5, //         | MARKS         | Gets the names of all currently set marks.
    GET_BAR_CONFIG = 6, //    | BAR_CONFIG    | Gets the specified bar configuration or the names of all bar configurations if payload is empty.
    GET_VERSION = 7, //       | VERSION       | Gets the i3 version.
    GET_BINDING_MODES = 8, // | BINDING_MODES | Gets the names of all currently configured binding modes.
    GET_CONFIG = 9, //        | CONFIG        | Returns the last loaded i3 config.
    SEND_TICK = 10, //        | TICK          | Sends a tick event with the specified payload.
    SYNC = 11, //             | SYNC          | Sends an i3 sync event with the specified random value to the specified window.
    GET_BINDING_STATE = 12, //| BINDING_STATE | Request the current binding state, i.e. the currently active binding mode name.
};

pub const I3_msg = struct {
    magic: [magic.len]u8 = magic.*,
    len: u32,
    cmd: I3_Cmd_reply,
    data: ?[]u8,
};
pub const I3_reply_type = enum(u32) {
    I3_cmd = @enumToInt(I3_Cmd.RUN_COMMAND),
    I3_get_workspace = @enumToInt(I3_Cmd.GET_WORKSPACES),
    I3_subscribe = @enumToInt(I3_Cmd.SUBSCRIBE),
    I3_get_output = @enumToInt(I3_Cmd.GET_OUTPUTS),
    I3_get_tree = @enumToInt(I3_Cmd.GET_TREE),
    I3_get_mark = @enumToInt(I3_Cmd.GET_MARKS),
    I3_get_bar_config = @enumToInt(I3_Cmd.GET_BAR_CONFIG),
    I3_get_version = @enumToInt(I3_Cmd.GET_VERSION),
    I3_get_binding_modes = @enumToInt(I3_Cmd.GET_BINDING_MODES),
    I3_get_config = @enumToInt(I3_Cmd.GET_CONFIG),
    I3_tick = @enumToInt(I3_Cmd.SEND_TICK),
    I3_sync = @enumToInt(I3_Cmd.SYNC),
    I3_get_binding_state = @enumToInt(I3_Cmd.GET_BINDING_STATE),
    I3_event_workspace = (1 << (@bitSizeOf(u32) - 1)) | 0,
    I3_event_output = (1 << (@bitSizeOf(u32) - 1)) | 1,
    I3_event_mode = (1 << (@bitSizeOf(u32) - 1)) | 2,
    I3_event_window = (1 << (@bitSizeOf(u32) - 1)) | 3,
    I3_event_barconfig_update = (1 << (@bitSizeOf(u32) - 1)) | 4,
    I3_event_binding = (1 << (@bitSizeOf(u32) - 1)) | 5,
    I3_event_shutdown = (1 << (@bitSizeOf(u32) - 1)) | 6,
    I3_event_tick = (1 << (@bitSizeOf(u32) - 1)) | 7,
};

pub const I3_reply = union(I3_reply_type) {

    /// Run the payload as an i3 command (like the commands you can bind to keys).
    I3_cmd: []I3_Cmd_reply,

    /// Get the list of current active workspaces.
    I3_get_workspace: []I3_Get_Workspace_reply,

    /// Subscribe this IPC connection to the event types specified in the message payload. See [events].
    I3_subscribe: I3_Subscribe_reply,

    /// Get the list of current outputs.
    I3_get_output: []I3_Get_Output_reply,

    /// Get the i3 layout tree.
    I3_get_tree: []I3_Tree_Node, //TODO: check if this should use I3_tree or I3_Tree_Node.

    /// Gets the names of all currently set marks.
    I3_get_mark: []I3_Get_Mark_reply,

    /// Gets the specified bar configuration or the names of all bar configurations if payload is empty.
    I3_get_bar_config: []I3_Get_Bar_config_reply,

    /// Gets the i3 version.
    I3_get_version: I3_Get_Version_reply,

    /// Gets the names of all currently configured binding modes.
    I3_get_binding_modes: I3_Get_Binding_modes_reply,

    /// Returns the last loaded i3 config.
    I3_get_config: I3_Get_Config_reply,

    /// Sends a tick event with the specified payload.
    I3_tick: I3_Tick_reply,

    /// Sends an i3 sync event with the specified random value to the specified window.
    I3_sync: I3_Sync_reply,

    /// Get the current binding state, i.e. the currently active binding mode name("default", "menu", "resize").
    I3_get_binding_state: I3_Get_Binding_state_reply,

    /// Sent when the user switches to a different workspace, when a new workspace is initialized or when a workspace is removed (because the last client vanished).
    I3_event_workspace: I3_Event_Workspace,

    /// Sent when RandR issues a change notification (of either screens, outputs, CRTCs or output properties).
    // NOTE: currently EVENT_OUTPUT event does not output anything useful. it just return:
    // { "change": "unspecified" }
    I3_event_output: I3_Event_Output,

    /// Sent whenever i3 changes its binding mode. Ex: "menu", "resize", "default"
    I3_event_mode: I3_Event_Mode,

    /// Sent when a client’s window is successfully reparented (that is when i3 has finished fitting it into a container), when a window received input focus or when certain properties of the window have changed.
    //5.6. window event
    // This event consists of a single serialized map containing a property
    // change (string) which indicates the type of the change
    // - new – the window has become managed by i3
    // - close – the window has closed
    // - focus – the window has received input focus
    // - title – the window’s title has changed
    // - fullscreen_mode – the window has entered or exited fullscreen mode
    // - move – the window has changed its position in the tree
    // - floating – the window has transitioned to or from floating
    // - urgent – the window has become urgent or lost its urgent status
    // - mark – a mark has been added to or removed from the window
    // Additionally a container (object) field will be present, which consists of the window’s parent container. Be aware that for the "new" event, the container will hold the initial name of the newly reparented window (e.g. if you run urxvt with a shell that changes the title, you will still at this point get the window title as "urxvt").
    I3_event_window: I3_Event_Window,

    // Sent when the hidden_state or mode field in the barconfig of any bar instance was updated and when the config is reloaded.
    /// This event consists of a single serialized map reporting on options from the barconfig of the specified bar_id that were updated in i3. This event is the same as a GET_BAR_CONFIG reply for the bar with the given id.
    I3_event_barconfig_update: I3_event_barconfig_update,

    // Sent when a configured command binding is triggered with the keyboard or mouse
    /// This event consists of a single serialized map reporting on the details of a binding that ran a command because of user input. The change (string) field indicates what sort of binding event was triggered (right now it will always be "run" but may be expanded in the future).
    /// The binding (object) field contains details about the binding that was run:
    /// - command (string)
    ///   The i3 command that is configured to run for this binding.
    /// - event_state_mask (array of strings)
    ///   The group and modifier keys that were configured with this binding.
    /// - input_code (integer)
    ///   If the binding was configured with bindcode, this will be the key code that was given for the binding. If the binding is a mouse binding, it will be the number of the mouse button that was pressed. Otherwise it will be 0.
    /// - symbol (string or null)
    ///   If this is a keyboard binding that was configured with bindsym, this field will contain the given symbol. Otherwise it will be null.
    /// - input_type (string)
    ///   This will be "keyboard" or "mouse" depending on whether or not this was a keyboard or a mouse binding.
    I3_event_binding: I3_event_binding,

    // Sent when the ipc shuts down because of a restart or exit by user command
    /// This event is triggered when the connection to the ipc is about to shutdown because of a user action such as a restart or exit command. The change (string) field indicates why the ipc is shutting down. It can be either "restart" or "exit".
    I3_event_shutdown: I3_event_shutdown,

    // Sent when the ipc client subscribes to the tick event (with "first": true) or when any ipc client sends a SEND_TICK message (with "first": false).
    /// This event is triggered by a subscription to tick events or by a SEND_TICK message.
    /// Example (upon subscription):
    /// ```json
    /// {
    ///   "first": true,
    ///   "payload": ""
    /// }
    /// ```
    /// Example (upon SEND_TICK with a payload of arbitrary string):
    /// ```json
    /// {
    ///   "first": false,
    ///   "payload": "arbitrary string"
    /// }
    /// ```
    I3_event_tick: I3_event_tick,
};

pub const I3_Cmd_reply = []struct { success: bool, parse_error: bool = false };
pub const I3_Get_Workspace_reply = struct {
    id: u64,
    num: i32,
    name: ?[]u8,
    visible: bool,
    focused: bool,
    rect: Rect,
    output: ?[]u8,
    urgent: bool,
};

const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const I3_Get_Output_reply = struct {
    /// name (string)
    /// The name of this output (as seen in xrandr(1)). Encoded in UTF-8.
    name: []u8,
    /// active (boolean)
    /// Whether this output is currently active (has a valid mode).
    active: bool,
    /// primary (boolean)
    /// Whether this output is currently the primary output.
    primary: bool,
    /// current_workspace (string or null)
    /// The name of the current workspace that is visible on this output. null if the output is not active.
    current_workspace: ?[]u8,
    /// rect (map)
    /// The rectangle of this output (equals the rect of the output it is on), consists of x, y, width, height.
    rect: Rect,
}; //       | OUTPUTS       | Get the list of current outputs.

pub const X11_WinProps = struct {
    class: ?[]u8 = null,
    instance: ?[]u8 = null,
    window_role: ?[]u8 = null,
    machine: ?[]u8 = null,
    title: ?[]u8 = null,
    // NOTE: It seems like this thing is an interger(not sure if uint).
    transient_for: ?i32 = null, // TODO: check what this is used for.
};

/// The list of current outputs.
/// The reply consists of a serialized list of outputs. Each output has the following properties:
pub const I3_Tree = struct {
    // The reply consists of a serialized tree. Each node in the tree (representing one container) has at least the properties listed below. While the nodes might have more properties, please do not use any properties which are not documented here. They are not yet finalized and will probably change!
    nodes: *I3_Tree_Node,
};

pub const I3_Subscribe_reply = struct { success: bool }; //         | SUBSCRIBE     | Subscribe this IPC connection to the event types specified in the message payload. See [events].
/// i3 Eventsvs
pub const I3_Event_Workspace = struct {
    /// change ("focus", "init", "empty", "urgent", "reload", "rename", "restored", "move")
    change: []u8,
    ///A current (object) property will be present with the affected workspace whenever the type of event affects a workspace (otherwise, it will be null).
    current: ?I3_Workspace_container,
    //When the change is "focus", an old (object) property will be present with the previous workspace. When the first switch occurs (when i3 focuses the workspace visible at the beginning) there is no previous workspace, and the old property will be set to null. Also note that if the previous is empty it will get destroyed when switching, but will still be present in the "old" property.
    old: ?I3_Workspace_container,
};

///NOTE: Very similar to the `I3_Tree_Node`, Just a feel things differents.
///It comes from the subscribe event of workspace changes.
pub const I3_Workspace_container = struct {
    id: u64, //TODO: this might be platform dependent. check this.
    // since this is a pointer to the container/windows/whatever.
    type: ?[]u8 = null,
    orientation: []u8,
    scratchpad_state: []u8,
    percent: ?f32,
    urgent: bool,
    marks: [][]u8,
    focused: bool,
    output: []u8,
    layout: []u8,
    workspace_layout: []u8,
    last_split_layout: []u8,
    border: []u8,
    current_border_width: i32,
    rect: Rect,
    deco_rect: Rect,
    window_rect: Rect,
    geometry: Rect,
    name: ?[]u8,
    window_icon_padding: i32,
    num: i32 = -1,
    window: ?u32,
    window_type: ?[]u8,
    nodes: ?[]I3_Workspace_container,
    floating_nodes: ?[]I3_Workspace_container,
    focus: []u64,
    fullscreen_mode: u3,
    sticky: bool,
    floating: []u8,
    swallows: ?[]u8, //TODO: Figure out what this is supposed to be
    window_properties: ?X11_WinProps = null, //for window events.
};

pub const I3_Event_Mode = struct {
    change: []u8,
    pango_markup: bool,
};

pub const I3_Event_Window = struct {
    change: []u8,
    container: I3_Workspace_container,
};
pub const I3_Event_Output = struct {
    //TODO: Not implemented yet.
    this: bool,
};

pub const I3_event_barconfig_update = struct {
    //TODO: Not implemented yet.
    this: bool,
};

pub const I3_event_binding = struct {
    //TODO: Not implemented yet.
    this: bool,
};
pub const I3_event_shutdown = struct {
    change: []u8,
};
pub const I3_event_tick = struct {
    //TODO: Not implemented yet.
    this: bool,
};

pub const I3_Tree_Node = struct {
    // id (integer)
    // The internal ID (actually a C pointer value) of this container. Do not make any assumptions about it. You can use it to (re-)identify and address containers when talking to i3.
    id: u64,

    // name (string)
    // The internal name of this container. For all containers which are part of the tree structure down to the workspace contents, this is set to a nice human-readable name of the container. For containers that have an X11 window, the content is the title (_NET_WM_NAME property) of that window. For all other containers, the content is not defined (yet).
    name: []u8,
    //num (integer) undocumented
    //num: u32,

    // type (string)
    // Type of this container. Can be one of "root", "output", "con", "floating_con", "workspace" or "dockarea".
    type: []u8,

    // border (string)
    // Can be either "normal", "none" or "pixel", depending on the container’s border style.
    border: []u8,

    // current_border_width (integer)
    // Number of pixels of the border width.
    current_border_width: i32,

    // layout (string)
    // Can be either "splith", "splitv", "stacked", "tabbed", "dockarea" or "output". Other values might be possible in the future, should we add new layouts.
    layout: []u8,
    last_split_layout: ?[]u8 = null,
    workspace_layout: ?[]u8 = null,

    // orientation (string)
    // Can be either "none" (for non-split containers), "horizontal" or "vertical". THIS FIELD IS OBSOLETE. It is still present, but your code should not use it. Instead, rely on the layout field.
    orientation: []u8,

    // percent (float or null)
    // The percentage which this container takes in its parent. A value of null means that the percent property does not make sense for this container, for example for the root container.
    percent: ?f32,

    // rect (map)
    // The absolute display coordinates for this container. Display coordinates means that when you have two 1600x1200 monitors on a single X11 Display (the standard way), the coordinates of the first window on the second monitor are { "x": 1600, "y": 0, "width": 1600, "height": 1200 }.
    rect: Rect,

    // window_rect (map)
    // The coordinates of the actual client window inside its container. These coordinates are relative to the container and do not include the window decoration (which is actually rendered on the parent container). So, when using the default layout, you will have a 2 pixel border on each side, making the window_rect { "x": 2, "y": 0, "width": 632, "height": 366 } (for example).
    window_rect: Rect,

    // deco_rect (map)
    // The coordinates of the window decoration inside its container. These coordinates are relative to the container and do not include the actual client window.
    deco_rect: Rect,

    // geometry (map)
    // The original geometry the window specified when i3 mapped it. Used when switching a window to floating mode, for example.
    geometry: Rect,

    // window (integer or null)
    // The X11 window ID of the actual client window inside this container. This field is set to null for split containers or otherwise empty containers. This ID corresponds to what xwininfo(1) and other X11-related tools display (usually in hex).
    window: ?u32,

    // window_properties (map)
    // This optional field contains all available X11 window properties from the following list: title, instance, class, window_role, machine and transient_for.
    // NOTE: It seems like some windows have some properties missing. Set default values so the json can parse it fine.
    window_properties: ?X11_WinProps = null,

    // window_type (string)
    // The window type (_NET_WM_WINDOW_TYPE). Possible values are undefined, normal, dialog, utility, toolbar, splash, menu, dropdown_menu, popup_menu, tooltip and notification.
    window_type: ?[]u8,
    //window_icon_padding (integer) undocmented
    window_icon_padding: i32 = -1,

    // urgent (bool)
    // Whether this container (window, split container, floating container or workspace) has the urgency hint set, directly or indirectly. All parent containers up until the workspace container will be marked urgent if they have at least one urgent child.
    urgent: bool,

    // marks (array of string)
    // List of marks assigned to container
    marks: [][]u8,

    // focused (bool)
    // Whether this container is currently focused.
    focused: bool,

    // focus (array of integer)
    // List of child node IDs (see nodes, floating_nodes and id) in focus order. Traversing the tree by following the first entry in this array will result in eventually reaching the one node with focused set to true.
    focus: []u64, //NOTE: sizeOf pointer… maybe handle it better?

    // fullscreen_mode (integer)
    // Whether this container is in fullscreen state or not. Possible values are 0 (no fullscreen), 1 (fullscreened on output) or 2 (fullscreened globally). Note that all workspaces are considered fullscreened on their respective output.
    fullscreen_mode: u3,

    // floating (string)
    // Floating state of container. Can be either "auto_on", "auto_off", "user_on" or "user_off"
    floating: []u8,

    // nodes (array of node)
    /// The tiling (i.e. non-floating) child containers of this node.
    nodes: ?[]I3_Tree_Node,

    // floating_nodes (array of node)
    /// The floating child containers of this node. Only non-empty on nodes with type workspace.
    floating_nodes: ?[]I3_Tree_Node,

    // scratchpad_state (string)
    /// Whether the window is not in the scratchpad ("none"), freshly moved to the scratchpad but not yet resized ("fresh") or moved to the scratchpad and resized ("changed").
    scratchpad_state: []u8,
    swallows: ?[]u8 = null,
};

pub const I3_Get_Mark_reply = struct {
    ///TODO{kotto}: Not implemented
    succes: bool,
}; //         | MARKS         | Gets the names of all currently set marks.
pub const I3_Get_Bar_config_reply = struct {
    ///TODO{kotto}: Not implemented
    succes: bool,
}; //    | BAR_CONFIG    | Gets the specified bar configuration or the names of all bar configurations if payload is empty.
pub const I3_Get_Version_reply = struct {
    ///TODO{kotto}: Not implemented
    succes: bool,
}; //       | VERSION       | Gets the i3 version.
pub const I3_Get_Binding_modes_reply = [][]u8; // | BINDING_MODES | Gets the names of all currently configured binding modes.
pub const I3_Get_Config_reply = struct {
    ///TODO{kotto}: Not implemented
    succes: bool,
}; //        | CONFIG        | Returns the last loaded i3 config.
pub const I3_Tick_reply = struct {
    ///TODO{kotto}: Not implemented
    succes: bool,
}; //        | TICK          | Sends a tick event with the specified payload.
pub const I3_Sync_reply = struct {
    ///TODO{kotto}: Not implemented
    succes: bool,
}; //             | SYNC          | Sends an i3 sync event with the specified random value to the specified window.
pub const I3_Get_Binding_state_reply = struct {
    ///TODO{kotto}: Not implemented
    succes: bool,
}; //| BINDING_STATE | Request the current binding state, i.e. the currently active binding mode name.

pub fn is_focused(nodes: ?[]I3_Workspace_container) bool {
    for (nodes.?) |node| {
        if (node.focused) return true;
    }
    return false;
}

const testing = std.testing;

test "handle I3_Event_Workspace" {
    const str = @embedFile("../" ++ "test/json/i3_event_workspace.json");
    @setEvalBranchQuota(100000);

    var stream = std.json.TokenStream.init(str);
    var rj = try std.json.parse(I3_Event_Workspace, &stream, .{
        .allocator = testing.allocator,
        //.ignore_unknown_fields = true, //NOTE: It seems like some fields are undecumented?
    });
    try testing.expect(std.mem.eql(u8, rj.change, "focus"));
}
