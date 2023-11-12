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
    "git-version;g;Execute latest version of $_PLUG_TITLE from GitHub (https://github.com/sodaliterocks/progs)"
    "serve;;Serve repository after successful build"
    "serve-port;;Port to serve on when using --serve;int;8080"
    "buildinfo-anon;;Do not print sensitive information into buildinfo file"
    "skip-cleanup;;Skip cleaning up on exit"
    "skip-tests;;Skip executing tests"
    "ex-container-args;;Extra arguments for Podman when using --container/-c"
    "ex-container-hostname;;Hostname for Podman container when using --container/-c;string;sodalite-build--$id"
    "ex-container-image;;Image for Podman when using --container/-c;string;fedora:39"
    "ex-container-image-allow-non-fedora;;Allow images other than Fedora to be used when using --container/-c"
    "ex-container-name;;Name for Podman container when using --container/-c;string;sodalite-build_$id"
    "ex-git-version-branch;;Branch to use when using --git-version/-g;string;main"
    "ex-no-unified-core;;Do not use --unified-core option with rpm-ostree"
    "ex-override-starttime;;;int"
    "ex-print-github-release-table-row;;"
    "ex-use-docker;;Use Docker instead of Podman when using --container/-c (experimental!)"
)
_PLUG_ROOT="true"

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
    me_filename="$SODALITE_BUILD_FILENAME"

    if [[ "$(id -u)" == "0" ]]; then
        _vendor="$(get_user)"
    fi

    [[ "$_working_dir" == "$default_working_dir" ]] && _working_dir="$_path/build"

    if [[ $_container == "true" ]]; then
        container_prog=""
        container_start_time=$(date +%s)

        podman_installed=false
        docker_installed=false

        [[ $(command -v "podman") ]] && podman_installed=true
        [[ $(command -v "docker") ]] && docker_installed=true

        if [[ $_ex_use_docker == "true" ]]; then
            if [[ $docker_installed == false ]]; then
                die_message="Docker not installed (using --ex-use-docker). Cannot build with --container/-c."
                [[ $podman_installed == true ]] && die_message+="\n       However, Podman was detected; try dropping --ex-use-docker to use Podman instead"

                build_die "$die_message"
            else
                container_prog="docker"
            fi
        else
            if [[ $podman_installed == false ]]; then
                die_message="Podman not installed. Cannot build with --container/-c."
                [[ $podman_installed == true ]] && die_message+="\n       However, Docker was detected; try adding --ex-use-docker to use Docker instead (warning: experimental!)"

                build_die "$die_message"
            else
                container_prog="podman"
            fi
        fi

        container_build_args+="--path /wd/src/"
        container_build_args+=" --working-dir /wd/out"
        [[ $_buildinfo_anon != "" ]] && container_build_args+=" --buildinfo-anon $_buildinfo_anon"
        [[ $_ex_no_unified_core != "" ]] && container_build_args+=" --ex-log $ex_log"
        [[ $_ex_print_github_release_table_row != "" ]] && container_build_args+=" --ex-print-github-release-table-row $_ex_print_github_release_table_row"
        [[ $_serve != "" ]] && container_build_args+=" --serve $_serve"
        [[ $_serve_port != "" ]] && container_build_args+=" --serve-port $_serve_port"
        [[ $_skip_cleanup != "" ]] && container_build_args+=" --skip-cleanup $_skip_cleanup"
        [[ $_skip_tests != "" ]] && container_build_args+=" --skip-tests $_skip_tests"
        [[ $_tree != "" ]] && container_build_args+=" --tree $_tree"
        [[ $_vendor != "" ]] && container_build_args+=" --vendor $_vendor"

        if [[ $_ex_override_starttime != "" ]]; then
            container_build_args+=" --ex-override-starttime $_ex_override_starttime"
        else
            container_build_args+=" --ex-override-starttime $container_start_time"
        fi

        container_args="run --rm --privileged \
            --hostname \"$_ex_container_hostname\" \
            --name \"$_ex_container_name\" \
            --volume \"$working_dir:/wd/out/\" \
            --volume \"$src_dir:/wd/src\" "
        [[ ! -z $_ex_conatiner_args ]] && container_args+="$_ex_container_args "

        container_command="touch /.sodalite-containerenv;"
        container_command+="dnf install -y curl git-core git-lfs hostname policycoreutils rpm-ostree selinux-policy selinux-policy-targeted;"
        container_command+="cd /wd/src; /wd/src/$me_filename $container_build_args;"
        container_args+="$container_image /bin/bash -c \"$container_command\""
    fi
}
