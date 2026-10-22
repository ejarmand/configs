# The trust store install/security-fixes.sh checked against the forged eMudhra
# chains, with an empty CA directory so the system's can't add the
# compromised roots back. A value set some other way is kept.
_bashrc_ca=${XDG_DATA_HOME:-$HOME/.local/share}/configs
if [[ -s $_bashrc_ca/ca-bundle.pem ]]; then
    export SSL_CERT_FILE=${SSL_CERT_FILE:-$_bashrc_ca/ca-bundle.pem}
    export REQUESTS_CA_BUNDLE=${REQUESTS_CA_BUNDLE:-$_bashrc_ca/ca-bundle.pem}
    export CURL_CA_BUNDLE=${CURL_CA_BUNDLE:-$_bashrc_ca/ca-bundle.pem}
    export SSL_CERT_DIR=${SSL_CERT_DIR:-$_bashrc_ca/no-ca-dir}
    export GIT_SSL_CAINFO=${GIT_SSL_CAINFO:-$_bashrc_ca/ca-bundle.pem}
    export GIT_SSL_CAPATH=${GIT_SSL_CAPATH:-$_bashrc_ca/no-ca-dir}
fi
unset _bashrc_ca
