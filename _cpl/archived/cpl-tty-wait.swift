import Darwin

guard CommandLine.arguments.count > 1 else { exit(1) }

// Open the TTY slave before the master closes, non-blocking, don't acquire as controlling tty
let fd = open(CommandLine.arguments[1], O_RDONLY | O_NONBLOCK | O_NOCTTY)
guard fd >= 0 else { exit(0) }

// Block until POLLHUP (master PTY closed = iTerm2 window closed)
var pfd = pollfd(fd: fd, events: Int16(POLLHUP), revents: 0)
poll(&pfd, 1, -1)

close(fd)
