# t3code-flake

Nix flake packaging [T3 Code](https://github.com/pingdotgg/t3code) (pingdotgg's
VS Code fork) for Linux and macOS. Pinned versions and hashes live in
[`sources.json`](./sources.json); a scheduled GitHub Action bumps them and
pushes to `main` when upstream releases a new version.

## Supported systems

| System           | Artifact                        |
| ---------------- | ------------------------------- |
| `x86_64-linux`   | AppImage wrapped with `appimageTools.wrapType2` |
| `aarch64-darwin` | `.app` bundle extracted from the arm64 zip |
| `x86_64-darwin`  | `.app` bundle extracted from the x64 zip |

## Run it without installing

```sh
nix run github:<owner>/t3code-flake
```

## Add to a NixOS / home-manager / nix-darwin config

```nix
{
  inputs.t3code.url = "github:<owner>/t3code-flake";

  # in your system/home config:
  environment.systemPackages = [ inputs.t3code.packages.${pkgs.system}.default ];
  # or on darwin / home-manager:
  # home.packages = [ inputs.t3code.packages.${pkgs.system}.default ];
}
```

On macOS the package installs the `.app` under `$out/Applications` and creates a
`t3code` symlink in `$out/bin`. Use [`mkAlias`](https://github.com/nix-darwin/nix-darwin)
or copy the bundle into `~/Applications` if you want it in Launchpad.

## Updating manually

```sh
./scripts/update.sh
```

Requires `jq` and either `gh` or `curl` on `$PATH`. Prints the new version on
stdout if anything changed, otherwise stays silent and exits 0.

## Auto-update workflow

[`.github/workflows/update.yml`](./.github/workflows/update.yml) runs daily
(and on demand via `workflow_dispatch`):

1. Runs `scripts/update.sh` against the latest upstream release.
2. If `sources.json` changed, builds the flake for `x86_64-linux` and
   `aarch64-darwin` to confirm the new hashes actually resolve.
3. Commits the bump with message `t3code: bump to vX.Y.Z` and pushes to `main`.

`GITHUB_TOKEN` needs `contents: write` (declared in the workflow). If `main` is
protected, either allow the `github-actions` app to bypass the rule or switch
the final job to `gh pr create --fill` plus `gh pr merge --auto --squash`.
