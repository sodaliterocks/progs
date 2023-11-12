#!/usr/bin/env bash

id="$(echo $RANDOM | md5sum | head -c 6; echo;)"
default_working_dir="./build"

_PLUG_TITLE="Sodalite Builder"
_PLUG_DESCRIPTION=""
_PLUG_ARGS=(
    "path;p;Path to local Sodalite repository;path;."
    "tree;t;Treefile (from ./src/treefiles);string;custom"
    "container;c;Build tree inside Podman container"
    "vendor;;Vendor to use in CPE;string;$USER"
    "working-dir;w;Directory to output build artifacts to;string;$default_working_dir"
    "git-version;g;Execute latest version of $_PLUG_TITLE from GitHub"
    "serve;;Serve repository after successful build"
    "serve-port;;Port to serve on when using --serve;int;8080"
    "buildinfo-anon;;Do not print sensitive information into buildinfo file"
    "skip-cleanup;;Skip cleaning up on exit"
    "skip-tests;;Skip executing tests"
    "ex-container-args;;Extra arguments for Podman when using --container/-c"
    "ex-container-hostname;;Hostname for Podman container when using --container/-c;string;sodalite-build--$id"
    "ex-container-image;;Image for Podman when using --container/-c;string;fedora:39"
    "ex-container-name;;Name for Podman container when using --container/-c;string;sodalite-build_$id"
    "ex-git-version-branch;;Branch to use when using --git-version/-g;string;main"
    "ex-no-unified-core;;Do not use --unified-core option with rpm-ostree"
    "ex-override-starttime;;;int"
    "ex-print-github-release-table-row;;"
)
_PLUG_ROOT="false"

function build_die() {
    exit_code=255
    message="$@"

    say error "$message"
    cleanup

    exit $exit_code
}

function build_emj() {
    if [[ -f /.sodalite-containerenv ]]; then
        echo "$1 "
    else
        echo $(emj "$1")
    fi
}

function cleanup() {
    if [[ "$_skip_cleanup" == "" ]]; then
        say primary "$(build_emj "🗑️")Cleaning up..."

        rm -f "$buildinfo_file"
        rm -rf /var/tmp/rpm-ostree.*

        if [[ $SUDO_USER != "" ]]; then
            if [[ -d "$working_dir" ]]; then
                chown -R $SUDO_USER:$SUDO_USER "$working_dir"
            fi
        fi
    else
        say warning "Not cleaning up (--skip-cleanup used)"
    fi
}

function get_user() {
    if [[ $SUDO_USER != "" ]]; then
        echo "$SUDO_USER"
    else
        echo "$USER"
    fi
}

function main() {
    if [[ "$(id -u)" == "0" ]]; then
        _vendor="$(get_user)"
    else
        if [[ $_container != "true" ]]; then
            die "Only --container supports building with root\n       Either use --container or run command with 'sudo'"
        fi
    fi

    [[ "$_working_dir" == "$default_working_dir" ]] && _working_dir="$_path/build"

    #if [[ $_git_version != "" ]]; then
    #    online_file_branch="$(echo $_ex_git_version_branch | sed "s|/|__|g")"
    #    online_file="https://raw.githubusercontent.com/sodaliterocks/progs/src/$ex_git_version_branch/build.sh"
    #fi
}
