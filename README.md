# t3code-flake

Nix flake packaging [T3 Code](https://github.com/pingdotgg/t3code) (pingdotgg's
desktop app) for Linux and macOS, in two channels:

| Package          | Channel | Upstream tags                       |
| ---------------- | ------- | ----------------------------------- |
| `t3code`         | stable  | `v0.0.28`                           |
| `t3code-nightly` | nightly | `v0.0.29-nightly.20260725.899`      |

`default` is the stable package, so nightlies are strictly opt-in. Nightlies are
prereleases cut several times a day; expect the pinned version to move often and
to occasionally be broken. Pinned versions and hashes for both channels live in
[`sources.json`](./sources.json); a scheduled GitHub Action bumps them and pushes
to `main` when either channel has a newer release.

## Supported systems

| System           | Artifact                        |
| ---------------- | ------------------------------- |
| `x86_64-linux`   | AppImage wrapped with `appimageTools.wrapType2` |
| `aarch64-darwin` | `.app` bundle extracted from the arm64 zip |
| `x86_64-darwin`  | `.app` bundle extracted from the x64 zip |

## Run it without installing

```sh
nix run github:winter-08/t3code-flake            # stable
nix run github:winter-08/t3code-flake#t3code-nightly
```

## Add to a NixOS / home-manager / nix-darwin config

```nix
{
  inputs.t3code.url = "github:winter-08/t3code-flake";

  # in your system/home config:
  environment.systemPackages = [ inputs.t3code.packages.${pkgs.system}.default ];
  # or the nightly channel:
  # environment.systemPackages = [ inputs.t3code.packages.${pkgs.system}.t3code-nightly ];
  # or on darwin / home-manager:
  # home.packages = [ inputs.t3code.packages.${pkgs.system}.default ];
}
```

Both packages can be installed side by side. The nightly names its executable,
desktop entry and icons `t3code-nightly` (upstream already labels the entry
"T3 Code (Nightly)" and ships a separately named `.app` bundle), so nothing
collides in a shared profile.

On macOS the package installs the `.app` under `$out/Applications` and creates a
`t3code` (or `t3code-nightly`) symlink in `$out/bin`. Use
[`mkAlias`](https://github.com/nix-darwin/nix-darwin) or copy the bundle into
`~/Applications` if you want it in Launchpad.

## Updating manually

```sh
./scripts/update.sh            # both channels
./scripts/update.sh nightly    # just one
```

Requires `jq` and either `gh` or `curl` on `$PATH`. Prints one
`<channel> <version>` line per channel that moved, otherwise stays silent, and
exits 0 either way. Per channel it picks the newest release that has assets for
all three supported systems, walking back past releases whose per-platform
builds failed.

To pin an older version, edit `sources.json` by hand — the asset names and
`sha256` digests are listed on the upstream release page.

## Auto-update workflow

[`.github/workflows/update.yml`](./.github/workflows/update.yml) runs every six
hours (and on demand via `workflow_dispatch`):

1. Runs `scripts/update.sh` against the latest upstream release on each channel.
2. If `sources.json` changed, builds both packages for `x86_64-linux` and
   `aarch64-darwin` to confirm the new hashes actually resolve.
3. Commits the bump with a message like `t3code: bump stable v0.0.28, nightly
   v0.0.29-nightly.20260725.899` and pushes to `main`.

`GITHUB_TOKEN` needs `contents: write` (declared in the workflow). If `main` is
protected, either allow the `github-actions` app to bypass the rule or switch
the final job to `gh pr create --fill` plus `gh pr merge --auto --squash`.
