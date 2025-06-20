const std = @import("std");
const termios = @import("termios.zig");
const unistd = @import("unistd.zig");
const ioctl = @import("ioctl.zig");

// odin-like
const u16x2 = @Vector(2, u16);
const f16x2 = @Vector(2, f16);
// ascii codes
const CSI = "\x1b[";
const ENTER_ALTERNATE_SCREEN_BUFFER = CSI ++ "?1049h";
const HIDE_CURSOR = CSI ++ "?25l";
const CLEAR_SCREEN = CSI ++ "2J";
const MOVE_CURSOR_TO_HOME = CSI ++ "H";
const EXIT_ALTERNATE_SCREEN_BUFFER = CSI ++ "?1049l";
const SHOW_CURSOR = CSI ++ "?25h";
// hi from opencode
const LOGO = [_][]const u8{
    "▄▀▀▄ ▄▀▀▀ ▄█▄ █▄▀▄ █▀▀█ █   ▄▀▀▄ █▀▀▄ ▀  █  █ █▀▄▀▄",
    "█▄▄█ ▀▀▀▄  █░ █    █░░█ █░░ █▄▄█ █▀▀█ █░ █░░█ █ █ █",
    "▀  ▀ ▀▀▀    ▀ ▀    ▀▀▀▀ ▀▀▀ ▀  ▀ ▀▀▀   ▀  ▀▀  ▀ ▀ ▀",
};
const LOGO_WIDTH = 51;

const Modes = enum {
    insert,
    normal,
    command,
};
const app_errors = error {
    EXIT_FAILURE,
};

// fuck errors
fn write(bytes: []const u8) void {
    _ = stdout.write(bytes) catch @panic("write failed");
}

fn print(comptime format: []const u8, args: anytype) void {
    _ = stdout_writer.print(format, args) catch @panic("print failed");
    
}

fn moveCursor(pos: u16x2) void {
    print(CSI ++ "{};{}H", .{pos[1],pos[0]});
}

fn entering_insert() void {
    moveCursor(Layout.bottom_line.startPos());
    write("-- INSERT --");
}

fn entering_normal() void {
    moveCursor(Layout.bottom_line.startPos());
    write("            ");
}

const ChainedString = struct {
    head: ChainNode,
    tail: *ChainNode,

    const link_size = 64;
    const ChainNode = struct {
        next: ?*ChainNode,
        prev: ?*ChainNode,
        string: [link_size]u8,
        end: u16 = 0,
    };
};

const RELATIVE_DIMENTIONS = 1<<0;
const RELATIVE_POSITION =   1<<1;
const Element = struct {
    features: i64,
    pos: f16x2,
    dimentions: f16x2,

    const Self = @This();
    pub fn startPos(self: Self) u16x2 {
        var retval: u16x2 = undefined;
        if (self.features & RELATIVE_POSITION != 0) {
            if (self.features & RELATIVE_DIMENTIONS != 0) {
                const initial_pos = (window_size-window_size*self.dimentions)*f16x2{0.5, 0.0};
                const shift = window_size*self.pos;
                retval = @as(u16x2, @intFromFloat(initial_pos+shift));
            } else {
                const initial_pos = (window_size-self.dimentions)*f16x2{0.5, 0.0};
                const shift = window_size*self.pos;
                retval = @as(u16x2, @intFromFloat(initial_pos+shift));
            }
        }
        else {
            if (self.features & RELATIVE_DIMENTIONS != 0) {
                @panic("We do not support relative dimention + absolute posisition");
            } else {
                var pos = self.pos;
                if (pos[0]<0) {
                    pos[0] = window_size[0]+pos[0];
                }
                if (pos[1]<0) {
                    pos[1] = window_size[1]+pos[1];
                }
                retval = @as(u16x2, @intFromFloat(pos));
            }
        }
        return retval;
    }
};


const Layout = struct {
    var logo = Element {
        .features = RELATIVE_POSITION,
        .pos = .{0.0, 0.1},
        .dimentions = .{51, 3},
    };

    var plan = Element {
        .features = RELATIVE_DIMENTIONS | RELATIVE_POSITION,
        .pos = .{0.0, 0.3},
        .dimentions = .{0.7, 0.6},
    };
    
    var bottom_line = Element {
        .features = 0,
        .pos = .{0,-1},
        .dimentions = .{-1,1},
    };
};

// App state:
var mode: Modes = .normal;
var quit: bool = false;
var plan_points: [20]ChainedString = undefined;
var plans_number: u16 = 0;
var current_plan_point: u16 = 0;
var stdout: std.fs.File = undefined;
var stdin: std.fs.File = undefined;
var stdout_writer: std.fs.File.Writer = undefined;
var window_size: f16x2 = undefined;

pub fn main() !void {
    write(ENTER_ALTERNATE_SCREEN_BUFFER);
    defer write(EXIT_ALTERNATE_SCREEN_BUFFER);
    var c_err: c_int = undefined;
    stdout = std.io.getStdOut();
    stdin = std.io.getStdIn();
    stdout_writer = stdout.writer();
    var chain_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer chain_arena.deinit();
    const chain_arena_allocator = chain_arena.allocator();
    _ = chain_arena_allocator;

    const cwd = std.fs.cwd();
    const state_file = cwd.createFile(".astrolabium", .{.mode = 0o600}) catch |err| {
        std.log.err("File .astrolabium cannot be accessed in this directory!", .{});
        return err;
    };
    defer state_file.close();

    var original_termios_settings: termios.termios = undefined;
    c_err = termios.tcgetattr(unistd.STDIN_FILENO, &original_termios_settings);
    if (c_err == -1) {
        std.log.err("tcgetattr failed", .{});
        return error.EXIT_FAILURE;
    }
    var raw_termios_settings = original_termios_settings;
    raw_termios_settings.c_lflag &= @bitCast(@as(i64, ~(termios.ICANON | termios.ECHO | termios.ISIG)));
    raw_termios_settings.c_cc[termios.VMIN] = 1;
    raw_termios_settings.c_cc[termios.VTIME] = 0;
    c_err = termios.tcsetattr(unistd.STDIN_FILENO, termios.TCSAFLUSH, &raw_termios_settings);
    if (c_err == -1) {
        std.log.err("tcsetattr raw mode failed", .{});
        return error.EXIT_FAILURE;
    }
    defer {
        c_err = termios.tcsetattr(unistd.STDIN_FILENO, termios.TCSAFLUSH, &original_termios_settings);
        if (c_err == -1) {
            std.log.err("tcsetattr original mode failed", .{});
        }
    }

    var ws: ioctl.winsize = undefined;
    c_err = ioctl.ioctl(unistd.STDOUT_FILENO, termios.TIOCGWINSZ, &ws);
    if (c_err == -1) {
        std.log.err("ioctl failed", .{});
    }
    window_size[0] = @floatFromInt(ws.ws_col);
    window_size[1] = @floatFromInt(ws.ws_row);

    const start_pos = Layout.logo.startPos();
    moveCursor(start_pos);
    write(LOGO[0]);
    moveCursor(start_pos+u16x2{0,1});
    write(LOGO[1]);
    moveCursor(start_pos+u16x2{0,2});
    write(LOGO[2]);

    moveCursor(Layout.plan.startPos());
    var user_cursor_pos = Layout.plan.startPos()+u16x2{3,0};
    for (&plan_points) |*plan_point| {
        plan_point.tail = &plan_point.head;
    }


    var plan_point: *ChainedString = undefined;
    while (!quit) {
        var buffer: [1]u8 = undefined;
        _ = stdin.read(&buffer) catch {
            continue;
        };
        if (mode == .normal) {
            switch (buffer[0]) {
                'x' => quit = true,
                'i' => {
                    entering_insert();
                    if (plans_number == 0) {
                        plans_number = 1;
                        moveCursor(Layout.plan.startPos());
                        write("1. ");
                        plan_point = &plan_points[current_plan_point];
                    }
                    mode = .insert;
                },
                'o' => {
                    entering_insert();
                    plans_number += 1;
                    current_plan_point += 1;
                    moveCursor(Layout.plan.startPos()+u16x2{0,current_plan_point*2});
                    plan_point = &plan_points[current_plan_point];
                    print("{}.", .{plans_number});
                    
                },
                'h' => {
                    user_cursor_pos -= u16x2{1,0};
                    moveCursor(user_cursor_pos);
                },
                'l' => {
                    user_cursor_pos += u16x2{1,0};
                    moveCursor(user_cursor_pos);
                },
                ':' => {
                    mode = .command;
                    moveCursor(Layout.bottom_line.startPos());
                    write(":");
                },
                else => {},
            }
        } else if (mode == .insert) {
            if (buffer[0] == '\x1b') {
                entering_normal();
                if (plan_point.tail.end == 0) {
                    moveCursor(Layout.plan.startPos());
                    write("  ");
                    plans_number -= 1;
                }
                mode = .normal; 
                continue;
            }
            else if (buffer[0] >= 32 and buffer[0] < 127) {
                var link = plan_point.tail;
                if (link.end < ChainedString.link_size) {
                    moveCursor(user_cursor_pos);
                    user_cursor_pos[0] += 1;
                    write(buffer[0..1]);
                    link.string[link.end] = buffer[0];
                    link.end += 1;
                }
            }
            else if (buffer[0] == 127) {
                var link = plan_point.tail;
                if (link.end > 0) {
                    user_cursor_pos[0] -= 1;
                    moveCursor(user_cursor_pos);
                    write(" ");
                    moveCursor(user_cursor_pos);
                    link.end -= 1;
                }
            }
        } else if (mode == .command) {
            if (buffer[0] == '\x1b') {
                entering_normal();
                mode = .normal; 
                moveCursor(Layout.bottom_line.startPos());
                write(" ");
                continue;
            }
        }
    }
}
