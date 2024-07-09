#!/usr/bin/env bash

id="$(echo $RANDOM | md5sum | head -c 6; echo;)"
default_path="."
default_working_dir="./build"
default_ostree_cache_dir="$default_working_dir/cache"
default_ostree_repo_dir="$default_working_dir/repo"

_PLUG_TITLE="Sodalite Builder"
_PLUG_DESCRIPTION=""
_PLUG_ARGS=(
    "path;p;Path to local Sodalite repository;path;$default_path"
    "tree;t;Treefile (from ./src/treefiles);string;custom"
    "container;c;Build tree inside Podman container"
    "working-dir;w;Directory to output build artifacts to;path;$default_working_dir"
    "buildinfo-anon;;Do not print sensitive information into buildinfo file"
    "container-image;;Image for Podman when using --container/-c;string;fedora:40"
    "git-version;;Execute latest version of $_PLUG_TITLE from GitHub (https://github.com/sodaliterocks/progs)"
    "serve;;Serve repository after successful build"
    "serve-port;;Port to serve on when using --serve;int;8080"
    "skip-cleanup;;Skip cleaning up on exit"
    "skip-tests;;Skip executing tests"
    "vendor;;Vendor to use in CPE;string;$USER"
    "ex-container-args;;Extra arguments for Podman when using --container/-c"
    "ex-container-hostname;;Hostname for Podman container when using --container/-c;string;sodalite-build--$id"
    "ex-container-image-allow-non-fedora;;Allow images other than Fedora to be used when using --container/-c"
    "ex-container-name;;Name for Podman container when using --container/-c;string;sodalite-build_$id"
    "ex-git-version-branch;;Branch to use when using --git-version/-g;string;main"
    "ex-no-internet-check;;Do not check for internet connectivity"
    "ex-no-unified-core;;Do not use --unified-core option with rpm-ostree"
    "ex-ostree-cache-dir;;;path;$default_ostree_cache_dir"
    "ex-ostree-repo-dir;;;path;$default_ostree_repo_dir"
    "ex-override-starttime;;;int"
    "ex-print-github-release-table-row;;"
    "ex-use-docker;;Use Docker instead of Podman when using --container/-c (experimental!)"
)
_PLUG_POSITIONAL="tree;tree working-dir"
_PLUG_ROOT="true"

_build_meta_dir=""
_buildinfo_file=""
_ref=""

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

        rm -f "$_buildinfo_file"
        rm -rf /var/tmp/rpm-ostree.*

        if [[ $SUDO_USER != "" ]]; then
            if [[ -d "$_working_dir" ]]; then
                chown -R $SUDO_USER:$SUDO_USER "$_working_dir"
            fi
        fi
    else
        say warning "Not cleaning up (--skip-cleanup used)"
    fi
}

function nudo() { # "Normal User DO"
    cmd="$@"
    eval_cmd="$cmd"

    if [[ $SUDO_USER != "" ]]; then
        eval_cmd="sudo -E -u $SUDO_USER $eval_cmd"
    fi

    eval "$eval_cmd"
}

function ost() {
    command=$1
    options="${@:2}"

    ostree $command --repo="$_ex_ostree_repo_dir" $options
}


function get_treefile() {
    passed_tree="$_tree"
    computed_tree=""
    treefile_dir="$_path/src/treefiles"

    if [[ -f "$treefile_dir/sodalite-desktop-$passed_tree.yaml" ]]; then
        computed_variant="desktop-$passed_tree"
    else
        [[ $passed_tree == *.yaml ]] && passed_tree="$(echo $passed_tree | sed s/.yaml//)"
        [[ $passed_tree == sodalite* ]] && passed_tree="$(echo $passed_tree | sed s/sodalite-//)"

        computed_tree="$passed_tree"
    fi

    echo "$treefile_dir/sodalite-$computed_tree.yaml"
}

function get_user() {
    if [[ $SUDO_USER != "" ]]; then
        echo "$SUDO_USER"
    else
        echo "$USER"
    fi
}

function print_time() {
    ((h=${1}/3600))
    ((m=(${1}%3600)/60))
    ((s=${1}%60))

    h_string="hours"
    m_string="minutes"
    s_string="seconds"

    [[ $h == 1 ]] && h_string="hour"
    [[ $m == 1 ]] && m_string="minute"
    [[ $s == 1 ]] && s_string="second"

    output=""

    [[ $h != "0" ]] && output+="$h $h_string"
    [[ $m != "0" ]] && output+=" $m $m_string"
    [[ $s != "0" ]] && output+=" $s $s_string"

    echo $output
}

###

function build_sodalite() {
    say primary "$(build_emj "🪛")Setting up..."

    git_commit=""
    git_tag=""
    lockfile="$_path/src/shared/overrides.yaml"
    treefile=""
    unified=""

    if [[ ! -f "$(get_treefile)" ]]; then
        build_die "'sodalite-$_tree.yaml' does not exist"
    else
        treefile="$(get_treefile)"
    fi

    if [[ $_ex_no_unified_core == "true" ]]; then
        unified="false"
    else
        unified="true"
    fi

    _buildinfo_file="$_path/src/sysroot/common/usr/lib/sodalite-buildinfo"
    _ref="$(echo "$(cat "$treefile")" | grep "ref:" | sed "s/ref: //" | sed "s/\${basearch}/$(uname -m)/")"

    if [[ $_ref =~ sodalite\/([^;]*)\/([^;]*)\/([^;]*) ]]; then
        ref_channel="${BASH_REMATCH[1]}"
        ref_arch="${BASH_REMATCH[2]}"
        ref_variant="${BASH_REMATCH[3]}"
    else
        build_die "Ref is an invalid format (expecting 'sodalite/<channel>/<arch>/<variant>'; is '$_ref')"
    fi

    if [[ -d "$_path/.git" ]]; then
        git config --global --add safe.directory "$_path"

        git_commit=$(git -C "$_path" rev-parse --short HEAD)

        if [[ "$(git -C "$_path" status --porcelain --untracked-files=no)" == "" ]]; then
            git_tag="$(git -C "$_path" describe --exact-match --tags $(git -C $src_dir log -n1 --pretty='%h') 2>/dev/null)"
        fi

        # BUG: Fails in the container because of host key verification
        say primary "$(build_emj "🗑️")Cleaning up Git repository..."
        nudo git -C "$_path" fetch --prune
        nudo git -C "$_path" fetch --prune-tags
    fi

    if [[ $git_commit != "" ]]; then
        _build_meta_dir="$_working_dir/meta/$git_commit"
    else
        _build_meta_dir="$_working_dir/meta/nogit"
    fi

    mkdir -p "$_build_meta_dir"
    mkdir -p "$_ex_ostree_cache_dir"
    mkdir -p "$_ex_ostree_repo_dir"

    if [ ! "$(ls -A $_ex_ostree_repo_dir)" ]; then
        say primary "$(build_emj "🆕")Initializing OSTree repository..."
        ost init --mode=archive
    fi

    say primary "$(build_emj "📝")Generating buildinfo file (/usr/lib/sodalite-buildinfo)..."

	buildinfo_build_container="false"
    buildinfo_build_host_kernel="$(uname -sr)"
    buildinfo_build_host_name="$(hostname -f)"
    buildinfo_build_host_os="$(get_property /usr/lib/os-release "PRETTY_NAME")"
    buildinfo_build_host_platform="$(uname -m) ($(uname -p))"
    buildinfo_build_tool="rpm-ostree $(echo "$(rpm-ostree --version)" | grep "Version:" | sed "s/ Version: //" | tr -d "'")+$(echo "$(rpm-ostree --version)" | grep "Git:" | sed "s/ Git: //")"

    if [[ $buildinfo_anon != "" ]]; then
        buildinfo_build_host_kernel="(Undisclosed)"
        buildinfo_build_host_name="(Undisclosed)"
        buildinfo_build_host_os="(Undisclosed)"
        buildinfo_build_host_platform="(Undisclosed)"
        buildinfo_build_tool="(Undisclosed)"
    fi

    if [[ -f "/.sodalite-containerenv" ]]; then
    	buildinfo_build_container="true"
    fi

    buildinfo_content="AWESOME=\"Yes\"
\nBUILD_CONTAINER=$buildinfo_build_container
\nBUILD_DATE=\"$(date +"%Y-%m-%d %T %z")\"
\nBUILD_HOST_KERNEL=\"$buildinfo_build_host_kernel\"
\nBUILD_HOST_NAME=\"$buildinfo_build_host_name\"
\nBUILD_HOST_OS=\"$buildinfo_build_host_os\"
\nBUILD_HOST_PLATFORM=\"$buildinfo_build_host_platform\"
\nBUILD_TOOL=\"$buildinfo_build_tool\"
\nBUILD_UNIFIED=$unified
\nGIT_COMMIT=$git_commit
\nGIT_TAG=$git_tag
\nTREE_FILENAME=\"$(basename "$treefile")\"
\nTREE_REF=\"$_ref\"
\nTREE_REF_ARCH=\"$ref_arch\"
\nTREE_REF_CHANNEL=\"$ref_channel\"
\nTREE_REF_VARIANT=\"$ref_variant\"
\nVENDOR=\"$_vendor\""

    echo -e $buildinfo_content > $_buildinfo_file
    cat $_buildinfo_file

    say primary "$(build_emj "⚡")Building tree..."

    compose_args="--repo=\"$_ex_ostree_repo_dir\""
    [[ $_ostree_cache_dir != "" ]] && compose_args+=" --cachedir=\"$_ex_ostree_cache_dir\""
    [[ -s $lockfile ]] && compose_args+=" --ex-lockfile=\"$lockfile\""
    [[ $unified == "true" ]] && compose_args+=" --unified-core"

    eval "rpm-ostree compose tree $compose_args $treefile"

    if [[ $? != 0 ]]; then
        build_die "Failed to build tree"
    fi
}

function publish_sodalite() {
    say primary "$(build_emj "✏️")Generating OSTree summary..."
    ost summary --update
}

function serve_sodalite() {
    say primary "$(build_emj "🥄")Serving repository..."
    check_prog "python"
    python -m http.server --bind 0.0.0.0 --directory "$_working_dir/repo" $_serve_port
    [[ $? != 0 ]] && build_die "Failed to run HTTP server"
}


function test_sodalite() {
    tests_dir="$_path/tests"
    test_failed_count=0

    if [[ -d $tests_dir ]]; then
        if (( $(ls -A "$tests_dir" | wc -l) > 0 )); then
            say primary "$(build_emj "🧪")Testing tree..."

            all_commits="$(ost log $_ref | grep "commit " | sed "s/commit //")"
            commit="$(echo "$all_commits" | head -1)"
            commit_prev="$(echo "$all_commits" | head -2 | tail -1)"

            [[ $commit == $commit_prev ]] && commit_prev=""

            for test_file in $tests_dir/*.sh; do
                export -f ost

                result=$(. "$test_file" 2>&1)

                if [[ $? -ne 0 ]]; then
                    test_message_prefix="Error"
                    test_message_color="33"
                    ((test_failed_count++))
                else
                    if [[ $result != "true" ]]; then
                        test_message_prefix="Fail"
                        test_message_color="31"
                        ((test_failed_count++))
                    else
                        test_message_prefix="Pass"
                        test_message_color="32"
                    fi
                fi

                say "   ⤷ \033[0;${test_message_color}m${test_message_prefix}: $(basename "$test_file" | cut -d. -f1)\033[0m"

                if [[ $result != "true" ]]; then
                    if [[ ! -z $result ]] && [[ $result != "false" ]]; then
                        say "     \033[0;37m${result}\033[0m"
                    fi
                fi
            done
        fi
    fi

    if (( $test_failed_count > 0 )); then
        if [[ -z $commit_prev ]]; then
            ost refs --delete $ref
        else
            ost reset $ref $commit_prev
        fi

        build_die "Failed to satisfy tests ($test_failed_count failed). Removing commit '$commit'..."
    fi
}

###

function main() {
    exit_code=0

    if [[ ! -f /.sodalite-containerenv ]]; then
        if [[ "$(id -u)" == "0" ]]; then
            _vendor="$(get_user)"
        fi
    fi

    [[ "$_path" == "$default_path" ]] && _path="$(pwd)"
    [[ "$_working_dir" == "$default_working_dir" ]] && _working_dir="$_path/build"
    [[ "$_ex_ostree_cache_dir" == "$default_ostree_cache_dir" ]] && _ex_ostree_cache_dir="$_working_dir/cache"
    [[ "$_ex_ostree_repo_dir" == "$default_ostree_repo_dir" ]] && _ex_ostree_repo_dir="$_working_dir/repo"

    mkdir -p "$_path"
    mkdir -p "$_working_dir"

    if [[ $_ex_no_internet_check != "" ]]; then
		say primary "$(emj "🔌")Checking for Internet connectivity..."

		wan_check_output="$(curl -sL https://cdn.zio.sh/ping.txt)"

		if [[ $wan_check_output != "Pong!" ]]; then
			build_die "No Internet connection available"
		fi
    fi

    if [[ $_git_version == "true" ]]; then
        online_file_branch="main"
        online_file="https://raw.githubusercontent.com/sodaliterocks/progs/$online_file_branch/src/rocks.sodalite.builder"
        downloaded_file="$_PLUG_PATH+$online_file_branch"

        local_md5sum="$(cat "$_PLUG_PATH" | md5sum | cut -d ' ' -f1)"
        online_md5sum="$(curl -sL $online_file | md5sum | cut -d ' ' -f1)"

        if [[ $? == 0 ]]; then
            if [[ $local_md5sum != $online_md5sum ]]; then
                curl -sL $online_file > "$downloaded_file"
                chmod +x "$downloaded_file"

                say primary "$(emj "🌐")Executing Git version ($online_file_branch)..."

                bash -c "$downloaded_file $(echo $_PLUG_PASSED_ARGS | sed "s|--git-version||")"
                downloaded_file_result="$?"

                rm -rf "$downloaded_file"
                exit $downloaded_file_result
            fi
        else
            build_die "Unable to check latest remote version of Sodalite Builder"
        fi
    fi

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

        container_build_args+="--path /wd/src/sodalite"
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
            --volume \"$HOME/.ssh:/root/.ssh\" \
            --volume \"$_working_dir:/wd/out\" \
            --volume \"$_PLUG_PATH:/wd/builder\" \
            --volume \"$invoker_dir:/wd/src/invoker\" \
            --volume \"$_path:/wd/src/sodalite\" "
        [[ ! -z $_ex_conatiner_args ]] && container_args+="$_ex_container_args "

        container_command="touch /.sodalite-containerenv;"
        container_command+="dnf install -y curl git-core git-lfs hostname policycoreutils rpm-ostree selinux-policy selinux-policy-targeted;"
        container_command+="cd /wd/src; /wd/src/invoker/invoke.sh /wd/builder $container_build_args"
        container_args+="$_container_image /bin/bash -c \"$container_command\""

        say primary "$(build_emj "⬇️")Pulling container image ($_container_image)..."
        podman pull $_container_image

        say primary "$(build_emj "📦")Executing container ($_ex_container_name)..."
        eval "podman $container_args"
        exit_code=$?
    else
        start_time=""

        if [[ $_ex_override_starttime == "" ]]; then
            start_time=$(date +%s)
        else
            start_time=$_ex_override_starttime # TODO: Validate?
        fi

        check_prog "git"
        check_prog "rpm-ostree"

        mkdir -p "$_working_dir"
        chown -R root:root "$_working_dir"

        build_sodalite
        test_sodalite
        publish_sodalite

        end_time=$(( $(date +%s) - $start_time ))
        highscore="false"
        highscore_file="$_build_meta_dir/highscore"
        prev_highscore=""

        if [[ ! -f "$highscore_file" ]]; then
            touch "$highscore_file"
            echo "$end_time" > "$highscore_file"
        else
            prev_highscore="$(cat "$highscore_file")"
            if (( $end_time < $prev_highscore )); then
                highscore="true"
                echo "$end_time" > "$highscore_file"
            fi
        fi

        cleanup

        echo "$(repeat "-" 80)"

        built_commit="$(echo "$(ost log $_ref | grep "commit " | sed "s/commit //")" | head -1)"
        built_version="$(ost cat $built_commit /usr/lib/os-release | grep "OSTREE_VERSION=" | sed "s/OSTREE_VERSION=//" | sed "s/'//g")"
        built_pretty_name="$(ost cat $built_commit /usr/lib/os-release | grep "PRETTY_NAME=" | sed "s/PRETTY_NAME=//" | sed "s/\"//g")"

        say "$(build_emj "ℹ️")\033[1;35mName:    \033[0;0m$built_pretty_name"
        say "   \033[1;35mBase:    \033[0;0m$(ost cat $built_commit /usr/lib/upstream-os-release | grep "PRETTY_NAME=" | sed "s/PRETTY_NAME=//" | sed "s/\"//g")"
        say "   \033[1;35mVersion: \033[0;0m$built_version"
        say "   \033[1;35mCPE:     \033[0;0m$(ost cat $built_commit /usr/lib/system-release-cpe)"
        say "   \033[1;35mRef:     \033[0;0m$(ost cat $built_commit /usr/lib/sodalite-buildinfo | grep "TREE_REF=" | sed "s/TREE_REF=//" | sed "s/\"//g")"
        say "   \033[1;35mCommit:  \033[0;0m$built_commit"

        if [[ $_ex_print_github_release_table_row != "" ]]; then
            echo "$(repeat "-" 80)"
            github_release_table_row="| <pre><b>$ref</b></pre> | **$(echo $built_pretty_name | sed -s "s| |\&#160;|g")** | $built_version | <pre>$built_commit</pre> |"
            say "$github_release_table_row"
        fi

        echo "$(repeat "-" 80)"

        say primary "$(build_emj "✅")Success ($(print_time $end_time))"
        [[ $highscore == "true" ]] && echo "$(build_emj "🏆") You're Winner (previous: $(print_time $prev_highscore))!"
    fi

    if [[ $serve == "true" ]]; then
        serve_sodalite
    fi

    exit $exit_code
}

if [[ $_PLUG_INVOKED != "true" ]]; then
    base_dir="$(dirname "$(realpath -s "$0")")"
    git_dir="$base_dir/.."
    invoker_dir=""

    if [[ -e "$git_dir/.git" ]]; then
        invoker_dir="$git_dir/lib/sodaliterocks.invoker/src" 
    else
        invoker_dir="/usr/libexec/sodalite/invoker"
    fi

    export invoker_dir
    "$invoker_dir/invoke.sh" "$0" $@
fi
