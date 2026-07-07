# ADR 0001: Detached homelab repository

## Status
Accepted

## Context
Docker compose stacks for self-hosted services (media, photos, VPN mesh, monitoring) were previously managed inside the flat `arch-dotfiles-v2` repo at `~/dotfiles`, alongside unrelated desktop config (Hyprland, waybar, shell, etc.). As dotfiles migrate to a multi-repo submodule architecture (`~/dotfiles-arch`), infrastructure config does not belong in an app-dotfiles parent repo.

## Decision
Maintain homelab infrastructure in a standalone repository at `~/homelab`, detached from `dotfiles-arch`. The homelab repo is the single source of truth for compose files, env templates, monitoring provisioning, and stack orchestration scripts.

## Alternatives considered
- **Keep containers in `~/dotfiles`** — couples infrastructure lifecycle to a legacy repo being actively dismantled; agents and humans must know which repo to edit.
- **Submodule inside `dotfiles-arch`** — homelab is machine-specific infrastructure, not a shareable app config; submodules add overhead without cross-machine reuse.
- **Ansible/Terraform monolith** — overkill for a single-host Docker Compose setup on one desktop.

## Consequences
- Clone and update homelab independently of dotfiles.
- AI agent docs (`CLAUDE.md`, `CONTEXT.md`, ADRs) live in this repo, not in dotfiles-arch.
- Legacy `~/dotfiles/containers/` should be retired once this repo is canonical on the host.
