// What bd needs from the operating system beyond the os library, in
// edge/sys.c: files with modes, an exclusive lock, durable appends, the
// working directory, and child processes with their output captured. Only
// the process edge (bd.goose) uses it.

namespace sys;

extern "bd_sys_getcwd" fn getcwd(out: u8[>..]&) -> bool;
extern "bd_sys_chdir" fn chdir(path: const u8[:]) -> bool;
extern "bd_sys_realpath" fn realpath(path: const u8[:], out: u8[>..]&) -> bool;
extern "bd_sys_mkdir" fn mkdir(path: const u8[:], mode: i64) -> bool;
extern "bd_sys_write_file" fn write_file(path: const u8[:], data: const u8[:], mode: i64, append: bool, sync: bool) -> bool;
extern "bd_sys_replace_file" fn replace_file(path: const u8[:], data: const u8[:], mode: i64) -> bool;
extern "bd_sys_lock" fn lock(path: const u8[:], mode: i64) -> i64;
extern "bd_sys_kind" fn kind(path: const u8[:]) -> i64;
extern "bd_sys_isatty" fn isatty(fd: i64) -> bool;
extern "bd_sys_stdin_redirected" fn stdin_redirected() -> bool;
extern "bd_sys_run" fn run(argv: const u8[:], dir: const u8[:], out: u8[>..]&, err: u8[>..]&) -> i64;

// What kind returns.
let NONE = 0;
let FILE = 1;
let DIR = 2;
