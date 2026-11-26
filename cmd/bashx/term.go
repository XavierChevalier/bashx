//go:build linux || darwin || freebsd || netbsd || openbsd

package main

import (
	"syscall"
	"unsafe"
)

// isTerminal reports whether fd is a terminal (tcgetattr succeeds).
func isTerminal(fd int) bool {
	var t syscall.Termios
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), ioctlGetTermios, uintptr(unsafe.Pointer(&t)))
	return errno == 0
}

// terminalSize is the width and height of the terminal on fd.
func terminalSize(fd int) (cols, rows int, ok bool) {
	var ws struct{ Row, Col, X, Y uint16 }
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TIOCGWINSZ, uintptr(unsafe.Pointer(&ws)))
	return int(ws.Col), int(ws.Row), errno == 0
}
