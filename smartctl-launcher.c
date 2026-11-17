// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Robert Paleka

/*
 * SnapRAID refuses to run scripts in place of its helper programs, so the
 * fake smartctl is installed as this tiny binary handing over to the script.
 */
#include <unistd.h>

int main(int argc, char* argv[])
{
	char* args[64];
	int n = 0;
	args[n++] = "/bin/bash";
	args[n++] = "/usr/libexec/lab/fake-smartctl";
	for (int i = 1; i < argc && n < 63; ++i)
		args[n++] = argv[i];
	args[n] = 0;
	execv(args[0], args);
	return 127;
}
