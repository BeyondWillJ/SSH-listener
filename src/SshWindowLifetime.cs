// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 BeyondWillJ
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace SshListener {
    // A suspended child is assigned before any of its code runs, so descendants
    // cannot escape the job in the gap between process creation and assignment.
    public sealed class WindowLifetime : IDisposable {
        [StructLayout(LayoutKind.Sequential)] private struct BasicLimits {
            public long ProcessTime, JobTime;
            public uint Flags;
            public UIntPtr MinWorkingSet, MaxWorkingSet;
            public uint ActiveProcesses;
            public UIntPtr Affinity;
            public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)] private struct IoCounters {
            public ulong ReadOperations, WriteOperations, OtherOperations;
            public ulong ReadBytes, WriteBytes, OtherBytes;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits {
            public BasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct StartupInfo {
            public uint cb;
            public string reserved, desktop, title;
            public uint x, y, xSize, ySize, xChars, yChars, fill, flags;
            public ushort show, reserved2Size;
            public IntPtr reserved2, stdin, stdout, stderr;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo {
            public IntPtr process, thread;
            public uint pid, tid;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool SetInformationJobObject(SafeFileHandle job, int kind, IntPtr data, uint size);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool CreateProcess(string application, StringBuilder command,
            IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles,
            uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo process);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll")] private static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] private static extern IntPtr GetStdHandle(int number);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool DuplicateHandle(
            IntPtr sourceProcess, IntPtr source, IntPtr targetProcess, out IntPtr target,
            uint access, bool inherit, uint options);
        private SafeFileHandle job;
        public WindowLifetime() {
            job = CreateJobObject(IntPtr.Zero, null);
            if (job.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            ExtendedLimits limits = new ExtendedLimits();
            limits.Basic.Flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            int size = Marshal.SizeOf(typeof(ExtendedLimits));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try {
                Marshal.StructureToPtr(limits, buffer, false);
                if (!SetInformationJobObject(job, 9, buffer, (uint)size)) {
                    int error = Marshal.GetLastWin32Error(); job.Dispose(); throw new Win32Exception(error);
                }
            } finally { Marshal.FreeHGlobal(buffer); }
        }
        public Process Start(string executable, string arguments) {
            if (job == null || job.IsClosed) throw new ObjectDisposedException("WindowLifetime");
            StartupInfo startup = new StartupInfo();
            startup.cb = (uint)Marshal.SizeOf(typeof(StartupInfo));
            startup.flags = 0x100; // STARTF_USESTDHANDLES
            IntPtr current = GetCurrentProcess();
            IntPtr[] streams = new IntPtr[3];
            ProcessInfo info;
            try {
                for (int i = 0; i < 3; i++) {
                    if (!DuplicateHandle(current, GetStdHandle(-10 - i), current, out streams[i], 0, true, 2))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                startup.stdin = streams[0]; startup.stdout = streams[1]; startup.stderr = streams[2];
                // Standard streams must be valid inherited handles: sshd uses them
                // while creating its authenticated child processes. The job handle
                // itself is non-inheritable and remains owned by the launcher.
                if (!CreateProcess(executable, new StringBuilder("\"" + executable + "\" " + arguments),
                    IntPtr.Zero, IntPtr.Zero, true, 4, IntPtr.Zero, null, ref startup, out info))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally { foreach (IntPtr stream in streams) if (stream != IntPtr.Zero) CloseHandle(stream); }
            try {
                if (!AssignProcessToJobObject(job, info.process)) throw new Win32Exception(Marshal.GetLastWin32Error());
                Process result = Process.GetProcessById((int)info.pid);
                // Open a stable process handle before resuming a potentially short-lived child.
                IntPtr unused = result.Handle;
                if (ResumeThread(info.thread) == UInt32.MaxValue) {
                    result.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                return result;
            } catch { TerminateProcess(info.process, 1); throw; }
            finally { CloseHandle(info.thread); CloseHandle(info.process); }
        }
        public void Dispose() { if (job != null) { job.Dispose(); job = null; } }
    }
}
