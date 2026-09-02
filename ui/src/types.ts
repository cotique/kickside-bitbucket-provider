// No host-driven props: the bitbucket-provider page fetches its own data.
export interface ComponentProps {}

export interface ModuleStatus {
  module: string
  status: string
  capabilities: string[]
}
