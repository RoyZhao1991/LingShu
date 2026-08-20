use crate::process::hide_console_window;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::env;
use std::ffi::OsStr;
use std::fs;
use std::io::Read;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Output, Stdio};

const MAX_WORKSPACE_FILES: usize = 4_000;
const MAX_WORKSPACE_DEPTH: usize = 10;

#[derive(Debug, Clone, PartialEq, Eq)]
struct WorkspaceFileStamp {
    length: u64,
    digest: [u8; 32],
}

#[derive(Debug, Clone)]
struct GitBaseline {
    git_dir: PathBuf,
    commit: String,
}

#[derive(Debug, Clone)]
pub(crate) struct WorkspaceBaseline {
    workspace: PathBuf,
    fallback_snapshot: BTreeMap<PathBuf, WorkspaceFileStamp>,
    git: Option<GitBaseline>,
}

/// Tracks files changed by one Loop run without modifying the user's repository.
///
/// A bare shadow repository is stored under LingShu's runtime data directory and is
/// always invoked with an explicit work tree. The Workspace never receives a `.git`
/// directory. Git is the primary content-level source of truth; a content-hash snapshot
/// is retained as a cross-platform fallback when Git is unavailable.
#[derive(Debug, Clone)]
pub(crate) struct WorkspaceDeltaTracker {
    shadow_root: PathBuf,
    git_executable: PathBuf,
}

impl WorkspaceDeltaTracker {
    pub(crate) fn new(data_dir: impl AsRef<Path>) -> Self {
        Self {
            shadow_root: data_dir.as_ref().join("ShadowGits"),
            git_executable: discover_git_executable(),
        }
    }

    #[cfg(test)]
    fn with_git_executable(data_dir: impl AsRef<Path>, executable: impl Into<PathBuf>) -> Self {
        Self {
            shadow_root: data_dir.as_ref().join("ShadowGits"),
            git_executable: executable.into(),
        }
    }

    pub(crate) fn baseline(&self, workspace: &Path) -> WorkspaceBaseline {
        let workspace = normalize_workspace(workspace);
        let fallback_snapshot = workspace_inventory(&workspace);
        let git = self.git_baseline(&workspace);
        WorkspaceBaseline {
            workspace,
            fallback_snapshot,
            git,
        }
    }

    pub(crate) fn changed_files(&self, baseline: WorkspaceBaseline) -> Vec<PathBuf> {
        if let Some(git) = &baseline.git {
            if let Some(paths) = self.git_changed_files(&baseline.workspace, git) {
                return paths;
            }
        }
        let after = workspace_inventory(&baseline.workspace);
        changed_snapshot_files(&baseline.fallback_snapshot, &after)
    }

    fn git_baseline(&self, workspace: &Path) -> Option<GitBaseline> {
        if !workspace.is_dir() || !self.git_available() {
            return None;
        }
        fs::create_dir_all(&self.shadow_root).ok()?;
        let git_dir = self.shadow_dir(workspace);
        if !git_dir.join("HEAD").is_file() {
            fs::create_dir_all(&git_dir).ok()?;
            let initialized = self.run_git(None, Some(&git_dir), ["init", "-q"]);
            if !initialized.is_some_and(|output| output.status.success()) {
                return None;
            }
            for (key, value) in [
                ("user.name", "LingShu"),
                ("user.email", "lingshu@local"),
                ("core.quotePath", "false"),
                ("core.autocrlf", "false"),
                ("core.filemode", "false"),
                ("commit.gpgsign", "false"),
                ("gc.auto", "0"),
            ] {
                let _ = self.run_git(
                    None,
                    Some(&git_dir),
                    [OsStr::new("config"), OsStr::new(key), OsStr::new(value)],
                );
            }
        }
        let added = self.run_git(
            Some(workspace),
            Some(&git_dir),
            [OsStr::new("add"), OsStr::new("-A")],
        )?;
        if !added.status.success() {
            return None;
        }
        let committed = self.run_git(
            Some(workspace),
            Some(&git_dir),
            [
                OsStr::new("commit"),
                OsStr::new("-q"),
                OsStr::new("--allow-empty"),
                OsStr::new("-m"),
                OsStr::new("lingshu-baseline"),
            ],
        )?;
        if !committed.status.success() {
            return None;
        }
        let head = self.run_git(
            None,
            Some(&git_dir),
            [OsStr::new("rev-parse"), OsStr::new("HEAD")],
        )?;
        if !head.status.success() {
            return None;
        }
        let commit = String::from_utf8_lossy(&head.stdout).trim().to_string();
        (!commit.is_empty()).then_some(GitBaseline { git_dir, commit })
    }

    fn git_changed_files(&self, workspace: &Path, baseline: &GitBaseline) -> Option<Vec<PathBuf>> {
        let added = self.run_git(
            Some(workspace),
            Some(&baseline.git_dir),
            [OsStr::new("add"), OsStr::new("-A")],
        )?;
        if !added.status.success() {
            return None;
        }
        let diff = self.run_git(
            Some(workspace),
            Some(&baseline.git_dir),
            [
                OsStr::new("diff"),
                OsStr::new("--cached"),
                OsStr::new("--no-renames"),
                OsStr::new("--name-status"),
                OsStr::new(&baseline.commit),
            ],
        )?;
        if !diff.status.success() {
            return None;
        }
        let output = String::from_utf8_lossy(&diff.stdout);
        let mut paths = Vec::new();
        for line in output.lines() {
            let Some((status, raw_path)) = line.split_once('\t') else {
                continue;
            };
            if !matches!(status.chars().next(), Some('A' | 'M')) {
                continue;
            }
            let relative = PathBuf::from(raw_path);
            if !safe_relative_path(&relative) || is_build_or_cache_noise(&relative) {
                continue;
            }
            let absolute = workspace.join(&relative);
            let Ok(metadata) = fs::symlink_metadata(&absolute) else {
                continue;
            };
            if metadata.file_type().is_file() && !metadata.file_type().is_symlink() {
                paths.push(relative);
            }
        }
        paths.sort();
        paths.dedup();
        Some(paths)
    }

    fn shadow_dir(&self, workspace: &Path) -> PathBuf {
        let digest = Sha256::digest(workspace.to_string_lossy().as_bytes());
        let key = digest[..8]
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        self.shadow_root.join(key)
    }

    fn git_available(&self) -> bool {
        self.run_git::<&OsStr, 1>(None, None, [OsStr::new("--version")])
            .is_some_and(|output| output.status.success())
    }

    fn run_git<I, const N: usize>(
        &self,
        work_tree: Option<&Path>,
        git_dir: Option<&Path>,
        args: [I; N],
    ) -> Option<Output>
    where
        I: AsRef<OsStr>,
    {
        let mut command = Command::new(&self.git_executable);
        hide_console_window(&mut command);
        if let Some(git_dir) = git_dir {
            command.arg("--git-dir").arg(git_dir);
        }
        if let Some(work_tree) = work_tree {
            command.arg("--work-tree").arg(work_tree);
        }
        command
            .args(args)
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_OPTIONAL_LOCKS", "0")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .ok()
    }
}

fn discover_git_executable() -> PathBuf {
    if let Some(path) = env::var_os("LINGSHU_GIT_EXECUTABLE") {
        return PathBuf::from(path);
    }
    #[cfg(target_os = "macos")]
    for path in [
        "/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
    ] {
        if Path::new(path).is_file() {
            return PathBuf::from(path);
        }
    }
    #[cfg(target_os = "windows")]
    for path in [
        r"C:\Program Files\Git\cmd\git.exe",
        r"C:\Program Files\Git\bin\git.exe",
        r"C:\Program Files (x86)\Git\cmd\git.exe",
    ] {
        if Path::new(path).is_file() {
            return PathBuf::from(path);
        }
    }
    PathBuf::from("git")
}

fn normalize_workspace(workspace: &Path) -> PathBuf {
    fs::canonicalize(workspace).unwrap_or_else(|_| workspace.to_path_buf())
}

fn safe_relative_path(path: &Path) -> bool {
    !path.is_absolute()
        && path.components().all(|component| {
            !matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
}

fn is_build_or_cache_noise(path: &Path) -> bool {
    const SKIP_DIRECTORIES: &[&str] = &[
        ".git",
        ".lingshu",
        ".build",
        "node_modules",
        "__pycache__",
        ".venv",
        "venv",
        "dist",
        "build",
        "target",
        ".pytest_cache",
        ".idea",
        ".next",
        ".cache",
        "DerivedData",
    ];
    if path.components().any(|component| {
        let value = component.as_os_str().to_string_lossy();
        SKIP_DIRECTORIES
            .iter()
            .any(|candidate| value.eq_ignore_ascii_case(candidate))
    }) {
        return true;
    }
    let extension = path
        .extension()
        .and_then(OsStr::to_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(extension.as_str(), "pyc" | "pyo" | "class" | "o")
        || path
            .file_name()
            .is_some_and(|name| name == OsStr::new(".DS_Store"))
}

fn workspace_inventory(root: &Path) -> BTreeMap<PathBuf, WorkspaceFileStamp> {
    let mut files = BTreeMap::new();
    collect_workspace_files(root, root, 0, &mut files);
    files
}

fn collect_workspace_files(
    root: &Path,
    directory: &Path,
    depth: usize,
    files: &mut BTreeMap<PathBuf, WorkspaceFileStamp>,
) {
    if depth > MAX_WORKSPACE_DEPTH || files.len() >= MAX_WORKSPACE_FILES {
        return;
    }
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        if files.len() >= MAX_WORKSPACE_FILES {
            break;
        }
        let path = entry.path();
        let relative = path
            .strip_prefix(root)
            .map(Path::to_path_buf)
            .unwrap_or_else(|_| path.clone());
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_dir() {
            if is_build_or_cache_noise(&relative) {
                continue;
            }
            collect_workspace_files(root, &path, depth + 1, files);
            continue;
        }
        if !metadata.is_file() || is_build_or_cache_noise(&relative) {
            continue;
        }
        let Some(digest) = file_digest(&path) else {
            continue;
        };
        files.insert(
            relative,
            WorkspaceFileStamp {
                length: metadata.len(),
                digest,
            },
        );
    }
}

fn file_digest(path: &Path) -> Option<[u8; 32]> {
    let mut file = fs::File::open(path).ok()?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).ok()?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Some(hasher.finalize().into())
}

fn changed_snapshot_files(
    before: &BTreeMap<PathBuf, WorkspaceFileStamp>,
    after: &BTreeMap<PathBuf, WorkspaceFileStamp>,
) -> Vec<PathBuf> {
    after
        .iter()
        .filter_map(|(path, stamp)| (before.get(path) != Some(stamp)).then(|| path.clone()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn shadow_git_is_outside_workspace_and_tracks_content_changes() {
        let data = tempdir().unwrap();
        let workspace = tempdir().unwrap();
        let tracker = WorkspaceDeltaTracker::new(data.path());
        if !tracker.git_available() {
            return;
        }
        fs::write(workspace.path().join("existing.txt"), "v1\n").unwrap();
        fs::write(workspace.path().join("touch-only.txt"), "same\n").unwrap();
        let baseline = tracker.baseline(workspace.path());
        assert!(baseline.git.is_some());
        assert!(!workspace.path().join(".git").exists());
        assert!(data.path().join("ShadowGits").is_dir());

        fs::write(workspace.path().join("existing.txt"), "v1\nv2\n").unwrap();
        fs::write(workspace.path().join("touch-only.txt"), "same\n").unwrap();
        fs::write(workspace.path().join("new.md"), "# delivery\n").unwrap();
        let changes = tracker.changed_files(baseline);
        assert!(changes.contains(&PathBuf::from("existing.txt")));
        assert!(changes.contains(&PathBuf::from("new.md")));
        assert!(!changes.contains(&PathBuf::from("touch-only.txt")));
    }

    #[test]
    fn honors_gitignore_and_filters_build_noise() {
        let data = tempdir().unwrap();
        let workspace = tempdir().unwrap();
        let tracker = WorkspaceDeltaTracker::new(data.path());
        if !tracker.git_available() {
            return;
        }
        fs::write(workspace.path().join(".gitignore"), "generated/\n").unwrap();
        let baseline = tracker.baseline(workspace.path());
        fs::create_dir_all(workspace.path().join("generated")).unwrap();
        fs::create_dir_all(workspace.path().join("node_modules/pkg")).unwrap();
        fs::write(workspace.path().join("generated/ignored.txt"), "ignored").unwrap();
        fs::write(
            workspace.path().join("node_modules/pkg/index.js"),
            "ignored",
        )
        .unwrap();
        fs::write(workspace.path().join("deliverable.docx"), "real").unwrap();
        let changes = tracker.changed_files(baseline);
        assert_eq!(changes, vec![PathBuf::from("deliverable.docx")]);
    }

    #[test]
    fn content_snapshot_fallback_ignores_mtime_only_rewrites() {
        let data = tempdir().unwrap();
        let workspace = tempdir().unwrap();
        let tracker = WorkspaceDeltaTracker::with_git_executable(
            data.path(),
            workspace.path().join("missing-git"),
        );
        fs::write(workspace.path().join("same.txt"), "same").unwrap();
        let baseline = tracker.baseline(workspace.path());
        assert!(baseline.git.is_none());
        fs::write(workspace.path().join("same.txt"), "same").unwrap();
        fs::write(workspace.path().join("new.txt"), "new").unwrap();
        assert_eq!(
            tracker.changed_files(baseline),
            vec![PathBuf::from("new.txt")]
        );
    }
}
