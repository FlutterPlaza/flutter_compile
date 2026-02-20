export interface DoctorCheck {
  name: string;
  category: "tools" | "engine_tools" | "config" | "environments";
  status:
    | "ok"
    | "missing"
    | "invalid"
    | "not_found"
    | "not_configured"
    | "missing_remotes"
    | "not_git_repo"
    | "error";
  path?: string;
  error?: string;
  missing_remotes?: string[];
}

export interface EngineStatus {
  configured: boolean;
  engine_path?: string;
  source_dir?: string;
  source_exists?: boolean;
  host_cpu?: string;
  builds?: BuildEntry[];
  flutter_project?: boolean;
}

export interface BuildEntry {
  name: string;
  size: string;
}
