# Hostnames here are the machines' actual short hostnames, not SSH aliases.
_bashrc_storage=
case ${HOSTNAME%%.*} in
    luogeng)
        _bashrc_storage=/media/earmand
        export NVM_DIR="$_bashrc_storage/.local/.nvm"
        # The root disk, which holds /home and /tmp, is full.
        if [[ -d $_bashrc_storage/tmp ]]; then
            export TMPDIR="$_bashrc_storage/tmp"
        fi
        ;;
    yixing)
        _bashrc_storage=/mnt/ultracube/earmand
        ;;
    pandiero)
        # Some locally installed tools live directly under ~/.local/share.
        bashrc_prepend_path "$HOME/.local/share"
        ;;
    mediator)
        export TEMPDIR=/data/tmp TMPDIR=/data/tmp TEMP=/data/tmp TMP=/data/tmp
        export XDG_CACHE_HOME=/data/earmand/.cache
        export APPTAINER_CACHEDIR="$XDG_CACHE_HOME/apptainer"
        bashrc_prepend_path /data/earmand/modules/apptainer/bin
        ;;
esac

if [[ -n $_bashrc_storage ]]; then
    # The same layout as a home directory, on the storage drive.
    # migrations/<host>.sh moves data from the older .local-as-data layout.
    export XDG_DATA_HOME="$_bashrc_storage/.local/share"
    export XDG_STATE_HOME="$_bashrc_storage/.local/state"
    export XDG_CACHE_HOME="$_bashrc_storage/.cache"
    export PIXI_HOME="$_bashrc_storage/.pixi"
fi
unset _bashrc_storage

# install-tools.sh reads this file too, so nvm is installed where shells load it.
if [[ -z ${NVM_DIR-} ]]; then
    NVM_DIR="$HOME/.nvm"
    if [[ -r /usr/share/nvm/init-nvm.sh && -n ${XDG_CONFIG_HOME-} ]]; then
        NVM_DIR="$XDG_CONFIG_HOME/nvm"
    fi
fi
export NVM_DIR
