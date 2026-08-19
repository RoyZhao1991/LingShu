#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

use std::io;

/// Owns the operating-system container for one spawned process tree.
///
/// Dropping Tokio's `Child` kills only that process. Plugins and managed Loop harnesses may launch
/// compilers, renderers, or shell commands of their own, so cancellation must also tear down every
/// descendant before the runtime releases its queue slot.
pub(crate) struct ProcessTreeGuard {
    #[cfg(unix)]
    process_group: i32,
    #[cfg(target_os = "windows")]
    job: usize,
}

pub(crate) fn hide_console_window(command: &mut std::process::Command) {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;

        command.creation_flags(CREATE_NO_WINDOW);
    }

    #[cfg(not(target_os = "windows"))]
    let _ = command;
}

pub(crate) fn hide_tokio_console_window(command: &mut tokio::process::Command) {
    hide_console_window(command.as_std_mut());
}

/// Spawn a blocking child in the same independently owned process-tree container used by Tokio
/// tools. Preview rendering runs on a blocking worker, but must retain identical descendant-kill
/// semantics when the foreground task is stopped.
pub(crate) fn spawn_process_tree(
    command: &mut std::process::Command,
) -> io::Result<(std::process::Child, ProcessTreeGuard)> {
    hide_console_window(command);
    configure_std_process_tree(command);

    let mut child = command.spawn()?;
    match ProcessTreeGuard::attach_std(&child) {
        Ok(guard) => Ok((child, guard)),
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            Err(error)
        }
    }
}

/// Spawn a Tokio child in an independently owned process tree.
///
/// Unix children become process-group leaders before `exec`. Windows children are immediately
/// assigned to a Job Object configured with `KILL_ON_JOB_CLOSE`. `kill_on_drop` remains enabled as
/// a direct-child fallback, while `ProcessTreeGuard` supplies the missing descendant teardown.
pub(crate) fn spawn_tokio_process_tree(
    command: &mut tokio::process::Command,
) -> io::Result<(tokio::process::Child, ProcessTreeGuard)> {
    command.kill_on_drop(true);
    hide_tokio_console_window(command);
    configure_process_tree(command);

    let mut child = command.spawn()?;
    match ProcessTreeGuard::attach(&child) {
        Ok(guard) => Ok((child, guard)),
        Err(error) => {
            // The process was created but never became safely owned. Do not let it continue with
            // weaker cancellation semantics than the caller requested.
            let _ = child.start_kill();
            Err(error)
        }
    }
}

#[cfg(unix)]
fn configure_process_tree(command: &mut tokio::process::Command) {
    use std::os::unix::process::CommandExt;

    command.as_std_mut().process_group(0);
}

#[cfg(unix)]
fn configure_std_process_tree(command: &mut std::process::Command) {
    use std::os::unix::process::CommandExt;

    command.process_group(0);
}

#[cfg(not(unix))]
fn configure_std_process_tree(command: &mut std::process::Command) {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        use windows_sys::Win32::System::Threading::CREATE_SUSPENDED;

        command.creation_flags(CREATE_NO_WINDOW | CREATE_SUSPENDED);
    }

    #[cfg(not(target_os = "windows"))]
    let _ = command;
}

#[cfg(not(unix))]
fn configure_process_tree(command: &mut tokio::process::Command) {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        use windows_sys::Win32::System::Threading::CREATE_SUSPENDED;

        // Assignment after an ordinary spawn has a race in which the new process can launch an
        // unowned grandchild first. Start suspended, attach the Job Object, then resume its primary
        // thread so every descendant is born inside the job.
        command
            .as_std_mut()
            .creation_flags(CREATE_NO_WINDOW | CREATE_SUSPENDED);
    }

    #[cfg(not(target_os = "windows"))]
    let _ = command;
}

#[cfg(unix)]
impl ProcessTreeGuard {
    fn attach(child: &tokio::process::Child) -> io::Result<Self> {
        Self::attach_process_id(child.id())
    }

    fn attach_std(child: &std::process::Child) -> io::Result<Self> {
        Self::attach_process_id(Some(child.id()))
    }

    fn attach_process_id(process_id: Option<u32>) -> io::Result<Self> {
        let process_group = process_id
            .and_then(|id| i32::try_from(id).ok())
            .ok_or_else(|| io::Error::other("spawned process has no valid process-group id"))?;
        Ok(Self { process_group })
    }
}

#[cfg(unix)]
impl Drop for ProcessTreeGuard {
    fn drop(&mut self) {
        const SIGKILL: i32 = 9;
        unsafe extern "C" {
            fn kill(process_id: i32, signal: i32) -> i32;
        }

        // A negative PID addresses the entire process group. Failure means the group has already
        // exited, which is the desired terminal state.
        let _ = unsafe { kill(-self.process_group, SIGKILL) };
    }
}

#[cfg(target_os = "windows")]
impl ProcessTreeGuard {
    fn attach(child: &tokio::process::Child) -> io::Result<Self> {
        let process = child
            .raw_handle()
            .ok_or_else(|| io::Error::other("spawned process has no Windows process handle"))?;
        Self::attach_process(process.cast(), child.id())
    }

    fn attach_std(child: &std::process::Child) -> io::Result<Self> {
        use std::os::windows::io::AsRawHandle;

        Self::attach_process(child.as_raw_handle().cast(), Some(child.id()))
    }

    fn attach_process(
        process: windows_sys::Win32::Foundation::HANDLE,
        process_id: Option<u32>,
    ) -> io::Result<Self> {
        use std::mem::{size_of, zeroed};
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
            SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        };

        let job = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if job.is_null() {
            return Err(io::Error::last_os_error());
        }

        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { zeroed() };
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let configured = unsafe {
            SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                (&raw const limits).cast(),
                size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
        };
        if configured == 0 {
            let error = io::Error::last_os_error();
            unsafe {
                CloseHandle(job);
            }
            return Err(error);
        }

        let assigned = unsafe { AssignProcessToJobObject(job, process) };
        if assigned == 0 {
            let error = io::Error::last_os_error();
            unsafe {
                CloseHandle(job);
            }
            return Err(error);
        }

        if let Err(error) = resume_suspended_process(process_id) {
            unsafe {
                CloseHandle(job);
            }
            return Err(error);
        }

        Ok(Self { job: job as usize })
    }
}

#[cfg(target_os = "windows")]
fn resume_suspended_process(process_id: Option<u32>) -> io::Result<()> {
    use std::mem::size_of;
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Thread32First, Thread32Next, TH32CS_SNAPTHREAD, THREADENTRY32,
    };
    use windows_sys::Win32::System::Threading::{OpenThread, ResumeThread, THREAD_SUSPEND_RESUME};

    let process_id =
        process_id.ok_or_else(|| io::Error::other("spawned process has no Windows process id"))?;
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }

    let mut entry = THREADENTRY32 {
        dwSize: size_of::<THREADENTRY32>() as u32,
        ..Default::default()
    };
    let mut present = unsafe { Thread32First(snapshot, &raw mut entry) } != 0;
    while present {
        if entry.th32OwnerProcessID == process_id {
            let thread = unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID) };
            if !thread.is_null() {
                let resumed = unsafe { ResumeThread(thread) };
                let resume_error = (resumed == u32::MAX).then(io::Error::last_os_error);
                unsafe {
                    CloseHandle(thread);
                    CloseHandle(snapshot);
                }
                if let Some(error) = resume_error {
                    return Err(error);
                }
                return Ok(());
            }
        }
        present = unsafe { Thread32Next(snapshot, &raw mut entry) } != 0;
    }

    let error = io::Error::last_os_error();
    unsafe {
        CloseHandle(snapshot);
    }
    Err(io::Error::new(
        error.kind(),
        format!("could not resume suspended process {process_id}: {error}"),
    ))
}

#[cfg(target_os = "windows")]
impl Drop for ProcessTreeGuard {
    fn drop(&mut self) {
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::JobObjects::TerminateJobObject;

        let job = self.job as windows_sys::Win32::Foundation::HANDLE;
        unsafe {
            // Explicit termination makes cancellation immediate; KILL_ON_JOB_CLOSE is retained as
            // a kernel-enforced fallback if this call races normal process exit.
            let _ = TerminateJobObject(job, 1);
            let _ = CloseHandle(job);
        }
    }
}

#[cfg(not(any(unix, target_os = "windows")))]
impl ProcessTreeGuard {
    fn attach(_child: &tokio::process::Child) -> io::Result<Self> {
        Ok(Self {})
    }

    fn attach_std(_child: &std::process::Child) -> io::Result<Self> {
        Ok(Self {})
    }
}
